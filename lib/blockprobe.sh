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
# issue-work prompt is built from the body alone). Only the LATEST
# "## Blocked (...)" section is read, probe and reason alike: a ticket can
# block more than once, and only the most recent block describes the current
# hold. Since the probe args are OPTIONAL, a latest section carrying no probe
# reads as UNPROBED even when an earlier section has one -- reading the probe
# from anywhere in the body would clear a ticket on a condition nobody
# currently means.
#
#   <!-- probe
#   kind: issue-open | pr-behind | operator | transient
#   ref: <owner>/<repo>#<number>   (omitted for kind: operator, transient)
#   confirmed: <YYYY-MM-DD>        (written by the sweep, not the producer)
#   cleared: <YYYY-MM-DD>          (written by the sweep, not the producer)
#   -->
#
# `cleared:` marks the probe SPENT -- the sweep already acted on it once and
# dropped Status/Blocked. A probe left live outlives the episode it describes:
# the next thing to re-apply Status/Blocked WITHOUT appending a new
# "## Blocked (...)" section (a human, by hand) would be undone on the very
# next tick, citing a condition from an episode nobody currently means. So a
# spent probe reads as UNPROBED, exactly like the mixed-body case below, and
# the label is left alone until a new block section records a new probe.
#
#   issue-open  HOLDS while ref is an OPEN issue/PR; CLEARS once it closes
#               (e.g. "blocked on X landing").
#   pr-behind   HOLDS while ref (a PR) is behind its base branch; CLEARS
#               once it is not (e.g. "blocked on PR #147 catching up").
#   operator    Not a mechanical condition -- a human decision ("the
#               operator needs to choose an approach"). Never evaluated,
#               never auto-requeued; this is the "who" vs "what" split
#               the issue asks for.
#   transient   No ref -- there is no external state to poll (e.g. a gate
#               that failed to produce a verdict at all: igor#491/igor#555).
#               ALWAYS evaluates CLEARED, so it requeues on the very next
#               sweep -- "presumed resolved, try again" rather than "prove
#               it resolved". Boundedness comes from the repeat-block guard
#               below, not a second retry counter: the identical reason
#               re-accumulates across requeue cycles and escalates on the
#               third occurrence. Since transient is the one kind that
#               requeues with no external condition to satisfy, the guard
#               ALSO counts transient episodes (blockprobe_kind_repeat_count)
#               -- a producer whose reason wording varies between attempts
#               would otherwise slip past text equality and requeue itself
#               indefinitely.
#
# do_blockprobe_tick sweeps every Status/Blocked issue in the analysis set
# once per tick (non-model, API-only, so it runs even during a Claude health
# cooldown -- same rationale as do_landed_tick/do_automerge_tick):
#   - no probe block at all           -> log UNPROBED, leave alone (an
#                                         honest "don't know" beats guessing)
#   - probe carries `cleared:`        -> SPENT; log UNPROBED, leave alone
#   - kind: operator                  -> log, leave alone, never requeue
#   - kind unrecognized               -> log loudly, treat as UNPROBED
#   - probe evaluates HOLDS           -> leave alone, and stamp `confirmed:
#                                         <date>` into the probe block so the
#                                         ticket itself says when the hold was
#                                         last re-checked (the tick log is
#                                         ephemeral). Date-gated: at most one
#                                         body PATCH per ticket per day.
#   - probe evaluates UNKNOWN         -> fails CLOSED: leave alone (a
#                                         transport blip must never look
#                                         like a resolved cause)
#   - probe evaluates CLEARED         -> repeat-block guard first (below);
#                                         then stamp `cleared: <date>` into
#                                         the probe (so it can never fire
#                                         again), remove Status/Blocked,
#                                         unassign, and comment why. The stamp
#                                         goes FIRST and gates the rest: a
#                                         ticket left blocked one more tick is
#                                         recoverable, a label cleared by a
#                                         still-live probe is the bug above.
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
# For kind: transient the same third-occurrence rule also applies to the
# EPISODE count (blockprobe_kind_repeat_count), since text equality alone is
# an escape hatch for a producer whose reason wording varies per attempt and
# transient is the only kind that requeues without satisfying anything.
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
BLOCKPROBE_KINDS="issue-open pr-behind operator transient"
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

