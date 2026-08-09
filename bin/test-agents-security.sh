#!/usr/bin/env bash
# test-agents-security.sh -- regression guard for #374.
#
# The worker-contract system prompt must NOT instruct the agent to invoke
# the `/security-review` slash command. In this environment that name
# resolves to the aws-dev-toolkit plugin's AWS security skill, whose
# MCP-tool calls aren't permitted by agent-settings.json -- so it errored
# on every rework tick, disabling the in-loop check. The agent now does a
# REASONED diff self-review; the AUTHORITATIVE, fail-closed gate is the
# harness-side security_gate (lib/security-gate.sh), which runs on every
# push path independently.
#
# Since igor#485/#486 the worker's actual system prompt is the sourced
# `worker-contract` (lib/context-source.sh's last-good Distillery cache),
# not this repo's AGENTS.md -- AGENTS.md is now a stub carrying only the
# check-sync.sh sentinels (igor#487). Skip-safe like every other suite
# here: without a seeded cache there is no local copy of the real prompt
# to check, and this suite has no business reaching the network.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/context-source.sh
. "$HERE/lib/context-source.sh"

if ! context_seeded; then
  echo "test-agents-security: prompt cache unseeded -- skipping (no local copy of the real worker-contract to check)"
  exit 0
fi

CONTRACT="$(mktemp)"
trap 'rm -f "$CONTRACT"' EXIT
context_surface worker-contract > "$CONTRACT"

FAIL=0
pass() { printf '  + %s\n' "$1"; }
fail() { printf '  x %s\n' "$1"; FAIL=1; }

echo "== worker-contract security directive (#374) =="

# The exact regression: an imperative to RUN the shadowed slash command.
if grep -qiE "run[[:space:]]+\`?/security-review" "$CONTRACT"; then
  fail "worker-contract still has a 'run \`/security-review\`' imperative"
else
  pass "no 'run \`/security-review\`' imperative"
fi

# The intent survives: a diff security review is still mandated.
if grep -qiE "MANDATORY:.*security|security-review my own diff" "$CONTRACT"; then
  pass "still mandates a security review of the diff"
else
  fail "worker-contract no longer mandates a security review of the diff"
fi

[ "$FAIL" -eq 0 ] && { echo "test-agents-security: all checks passed"; exit 0; }
echo "test-agents-security: FAILED"; exit 1
