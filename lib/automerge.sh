#!/usr/bin/env bash
# automerge.sh -- auto-merge-on-approve + the deploy barrier. Sourced by bin/tick.sh.
#
# "After you approve, your job ends." A repo opts in by CONVENTION: a root
# agent.json (AGENT_CONFIG_FILE) carrying a `.smoke.url` marks it
# auto-merge-eligible -- agent.json is the shared per-repo machine-config dossier
# (each feature reads its own key). The
# harness merges a bot PR ONLY when the human (FORGEJO_REVIEWER) has submitted an
# APPROVED review, CI is green on the head, it is cleanly mergeable, and the
# shadow verdict is not REQUEST_CHANGES. On merge it stamps a pending deploy
# under .deploy in discretionary-state.
#
# The deploy barrier (do_deploy_barrier, run EARLY each tick) then watches that
# deploy to verified-healthy -- CI green + the live URL responds -- and ENDS the
# tick each minute while it is still deploying, so no long work starts mid-deploy
# (the 1-minute cadence IS the polling loop; the tick is never held open). On a
# failed deploy/smoke it emails ALERT_RECIPIENTS. Phase 1 is alert-only: NO
# automatic revert.
#
# NEVER the harness's own repo: a watcher can't reliably watch itself (a broken
# self-deploy could crash the very tick meant to smoke-test it), so igor stays a
# manual merge. No-ops cleanly when no repo opts in.

AGENT_CONFIG_FILE="agent.json"                               # repo root; per-repo machine-config dossier (jq-parsed)
AUTOMERGE_SMOKE_MAX_ATTEMPTS=5                                # propagation grace before a smoke alert
AUTOMERGE_CI_MAX_ATTEMPTS=30                                  # ~30 ticks before a never-reporting deploy CI self-heals
AUTOMERGE_SELF_REPO="${AUTOMERGE_SELF_REPO:-joshtronic/igor}" # never auto-merge the harness
AUTOMERGE_BLOCK_COOLDOWN_SECS=3600                            # after a rejected merge, back off ~1h before re-trying the same head

# Fallback logger so this module is sourceable standalone (tests).
if ! declare -F log >/dev/null; then log() { printf '[agent] %s\n' "$*"; }; fi

_deploy_state_file() { echo "${AGENT_STATE_DIR:-$HOME/.local/state/agent}/discretionary-state.json"; }

# automerge_smoke_url <repo> -- the live URL from the repo's agent.json
# `.smoke.url`, or empty: not eligible (no agent.json / no .smoke.url), or the
# harness's own repo.
automerge_smoke_url() {
  local repo="$1"
  [ "$repo" = "$AUTOMERGE_SELF_REPO" ] && return 0
  forgejo_repo_get_file "$repo" "$AGENT_CONFIG_FILE" 2>/dev/null \
    | jq -r '.smoke.url // empty' 2>/dev/null || true
}

# automerge_require_human <repo> -- exit 0 if the repo pins itself to a HUMAN
# review gate (`agent.json` `.automerge.require_human == true`); exit 1 otherwise
# (the default -- the shadow review's APPROVE gates the merge). The carve-out for
# repos whose real defect class a diff review can't judge (joshing.you, igor.bot,
# porksicle.com). igor is already excluded upstream by automerge_smoke_url.
automerge_require_human() {
  local repo="$1"
  [ "$(forgejo_repo_get_file "$repo" "$AGENT_CONFIG_FILE" 2>/dev/null \
        | jq -r '.automerge.require_human // false' 2>/dev/null)" = "true" ]
}

