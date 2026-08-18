#!/usr/bin/env bash
# landed.sh -- host-state "landed" verification for url-less auto-merge
# repos (igor#512, genericized igor#538). Companion to the deploy barrier
# (lib/automerge.sh) for repos with no live URL to smoke-test -- "landed"
# here is a HOST-STATE assertion instead of an HTTP one. Sourced by
# bin/tick.sh.
#
# This module is a DISPATCHER over declared `landed-kind` dossier values
# (docs/agents-md-spec.md; root AGENTS.md Metadata, or legacy agent.json
# `.landed.kind`) -- the repo -> kind binding lives in each repo's own
# dossier, not here. Two kinds are implemented (LANDED_KINDS below):
#   self-pull:      the live install's self-pull has reached the merged sha
#                    -- `git -C $AGENT_HOME rev-parse HEAD` equals or
#                    descends from it (landed_assert_self_pull, an ancestor
#                    check so a LATER merge also counts as "landed"). igor
#                    declares this kind on itself.
#   context-cache:   the served prompt-context cache has swapped to the
#                    merged sha -- lib/context-source.sh's generation marker
#                    ($CONTEXT_CACHE_DIR/current/HEAD) equals it exactly
#                    (landed_assert_context_cache). This catches a real
#                    silent failure: context_refresh is all-or-nothing and
#                    REFUSES to swap a malformed/too-thin skill, logging
#                    once -- a merged directive can land at master but never
#                    go live in the served cache (observed igor#512:
#                    distillery#4 merged at master 56b5ea5 while the cache
#                    kept serving an older generation until the next VALID
#                    refresh). The distillery declares this kind on itself.
#
# A repo that declares no `landed-kind` gets no watch -- quiet, exactly like
# any other repo this module doesn't know about. A repo that declares a
# value outside LANDED_KINDS also gets no watch, but LOUDLY: one log line,
# never a silent default (the operator's standing rule).
#
# Mechanics mirror lib/automerge.sh's `.deploy` pending-watch: a merge on a
# kind-declaring repo stamps a pending entry under `.landed` in
# discretionary-state.json (do_automerge_tick, via landed_record); every
# tick (do_landed_tick, called near the top of the cascade, non-model) then
# re-checks each pending entry's host-state assertion. The kind is resolved
# ONCE, at record time, and persisted on the entry -- the tick loop never
# re-reads the dossier, so a Forgejo blip can't turn a pending watch into a
# dropped one. Landed -> clear +
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
# self-pull that's silently failing, or a swap the context-cache kind
# refuses. Layering: heartbeat = hard bricks; this = soft ones.

# Fallback stubs so this module is sourceable standalone (tests).
if ! declare -F log >/dev/null; then log() { printf '[agent] %s\n' "$*" >&2; }; fi
if ! declare -F recipients_with_primary >/dev/null; then
  recipients_with_primary() { printf '%s' "${PRIMARY_RECIPIENTS:-}"; }
fi
if ! declare -F email_send >/dev/null; then email_send() { return 1; }; fi
if ! declare -F forgejo_comment >/dev/null; then forgejo_comment() { return 0; }; fi

# LANDED_KINDS -- the closed vocabulary of `landed-kind` dossier values this
# module knows how to verify (docs/agents-md-spec.md). Any other declared
# value is unrecognized.
LANDED_KINDS="self-pull context-cache"
LANDED_GRACE_TICKS=10   # ~10 ticks of grace before a stuck watch alerts

_landed_state_file() { echo "${AGENT_STATE_DIR:-$HOME/.local/state/agent}/discretionary-state.json"; }

