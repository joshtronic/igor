#!/usr/bin/env bash
# Unit tests for the stale headless-browser reaper's selection predicate
# (lib/browser-reap.sh). Exercises browser_reap_select_victims ONLY --
# against a mock ps-style table, never a real `ps`/`kill` -- so this stays
# safe to run anywhere, including CI. Skip-safe: exits 0 with a notice if
# a required tool is missing.
set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/browser-reap.sh
. "$HERE/lib/browser-reap.sh"

for t in basename grep awk; do
  command -v "$t" >/dev/null 2>&1 || { echo "test-browser-reap: $t unavailable -- skipping"; exit 0; }
done

FAIL=0
killed() {
  # killed <desc> <table> <pid> -- assert pid IS in the victim set
  local desc="$1" table="$2" pid="$3" victims
  victims=$(browser_reap_select_victims <<<"$table")
  if grep -qx "$pid" <<<"$victims"; then
    printf '  + %s\n' "$desc"
  else
    printf '  x %s: expected pid %s selected, victims=[%s]\n' "$desc" "$pid" "$(tr '\n' ' ' <<<"$victims")"
    FAIL=$((FAIL + 1))
  fi
}
spared() {
  # spared <desc> <table> <pid> -- assert pid is NOT in the victim set
  local desc="$1" table="$2" pid="$3" victims
  victims=$(browser_reap_select_victims <<<"$table")
  if grep -qx "$pid" <<<"$victims"; then
    printf '  x %s: expected pid %s spared, victims=[%s]\n' "$desc" "$pid" "$(tr '\n' ' ' <<<"$victims")"
    FAIL=$((FAIL + 1))
  else
    printf '  + %s\n' "$desc"
  fi
}

echo "== stale headless_shell -> killed =="
T1='1001 1 4000 /usr/lib/chromium/headless_shell --headless --disable-gpu'
killed "etimes 4000 >= 3600, headless_shell binary" "$T1" 1001

echo "== fresh headless_shell -> spared =="
T2='1002 1 30 /usr/lib/chromium/headless_shell --headless --disable-gpu'
spared "etimes 30 < 3600 despite binary match" "$T2" 1002

echo "== stale non-browser (2h node build) -> spared (signature must match) =="
T3='1003 1 7200 node build.js --watch'
spared "node basename, no browser signature" "$T3" 1003
T3B='1003b 1 7200 /usr/bin/rustc --edition 2021 main.rs'
spared "unrelated compiler, no browser signature, etimes alone is not enough" "$T3B" 1003b

echo "== stale chrome with --headless -> killed =="
T4='1004 1 5000 /opt/google/chrome/chrome --headless --disable-gpu --remote-debugging-port=9222'
killed "etimes 5000 >= 3600, chrome + --headless" "$T4" 1004

echo "== harness's own claude/node proc -> never selected =="
T5A='1005 1 9999 /usr/local/bin/claude --dangerously-skip-permissions'
spared "claude basename is protected even when ancient" "$T5A" 1005
T5B='1006 1 9999 node /app/mcp-server/index.js --playwright'
spared "node basename is protected even with a playwright-looking cmdline" "$T5B" 1006

echo "== login shell (argv0 '-bash') -> no basename error, spared (igor#392) =="
# A login shell's argv[0] is '-bash', so ${cmd%% *} is '-bash'; basename must
# not treat it as an option. Under the harness's errexit that error aborted the
# whole selection loop, so real victims after such a row were never reaped.
T6='1009 1 9999 -bash'
err=$(browser_reap_select_victims <<<"$T6" 2>&1 >/dev/null)
if [ -n "$err" ]; then
  printf '  x leading-dash argv0 emitted an error: %s\n' "$err"
  FAIL=$((FAIL + 1))
else
  printf '  + %s\n' "leading-dash argv0 produces no basename/option error"
fi
spared "login shell is not a reap victim" "$T6" 1009

echo "== boundary: etimes exactly at threshold -> killed; one below -> spared =="
TB1='1007 1 3600 /usr/lib/chromium/headless_shell --headless'
killed "etimes == 3600 (>=) is stale" "$TB1" 1007
TB2='1008 1 3599 /usr/lib/chromium/headless_shell --headless'
spared "etimes == 3599 (<) is not yet stale" "$TB2" 1008

echo "== multi-row table -> only the matching stale row is selected =="
MULTI=$(printf '%s\n%s\n%s\n%s\n' \
  '2001 1 5000 /usr/lib/chromium/headless_shell --headless' \
  '2002 1 5000 node build.js' \
  '2003 1 20 /usr/lib/chromium/headless_shell --headless' \
  '2004 1 8000 /usr/local/bin/claude --dangerously-skip-permissions')
victims=$(browser_reap_select_victims <<<"$MULTI")
if [ "$victims" = "2001" ]; then
  printf '  + %s\n' "exactly the stale browser row is selected, siblings spared"
else
  printf '  x multi-row selection: expected [2001] got [%s]\n' "$(tr '\n' ' ' <<<"$victims")"
  FAIL=$((FAIL + 1))
fi

if [ "$FAIL" -eq 0 ]; then
  echo "test-browser-reap: all checks passed"
else
  echo "test-browser-reap: $FAIL FAILED"
  exit 1
fi
