#!/usr/bin/env bash
# landed.sh -- host-state "landed" verification for the two URL-less
# auto-merge repos (igor#512): igor itself, and the distillery -- the pair
# whose merge path igor#520 made human-gated for want of a URL. Companion to
# the deploy barrier (lib/automerge.sh) for repos with no live URL to
# smoke-test -- "landed" here is a HOST-STATE assertion instead of an HTTP
# one. Sourced by bin/tick.sh.
#
# Two hardcoded checks, no config knob (deliberately -- igor#512, "two
# special cases, no config knob"):
#   igor:        the live install's self-pull has reached the merged sha --
#                `git -C $AGENT_HOME rev-parse HEAD` equals or descends from
#                it (landed_assert_igor, an ancestor check so a LATER merge
#                also counts as "landed").
#   distillery:  the served prompt-context cache has swapped to the merged
#                sha -- lib/context-source.sh's generation marker
#                ($CONTEXT_CACHE_DIR/current/HEAD) equals it exactly
#                (landed_assert_distillery). This catches a real silent
#                failure: context_refresh is all-or-nothing and REFUSES to
#                swap a malformed/too-thin skill, logging once -- a merged
#                directive can land at master but never go live in the
#                served cache (observed igor#512: distillery#4 merged at
#                master 56b5ea5 while the cache kept serving an older
#                generation until the next VALID refresh).
#
# Mechanics mirror lib/automerge.sh's `.deploy` pending-watch: a merge on a
# hardcoded repo stamps a pending entry under `.landed` in
# discretionary-state.json (do_automerge_tick, via landed_record); every
# tick (do_landed_tick, called near the top of the cascade, non-model) then
# re-checks each pending entry's host-state assertion. Landed -> clear +
# queue a ship-report note (drained by lib/ship-report.sh's
# shipreport_landed_read/shipreport_landed_clear, behind its usual
# creds/hour/sent-today gates). Not landed after LANDED_GRACE_TICKS ticks ->
# email ALERT_RECIPIENTS with repo/merged-sha/observed-state, then clear --
# a stuck watch doesn't nag forever; the merge itself already happened, this
# is a post-hoc confirmation, not a gate.
#
# Deliberately does NOT end the tick while waiting (unlike the deploy
# barrier): nothing here is disrupted by concurrent work running in
# parallel, so there's no reason to hold the tick open on it.
#
# Honest scope limit: this checker runs INSIDE the tick, so it cannot catch
# a merge that bricks tick.sh itself (e.g. a self-merge that breaks bash
# syntax) -- that class is covered by the existing external task-heartbeat
# ("didn't ping") alerting. This catches the SOFT failures instead: a
# self-pull that's silently failing, or a swap the distillery cache
# refuses. Layering: heartbeat = hard bricks; this = soft ones.

# Fallback stubs so this module is sourceable standalone (tests).
if ! declare -F log >/dev/null; then log() { printf '[agent] %s\n' "$*" >&2; }; fi
if ! declare -F recipients_with_primary >/dev/null; then
  recipients_with_primary() { printf '%s' "${PRIMARY_RECIPIENTS:-}"; }
fi
if ! declare -F email_send >/dev/null; then email_send() { return 1; }; fi
if ! declare -F forgejo_comment >/dev/null; then forgejo_comment() { return 0; }; fi

LANDED_DISTILLERY_REPO="${LANDED_DISTILLERY_REPO:-joshtronic/distillery}"
LANDED_GRACE_TICKS=10   # ~10 ticks of grace before a stuck watch alerts

_landed_state_file() { echo "${AGENT_STATE_DIR:-$HOME/.local/state/agent}/discretionary-state.json"; }

# landed_kind <repo> -- echoes "igor" or "distillery" and returns 0 if this
# repo is one of the two hardcoded URL-less repos this checker knows how to
# verify; returns 1 (echoing nothing) otherwise. AUTOMERGE_SELF_REPO is read
# with the same inline default lib/automerge.sh uses, rather than depending
# on that module's own assignment having already run -- this module must
# stay independently sourceable.
landed_kind() {
  local repo="$1"
  if [ "$repo" = "${AUTOMERGE_SELF_REPO:-joshtronic/igor}" ]; then
    printf 'igor'; return 0
  fi
  if [ "$repo" = "$LANDED_DISTILLERY_REPO" ]; then
    printf 'distillery'; return 0
  fi
  return 1
}

# landed_applies <repo> -- exit 0 if landed_kind recognizes this repo.
landed_applies() { landed_kind "$1" >/dev/null 2>&1; }

