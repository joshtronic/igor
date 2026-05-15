#!/usr/bin/env bash
# Forgejo API helpers. Sourced by bin/tick.sh and bin/agent-*.sh.
#
# Requires in environment:
#   FORGEJO_URL    -- e.g., https://git.sherver.org
#   FORGEJO_TOKEN  -- bot's API token (loaded from $TICK_HOME/.env)
#
# Requires on PATH: curl, jq.

: "${FORGEJO_URL:?FORGEJO_URL must be set}"
: "${FORGEJO_TOKEN:?FORGEJO_TOKEN must be set}"

_fj() {
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -sf -X "$method" \
      -H "Authorization: token $FORGEJO_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$body" \
      "$FORGEJO_URL/api/v1${path}"
  else
    curl -sf -X "$method" \
      -H "Authorization: token $FORGEJO_TOKEN" \
      "$FORGEJO_URL/api/v1${path}"
  fi
}

# Oldest open issue with label:Agent, no assignee, no Status/Blocked.
# Returns the issue JSON on stdout, or empty if none.
forgejo_find_claimable() {
  local repo="$1"
  _fj GET "/repos/${repo}/issues?state=open&labels=Agent&type=issues&sort=oldest&limit=50" \
    | jq -c '
        map(select(
          ((.assignees // []) | length) == 0
          and (([.labels[].name] | index("Status/Blocked")) == null)
        ))
        | sort_by(.created_at)
        | first // empty
      '
}

forgejo_get_issue() {
  local repo="$1" number="$2"
  _fj GET "/repos/${repo}/issues/${number}"
}

# All open issues currently assigned to a given user.
# Returns a JSON array (possibly empty). Filters client-side so this
# works the same across Forgejo versions.
forgejo_find_assigned() {
  local repo="$1" user="$2"
  _fj GET "/repos/${repo}/issues?state=open&type=issues&limit=50" \
    | jq -c --arg u "$user" '
        map(select(
          (.assignees // []) | map(.login) | index($u) != null
        ))
      '
}

forgejo_assign() {
  local repo="$1" number="$2" user="$3"
  _fj PATCH "/repos/${repo}/issues/${number}" \
    "$(jq -n --arg u "$user" '{assignees: [$u]}')" >/dev/null
}

forgejo_unassign_all() {
  local repo="$1" number="$2"
  _fj PATCH "/repos/${repo}/issues/${number}" '{"assignees": []}' >/dev/null
}

forgejo_comment() {
  local repo="$1" number="$2" body="$3"
  _fj POST "/repos/${repo}/issues/${number}/comments" \
    "$(jq -n --arg b "$body" '{body: $b}')" >/dev/null
}

forgejo_open_pr() {
  local repo="$1" head="$2" base="$3" title="$4" body="$5"
  _fj POST "/repos/${repo}/pulls" \
    "$(jq -n \
        --arg t "$title" --arg b "$body" \
        --arg h "$head"  --arg ba "$base" \
        '{title: $t, body: $b, head: $h, base: $ba}')" >/dev/null
}

# Add a label by name. Forgejo's API takes label IDs, so this resolves
# name -> id with a single API call.
forgejo_add_label() {
  local repo="$1" number="$2" name="$3"
  local id
  id=$(_fj GET "/repos/${repo}/labels" \
       | jq -r --arg n "$name" '.[] | select(.name == $n) | .id' \
       | head -1)
  [ -n "$id" ] || { echo "label not found: $name" >&2; return 1; }
  _fj POST "/repos/${repo}/issues/${number}/labels" \
    "$(jq -n --argjson id "$id" '{labels: [$id]}')" >/dev/null
}

# Returns the authenticated user's login (the bot's username). Empty
# on failure.
forgejo_whoami() {
  _fj GET "/user" | jq -r '.login // empty'
}

# Lists every repo the bot has push access to. Returns a JSON array of
# {full_name, default_branch}. Paginated (50/page).
forgejo_list_bot_repos() {
  local page=1 batch count all='[]'
  while batch=$(_fj GET "/user/repos?limit=50&page=${page}"); do
    count=$(jq 'length' <<<"$batch")
    [ "$count" -eq 0 ] && break
    all=$(printf '%s\n%s' "$all" "$batch" | jq -s 'add')
    [ "$count" -lt 50 ] && break
    page=$((page + 1))
  done
  jq '[.[] | select(.permissions.push == true)
        | {full_name, default_branch}]' <<<"$all"
}

# All open issues currently assigned to the authenticated user across
# every accessible repo. Returns a JSON array. Used by the recovery
# sweep -- one call replaces N per-repo calls.
forgejo_my_assigned() {
  _fj GET "/repos/issues/search?state=open&type=issues&assigned=true&limit=50"
}
