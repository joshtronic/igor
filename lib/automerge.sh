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
# REQUIRED-AND-EXPLICIT (igor#558) -- no default. Self-identity must never be
# a defaulted knob: an unset var fails the tick loudly instead of every
# install silently running against joshtronic/igor. bin/tick.sh also carries
# a `:?` check beside the other required env (same posture as DISTILLERY_REPO,
# igor#551); this one covers every OTHER caller that sources this file
# directly (bin/test-automerge.sh, bin/test-landed.sh, bin/test-blockprobe.sh).
: "${AUTOMERGE_SELF_REPO:?AUTOMERGE_SELF_REPO must be set -- no default, see .env.example}"
AUTOMERGE_BLOCK_COOLDOWN_SECS=3600                            # after a rejected merge, back off ~1h before re-trying the same head

# -- Maintenance-tier carve-out (igor#516, agnostic per igor#537) ----------
#
# A narrow, deterministic exception to a require_human pin: a repo's OWN
# review->master PR merges WITHOUT the human gate when every
# automerge_maintenance_tier_* check below agrees the diff is pure
# maintenance churn (no listing added or removed). igor#516 scoped this to
# ONE hardcoded repo (joshtronic/joshing.you); igor#537 made the repo pin
# "any repo whose dossier declares automerge.maintenance" -- the safety
# no longer comes from being pinned to one repo, it comes from the
# declaration being REQUIRED-AND-EXPLICIT (missing/partial = tier off, no
# defaults -- automerge_maintenance_declaration) plus the dossier-file
# refusal guard below.
#
# The base branch stays hardcoded: only the review branch's NAME was ever a
# per-repo fact (the head side of the refresh pipeline's own PR); "master"
# is this harness's fleet-wide default-branch convention (see PR_BASE in
# AGENTS.md), not a fact about whichever repo declares the tier.
AUTOMERGE_MAINTENANCE_TIER_BASE_BRANCH="master"

# Filenames that must never fall inside a declared maintenance-tier
# allowlist or data_file -- the security invariant (igor#537): a repo can
# READ its own automerge.maintenance privileges from its dossier, but must
# never be able to CHANGE them unattended. If a maintenance-tier PR could
# touch its own dossier, it could quietly widen its own allowlist (or flip
# require_human) for a LATER PR that no human ever reviewed. Enforced at
# declaration-read time (automerge_maintenance_declaration), not per-diff --
# a repo whose declaration violates this never qualifies for the tier at
# all, on any PR.
AUTOMERGE_MAINTENANCE_DOSSIER_FILES="agent.json AGENTS.md"