# landed_record <repo> <pr> <sha> -- stamp a pending landed-watch, keyed by
# repo full_name. A second merge on the same repo before the first watch
# clears just overwrites it with the newer sha and resets attempts to 0 --
# the newer merge implies the older one (a self-pull/cache-swap that reaches
# the newer sha necessarily passed through, or superseded, the older one).
landed_record() {
  local repo="$1" pr="$2" sha="$3" sf tmp
  sf=$(_landed_state_file); [ -f "$sf" ] || echo '{}' > "$sf"
  tmp=$(mktemp)
  if jq --arg r "$repo" --arg p "$pr" --arg s "$sha" \
    '.landed[$r] = {pr:$p, sha:$s, attempts:0}' "$sf" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$sf"
  else
    rm -f "$tmp"
  fi
}

# landed_clear <repo> -- drop the pending watch for this repo.
landed_clear() {
  local repo="$1" sf tmp
  sf=$(_landed_state_file); [ -f "$sf" ] || return 0
  tmp=$(mktemp)
  if jq --arg r "$repo" 'if (.landed|type) == "object" then .landed |= del(.[$r]) else . end' "$sf" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$sf"
  else
    rm -f "$tmp"
  fi
}

# landed_pending_repos -- newline-separated repo keys with a pending watch.
landed_pending_repos() {
  local sf; sf=$(_landed_state_file); [ -f "$sf" ] || return 0
  jq -r '.landed // {} | keys[]' "$sf" 2>/dev/null
}

# landed_pending_entry <repo> -- echoes the pending watch's JSON
# ({pr,sha,attempts}), or "{}" if there is none.
landed_pending_entry() {
  local repo="$1" sf
  sf=$(_landed_state_file); [ -f "$sf" ] || { printf '{}'; return 0; }
  jq -c --arg r "$repo" '.landed[$r] // {}' "$sf" 2>/dev/null || printf '{}'
}

# landed_attempts_set <repo> <n> -- record another failed check.
landed_attempts_set() {
  local repo="$1" n="$2" sf tmp
  sf=$(_landed_state_file); [ -f "$sf" ] || return 0
  tmp=$(mktemp)
  if jq --arg r "$repo" --argjson n "$n" '.landed[$r].attempts = $n' "$sf" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$sf"
  else
    rm -f "$tmp"
  fi
}

# landed_note_queue <repo> <pr> <sha> <detail> -- queue a ship-report note
# for a confirmed landing. Drained (read + cleared) by lib/ship-report.sh's
# do_shipreport_tick, behind its usual creds/hour/sent-today gates -- so a
# landing confirmed at 3am rides the normal 07:00 morning send rather than
# triggering anything of its own.
landed_note_queue() {
  local repo="$1" pr="$2" sha="$3" detail="$4" sf tmp
  sf=$(_landed_state_file); [ -f "$sf" ] || echo '{}' > "$sf"
  tmp=$(mktemp)
  if jq --arg r "$repo" --arg p "$pr" --arg s "$sha" --arg d "$detail" \
    '.landed_notes = ((.landed_notes // []) + [{repo:$r, pr:$p, sha:$s, detail:$d}])' "$sf" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$sf"
  else
    rm -f "$tmp"
  fi
}

# landed_assert_igor <sha> [repo-path] -- exit 0 if the live install's HEAD
# equals or descends from <sha> (the self-pull at the very top of every
# tick keeps it moving forward -- an ancestor check, not exact equality, so
# a LATER merge still counts as this one having landed). repo-path defaults
# to AGENT_HOME; tests point it at a fixture repo.
landed_assert_igor() {
  local sha="$1" path="${2:-${AGENT_HOME:-}}"
  [ -n "$path" ] && [ -n "$sha" ] || return 1
  git -C "$path" merge-base --is-ancestor "$sha" HEAD 2>/dev/null
}

# landed_igor_observed [repo-path] -- the live install's current HEAD sha,
# for logging/alerting.
# shellcheck disable=SC2120  # do_landed_tick calls it bare; tests pass a fixture path
landed_igor_observed() {
  local path="${1:-${AGENT_HOME:-}}"
  [ -n "$path" ] || return 0
  git -C "$path" rev-parse HEAD 2>/dev/null
}

# landed_assert_distillery <sha> [cache-dir] -- exit 0 if the served context
# cache's generation marker equals <sha> exactly. context_refresh's swap is
# all-or-nothing and jumps straight to origin/master's HEAD (see
# lib/context-source.sh), so once a valid refresh happens the marker IS the
# merged sha -- there is no partial-progress state to treat as "descends
# from" the way the self-pull's is. cache-dir defaults to CONTEXT_CACHE_DIR
# (same default lib/context-source.sh uses); tests point it at a fixture.
landed_assert_distillery() {
  local sha="$1" observed
  [ -n "$sha" ] || return 1
  observed=$(landed_distillery_observed "${2:-}")
  [ -n "$observed" ] && [ "$observed" = "$sha" ]
}

