#!/usr/bin/env bash
# Unit tests for the stale static-file-server reaper's selection predicate
# (lib/http-reap.sh). Exercises http_reap_select_victims ONLY -- against a
# mock ps-style table, never a real `ps`/`kill` -- so this stays safe to
# run anywhere, including CI. Skip-safe: exits 0 with a notice if a
# required tool is missing.
set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/http-reap.sh
. "$HERE/lib/http-reap.sh"

for t in basename grep awk; do
  command -v "$t" >/dev/null 2>&1 || { echo "test-http-reap: $t unavailable -- skipping"; exit 0; }
done

FAIL=0
killed() {
  # killed <desc> <table> <pid> -- assert pid IS in the victim set
  local desc="$1" table="$2" pid="$3" victims
  victims=$(http_reap_select_victims <<<"$table")
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
  victims=$(http_reap_select_victims <<<"$table")
  if grep -qx "$pid" <<<"$victims"; then
    printf '  x %s: expected pid %s spared, victims=[%s]\n' "$desc" "$pid" "$(tr '\n' ' ' <<<"$victims")"
    FAIL=$((FAIL + 1))
  else
    printf '  + %s\n' "$desc"
  fi
}

echo "== stale python3 -m http.server -> killed =="
T1='1001 1 500 python3 -m http.server 8099'
killed "etimes 500 >= 300, python3 -m http.server" "$T1" 1001

echo "== fresh python3 -m http.server -> spared =="
T2='1002 1 30 python3 -m http.server 8791'
spared "etimes 30 < 300 despite cmdline match" "$T2" 1002

echo "== stale python -m SimpleHTTPServer -> killed =="
T2B='1010 1 500 python -m SimpleHTTPServer 8792'
killed "etimes 500 >= 300, python -m SimpleHTTPServer" "$T2B" 1010

echo "== stale non-server (2h node build) -> spared (signature must match) =="
T3='1003 1 7200 node build.js --watch'
spared "node basename, no server signature" "$T3" 1003
T3B='1013 1 7200 /usr/bin/rustc --edition 2021 main.rs'
spared "unrelated compiler, no server signature, etimes alone is not enough" "$T3B" 1013

echo "== malformed pid -> row skipped by the numeric-pid guard =="
# Same otherwise-reapable cmdline as T1, so the ONLY reason it's spared is
# the non-numeric pid guard -- keeps the guard covered deliberately rather
# than by accident.
T3C='1003b 1 500 python3 -m http.server 8099'
spared "non-numeric pid is never selected" "$T3C" 1003b

echo "== unrelated proc whose ARGS mention a server -> spared =="
T3D='1012 1 7200 tail -F /var/log/http-server.log'
spared "tail on a server logfile is not an interpreter" "$T3D" 1012
T3E='1014 1 7200 grep -r http.server /home/agent/src'
spared "grep for the signature is not an interpreter" "$T3E" 1014

echo "== stale http-server (npm package) -> killed =="
T4='1004 1 900 http-server dist -p 8792'
killed "etimes 900 >= 300, http-server binary" "$T4" 1004

echo "== stale php -S -> killed =="
T4B='1011 1 900 php -S 0.0.0.0:8793 -t dist'
killed "etimes 900 >= 300, php -S" "$T4B" 1011

echo "== harness's own claude/node proc -> never selected =="
T5A='1005 1 9999 /usr/local/bin/claude --dangerously-skip-permissions'
spared "claude basename is protected even when ancient" "$T5A" 1005
T5B='1006 1 9999 node /app/mcp-server/http-server-shim/index.js'
spared "node basename is protected even with a matching cmdline substring" "$T5B" 1006

echo "== login shell (argv0 '-bash') -> no basename error, spared (igor#392 pattern) =="
T6='1009 1 9999 -bash'
err=$(http_reap_select_victims <<<"$T6" 2>&1 >/dev/null)
if [ -n "$err" ]; then
  printf '  x leading-dash argv0 emitted an error: %s\n' "$err"
  FAIL=$((FAIL + 1))
else
  printf '  + %s\n' "leading-dash argv0 produces no basename/option error"
fi
spared "login shell is not a reap victim" "$T6" 1009

echo "== boundary: etimes exactly at threshold -> killed; one below -> spared =="
TB1='1007 1 300 python3 -m http.server 8000'
killed "etimes == 300 (>=) is stale" "$TB1" 1007
TB2='1008 1 299 python3 -m http.server 8000'
spared "etimes == 299 (<) is not yet stale" "$TB2" 1008

echo "== multi-row table -> only the matching stale row is selected =="
MULTI=$(printf '%s\n%s\n%s\n%s\n' \
  '2001 1 500 python3 -m http.server 8099' \
  '2002 1 500 node build.js' \
  '2003 1 20 python3 -m http.server 8100' \
  '2004 1 8000 /usr/local/bin/claude --dangerously-skip-permissions')
victims=$(http_reap_select_victims <<<"$MULTI")
if [ "$victims" = "2001" ]; then
  printf '  + %s\n' "exactly the stale server row is selected, siblings spared"
else
  printf '  x multi-row selection: expected [2001] got [%s]\n' "$(tr '\n' ' ' <<<"$victims")"
  FAIL=$((FAIL + 1))
fi

if [ "$FAIL" -eq 0 ]; then
  echo "test-http-reap: all checks passed"
else
  echo "test-http-reap: $FAIL FAILED"
  exit 1
fi