# The rejected.json "guard-rejection belt" (no net GAIN of a declared
# rejection category) applies ONLY when a declaring repo's own allowlist
# opts this literal FILE PATH in. The path itself stays hardcoded -- a
# fleet-wide convention for where a maintenance-tier repo's rejection log
# lives, same footing as AUTOMERGE_MAINTENANCE_TIER_BASE_BRANCH below. The
# CATEGORY NAME is not hardcoded (igor#558, was: joshing.you's
# "no-josh-visible" baked in here): it comes from the repo's own declared
# `rejected_category`, read alongside branch/allowlist/data_file
# (automerge_maintenance_declaration). A repo that opts this file into its
# allowlist but declares no category fails the WHOLE declaration closed --
# see automerge_maintenance_declaration -- so the belt can never be
# silently skipped by omission.
AUTOMERGE_MAINTENANCE_REJECTED_FILE="src/_data/rejected.json"

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
# repos whose real defect class a diff review can't judge (a personal-sites
# directory whose defects are data content, a blog whose defects are
# visual/typographic, a game whose bugs are visual/interaction -- none
# diffable). A url-less repo (including igor itself) is ALREADY human-gated
# upstream, unconditionally, regardless of this flag -- see do_automerge_tick's
# use of automerge_url_status.
#
# Fails closed on UNKNOWN, never on UNSTATED (igor#578; three prior attempts
# -- igor#561, #562, #571 -- all got this backwards). A readable config that
# simply never mentions the key, or has no `.automerge` object at all, is an
# EXPRESSED intent -- the repo hasn't opted in, same as master's behavior
# always was -- and must NOT gate. Only a state the harness genuinely could
# not read requires a human: the file gone (404, e.g. mid dossier-conversion),
# a fetch/transport error, malformed JSON, or a 200 with an empty body. Uses
# forgejo_repo_get_file_status (found/missing/error) rather than the plain
# forgejo_repo_get_file so a 403/5xx can't masquerade as "no file" and get
# read as unstated. The comparison is `== true` rather than a `-r`-and-string
# compare so it stays type-aware: the JSON string "true" is not the boolean.
automerge_require_human() {
  local repo="$1" out status body rc
  out=$(forgejo_repo_get_file_status "$repo" "$AGENT_CONFIG_FILE" 2>/dev/null) || out=$'error\t'
  status=${out%%$'\t'*}
  [ "$status" = "found" ] || return 0
  body=${out#*$'\t'}
  jq -e '.automerge.require_human == true' <<<"$body" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 1 ] && return 1
  return 0
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
  forgejo_pr_reviews "$repo" "$pr" 2>/dev/null \
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
  approved=$(forgejo_pr_reviews "$repo" "$pr" 2>/dev/null \
    | jq -r --arg u "$user" '
        [ .[]? | select(.user.login == $u)
          | select((.dismissed // false) == false)
          | select(.state == "APPROVED" or .state == "REQUEST_CHANGES") ]
        | sort_by(.submitted_at) | last
        | if (. != null) and (.state == "APPROVED") then (.commit_id // "") else "" end' 2>/dev/null)
  [ -n "$approved" ] || return 1   # no counting approval, or Forgejo gave no commit_id -> fail closed

  base_ref=$(forgejo_get_pr "$repo" "$pr" 2>/dev/null | jq -r '.base.ref // ""' 2>/dev/null)
  [ -n "$base_ref" ] || return 1
  base_tip=$(forgejo_get_branch "$repo" "$base_ref" 2>/dev/null | jq -r '.commit.id // ""' 2>/dev/null)
  [ -n "$base_tip" ] || return 1

  cur="$head"
  while [ "$walk" -lt 50 ]; do     # bound the walk; base-merges are few
    walk=$((walk + 1))
    [ "$cur" = "$approved" ] && return 0
    obj=$(forgejo_get_commit "$repo" "$cur" 2>/dev/null)
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
      ahead=$(forgejo_compare "$repo" "$base_tip" "$p" 2>/dev/null \
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
  forgejo_pr_reviews "$repo" "$pr" 2>/dev/null \
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

# _automerge_maintenance_path_allowed <path> <allowlist-json-array> -- exit 0
# if <path> matches one of the glob patterns in <allowlist-json-array>
# (a compact JSON array of strings). Shared glob-match primitive for the
# files/data checks below.
_automerge_maintenance_path_allowed() {
  local f="$1" allowlist="$2" pat
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    # shellcheck disable=SC2254  # deliberate glob match -- $pat is a declared allowlist pattern, not a literal
    case "$f" in $pat) return 0 ;; esac
  done < <(jq -r '.[]?' <<<"$allowlist" 2>/dev/null)
  return 1
}

# automerge_maintenance_declaration <repo> -- echoes the repo's agent.json
# `.automerge.maintenance` declaration as a compact single-line JSON object
# {branch, allowlist, data_file, rejected_category?} and returns 0 IFF it is
# REQUIRED-AND-EXPLICIT: branch and data_file are non-empty strings,
# allowlist is a non-empty array of non-empty strings, and neither the
# allowlist nor data_file can ever match a dossier file
# (AUTOMERGE_MAINTENANCE_DOSSIER_FILES, above -- deliverable 3, igor#537).
# Missing or partial declaration reads as "the maintenance tier does not
# exist for this repo" -- no defaults; a partial one logs ONE loud line so
# the gap is visible instead of silently no-op'ing.
#
# rejected_category is OPTIONAL at this level -- most repos never opt
# AUTOMERGE_MAINTENANCE_REJECTED_FILE into their allowlist at all, and the
# tier doesn't require the guard-rejection belt to function. But a repo that
# DOES opt that file in must also declare the category it wants guarded
# (igor#558): silently skipping the belt on a missing category would turn a
# safety check into a no-op by omission, which is worse than the file simply
# not being in the tier at all. That combination refuses the WHOLE
# declaration, same posture as the dossier-file check below; so does a
# category that is present but malformed, unconditionally -- see the type
# check in the body.
#
# Reads agent.json off forgejo_repo_get_file, which -- passed no `ref` --
# resolves against the repo's DEFAULT BRANCH (see lib/review.sh's
# trust-model note), never a PR head under classification. That is what
# makes a maintenance-tier PR editing its own agent.json powerless to affect
# its OWN classification: the edit can only take effect for a LATER PR,
# after this one already merged (or didn't) through today's rules.
automerge_maintenance_declaration() {
  local repo="$1" cfg decl branch data_file allowlist allowlist_len rejected_category

  cfg=$(forgejo_repo_get_file "$repo" "$AGENT_CONFIG_FILE" 2>/dev/null) || return 1
  [ -n "$cfg" ] || return 1
  decl=$(jq -c '.automerge.maintenance // empty' <<<"$cfg" 2>/dev/null)
  [ -n "$decl" ] && [ "$decl" != "null" ] || return 1

  branch=$(jq -r '.branch // empty' <<<"$decl" 2>/dev/null)
  data_file=$(jq -r '.data_file // empty' <<<"$decl" 2>/dev/null)
  allowlist=$(jq -c '.allowlist // empty' <<<"$decl" 2>/dev/null)
  allowlist_len=$(jq -r 'if type == "array" then length else empty end' <<<"$allowlist" 2>/dev/null)
  rejected_category=$(jq -r '.rejected_category // empty' <<<"$decl" 2>/dev/null)

  if [ -z "$branch" ] || [ -z "$data_file" ] || [ -z "$allowlist_len" ] || [ "$allowlist_len" -eq 0 ] \
     || ! jq -e 'all(.[]; type == "string" and length > 0)' <<<"$allowlist" >/dev/null 2>&1; then
    log "automerge: ${repo} declares a partial automerge.maintenance (branch, allowlist, and data_file are all required, non-empty) -- tier off"
    return 1
  fi

  if _automerge_maintenance_declares_dossier_file "$allowlist" "$data_file"; then
    log "automerge: ${repo} automerge.maintenance allowlist/data_file would match its own dossier (${AUTOMERGE_MAINTENANCE_DOSSIER_FILES}) -- refusing the declaration (a repo can read its privileges, never change them unattended)"
    return 1
  fi

  # A DECLARED category must be a non-empty STRING. `jq -r` renders an array,
  # number or object to a non-empty string, so a mistyped category would sail
  # past the emptiness check below and then match nothing in rejected.json --
  # zero rejections counted on both sides, belt passes trivially. Same silent
  # no-op the missing-category refusal exists to prevent, reached by mistyping
  # instead of by omission, and unlike branch/data_file (which fail closed at
  # the branch check and at `git show`) this one fails OPEN. Refused
  # regardless of whether the allowlist opts the file in: the field is inert
  # there, but a malformed declaration is still malformed.
  if ! jq -e '.rejected_category == null or (.rejected_category | type == "string" and length > 0)' <<<"$decl" >/dev/null 2>&1; then
    log "automerge: ${repo} declares a non-string (or empty) automerge.maintenance rejected_category -- refusing the declaration (a category that matches nothing would silently no-op the guard-rejection belt)"
    return 1
  fi

  if _automerge_maintenance_path_allowed "$AUTOMERGE_MAINTENANCE_REJECTED_FILE" "$allowlist" && [ -z "$rejected_category" ]; then
    log "automerge: ${repo} opts ${AUTOMERGE_MAINTENANCE_REJECTED_FILE} into its allowlist but declares no rejected_category -- refusing the declaration (the guard-rejection belt must never silently no-op)"
    return 1
  fi

  printf '%s' "$decl"
}

# _automerge_maintenance_declares_dossier_file <allowlist-json-array>
# <data_file> -- exit 0 if <data_file>, or any AUTOMERGE_MAINTENANCE_DOSSIER_FILES
# name, matches one of the allowlist's glob patterns -- i.e. the declaration
# would let a maintenance-tier PR touch its own dossier.
_automerge_maintenance_declares_dossier_file() {
  local allowlist="$1" data_file="$2" dossier
  for dossier in $AUTOMERGE_MAINTENANCE_DOSSIER_FILES; do
    _automerge_maintenance_path_allowed "$dossier" "$allowlist" && return 0
    [ "$data_file" = "$dossier" ] && return 0
  done
  return 1
}

# automerge_maintenance_tier_branch_ok <pr_json> <head_branch> -- exit 0 if
# this is the declared refresh pipeline's own SAME-REPO
# <head_branch>->master PR: the head repo is literally the base repo (not a
# fork that happens to name its branch the same -- the branch-name pin alone
# would be satisfied while the local clone's origin/<head_branch> is
# entirely unrelated content; igor#516 security review). Base branch is
# always AUTOMERGE_MAINTENANCE_TIER_BASE_BRANCH (see the constant's comment).
automerge_maintenance_tier_branch_ok() {
  local pr_json="$1" head_branch="$2" head_ref base_ref head_full base_full
  head_ref=$(jq -r '.head.ref // ""' <<<"$pr_json" 2>/dev/null)
  base_ref=$(jq -r '.base.ref // ""' <<<"$pr_json" 2>/dev/null)
  head_full=$(jq -r '.head.repo.full_name // ""' <<<"$pr_json" 2>/dev/null)
  base_full=$(jq -r '.base.repo.full_name // ""' <<<"$pr_json" 2>/dev/null)
  [ "$head_ref" = "$head_branch" ] \
    && [ "$base_ref" = "$AUTOMERGE_MAINTENANCE_TIER_BASE_BRANCH" ] \
    && [ -n "$head_full" ] && [ "$head_full" = "$base_full" ]
}

# automerge_maintenance_tier_files_ok <repo> <pr> <allowlist-json-array> --
# exit 0 (echoing the changed-file count) if every changed path -- and, for
# a rename, its previous path too -- sits inside the declared allowlist.
# Anything else (scripts, workflows, templates, evidence/) refuses. Fails
# CLOSED on an unwalkable file listing (forgejo_pr_files pages; a truncated
# listing must never read as "all allowlisted") or a filename-less element,
# same posture as automerge_risk_gate.
automerge_maintenance_tier_files_ok() {
  local repo="$1" pr="$2" allowlist="$3" files nfiles bad
  files=$(forgejo_pr_files "$repo" "$pr" 2>/dev/null) || return 1
  nfiles=$(jq -r 'if type == "array" then length else empty end' <<<"$files" 2>/dev/null)
  [ -n "$nfiles" ] || return 1
  jq -e 'all(.[]; (.filename | type) == "string")' <<<"$files" >/dev/null 2>&1 || return 1
  bad=$(jq -r '.[] | (.filename, (.previous_filename // empty))' <<<"$files" 2>/dev/null | {
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      _automerge_maintenance_path_allowed "$f" "$allowlist" && continue
      printf '%s' "$f"; break
    done
  })
  [ -z "$bad" ] || return 1
  printf '%s' "$nfiles"
}

# automerge_maintenance_tier_data_ok <clone-path> <base-sha> <head-sha>
# <data_file> <allowlist-json-array> <rejected_category> -- exit 0 if
# <data_file> changed only in ways the maintenance tier trusts unattended:
# no listing added or removed. Additionally applies the rejected.json
# "guard-rejection belt" (no net GAIN of <rejected_category> entries) IF the
# repo's own allowlist opts AUTOMERGE_MAINTENANCE_REJECTED_FILE in (see that
# constant's comment -- the FILE PATH stays hardcoded; the category is the
# caller-supplied <rejected_category>, sourced from the repo's own
# declaration). Fails closed if the file is allowlisted but
# <rejected_category> is empty OR omitted -- the caller
# (automerge_maintenance_tier_ok) only reaches here with a declaration
# automerge_maintenance_declaration already validated, so this is a
# defensive second line, not the primary gate.
#
# <data_file> is compared by CORE IDENTITY, not a line-level diff or a bare
# element count: each entry with the fields the issue itself names as
# legitimate metadata churn (updatedDate, title, feeds) stripped, then the
# SORTED set of what's left compared between base and head. Two entry sets
# are "the same listings" only if every core-identity object on one side has
# an exact match on the other -- which catches an outright add/remove (the
# set sizes differ), a same-count SWAP (one listing removed, a different one
# added -- a bare count check would miss this), AND an added entry that
# happens to omit addedDate entirely (a textual "did an addedDate line
# appear" check would miss this too -- both were igor#516 security review
# findings). Immune to reformatting/line-wrapping since nothing here reads
# the file as text.
#
# rejected.json's gained-guard-rejections check is likewise jq-structural
# over the whole tree (not a line count, which reformatting/minifying
# defeats -- same review).
#
# Reads every blob off the PINNED shas via `git show`, never a branch tip and
# never the working tree -- diffing branch names races a push landing between
# the PR read and the classification (same review). Fails CLOSED on any
# unreadable blob or unparseable JSON.
automerge_maintenance_tier_data_ok() {
  # `${6:-}` not `$6`: under `set -u` a 5-arg caller would abort the calling
  # shell -- i.e. kill the tick -- instead of returning 1. An omitted category
  # reads as "not declared" and falls through to the belt's fail-closed check
  # below, so the failure mode stays "refuse the merge", never "crash".
  local path="$1" base="$2" head="$3" data_file="$4" allowlist="$5" rejected_category="${6:-}"
  local old_sites new_sites old_core new_core old_rej new_rej old_rn new_rn

  old_sites=$(git -C "$path" show "${base}:${data_file}" 2>/dev/null) || return 1
  new_sites=$(git -C "$path" show "${head}:${data_file}" 2>/dev/null) || return 1
  jq -e 'type == "array"' <<<"$old_sites" >/dev/null 2>&1 || return 1
  jq -e 'type == "array"' <<<"$new_sites" >/dev/null 2>&1 || return 1
  old_core=$(jq -c '[.[] | del(.updatedDate, .title, .feeds)] | sort_by(tostring)' <<<"$old_sites" 2>/dev/null)
  new_core=$(jq -c '[.[] | del(.updatedDate, .title, .feeds)] | sort_by(tostring)' <<<"$new_sites" 2>/dev/null)
  [ -n "$old_core" ] && [ -n "$new_core" ] || return 1
  [ "$old_core" = "$new_core" ] || return 1

  if _automerge_maintenance_path_allowed "$AUTOMERGE_MAINTENANCE_REJECTED_FILE" "$allowlist"; then
    [ -n "$rejected_category" ] || return 1
    old_rej=$(git -C "$path" show "${base}:${AUTOMERGE_MAINTENANCE_REJECTED_FILE}" 2>/dev/null) || return 1
    new_rej=$(git -C "$path" show "${head}:${AUTOMERGE_MAINTENANCE_REJECTED_FILE}" 2>/dev/null) || return 1
    old_rn=$(jq -r --arg c "$rejected_category" '[.. | strings | select(. == $c)] | length' <<<"$old_rej" 2>/dev/null)
    new_rn=$(jq -r --arg c "$rejected_category" '[.. | strings | select(. == $c)] | length' <<<"$new_rej" 2>/dev/null)
    [ -n "$old_rn" ] && [ -n "$new_rn" ] || return 1
    [ "$new_rn" -le "$old_rn" ] 2>/dev/null || return 1
  fi
  return 0
}

# automerge_maintenance_tier_ok <repo> <pr> <pr_json> <head> <verdict>
# <reviewed_sha> -- exit 0 (echoing "files=N, +0 sites, -0 sites" for the log
# line) if this require_human PR qualifies for the maintenance-tier
# carve-out. ALL of:
#   - automerge_maintenance_declaration -- the repo's OWN dossier declares a
#     complete, valid automerge.maintenance (REQUIRED-AND-EXPLICIT opt-in;
#     igor#537 -- undeclared/partial repos never reach the checks below);
#   - the shadow review is the ONLY review signal on this path (there is no
#     human in the loop here), so it must be an affirmative APPROVE bound to
#     THIS exact head -- an absent/COMMENT/stale verdict never qualifies;
#   - the human hasn't lodged a live REQUEST_CHANGES -- the require_human pin
#     exists to give the human MORE authority, not less, so their veto still
#     applies exactly as it does on every other merge path (igor#516
#     amendment 2);
#   - automerge_maintenance_tier_branch_ok (same-repo <branch>->master);
#   - automerge_maintenance_tier_files_ok (the declared allowlist);
#   - automerge_maintenance_tier_data_ok (no listing added or removed in
#     the declared data_file).
# <pr_json> is the caller's own /pulls/<pr> fetch, reused here rather than
# re-fetched -- a second fetch would only widen the race between what gets
# classified and what gets merged.
automerge_maintenance_tier_ok() {
  local repo="$1" pr="$2" pr_json="$3" head="$4" verdict="$5" reviewed_sha="$6"
  local decl branch data_file allowlist rejected_category base_sha nfiles clone_path

  [ "$verdict" = "APPROVE" ] && [ "$reviewed_sha" = "$head" ] || return 1
  automerge_reviewer_blocks "$repo" "$pr" "${FORGEJO_REVIEWER:-}" && return 1

  decl=$(automerge_maintenance_declaration "$repo") || return 1
  branch=$(jq -r '.branch' <<<"$decl" 2>/dev/null)
  data_file=$(jq -r '.data_file' <<<"$decl" 2>/dev/null)
  allowlist=$(jq -c '.allowlist' <<<"$decl" 2>/dev/null)
  rejected_category=$(jq -r '.rejected_category // empty' <<<"$decl" 2>/dev/null)

  automerge_maintenance_tier_branch_ok "$pr_json" "$branch" || return 1
  base_sha=$(jq -r '.base.sha // ""' <<<"$pr_json" 2>/dev/null)
  [ -n "$base_sha" ] || return 1

  nfiles=$(automerge_maintenance_tier_files_ok "$repo" "$pr" "$allowlist") || return 1

  ensure_repo_local "$repo"
  clone_path=$(repo_path_for "$repo")
  automerge_maintenance_tier_data_ok "$clone_path" "$base_sha" "$head" "$data_file" "$allowlist" "$rejected_category" || return 1

  printf 'files=%s, +0 sites, -0 sites' "$nfiles"
}

# automerge_mergeable <repo> <pr> -- exit 0 if the PR is open AND cleanly mergeable.
automerge_mergeable() {
  local repo="$1" pr="$2"
  forgejo_get_pr "$repo" "$pr" 2>/dev/null \
    | jq -e '(.state == "open") and (.mergeable == true)' >/dev/null 2>&1
}

# automerge_do_merge <repo> <pr> -- merge the PR (merge commit). On success echoes
# the merge commit SHA and returns 0. On failure echoes the REASON ("HTTP <code>:
# <message>") and returns 1, so the caller can log WHY (permission, conflict, ...)
# and back off instead of re-POSTing a doomed merge every tick (igor#322).
automerge_do_merge() {
  local repo="$1" pr="$2" res code msg
  res=$(forgejo_merge_pr "$repo" "$pr")
  code=${res%%$'\t'*}; msg=${res#*$'\t'}
  case "$code" in
    2??) forgejo_get_pr "$repo" "$pr" 2>/dev/null | jq -r '.merge_commit_sha // empty'; return 0 ;;
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
  obj=$(forgejo_get_pr "$repo" "$pr" 2>/dev/null) || { echo -1; return; }
  head=$(jq -r '.head.sha // empty' <<<"$obj"); base=$(jq -r '.base.ref // empty' <<<"$obj")
  if [ -z "$head" ] || [ -z "$base" ]; then echo -1; return; fi
  cmp=$(forgejo_compare "$repo" "$head" "$base" 2>/dev/null) || { echo -1; return; }
  jq -r 'if type == "object" then (.total_commits // (.commits | length) // 0) else -1 end' <<<"$cmp" 2>/dev/null || echo -1
}

# automerge_update_branch <repo> <pr> -- merge the base branch into the PR head
# (Forgejo "update branch") so a behind PR satisfies require-up-to-date. The
# human's APPROVAL survives this base-merge (verified live on a real repo), and
# the shadow review's patch-id dedup treats the base-merge as an already-seen net
# diff, so it isn't re-reviewed. rc 0 on success.
automerge_update_branch() {
  local repo="$1" pr="$2"
  forgejo_pr_update_branch "$repo" "$pr"
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
  local pr_json maint_class
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
      # Fetch the PR object up front: the default path binds the shadow APPROVE
      # to head.sha (below), the CI check needs it, and the maintenance tier
      # (below) reuses this SAME fetch for its branch/base checks rather than
      # re-fetching (a second fetch would only widen the classify-vs-merge race).
      pr_json=$(forgejo_get_pr "$repo" "$pr" 2>/dev/null)
      head=$(jq -r '.head.sha // ""' <<<"$pr_json" 2>/dev/null)
      [ -n "$head" ] || continue
      verdict=$(jq -r --arg k "$key" '.review[$k].verdict // ""' "$sf" 2>/dev/null)
      reviewed_sha=$(jq -r --arg k "$key" '.review[$k].sha // ""' "$sf" 2>/dev/null)
      # Approval gate. A flagged repo needs the HUMAN reviewer's live APPROVED
      # review (today's behavior). A default repo merges on the SHADOW review's
      # affirmative APPROVE -- APPROVE only, never COMMENT. On BOTH paths a live
      # REQUEST_CHANGES vetoes: the shadow's on the human path, the human's on the
      # default path -- we never merge over a "no".
      if [ "$req_human" = "1" ]; then
        # Maintenance-tier carve-out (igor#516; agnostic per igor#537): the
        # repo pin is now "any repo whose OWN dossier declares
        # automerge.maintenance" -- automerge_maintenance_tier_ok's first
        # check is automerge_maintenance_declaration, which fails closed
        # (tier off) on anything missing/partial/dossier-touching, so a
        # classifier bug can at worst mis-gate a repo that opted itself in,
        # never widen the bypass to a repo that never declared the tier.
        maint_class=$(automerge_maintenance_tier_ok "$repo" "$pr" "$pr_json" "$head" "$verdict" "$reviewed_sha") || true
        if [ -n "$maint_class" ]; then
          log "automerge: ${key} maintenance-tier (${maint_class}) -- merging without human gate"
        else
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
            # igor#512, genericized igor#538: a url-less repo whose dossier
            # declares a `landed-kind` gets a host-state landed-watch instead
            # of a deploy/smoke watch -- see lib/landed.sh.
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
