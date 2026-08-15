#!/usr/bin/env bash
# automerge.sh -- auto-merge-on-approve + the deploy barrier. Sourced by bin/tick.sh.
#
# "After you approve, your job ends." A repo's dossier declaring a live `url`
# marks it auto-merge-eligible for the SHADOW-gated path -- root AGENTS.md
# `url` (docs/agents-md-spec.md), falling back to legacy agent.json
# (AGENT_CONFIG_FILE) `.smoke.url` via lib/dossier.sh's dossier_get_repo_status
# for any repo that hasn't adopted the spec yet. A repo that genuinely
# declares NO url is not left without a merge path, though: it gets the
# URL-LESS human-approval path instead (igor#520) -- implicitly human-gated,
# like `automerge.require_human`, but skipping the deploy stamp/watch below
# since there's no live URL to smoke-test.
#
# Merge gate on a url-bearing repo: shadow-review APPROVE is the default;
# agent.json .automerge.require_human pins it to the human gate instead.
# Design: igor#404. On a url-bearing merge it stamps a pending deploy under
# .deploy in discretionary-state; a url-less merge skips that stamp entirely.
#
# The deploy barrier (do_deploy_barrier, run EARLY each tick) then watches a
# stamped deploy to verified-healthy -- CI green + the live URL responds --
# and ENDS the tick each minute while it is still deploying, so no long work
# starts mid-deploy (the 1-minute cadence IS the polling loop; the tick is
# never held open). On a failed deploy/smoke it emails ALERT_RECIPIENTS.
# Phase 1 is alert-only: NO automatic revert.
#
# The harness's own repo (AUTOMERGE_SELF_REPO) never declares a url and is
# excluded from the SHADOW-gated path and from deploy-watching -- a watcher
# can't reliably watch itself (a broken self-deploy could crash the very tick
# meant to smoke-test it) -- but it takes the URL-LESS human-approval path
# like any other url-less repo: the concern above is specifically about
# self-SMOKE-watching, which that path never does, and the harness's own
# self-pull picks up merged master on the next tick as it always has.
# No-ops cleanly when no repo opts in.
#
# Two of the url-less repos (igor itself, the distillery) get a HOST-STATE
# landed-watch in place of the deploy/smoke watch -- see lib/landed.sh,
# stamped by landed_record below on their merge.

AGENT_CONFIG_FILE="agent.json"                               # repo root; per-repo machine-config dossier (jq-parsed)
AUTOMERGE_SMOKE_MAX_ATTEMPTS=5                                # propagation grace before a smoke alert
AUTOMERGE_CI_MAX_ATTEMPTS=30                                  # ~30 ticks before a never-reporting deploy CI self-heals
AUTOMERGE_SELF_REPO="${AUTOMERGE_SELF_REPO:-joshtronic/igor}" # url-less: human-approval merge, but never shadow-gated or deploy-watched
AUTOMERGE_BLOCK_COOLDOWN_SECS=3600                            # after a rejected merge, back off ~1h before re-trying the same head

# Fallback logger so this module is sourceable standalone (tests).
if ! declare -F log >/dev/null; then log() { printf '[agent] %s\n' "$*" >&2; }; fi

_deploy_state_file() { echo "${AGENT_STATE_DIR:-$HOME/.local/state/agent}/discretionary-state.json"; }

# automerge_url_status <repo> -- the live URL from the repo's dossier (root
# AGENTS.md `url`, falling back to legacy agent.json `.smoke.url` -- see
# lib/dossier.sh), distinguishing a genuine "no url declared" from a dossier
# fetch that failed THIS TICK (igor#520). A plain dossier_get_repo swallows
# both into the same empty string, which would silently downgrade a
# url-bearing repo with a standing human approve to the no-deploy-watch
# url-less path on one flaky tick -- exactly the "silent downgrade of the
# deploy guarantee" this function exists to prevent. Echoes "<status>\t<url>":
#   ok    -- the dossier (or legacy agent.json) was read cleanly; url is the
#            declared value, or empty when the repo genuinely has none (the
#            repo is auto-merge-eligible via the URL-LESS human-approval
#            path in do_automerge_tick, below)
#   error -- the fetch failed this tick -- the repo must be SKIPPED entirely
#            (no merge, either path) and retried next tick
#
# The harness's own repo is always "ok" with an empty url: it never declares
# a smoke URL, so there's nothing to fetch or fail on -- it always takes the
# url-less human-approval path (see the file header).
#
# Needs dossier_get_repo_status (lib/dossier.sh) sourced -- bin/tick.sh
# sources dossier.sh above automerge.sh; bin/test-automerge.sh mirrors that.
# A MISSING dependency fails CLOSED ("error", not "ok" with an empty url) --
# treating it as "every repo declares no url" would flip every url-bearing
# repo onto the un-watched merge path, silently disabling the deploy barrier
# fleet-wide instead of just refusing to merge.
automerge_url_status() {
  local repo="$1"
  if [ "$repo" = "$AUTOMERGE_SELF_REPO" ]; then printf 'ok\t'; return 0; fi
  if ! declare -F dossier_get_repo_status >/dev/null; then
    log "automerge: BUG -- lib/dossier.sh not sourced; every repo reads as unfetchable (fail closed)"
    printf 'error\t'
    return 0
  fi
  dossier_get_repo_status "$repo" url
}

# automerge_require_human <repo> -- exit 0 if the repo pins itself to a HUMAN
# review gate (`agent.json` `.automerge.require_human == true`); exit 1 otherwise
# (the default -- the shadow review's APPROVE gates the merge). The carve-out for
# repos whose real defect class a diff review can't judge (joshing.you, igor.bot,
# porksicle.com). A url-less repo (including igor itself) is ALREADY
# human-gated upstream, unconditionally, regardless of this flag -- see
# do_automerge_tick's use of automerge_url_status.
automerge_require_human() {
  local repo="$1"
  [ "$(forgejo_repo_get_file "$repo" "$AGENT_CONFIG_FILE" 2>/dev/null \
        | jq -r '.automerge.require_human // false' 2>/dev/null)" = "true" ]
}