# landed_kind <repo> -- echoes the repo's declared `landed-kind` dossier
# value ("self-pull" or "context-cache"). Three-way return, because "this
# repo declares no kind" and "Forgejo wouldn't tell us this tick" are
# different answers and a caller holding a pending watch must not conflate
# them:
#   0 -- a recognized kind, echoed on stdout.
#   1 -- no watch. The repo declares no landed-kind at all (quiet -- same as
#        any other repo this module doesn't watch), or declares a value
#        outside LANDED_KINDS (loud -- one log line, never a silent default,
#        the operator's standing rule), or lib/dossier.sh was never sourced
#        (a code defect, not a transient one: retrying can't fix it).
#   2 -- unknown: the dossier read itself failed transport-wise this tick.
#        NOT "absent" -- treating it as absent would drop a pending watch on
#        a Forgejo blip, handing the module whose whole purpose is catching
#        silent failures a silent failure of its own (igor#538 review).
# Reads through dossier_get_repo_status rather than dossier_get_repo for
# exactly that distinction: dossier_get_repo collapses a blip and a real 404
# into the same empty string. Needs lib/dossier.sh sourced -- bin/tick.sh
# sources it above landed.sh; bin/test-landed.sh mirrors that.
landed_kind() {
  local repo="$1" out status kind
  if ! declare -F dossier_get_repo_status >/dev/null; then
    log "landed: BUG -- lib/dossier.sh not sourced; landed-kind unreadable"
    return 1
  fi
  out=$(dossier_get_repo_status "$repo" landed-kind 2>/dev/null) || return 2
  status=${out%%$'\t'*}; kind=${out#*$'\t'}
  [ "$status" = "ok" ] || return 2
  [ -n "$kind" ] || return 1
  case " $LANDED_KINDS " in
    *" $kind "*) printf '%s' "$kind"; return 0 ;;
  esac
  log "landed: ${repo} declares unrecognized landed-kind '${kind}' -- no watch"
  return 1
}

# landed_applies <repo> -- exit 0 if a merge on this repo should stamp a
# landed-watch: a recognized kind, or a kind that couldn't be READ this tick.
# The unknown case stamps a watch carrying an empty kind, which do_landed_tick
# resolves on a later tick -- so a Forgejo blip at merge time defers the
# decision instead of losing the watch outright. A repo that genuinely
# declares nothing still gets no watch.
landed_applies() {
  local rc=0
  landed_kind "$1" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 1 ]
}

# landed_record <repo> <pr> <sha> -- stamp a pending landed-watch, keyed by
# repo full_name, with the repo's landed-kind resolved HERE and persisted on
# the entry. do_landed_tick reads that kind back out of state instead of
# re-querying the dossier every tick: the watch then survives a Forgejo blip
# (which a per-tick re-query would read as "no longer a watched repo"), and
# the tick loop sheds a network call. An unreadable dossier stamps an empty
# kind for do_landed_tick to resolve later.
#
# A second merge on the same repo before the first watch
# clears just overwrites it with the newer sha and resets attempts to 0 --
# the newer merge implies the older one (a self-pull/cache-swap that reaches
# the newer sha necessarily passed through, or superseded, the older one).
landed_record() {
  local repo="$1" pr="$2" sha="$3" kind sf tmp
  kind=$(landed_kind "$repo" 2>/dev/null) || kind=""
  sf=$(_landed_state_file); [ -f "$sf" ] || echo '{}' > "$sf"
  tmp=$(mktemp)
  if jq --arg r "$repo" --arg p "$pr" --arg s "$sha" --arg k "$kind" \
    '.landed[$r] = {pr:$p, sha:$s, kind:$k, attempts:0}' "$sf" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$sf"
  else
    rm -f "$tmp"
  fi
}

