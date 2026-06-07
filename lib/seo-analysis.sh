#!/usr/bin/env bash
# seo-analysis.sh -- the scripted SEO analysis: turn raw Google Search
# Console rows into ranked, capped, graded opportunities, and render
# them for email + ticket. Pure-ish functions over JSON (no network --
# lib/gsc.sh does the fetching) so the logic is unit-testable with
# fixtures. Sourced by bin/tick.sh.
#
# Deliberately NO LLM: GSC data is a known quantity, so every grade and
# recommendation is deterministic and cheap. Each surfaced opportunity
# is a falsifiable prediction; lib (future Layer 2) re-measures whether
# it panned out -- which is why seo_record_opportunities logs baselines.
#
# Requires on PATH: jq, date.

# Fallback logger so this module is sourceable standalone (tests).
if ! declare -F log >/dev/null; then
  log() { printf '[agent] %s\n' "$*"; }
fi

# Expected click-through rate by average position -- a rough industry
# curve. Used to estimate "click upside" (the score) and to flag pages
# whose CTR is below par for where they rank. Shared by every analysis
# as a jq prelude. Heuristic, not gospel; the grade is an aggregate so
# per-row imprecision washes out.
SEO_ECTR_DEF='def ectr(p):
  if   p<=1  then 0.28 elif p<=2  then 0.15 elif p<=3 then 0.10
  elif p<=4  then 0.07 elif p<=5  then 0.05 elif p<=6 then 0.04
  elif p<=7  then 0.03 elif p<=8  then 0.025 elif p<=9 then 0.02
  elif p<=10 then 0.018 elif p<=20 then 0.01 else 0.005 end;'

# _date_days_ago <n> -> YYYY-MM-DD (n days before today). Portable
# across GNU (Linux server) and BSD (macOS dev) date.
_date_days_ago() {
  local n="$1"
  date -d "-${n} days" +%F 2>/dev/null || date -v-"${n}"d +%F 2>/dev/null
}

# seo_window -> echoes "start end prev_start prev_end" (4 dates).
# Current window: a 28-day span ending 3 days ago (GSC data lags ~2-3
# days). Prior window: the 28 days immediately before it (for decay).
seo_window() {
  local end start pstart pend
  end=$(_date_days_ago 3)
  start=$(_date_days_ago 30)
  pend=$(_date_days_ago 31)
  pstart=$(_date_days_ago 58)
  printf '%s %s %s %s' "$start" "$end" "$pstart" "$pend"
}

# --- analyses: each echoes a JSON array of scored opportunities,
#     filtered by the impression floor, sorted by score desc, capped
#     to top-K. ---

# seo_striking_distance <cur_query_page_json> <floor> <topk>
# Queries ranking just off page one (pos 5-20) with real impressions --
# a small push could reach the top. Score = impressions the click curve
# says we'd gain getting to ~position 3.
seo_striking_distance() {
  local data="$1" floor="$2" topk="$3"
  jq -c --argjson floor "$floor" --argjson k "$topk" "
    $SEO_ECTR_DEF
    [ .rows[]?
      | select(.impressions >= \$floor and .position >= 5 and .position <= 20)
      | { type:\"striking_distance\", query:.keys[0], page:.keys[1],
          impressions:.impressions, clicks:.clicks, ctr:.ctr, position:.position,
          score: ((.impressions * (ectr(3) - .ctr)) as \$s
                  | if \$s < 0 then 0 else \$s end) } ]
    | map(select(.score > 0)) | sort_by(-.score) | .[0:\$k]
  " <<<"$data" 2>/dev/null || printf '[]'
}

# seo_low_ctr <cur_page_json> <floor> <topk>
# Pages that rank well (pos <=10) but whose CTR is meaningfully below
# par for their position -- a title/meta/snippet problem, not a ranking
# one. Score = clicks we'd recover by hitting the expected CTR.
seo_low_ctr() {
  local data="$1" floor="$2" topk="$3"
  jq -c --argjson floor "$floor" --argjson k "$topk" "
    $SEO_ECTR_DEF
    [ .rows[]?
      | select(.impressions >= \$floor and .position <= 10)
      | (ectr(.position)) as \$e
      | select(.ctr < (\$e * 0.7))
      | { type:\"low_ctr\", page:.keys[0],
          impressions:.impressions, clicks:.clicks, ctr:.ctr, position:.position,
          expected:\$e, score: (.impressions * (\$e - .ctr)) } ]
    | map(select(.score > 0)) | sort_by(-.score) | .[0:\$k]
  " <<<"$data" 2>/dev/null || printf '[]'
}