# _blockprobe_last_block <body> -- the body from the LAST "## Blocked (...)"
# heading onward (past its closing paren), or empty when the body records no
# block at all. Every other reader works from this slice, so the probe and the
# reason can never come from different blocks.
_blockprobe_last_block() {
  local body="$1" tail
  case "$body" in
    *"$BLOCKPROBE_BLOCKED_HEADING"*) tail="${body##*"$BLOCKPROBE_BLOCKED_HEADING"}" ;;
    *) return 0 ;;
  esac
  printf '%s' "${tail#*)}"
}

# _blockprobe_last_probe_block <body> -- the content between the LATEST
# block's "<!-- probe" marker and its closing "-->", or empty if that block
# records none.
_blockprobe_last_probe_block() {
  local tail
  tail=$(_blockprobe_last_block "$1")
  case "$tail" in
    *"$BLOCKPROBE_OPEN"*) tail="${tail##*"$BLOCKPROBE_OPEN"}" ;;
    *) return 0 ;;
  esac
  case "$tail" in
    *"-->"*) tail="${tail%%-->*}" ;;
  esac
  printf '%s' "$tail"
}

# _blockprobe_probe_field <body> <field> -- the LATEST probe block's <field>:
# value, or empty if the body records no probe at all. <field> is always one of
# this file's own literals, never anything read off a ticket, so interpolating
# it into the sed expression can't be steered from outside.
_blockprobe_probe_field() {
  local blk; blk=$(_blockprobe_last_probe_block "$1")
  [ -n "$blk" ] || return 0
  printf '%s\n' "$blk" | sed -n "s/^[[:space:]]*${2}:[[:space:]]*//p" | head -1 | tr -d '[:space:]'
}

# blockprobe_parse_kind <body> -- the LATEST probe block's kind: value.
blockprobe_parse_kind() { _blockprobe_probe_field "$1" kind; }

# blockprobe_parse_ref <body> -- the LATEST probe block's ref: value.
blockprobe_parse_ref() { _blockprobe_probe_field "$1" ref; }

# blockprobe_parse_confirmed <body> -- the LATEST probe block's confirmed:
# date (YYYY-MM-DD), or empty if the probe has never been re-confirmed.
blockprobe_parse_confirmed() { _blockprobe_probe_field "$1" confirmed; }

# blockprobe_parse_cleared <body> -- the LATEST probe block's cleared: date,
# or empty while the probe is still live. Non-empty means SPENT: the sweep
# already acted on this probe, so it describes a block episode that is over.
blockprobe_parse_cleared() { _blockprobe_probe_field "$1" cleared; }

# _blockprobe_body_with_field <body> <field> <date> -- <body> with the LATEST
# probe block carrying `<field>: <date>`, echoed to stdout. Pure string work,
# no I/O. rc 1 (echoing <body> unchanged) when there is no probe block to
# stamp.
#
# The stamp REPLACES any existing one of the SAME field rather than appending:
# a block held for a month would otherwise grow 30 confirmed: lines in the
# issue description. Other fields are left alone, so a probe that held for
# weeks and then cleared carries both dates. It lives INSIDE the probe comment
# for two reasons -- it is invisible in rendered markdown, and it can never be
# mistaken for part of the human reason text that
# blockprobe_reason_repeat_count counts.
_blockprobe_body_with_field() {
  local body="$1" field="$2" date="$3" pre rest inner suffix kept
  case "$body" in
    *"$BLOCKPROBE_OPEN"*) ;;
    *) printf '%s' "$body"; return 1 ;;
  esac
  # `%` (not `%%`) is what makes this the LAST probe block: shortest matching
  # suffix, so `pre` ends just before the final marker.
  pre="${body%"$BLOCKPROBE_OPEN"*}"
  rest="${body#"$pre""$BLOCKPROBE_OPEN"}"
  case "$rest" in
    *"-->"*) inner="${rest%%-->*}"; suffix="${rest#*-->}" ;;
    *) printf '%s' "$body"; return 1 ;;
  esac
  kept=$(printf '%s' "$inner" | sed "/^[[:space:]]*${field}:[[:space:]]*/d")
  printf '%s%s%s\n%s: %s\n-->%s' "$pre" "$BLOCKPROBE_OPEN" "$kept" "$field" "$date" "$suffix"
}