# landed_kind_set <repo> <kind> -- persist a lazily-resolved kind onto an
# existing watch (see do_landed_tick's empty-kind path).
landed_kind_set() {
  local repo="$1" kind="$2" sf tmp
  sf=$(_landed_state_file); [ -f "$sf" ] || return 0
  tmp=$(mktemp)
  if jq --arg r "$repo" --arg k "$kind" '.landed[$r].kind = $k' "$sf" > "$tmp" 2>/dev/null; then
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

# landed_assert_self_pull <sha> [repo-path] -- exit 0 if the live install's
# HEAD equals or descends from <sha> (the self-pull at the very top of every
# tick keeps it moving forward -- an ancestor check, not exact equality, so
# a LATER merge still counts as this one having landed). repo-path defaults
# to AGENT_HOME; tests point it at a fixture repo.
landed_assert_self_pull() {
  local sha="$1" path="${2:-${AGENT_HOME:-}}"
  [ -n "$path" ] && [ -n "$sha" ] || return 1
  git -C "$path" merge-base --is-ancestor "$sha" HEAD 2>/dev/null
}

# landed_self_pull_observed [repo-path] -- the live install's current HEAD
# sha, for logging/alerting.
# shellcheck disable=SC2120  # do_landed_tick calls it bare; tests pass a fixture path
landed_self_pull_observed() {
  local path="${1:-${AGENT_HOME:-}}"
  [ -n "$path" ] || return 0
  git -C "$path" rev-parse HEAD 2>/dev/null
}

# landed_assert_context_cache <sha> [cache-dir] -- exit 0 if the served
# context cache's generation marker equals <sha> exactly. context_refresh's
# swap is all-or-nothing and jumps straight to origin/master's HEAD (see
# lib/context-source.sh), so once a valid refresh happens the marker IS the
# merged sha -- there is no partial-progress state to treat as "descends
# from" the way the self-pull's is. cache-dir defaults to CONTEXT_CACHE_DIR
# (same default lib/context-source.sh uses); tests point it at a fixture.
landed_assert_context_cache() {
  local sha="$1" observed
  [ -n "$sha" ] || return 1
  observed=$(landed_context_cache_observed "${2:-}")
  [ -n "$observed" ] && [ "$observed" = "$sha" ]
}

# landed_context_cache_observed [cache-dir] -- the served context cache's
# generation marker, or empty if the cache has never been seeded.
landed_context_cache_observed() {
  local cache_dir="${1:-${CONTEXT_CACHE_DIR:-${AGENT_STATE_DIR:-$HOME/.local/state/agent}/context}}"
  cat "${cache_dir}/current/HEAD" 2>/dev/null
}

# _landed_alert <repo> <pr> <sha> <observed> <kind> -- email
# ALERT_RECIPIENTS (+ PRIMARY) and comment on the merged PR: the grace
# window expired without the host-state assertion passing.
_landed_alert() {
  local repo="$1" pr="$2" sha="$3" observed="$4" kind="$5" what recipients subject body
  case "$kind" in
    self-pull)     what="the live install's self-pull (git HEAD)" ;;
    context-cache) what="the served context-cache generation marker" ;;
    *)             what="the landed-verification check" ;;
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
or (for the context-cache kind) a swap being refused because the merged
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
  local repo entry kind rc pr sha attempts observed detail
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    entry=$(landed_pending_entry "$repo")
    kind=$(jq -r '.kind // ""' <<<"$entry" 2>/dev/null)
    if [ -z "$kind" ]; then
      # No kind on the entry: it predates landed_record persisting one, or the
      # dossier was unreadable at merge time. Resolve it now.
      rc=0; kind=$(landed_kind "$repo") || rc=$?
      case "$rc" in
        0) landed_kind_set "$repo" "$kind" ;;
        2) # Unreadable this tick -- unknown, not absent. Keep the watch and
           # fall through with no kind, so the assertion is skipped but the
           # attempt counter still runs: a repo whose dossier NEVER comes back
           # expires out of the grace window instead of pending forever.
           log "landed: ${repo} landed-kind unreadable this tick -- watch kept pending"
           kind="" ;;
        *) # This module no longer recognizes the repo (its dossier's
           # landed-kind changed, was removed, or reads as unrecognized) --
           # nothing to check; drop it.
           landed_clear "$repo"
           continue ;;
      esac
    fi
    pr=$(jq -r '.pr // ""' <<<"$entry" 2>/dev/null)
    sha=$(jq -r '.sha // ""' <<<"$entry" 2>/dev/null)
    attempts=$(jq -r '.attempts // 0' <<<"$entry" 2>/dev/null)
    [ -n "$sha" ] || { landed_clear "$repo"; continue; }
    [ -n "$attempts" ] || attempts=0
    # Reset per iteration rather than `unset`ing on the landed path -- `unset`
    # would drop the `local` binding and expose any global of the same name.
    detail=""; observed=""

    case "$kind" in
      self-pull)
        observed=$(landed_self_pull_observed)
        if landed_assert_self_pull "$sha"; then
          detail="self-pull HEAD is ${observed:0:8}"
        fi
        ;;
      context-cache)
        observed=$(landed_context_cache_observed)
        if landed_assert_context_cache "$sha"; then
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