# seo_decay <cur_page_json> <prev_page_json> <floor> <topk> <pct>
# Pages whose clicks fell by >= pct vs the prior window. Score = clicks
# lost (what recovering would win back).
seo_decay() {
  local cur="$1" prev="$2" floor="$3" topk="$4" pct="$5"
  local prev_rows
  prev_rows=$(jq -c '.rows // []' <<<"$prev" 2>/dev/null || printf '[]')
  jq -c --argjson floor "$floor" --argjson k "$topk" \
        --argjson pct "$pct" --argjson prev "$prev_rows" '
    ( $prev | map({key:.keys[0], value:.}) | from_entries ) as $pmap
    | [ .rows[]?
        | .keys[0] as $pg
        | ($pmap[$pg]) as $p
        | select($p != null and $p.impressions >= $floor)
        | select($p.clicks > 0 and .clicks < ($p.clicks * (1 - $pct)))
        | { type:"decay", page:$pg,
            impressions:.impressions, clicks:.clicks, ctr:.ctr, position:.position,
            prev_impressions:$p.impressions, prev_clicks:$p.clicks,
            score: (($p.clicks - .clicks) | if . < 0 then 0 else . end) } ]
    | map(select(.score > 0)) | sort_by(-.score) | .[0:$k]
  ' <<<"$cur" 2>/dev/null || printf '[]'
}

