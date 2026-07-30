#!/usr/bin/env bash
# needsyou.sh -- what is waiting on the OPERATOR right now (igor#439).
#
# The operator's stated biggest problem is not knowing when he is the blocker.
# Today that is only discoverable by asking, or by opening Forgejo and reading.
#
# This half is DETECTION only: build the set of items waiting on the human, and
# work out what is NEW since the last look. Delivery (email) is deliberately a
# separate change -- the first attempt at this issue tried both at once and hit
# the 400-line scope cap at 792 lines.
#
# EVENT-DRIVEN, not periodic. An hourly digest that usually says "nothing needs
# you" trains the reader to stop opening it, and then it fails exactly when it
# matters. The arrival of a notification IS the signal, so only ADDITIONS to the
# set are worth announcing; removals are silent, and an unchanged set says
# nothing at all.
#
# State lives in discretionary-state.json under ".needsyou": a map of
# key -> { repo, kind, number, why, since }. `since` is the epoch when the item
# FIRST entered the set, so a later report can say how long it has been waiting
# without needing a second store.
#
# Pure functions operate on JSON TEXT so they are testable without a state file
# or a single API call. The scan that builds the live set is at the bottom,
# talking to the fleet only through named seams a test can stub.

# needsyou_key <repo> <kind> <number>
# Stable identity for one waiting item. Kind is in the key because an issue and
# a PR can share a number in Forgejo's numbering.
needsyou_key() {
  printf '%s/%s/%s' "${1:-}" "${2:-}" "${3:-}"
}

# needsyou_item <repo> <kind> <number> <why> <since_epoch>
# One item as a compact JSON object, ready to be folded into a set.
#
# A non-numeric `since` is coerced to 0 rather than passed to --argjson, where
# it would fail the whole invocation and yield a bare {} -- which the scan would
# still fold into the set under a valid key, so needsyou_describe would render
# "null#null". A wrong wait time is a bad line; a {} is a broken one.
needsyou_item() {
  local since="${5:-0}"
  case "$since" in ''|*[!0-9]*) since=0 ;; esac
  jq -cn --arg r "${1:-}" --arg k "${2:-}" --arg n "${3:-}" --arg w "${4:-}" \
    --argjson s "$since" \
    '{repo:$r, kind:$k, number:$n, why:$w, since:$s}' 2>/dev/null || printf '{}'
}