# landed_distillery_observed [cache-dir] -- the served context cache's
# generation marker, or empty if the cache has never been seeded.
landed_distillery_observed() {
  local cache_dir="${1:-${CONTEXT_CACHE_DIR:-${AGENT_STATE_DIR:-$HOME/.local/state/agent}/context}}"
  cat "${cache_dir}/current/HEAD" 2>/dev/null
}

# _landed_alert <repo> <pr> <sha> <observed> <kind> -- email
# ALERT_RECIPIENTS (+ PRIMARY) and comment on the merged PR: the grace
# window expired without the host-state assertion passing.
_landed_alert() {
  local repo="$1" pr="$2" sha="$3" observed="$4" kind="$5" what recipients subject body
  case "$kind" in
    igor)       what="the live install's self-pull (git HEAD)" ;;
    distillery) what="the served context-cache generation marker" ;;
    *)          what="the landed-verification check" ;;
  esac
  log "landed: ALERT ${repo}#${pr} merged ${sha:0:8} but ${what} still shows ${observed:-none} after ${LANDED_GRACE_TICKS} ticks"
  forgejo_comment "$repo" "$pr" \
    "⚠️ **Merge landed but did not verify.** ${what} still shows \`${observed:-none}\`, not the merged commit \`${sha:0:8}\`, after ${LANDED_GRACE_TICKS} ticks. No auto-revert -- needs eyes." \
    2>/dev/null || true
  recipients=$(recipients_with_primary "${ALERT_RECIPIENTS:-}")
  [ -n "$recipients" ] && [ -n "${SMTP2GO_API_KEY:-}" ] && [ -n "${SMTP2GO_SENDER:-}" ] || return 0
  subject="[Agent] Landed-verification failed: ${repo}#${pr}"
  body="Merged ${repo}#${pr} to master (merge commit ${sha}), but ${what} has not
caught up after ${LANDED_GRACE_TICKS} ticks.

Observed: ${observed:-none}
Expected: ${sha}

This checker runs inside the tick, so it cannot catch a merge that bricks
tick.sh itself -- that class is covered by the external task-heartbeat
alert. What it DOES catch is a soft failure: a self-pull silently failing,
or (for distillery) a context-cache swap being refused because the merged
skill is malformed or too thin (context_refresh is all-or-nothing).

Eyes on it."
  if email_send "$subject" "<pre>${body}</pre>" "$body" "$recipients"; then
    log "landed: alert emailed to ${recipients}"
  else
    log "warning: landed: alert email failed"
  fi
}

# do_landed_tick -- re-check every pending landed-watch's host-state
# assertion. Landed -> clear + queue a ship-report note. Not landed and
# still within grace -> bump the attempt counter. Grace exceeded -> alert +
# clear. Never ends the tick (always returns 0) -- call as
# `do_landed_tick || true`.
do_landed_tick() {
  local repo entry kind pr sha attempts observed detail
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    if ! kind=$(landed_kind "$repo"); then
      # A pending entry for a repo this module no longer recognizes (e.g.
      # LANDED_DISTILLERY_REPO changed) -- nothing to check; drop it.
      landed_clear "$repo"
      continue
    fi
    entry=$(landed_pending_entry "$repo")
    pr=$(jq -r '.pr // ""' <<<"$entry" 2>/dev/null)
    sha=$(jq -r '.sha // ""' <<<"$entry" 2>/dev/null)
    attempts=$(jq -r '.attempts // 0' <<<"$entry" 2>/dev/null)
    [ -n "$sha" ] || { landed_clear "$repo"; continue; }
    [ -n "$attempts" ] || attempts=0
    # Reset per iteration rather than `unset`ing on the landed path -- `unset`
    # would drop the `local` binding and expose any global of the same name.
    detail=""

    case "$kind" in
      igor)
        observed=$(landed_igor_observed)
        if landed_assert_igor "$sha"; then
          detail="self-pull HEAD is ${observed:0:8}"
        fi
        ;;
      distillery)
        observed=$(landed_distillery_observed)
        if landed_assert_distillery "$sha"; then
          detail="context-cache generation is ${observed:0:8}"
        fi
        ;;
    esac

    if [ -n "$detail" ]; then
      log "landed: ${repo}#${pr} ${sha:0:8} confirmed landed (${detail})"
      landed_note_queue "$repo" "$pr" "$sha" "$detail"
      landed_clear "$repo"
      continue
    fi

    attempts=$((attempts + 1))
    if [ "$attempts" -ge "$LANDED_GRACE_TICKS" ]; then
      _landed_alert "$repo" "$pr" "$sha" "$observed" "$kind"
      landed_clear "$repo"
    else
      landed_attempts_set "$repo" "$attempts"
      log "landed: ${repo}#${pr} ${sha:0:8} not yet landed (observed ${observed:-none}) -- ${attempts}/${LANDED_GRACE_TICKS}"
    fi
  done < <(landed_pending_repos)
  return 0
}