# seo_build_report <domain> <cur_qp> <cur_page> <prev_page> <start> <end> <pstart> <pend>
# Assembles a single report object:
#   { domain, grade, window:{...}, total_upside, count, groups:{...} }
# grade is GOOD if the best opportunity clears SEO_GOOD_UPSIDE estimated
# clicks, else INDIFFERENT. (BAD is a Layer-2/outcome verdict, not an
# emit-time one.) Reads SEO_IMPRESSION_FLOOR / SEO_TOP_K from env.
seo_build_report() {
  local domain="$1" cur_qp="$2" cur_page="$3" prev_page="$4"
  local start="$5" end="$6" pstart="$7" pend="$8"
  local floor="${SEO_IMPRESSION_FLOOR:-50}"
  local topk="${SEO_TOP_K:-10}"
  local decay_pct="${SEO_DECAY_PCT:-0.3}"
  local good_upside="${SEO_GOOD_UPSIDE:-10}"

  local sd lc dc
  sd=$(seo_striking_distance "$cur_qp" "$floor" "$topk")
  lc=$(seo_low_ctr "$cur_page" "$floor" "$topk")
  dc=$(seo_decay "$cur_page" "$prev_page" "$floor" "$topk" "$decay_pct")

  jq -n \
    --arg domain "$domain" \
    --arg start "$start" --arg end "$end" \
    --arg pstart "$pstart" --arg pend "$pend" \
    --argjson good "$good_upside" \
    --argjson sd "$sd" --argjson lc "$lc" --argjson dc "$dc" '
    ($sd + $lc + $dc) as $all
    | ([$all[].score] | add // 0) as $upside
    | ([$all[].score] | max // 0) as $top
    | {
        domain: $domain,
        window: {start:$start, end:$end, prev_start:$pstart, prev_end:$pend},
        count: ($all | length),
        total_upside: ($upside | round),
        grade: (if $top >= $good then "GOOD" else "INDIFFERENT" end),
        groups: { striking_distance:$sd, low_ctr:$lc, decay:$dc }
      }'
}

# --- rendering ---
#
# Two renderers: markdown (used for BOTH the Forgejo ticket body and the
# email text part -- markdown reads fine as plain text) and HTML (the
# email html part, with @html escaping for safety).

# Shared jq formatting helpers, prepended to each renderer program.
SEO_FMT_DEF='
  def pct(c): (c*1000|round)/10;
  def pos(p): (p*10|round)/10;
  def clk(s): (s|round);'

# seo_render_markdown <report_json>
seo_render_markdown() {
  jq -r "$SEO_FMT_DEF"'
    "# SEO opportunities — \(.domain)\n",
    "**Grade: \(.grade)** · \(.count) opportunities · ~\(.total_upside) est. clicks/28d upside",
    "Window: \(.window.start) → \(.window.end) (vs \(.window.prev_start) → \(.window.prev_end))\n",

    (if (.groups.striking_distance | length) > 0 then
      "## Striking distance — just off page one",
      "Queries ranking 5–20 with real impressions; a small push reaches the top.\n",
      (.groups.striking_distance[]
        | "- **\"\(.query)\"** → \(.page)\n  pos \(pos(.position)), \(.impressions) impr, \(pct(.ctr))% CTR · ~\(clk(.score)) clicks upside")
     else empty end),

    (if (.groups.low_ctr | length) > 0 then
      "\n## Low CTR for rank — title/snippet fixes",
      "Pages ranking well but under-clicked for their position.\n",
      (.groups.low_ctr[]
        | "- \(.page)\n  pos \(pos(.position)), \(.impressions) impr, \(pct(.ctr))% CTR (par ~\(pct(.expected))%) · ~\(clk(.score)) clicks upside")
     else empty end),

    (if (.groups.decay | length) > 0 then
      "\n## Declining — refresh candidates",
      "Pages whose clicks dropped vs the prior 28 days.\n",
      (.groups.decay[]
        | "- \(.page)\n  clicks \(.prev_clicks) → \(.clicks), \(.impressions) impr · ~\(clk(.score)) clicks to recover")
     else empty end),

    "\n---",
    "_Automated SEO pass over Google Search Console data. Tune volume via SEO_IMPRESSION_FLOOR / SEO_TOP_K._"
  '
}

# seo_render_html <report_json>
seo_render_html() {
  jq -r "$SEO_FMT_DEF"'
    def esc: @html;
    "<h2>SEO opportunities — \(.domain|esc)</h2>",
    "<p><strong>Grade: \(.grade)</strong> · \(.count) opportunities · ~\(.total_upside) est. clicks/28d upside<br>",
    "<small>Window: \(.window.start) → \(.window.end) (vs \(.window.prev_start) → \(.window.prev_end))</small></p>",

    (if (.groups.striking_distance | length) > 0 then
      "<h3>Striking distance — just off page one</h3>",
      "<p>Queries ranking 5–20 with real impressions; a small push reaches the top.</p><ul>",
      (.groups.striking_distance[]
        | "<li><strong>\"\(.query|esc)\"</strong> → \(.page|esc)<br><small>pos \(pos(.position)), \(.impressions) impr, \(pct(.ctr))% CTR · ~\(clk(.score)) clicks upside</small></li>"),
      "</ul>"
     else empty end),

    (if (.groups.low_ctr | length) > 0 then
      "<h3>Low CTR for rank — title/snippet fixes</h3>",
      "<p>Pages ranking well but under-clicked for their position.</p><ul>",
      (.groups.low_ctr[]
        | "<li>\(.page|esc)<br><small>pos \(pos(.position)), \(.impressions) impr, \(pct(.ctr))% CTR (par ~\(pct(.expected))%) · ~\(clk(.score)) clicks upside</small></li>"),
      "</ul>"
     else empty end),

    (if (.groups.decay | length) > 0 then
      "<h3>Declining — refresh candidates</h3>",
      "<p>Pages whose clicks dropped vs the prior 28 days.</p><ul>",
      (.groups.decay[]
        | "<li>\(.page|esc)<br><small>clicks \(.prev_clicks) → \(.clicks), \(.impressions) impr · ~\(clk(.score)) clicks to recover</small></li>"),
      "</ul>"
     else empty end),

    "<hr><p><small>Automated SEO pass over Google Search Console data. Tune volume via SEO_IMPRESSION_FLOOR / SEO_TOP_K.</small></p>"
  '
}

# seo_record_opportunities <report_json> <agentic_bool> <iso_week>
# Appends one JSONL record per surfaced opportunity to
# $AGENT_STATE_DIR/seo-opportunities.jsonl, capturing the baseline
# metrics + date so a future Layer-2 pass can re-measure whether each
# prediction panned out. Append-only = crash-safe, no read-modify-write.
seo_record_opportunities() {
  local report="$1" agentic="${2:-false}" week="$3"
  local out="${AGENT_STATE_DIR:-$HOME/.local/state/agent}/seo-opportunities.jsonl"
  local today; today=$(date +%F)
  mkdir -p "$(dirname "$out")"
  jq -c --arg today "$today" --arg week "$week" --argjson agentic "$agentic" '
    .domain as $d | .window.end as $wend
    | (.groups | to_entries[].value[])
    | { recorded:$today, week:$week, domain:$d, agentic:$agentic,
        type:.type, query:(.query // null), page:(.page // null),
        baseline:{ impressions:.impressions, clicks:.clicks,
                   ctr:.ctr, position:.position }, score:.score }
  ' <<<"$report" >> "$out" 2>/dev/null || true
}
