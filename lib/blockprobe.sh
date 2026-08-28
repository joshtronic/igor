#!/usr/bin/env bash
# blockprobe.sh -- re-evaluate WHY a ticket is Status/Blocked, so a stale
# block can go red when its cause resolves (igor#546).
#
# `Status/Blocked` is prose: it asserts a condition and then nothing ever
# re-checks it. joshing.you#220 blocked on igor#537 landing and stayed
# Status/Blocked for seven days after igor#537 merged, because nothing
# reads the label as a claim that can become false.
#
# Fix: bin/agent-block.sh can now record a machine-checkable PROBE alongside
# the human reason, appended to the issue BODY (never just a comment -- the
# issue-work prompt is built from the body alone). One probe block, first
# match... no, LATEST match wins (a ticket can block more than once; only
# the most recent block's probe describes the CURRENT hold):
#
#   <!-- probe
#   kind: issue-open | pr-behind | operator
#   ref: <owner>/<repo>#<number>   (omitted for kind: operator)
#   -->
#
#   issue-open  HOLDS while ref is an OPEN issue/PR; CLEARS once it closes
#               (e.g. "blocked on X landing").
#   pr-behind   HOLDS while ref (a PR) is behind its base branch; CLEARS
#               once it is not (e.g. "blocked on PR #147 catching up").
#   operator    Not a mechanical condition -- a human decision ("Josh needs
#               to choose an approach"). Never evaluated, never auto-
#               requeued; this is the "who" vs "what" split the issue asks
#               for.
#
# do_blockprobe_tick sweeps every Status/Blocked issue in the analysis set
# once per tick (non-model, API-only, so it runs even during a Claude health
# cooldown -- same rationale as do_landed_tick/do_automerge_tick):
#   - no probe block at all           -> log UNPROBED, leave alone (an
#                                         honest "don't know" beats guessing)
#   - kind: operator                  -> log, leave alone, never requeue
#   - kind unrecognized               -> log loudly, treat as UNPROBED
#   - probe evaluates HOLDS           -> log confirmation, leave alone
#   - probe evaluates UNKNOWN         -> fails CLOSED: leave alone (a
#                                         transport blip must never look
#                                         like a resolved cause)
#   - probe evaluates CLEARED         -> repeat-block guard first (below);
#                                         then remove Status/Blocked,
#                                         unassign, and comment why.
#
# Repeat-block guard (ctj#127): a block that regenerates with the IDENTICAL
# reason text more than twice smells like a requeue loop, not a resolved
# condition -- auto-requeuing again would just burn a tick every cycle
# looking like progress. blockprobe_reason_repeat_count counts exact
# occurrences of the latest reason text anywhere in the body (a plain
# substring count, not section-aware parsing -- cheap and, since a repeated
# block reason across separate "## Blocked (...)" sections is exactly what
# it's meant to catch, right for the job even though a reason that happens
# to also appear in the ticket's own prose would over-count). On the third
# occurrence the sweep escalates instead: it comments once (deduped via a
# `<!-- blockprobe-escalated -->` marker, like the shadow reviewer's per-sha
# marker) and assigns FORGEJO_REVIEWER, but leaves Status/Blocked in place.
#
# Deliberately does NOT touch tickets gated by lib/deferred.sh's own
# `<!-- gate ... -->` block -- that's a different mechanism (an LLM read of
# an external page, released to the human for confirmation) and must not be
# double-processed here.
#
# Sourced by tick.sh; depends on _fj + forgejo_get_issue/forgejo_remove_label/
# forgejo_unassign_all/forgejo_comment/forgejo_assign/
# forgejo_pr_has_comment_containing (lib/forgejo.sh), automerge_behind_count
# (lib/automerge.sh), log (tick.sh), jq.

BLOCKPROBE_OPEN="<!-- probe"
BLOCKPROBE_KINDS="issue-open pr-behind operator"
BLOCKPROBE_BLOCKED_HEADING="## Blocked ("
BLOCKPROBE_ESCALATED_MARKER="<!-- blockprobe-escalated -->"

# _blockprobe_trim <text> -- strip leading/trailing whitespace (including
# newlines -- this operates on multi-line reason text, not a single line).
_blockprobe_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# _blockprobe_last_probe_block <body> -- the content between the LAST
# "<!-- probe" marker and its closing "-->", or empty if there is none.
_blockprobe_last_probe_block() {
  local body="$1" tail
  case "$body" in
    *"$BLOCKPROBE_OPEN"*) tail="${body##*"$BLOCKPROBE_OPEN"}" ;;
    *) return 0 ;;
  esac
  case "$tail" in
    *"-->"*) tail="${tail%%-->*}" ;;
  esac
  printf '%s' "$tail"
}