# blockprobe_body_with_confirmation <body> <date> -- the probe was re-checked
# on <date> and still holds.
blockprobe_body_with_confirmation() { _blockprobe_body_with_field "$1" confirmed "$2"; }

# blockprobe_body_with_cleared <body> <date> -- the probe's condition resolved
# on <date> and the sweep acted on it. Marks the probe SPENT, so it can never
# clear a later block episode that nobody recorded it for.
blockprobe_body_with_cleared() { _blockprobe_body_with_field "$1" cleared "$2"; }

# _blockprobe_record_stamp <repo> <num> <field> <date> -- stamp the ticket's
# LATEST probe with `<field>: <date>`. rc 0 when written or already current, 1
# when the ticket can't be read or has no probe to stamp.
#
# Re-fetches rather than reusing the sweep's list body, and validates the
# payload looks like an issue before writing, for the reason spelled out at
# length on forgejo_append_issue_body: the failure mode of a read-modify-write
# on an unvalidated fetch is DESTRUCTIVE -- it PATCHes a near-empty body over
# the issue description this whole mechanism exists to preserve.
_blockprobe_record_stamp() {
  local repo="$1" num="$2" field="$3" date="$4" raw current new
  raw=$(forgejo_get_issue "$repo" "$num") || return 1
  current=$(jq -er '
      if (type == "object") and has("number") and has("body")
      then (.body // "") else empty end
    ' <<<"$raw") || return 1
  [ "$(_blockprobe_probe_field "$current" "$field")" != "$date" ] || return 0
  # The caller's verdict was reached from the LIST body; this is the RE-FETCHED
  # one. If a write landed in between and the latest block no longer carries a
  # probe, _blockprobe_body_with_field would stamp an earlier block's probe --
  # a date against a condition nobody currently means. Re-check here so "the
  # stamp lands on the latest block" holds by construction rather than by
  # argument about the two reads agreeing.
  [ -n "$(blockprobe_parse_kind "$current")" ] || return 1
  new=$(_blockprobe_body_with_field "$current" "$field" "$date") || return 1
  _fj PATCH "/repos/${repo}/issues/${num}" \
    "$(jq -n --arg b "$new" '{body: $b}')" >/dev/null
}

# blockprobe_record_confirmation <repo> <num> <date> -- record that the probe
# was re-checked on <date> and still holds.
blockprobe_record_confirmation() { _blockprobe_record_stamp "$1" "$2" confirmed "$3"; }

# blockprobe_record_cleared <repo> <num> <date> -- mark the probe SPENT. This
# is what stops it outliving the block episode it was recorded for.
blockprobe_record_cleared() { _blockprobe_record_stamp "$1" "$2" cleared "$3"; }

# blockprobe_last_reason <body> -- the human reason text of the LATEST
# "## Blocked (...)" section, with any trailing probe block and surrounding
# whitespace stripped.
blockprobe_last_reason() {
  local tail
  tail=$(_blockprobe_last_block "$1")
  [ -n "$tail" ] || return 0
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

# blockprobe_kind_repeat_count <body> <kind> -- how many probe blocks in <body>
# declare <kind>, spent ones included (a spent probe still marks an episode
# that happened). The reason guard above is text equality, so a producer whose
# wording varies between attempts slips past it; counting episodes bounds a
# self-clearing kind structurally instead. Empty or non-vocabulary kind -> 0.
blockprobe_kind_repeat_count() {
  local body="$1" kind="$2" count
  [ -n "$kind" ] || { printf '0'; return 0; }
  case "$kind" in *[!a-z-]*) printf '0'; return 0 ;; esac
  count=$(printf '%s\n' "$body" | grep -cE "^[[:space:]]*kind:[[:space:]]*${kind}[[:space:]]*$" || true)
  printf '%s' "${count:-0}"
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
  # Anything non-numeric is UNKNOWN, and so is ANY negative: -1 is the
  # documented "couldn't tell" sentinel, but a different negative is no more
  # evidence of being behind than -1 is, and must not fall through to HOLDS.
  case "$behind" in
    0) printf 'CLEARED' ;;
    ''|*[!0-9]*) printf 'UNKNOWN' ;;
    *) printf 'HOLDS' ;;
  esac
}

