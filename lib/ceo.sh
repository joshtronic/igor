#!/usr/bin/env bash
# ceo.sh -- the CEO pass's READ side: convention-driven opt-in via a repo's
# .agent/ceo.md mandate, plus a weekly activity gather for the board digest.
#
# Opt-in is the mandate's mere presence -- exactly like logwatch keys off a
# root systemd/ dir and the review tick keys off the merge. A repo that grows a
# .agent/ceo.md is under autonomous CEO management; no env knob, no hardcoded
# repo. (See the mandate itself: "the mandate's mere presence in the repo is
# what opts [it] into autonomous CEO management.")
#
# Phase 1 is strictly read-only: read the mandate, gather the week, hand both to
# one model call that writes the board digest. No issue-filing / steering /
# doc-edits yet -- those are later phases, per the mandate's "start tight,
# loosen as trust earns it" rope.
#
# Sourced by tick.sh; depends on _fj (lib/forgejo.sh) + jq.

CEO_MANDATE_PATH=".agent/ceo.md"

# ceo_read_mandate <repo> -- echo the mandate's raw content (empty if absent).
ceo_read_mandate() {
  local repo="$1"
  _fj GET "/repos/${repo}/raw/${CEO_MANDATE_PATH}" 2>/dev/null
}

# ceo_repo_has_mandate <repo> -- exit 0 iff the repo opts into CEO management.
ceo_repo_has_mandate() {
  local repo="$1"
  _fj GET "/repos/${repo}/raw/${CEO_MANDATE_PATH}" >/dev/null 2>&1
}

# ceo_gather_week <repo> <since_iso> -- echo a markdown summary of the repo's
# activity since <since_iso> (RFC3339): commits to the default branch, PRs
# merged, issues opened/closed, and the current open Agent queue. This is the
# board digest's evidence base -- what actually happened, for the model to read
# against the mandate's priorities.
ceo_gather_week() {
  local repo="$1" since="$2"
  local prs issues_recent agent_queue

  printf '## Activity on %s since %s\n\n' "$repo" "$since"

  printf '### PRs merged (what shipped)\n'
  prs=$(_fj GET "/repos/${repo}/pulls?state=closed&sort=recentupdate&limit=50" 2>/dev/null)
  jq -r --arg s "$since" '
    [ (.[]? | select((.merged_at // "") >= $s)) ]
    | if length==0 then "- (none)" else (.[] | "- #\(.number) \(.title) (by \(.user.login))") end
  ' <<<"${prs:-[]}" 2>/dev/null || printf -- '- (none)\n'
  printf '\n'

  printf '### Issues opened / closed\n'
  issues_recent=$(_fj GET "/repos/${repo}/issues?state=all&type=issues&since=${since}&limit=50" 2>/dev/null)
  jq -r --arg s "$since" '
    [ (.[]? | select(.pull_request == null)
        | select((.created_at >= $s) or ((.closed_at // "") >= $s))) ]
    | if length==0 then "- (none)"
      else (.[] | "- #\(.number) [\(.state)] \(.title)"
            + (if .created_at >= $s then " (opened)" else "" end)
            + (if (.closed_at // "") >= $s then " (closed)" else "" end)) end
  ' <<<"${issues_recent:-[]}" 2>/dev/null || printf -- '- (none)\n'
  printf '\n'

  printf '### Open Agent queue\n'
  agent_queue=$(_fj GET "/repos/${repo}/issues?state=open&type=issues&labels=Agent&limit=50" 2>/dev/null)
  jq -r '
    [ (.[]? | select(.pull_request == null)) ]
    | if length==0 then "- (none)" else (.[] | "- #\(.number) \(.title)") end
  ' <<<"${agent_queue:-[]}" 2>/dev/null || printf -- '- (none)\n'
}
