#!/usr/bin/env bash
# test-log-stderr.sh -- log() must write to stderr, not stdout (igor#453).
#
# The bug this locks down: nearly every helper that logs is invoked inside
# command substitution --
#
#   raw=$(claude_call ...) || { log "review call failed"; }
#
# -- so a log() that printf's to STDOUT has its output captured into `raw` and
# thrown away with it. On 2026-07-28 that swallowed nineteen consecutive
# `claude review: failed (rc=...)` lines: the journal recorded only that the
# review failed, never why, and the filed ticket (#453) could not name a cause.
# `rc=124` would have said "timeout" on the first occurrence.
#
# systemd routes both streams to the journal (agent.service sets neither
# StandardOutput nor StandardError), so stderr loses nothing and stops the
# diagnostics from contaminating captured values.
#
# Skip-safe: needs jq for the claude_call block; the rest runs anywhere.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"

FAIL=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi; }

echo "== every log() in the repo writes to stderr =="
# A property test, not a list: a lib added later with a stdout fallback fails
# here rather than silently reintroducing the swallow. Deliberately covers the
# `if ! declare -F log ...; fi` one-liners too.
STDOUT_LOGGERS=$(grep -rn "log() { printf '\[agent\] %s\\\\n' \"\$\*\"; }" \
  "$HERE"/bin/*.sh "$HERE"/lib/*.sh 2>/dev/null || true)
eq "no [agent] log() still printing to stdout" "" "$STDOUT_LOGGERS"

DEFS=$(grep -rlE "log\(\) \{ printf '\[agent\]" "$HERE"/bin/*.sh "$HERE"/lib/*.sh 2>/dev/null | wc -l)
if [ "$DEFS" -ge 15 ]; then ok "found $DEFS files defining an [agent] log() (all checked)"
else bad "expected >=15 files with an [agent] log(), found $DEFS -- did the grep drift?"; fi

echo "== the swallow itself: a logging function inside \$( ) =="
# The exact shape from the review path.
OUT=$(
  log() { printf '[agent] %s\n' "$*" >&2; }
  failing() { log "claude review: failed (rc=124) -- timeout"; return 1; }
  captured=$(failing 2>/dev/null) || true
  printf '%s' "$captured"
)
eq "the captured value stays clean" "" "$OUT"

ERR=$( {
  log() { printf '[agent] %s\n' "$*" >&2; }
  failing() { log "claude review: failed (rc=124) -- timeout"; return 1; }
  captured=$(failing) || true
  : "$captured"
} 2>&1 )
case "$ERR" in
  *"rc=124"*) ok "and the reason still reaches stderr" ;;
  *)          bad "and the reason still reaches stderr: got [$ERR]" ;;
esac

echo "== the real claude_call path (igor#453's actual code) =="
if ! command -v jq >/dev/null 2>&1; then
  echo "  (jq absent -- skipping the claude_call block)"
else
  # Stub `claude` as a real executable: claude_call invokes it through `env`,
  # which execs and so cannot see a shell function.
  STUB=$(mktemp -d); trap 'rm -rf "$STUB"' EXIT
  printf '#!/usr/bin/env bash\necho "boom: model unavailable" >&2\nexit 42\n' > "$STUB/claude"
  chmod +x "$STUB/claude"
  export PATH="$STUB:$PATH"
  export AGENT_STATE_DIR="$STUB"          # no inherited health backoff
  cost_record_cli() { :; }                # not under test here

  # shellcheck source=../lib/claude.sh
  . "$HERE/lib/claude.sh"

  CAPTURED=$(claude_call "test-model" "review" 100 "sys" "usr" 0 5 2>"$STUB/err") && RC=0 || RC=$?
  eq "claude_call reports failure" "1" "$RC"
  eq "the caller's captured value is EMPTY, not a log line" "" "$CAPTURED"
  case "$(cat "$STUB/err")" in
    *"claude review: failed"*) ok "the failure reason lands on stderr where the journal sees it" ;;
    *) bad "the failure reason lands on stderr: got [$(head -c 200 "$STUB/err")]" ;;
  esac
  case "$(cat "$STUB/err")" in
    *"rc=42"*) ok "and it carries the exit code (rc=124 would have named #453's timeout)" ;;
    *) bad "and it carries the exit code: got [$(head -c 200 "$STUB/err")]" ;;
  esac
fi

if [ "$FAIL" -eq 0 ]; then
  echo "test-log-stderr: all checks passed"
else
  echo "test-log-stderr: $FAIL FAILED"
  exit 1
fi
