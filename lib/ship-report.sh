#!/usr/bin/env bash
# ship-report.sh -- the daily fleet ship-report: what auto-merged + shipped in the
# last 24h, what still needs the human, and what's in flight. Sourced by
# bin/tick.sh (do_shipreport_tick).
#
# FULLY SCRIPTED -- no model call -- so it sends even during a Claude cooldown
# (exactly when knowing what shipped matters). It's the safety valve for
# shadow-review auto-merge: once the human is out of the per-PR gate, this is the
# once-a-day window that keeps them in control by exception.
#
# This module is PURE assembly + rendering + the daily stamp. The Forgejo
# gathering (which PRs merged / are open per repo) lives in do_shipreport_tick,
# like do_seo_tick's gathering -- so these functions unit-test off fixtures.
#
# It's also where lib/landed.sh's landed-verification notes (igor#512, the
# host-state companion to the deploy barrier for the url-less repos) drain
# into: shipreport_landed_read/shipreport_landed_clear read and clear the
# queue, shipreport_merge_landed folds it into a report as a `landed`
# bucket. do_shipreport_tick calls these AFTER its own creds/hour/
# sent-today gates, so the drain never fires outside a real send.
#
# igor#610: also where a merged PR's unresolved review judgment surfaces --
# shipreport_judgment_build wraps the per-PR items lib/review-corpus.sh's
# review_corpus_judgment_items extracts (a non-APPROVE final verdict in full,
# an APPROVE's "needs your judgment" section, or a dismissal never blessed by
# a later APPROVE) into the `judgment_items` key.

# Fallback logger so this module is sourceable standalone (tests).
if ! declare -F log >/dev/null; then log() { printf '[agent] %s\n' "$*" >&2; }; fi

_shipreport_state_file() { echo "${AGENT_STATE_DIR:-$HOME/.local/state/agent}/discretionary-state.json"; }

# igor#633: .shipreport is day-keyed like the sports digest's .sports --
# { date, sent, failures, last_attempt } -- so a failed send can retry on a
# later tick (bounded by a cooldown + failure cap) instead of being stamped
# sent regardless of outcome, which lost the whole day's report silently on
# one transient SMTP2GO failure.
SHIPREPORT_RETRY_COOLDOWN_SECS="${SHIPREPORT_RETRY_COOLDOWN_SECS:-900}"  # 15 min, mirrors sports

# igor#635: the transport can now carry an email of any size (body goes on
# curl's stdin, not argv -- see lib/email.sh), but a multi-megabyte report is
# a *readability* failure even once it sends. These bound the judgment-items
# section specifically, since it's the one section that embeds raw,
# unbounded review/rework text. Measured on the 2026-09-14 window that
# tripped the original ARG_MAX bug: 91 judgment-item bodies, 223 KB total --
# averaging ~2.45 KB/item. ITEM_MAX_CHARS is ~3x that average, so a normal
# item never gets touched and only a pathological single dump (a full diff
# pasted into a review comment) gets shortened. SECTION_MAX_CHARS sits just
# under that 223 KB day, so the exact day that caused the failure trims by a
# small amount (proving the cap actually engages) while a normal, even fairly
# busy, day renders in full. Char count is used as a byte-count
# approximation (review text is ASCII-dominant); see shipreport_judgment_build.
SHIPREPORT_JUDGMENT_ITEM_MAX_CHARS="${SHIPREPORT_JUDGMENT_ITEM_MAX_CHARS:-8000}"
SHIPREPORT_JUDGMENT_SECTION_MAX_CHARS="${SHIPREPORT_JUDGMENT_SECTION_MAX_CHARS:-200000}"

# jq fragment: normalize .shipreport to today, resetting if the day rolled.
# shellcheck disable=SC2016  # $d is a jq --arg, not shell -- must not expand
SHIPREPORT_ROLL='(if (.shipreport.date // "") == $d then .shipreport
                  else {date:$d, sent:false, failures:0, last_attempt:0} end)'

# shipreport_sent_today -- exit 0 if today's report already went out (daily stamp
# under .shipreport, mirroring the sports digest's .sports).
shipreport_sent_today() {
  local sf today
  sf=$(_shipreport_state_file); [ -f "$sf" ] || return 1
  today=$(date +%F)
  [ "$(jq -r '.shipreport.date // ""' "$sf" 2>/dev/null)" = "$today" ] \
    && [ "$(jq -r '.shipreport.sent // false' "$sf" 2>/dev/null)" = "true" ]
}

