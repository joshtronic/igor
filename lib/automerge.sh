#!/usr/bin/env bash
# automerge.sh -- auto-merge-on-approve + the deploy barrier. Sourced by bin/tick.sh.
#
# "After you approve, your job ends." A repo opts in by CONVENTION: a root
# AUTOMERGE_SMOKE_FILE holding its live URL marks it auto-merge-eligible. The
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

AUTOMERGE_SMOKE_FILE="smoke-url"                              # repo root; presence = eligible
AUTOMERGE_SMOKE_MAX_ATTEMPTS=5                                # propagation grace before a smoke alert
AUTOMERGE_CI_MAX_ATTEMPTS=30                                  # ~30 ticks before a never-reporting deploy CI self-heals
AUTOMERGE_SELF_REPO="${AUTOMERGE_SELF_REPO:-joshtronic/igor}" # never auto-merge the harness

# Fallback logger so this module is sourceable standalone (tests).
if ! declare -F log >/dev/null; then log() { printf '[agent] %s\n' "$*"; }; fi

_deploy_state_file() { echo "${AGENT_STATE_DIR:-$HOME/.local/state/agent}/discretionary-state.json"; }

# automerge_smoke_url <repo> -- the live URL declared in the repo's smoke-url
# file (first http(s) token), or empty: not eligible, or the harness's own repo.
automerge_smoke_url() {
  local repo="$1"
  [ "$repo" = "$AUTOMERGE_SELF_REPO" ] && return 0
  forgejo_repo_get_file "$repo" "$AUTOMERGE_SMOKE_FILE" 2>/dev/null \
    | grep -m1 -oE 'https?://[^[:space:]]+' || true
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

# automerge_mergeable <repo> <pr> -- exit 0 if the PR is open AND cleanly mergeable.
automerge_mergeable() {
  local repo="$1" pr="$2"
  _fj GET "/repos/${repo}/pulls/${pr}" 2>/dev/null \
    | jq -e '(.state == "open") and (.mergeable == true)' >/dev/null 2>&1
}

# automerge_do_merge <repo> <pr> -- merge the PR (merge commit). Echoes the merge
# commit SHA on success; empty + nonzero on a failed merge API call.
automerge_do_merge() {
  local repo="$1" pr="$2"
  _fj POST "/repos/${repo}/pulls/${pr}/merge" '{"Do":"merge"}' >/dev/null 2>&1 || return 1
  _fj GET "/repos/${repo}/pulls/${pr}" 2>/dev/null | jq -r '.merge_commit_sha // empty'
}

# automerge_smoke <url> -- exit 0 if the live URL responds 2xx/3xx.
automerge_smoke() {
  local url="$1" code
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -L "$url" 2>/dev/null || echo 000)
  case "$code" in 2??|3??) return 0 ;; *) return 1 ;; esac
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
  email_send "$subject" "<pre>${body}</pre>" "$body" "$recipients" \
    && log "deploy: alert emailed to ${recipients}" \
    || log "warning: deploy: alert email failed"
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

  if automerge_smoke "$url"; then
    log "deploy: ${repo}#${pr} verified healthy (CI green, ${url} responds) -- resuming work"
    _deploy_clear; return 1
  fi
  attempts=$((attempts + 1))
  if [ "$attempts" -ge "$AUTOMERGE_SMOKE_MAX_ATTEMPTS" ]; then
    _deploy_alert "$repo" "$pr" "$sha" "$url" "CI green but ${url} did not respond after ${attempts} checks"
    _deploy_clear; return 1
  fi
  tmp=$(mktemp); jq --argjson a "$attempts" '.deploy.smoke_attempts = $a' "$sf" > "$tmp" && mv "$tmp" "$sf"
  log "deploy: ${repo}#${pr} CI green but ${url} not live yet (${attempts}/${AUTOMERGE_SMOKE_MAX_ATTEMPTS}) -- ending tick"
  return 0
}

# do_automerge_tick -- merge ONE human-approved bot PR on an auto-merge-eligible
# repo, stamping a pending deploy for the barrier. Returns 0 if it merged.
do_automerge_tick() {
  [ -n "${FORGEJO_REVIEWER:-}" ] || return 1
  local sf; sf=$(_deploy_state_file)
  # one deploy at a time (the barrier guards this too, but belt + suspenders)
  [ -f "$sf" ] && [ -n "$(jq -r '.deploy.repo // ""' "$sf" 2>/dev/null)" ] && return 1

  local repo url prs pr head verdict key ci sha
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    url=$(automerge_smoke_url "$repo"); [ -n "$url" ] || continue   # not eligible
    prs=$(forgejo_list_open_bot_prs "$repo" "$BOT_USER" 2>/dev/null) || continue
    while IFS= read -r pr; do
      [ -n "$pr" ] && [ "$pr" != "null" ] || continue
      automerge_approved_by "$repo" "$pr" "$FORGEJO_REVIEWER" || continue
      key="${repo}#${pr}"
      verdict=$(jq -r --arg k "$key" '.review[$k].verdict // ""' "$sf" 2>/dev/null)
      if [ "$verdict" = "REQUEST_CHANGES" ]; then
        log "automerge: ${key} approved but shadow verdict is REQUEST_CHANGES -- not merging"; continue
      fi
      head=$(_fj GET "/repos/${repo}/pulls/${pr}" 2>/dev/null | jq -r '.head.sha // ""')
      [ -n "$head" ] || continue
      ci=$(forgejo_commit_status "$repo" "$head")
      if [ "$ci" != "success" ]; then
        log "automerge: ${key} CI=${ci:-unknown} -- not merging"; continue
      fi
      automerge_mergeable "$repo" "$pr" || { log "automerge: ${key} not cleanly mergeable -- skipping"; continue; }
      sha=$(automerge_do_merge "$repo" "$pr") || { log "warning: automerge: merge API failed on ${key}"; continue; }
      [ -n "$sha" ] || sha="$head"   # fall back to the head if the merge SHA didn't come back
      _deploy_record "$repo" "$pr" "$sha" "$url"
      log "automerge: merged ${key} (approved by ${FORGEJO_REVIEWER}, CI green) -- watching deploy ${sha:0:8}"
      return 0
    done < <(jq -r '.[]?.number // empty' <<<"$prs")
    # VALIDATED_REPOS_JSON is a NEWLINE-DELIMITED STREAM of repo objects (one per
    # line), NOT a JSON array -- built that way in tick.sh and consumed the same
    # way by maintenance_repo_validated. So `.full_name` runs per object; `.[]?`
    # would error ("Cannot index string") on a stream. Multi-repo iteration is
    # covered by test-automerge.sh.
  done < <(printf '%s' "${VALIDATED_REPOS_JSON:-}" | jq -r '.full_name // empty' 2>/dev/null)
  return 1
}