# automerge_approved_by <repo> <pr> <user> -- exit 0 if <user>'s CURRENT review
# on the PR is an APPROVED (the human green-light). NOT "ever approved": Forgejo
# keeps the full review history, so an old APPROVED followed by a later
# REQUEST_CHANGES must NOT count as approval. We key on the user's LATEST
# decision review (APPROVED / REQUEST_CHANGES -- a COMMENT review never changes
# the verdict) and trust Forgejo's own `stale`/`dismissed` flags, the same way
# the REQUEST_CHANGES pickup in tick.sh does. A dismissed review is dropped (it
# was explicitly withdrawn); a stale APPROVED does not merge (the head moved past
# what the human looked at). So a walked-back approval can never auto-merge.
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
        | (. != null) and (.state == "APPROVED") and ((.stale // false) == false)
      ' >/dev/null 2>&1
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
  # <state-file> <key> -- drop the block (on a successful merge).
  local sf="$1" key="$2" tmp
  [ -f "$sf" ] || return 0
  tmp=$(mktemp)
  if jq --arg k "$key" 'if .automerge_block then .automerge_block |= del(.[$k]) else . end' "$sf" >"$tmp" 2>/dev/null; then
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

# do_automerge_tick -- merge ONE human-approved bot PR on an auto-merge-eligible
# repo, stamping a pending deploy for the barrier. Returns 0 if it merged.
do_automerge_tick() {
  [ -n "${FORGEJO_REVIEWER:-}" ] || return 1
  local sf; sf=$(_deploy_state_file)
  # one deploy at a time (the barrier guards this too, but belt + suspenders)
  [ -f "$sf" ] && [ -n "$(jq -r '.deploy.repo // ""' "$sf" 2>/dev/null)" ] && return 1

  local repo url req_human prs pr head verdict key ci sha behind
  local behind_repo="" behind_pr="" behind_n=""
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    url=$(automerge_smoke_url "$repo"); [ -n "$url" ] || continue   # not eligible
    if automerge_require_human "$repo"; then req_human=1; else req_human=0; fi
    prs=$(forgejo_list_open_bot_prs "$repo" "$BOT_USER" 2>/dev/null) || continue
    while IFS= read -r pr; do
      if [ -z "$pr" ] || [ "$pr" = "null" ]; then continue; fi
      key="${repo}#${pr}"
      verdict=$(jq -r --arg k "$key" '.review[$k].verdict // ""' "$sf" 2>/dev/null)
      # Approval gate. A flagged repo needs the HUMAN reviewer's live APPROVED
      # review (today's behavior). A default repo merges on the SHADOW review's
      # affirmative APPROVE -- APPROVE only, never COMMENT. On BOTH paths a live
      # REQUEST_CHANGES vetoes: the shadow's on the human path, the human's on the
      # default path -- we never merge over a "no".
      if [ "$req_human" = "1" ]; then
        automerge_approved_by "$repo" "$pr" "$FORGEJO_REVIEWER" || continue
        if [ "$verdict" = "REQUEST_CHANGES" ]; then
          log "automerge: ${key} human-approved but shadow verdict is REQUEST_CHANGES -- not merging"; continue
        fi
      else
        if [ "$verdict" != "APPROVE" ]; then
          log "automerge: ${key} no shadow APPROVE (verdict='${verdict:-none}') -- routes to human, not auto-merging"; continue
        fi
        if automerge_reviewer_blocks "$repo" "$pr" "$FORGEJO_REVIEWER"; then
          log "automerge: ${key} shadow-APPROVE but ${FORGEJO_REVIEWER} requested changes -- not merging"; continue
        fi
      fi
      head=$(_fj GET "/repos/${repo}/pulls/${pr}" 2>/dev/null | jq -r '.head.sha // ""')
      [ -n "$head" ] || continue
      ci=$(forgejo_commit_status "$repo" "$head")
      if [ "$ci" != "success" ]; then
        log "automerge: ${key} CI=${ci:-unknown} -- not merging"; continue
      fi
      automerge_mergeable "$repo" "$pr" || { log "automerge: ${key} not cleanly mergeable -- skipping"; continue; }
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
          _deploy_record "$repo" "$pr" "$sha" "$url"
          log "automerge: merged ${key} (approved by ${FORGEJO_REVIEWER}, CI green) -- watching deploy ${sha:0:8}"
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
