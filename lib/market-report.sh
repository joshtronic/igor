#!/usr/bin/env bash
# market-report.sh -- turn raw marketstack EOD rows into the daily
# high/low report object and render it for email. Pure functions over
# JSON (no network -- lib/marketstack.sh does the fetching) so the logic
# is unit-testable with fixtures, mirroring lib/seo-analysis.sh.
#
# Deliberately NO LLM: the report is a flat lookup (previous trading
# day's high and low per symbol), so every line is deterministic and
# cheap. Kept intentionally simple -- one report, one table -- until
# there's a reason for more.
#
# Requires on PATH: jq.

# Fallback logger so this module is sourceable standalone (tests).
if ! declare -F log >/dev/null; then
  log() { printf '[agent] %s\n' "$*"; }
fi

# market_build_report <eod_json> <symbols_csv>
# Shapes the marketstack response into a single report object:
#   { session_date, count, rows:[{symbol,high,low,date}], missing:[...] }
# session_date is the latest bar date present (the "previous trading
# day"). rows are sorted by symbol. missing lists requested symbols
# marketstack returned no bar for (typo, delisted, not-on-plan) --
# surfaced so a silent gap reads as a gap, not a clean report. Symbols
# are compared upper-cased so request/response casing can't drop a row.
market_build_report() {
  local eod="$1" symbols="$2"
  local rows
  rows=$(jq -c '.data // []' <<<"$eod" 2>/dev/null || printf '[]')
  jq -n --argjson data "$rows" --arg syms "$symbols" '
    ($syms | split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length>0))
      | map(ascii_upcase)) as $req
    | ($data | map({ symbol:(.symbol|ascii_upcase), high:.high, low:.low,
                     date:((.date // "") | split("T")[0]) })) as $rows
    | ($rows | map(.symbol)) as $present
    | {
        session_date: ($rows | map(.date) | max // null),
        count: ($rows | length),
        rows: ($rows | sort_by(.symbol)),
        missing: ($req | map(select(. as $s | ($present | index($s)) | not)))
      }' 2>/dev/null || printf '{"session_date":null,"count":0,"rows":[],"missing":[]}'
}

# Shared jq prelude: format a price to a fixed 2 decimals (cents-exact,
# no float artifacts), "n/a" for a missing value.
# shellcheck disable=SC2016  # $c/$whole/$cents are jq vars, not shell -- must not expand
MARKET_FMT_DEF='
  def money(v):
    if v == null then "n/a"
    else (v * 100 | round) as $c
      | ($c / 100 | floor) as $whole
      | ($c % 100) as $cents
      | "\($whole).\(if $cents < 10 then "0" else "" end)\($cents)"
    end;'

# market_render_markdown <report_json>
# Markdown body -- doubles as the email text/plain part (a markdown table
# reads fine as plain text).
market_render_markdown() {
  jq -r "$MARKET_FMT_DEF"'
    "# Market report — \(.session_date // "no session data")\n",
    "Previous trading day high / low.\n",
    "| Symbol | High | Low |",
    "| --- | ---: | ---: |",
    (.rows[] | "| \(.symbol) | \(money(.high)) | \(money(.low)) |"),
    (if (.missing | length) > 0 then
      "\n> No data returned for: \(.missing | join(", "))"
     else empty end),
    "\n---",
    "_Automated daily market report (marketstack EOD). Symbols via MARKET_SYMBOLS._"
  '
}

# market_render_html <report_json>
market_render_html() {
  jq -r "$MARKET_FMT_DEF"'
    def esc: @html;
    "<h2>Market report — \(.session_date // "no session data" | esc)</h2>",
    "<p>Previous trading day high / low.</p>",
    "<table cellpadding=\"6\" style=\"border-collapse:collapse\">",
    "<thead><tr><th align=\"left\">Symbol</th><th align=\"right\">High</th><th align=\"right\">Low</th></tr></thead>",
    "<tbody>",
    (.rows[] | "<tr><td>\(.symbol|esc)</td><td align=\"right\">\(money(.high))</td><td align=\"right\">\(money(.low))</td></tr>"),
    "</tbody></table>",
    (if (.missing | length) > 0 then
      "<p><small>No data returned for: \(.missing | join(", ") | esc)</small></p>"
     else empty end),
    "<hr><p><small>Automated daily market report (marketstack EOD). Symbols via MARKET_SYMBOLS.</small></p>"
  '
}