# blockprobe_evaluate <kind> <ref> -- HOLDS / CLEARED / UNKNOWN. ref must be
# exactly "<owner>/<repo>#<number>"; anything else, or an unrecognized kind,
# is UNKNOWN.
#
# The shape is CHECKED rather than assumed because repo and num are
# interpolated straight into an API path. Collaborator rights and GET-only
# requests already bound the damage, but a checked shape makes "a crafted ref
# reaches no request" structurally true instead of incidentally true.
#
# kind: transient takes no ref and needs no request at all -- it always
# evaluates CLEARED, so it must be dispatched before the ref-shape check
# below (an empty ref would otherwise read as UNKNOWN and never requeue).
blockprobe_evaluate() {
  local kind="$1" ref="$2" repo num
  if [ "$kind" = "transient" ]; then
    printf 'CLEARED'; return 0
  fi
  if [[ ! "$ref" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\#[0-9]+$ ]] || [ "${ref#*..}" != "$ref" ]; then
    printf 'UNKNOWN'; return 0
  fi
  repo="${ref%#*}"; num="${ref##*#}"
  case "$kind" in
    issue-open) blockprobe_eval_issue_open "$repo" "$num" ;;
    pr-behind)  blockprobe_eval_pr_behind "$repo" "$num" ;;
    *)          printf 'UNKNOWN' ;;
  esac
}

