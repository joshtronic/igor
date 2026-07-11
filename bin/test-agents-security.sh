#!/usr/bin/env bash
# test-agents-security.sh -- regression guard for #374.
#
# AGENTS.md must NOT instruct the agent to invoke the `/security-review` slash
# command. In this environment that name resolves to the aws-dev-toolkit
# plugin's AWS security skill, whose MCP-tool calls aren't permitted by
# agent-settings.json -- so it errored on every rework tick, disabling the
# in-loop check. The agent now does a REASONED diff self-review; the
# AUTHORITATIVE, fail-closed gate is the harness-side security_gate
# (lib/security-gate.sh), which runs on every push path independently.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENTS="$HERE/../AGENTS.md"
FAIL=0
pass() { printf '  + %s\n' "$1"; }
fail() { printf '  x %s\n' "$1"; FAIL=1; }

echo "== AGENTS.md security directive (#374) =="

# The exact regression: an imperative to RUN the shadowed slash command.
if grep -qiE "run[[:space:]]+\`?/security-review" "$AGENTS"; then
  fail "AGENTS.md still has a 'run \`/security-review\`' imperative"
else
  pass "no 'run \`/security-review\`' imperative"
fi

# The intent survives: a diff security review is still mandated.
if grep -qiE "MANDATORY:.*security|security-review my own diff" "$AGENTS"; then
  pass "still mandates a security review of the diff"
else
  fail "AGENTS.md no longer mandates a security review of the diff"
fi

[ "$FAIL" -eq 0 ] && { echo "test-agents-security: all checks passed"; exit 0; }
echo "test-agents-security: FAILED"; exit 1
