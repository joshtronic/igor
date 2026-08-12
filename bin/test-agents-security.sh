#!/usr/bin/env bash
# test-agents-security.sh -- regression guard for #374.
#
# The worker contract must NOT instruct the agent to invoke the
# `/security-review` slash command. In this environment that name resolves to
# the aws-dev-toolkit plugin's AWS security skill, whose MCP-tool calls aren't
# permitted by agent-settings.json -- so it errored on every rework tick,
# disabling the in-loop check. The agent now does a REASONED diff self-review;
# the AUTHORITATIVE, fail-closed gate is the harness-side security_gate
# (lib/security-gate.sh), which runs on every push path independently.
#
# Since igor#485-488 the worker's real system prompt is `context_surface
# worker-contract`, not this repo's AGENTS.md -- so this guard validates
# whichever document worker_doc_select actually serves (same choice
# bin/check-sync.sh makes), not a copy the model may never read. A seeded
# cache with the prose stripped, or an unseeded CI run with no in-repo prose
# left to check, must FAIL LOUDLY rather than quietly report "skipped" --
# a guard that goes quiet exactly when its subject disappears is not a guard
# (igor#502, the security gate's finding on this test's first attempt).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/context-source.sh
. "$HERE/../lib/context-source.sh"
# shellcheck source=../lib/worker-doc.sh
. "$HERE/../lib/worker-doc.sh"

FAIL=0
pass() { printf '  + %s\n' "$1"; }
fail() { printf '  x %s\n' "$1"; FAIL=1; }

echo "== worker-contract security directive (#374, #502) =="

DEST=$(mktemp)
trap 'rm -f "$DEST"' EXIT

if ! worker_doc_select "$DEST"; then
  echo "  x prompt cache is seeded but 'worker-contract' could not be served"
  echo "test-agents-security: FAILED"
  exit 1
fi
echo "  (validating against: $WORKER_DOC_LABEL)"

SECURITY_RE="MANDATORY:.*security|security-review my own diff"

if [ "$WORKER_DOC" = "AGENTS.md" ] && ! grep -qiE "$SECURITY_RE" "$WORKER_DOC"; then
  echo "  x cannot verify the security directive: no cache and no in-repo prose"
  echo "test-agents-security: FAILED"
  exit 1
fi

# The exact regression: an imperative to RUN the shadowed slash command.
if grep -qiE "run[[:space:]]+\`?/security-review" "$WORKER_DOC"; then
  fail "still has a 'run \`/security-review\`' imperative"
else
  pass "no 'run \`/security-review\`' imperative"
fi

# The intent survives: a diff security review is still mandated.
if grep -qiE "$SECURITY_RE" "$WORKER_DOC"; then
  pass "still mandates a security review of the diff"
else
  fail "no longer mandates a security review of the diff"
fi

[ "$FAIL" -eq 0 ] && { echo "test-agents-security: all checks passed"; exit 0; }
echo "test-agents-security: FAILED"; exit 1
