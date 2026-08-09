#!/usr/bin/env bash
# validate-repo.sh -- audit a Forgejo repo for agent readiness. Clones the
# repo to a temp dir and runs the same LOCAL checks the tick uses
# (lib/repo-checks.sh), then prints a markdown checklist. Exits 0 if all
# checks pass, 1 if any fail. Use this to spot-check before adding a repo,
# or to see why a repo the bot can reach isn't being worked.
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
# shellcheck source=../lib/dossier.sh
. "$AGENT_HOME/lib/dossier.sh"
# shellcheck source=../lib/repo-checks.sh
. "$AGENT_HOME/lib/repo-checks.sh"

if [ $# -ne 1 ]; then
  echo "usage: validate-repo.sh <owner>/<name> | --all" >&2
  exit 2
fi

# Same SSH clone URL the harness uses (bin/tick.sh:ssh_clone_url).
ssh_clone_url() {
  local repo="$1"
  if [[ "${FORGEJO_HOST:-}" == *:* ]]; then
    echo "ssh://git@${FORGEJO_HOST}/${repo}.git"
  else
    echo "git@${FORGEJO_HOST}:${repo}.git"
  fi
}

audit_one() {
  local repo="$1" tmp status
  printf '== %s ==\n' "$repo"
  tmp=$(mktemp -d) || { echo "mktemp failed" >&2; return 2; }
  # Shallow clone of the default branch is all the checks read.
  if ! git clone --quiet --depth 1 "$(ssh_clone_url "$repo")" "$tmp" 2>/dev/null; then
    printf 'could not clone %s -- check bot access\n\n' "$repo"
    rm -rf "$tmp"
    return 2
  fi
  validate_repo_local "$repo" "$tmp"
  status=$?
  rm -rf "$tmp"

  # Agent greenlight label -- repo metadata, so it's the one API read here and
  # deliberately NOT in validate_repo_local (that stays pure local-clone reads
  # for the per-tick hot path). ADVISORY: a missing `Agent` label is now safe
  # (the gate fails closed since #375), so it never flips readiness -- but a
  # repo meant to be agentic that lacks it silently does no issue work, so we
  # flag it "so you notice" (#376).
  forgejo_repo_has_label "$repo" Agent
  case $? in
    0) printf -- '- [x] %s\n' '`Agent` greenlight label defined' ;;
    1) printf -- '- [ ] %s -- %s\n' '`Agent` greenlight label defined (advisory)' \
         'no issues here are claimable until this repo defines an `Agent` label -- the greenlight gate has nothing to match' ;;
    *) printf -- '- [~] %s\n' '`Agent` label check skipped -- could not read repo labels (network/token)' ;;
  esac

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
