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

# Fallback logger so this module is sourceable standalone (tests).
if ! declare -F log >/dev/null; then log() { printf '[agent] %s\n' "$*" >&2; }; fi

_shipreport_state_file() { echo "${AGENT_STATE_DIR:-$HOME/.local/state/agent}/discretionary-state.json"; }

# shipreport_sent_today -- exit 0 if today's report already went out (daily stamp
# under .shipreport, mirroring the sports digest's .sports).
shipreport_sent_today() {
  local sf today
  sf=$(_shipreport_state_file); [ -f "$sf" ] || return 1
  today=$(date +%F)
  [ "$(jq -r '.shipreport.date // ""' "$sf" 2>/dev/null)" = "$today" ] \
    && [ "$(jq -r '.shipreport.sent // false' "$sf" 2>/dev/null)" = "true" ]
}

# shipreport_mark_sent -- stamp today done. Clear .shipreport to force a resend.
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

# Shared jq defs for the metrics/version renderers below.
_SHIPREPORT_FMT_DEFS='
  def fabs: if . < 0 then -. else . end;
  def fmt_usd: if . == null then "?" else (. as $v | (($v*100|round)/100) | tostring) end;
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
