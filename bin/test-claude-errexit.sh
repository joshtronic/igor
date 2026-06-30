#!/usr/bin/env bash
# test-claude-errexit.sh -- regression for the igor#291 / #279 crash.
#
# claude_run_with_cost() toggles errexit internally (set +e around the stream
# pipeline, then restore). Every caller wraps the call in `set +e` to capture a
# nonzero exit (a recoverable model crash mid-stream) and handle it. The bug:
# the function restored errexit with an UNCONDITIONAL `set -e`, so on a nonzero
# `return` errexit tripped in the CALLER and took the whole tick down (status=1,
# no "claude exited" line) before the caller could capture the exit. This locks
# in the fix: a nonzero claude exit must come back as a return value, not a
# tick-killing abort.
#
# Run standalone (`bin/test-claude-errexit.sh`) or via `make test`. Skip-safe:
# exits 0 with a notice if a required tool is absent.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"

for tool in jq timeout tee mktemp; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "test-claude-errexit: $tool not installed -- skipping"; exit 0; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Stub `claude`: emit a few stream-json events (assistant text, tool_use,
# tool_result) then exit NONZERO -- the mid-stream model crash we must survive.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}'
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}'
printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result"}]}}'
exit 1
STUB
chmod +x "$TMP/bin/claude"
PATH="$TMP/bin:$PATH"

# Minimal harness deps: a log() (tick.sh provides one) and a state dir for the
# cost/health bookkeeping.
log() { :; }
export AGENT_STATE_DIR="$TMP/state"
mkdir -p "$AGENT_STATE_DIR"
echo '{}' > "$AGENT_STATE_DIR/discretionary-state.json"

# shellcheck source=lib/cost.sh
. "$HERE/lib/cost.sh" 2>/dev/null || true
# shellcheck source=lib/claude.sh
. "$HERE/lib/claude.sh"

fails=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; fails=$((fails + 1)); }

echo "== claude_run_with_cost: nonzero exit must not abort the caller =="

# Replicate the tick.sh caller pattern EXACTLY: errexit ON baseline (the tick's
# `set -euo pipefail`), then `set +e` to guard the call, call, capture, `set -e`.
# Run it in a STANDALONE subshell whose failure we capture via the parent's
# `set +e` -- NOT via `|| true`, because bash disables errexit inside any
# subshell that is an operand of `&&`/`||`/`if`, which would mask the very leak
# under test. On the buggy lib the function leaks `set -e`, so the nonzero return
# aborts the subshell before it writes REACHED.
REACHED="$TMP/reached"
rm -f "$REACHED"
set +e
(
  set -e
  set +e
  claude_run_with_cost "test" "$AGENT_STATE_DIR/out.log" "30s" --print "hi"
  rc=$?
  set -e
  printf '%s\n' "$rc" > "$REACHED"   # only written if the caller SURVIVED
) >/dev/null 2>&1
set -e

if [ -f "$REACHED" ]; then
  ok "caller survived a nonzero claude exit (reached the line after the call)"
  got="$(cat "$REACHED")"
  if [ "$got" = "1" ]; then
    ok "nonzero exit surfaced as a return value (rc=1), not a tick abort"
  else
    bad "expected captured rc=1, got [$got]"
  fi
else
  bad "caller was aborted by the call -- errexit leaked (igor#291 regression)"
fi

# Caller's errexit must be left exactly as it was (the function must not leak
# its internal toggling in EITHER direction).
echo "== errexit state is preserved across the call =="

# Caller had errexit OFF -> must still be OFF afterward.
(
  set +e
  claude_run_with_cost "test" "$AGENT_STATE_DIR/out.log" "30s" --print "hi"
  case $- in *e*) echo on ;; *) echo off ;; esac > "$TMP/e_off"
) >/dev/null 2>&1 || true
if [ "$(cat "$TMP/e_off" 2>/dev/null)" = off ]; then ok "errexit OFF preserved"
else bad "errexit OFF not preserved (got [$(cat "$TMP/e_off" 2>/dev/null)])"; fi

# Caller had errexit ON (guarding the nonzero return with || true) -> still ON.
(
  set -e
  claude_run_with_cost "test" "$AGENT_STATE_DIR/out.log" "30s" --print "hi" || true
  case $- in *e*) echo on ;; *) echo off ;; esac > "$TMP/e_on"
) >/dev/null 2>&1 || true
if [ "$(cat "$TMP/e_on" 2>/dev/null)" = on ]; then ok "errexit ON preserved"
else bad "errexit ON not preserved (got [$(cat "$TMP/e_on" 2>/dev/null)])"; fi

if [ "$fails" -eq 0 ]; then
  echo "test-claude-errexit: all checks passed"
  exit 0
else
  echo "test-claude-errexit: $fails check(s) failed"
  exit 1
fi