# needsyou_pr_numbers <pulls_json>
# The PR numbers worth classifying, one per line.
#
# forgejo_list_open_bot_prs returns a JSON ARRAY of objects, so feeding it
# straight into `while read` yields "[", "  {", '  "number": 449,' and never a
# number -- which is how the first cut of the scan classified nothing at all
# across the whole fleet. do_automerge_tick pulls .number out the same way.
#
# Drafts are dropped for the same reason the rework loop is: a WIP: checkpoint
# PR is Igor mid-task, not the operator's turn. It can also still carry the
# verdict from before it checkpointed, which would otherwise read as "escalated
# to you" while Igor is in fact still working on it.
needsyou_pr_numbers() {
  jq -r --arg wip "${CHECKPOINT_WIP_PREFIX:-WIP: }" '
      .[]? | select((.title // "") | startswith($wip) | not) | .number // empty
    ' <<<"$(_needsyou_arr "${1:-}")" 2>/dev/null || true
}

# needsyou_merge <previous_set_json> <current_set_json> <now_epoch>
# The set to persist: every key currently waiting, carrying the `since` it had
# in the previous set if it was already there, or <now_epoch> if it is new.
#
# Preserving `since` across scans is the whole reason this is a merge rather
# than a replace -- otherwise every scan resets the clock and nothing can ever
# be reported as "waiting three days".
needsyou_merge() {
  local prev="${1:-}" cur="${2:-}" now="${3:-0}"
  jq -cn --argjson p "$(_needsyou_obj "$prev")" --argjson c "$(_needsyou_obj "$cur")" \
    --argjson now "$now" '
      $c | with_entries(
        .value.since = ( ($p[.key].since // $now) )
      )' 2>/dev/null || printf '{}'
}

# needsyou_added <previous_set_json> <current_set_json>
# Keys present now and absent before, newline separated, sorted. These are the
# only things worth announcing.
needsyou_added() {
  jq -rn --argjson p "$(_needsyou_obj "${1:-}")" --argjson c "$(_needsyou_obj "${2:-}")" \
    '($c | keys) - ($p | keys) | sort | .[]' 2>/dev/null || true
}

# needsyou_removed <previous_set_json> <current_set_json>
# Keys that have left the set -- the operator dealt with them. Never announced;
# available so a caller can log that the queue drained.
needsyou_removed() {
  jq -rn --argjson p "$(_needsyou_obj "${1:-}")" --argjson c "$(_needsyou_obj "${2:-}")" \
    '($p | keys) - ($c | keys) | sort | .[]' 2>/dev/null || true
}

# needsyou_pr_why <verdict> <require_human> <rework_rounds> <repo_validated>
# Why an open bot PR is waiting on the OPERATOR, or EMPTY when it is not.
#
# The first cut of this asked `! automerge_will_take`, which is much broader
# than "the human is the blocker": it is also true of a PR nobody has reviewed
# yet (the shadow reviewer's turn) and of one inside the rework loop (Igor's
# turn, up to the round cap). Both of those flip in and out of the set on their
# own, so announcing them is exactly the "usually says nothing needs you" noise
# this feature exists to avoid. So the verdicts that mean HUMAN are enumerated
# instead, mirroring do_review_tick's own routing:
#
#   ""/none        the review has not happened yet   -> reviewer
#   APPROVE        auto-merge takes it               -> nobody, unless the repo
#                                                       pins itself to a human
#   COMMENT        auto-merge will not take it       -> human
#   REQUEST_CHANGES  rework rounds under the cap     -> Igor
#                    escalated (>= REWORK_ROUND_CAP,
#                    lib/review.sh) or unverifiable  -> human
needsyou_pr_why() {
  local verdict="${1:-}" require_human="${2:-false}" rounds="${3:-0}" validated="${4:-true}"
  case "$rounds" in ''|*[!0-9]*) rounds=0 ;; esac
  case "$verdict" in
    APPROVE)
      [ "$require_human" = "true" ] || return 0
      printf 'Igor approved it and this repo is pinned to your review'
      ;;
    COMMENT)
      printf 'Igor reviewed it as COMMENT -- auto-merge will not take that, so it is your call'
      ;;
    REQUEST_CHANGES)
      if [ "$validated" != "true" ]; then
        printf 'Igor requested changes on a repo whose rework cannot be CI-verified -- handed to you'
      elif [ "$rounds" -ge "${REWORK_ROUND_CAP:-10}" ]; then
        printf 'Igor requested changes %s times without converging -- escalated to you' "$rounds"
      fi
      ;;
  esac
  return 0
}

# needsyou_issue_lines <issues_json>
# "<number>|<why>" for each open issue the harness has parked on the operator:
# Status/Blocked (Igor gave up and said what it needs) or Status/Need More Info.
# The why is the issue's Status/* labels, so the line reads as the tracker does;
# other labels (Agent, Priority/*) are not why it is waiting.
needsyou_issue_lines() {
  jq -rn --argjson issues "$(_needsyou_arr "${1:-}")" '
    $issues[]?
    | select([.labels[]?.name] | any(. == "Status/Blocked" or . == "Status/Need More Info"))
    | "\(.number)|\([.labels[]?.name] | map(select(startswith("Status/"))) | join(", "))"
  ' 2>/dev/null || true
}