# blockprobe_parse_kind <body> -- the LATEST probe block's kind: value, or
# empty if the body records no probe at all.
blockprobe_parse_kind() {
  local blk; blk=$(_blockprobe_last_probe_block "$1")
  [ -n "$blk" ] || return 0
  printf '%s\n' "$blk" | sed -n 's/^[[:space:]]*kind:[[:space:]]*//p' | head -1 | tr -d '[:space:]'
}

# blockprobe_parse_ref <body> -- the LATEST probe block's ref: value.
blockprobe_parse_ref() {
  local blk; blk=$(_blockprobe_last_probe_block "$1")
  [ -n "$blk" ] || return 0
  printf '%s\n' "$blk" | sed -n 's/^[[:space:]]*ref:[[:space:]]*//p' | head -1 | tr -d '[:space:]'
}

# blockprobe_last_reason <body> -- the human reason text of the LATEST
# "## Blocked (...)" section, with any trailing probe block and surrounding
# whitespace stripped.
blockprobe_last_reason() {
  local body="$1" tail
  case "$body" in
    *"$BLOCKPROBE_BLOCKED_HEADING"*) tail="${body##*"$BLOCKPROBE_BLOCKED_HEADING"}" ;;
    *) return 0 ;;
  esac
  tail="${tail#*)}"   # drop through the timestamp's closing paren
  case "$tail" in
    *"$BLOCKPROBE_OPEN"*) tail="${tail%%"$BLOCKPROBE_OPEN"*}" ;;
  esac
  _blockprobe_trim "$tail"
}

# blockprobe_reason_repeat_count <body> <reason> -- how many times the exact
# <reason> text appears in <body> (non-overlapping). Empty reason -> 0.
blockprobe_reason_repeat_count() {
  local body="$1" reason="$2" count=0 rest
  rest="$body"
  [ -n "$reason" ] || { printf '0'; return 0; }
  while true; do
    case "$rest" in
      *"$reason"*)
        count=$((count + 1))
        rest="${rest#*"$reason"}"
        ;;
      *) break ;;
    esac
  done
  printf '%s' "$count"
}

# blockprobe_eval_issue_open <repo> <num> -- HOLDS while open, CLEARED once
# closed, UNKNOWN if the fetch fails or the payload is unreadable (fail
# closed -- a transport blip must never read as "cause resolved").
blockprobe_eval_issue_open() {
  local repo="$1" num="$2" obj state
  if [ -z "$repo" ] || [ -z "$num" ]; then printf 'UNKNOWN'; return 0; fi
  obj=$(forgejo_get_issue "$repo" "$num" 2>/dev/null) || { printf 'UNKNOWN'; return 0; }
  state=$(jq -r 'if type == "object" then (.state // "") else "" end' <<<"$obj" 2>/dev/null)
  case "$state" in
    open)   printf 'HOLDS' ;;
    closed) printf 'CLEARED' ;;
    *)      printf 'UNKNOWN' ;;
  esac
}

# blockprobe_eval_pr_behind <repo> <num> -- HOLDS while behind, CLEARED once
# not behind, UNKNOWN when automerge_behind_count can't tell (-1).
blockprobe_eval_pr_behind() {
  local repo="$1" num="$2" behind
  if [ -z "$repo" ] || [ -z "$num" ]; then printf 'UNKNOWN'; return 0; fi
  behind=$(automerge_behind_count "$repo" "$num" 2>/dev/null)
  case "$behind" in
    0) printf 'CLEARED' ;;
    ''|*[!0-9-]*|-1) printf 'UNKNOWN' ;;
    *) printf 'HOLDS' ;;
  esac
}

# blockprobe_evaluate <kind> <ref> -- HOLDS / CLEARED / UNKNOWN. ref is
# "<owner>/<repo>#<number>"; a malformed ref or unrecognized kind is UNKNOWN.
blockprobe_evaluate() {
  local kind="$1" ref="$2" repo num
  case "$ref" in
    *#*) repo="${ref%#*}"; num="${ref##*#}" ;;
    *) printf 'UNKNOWN'; return 0 ;;
  esac
  case "$kind" in
    issue-open) blockprobe_eval_issue_open "$repo" "$num" ;;
    pr-behind)  blockprobe_eval_pr_behind "$repo" "$num" ;;
    *)          printf 'UNKNOWN' ;;
  esac
}

# blockprobe_requeue <repo> <num> <kind> <ref> -- the cause is gone: drop
# Status/Blocked, unassign, and comment why. Deliberately does NOT touch the
# `Agent` label -- unlike lib/deferred.sh's LLM-judged release, this is a
# direct machine check of a declared condition, so the ticket goes straight
# back to claimable rather than through a human confirmation step.
blockprobe_requeue() {
  local repo="$1" num="$2" kind="$3" ref="$4"
  forgejo_remove_label "$repo" "$num" "Status/Blocked" 2>/dev/null \
    || log "blockprobe: warning -- could not drop Status/Blocked on ${repo}#${num}"
  forgejo_unassign_all "$repo" "$num" 2>/dev/null \
    || log "blockprobe: warning -- could not unassign ${repo}#${num}"
  forgejo_comment "$repo" "$num" \
    "Block probe cleared -- the recorded condition (\`${kind}\`: \`${ref}\`) no longer holds. Removed \`Status/Blocked\` and unassigned so the ticket is claimable again." \
    2>/dev/null || true
  log "blockprobe: ${repo}#${num} requeued (kind=${kind} ref=${ref})"
}