# shipreport_mark_sent -- stamp today done (and implicitly clear today's
# failure count, since it replaces the whole day's record). Clear
# .shipreport to force a resend.
shipreport_mark_sent() {
  local sf tmp today
  sf=$(_shipreport_state_file); today=$(date +%F)
  [ -f "$sf" ] || echo '{}' > "$sf"
  tmp=$(mktemp)
  if jq --arg d "$today" '.shipreport = {date:$d, sent:true}' "$sf" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$sf"
  else
    rm -f "$tmp"
  fi
}

# shipreport_failures -- echo today's failed-send count (0 if unset or the
# day rolled). Read-only -- the cap that consumes it lives in
# do_shipreport_tick.
shipreport_failures() {
  local sf today n
  sf=$(_shipreport_state_file)
  [ -f "$sf" ] || { echo 0; return; }
  today=$(date +%F)
  n=$(jq -r --arg d "$today" \
    'if (.shipreport.date // "") == $d then (.shipreport.failures // 0) else 0 end' \
    "$sf" 2>/dev/null)
  [ -n "$n" ] && [ "$n" != "null" ] || n=0
  echo "$n"
}

# shipreport_mark_attempt -- stamp last_attempt=now (resetting on a day
# rollover). Called once per send attempt, before the Forgejo gathering --
# it's what the retry cooldown reads.
shipreport_mark_attempt() {
  local sf tmp today now
  sf=$(_shipreport_state_file); today=$(date +%F); now=$(date +%s)
  [ -f "$sf" ] || echo '{}' > "$sf"
  tmp=$(mktemp)
  if jq --arg d "$today" --argjson now "$now" \
      ".shipreport = ($SHIPREPORT_ROLL | .last_attempt = \$now)" \
      "$sf" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$sf"
  else
    rm -f "$tmp"
  fi
}

# shipreport_retry_ready -- true when it's OK to attempt the send again
# today: either no attempt yet, or the cooldown since the last attempt has
# elapsed.
shipreport_retry_ready() {
  local sf today last now
  sf=$(_shipreport_state_file)
  [ -f "$sf" ] || return 0
  today=$(date +%F)
  last=$(jq -r --arg d "$today" \
    'if (.shipreport.date // "") == $d then (.shipreport.last_attempt // 0) else 0 end' \
    "$sf" 2>/dev/null)
  [ -n "$last" ] && [ "$last" != "null" ] || last=0
  now=$(date +%s)
  [ "$((now - last))" -ge "$SHIPREPORT_RETRY_COOLDOWN_SECS" ]
}

# shipreport_failure_inc -- bump today's failed-send count and echo the new
# value. Deliberately does NOT touch `sent` -- a failed send must stay
# retryable until do_shipreport_tick's cap gives up for the day.
shipreport_failure_inc() {
  local sf tmp today n
  sf=$(_shipreport_state_file); today=$(date +%F)
  [ -f "$sf" ] || echo '{}' > "$sf"
  tmp=$(mktemp)
  if jq --arg d "$today" ".shipreport = ($SHIPREPORT_ROLL | .failures += 1)" \
      "$sf" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$sf"
  else
    rm -f "$tmp"
  fi
  n=$(jq -r '.shipreport.failures' "$sf" 2>/dev/null)
  [ -n "$n" ] && [ "$n" != "null" ] || n=0
  echo "$n"
}

# shipreport_landed_read -- echoes the JSON array of landed-verification
# notes queued by lib/landed.sh's landed_note_queue (or "[]" if none/the
# state file is missing). Read-only; pair with shipreport_landed_clear once
# a report actually goes out.
shipreport_landed_read() {
  local sf; sf=$(_shipreport_state_file)
  [ -f "$sf" ] || { printf '[]'; return 0; }
  jq -c '.landed_notes // []' "$sf" 2>/dev/null || printf '[]'
}

# shipreport_landed_clear -- drop the drained landed notes. Call only once
# a report carrying them has actually been assembled for sending -- this is
# the "drain" half of the igor#512 landed-verification companion to the
# deploy barrier.
shipreport_landed_clear() {
  local sf tmp; sf=$(_shipreport_state_file); [ -f "$sf" ] || return 0
  tmp=$(mktemp)
  if jq '.landed_notes = []' "$sf" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$sf"
  else
    rm -f "$tmp"
  fi
}