# needsyou_describe <set_json> <key> <now_epoch>
# One human line for an item: what it is, why it is waiting, and how long.
# Shared by the log line here and by delivery later, so both phrase it the same.
needsyou_describe() {
  local set_json key="$2" now="${3:-0}"
  set_json=$(_needsyou_obj "${1:-}")
  # `// empty` already emits nothing for a missing key, so there is no null
  # branch to guard -- an unknown key simply produces no line.
  jq -rn --argjson s "$set_json" --arg k "$key" --argjson now "$now" '
    ($s[$k] // empty) as $i
    # Clamped at 0: a hand-edited state file or clock skew can put `since`
    # in the future, and "waiting -1m" reads as a bug in the notifier.
    | (([$now - ($i.since // $now), 0] | max) / 60 | floor) as $mins
    | ( if $mins < 60 then "\($mins)m"
        elif $mins < 1440 then "\(($mins/60)|floor)h"
        else "\(($mins/1440)|floor)d" end ) as $age
    | "\($i.repo)#\($i.number) (\($i.kind)) -- \($i.why) [waiting \($age)]"
  ' 2>/dev/null || true
}

# _needsyou_obj <json>
# The argument as a JSON object, or {} when empty or unparseable. Written as a
# helper rather than inline `${1:-{}}` because braces need escaping inside
# double quotes and bash strips a backslash there only before $ ` " \ -- so
# `\{\}` would reach jq verbatim as an invalid document (the igor#441 lesson).
#
# Checks the TYPE, not just that it parses: `keys` on an array yields its
# INDICES, so a stray array reaching needsyou_added would announce "0", "1",
# "2" as if they were waiting items.
_needsyou_obj() {
  local v="${1:-}"
  [ -n "$v" ] || { printf '{}'; return 0; }
  jq -ce 'type == "object"' >/dev/null 2>&1 <<<"$v" || { printf '{}'; return 0; }
  printf '%s' "$v"
}

# _needsyou_arr <json> -- the same, for an API list payload: the argument as a
# JSON array, or [] when empty, unparseable, or an error object.
_needsyou_arr() {
  local v="${1:-}"
  [ -n "$v" ] || { printf '[]'; return 0; }
  jq -ce 'type == "array"' >/dev/null 2>&1 <<<"$v" || { printf '[]'; return 0; }
  printf '%s' "$v"
}

# -- the scan ------------------------------------------------------------
#
# Everything above is pure. What follows talks to the fleet: it gathers the
# facts those predicates need -- the recorded shadow verdict, the repo's
# human-pin, its rework round count, whether it is validated -- and folds the
# answers into a set. It lives here rather than in bin/tick.sh so it can be
# unit-tested at its seams; an untested scan is how the first cut of this
# feature shipped blind to every PR in the fleet while still reporting a
# perfectly plausible "nothing needs you".
#
# Scanned rather than hooked at the emit points, because items must also LEAVE
# the set when the operator deals with them. A hook can only ever add; without
# removal an item stays "already known" forever and a genuine recurrence is
# never announced again. A scan is idempotent and self-correcting, and it also
# picks up anything that entered the queue before this shipped.
#
# Throttled by the caller to every NEEDSYOU_SCAN_EVERY ticks: it costs a
# PR-list AND an issue-list call for every repo in the analysis set -- 2N, the
# fleet-sweep cost igor#441 is about -- plus one agent.json fetch for each repo
# that actually has an open bot PR, which in practice is a handful. At the
# post-#447 cadence that is a few minutes' latency on learning you are blocked,
# against the status quo of finding out by asking.
NEEDSYOU_SCAN_EVERY=${NEEDSYOU_SCAN_EVERY:-20}

# _needsyou_repo_lines <analysis_repos_json> -- the repo objects, one per line.
#
# bin/tick.sh assigns ANALYSIS_REPOS_JSON as `jq -c '.[]' <<<"$ALL_REPOS"` (see
# its "Analysis set:" comment), i.e. newline-delimited compact objects, which
# is what every other fleet loop reads. Flattening an ARRAY here anyway is a
# cheap hedge against that shape ever changing: read line by line, an array
# yields "[", "  {" and never a repo, so the scan would go blind fleet-wide --
# and "nothing needs you" would still look like a legitimate answer. That is
# exactly the bug this feature already shipped one layer up, in the PR list.
_needsyou_repo_lines() {
  local v="${1:-}"
  [ -n "$v" ] || return 0
  jq -c 'if type == "array" then .[] else . end' <<<"$v" 2>/dev/null || true
}

# _needsyou_listed <payload> -- true when a list call actually ANSWERED.
#
# forgejo_list_open_bot_prs is `_fj | jq`, so its exit status is jq's, not the
# request's: a failed fetch yields empty output and rc 0, indistinguishable
# from "this repo has no open bot PRs". A payload that parses as an array is
# the only evidence the call landed.
_needsyou_listed() {
  jq -ce 'type == "array"' >/dev/null 2>&1 <<<"${1:-}"
}

# needsyou_scan_set
# The live set on stdout. Returns NONZERO when the scan was INCOMPLETE -- no
# repos, or a list call that did not answer -- because a partial scan looks
# exactly like an empty one and must not be mistaken for "nothing is waiting".
needsyou_scan_set() {
  local sf repo_line repo pulls prs pr verdict out='{}' item why line num
  local require_human validated issues repos=0 failed=0
  sf=$(discretionary_state_file)
  while IFS= read -r repo_line; do
    [ -n "$repo_line" ] || continue
    repo=$(jq -r '.full_name // empty' <<<"$repo_line" 2>/dev/null || true)
    if [ -z "$repo" ] || [ "$repo" = "null" ]; then continue; fi
    repos=$((repos + 1))

    pulls=$(forgejo_list_open_bot_prs "$repo" "${BOT_USER:-}" 2>/dev/null || true)
    _needsyou_listed "$pulls" || { failed=1; continue; }
    # needsyou_pr_numbers, not the raw array: reading that text line by line
    # hands the predicate "[" and '"number": 449,' instead of a number. It also
    # makes the emptiness test below mean something -- "[]" is a non-empty
    # STRING, so gating on the raw payload paid for the agent.json fetch on
    # every repo in the fleet.
    prs=$(needsyou_pr_numbers "$pulls")
    # Both only matter to the PR predicate, and automerge_require_human reads
    # the repo's agent.json over the API -- so pay for them only where there is
    # actually a PR to classify.
    require_human=false; validated=false
    if [ -n "$prs" ]; then
      automerge_require_human "$repo" && require_human=true
      maintenance_repo_validated "$repo" && validated=true
    fi
    while IFS= read -r pr; do
      if [ -z "$pr" ] || [ "$pr" = "null" ]; then continue; fi
      verdict=$(jq -r --arg k "${repo}#${pr}" '.review[$k].verdict // ""' "$sf" 2>/dev/null || printf '')
      why=$(needsyou_pr_why "$verdict" "$require_human" \
              "$(review_rework_rounds "${repo}#${pr}")" "$validated")
      [ -n "$why" ] || continue
      item=$(needsyou_item "$repo" pr "$pr" "$why" 0)
      out=$(jq -c --arg k "$(needsyou_key "$repo" pr "$pr")" --argjson v "$item" \
              '. + {($k): $v}' <<<"$out" 2>/dev/null || printf '%s' "$out")
    done <<<"$prs"

    issues=$(_fj GET "/repos/${repo}/issues?state=open&type=issues&limit=50" 2>/dev/null || true)
    _needsyou_listed "$issues" || { failed=1; continue; }
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      num=${line%%|*}; why=${line#*|}
      item=$(needsyou_item "$repo" issue "$num" "$why" 0)
      out=$(jq -c --arg k "$(needsyou_key "$repo" issue "$num")" --argjson v "$item" \
              '. + {($k): $v}' <<<"$out" 2>/dev/null || printf '%s' "$out")
    done <<<"$(needsyou_issue_lines "$issues")"
    # Defensive `:-`: this is the only fleet loop that runs from the cascade
    # prelude rather than from a stage, so it is the one most likely to be
    # moved above the validation sweep that assigns the set. Under `set -u`
    # that would abort the whole tick, and only every NEEDSYOU_SCAN_EVERY ticks
    # -- a rare, confusing failure. Reporting an incomplete scan is cheaper.
  done <<<"$(_needsyou_repo_lines "${ANALYSIS_REPOS_JSON:-}")"
  printf '%s' "$out"
  if [ "$repos" -gt 0 ] && [ "$failed" -eq 0 ]; then return 0; fi
  return 1
}

# needsyou_pass
# One scan: persist the live set (each item keeping the `since` it already had)
# and log what is NEW. Removals are silent; an unchanged set logs nothing.
# Needs `log` and `discretionary_state_file` from bin/tick.sh.
needsyou_pass() {
  local sf prev cur merged now added key tmp
  sf=$(discretionary_state_file)
  [ -f "$sf" ] || echo '{}' > "$sf"
  now=$(date +%s)
  prev=$(jq -c '.needsyou // {}' "$sf" 2>/dev/null || echo '{}')

  # A partial scan is thrown away rather than believed. Persisting one would
  # DROP items the operator has not touched, losing their `since` and
  # re-announcing the lot as new on the next good scan -- one transient blip
  # turning this into exactly the notification a reader learns to ignore.
  if ! cur=$(needsyou_scan_set); then
    log "needs-you: scan incomplete (no repos, or a list call did not answer) -- keeping the previous set"
    return 0
  fi
  merged=$(needsyou_merge "$prev" "$cur" "$now")
  added=$(needsyou_added "$prev" "$cur")

  # A write that never lands is not harmless: `prev` then reads as {} forever
  # and every scan re-announces the whole set, which is the failure mode this
  # feature is supposed to avoid. So say so rather than swallowing it.
  tmp=$(mktemp)
  if jq --argjson n "$merged" '.needsyou = $n' "$sf" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$sf"
  else
    rm -f "$tmp"
    log "warning: needs-you: could not write state to ${sf} -- the set will re-announce next scan"
  fi

  if [ -n "$added" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      log "needs-you: $(needsyou_describe "$merged" "$key" "$now")"
    done <<<"$added"
  fi
}