# automerge_will_take <repo> <verdict> -- exit 0 if the auto-merge tick will merge
# on this shadow verdict alone: a default (shadow-gated, url-bearing) repo with
# an APPROVE. Used by do_review_tick to skip requesting the human when the merge
# is going to happen without them anyway -- requesting would just be noise for a
# self-merging PR (awareness comes via the ship-report). This is only about the
# APPROVAL signal; CI/mergeable/behind still gate the real merge. A COMMENT
# (won't auto-merge), a require_human carve-out, a url-less repo (igor#520 --
# implicitly human-gated, shadow-APPROVE alone must never take it), or a dossier
# fetch we couldn't read this tick all return 1 -> the human is still asked.
automerge_will_take() {
  local repo="$1" verdict="$2" url_out url_status url
  [ "$verdict" = "APPROVE" ] || return 1
  url_out=$(automerge_url_status "$repo")
  url_status=${url_out%%$'\t'*}; url=${url_out#*$'\t'}
  [ "$url_status" = "ok" ] && [ -n "$url" ] || return 1
  ! automerge_require_human "$repo"
}

# automerge_approved_by <repo> <pr> <user> -- exit 0 if <user>'s CURRENT review on
# the PR is an official, non-dismissed APPROVED (the human green-light). NOT "ever
# approved": Forgejo keeps the full review history, so an old APPROVED followed by
# a later REQUEST_CHANGES must NOT count -- we key on the user's LATEST decision
# review (APPROVED / REQUEST_CHANGES; a COMMENT never changes the verdict).
#
# We trust Forgejo's `dismissed` flag as the authoritative "does this approval
# still count," NOT `stale`. `stale` only means the head moved since the review;
# whether that INVALIDATES the approval is the repo's branch-protection choice
# ("dismiss stale approvals"), which Forgejo encodes by setting `dismissed`. So a
# stale-but-not-dismissed approval still stands -- exactly as a manual merge would
# honor it, and it's a base-merge-staled approval that this un-strands -- without
# imposing a stricter policy than the repo is configured for. (`official` guards
# against a non-counting review from an unauthorized user.)
automerge_approved_by() {
  local repo="$1" pr="$2" user="$3"
  _fj GET "/repos/${repo}/pulls/${pr}/reviews" 2>/dev/null \
    | jq -e --arg u "$user" '
        [ .[]?
          | select(.user.login == $u)
          | select((.dismissed // false) == false)
          | select(.state == "APPROVED" or .state == "REQUEST_CHANGES")
        ]
        | sort_by(.submitted_at)
        | last
        | (. != null) and (.state == "APPROVED") and ((.official // true) == true)
      ' >/dev/null 2>&1
}

# automerge_approval_covers_head <repo> <pr> <user> <head> -- exit 0 if <user>'s
# latest counting APPROVED review still covers the CURRENT head: either the head
# IS the approved commit (a live approval), or the head is only BASE-MERGES on top
# of it (same net diff vs base -- the auto-merge's own require-up-to-date update,
# which stales the approval without changing what the human saw). Exit 1 if any
# NEW content landed after the approval -- a real commit no human reviewed.
#
# This is the security guard the #409 helper enforced, restored after #410 keyed
# automerge_approved_by on `dismissed` (which alone accepts ANY stale approval,
# including one staled by an agent pushing new commits -- the PR tip is
# agent-controlled). #410's bug was checking the approved commit is a DIRECT parent
# of the head, which the MULTI-LEVEL base-merges ctj#59 hit broke (the approved
# commit was several base-merges back). We instead WALK the first-parent chain from
# the head down to the approved commit: a Forgejo "update branch" base-merge makes
# the PR head the FIRST parent and the base commit a later parent, so the
# first-parent line is the PR's own commit history. Reaching the approved commit
# with every skipped merge's other parents sitting on the base branch means nothing
# but base-merges happened. A single-parent commit that ISN'T the approved commit,
# or a merge whose other parent is off the base branch (a hostile merge), is new
# unreviewed content -> fail closed. Robust to any number of base-merge levels.
automerge_approval_covers_head() {
  local repo="$1" pr="$2" user="$3" head="$4"
  local approved base_ref base_tip cur obj n first p ahead walk=0
  approved=$(_fj GET "/repos/${repo}/pulls/${pr}/reviews" 2>/dev/null \
    | jq -r --arg u "$user" '
        [ .[]? | select(.user.login == $u)
          | select((.dismissed // false) == false)
          | select(.state == "APPROVED" or .state == "REQUEST_CHANGES") ]
        | sort_by(.submitted_at) | last
        | if (. != null) and (.state == "APPROVED") then (.commit_id // "") else "" end' 2>/dev/null)
  [ -n "$approved" ] || return 1   # no counting approval, or Forgejo gave no commit_id -> fail closed

  base_ref=$(_fj GET "/repos/${repo}/pulls/${pr}" 2>/dev/null | jq -r '.base.ref // ""' 2>/dev/null)
  [ -n "$base_ref" ] || return 1
  base_tip=$(_fj GET "/repos/${repo}/branches/${base_ref}" 2>/dev/null | jq -r '.commit.id // ""' 2>/dev/null)
  [ -n "$base_tip" ] || return 1

  cur="$head"
  while [ "$walk" -lt 50 ]; do     # bound the walk; base-merges are few
    walk=$((walk + 1))
    [ "$cur" = "$approved" ] && return 0
    obj=$(_fj GET "/repos/${repo}/git/commits/${cur}" 2>/dev/null)
    n=$(jq -r '.parents | length' <<<"$obj" 2>/dev/null)
    [ -n "$n" ] && [ "$n" != "null" ] || return 1
    [ "$n" -ge 2 ] || return 1     # single-parent commit that isn't the approved one -> new content
    first=$(jq -r '.parents[0].sha // ""' <<<"$obj" 2>/dev/null)
    [ -n "$first" ] || return 1
    # Every NON-first parent (the merged-in base commits) must sit on the base
    # branch: compare base_tip...p echoes the commits p is ahead of the tip, so 0
    # means p introduces nothing beyond base. Anything else is an off-base (hostile)
    # merge -> fail closed.
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      ahead=$(_fj GET "/repos/${repo}/compare/${base_tip}...${p}" 2>/dev/null \
        | jq -r 'if type == "object" then (.total_commits // (.commits | length) // -1) else -1 end' 2>/dev/null)
      [ "$ahead" = "0" ] || return 1
    done < <(jq -r '.parents[1:][].sha // empty' <<<"$obj" 2>/dev/null)
    cur="$first"
  done
  return 1   # walk exceeded the bound without reaching the approved commit -- fail closed
}

# automerge_reviewer_blocks <repo> <pr> <user> -- exit 0 if <user>'s CURRENT
# review is a live (non-stale, non-dismissed) REQUEST_CHANGES. A human can veto
# ANY PR -- including a shadow-gated one -- by requesting changes, so this blocks
# the merge regardless of the shadow verdict. Mirror of automerge_approved_by:
# same latest-decision-review logic, inverted to REQUEST_CHANGES.
automerge_reviewer_blocks() {
  local repo="$1" pr="$2" user="$3"
  _fj GET "/repos/${repo}/pulls/${pr}/reviews" 2>/dev/null \
    | jq -e --arg u "$user" '
        [ .[]?
          | select(.user.login == $u)
          | select((.dismissed // false) == false)
          | select(.state == "APPROVED" or .state == "REQUEST_CHANGES")
        ]
        | sort_by(.submitted_at)
        | last
        | (. != null) and (.state == "REQUEST_CHANGES") and ((.stale // false) == false)
      ' >/dev/null 2>&1
}

# automerge_mergeable <repo> <pr> -- exit 0 if the PR is open AND cleanly mergeable.
automerge_mergeable() {
  local repo="$1" pr="$2"
  _fj GET "/repos/${repo}/pulls/${pr}" 2>/dev/null \
    | jq -e '(.state == "open") and (.mergeable == true)' >/dev/null 2>&1
}

# _fj_merge <repo> <pr> -- POST the merge and echo "<http_code>\t<message>".
# Bypasses _fj deliberately: _fj uses `curl -f`, which discards the response body
# on a non-2xx -- but that body carries the REASON ("User not allowed to merge
# PR", a conflict, ...), which we want to log instead of a bare "merge API failed".
_fj_merge() {
  local repo="$1" pr="$2" out code body
  out=$(curl -s -w '\n%{http_code}' --max-time 30 -X POST \
    -H "Authorization: token ${FORGEJO_TOKEN}" -H "Content-Type: application/json" \
    -d '{"Do":"merge","delete_branch_after_merge":true}' \
    "${FORGEJO_URL}/api/v1/repos/${repo}/pulls/${pr}/merge" 2>/dev/null)
  code=${out##*$'\n'}
  body=${out%$'\n'*}
  printf '%s\t%s' "$code" "$(printf '%s' "$body" | jq -r '.message // empty' 2>/dev/null | head -1)"
}

# automerge_do_merge <repo> <pr> -- merge the PR (merge commit). On success echoes
# the merge commit SHA and returns 0. On failure echoes the REASON ("HTTP <code>:
# <message>") and returns 1, so the caller can log WHY (permission, conflict, ...)
# and back off instead of re-POSTing a doomed merge every tick (igor#322).
automerge_do_merge() {
  local repo="$1" pr="$2" res code msg
  res=$(_fj_merge "$repo" "$pr")
  code=${res%%$'\t'*}; msg=${res#*$'\t'}
  case "$code" in
    2??) _fj GET "/repos/${repo}/pulls/${pr}" 2>/dev/null | jq -r '.merge_commit_sha // empty'; return 0 ;;
    *)   printf 'HTTP %s: %s' "$code" "$msg"; return 1 ;;
  esac
}

# -- Rejected-merge backoff (igor#322) --------------------------
#
# A rejected merge (permission, conflict, a required check the API enforces)
# usually WON'T self-heal by re-POSTing next tick -- the old code retried it
# forever, once per tick, with a bare "merge API failed". Instead, record the
# failed head + reason and skip re-attempting the SAME head for a cooldown. It
# self-heals: a config fix is picked up after the cooldown, and a new commit
# (different head) clears the block immediately.
automerge_block_active() {
  # <state-file> <key> <head> -- 0 (skip) if this key last failed on the SAME
  # head within the cooldown; 1 (attempt) otherwise.
  local sf="$1" key="$2" head="$3" bsha bts now
  [ -f "$sf" ] || return 1
  bsha=$(jq -r --arg k "$key" '.automerge_block[$k].sha // ""' "$sf" 2>/dev/null)
  [ "$bsha" = "$head" ] || return 1
  bts=$(jq -r --arg k "$key" '.automerge_block[$k].ts // 0' "$sf" 2>/dev/null)
  now=$(date +%s)
  [ $(( now - bts )) -lt "$AUTOMERGE_BLOCK_COOLDOWN_SECS" ]
}

automerge_block_record() {
  # <state-file> <key> <head> <reason>
  local sf="$1" key="$2" head="$3" reason="$4" tmp now
  [ -f "$sf" ] || echo '{}' >"$sf"
  now=$(date +%s); tmp=$(mktemp)
  if jq --arg k "$key" --arg s "$head" --arg r "$reason" --argjson t "$now" \
    '.automerge_block[$k] = {sha:$s, reason:$r, ts:$t}' "$sf" >"$tmp" 2>/dev/null; then
    mv "$tmp" "$sf"
  else
    rm -f "$tmp"
  fi
}

automerge_block_clear() {
  # <state-file> <key> -- drop this PR's per-PR auto-merge state (on a
  # successful merge): the block, and the risk-gate notification stamp. A
  # merged PR is never revisited, so both would otherwise accumulate forever.
  local sf="$1" key="$2" tmp
  [ -f "$sf" ] || return 0
  tmp=$(mktemp)
  if jq --arg k "$key" '(if .automerge_block then .automerge_block |= del(.[$k]) else . end)
                        | (if .automerge_risk_notified then .automerge_risk_notified |= del(.[$k]) else . end)' "$sf" >"$tmp" 2>/dev/null; then
    mv "$tmp" "$sf"
  else
    rm -f "$tmp"
  fi
}

# -- Risk gate (igor#514) -----------------------------------------------
#
# Deterministic bounds on the shadow-APPROVE auto-merge path ONLY: a
# human-approved merge is never gated here (a human already saw the diff).
# Hardcoded, no config knob (deliberately -- see the issue: "no per-repo
# config for thresholds").

AUTOMERGE_RISK_MAX_LINES=500   # total additions+deletions
AUTOMERGE_RISK_MAX_FILES=20    # changed file count

# automerge_risk_gate <repo> <pr> -- exit 0 if the PR is within the
# deterministic risk bounds (safe for the shadow-APPROVE path to merge
# unattended). On refusal (exit 1), echoes "lines=N, files=N, path=P" for the
# caller to log -- P is the first deny-listed path matched, or "none" if the
# refusal is purely size-based. Any other text means the gate could not
# EVALUATE (as opposed to a bound being exceeded); the caller distinguishes
# them by the leading "lines=".
#
# Fails CLOSED (refuses) whenever the changed-file data can't be trusted: the
# fetch failed (forgejo_pr_files pages, so a truncated listing is a failure,
# not a short array), the response isn't an array, any element is missing
# numeric additions/deletions, or any element is missing a string filename.
# That last one matters because silently skipping a filename-less element
# would be another place this function opens rather than closes -- a shape
# change that drops filenames would make the deny-list walk vacuous instead
# of refusing. `previous_filename` (Forgejo's rename field) is also matched
# against the deny-list, alongside `filename`, so a rename FROM a denied path
# is caught too.
automerge_risk_gate() {
  local repo="$1" pr="$2" files nfiles lines path
  files=$(forgejo_pr_files "$repo" "$pr" 2>/dev/null) || { printf 'unable to fetch changed files'; return 1; }
  nfiles=$(jq -r 'if type == "array" then length else empty end' <<<"$files" 2>/dev/null)
  [ -n "$nfiles" ] || { printf 'unable to fetch changed files'; return 1; }
  lines=$(jq -r 'if all(.[]; (.additions | type) == "number" and (.deletions | type) == "number")
                 then ([.[] | .additions + .deletions] | add // 0) else empty end' <<<"$files" 2>/dev/null)
  [ -n "$lines" ] || { printf 'changed-file data has no additions/deletions counts'; return 1; }
  jq -e 'all(.[]; (.filename | type) == "string")' <<<"$files" >/dev/null 2>&1 \
    || { printf 'changed-file data has no filename'; return 1; }
  path=$(jq -r '.[] | (.filename, (.previous_filename // empty))' <<<"$files" 2>/dev/null | {
    while IFS= read -r f; do
      case "$f" in
        .forgejo/workflows/*|agent.json|AGENTS.md|install.sh|scripts/deploy*|*.sql)
          printf '%s' "$f"; break ;;
      esac
    done
  })
  if [ "${lines:-0}" -gt "$AUTOMERGE_RISK_MAX_LINES" ] 2>/dev/null \
     || [ "${nfiles:-0}" -gt "$AUTOMERGE_RISK_MAX_FILES" ] 2>/dev/null \
     || [ -n "$path" ]; then
    printf 'lines=%s, files=%s, path=%s' "${lines:-0}" "${nfiles:-0}" "${path:-none}"
    return 1
  fi
  return 0
}

# automerge_risk_notified <state-file> <key> <head> -- exit 0 if we already
# requested the human for this EXACT head (so a refused PR doesn't nag every
# tick); exit 1 otherwise. A new commit (different head) clears it -- fresh
# content deserves a fresh notification.
automerge_risk_notified() {
  local sf="$1" key="$2" head="$3" sha
  [ -f "$sf" ] || return 1
  sha=$(jq -r --arg k "$key" '.automerge_risk_notified[$k].sha // ""' "$sf" 2>/dev/null)
  [ -n "$sha" ] && [ "$sha" = "$head" ]
}

# automerge_risk_notify_record <state-file> <key> <head> -- remember that the
# human was asked for this head, so later ticks skip re-asking.
automerge_risk_notify_record() {
  local sf="$1" key="$2" head="$3" tmp
  [ -f "$sf" ] || echo '{}' >"$sf"
  tmp=$(mktemp)
  if jq --arg k "$key" --arg s "$head" '.automerge_risk_notified[$k] = {sha:$s}' "$sf" >"$tmp" 2>/dev/null; then
    mv "$tmp" "$sf"
  else
    rm -f "$tmp"
  fi
}

# automerge_behind_count <repo> <pr> -- how many base-branch commits the PR head
# is missing (0 = up to date, which is exactly what require-up-to-date enforces).
# Echoes -1 when it can't be determined, so the caller skips rather than guesses.
automerge_behind_count() {
  local repo="$1" pr="$2" obj head base cmp
  obj=$(_fj GET "/repos/${repo}/pulls/${pr}" 2>/dev/null) || { echo -1; return; }
  head=$(jq -r '.head.sha // empty' <<<"$obj"); base=$(jq -r '.base.ref // empty' <<<"$obj")
  if [ -z "$head" ] || [ -z "$base" ]; then echo -1; return; fi
  cmp=$(_fj GET "/repos/${repo}/compare/${head}...${base}" 2>/dev/null) || { echo -1; return; }
  jq -r 'if type == "object" then (.total_commits // (.commits | length) // 0) else -1 end' <<<"$cmp" 2>/dev/null || echo -1
}

# automerge_update_branch <repo> <pr> -- merge the base branch into the PR head
# (Forgejo "update branch") so a behind PR satisfies require-up-to-date. The
# human's APPROVAL survives this base-merge (verified live on porksicle#81), and
# the shadow review's patch-id dedup treats the base-merge as an already-seen net
# diff, so it isn't re-reviewed. rc 0 on success.
automerge_update_branch() {
  local repo="$1" pr="$2"
  _fj POST "/repos/${repo}/pulls/${pr}/update" >/dev/null 2>&1
}

# automerge_smoke <url> -- exit 0 if the live URL responds 2xx/3xx.
automerge_smoke() {
  local url="$1" code
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -L "$url" 2>/dev/null || echo 000)
  case "$code" in 2??|3??) return 0 ;; *) return 1 ;; esac
}

# automerge_live_sha <url> -- the live page's <meta name="deploy-sha"> value, or
# empty if the page carries no such marker (the barrier then falls back to a plain
# liveness check). A build that stamps this lets us verify the SERVING build is the
# merged commit, not just that something answered.
automerge_live_sha() {
  curl -fsSL --max-time 20 "$1" 2>/dev/null \
    | grep -oiE '<meta[^>]*name="deploy-sha"[^>]*>' | head -1 \
    | grep -oE 'content="[^"]*"' | head -1 | sed 's/^content="//; s/"$//'
}

# automerge_sitemap_failures <url> -- "sitemap-when-available": if <base>/sitemap.xml
# exists, GET every <loc> and echo the ones that aren't 2xx/3xx (one per line, with
# the code). Empty output = all good OR no sitemap. Capped at 500 urls; a larger
# sitemap is noted on stderr (-> journal), never silently truncated.
automerge_sitemap_failures() {
  local base xml locs total loc code
  local -a loc_arr=()
  base=$(printf '%s' "$1" | sed -E 's#^(https?://[^/]+).*#\1#')
  xml=$(curl -fsSL --max-time 20 "${base}/sitemap.xml" 2>/dev/null) || return 0   # no sitemap -> skip
  locs=$(printf '%s' "$xml" | grep -oE '<loc>[^<]+</loc>' | sed -E 's#</?loc>##g')
  total=$(printf '%s\n' "$locs" | grep -c . || true)
  [ "${total:-0}" -gt 500 ] && printf 'deploy: sitemap has %s urls, checking the first 500\n' "$total" >&2
  # Slice the first 500 from an array, NOT `printf ... | head -500`: head closes
  # the pipe after 500 lines while printf is still writing the rest, killing it
  # with SIGPIPE (broken-pipe spew on every >500-url deploy -- issue #364). No
  # pipe to the reader, no signal.
  mapfile -t loc_arr <<< "$locs"
  for loc in "${loc_arr[@]:0:500}"; do
    [ -n "$loc" ] || continue
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -L "$loc" 2>/dev/null || echo 000)
    case "$code" in 2??|3??) ;; *) printf '%s (%s)\n' "$loc" "$code" ;; esac
  done
}

# _deploy_record <repo> <pr> <sha> <url> -- stamp a pending deploy under .deploy.
_deploy_record() {
  local repo="$1" pr="$2" sha="$3" url="$4" sf tmp
  sf=$(_deploy_state_file); [ -f "$sf" ] || echo '{}' > "$sf"
  tmp=$(mktemp)
  jq --arg r "$repo" --arg p "$pr" --arg s "$sha" --arg u "$url" \
    '.deploy = {repo:$r, pr:$p, sha:$s, url:$u, smoke_attempts:0, ci_attempts:0}' "$sf" > "$tmp" && mv "$tmp" "$sf"
}

# _deploy_clear -- drop the pending deploy.
_deploy_clear() {
  local sf tmp; sf=$(_deploy_state_file); [ -f "$sf" ] || return 0
  tmp=$(mktemp); jq 'del(.deploy)' "$sf" > "$tmp" && mv "$tmp" "$sf"
}

# _deploy_alert <repo> <pr> <sha> <url> <why> -- email ALERT_RECIPIENTS (+ PRIMARY).
_deploy_alert() {
  local repo="$1" pr="$2" sha="$3" url="$4" why="$5" recipients subject body
  log "deploy: ALERT ${repo}#${pr} ${sha:0:8}: ${why}"
  forgejo_comment "$repo" "$pr" \
    "⚠️ **Auto-merge deploy did NOT verify.** ${why}. Merge commit \`${sha:0:8}\`, URL ${url}. Phase 1 is alert-only (no auto-revert) -- needs eyes." \
    2>/dev/null || true
  recipients=$(recipients_with_primary "${ALERT_RECIPIENTS:-}")
  [ -n "$recipients" ] && [ -n "${SMTP2GO_API_KEY:-}" ] && [ -n "${SMTP2GO_SENDER:-}" ] || return 0
  subject="[Agent] Auto-merge deploy needs you: ${repo}#${pr}"
  body="Auto-merged ${repo}#${pr} (you approved it), but the post-merge deploy did
not verify:

  ${why}

Merge commit: ${sha}
Live URL:     ${url}

Phase 1 is alert-only -- no automatic revert. Eyes on it: check CI / the deploy
and the live site."
  if email_send "$subject" "<pre>${body}</pre>" "$body" "$recipients"; then
    log "deploy: alert emailed to ${recipients}"
  else
    log "warning: deploy: alert email failed"
  fi
}

# do_deploy_barrier -- watch a pending deploy. Returns 0 (END THE TICK) while it
# is still deploying; returns 1 (fall through to normal work) when nothing is
# pending, or once the deploy is verified healthy / has failed (alerted). Wire as
# `do_deploy_barrier && exit 0` EARLY in the cascade.
do_deploy_barrier() {
  local sf repo sha url pr attempts ci_attempts ci tmp
  sf=$(_deploy_state_file); [ -f "$sf" ] || return 1
  repo=$(jq -r '.deploy.repo // ""' "$sf" 2>/dev/null)
  [ -n "$repo" ] || return 1   # nothing deploying
  sha=$(jq -r '.deploy.sha // ""' "$sf"); url=$(jq -r '.deploy.url // ""' "$sf")
  pr=$(jq -r '.deploy.pr // ""' "$sf");  attempts=$(jq -r '.deploy.smoke_attempts // 0' "$sf")
  ci_attempts=$(jq -r '.deploy.ci_attempts // 0' "$sf")

  ci=$(forgejo_commit_status "$repo" "$sha")
  case "$ci" in
    success) ;;   # built -- fall through to the smoke
    failure|error)
      _deploy_alert "$repo" "$pr" "$sha" "$url" "deploy CI reported ${ci}"
      _deploy_clear; return 1 ;;
    *)            # pending / unknown / no status posted -- still deploying, but bounded
      ci_attempts=$((ci_attempts + 1))
      if [ "$ci_attempts" -ge "$AUTOMERGE_CI_MAX_ATTEMPTS" ]; then
        # A deploy whose SHA never gets a success/failure status (e.g. it posts a
        # deployment, or a differently-named status context) would otherwise wedge
        # the harness every minute forever. Alert + clear so it self-heals.
        _deploy_alert "$repo" "$pr" "$sha" "$url" \
          "deploy CI never reported success/failure after ${ci_attempts} checks (status=${ci:-none})"
        _deploy_clear; return 1
      fi
      tmp=$(mktemp); jq --argjson a "$ci_attempts" '.deploy.ci_attempts = $a' "$sf" > "$tmp" && mv "$tmp" "$sf"
      log "deploy: ${repo}#${pr} ${sha:0:8} CI=${ci:-unknown} (${ci_attempts}/${AUTOMERGE_CI_MAX_ATTEMPTS}) -- still deploying, ending tick"
      return 0 ;;
  esac

  # -- Liveness / propagation / sitemap, all on the same grace counter ----------
  # Propagation: the live page's <meta name="deploy-sha"> must equal the merged
  # commit, so we KNOW the build that's serving is the one we merged -- not merely
  # that the site is up (monit already owns up/down). No marker on the page ->
  # fall back to a plain liveness curl, the legacy behaviour.
  local live_sha live_ok=0 detail sm_fails
  live_sha=$(automerge_live_sha "$url")
  if [ -n "$live_sha" ]; then
    case "$sha" in
      "$live_sha"*) live_ok=1; detail="deploy-sha ${sha:0:8} is live" ;;
      *)            detail="still serving an older build (deploy-sha ${live_sha:0:8}, want ${sha:0:8})" ;;
    esac
  elif automerge_smoke "$url"; then
    live_ok=1; detail="${url} responds (no deploy-sha marker)"
  else
    detail="${url} did not respond"
  fi

  if [ "$live_ok" -ne 1 ]; then
    # not the merged build yet (rsync/propagation lag, or down) -- grace, then alert
    attempts=$((attempts + 1))
    if [ "$attempts" -ge "$AUTOMERGE_SMOKE_MAX_ATTEMPTS" ]; then
      _deploy_alert "$repo" "$pr" "$sha" "$url" "CI green but ${detail} after ${attempts} checks"
      _deploy_clear; return 1
    fi
    tmp=$(mktemp); jq --argjson a "$attempts" '.deploy.smoke_attempts = $a' "$sf" > "$tmp" && mv "$tmp" "$sf"
    log "deploy: ${repo}#${pr} ${detail} (${attempts}/${AUTOMERGE_SMOKE_MAX_ATTEMPTS}) -- ending tick"
    return 0
  fi

  # The merged build is live. Sitemap-when-available: every <loc> must be 2xx/3xx.
  sm_fails=$(automerge_sitemap_failures "$url")
  if [ -n "$sm_fails" ]; then
    _deploy_alert "$repo" "$pr" "$sha" "$url" \
      "deploy live (${detail}) but sitemap pages failed: $(printf '%s' "$sm_fails" | tr '\n' ' ')"
    _deploy_clear; return 1
  fi

  log "deploy: ${repo}#${pr} verified healthy (CI green, ${detail}) -- resuming work"
  forgejo_comment "$repo" "$pr" \
    "🚀 **Auto-merge deploy verified.** CI green and the live build is the merged commit — ${detail}. Merge commit \`${sha:0:8}\`. (Posted by the harness deploy barrier; no action needed.)" \
    2>/dev/null || log "warning: deploy: confirm-comment failed on ${repo}#${pr}"
  _deploy_clear; return 1
}

# do_automerge_tick -- merge ONE approved bot PR on an auto-merge-eligible
# repo. A url-bearing repo stamps a pending deploy for the barrier
# regardless of which gate approved it (shadow or human/require_human); a
# url-less repo has no live URL to watch and skips the stamp entirely.
# Returns 0 if it merged.
do_automerge_tick() {
  [ -n "${FORGEJO_REVIEWER:-}" ] || return 1
  local sf; sf=$(_deploy_state_file)
  # one deploy at a time (the barrier guards this too, but belt + suspenders)
  [ -f "$sf" ] && [ -n "$(jq -r '.deploy.repo // ""' "$sf" 2>/dev/null)" ] && return 1

  local repo url url_out url_status req_human prs pr head verdict reviewed_sha key ci sha behind
  local behind_repo="" behind_pr="" behind_n="" shadow_only risk_reason
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    url_out=$(automerge_url_status "$repo")
    url_status=${url_out%%$'\t'*}; url=${url_out#*$'\t'}
    # Anything but a clean `ok` is unknown, not "declares no url" -- reading an
    # unrecognized status as url-less is the silent downgrade of the deploy
    # guarantee this whole status channel exists to prevent, so it fails CLOSED.
    if [ "$url_status" != "ok" ]; then
      log "automerge: ${repo} dossier fetch failed this tick -- skipping (retry next tick)"
      continue
    fi
    # A repo that genuinely declares no url is implicitly human-gated
    # (igor#520): never merge on the shadow verdict alone, and skip the
    # deploy stamp/watch below (there's nothing to smoke-test). A url-bearing
    # repo falls back to its own require_human pin, as before.
    if [ -z "$url" ]; then
      req_human=1
    elif automerge_require_human "$repo"; then
      req_human=1
    else
      req_human=0
    fi
    prs=$(forgejo_list_open_bot_prs "$repo" "$BOT_USER" 2>/dev/null) || continue
    while IFS= read -r pr; do
      if [ -z "$pr" ] || [ "$pr" = "null" ]; then continue; fi
      key="${repo}#${pr}"
      shadow_only=0   # reset per-PR: set below only on the shadow-only (no human eyes) merge path
      # Fetch the head sha up front: the default path binds the shadow APPROVE to
      # it (below), and the CI check needs it.
      head=$(_fj GET "/repos/${repo}/pulls/${pr}" 2>/dev/null | jq -r '.head.sha // ""')
      [ -n "$head" ] || continue
      verdict=$(jq -r --arg k "$key" '.review[$k].verdict // ""' "$sf" 2>/dev/null)
      # Approval gate. A flagged repo needs the HUMAN reviewer's live APPROVED
      # review (today's behavior). A default repo merges on the SHADOW review's
      # affirmative APPROVE -- APPROVE only, never COMMENT. On BOTH paths a live
      # REQUEST_CHANGES vetoes: the shadow's on the human path, the human's on the
      # default path -- we never merge over a "no".
      if [ "$req_human" = "1" ]; then
        automerge_approved_by "$repo" "$pr" "$FORGEJO_REVIEWER" || continue
        # A stale-but-not-dismissed approval counts (automerge_approved_by), but
        # ONLY if the current head is the SAME net diff the human approved -- a
        # base-merge, never new agent-pushed content the human never saw.
        if ! automerge_approval_covers_head "$repo" "$pr" "$FORGEJO_REVIEWER" "$head"; then
          log "automerge: ${key} approval predates the current head's content (not a base-merge) -- not merging"; continue
        fi
        if [ "$verdict" = "REQUEST_CHANGES" ]; then
          log "automerge: ${key} human-approved but shadow verdict is REQUEST_CHANGES -- not merging"; continue
        fi
      else
        # Default (shadow-gated). Never merge over a REQUEST_CHANGES -- the shadow's
        # OR the human's. Then merge on EITHER signal: a human FORGEJO_REVIEWER
        # APPROVED review (a human can merge ANY repo by approving -- e.g. the
        # shadow only COMMENTed but the human reviewed and approved), OR the
        # shadow's APPROVE for the CURRENT head. review_record stores the verdict
        # with the sha it reviewed, so a stale APPROVE for an older commit (head
        # advanced with a real change not yet re-reviewed) must NOT merge the
        # unreviewed code; a base-merge keeps sha == head (review_update_sha), so
        # those still qualify.
        reviewed_sha=$(jq -r --arg k "$key" '.review[$k].sha // ""' "$sf" 2>/dev/null)
        if [ "$verdict" = "REQUEST_CHANGES" ]; then
          log "automerge: ${key} shadow verdict is REQUEST_CHANGES -- not merging"; continue
        fi
        if automerge_reviewer_blocks "$repo" "$pr" "$FORGEJO_REVIEWER"; then
          log "automerge: ${key} ${FORGEJO_REVIEWER} requested changes -- not merging"; continue
        fi
        if automerge_approved_by "$repo" "$pr" "$FORGEJO_REVIEWER" \
           && automerge_approval_covers_head "$repo" "$pr" "$FORGEJO_REVIEWER" "$head"; then
          : # human approved THIS net diff (live, or a base-merge-staled approval) -> merge
        elif [ "$verdict" = "APPROVE" ] && [ "$reviewed_sha" = "$head" ]; then
          shadow_only=1   # the shadow approved the current head, no human eyes -> gate on risk
        else
          log "automerge: ${key} not mergeable yet (shadow verdict='${verdict:-none}' reviewed=${reviewed_sha:0:8} head=${head:0:8}; no human approve) -- not auto-merging"; continue
        fi
      fi
      ci=$(forgejo_commit_status "$repo" "$head")
      if [ "$ci" != "success" ]; then
        log "automerge: ${key} CI=${ci:-unknown} -- not merging"; continue
      fi
      automerge_mergeable "$repo" "$pr" || { log "automerge: ${key} not cleanly mergeable -- skipping"; continue; }
      # Risk gate (igor#514): a human-approved merge is never gated (a human
      # already saw the diff) -- only the shadow-only path, the default and
      # only unattended-approval route, is bounded here. Sits BELOW the CI and
      # mergeability checks deliberately: a PR that isn't otherwise merge-ready
      # would have stopped above anyway, so gating it first would only pull the
      # human in on a red-CI head that no one was going to auto-merge.
      if [ "$shadow_only" = "1" ]; then
        if ! risk_reason=$(automerge_risk_gate "$repo" "$pr"); then
          if ! automerge_risk_notified "$sf" "$key" "$head"; then
            case "$risk_reason" in
              lines=*) log "automerge: ${key} exceeds risk gate (${risk_reason}) -- requesting human review" ;;
              *)       log "automerge: ${key} risk gate could not evaluate (${risk_reason}) -- requesting human review" ;;
            esac
            if forgejo_request_review "$repo" "$pr" "$FORGEJO_REVIEWER" 2>/dev/null; then
              automerge_risk_notify_record "$sf" "$key" "$head"
            fi
          else
            case "$risk_reason" in
              lines=*) log "automerge: ${key} exceeds risk gate (${risk_reason}) -- risk-gated (human already requested)" ;;
              *)       log "automerge: ${key} risk gate could not evaluate (${risk_reason}) -- risk-gated (human already requested)" ;;
            esac
          fi
          continue
        fi
      fi
      # Require-up-to-date: the merge API rejects a behind-base PR, so check it
      # OURSELVES rather than POST a doomed merge (the old "merge API failed"
      # warning). 0 = current -> merge now; >0 = behind -> remember it; -1 =
      # couldn't tell -> skip this tick.
      behind=$(automerge_behind_count "$repo" "$pr")
      if [ "$behind" = "0" ]; then
        # Back off a head we already know the API rejects -- don't re-POST a
        # doomed merge every tick (igor#322); the reason was logged on first fail.
        # Still log EACH skipped tick during the cooldown (igor#386) -- the
        # original rejection log line scrolls out of view long before the
        # cooldown clears, and a silent skip here otherwise looks identical
        # to the tick never reaching this PR at all.
        if automerge_block_active "$sf" "$key" "$head"; then
          log "automerge: ${key} still backing off a prior rejected merge on head ${head:0:8} (${AUTOMERGE_BLOCK_COOLDOWN_SECS}s cooldown)"
          continue
        fi
        if sha=$(automerge_do_merge "$repo" "$pr"); then
          automerge_block_clear "$sf" "$key"
          [ -n "$sha" ] || sha="$head"   # fall back to the head if the merge SHA didn't come back
          if [ -n "$url" ]; then
            _deploy_record "$repo" "$pr" "$sha" "$url"
            log "automerge: merged ${key} (approved by ${FORGEJO_REVIEWER}, CI green) -- watching deploy ${sha:0:8}"
          elif landed_applies "$repo"; then
            # igor#512: the two url-less repos this checker knows how to
            # verify (igor itself, the distillery) get a host-state
            # landed-watch instead of a deploy/smoke watch -- see
            # lib/landed.sh.
            landed_record "$repo" "$pr" "$sha"
            log "automerge: merged ${key} (approved by ${FORGEJO_REVIEWER}, CI green) -- no live URL, watching landed-verification ${sha:0:8}"
          else
            log "automerge: merged ${key} (approved by ${FORGEJO_REVIEWER}, CI green) -- no live URL, skipping deploy watch"
          fi
          return 0
        else
          # $sha holds the reason on failure ("HTTP 405: User not allowed ...").
          automerge_block_record "$sf" "$key" "$head" "$sha"
          log "automerge: ${key} merge rejected -- ${sha:-unknown reason}; backing off ${AUTOMERGE_BLOCK_COOLDOWN_SECS}s (head ${head:0:8})"
          continue
        fi
      elif [ "$behind" -gt 0 ] 2>/dev/null; then
        # Ready but behind base. Prefer to merge a CURRENT pr this tick (so master
        # advances just once); only if none is current do we update this one --
        # one branch-update per tick, so a fast-moving master can't make us thrash.
        [ -z "$behind_pr" ] && { behind_repo="$repo"; behind_pr="$pr"; behind_n="$behind"; }
      else
        log "automerge: ${key} up-to-date check inconclusive -- skipping this tick"
      fi
      # WIP checkpoint drafts are excluded up front (a human won't approve one,
      # and Forgejo blocks the merge, but never even consider them).
    done < <(jq -r --arg wip "${CHECKPOINT_WIP_PREFIX:-WIP: }" '.[]? | select((.title // "") | startswith($wip) | not) | .number // empty' <<<"$prs")
    # VALIDATED_REPOS_JSON is a NEWLINE-DELIMITED STREAM of repo objects (one per
    # line), NOT a JSON array -- built that way in tick.sh and consumed the same
    # way by maintenance_repo_validated. So `.full_name` runs per object; `.[]?`
    # would error ("Cannot index string") on a stream. Multi-repo iteration is
    # covered by test-automerge.sh.
  done < <(printf '%s' "${VALIDATED_REPOS_JSON:-}" | jq -r '.full_name // empty' 2>/dev/null)

  # No CURRENT pr merged this tick. If a ready one is only behind base, bring it up
  # to date (merge base in) so it merges next cycle -- the approval survives, CI
  # re-runs, and it's logged as info, never the old failed-merge warning.
  if [ -n "$behind_pr" ]; then
    if automerge_update_branch "$behind_repo" "$behind_pr"; then
      log "automerge: ${behind_repo}#${behind_pr} behind base by ${behind_n} -- updated branch, will merge once CI is green"
    else
      log "warning: automerge: failed to update ${behind_repo}#${behind_pr} branch to base"
    fi
    return 0
  fi
  return 1
}
