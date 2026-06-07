#!/usr/bin/env bash
# seo-analysis.sh -- the scripted SEO analysis: turn raw Google Search
# Console rows into ranked, capped, graded opportunities, and render
# them for email + ticket. Pure-ish functions over JSON (no network --
# lib/gsc.sh does the fetching) so the logic is unit-testable with
# fixtures. Sourced by bin/tick.sh.
#
# Deliberately NO LLM: GSC data is a known quantity, so every grade and
# recommendation is deterministic and cheap. Each surfaced opportunity
# is a falsifiable prediction; a future Layer 2 re-measures whether it
# panned out -- which is why seo_record_opportunities logs baselines.
#
# Six analyses, two families:
#   click-estimate (counted in the headline upside):
#     striking_distance, low_ctr, decay, rising
#   informational (NOT counted in upside):
#     cannibalization, zero_click
#
# The upside estimate is deliberately conservative -- v1's first live run
# over-credited "fix the title" clicks on queries whose low CTR is
# actually structural (featured snippets, AI overviews, brand/intent
# mismatch). So: striking-distance scales the rank-climb gain by how well
# the page ALREADY converts (a snippet-eaten page gets little credit),
# low-CTR only fires in a band that's plausibly title-fixable (not
# catastrophically below par = structural), and the genuinely-eaten
# high-impression/near-zero-click queries get their own honest bucket.
#
# Requires on PATH: jq, date.

# Fallback logger so this module is sourceable standalone (tests).
if ! declare -F log >/dev/null; then
  log() { printf '[agent] %s\n' "$*"; }
fi

# Expected click-through rate by average position -- a rough industry
# curve. Used to estimate click upside and to flag pages whose CTR is
# below par for where they rank. Shared by every analysis as a jq
# prelude. Heuristic, not gospel; the grade is an aggregate so per-row
# imprecision washes out.
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
# days). Prior window: the 28 days immediately before it (for decay +
# rising).
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

# seo_striking_distance <cur_query_page_json> <floor> <topk> <target_pos>
# Queries ranking just off page one (pos 5-20). Upside = the extra clicks
# from climbing to <target_pos>, scaled by how well the page ALREADY
# converts (actual CTR / expected CTR at its current rank, capped at 1).
# That realization factor is the honesty lever: a page whose CTR is far
# below par (snippet/intent-eaten) earns little climb credit; a page
# converting at par earns full credit.
seo_striking_distance() {
  local data="$1" floor="$2" topk="$3" target="$4"
  jq -c --argjson floor "$floor" --argjson k "$topk" --argjson target "$target" "
    $SEO_ECTR_DEF
    [ .rows[]?
      | select(.impressions >= \$floor and .position >= 5 and .position <= 20)
      | (ectr(.position)) as \$ec
      | (if .ctr > \$ec then 1 else (.ctr / \$ec) end) as \$real
      | ((.impressions * ((ectr(\$target)) - \$ec) * \$real) as \$s
         | if \$s < 0 then 0 else \$s end) as \$score
      | { type:\"striking_distance\", query:.keys[0], page:.keys[1],
          impressions:.impressions, clicks:.clicks, ctr:.ctr, position:.position,
          score:\$score } ]
    | map(select(.score > 0)) | sort_by(-.score) | .[0:\$k]
  " <<<"$data" 2>/dev/null || printf '[]'
}

# seo_low_ctr <cur_page_json> <floor> <topk> <lo_ratio> <hi_ratio> <recovery>
# Pages ranking well (pos <=10) whose CTR is MODERATELY below par --
# between lo_ratio and hi_ratio of expected. Below lo_ratio is treated as
# structural (snippet/intent, not title-fixable) and left for the
# zero_click bucket. Upside = the closable gap times a recovery fraction.
seo_low_ctr() {
  local data="$1" floor="$2" topk="$3" lo="$4" hi="$5" rec="$6"
  jq -c --argjson floor "$floor" --argjson k "$topk" \
        --argjson lo "$lo" --argjson hi "$hi" --argjson rec "$rec" "
    $SEO_ECTR_DEF
    [ .rows[]?
      | select(.impressions >= \$floor and .position <= 10)
      | (ectr(.position)) as \$e
      | select(.ctr >= (\$e * \$lo) and .ctr < (\$e * \$hi))
      | { type:\"low_ctr\", page:.keys[0],
          impressions:.impressions, clicks:.clicks, ctr:.ctr, position:.position,
          expected:\$e, score: (.impressions * (\$e - .ctr) * \$rec) } ]
    | map(select(.score > 0)) | sort_by(-.score) | .[0:\$k]
  " <<<"$data" 2>/dev/null || printf '[]'
}

