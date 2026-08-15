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
# that as "omit the section" rather than "empty section".
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
shipreport_is_empty() {
  [ "$(jq -r '[.needs_you, .shipped, .inflight, (.landed // [])] | map(length) | add // 0' <<<"$1" 2>/dev/null)" = "0" ]
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

  printf '<hr style="border:none;border-top:1px solid #eee;margin:16px 0"><p style="color:#888;font-size:13px">Deploy failures are alerted separately, in real time, by the deploy barrier.</p>'
  printf '</div>'
}
