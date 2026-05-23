#!/usr/bin/env bash
# validate-repo.sh -- audit a Forgejo repo for the agent readiness without
# cloning it. Prints a markdown checklist; exits 0 if all checks pass,
# 1 if any fail. Use this to spot-check before adding a repo, or to
# debug an auto-filed onboarding ticket.
#
# Usage:
#   validate-repo.sh <owner>/<name>          # check one repo
#   validate-repo.sh --all                   # check every bot-accessible repo

set -uo pipefail

AGENT_HOME="$(cd "$(dirname "$0")/.." && pwd)"

if [ -f "$AGENT_HOME/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$AGENT_HOME/.env"
  set +a
fi

# shellcheck source=../lib/forgejo.sh
. "$AGENT_HOME/lib/forgejo.sh"
# shellcheck source=../lib/repo-checks.sh
. "$AGENT_HOME/lib/repo-checks.sh"

if [ $# -ne 1 ]; then
  echo "usage: validate-repo.sh <owner>/<name> | --all" >&2
  exit 2
fi

audit_one() {
  local repo="$1"
  printf '== %s ==\n' "$repo"
  validate_repo_via_api "$repo"
  local status=$?
  echo
  return $status
}

if [ "$1" = "--all" ]; then
  ANY_FAIL=0
  repos=$(forgejo_list_bot_repos)
  while read -r r; do
    [ -z "$r" ] && continue
    audit_one "$r" || ANY_FAIL=1
  done < <(jq -r '.[].full_name' <<<"$repos")
  exit $ANY_FAIL
else
  audit_one "$1"
fi
