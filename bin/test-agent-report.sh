#!/usr/bin/env bash
# test-agent-report.sh -- regression guard for #398.
#
# agent-report.sh "<body>" posts a comment to Forgejo and closes the issue --
# a real, irreversible side effect. Invoking it with --help/-h must
# short-circuit to usage and exit 0 WITHOUT contacting Forgejo. The
# regression: --help was taken as the report BODY and posted a junk comment
# to the live issue.
#
# The guard sits AHEAD of the ISSUE_NUMBER/FORGEJO_REPO/AGENT_HOME checks, so
# we prove the short-circuit by running --help with none of those set (env -i):
# a correct guard exits 0 first; a missing guard falls through to those
# required-var checks (or the Forgejo call) and exits non-zero.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/agent-report.sh"
FAIL=0
pass() { printf '  + %s\n' "$1"; }
fail() { printf '  x %s\n' "$1"; FAIL=1; }

echo "== agent-report.sh --help short-circuit (#398) =="

for flag in --help -h; do
  # Run with the tick env deliberately UNSET (env -i also blocks any FORGEJO_*
  # leak from the caller). Correct guard: exit 0 before the env checks fire.
  out=$(env -i PATH="$PATH" bash "$SCRIPT" "$flag" 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "$flag exits 0 with no tick env (short-circuits before the env checks)"
  else
    fail "$flag exited $rc -- did not short-circuit before the env/Forgejo checks"
  fi
  if printf '%s' "$out" | grep -qi "usage"; then
    pass "$flag prints usage text"
  else
    fail "$flag did not print usage text"
  fi
done

# Sanity: a real body with no ISSUE_NUMBER must STILL fail -- the guard must
# not have swallowed normal argument/env validation.
if env -i PATH="$PATH" bash "$SCRIPT" "a real body" >/dev/null 2>&1; then
  fail "a real body with no ISSUE_NUMBER unexpectedly succeeded"
else
  pass "a real body still requires the tick env (validation intact)"
fi

[ "$FAIL" -eq 0 ] && { echo "test-agent-report: all checks passed"; exit 0; }
echo "test-agent-report: FAILED"
exit 1