# seo_decay <cur_page_json> <prev_page_json> <floor> <topk> <pct>
# Pages whose clicks fell by >= pct vs the prior window. Score = clicks
# lost (what recovering would win back) -- the most concrete of the
# estimates, so no extra discount.
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

# seo_rising <cur_query_json> <prev_query_json> <floor> <topk>
# Queries gaining impressions vs the prior window (new, or up >=50%).
# Score = impression growth times the click curve at the current rank --
# the clicks the new demand could yield if the existing rank holds.
seo_rising() {
  local cur="$1" prev="$2" floor="$3" topk="$4"
  local prev_rows
  prev_rows=$(jq -c '.rows // []' <<<"$prev" 2>/dev/null || printf '[]')
  jq -c --argjson floor "$floor" --argjson k "$topk" --argjson prev "$prev_rows" "
    $SEO_ECTR_DEF
    ( \$prev | map({key:.keys[0], value:.}) | from_entries ) as \$pmap
    | [ .rows[]?
        | .keys[0] as \$q
        | (\$pmap[\$q].impressions // 0) as \$pi
        | select(.impressions >= \$floor)
        | select((\$pi == 0) or (.impressions >= (\$pi * 1.5)))
        | (.impressions - \$pi) as \$growth
        | select(\$growth >= \$floor)
        | { type:\"rising\", query:\$q,
            impressions:.impressions, clicks:.clicks, ctr:.ctr, position:.position,
            prev_impressions:\$pi, score: (\$growth * (ectr(.position))) } ]
    | map(select(.score > 0)) | sort_by(-.score) | .[0:\$k]
  " <<<"$cur" 2>/dev/null || printf '[]'
}

# seo_cannibalization <cur_query_page_json> <floor> <topk>
# Queries where 2+ of the site's pages both rank (pos <=20, each with
# >= half the floor in impressions) -- competing URLs split authority.
# Informational: score = the query's total contested impressions (rank
# importance), NOT a click estimate.
seo_cannibalization() {
  local data="$1" floor="$2" topk="$3"
  jq -c --argjson floor "$floor" --argjson k "$topk" '
    [ .rows[]? | select(.impressions >= ($floor * 0.5) and .position <= 20) ]
    | group_by(.keys[0])
    | map(select(length >= 2)
          | { type:"cannibalization", query:(.[0].keys[0]),
              pages:(sort_by(.position)
                     | map({page:.keys[1], position:.position, impressions:.impressions})),
              impressions:(map(.impressions) | add),
              score:(map(.impressions) | add) })
    | sort_by(-.score) | .[0:$k]
  ' <<<"$data" 2>/dev/null || printf '[]'
}

# seo_zero_click <cur_query_page_json> <floor> <topk>
# High-impression query+page rows with effectively no clicks (CTR < 0.5%)
# -- the SERP is eating the click (featured snippet, AI overview, or
# brand/intent mismatch). Informational and honest: a title rarely fixes
# these, so score = impressions (wasted reach) and it's NOT in the upside.
seo_zero_click() {
  local data="$1" floor="$2" topk="$3"
  jq -c --argjson floor "$floor" --argjson k "$topk" '
    [ .rows[]?
      | select(.impressions >= ($floor * 2) and .ctr < 0.005 and .position <= 20)
      | { type:"zero_click", query:.keys[0], page:.keys[1],
          impressions:.impressions, clicks:.clicks, ctr:.ctr, position:.position,
          score:.impressions } ]
    | sort_by(-.score) | .[0:$k]
  ' <<<"$data" 2>/dev/null || printf '[]'
}

# seo_build_report <domain> <cur_qp> <cur_page> <prev_page> <cur_query> <prev_query> <start> <end> <pstart> <pend>
# Assembles a single report object:
#   { domain, grade, window:{...}, total_upside, count, groups:{...6...} }
# Dedups so a page/query is reported under one lens (zero-click out of
# striking-distance; SD/decay pages out of low-CTR). Headline upside sums
# only the click-estimate buckets. grade is GOOD if the best click
# opportunity clears SEO_GOOD_UPSIDE, else INDIFFERENT. Reads
# SEO_IMPRESSION_FLOOR / SEO_TOP_K from env.
seo_build_report() {
  local domain="$1" cur_qp="$2" cur_page="$3" prev_page="$4" cur_query="$5" prev_query="$6"
  local start="$7" end="$8" pstart="$9" pend="${10}"
  local floor="${SEO_IMPRESSION_FLOOR:-50}" topk="${SEO_TOP_K:-10}"
  local decay_pct="${SEO_DECAY_PCT:-0.3}" good_upside="${SEO_GOOD_UPSIDE:-10}"
  # Scoring constants (not env -- keep the public knob surface to floor +
  # top-K). target_pos: striking-distance aspiration. recovery: fraction
  # of a low-CTR gap a title fix realistically captures. lo/hi: the
  # low-CTR band (below lo = structural, above hi = basically fine).
  local target_pos=3 recovery=0.5 lo=0.10 hi=0.70
  local sk=$(( topk < 5 ? topk : 5 ))   # tighter cap for informational buckets

  local sd lc dc ri ca zc
  sd=$(seo_striking_distance "$cur_qp" "$floor" "$topk" "$target_pos")
  lc=$(seo_low_ctr "$cur_page" "$floor" "$topk" "$lo" "$hi" "$recovery")
  dc=$(seo_decay "$cur_page" "$prev_page" "$floor" "$topk" "$decay_pct")
  ri=$(seo_rising "$cur_query" "$prev_query" "$floor" "$topk")
  ca=$(seo_cannibalization "$cur_qp" "$floor" "$sk")
  zc=$(seo_zero_click "$cur_qp" "$floor" "$sk")

  jq -n \
    --arg domain "$domain" \
    --arg start "$start" --arg end "$end" --arg pstart "$pstart" --arg pend "$pend" \
    --argjson good "$good_upside" \
    --argjson sd "$sd" --argjson lc "$lc" --argjson dc "$dc" \
    --argjson ri "$ri" --argjson ca "$ca" --argjson zc "$zc" '
    # dedup: zero-click (query,page) out of striking-distance
    ($zc | map({q:.query, p:.page})) as $zk
    | ($sd | map(. as $r | select(($zk | any(.q == $r.query and .p == $r.page)) | not))) as $sd2
    # dedup: pages already surfaced by SD or decay out of low-CTR
    | (($sd2 | map(.page)) + ($dc | map(.page))) as $seen
    | ($lc | map(select(.page as $p | ($seen | index($p)) | not))) as $lc2
    # headline upside = click-estimate buckets only
    | ($sd2 + $lc2 + $dc + $ri) as $click
    | ([$click[].score] | add // 0) as $upside
    | ([$click[].score] | max // 0) as $top
    | ($sd2 + $lc2 + $dc + $ri + $ca + $zc) as $all
    | {
        domain: $domain,
        window: {start:$start, end:$end, prev_start:$pstart, prev_end:$pend},
        count: ($all | length),
        total_upside: ($upside | round),
        grade: (if $top >= $good then "GOOD" else "INDIFFERENT" end),
        groups: { striking_distance:$sd2, low_ctr:$lc2, decay:$dc,
                  rising:$ri, cannibalization:$ca, zero_click:$zc }
      }'
}

# --- rendering ---
#
# Two renderers: markdown (BOTH the Forgejo ticket body and the email
# text part -- markdown reads fine as plain text) and HTML (the email
# html part, with @html escaping).

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
      "Queries ranking 5–20 that already convert; a rank bump should add clicks.\n",
      (.groups.striking_distance[]
        | "- **\"\(.query)\"** → \(.page)\n  pos \(pos(.position)), \(.impressions) impr, \(pct(.ctr))% CTR · ~\(clk(.score)) clicks upside")
     else empty end),

    (if (.groups.low_ctr | length) > 0 then
      "\n## Low CTR for rank — title/snippet fixes",
      "Pages ranking well but moderately under-clicked — a title/meta rewrite is the lever.\n",
      (.groups.low_ctr[]
        | "- \(.page)\n  pos \(pos(.position)), \(.impressions) impr, \(pct(.ctr))% CTR (par ~\(pct(.expected))%) · ~\(clk(.score)) clicks upside")
     else empty end),

    (if (.groups.decay | length) > 0 then
      "\n## Declining — refresh candidates",
      "Pages whose clicks dropped vs the prior 28 days.\n",
      (.groups.decay[]
        | "- \(.page)\n  clicks \(.prev_clicks) → \(.clicks), \(.impressions) impr · ~\(clk(.score)) clicks to recover")
     else empty end),

    (if (.groups.rising | length) > 0 then
      "\n## Rising — growing demand to ride",
      "Queries gaining impressions vs the prior 28 days; expand or sharpen the content.\n",
      (.groups.rising[]
        | "- **\"\(.query)\"**\n  impr \(.prev_impressions) → \(.impressions), pos \(pos(.position)) · ~\(clk(.score)) clicks of new demand")
     else empty end),

    (if (.groups.cannibalization | length) > 0 then
      "\n## Cannibalization — pages competing for one query",
      "Multiple URLs ranking for the same query split authority; consider consolidating.\n",
      (.groups.cannibalization[]
        | "- **\"\(.query)\"** (\(.pages | length) pages, \(.impressions) impr):\n"
          + (.pages | map("    - \(.page) (pos \(pos(.position)))") | join("\n")))
     else empty end),

    (if (.groups.zero_click | length) > 0 then
      "\n## Zero-click — shown a lot, rarely clicked",
      "High impressions, ~0 clicks: usually a featured snippet, AI overview, or intent/brand mismatch. A title rarely fixes these — win the snippet or accept the gap. (Informational; not in the upside above.)\n",
      (.groups.zero_click[]
        | "- **\"\(.query)\"** → \(.page)\n  \(.impressions) impr, \(pct(.ctr))% CTR at pos \(pos(.position))")
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
      "<p>Queries ranking 5–20 that already convert; a rank bump should add clicks.</p><ul>",
      (.groups.striking_distance[]
        | "<li><strong>\"\(.query|esc)\"</strong> → \(.page|esc)<br><small>pos \(pos(.position)), \(.impressions) impr, \(pct(.ctr))% CTR · ~\(clk(.score)) clicks upside</small></li>"),
      "</ul>"
     else empty end),

    (if (.groups.low_ctr | length) > 0 then
      "<h3>Low CTR for rank — title/snippet fixes</h3>",
      "<p>Pages ranking well but moderately under-clicked — a title/meta rewrite is the lever.</p><ul>",
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

    (if (.groups.rising | length) > 0 then
      "<h3>Rising — growing demand to ride</h3>",
      "<p>Queries gaining impressions vs the prior 28 days; expand or sharpen the content.</p><ul>",
      (.groups.rising[]
        | "<li><strong>\"\(.query|esc)\"</strong><br><small>impr \(.prev_impressions) → \(.impressions), pos \(pos(.position)) · ~\(clk(.score)) clicks of new demand</small></li>"),
      "</ul>"
     else empty end),

    (if (.groups.cannibalization | length) > 0 then
      "<h3>Cannibalization — pages competing for one query</h3>",
      "<p>Multiple URLs ranking for the same query split authority; consider consolidating.</p><ul>",
      (.groups.cannibalization[]
        | "<li><strong>\"\(.query|esc)\"</strong> <small>(\(.pages|length) pages, \(.impressions) impr)</small><ul>"
          + (.pages | map("<li>\(.page|esc) <small>(pos \(pos(.position)))</small></li>") | join(""))
          + "</ul></li>"),
      "</ul>"
     else empty end),

    (if (.groups.zero_click | length) > 0 then
      "<h3>Zero-click — shown a lot, rarely clicked</h3>",
      "<p>High impressions, ~0 clicks: usually a featured snippet, AI overview, or intent/brand mismatch. A title rarely fixes these — win the snippet or accept the gap. (Informational; not in the upside above.)</p><ul>",
      (.groups.zero_click[]
        | "<li><strong>\"\(.query|esc)\"</strong> → \(.page|esc)<br><small>\(.impressions) impr, \(pct(.ctr))% CTR at pos \(pos(.position))</small></li>"),
      "</ul>"
     else empty end),

    "<hr><p><small>Automated SEO pass over Google Search Console data. Tune volume via SEO_IMPRESSION_FLOOR / SEO_TOP_K.</small></p>"
  '
}

# seo_record_opportunities <report_json> <agentic_bool> <iso_week>
# Appends one JSONL record per surfaced opportunity to
# $AGENT_STATE_DIR/seo-opportunities.jsonl, capturing baseline metrics +
# date so a future Layer-2 pass can re-measure whether each prediction
# panned out. Append-only = crash-safe, no read-modify-write.
seo_record_opportunities() {
  local report="$1" agentic="${2:-false}" week="$3"
  local out="${AGENT_STATE_DIR:-$HOME/.local/state/agent}/seo-opportunities.jsonl"
  local today; today=$(date +%F)
  mkdir -p "$(dirname "$out")"
  jq -c --arg today "$today" --arg week "$week" --argjson agentic "$agentic" '
    .domain as $d
    | (.groups | to_entries[].value[])
    | { recorded:$today, week:$week, domain:$d, agentic:$agentic,
        type:.type, query:(.query // null), page:(.page // null),
        baseline:{ impressions:(.impressions // null), clicks:(.clicks // null),
                   ctr:(.ctr // null), position:(.position // null) },
        score:.score }
  ' <<<"$report" >> "$out" 2>/dev/null || true
}
