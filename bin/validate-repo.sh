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

# FLEET_LANG_GAPS -- one "repo: lang1, lang2" line per repo audited this run
# that has a detected language with no CI step (lib/repo-checks.sh's
# check_language_ci_coverage, via validate_repo_local's advisory report).
# Accumulated across audit_one calls so --all can print a fleet-wide summary
# at the end -- that list is the actual deliverable of igor#614.
FLEET_LANG_GAPS=""

audit_one() {
  local repo="$1" tmp status gaps
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

  # validate_repo_local sets LANG_CI_REPORT as a side effect (igor#614) and
  # clears it first, so this reads THIS repo's gaps even when the clone turned
  # out to be unreadable. Called bare above -- a command substitution would
  # strand the report in a subshell and leave the summary permanently empty.
  gaps=$(lang_ci_gap_list)
  [ -n "$gaps" ] && FLEET_LANG_GAPS="${FLEET_LANG_GAPS}${repo}: ${gaps}"$'\n'

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

  printf '== Language CI gaps (fleet-wide) ==\n'
  if [ -n "$FLEET_LANG_GAPS" ]; then
    printf '%s' "$FLEET_LANG_GAPS"
  else
    printf 'none -- every detected language in every repo has a CI step\n'
  fi

  exit $ANY_FAIL
else
  audit_one "$1"
fi
