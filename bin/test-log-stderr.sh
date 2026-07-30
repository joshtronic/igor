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

echo "== every log() definition outside tests redirects to stderr =="
# Matches on the DEFINITION, not on one exact byte sequence: a future lib that
# uses `echo`, a different format string, or a new prefix is still caught. The
# first version of this test byte-matched `printf '[agent] %s\n' "$*"` and would
# have waved all three through.
#
# Limitation, stated rather than oversold: it reads the definition LINE, so a
# multi-line log() body would need this extended. Every definition in the repo
# is a one-liner today, and the count floor below is the alarm for that changing.
#
# bin/test-*.sh are excluded on purpose -- suites legitimately stub log() as a
# no-op or a capture-into-variable.
NON_STDERR=$(grep -rnE '(^|[^a-zA-Z0-9_])log\(\) \{' "$HERE"/bin/*.sh "$HERE"/lib/*.sh 2>/dev/null \
  | grep -v '/test-' | grep -v '>&2' || true)
eq "no log() definition still writes to stdout" "" "$NON_STDERR"

DEFS=$(grep -rlE '(^|[^a-zA-Z0-9_])log\(\) \{' "$HERE"/bin/*.sh "$HERE"/lib/*.sh 2>/dev/null | grep -vc '/test-')
if [ "$DEFS" -ge 20 ]; then ok "checked $DEFS non-test files defining log()"
else bad "expected >=20 non-test files defining log(), found $DEFS -- did the grep drift?"; fi

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