# blockprobe_requeue <repo> <num> <kind> <ref> <date> -- the cause is gone:
# mark the probe spent, then drop Status/Blocked, unassign, and comment why.
# Deliberately does NOT touch the `Agent` label -- unlike lib/deferred.sh's
# LLM-judged release, this is a direct machine check of a declared condition,
# so the ticket goes straight back to claimable rather than through a human
# confirmation step. rc 1 without touching anything if the probe can't be
# marked spent.
blockprobe_requeue() {
  local repo="$1" num="$2" kind="$3" ref="$4" date="$5"
  # The spent-stamp GATES the clear, and deliberately fails closed. An
  # un-spent probe evaluates CLEARED forever, so the next Status/Blocked
  # applied without a new "## Blocked (...)" section -- a human labelling the
  # ticket by hand -- would be stripped again on the next tick, justified by a
  # condition from an episode that is over. A ticket left blocked one more
  # tick is recoverable and self-heals on the retry; a label cleared out from
  # under the human who set it is not.
  if ! blockprobe_record_cleared "$repo" "$num" "$date"; then
    log "blockprobe: ${repo}#${num} probe cleared but the spent-stamp could not be written -- leaving Status/Blocked, will retry next tick"
    return 1
  fi
  # A failure HERE, after the stamp landed, is the one case the sweep does not
  # retry: next tick reads a spent probe and leaves the ticket alone. That is
  # the accepted cost of ordering the stamp first -- the label survives, the
  # warning names the ticket, and the probe itself says `cleared:`, so the
  # state is self-describing rather than silently wrong.
  forgejo_remove_label "$repo" "$num" "Status/Blocked" 2>/dev/null \
    || log "blockprobe: warning -- could not drop Status/Blocked on ${repo}#${num}"
  # Clearing ALL assignees is right rather than surgical: both producers of a
  # blocked ticket leave it assigned to FORGEJO_REVIEWER as the "a human owes
  # this a decision" marker (bin/agent-block.sh, and the rejected-PR strike in
  # bin/tick.sh), so the assignee being dropped here is the harness's own
  # escalation flag -- and that flag is exactly what stops being true once the
  # probe's condition resolves.
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
#
# The dedup filters by comment AUTHOR, so an empty $BOT_USER would match no
# comment and re-post the escalation every tick -- spam on exactly the tickets
# this guard exists to quiet. tick.sh resolves BOT_USER or exits 3 long before
# any sweep runs (bin/tick.sh, `[ -n "$BOT_USER" ] || { ... exit 3; }`, asserted
# by bin/test-blockprobe.sh), so `${BOT_USER:-}` here is only about surviving
# `set -u` in a lib sourced from a test or a helper script.
blockprobe_escalate() {
  local repo="$1" num="$2" reason="$3" reviewer="$4" bot="${BOT_USER:-}" cnt
  cnt=$(forgejo_pr_has_comment_containing "$repo" "$num" "$bot" "$BLOCKPROBE_ESCALATED_MARKER" 2>/dev/null)
  case "$cnt" in ''|*[!0-9]*) cnt=0 ;; esac
  if [ "$cnt" -gt 0 ]; then
    return 0
  fi
  # The reason is quoted verbatim in a fence: it's what the human has to judge,
  # and it may be several lines of the agent's own words.
  forgejo_comment "$repo" "$num" \
    "This ticket has blocked and re-blocked more than twice -- with the identical reason, or on a probe kind that clears itself. Either way it looks like a loop, not a resolved condition. Leaving \`Status/Blocked\` in place and escalating for a human decision instead of auto-requeuing again.

The most recent reason:

\`\`\`
${reason}
\`\`\`

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
  local repo_line repo issues n body kind ref verdict reason repeat episodes reviewer today spent
  reviewer="${FORGEJO_REVIEWER:-}"
  today=$(date -u '+%Y-%m-%d')

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
      # A spent probe belongs to a block episode this sweep already ended.
      # Whatever re-applied Status/Blocked since means something else by it,
      # and never said what -- so this reads as UNPROBED, same as a latest
      # block that carries no probe at all.
      spent=$(blockprobe_parse_cleared "$body")
      if [ -n "$spent" ]; then
        log "blockprobe: ${repo}#${n} UNPROBED -- the recorded probe was already spent (cleared ${spent}), leaving Status/Blocked"
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
          # Date-gated on the body we already have, so a held block costs one
          # extra API call per DAY rather than one per tick.
          if [ "$(blockprobe_parse_confirmed "$body")" != "$today" ]; then
            blockprobe_record_confirmation "$repo" "$n" "$today" \
              || log "blockprobe: warning -- could not stamp the confirmation date on ${repo}#${n}"
          fi
          ;;
        UNKNOWN)
          log "blockprobe: ${repo}#${n} probe could not be evaluated this tick (kind=${kind} ref=${ref}) -- leaving Status/Blocked"
          ;;
        CLEARED)
          reason=$(blockprobe_last_reason "$body")
          repeat=$(blockprobe_reason_repeat_count "$body" "$reason")
          # transient clears unconditionally, so it is the one kind whose bound
          # is entirely in this guard. Text equality alone is too weak for it:
          # a producer whose reason carries a timestamp or a findings excerpt
          # would requeue itself indefinitely. Count the episodes too.
          episodes=0
          if [ "$kind" = "transient" ]; then
            episodes=$(blockprobe_kind_repeat_count "$body" "$kind")
          fi
          if [ "$repeat" -gt 2 ] || [ "$episodes" -gt 2 ]; then
            blockprobe_escalate "$repo" "$n" "$reason" "$reviewer"
          else
            blockprobe_requeue "$repo" "$n" "$kind" "$ref" "$today" || true
          fi
          ;;
      esac
    done < <(jq -r '.[]?.number' <<<"$issues" 2>/dev/null)
  done <<<"${ANALYSIS_REPOS_JSON:-}"

  return 0
}