# blockprobe_escalate <repo> <num> <reason> <reviewer> -- the repeat-block
# guard tripped: leave Status/Blocked in place, comment once (deduped via
# BLOCKPROBE_ESCALATED_MARKER), and assign the reviewer.
blockprobe_escalate() {
  local repo="$1" num="$2" reviewer="$4" bot="${BOT_USER:-}" cnt
  cnt=$(forgejo_pr_has_comment_containing "$repo" "$num" "$bot" "$BLOCKPROBE_ESCALATED_MARKER" 2>/dev/null)
  case "$cnt" in ''|*[!0-9]*) cnt=0 ;; esac
  if [ "$cnt" -gt 0 ]; then
    return 0
  fi
  forgejo_comment "$repo" "$num" \
    "This ticket has blocked with the identical reason more than twice -- clearing and re-blocking looks like a loop, not a resolved condition. Leaving \`Status/Blocked\` in place and escalating for a human decision instead of auto-requeuing again.

${BLOCKPROBE_ESCALATED_MARKER}" \
    2>/dev/null || true
  if [ -n "$reviewer" ]; then
    forgejo_assign "$repo" "$num" "$reviewer" 2>/dev/null \
      || log "blockprobe: warning -- could not assign ${repo}#${num} to ${reviewer}"
  fi
  log "blockprobe: ${repo}#${num} repeat-block guard tripped -- escalated instead of requeuing"
}

# do_blockprobe_tick -- sweep every Status/Blocked issue in the analysis
# set, evaluate its recorded probe, and requeue/escalate/leave-alone per the
# rules above. Non-model (API-only): call as `do_blockprobe_tick || true`,
# same as do_landed_tick.
do_blockprobe_tick() {
  local repo_line repo issues n body kind ref verdict reason repeat reviewer
  reviewer="${FORGEJO_REVIEWER:-}"

  while IFS= read -r repo_line; do
    [ -n "$repo_line" ] || continue
    repo=$(jq -r '.full_name // empty' <<<"$repo_line" 2>/dev/null)
    [ -n "$repo" ] || continue

    issues=$(_fj GET "/repos/${repo}/issues?state=open&type=issues&labels=Status/Blocked&limit=50" 2>/dev/null) || continue
    [ -n "$issues" ] || continue

    while IFS= read -r n; do
      [ -n "$n" ] || continue
      body=$(jq -r --arg num "$n" '.[] | select((.number|tostring)==$num) | .body // ""' <<<"$issues")

      # lib/deferred.sh owns any ticket gated by its own <!-- gate --> block.
      case "$body" in *"<!-- gate"*) continue ;; esac

      kind=$(blockprobe_parse_kind "$body")
      if [ -z "$kind" ]; then
        log "blockprobe: ${repo}#${n} UNPROBED -- no machine-checkable probe recorded, leaving Status/Blocked"
        continue
      fi
      case " $BLOCKPROBE_KINDS " in
        *" $kind "*) ;;
        *)
          log "blockprobe: ${repo}#${n} declares unrecognized probe kind '${kind}' -- treating as UNPROBED"
          continue
          ;;
      esac
      if [ "$kind" = "operator" ]; then
        log "blockprobe: ${repo}#${n} blocked on an operator decision -- never auto-requeued"
        continue
      fi

      ref=$(blockprobe_parse_ref "$body")
      verdict=$(blockprobe_evaluate "$kind" "$ref")
      case "$verdict" in
        HOLDS)
          log "blockprobe: ${repo}#${n} probe still holds (kind=${kind} ref=${ref})"
          ;;
        UNKNOWN)
          log "blockprobe: ${repo}#${n} probe could not be evaluated this tick (kind=${kind} ref=${ref}) -- leaving Status/Blocked"
          ;;
        CLEARED)
          reason=$(blockprobe_last_reason "$body")
          repeat=$(blockprobe_reason_repeat_count "$body" "$reason")
          if [ "$repeat" -gt 2 ]; then
            blockprobe_escalate "$repo" "$n" "$reason" "$reviewer"
          else
            blockprobe_requeue "$repo" "$n" "$kind" "$ref"
          fi
          ;;
      esac
    done < <(jq -r '.[]?.number' <<<"$issues" 2>/dev/null)
  done <<<"${ANALYSIS_REPOS_JSON:-}"

  return 0
}