# shipreport_merge_landed <report_json> <landed_json> -- adds a `landed`
# bucket to an already-built report. Kept separate from shipreport_build
# (which only knows about Forgejo PR items) so callers that never touch
# landed notes -- including every existing caller of shipreport_build --
# get a report with no `landed` key at all, and the renderers below treat
# that as "omit the section" rather than "empty section". do_shipreport_tick
# skips the merge on an empty queue for that same reason.
shipreport_merge_landed() {
  local report="$1" landed="$2"
  jq -c --argjson l "${landed:-[]}" '. + {landed: $l}' <<<"$report" 2>/dev/null || printf '%s' "$report"
}

# shipreport_build -- reads a JSON array of per-PR items on stdin and buckets them.
# Item shape:
#   {repo, number, title, url, state:"merged"|"open", gate:"shadow"|"human"|"",
#    require_human:bool}
# Buckets:
#   needs_you : open PRs on a require_human (carve-out) repo -- your review gates.
#   shipped   : merged PRs (gate-tagged shadow/human).
#   inflight  : open PRs on a default (shadow-gated) repo -- the loop's working them.
shipreport_build() {
  jq -c '{
    needs_you: [ .[] | select(.state == "open"   and .require_human == true) ],
    shipped:   [ .[] | select(.state == "merged") ],
    inflight:  [ .[] | select(.state == "open"   and (.require_human != true)) ]
  }'
}

