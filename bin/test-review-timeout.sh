#!/usr/bin/env bash
# test-review-timeout.sh -- the shadow review gets its own wall-clock budget
# (igor#453).
#
# What went wrong: claude_call defaults to 300s, and reviewer_effort escalates to
# `max` at rework round 3. Measured on igor#455, same PR, consecutive rounds:
# effort=high on 24683 chars produced a verdict in 77s; effort=max on 26898 chars
# timed out (rc=124) twice, then landed in 197s. So `max` near the 400-line scope
# cap straddles the default budget.
#
# The consequence is worse than a slow review. A timeout leaves the head
# un-recorded, do_review_tick re-picks the same PR next tick, and every other PR
# in the fleet queues behind it -- which is exactly what it looked like on
# 2026-07-30 until one attempt got lucky.
#
# Skip-safe: needs jq (claude_call parses its envelope with it).
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "test-review-timeout: jq absent -- skipping"; exit 0; }

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TICK="$HERE/bin/tick.sh"

FAIL=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi; }

echo "== claude_call actually honours an explicit timeout =="
# The behavioural half. Everything else here is a source assertion, but this is
# the mechanism the whole fix rests on: if the 7th argument were ignored, the
# constant below would be decoration and the bug would survive the PR.
STUB=$(mktemp -d); trap 'rm -rf "$STUB"' EXIT
printf '#!/usr/bin/env bash\nsleep 30\n' > "$STUB/claude"
chmod +x "$STUB/claude"

OUT=$(
  PATH="$STUB:$PATH" AGENT_STATE_DIR="$STUB" bash -c '
    cost_record_cli() { :; }
    . "'"$HERE"'/lib/claude.sh"
    start=$(date +%s)
    claude_call "m" "review" 100 "sys" "usr" 0 2 >/dev/null 2>"'"$STUB"'/err"
    printf "%s %s" "$?" "$(( $(date +%s) - start ))"
  '
)
RC="${OUT%% *}"; SECS="${OUT##* }"
eq "a call that outruns its budget fails" "1" "$RC"
if [ "$SECS" -le 6 ]; then ok "and is killed at the budget, not 30s later (${SECS}s)"
else bad "and is killed at the budget, not 30s later (took ${SECS}s)"; fi
if grep -q 'rc=124' "$STUB/err"; then
  ok "the journal gets rc=124, so a timeout is diagnosable as a timeout"
else
  bad "the journal gets rc=124: got [$(head -c 120 "$STUB/err")]"
fi

echo "== the review call site uses its own budget (source assertions) =="
if grep -q 'REVIEW_CALL_TIMEOUT_SECS=' "$TICK"; then
  ok "REVIEW_CALL_TIMEOUT_SECS is defined"
else bad "REVIEW_CALL_TIMEOUT_SECS is defined"; fi

if grep -q 'claude_call "\${AGENT_MODEL_REVIEW}:\${rev_effort}".*"\$REVIEW_CALL_TIMEOUT_SECS"' "$TICK"; then
  ok "the shadow-review call passes it"
else bad "the shadow-review call passes it -- without the 7th arg it silently falls back to 300s"; fi

# The whole point is that it EXCEEDS claude_call's default. Setting it to 300 or
# below would leave the file looking fixed while changing nothing, which is the
# one regression a source assertion can actually catch here.
BUDGET=$(sed -n 's/^REVIEW_CALL_TIMEOUT_SECS=\([0-9]*\).*/\1/p' "$TICK" | head -1)
DEFAULT=$(sed -n 's/.*CLAUDE_CALL_TIMEOUT_SECS:-\([0-9]*\)}.*/\1/p' "$HERE/lib/claude.sh" | head -1)
eq "claude_call's default is still what we think" "300" "${DEFAULT:-?}"
if [ -n "$BUDGET" ] && [ "$BUDGET" -gt "${DEFAULT:-300}" ]; then
  ok "the review budget (${BUDGET}s) exceeds the default (${DEFAULT}s)"
else
  bad "the review budget (${BUDGET:-unset}) must exceed the default (${DEFAULT:-300}) or this fix is a no-op"
fi
# Observed successful max-effort run was 197s; anything under ~2x that is not
# meaningfully more headroom than the budget it replaced.
if [ -n "$BUDGET" ] && [ "$BUDGET" -ge 400 ]; then
  ok "and leaves real headroom over the 197s max-effort run we measured"
else
  bad "and leaves real headroom over the 197s max-effort run we measured (got ${BUDGET:-unset})"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "test-review-timeout: all checks passed"
else
  echo "test-review-timeout: $FAIL FAILED"
  exit 1
fi
