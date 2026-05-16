#!/usr/bin/env bash
# validate-repo.sh -- audit a Forgejo repo for Igor readiness without
# cloning it. Prints a markdown checklist; exits 0 if all checks pass,
# 1 if any fail. Use this to spot-check before adding a repo, or to
# debug an auto-filed onboarding ticket.
#
# Usage:
#   validate-repo.sh <owner>/<name>          # check one repo
#   validate-repo.sh --all                   # check every bot-accessible repo

set -uo pipefail

IGOR_HOME="$(cd "$(dirname "$0")/.." && pwd)"
IGOR_CONFIG_DIR="${IGOR_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/igor}"

if [ -f "$IGOR_CONFIG_DIR/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$IGOR_CONFIG_DIR/.env"
  set +a
fi

# shellcheck source=../lib/forgejo.sh
. "$IGOR_HOME/lib/forgejo.sh"
# shellcheck source=../lib/validate-repo.sh
. "$IGOR_HOME/lib/validate-repo.sh"

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