# shipreport_is_empty <report_json> -- exit 0 if every bucket is empty,
# including `landed` when the caller merged one in (shipreport_merge_landed)
# -- a report with landed-verification notes and nothing else is NOT empty.
# Also NOT empty (igor#612) when the caller merged in a metrics section that
# actually has cost or tick-timing data, or a Claude Code version check that
# came back behind -- a quiet PR day still gets the spend/timing visibility
# Josh asked for, rather than the whole report vanishing on the days with
# nothing else to say. Both conditions default to "absent" via `// false`,
# so a report that never called shipreport_metrics_build (every existing
# caller, and every existing test) behaves exactly as before.
shipreport_is_empty() {
  [ "$(jq -r '
    (([.needs_you, .shipped, .inflight, (.landed // [])] | map(length) | add) == 0)
    and ((.metrics.cost.now.has_data // false) | not)
    and ((.metrics.timing.now.has_data // false) | not)
    and ((.claude_version.behind // false) | not)
  ' <<<"$1" 2>/dev/null)" = "true" ]
}

# shipreport_metrics_build <cost_now> <cost_prev> <timing_now> <timing_prev> <claude_version>
# igor#612: "times and costs shown in aggregate so we can check if there's a
# change." Bundles the current-window cost/tick-timing summaries (from
# lib/cost.sh's cost_ledger_summary / lib/tick-timing.sh's
# tick_timing_summary) with the prior-period equivalents for a delta, plus
# the Claude Code version check (lib/claude-version.sh). Pure merge, no
# gathering -- same split as shipreport_build vs. do_shipreport_tick's
# Forgejo gathering, so this stays unit-testable off fixtures. Merge the
# result into a report with `jq '. + $that'` -- it emits BOTH the `metrics`
# and `claude_version` top-level keys the renderers below look for.
shipreport_metrics_build() {
  local cost_now="$1" cost_prev="$2" timing_now="$3" timing_prev="$4" claude_version="$5"
  jq -cn \
    --argjson cn "$cost_now" --argjson cp "$cost_prev" \
    --argjson tn "$timing_now" --argjson tp "$timing_prev" \
    --argjson cv "$claude_version" \
    '{
       metrics: {
         cost: { now: $cn, prev: $cp,
                 delta_usd: (if $cn.has_data and $cp.has_data
                             then ((($cn.total_usd - $cp.total_usd) * 100 | round) / 100)
                             else null end) },
         timing: { now: $tn, prev: $tp,
                   delta_median_s: (if $tn.has_data and $tp.has_data
                                    then ($tn.median_s - $tp.median_s) else null end) }
       },
       claude_version: $cv
     }'
}

# shipreport_judgment_build <judgment_json>
# igor#610: 46.7% of review verdicts across the fleet are COMMENT -- the
# plurality outcome, and the one that carries "needs your judgment" items
# without blocking or triggering rework. Under auto-merge that content ships
# unread. This wraps a pre-gathered array of per-PR judgment-item groups
# (shape: [{repo, number, title, url, items: [...]}], one entry per merged
# PR that has at least one item left by review_corpus_judgment_items,
# lib/review-corpus.sh) into the `judgment_items` key merged onto a report.
#
# Pure merge, same split as shipreport_metrics_build: the Forgejo gathering
# (fetching each merged PR's comment thread and running
# review_corpus_judgment_items over it) lives in do_shipreport_tick, so this
# stays unit-testable off fixtures.
#
# Unlike `landed`/`metrics` (optional bonus sections omitted when the caller
# never merges them in), the renderers below treat `judgment_items` as a
# MANDATORY section -- defaulting a missing key to `[]` and always printing
# it, empty or not. The issue this closes is explicitly that silence here
# must never be ambiguous between "nothing unresolved" and "the extraction
# broke," so do_shipreport_tick always calls this, never skips the merge.
#
# igor#635: also bounds the section's size -- per-item first, then greedy
# packing of whole PR entries into SHIPREPORT_JUDGMENT_SECTION_MAX_CHARS. An
# entry that doesn't fit is dropped WHOLE and the walk continues, so a later
# smaller entry is still kept and no entry is ever shown half-rendered. Every
# trim is tallied into `judgment_trim` and rendered as an explicit notice --
# the issue's rule is that a silent truncation is worse than a large report.
# The pass-1 tally counts only items that survived pass 2, so an item that was
# shortened and then dropped with its entry is reported once, as omitted.
shipreport_judgment_build() {
  local judgment_json="${1:-[]}"
  local item_max="${SHIPREPORT_JUDGMENT_ITEM_MAX_CHARS}" section_max="${SHIPREPORT_JUDGMENT_SECTION_MAX_CHARS}"
  # igor#635: the array itself can carry the same >223 KB of raw comment
  # text this whole issue is about -- --argjson would put it on jq's OWN
  # argv (the same ARG_MAX cliff as curl's -d, one step upstream of it).
  # --slurpfile instead takes a file PATH on argv and reads the content via
  # a read(), same fix as email.sh's --rawfile for the html/text bodies.
  local judgment_file; judgment_file=$(mktemp)
  printf '%s' "${judgment_json:-[]}" >"$judgment_file"
  local out rc=0
  out=$(jq -cn --slurpfile jarr "$judgment_file" --argjson imax "$item_max" --argjson smax "$section_max" '
    def trunc_item($imax):
      (.body | length) as $blen
      | if $blen > $imax then
          .body = (.body[0:$imax] + "\n... [truncated, " + (($blen - $imax) | tostring) + " more char(s) -- see the PR thread]")
          | .truncated_bytes = ($blen - $imax)
        else . end;

    ($jarr[0] | map(.items = ((.items // []) | map(trunc_item($imax))))) as $capped
    | (reduce $capped[] as $pr (
        {kept: [], budget: $smax, entries_omitted: 0, items_omitted: 0, bytes_omitted: 0};
        ( [ $pr.items[] | (.body | length) ] | add // 0 ) as $prlen
        | if $prlen <= .budget then
            .kept += [$pr] | .budget -= $prlen
          else
            .entries_omitted += 1
            | .items_omitted += ($pr.items | length)
            | .bytes_omitted += $prlen
          end
      )) as $r
    | {
        judgment_items: [ $r.kept[] | .items |= map(del(.truncated_bytes)) ],
        judgment_trim: {
          entries_omitted: $r.entries_omitted,
          items_omitted: $r.items_omitted,
          bytes_omitted: $r.bytes_omitted,
          items_truncated: ([$r.kept[].items[] | select(.truncated_bytes != null)] | length),
          bytes_truncated: ([$r.kept[].items[] | (.truncated_bytes // 0)] | add // 0)
        }
      }
  ') || rc=$?
  rm -f "$judgment_file"
  # The temp file is cleaned up before the status is handed back, but the
  # status IS jq's, not rm's -- a malformed judgment_json has to reach the
  # caller as a failure. Silence here must never read as "nothing unresolved".
  printf '%s' "$out"
  return "$rc"
}

# shipreport_merge_judgment <report_json> <judgment_json> -- folds
# shipreport_judgment_build's output onto an already-built report.
#
# igor#635: this exists only because of the argv ceiling. `--argjson j
# "$judgment"` cannot exec once the judgment object passes Linux's
# MAX_ARG_STRLEN -- 32 pages, 131072 bytes, a PER-ARGUMENT limit far below
# `getconf ARG_MAX` (2 MB here) -- and SHIPREPORT_JUDGMENT_SECTION_MAX_CHARS
# deliberately allows 200000, so the merge would die on exactly the busy day
# the section is worth reading. Both documents go on jq's stdin instead, so
# neither is ever an argv entry at any size.
#
# Unlike shipreport_merge_landed above, there is NO fallback to the unmerged
# report: a dropped `judgment_items` key renders as an empty section, which
# reads as "nothing unresolved" -- the ambiguity igor#610 exists to prevent.
# A failed merge (either side unparseable, empty, or not an object) returns
# nonzero for the caller to log. Both guards exist because jq treats null as
# the identity for `+`: the length check catches a side that is missing
# entirely, the type check a side that parsed to a literal `null` (or any
# non-object) -- either would otherwise merge to the report unchanged and
# report success.
shipreport_merge_judgment() {
  printf '%s\n%s\n' "${1:-}" "${2:-}" \
    | jq -cs 'if length == 2 and all(.[]; type == "object") then .[0] + .[1]
              else error("judgment merge expected 2 JSON objects, got \(length) document(s): \([.[] | type] | join(", "))") end'
}

# shipreport_mark_judgment_error <report_json> -- flag a report whose judgment
# section could not be built or merged, so the EMAIL says so. Without it the
# failure renders identically to a clean day ("no unresolved judgment items")
# and only the harness log tells the two apart -- which puts the igor#610
# ambiguity right back, in the one place the human actually reads.
shipreport_mark_judgment_error() {
  jq -c '. + {judgment_error: true}' <<<"${1:-}"
}

# Shared jq defs for the metrics/version renderers below.
_SHIPREPORT_FMT_DEFS='
  def fabs: if . < 0 then -. else . end;
  def fmt_usd: if . == null then "?" else
      ((. * 100) | round | fabs) as $c
      | (($c / 100) | floor | tostring) + "."
        + (($c % 100 | tostring) | if length < 2 then "0" + . else . end)
    end;
  def fmt_dur: if . == null then "?" else
      (. as $s | ($s|floor) as $secs
       | if $secs < 60 then "\($secs)s"
         else "\($secs/60|floor)m\($secs%60)s" end)
    end;
'

# _shipreport_metrics_lines <report_json on stdin> -- one line per array
# element (jq -r on a multi-value filter), empty output when the report
# never merged in a `metrics` key (a plain PR-only report).
_shipreport_metrics_lines() {
  jq -r "$_SHIPREPORT_FMT_DEFS"'
    if has("metrics") then
      "-- COST & TIMING (24h) --",
      (if .metrics.cost.now.has_data then
         "  spend: $" + (.metrics.cost.now.total_usd|fmt_usd)
         + (if .metrics.cost.delta_usd == null then " (no prior-period data to compare)"
            else (if .metrics.cost.delta_usd >= 0 then " (+$" else " (-$" end)
                 + ((.metrics.cost.delta_usd|fabs)|fmt_usd) + " vs prior 24h)" end)
       else "  no cost data recorded" end),
      (.metrics.cost.now.by_site[]? | "    " + .site + ": $" + (.usd|fmt_usd)),
      (if .metrics.timing.now.has_data then
         "  ticks: " + (.metrics.timing.now.count|tostring)
         + " (median " + (.metrics.timing.now.median_s|fmt_dur)
         + ", p90 " + (.metrics.timing.now.p90_s|fmt_dur)
         + ", longest " + (.metrics.timing.now.max_s|fmt_dur) + ")"
         + (if .metrics.timing.delta_median_s == null then ""
            else (if .metrics.timing.delta_median_s >= 0 then " (median +" else " (median -" end)
                 + ((.metrics.timing.delta_median_s|fabs)|fmt_dur) + " vs prior 24h)" end)
       else "  no tick-timing data recorded" end)
    else empty end
  '
}

# _shipreport_claude_version_line <report_json on stdin> -- one line, or
# empty when the report never merged in a `claude_version` key. Shouts
# (BEHIND) only when actually behind; a matching version gets one quiet
# line; a failed registry lookup says so explicitly rather than going dark
# (igor#612: "a version check that silently stops is this whole ticket
# happening again").
_shipreport_claude_version_line() {
  jq -r '
    if has("claude_version") then
      (if .claude_version.checked_ok then
         (if .claude_version.behind then
            "Claude Code: " + .claude_version.installed + " -- BEHIND latest " + .claude_version.latest
              + (if .claude_version.since_days != null
                 then " (unchanged " + (.claude_version.since_days|tostring) + "d)" else "" end)
          else
            "Claude Code: " + .claude_version.installed + " (up to date)"
          end)
       else
         "Claude Code: could not check (installed " + (.claude_version.installed // "unknown") + ")"
       end)
    else empty end
  '
}

# _shipreport_judgment_lines <report_json on stdin> -- the body of the
# JUDGMENT ITEMS section, one line per row. Grouped by repo (`group_by`
# rather than relying on gather order, so the section reads the same
# regardless of how do_shipreport_tick walked ANALYSIS_REPOS_JSON). The
# `// []` default on a missing key is what makes the section mandatory --
# see shipreport_judgment_build.
_shipreport_judgment_lines() {
  jq -r '
    (.judgment_items // []) as $j
    | if (.judgment_error // false) then
        "  ERROR: this section could not be built -- read it as UNKNOWN, not as \"nothing unresolved\". The harness log has the failure."
      elif ($j | length) == 0 then
        "  (no unresolved judgment items)"
      else
        ( $j | group_by(.repo)[] | .[] |
          "  * \(.repo)#\(.number)  \(.title)",
          "    \(.url)",
          ( .items[] |
            "    [\(if .verdict then .verdict else "dismissed" end)] \(if .comment_url == "" then "(no direct link)" else .comment_url end)",
            ( .body | split("\n") | map("      " + .) | join("\n") )
          )
        )
      end
  '
}

# _shipreport_judgment_trim_note <report_json on stdin> -- one line, or empty
# when shipreport_judgment_build did no trimming (or the report never
# merged in a `judgment_trim` key, e.g. every existing test fixture). Names
# a count and a size for both trim passes -- see shipreport_judgment_build.
_shipreport_judgment_trim_note() {
  jq -r '
    (.judgment_trim // {entries_omitted:0, items_omitted:0, bytes_omitted:0, items_truncated:0, bytes_truncated:0}) as $t
    | [
        (if $t.entries_omitted > 0 then
           "\($t.entries_omitted) PR(s) / \($t.items_omitted) item(s) omitted (~\(($t.bytes_omitted/1000)|round) KB) -- see the PR threads directly"
         else empty end),
        (if $t.items_truncated > 0 then
           "\($t.items_truncated) item body/bodies shortened (~\(($t.bytes_truncated/1000)|round) KB removed)"
         else empty end)
      ] as $parts
    | if ($parts | length) == 0 then empty
      else "  NOTE: " + ($parts | join("; ")) + " to keep this email a reasonable size."
      end
  '
}

# shipreport_render_text <report_json on stdin> -- plain-text email body (ASCII).
shipreport_render_text() {
  local r; r=$(cat)
  printf 'FLEET SHIP REPORT -- %s\n' "$(date +%F)"
  printf '=================================\n\n'

  printf -- '-- NEEDS YOU (%s) --\n' "$(jq -r '.needs_you | length' <<<"$r")"
  if [ "$(jq -r '.needs_you | length' <<<"$r")" = "0" ]; then
    printf '  (nothing awaiting your review)\n'
  else
    jq -r '.needs_you[] | "  * \(.repo)#\(.number)  \(.title)\n    \(.url)"' <<<"$r"
  fi
  printf '\n'

  printf -- '-- SHIPPED, last 24h (%s) --\n' "$(jq -r '.shipped | length' <<<"$r")"
  if [ "$(jq -r '.shipped | length' <<<"$r")" = "0" ]; then
    printf '  (nothing shipped)\n'
  else
    jq -r '.shipped[] | "  [\(if .gate == "human" then "you" else "shadow" end)]  \(.repo)#\(.number)  \(.title)"' <<<"$r"
  fi
  printf '\n'

  # igor#610: printed unconditionally, unlike LANDED/metrics below (see
  # shipreport_judgment_build).
  local jcount jn
  jcount=$(jq -r '[(.judgment_items // [])[].items[]?] | length' <<<"$r")
  jn=$(jq -r '.judgment_items // [] | length' <<<"$r")
  printf -- '-- JUDGMENT ITEMS, unresolved (%s PR(s), %s item(s)) --\n' "$jn" "$jcount"
  _shipreport_judgment_lines <<<"$r"
  local trim_note; trim_note=$(_shipreport_judgment_trim_note <<<"$r")
  if [ -n "$trim_note" ]; then
    printf '%s\n' "$trim_note"
  fi
  printf '\n'

  printf -- '-- IN FLIGHT (%s) --\n' "$(jq -r '.inflight | length' <<<"$r")"
  if [ "$(jq -r '.inflight | length' <<<"$r")" = "0" ]; then
    printf '  (nothing in flight)\n'
  else
    jq -r '.inflight[] | "  * \(.repo)#\(.number)  \(.title)"' <<<"$r"
  fi
  printf '\n'

  if jq -e 'has("landed")' <<<"$r" >/dev/null 2>&1; then
    printf -- '-- LANDED (%s) --\n' "$(jq -r '.landed | length' <<<"$r")"
    if [ "$(jq -r '.landed | length' <<<"$r")" = "0" ]; then
      printf '  (nothing landed)\n'
    else
      jq -r '.landed[] | "  * \(.repo)#\(.pr)  \(.sha[0:8])  \(.detail)"' <<<"$r"
    fi
    printf '\n'
  fi

  # Cost + tick-timing (igor#612): omitted entirely for a report that never
  # merged in a `metrics` key (a plain PR report, e.g. every existing test).
  local metrics_lines; metrics_lines=$(_shipreport_metrics_lines <<<"$r")
  if [ -n "$metrics_lines" ]; then
    printf '%s\n\n' "$metrics_lines"
  fi
  local version_line; version_line=$(_shipreport_claude_version_line <<<"$r")
  if [ -n "$version_line" ]; then
    printf '%s\n\n' "$version_line"
  fi

  printf -- '---\nDeploy failures are alerted separately, in real time, by the deploy barrier.\n'
}

# shipreport_render_html <report_json on stdin> -- html email body.
shipreport_render_html() {
  local r; r=$(cat)
  local wrap='font-family:-apple-system,Segoe UI,sans-serif;color:#222'
  printf '<div style="%s">' "$wrap"
  printf '<h2 style="margin:0 0 4px">Fleet Ship Report</h2>'
  printf '<p style="color:#888;margin:0 0 16px">%s</p>' "$(date +%F)"

  # Needs you
  printf '<h3 style="border-bottom:1px solid #eee;padding-bottom:4px">&#128276; Needs you (%s)</h3>' \
    "$(jq -r '.needs_you | length' <<<"$r")"
  local ny
  ny=$(jq -r '.needs_you[] | "<li><a href=\"\(.url)\">\(.repo)#\(.number)</a> &mdash; \(.title|@html)</li>"' <<<"$r")
  if [ -n "$ny" ]; then printf '<ul>%s</ul>' "$ny"; else printf '<p style="color:#888"><em>nothing awaiting your review</em></p>'; fi

  # Shipped
  printf '<h3 style="border-bottom:1px solid #eee;padding-bottom:4px">&#128230; Shipped, last 24h (%s)</h3>' \
    "$(jq -r '.shipped | length' <<<"$r")"
  local sh
  sh=$(jq -r '.shipped[] | "<li>\(if .gate=="human" then "&#128100; you" else "&#129302; shadow" end) &nbsp; <a href=\"\(.url)\"><strong>\(.repo)#\(.number)</strong></a> &mdash; \(.title|@html)</li>"' <<<"$r")
  if [ -n "$sh" ]; then printf '<ul>%s</ul>' "$sh"; else printf '<p style="color:#888"><em>nothing shipped</em></p>'; fi

  # In flight
  printf '<h3 style="border-bottom:1px solid #eee;padding-bottom:4px">&#128640; In flight (%s)</h3>' \
    "$(jq -r '.inflight | length' <<<"$r")"
  local inf
  inf=$(jq -r '.inflight[] | "<li><a href=\"\(.url)\">\(.repo)#\(.number)</a> &mdash; \(.title|@html)</li>"' <<<"$r")
  if [ -n "$inf" ]; then printf '<ul>%s</ul>' "$inf"; else printf '<p style="color:#888"><em>nothing in flight</em></p>'; fi

  # Judgment items (igor#610): rendered unconditionally, unlike
  # Landed/metrics below (see shipreport_judgment_build).
  local jcount jn
  jcount=$(jq -r '[(.judgment_items // [])[].items[]?] | length' <<<"$r")
  jn=$(jq -r '.judgment_items // [] | length' <<<"$r")
  printf '<h3 style="border-bottom:1px solid #eee;padding-bottom:4px">&#9878; Judgment items, unresolved (%s PR(s), %s item(s))</h3>' \
    "$jn" "$jcount"
  local ji
  ji=$(jq -r '
    (.judgment_items // []) | group_by(.repo)[] | .[] |
    "<li><a href=\"\(.url|@html)\"><strong>\(.repo)#\(.number)</strong></a> &mdash; \(.title|@html)"
    + ( [ .items[] |
          "<div style=\"margin:4px 0 8px 16px\"><strong>[" + (if .verdict then .verdict else "dismissed" end) + "]</strong> "
          + (if .comment_url == "" then "(no direct link)" else "<a href=\"" + (.comment_url|@html) + "\">source</a>" end)
          + "<pre style=\"white-space:pre-wrap;font-family:inherit;font-size:13px;margin:4px 0\">" + (.body|@html) + "</pre></div>"
        ] | join("") )
    + "</li>"
  ' <<<"$r")
  # Error branch first, matching _shipreport_judgment_lines: the flag means
  # "do not trust this section", which outranks showing whatever survived.
  if jq -e '.judgment_error // false' <<<"$r" >/dev/null 2>&1; then
    printf '<p style="color:#b00"><strong>ERROR:</strong> this section could not be built &mdash; read it as UNKNOWN, not as &ldquo;nothing unresolved&rdquo;. The harness log has the failure.</p>'
  elif [ -n "$ji" ]; then printf '<ul>%s</ul>' "$ji"
  else printf '<p style="color:#888"><em>no unresolved judgment items</em></p>'; fi
  local trim_note; trim_note=$(_shipreport_judgment_trim_note <<<"$r")
  if [ -n "$trim_note" ]; then
    printf '<p style="color:#888;font-size:13px">%s</p>' "$(printf '%s' "$trim_note" | sed 's/^  //')"
  fi

  # Landed (igor#512): only shown when the caller merged one in via
  # shipreport_merge_landed -- omitted entirely for a plain PR report.
  if jq -e 'has("landed")' <<<"$r" >/dev/null 2>&1; then
    printf '<h3 style="border-bottom:1px solid #eee;padding-bottom:4px">&#127775; Landed (%s)</h3>' \
      "$(jq -r '.landed | length' <<<"$r")"
    local ld
    ld=$(jq -r '.landed[] | "<li><strong>\(.repo)#\(.pr)</strong> \(.sha[0:8]) &mdash; \(.detail|@html)</li>"' <<<"$r")
    if [ -n "$ld" ]; then printf '<ul>%s</ul>' "$ld"; else printf '<p style="color:#888"><em>nothing landed</em></p>'; fi
  fi

  # Cost + tick-timing (igor#612): reuses the same line generator as
  # shipreport_render_text (one source of truth for the numbers), wrapped
  # in <pre> for the email. Omitted for a report that never merged in a
  # `metrics` key.
  local metrics_lines; metrics_lines=$(_shipreport_metrics_lines <<<"$r")
  if [ -n "$metrics_lines" ]; then
    printf '<pre style="white-space:pre-wrap;font-family:inherit;font-size:14px;margin:16px 0 0">%s</pre>' "$metrics_lines"
  fi
  local version_line; version_line=$(_shipreport_claude_version_line <<<"$r")
  if [ -n "$version_line" ]; then
    printf '<p style="color:#888;font-size:13px;margin:8px 0 0">%s</p>' "$version_line"
  fi

  printf '<hr style="border:none;border-top:1px solid #eee;margin:16px 0"><p style="color:#888;font-size:13px">Deploy failures are alerted separately, in real time, by the deploy barrier.</p>'
  printf '</div>'
}
