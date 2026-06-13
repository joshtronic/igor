#!/usr/bin/env bash
# sports-digest.sh -- pure functions for the daily sports-tutor digest:
# prompt assembly, response parsing, markdown->HTML rendering, and the
# taught-concepts curriculum ledger. No network (lib/espn.sh fetches;
# tick.sh makes the model call) so the logic is unit-testable with
# fixtures, mirroring lib/market-report.sh.
#
# The digest's purpose is education: each email teaches the reader a
# few new sports concepts off the back of yesterday's news, building on
# everything already taught. The ledger is what makes "building on"
# real across days.
#
# Requires on PATH: jq, sed, awk.

# Fallback logger so this module is sourceable standalone (tests).
if ! declare -F log >/dev/null; then
  log() { printf '[agent] %s\n' "$*"; }
fi

# The curriculum ledger -- deliberately a SEPARATE file from
# discretionary-state.json: clearing the .sports day-state to force a
# re-send must never wipe what the reader has already been taught.
# Shape: { concepts: [ {name, date}, ... ] }, newest last.
sports_curriculum_file() {
  printf '%s/sports-curriculum.json' \
    "${AGENT_STATE_DIR:-$HOME/.local/state/agent}"
}

# sports_concepts_load
# Echoes the taught-concept names as a JSON array of strings (oldest
# first). Empty array if the ledger doesn't exist yet (first run).
sports_concepts_load() {
  local f; f=$(sports_curriculum_file)
  [ -f "$f" ] || { printf '[]'; return 0; }
  jq -c '[.concepts[]?.name] // []' "$f" 2>/dev/null || printf '[]'
}

# sports_concepts_append <names_json_array> <date>
# Appends new concepts to the ledger, stamped with the digest date.
# Dedupes case-insensitively against what's already taught, then caps
# the ledger at the newest 300 -- by then the oldest entries are
# either internalized or worth re-teaching anyway.
sports_concepts_append() {
  local names="$1" date="$2" f tmp
  f=$(sports_curriculum_file)
  [ -f "$f" ] || printf '{"concepts":[]}' > "$f"
  tmp=$(mktemp)
  jq --argjson new "$names" --arg d "$date" '
    (.concepts // []) as $had
    | ($had | map(.name | ascii_downcase)) as $seen
    | .concepts = (($had + ($new
        | map(gsub("^\\s+|\\s+$";"")) | map(select(length>0))
        | map(select((ascii_downcase) as $n | ($seen | index($n)) | not))
        | unique_by(ascii_downcase)
        | map({name:., date:$d})))[-300:])
  ' "$f" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$f"
}

# sports_build_prompt <slim_payload_json> <covered_json_array> <date>
# Assembles the user prompt for the distill call: the digest date, the
# already-taught concept list, and the per-league payloads from
# lib/espn.sh. The system prompt (persona, curation rule, output
# contract) lives in bin/lib/sports-digest-directive.md.
sports_build_prompt() {
  local payload="$1" covered="$2" date="$3" covered_lines
  covered_lines=$(jq -r '.[]? | "- " + .' <<<"$covered" 2>/dev/null)
  printf 'Digest date: this email covers %s (yesterday).

## Concepts already taught in previous digests

Build on these -- reference them freely, do NOT re-explain them.

%s

## League payloads (JSON)

One object per configured league. events are yesterday'\''s
games/sessions; headlines are current ESPN stories with real links.

%s' "$date" "${covered_lines:-(none yet -- this is the first digest; start from zero)}" "$payload"
}

# sports_parse_response <raw>
# Parses the model's label-line + sentinel response (never
# model-written JSON -- a hand-built JSON envelope around a long
# markdown body is exactly the fragility this repo has been burned
# by):
#
#   CONCEPTS: name; name; name
#   ===BODY===
#   <markdown digest>
#
# Echoes harness-built JSON {concepts:[...], body:"..."} on stdout;
# rc=1 when the sentinel or body is missing (caller retries).
sports_parse_response() {
  local raw="$1" head body concepts_line
  case "$raw" in
    *'===BODY==='*) ;;
    *) return 1 ;;
  esac
  head="${raw%%===BODY===*}"
  body="${raw#*===BODY===}"
  printf '%s' "$body" | grep -q '[^[:space:]]' || return 1
  # Trim blank lines off both ends (interior blanks survive): skip
  # until the first non-blank, then buffer blanks and flush them only
  # when another non-blank follows.
  body=$(printf '%s\n' "$body" | awk '
    NF { if (started) for (i = 0; i < blanks; i++) print ""
         blanks = 0; started = 1; print; next }
    started { blanks++ }')
  concepts_line=$(printf '%s' "$head" | sed -n 's/^CONCEPTS:[[:space:]]*//p' | head -1)
  jq -n --arg c "$concepts_line" --arg b "$body" '{
    concepts: ($c | split(";") | map(gsub("^\\s+|\\s+$";"")) | map(select(length>0))),
    body: $b
  }'
}

# sports_render_html <<< <markdown>
# Deliberately MINIMAL markdown->HTML for the email's html part (the
# raw markdown ships as the text/plain part, like the market report's
# table). Covers exactly what the directive allows the model to emit:
# #/##/### headings, **bold**, [links](url), "- " bullet lists, ---
# rules, paragraphs. Anything else passes through escaped as text.
sports_render_html() {
  # Escape first so model text can't inject HTML, then rewrite the
  # markdown inline spans, then let awk handle block structure.
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
    | sed -E \
        -e 's|\*\*([^*]+)\*\*|<strong>\1</strong>|g' \
        -e 's|\[([^]]+)\]\(([^)]+)\)|<a href="\2">\1</a>|g' \
    | awk '
      function close_para() { if (inp) { print "</p>"; inp = 0 } }
      function close_list() { if (inl) { print "</ul>"; inl = 0 } }
      /^### /  { close_para(); close_list(); print "<h4>" substr($0, 5) "</h4>"; next }
      /^## /   { close_para(); close_list(); print "<h3>" substr($0, 4) "</h3>"; next }
      /^# /    { close_para(); close_list(); print "<h2>" substr($0, 3) "</h2>"; next }
      /^---+$/ { close_para(); close_list(); print "<hr>"; next }
      /^- /    { close_para(); if (!inl) { print "<ul>"; inl = 1 }
                 print "<li>" substr($0, 3) "</li>"; next }
      /^[[:space:]]*$/ { close_para(); close_list(); next }
      { close_list(); if (!inp) { print "<p>"; inp = 1 } print }
      END { close_para(); close_list() }
    '
}
