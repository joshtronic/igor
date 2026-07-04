#!/usr/bin/env bash
# ceo.sh -- the CEO pass's READ side: convention-driven opt-in via a repo's
# CEO.md mandate, plus a weekly activity gather for the board digest.
#
# Opt-in is the mandate's mere presence -- exactly like logwatch keys off a
# root systemd/ dir and the review tick keys off the merge. A repo that grows a
# CEO.md is under autonomous CEO management; no env knob, no hardcoded
# repo. (See the mandate itself: "the mandate's mere presence in the repo is
# what opts [it] into autonomous CEO management.")
#
# Phase 1 is strictly read-only: read the mandate, gather the week, hand both to
# one model call that writes the board digest. No issue-filing / steering /
# doc-edits yet -- those are later phases, per the mandate's "start tight,
# loosen as trust earns it" rope.
#
# Sourced by tick.sh; depends on _fj (lib/forgejo.sh) + jq.

CEO_MANDATE_PATH="CEO.md"
# Stamped (HTML comment) into every CEO-proposed issue body so the next week's
# pass can tell whether the last batch has been triaged -- the proposal throttle.
CEO_PROPOSAL_MARKER="<!-- ceo-proposal -->"
# Phase 4: stamped into every CEO board QUESTION so the next tick can find its
# own open questions -- the two-way channel AND the CEO's question-memory. A
# question issue is assigned to the reviewer + labeled Status/Need More Info; the
# reviewer answers in a comment and UNASSIGNS to hand it back (the act trigger).
CEO_QUESTION_MARKER="<!-- ceo-question -->"
# Upper bound on simultaneously-open CEO items (proposals + questions) before the
# pass stops filing new ones -- a generous backstop against infinite pileup that
# still lets the CEO grind, replacing the old "no new work until zero open" gate.
CEO_MAX_OPEN=8
# Stamped into the weekly board digest, now a RESPONDABLE issue (the brief moved off
# one-way email): the board comments to steer next week's read, closes to drop. Not a
# work item (no Agent label) and NOT counted toward CEO_MAX_OPEN.
CEO_DIGEST_MARKER="<!-- ceo-digest -->"

# ceo_read_mandate <repo> -- echo the mandate's raw content, empty if absent.
# This IS the opt-in probe: a present CEO.md returns its body, a missing
# one 404s (_fj is `curl -sf` -> empty output, nonzero exit), so callers gate on
# non-empty output (`[ -n "$mandate" ]`) and need no separate existence check.
# The `|| true` swallows the 404's nonzero so the caller's `mandate=$(...)`
# assignment doesn't trip `set -e` on every repo that hasn't opted in.
ceo_read_mandate() {
  local repo="$1"
  _fj GET "/repos/${repo}/raw/${CEO_MANDATE_PATH}" 2>/dev/null || true
}

# ceo_gather_week <repo> <since_iso> -- echo a markdown summary of the repo's
# activity since <since_iso> (RFC3339): commits to the default branch, PRs
# merged, issues opened/closed, and the current open Agent queue. This is the
# board digest's evidence base -- what actually happened, for the model to read
# against the mandate's priorities.
ceo_gather_week() {
  local repo="$1" since="$2"
  local prs issues_recent open_prs all_open

  printf '## Activity on %s since %s\n\n' "$repo" "$since"

  printf '### PRs merged (what shipped)\n'
  prs=$(_fj GET "/repos/${repo}/pulls?state=closed&sort=recentupdate&limit=50" 2>/dev/null)
  jq -r --arg s "$since" '
    [ (.[]? | select((.merged_at // "") >= $s)) ]
    | if length==0 then "- (none)" else (.[] | "- #\(.number) \(.title) (by \(.user.login))") end
  ' <<<"${prs:-[]}" 2>/dev/null || printf -- '- (none)\n'
  printf '\n'

  printf '### Issues opened / closed\n'
  issues_recent=$(_fj GET "/repos/${repo}/issues?state=all&type=issues&since=${since}&limit=50" 2>/dev/null)
  jq -r --arg s "$since" '
    [ (.[]? | select(.pull_request == null)
        | select((.created_at >= $s) or ((.closed_at // "") >= $s))) ]
    | if length==0 then "- (none)"
      else (.[] | "- #\(.number) [\(.state)] \(.title)"
            + (if .created_at >= $s then " (opened)" else "" end)
            + (if (.closed_at // "") >= $s then " (closed)" else "" end)) end
  ' <<<"${issues_recent:-[]}" 2>/dev/null || printf -- '- (none)\n'
  printf '\n'

  printf '### Open PRs (in flight -- in review or awaiting merge)\n'
  open_prs=$(_fj GET "/repos/${repo}/pulls?state=open&limit=50" 2>/dev/null)
  jq -r '
    [ .[]? ]
    | if length==0 then "- (none)" else (.[] | "- #\(.number) \(.title) (by \(.user.login))") end
  ' <<<"${open_prs:-[]}" 2>/dev/null || printf -- '- (none)\n'
  printf '\n'

  # The WHOLE open board, not just the Agent queue -- the CEO sees everything
  # (onboarding, maintenance triage, its own pending proposals, blockers awaiting
  # the human), labels and all. This is the dedup surface: do NOT propose work an
  # open ticket already owns, and if the repo is blocked on one (e.g. onboarding),
  # say so rather than re-filing the blocker as new work.
  printf '### Open issues -- the WHOLE board (dedup against this)\n'
  all_open=$(_fj GET "/repos/${repo}/issues?state=open&type=issues&limit=50" 2>/dev/null)
  jq -r '
    [ (.[]? | select(.pull_request == null)) ]
    | if length==0 then "- (none)"
      else (.[] | "- #\(.number) \(.title)"
            + (if ([.labels[]?.name] | length) > 0
               then "  [\([.labels[]?.name] | join(","))]" else "  [unlabeled]" end)) end
  ' <<<"${all_open:-[]}" 2>/dev/null || printf -- '- (none)\n'
}

# ---- digest assembly: prompt, parse, render (mirrors sports-digest.sh) ----

# ceo_build_prompt <repo> <mandate> <activity> <since_iso>
# Assembles the USER prompt: the board mandate (the north-star) + the week's
# activity. The SYSTEM prompt (CEO persona, what the digest must do, the output
# contract) lives in bin/lib/ceo-digest-directive.md.
ceo_build_prompt() {
  local repo="$1" mandate="$2" activity="$3" since="$4"
  printf 'You are writing the weekly board digest for **%s**, covering activity since %s.

## The mandate (CEO.md) -- your north-star

%s

## This week'"'"'s activity (the evidence base)

%s

## Output format (mechanical contract -- repeated because it matters)

Your VERY FIRST line must be `SUBJECT: <one-line subject>`. Your SECOND line
must be exactly ===BODY===. Then the markdown digest. Then, for each proposal
(zero, one, or two), a ===ISSUE=== line, a `TITLE: <title>` line, and the issue
body. No preamble, no fences around the whole response, nothing after the final
block.' \
    "$repo" "$since" "$mandate" "$activity"
}

# ceo_build_answer_prompt <repo> <mandate> <answered-questions-block>
# Phase 4 act-on-answers prompt: the board answered open questions; turn each
# decision into the work it implies (===ISSUE=== / ===GUIDANCE===), no digest.
ceo_build_answer_prompt() {
  local repo="$1" mandate="$2" qblock="$3"
  printf 'The board has ANSWERED open questions you asked for **%s**. Read the replies and ACT on them -- turn each decision into the work it implies. This is NOT a weekly digest.

## The mandate (CEO.md) -- your north-star

%s

## Your answered questions and the board replies

%s

## What to emit

For each answered question, translate the decision into action: append an ===ISSUE=== block (TITLE: + body) for any work it greenlights, and/or a ===GUIDANCE=== line if the answer reveals a durable decision rule. Keep the body to a one-line acknowledgement; do NOT write a full digest and do NOT ask new questions.

## Output format (mechanical contract -- match exactly)

First line: `SUBJECT: <one-line>`. Second line: exactly ===BODY===. Then a one-line acknowledgement. Then, for each action, a ===ISSUE=== line, a `TITLE: <title>` line, and the body markdown. Finally, IF you have decision guidance, a ===GUIDANCE=== line. Nothing before SUBJECT, nothing after the final block.' \
    "$repo" "$mandate" "$qblock"
}

# _ceo_trim_blanks -- stdin->stdout: strip leading/trailing blank lines, keep
# interior blanks. Shared by the digest body and each proposal body.
_ceo_trim_blanks() {
  awk 'NF { if (started) for (i = 0; i < blanks; i++) print ""
            blanks = 0; started = 1; print; next }
       started { blanks++ }'
}

# _ceo_parse_issues <rest-after-BODY> -- echo a JSON array [{title, body}] of the
# proposal blocks appended after the digest. Each block is:
#   ===ISSUE===
#   TITLE: <single-line title>
#   <body markdown...>
# Empty array if there are no ===ISSUE=== blocks. Harness-built JSON, never
# model-written -- the same anti-fragility rule as the digest body. A block
# missing its TITLE: line is skipped.
_ceo_parse_issues() {
  local rest="$1" issues='[]' chunk title body
  case "$rest" in *'===ISSUE==='*) ;; *) printf '[]'; return 0 ;; esac
  while IFS= read -r -d '' chunk; do
    title=$(printf '%s\n' "$chunk" | sed -n 's/^[[:space:]]*TITLE:[[:space:]]*//p' | head -1)
    [ -n "$title" ] || continue
    # Body = everything after the (first) TITLE: line, wherever it sits.
    body=$(printf '%s\n' "$chunk" | awk 'p { print } /^[[:space:]]*TITLE:/ { p = 1 }' | _ceo_trim_blanks)
    issues=$(jq -c --arg t "$title" --arg b "$body" '. + [{title:$t, body:$b}]' <<<"$issues")
  done < <(printf '%s' "${rest#*===ISSUE===}" | awk 'BEGIN { RS = "===ISSUE===" } { printf "%s\0", $0 }')
  # Cap at 2 harness-side -- enforce the directive's "up to two" rather than
  # trusting model restraint. A misbehaving/poisoned model emitting N blocks
  # would otherwise have N issues filed; the human label gate bounds the blast
  # radius, but we enforce the limit regardless.
  jq -c '.[:2]' <<<"$issues"
}

# _ceo_parse_questions <rest-region> -- echo a JSON array [{title, body}] of the
# ===QUESTION=== blocks. Structurally identical to _ceo_parse_issues but for the
# CEO's board questions (decisions it needs from the human), capped at 2.
_ceo_parse_questions() {
  local rest="$1" questions='[]' chunk title body
  case "$rest" in *'===QUESTION==='*) ;; *) printf '[]'; return 0 ;; esac
  while IFS= read -r -d '' chunk; do
    title=$(printf '%s\n' "$chunk" | sed -n 's/^[[:space:]]*TITLE:[[:space:]]*//p' | head -1)
    [ -n "$title" ] || continue
    body=$(printf '%s\n' "$chunk" | awk 'p { print } /^[[:space:]]*TITLE:/ { p = 1 }' | _ceo_trim_blanks)
    questions=$(jq -c --arg t "$title" --arg b "$body" '. + [{title:$t, body:$b}]' <<<"$questions")
  done < <(printf '%s' "${rest#*===QUESTION===}" | awk 'BEGIN { RS = "===QUESTION===" } { printf "%s\0", $0 }')
  jq -c '.[:2]' <<<"$questions"
}

# ceo_parse_response <raw>
# Parses the model's label-line + sentinel response (never model-written JSON):
#   SUBJECT: <one-line subject>
#   ===BODY===
#   <markdown digest>
#   [ zero or more ===ISSUE=== proposal blocks -- see _ceo_parse_issues ]
# Echoes harness-built JSON {subject, body, issues:[...]}; rc=1 if the sentinel
# or body is missing (caller retries). Mirrors sports_parse_response.
ceo_parse_response() {
  local raw="$1" head rest body subject_line issues questions guidance issues_part questions_part
  case "$raw" in
    *'===BODY==='*) ;;
    *) return 1 ;;
  esac
  head="${raw%%===BODY===*}"
  rest="${raw#*===BODY===}"
  # Phase 3: split off the optional ===GUIDANCE=== section (last of all) first.
  guidance=""
  case "$rest" in
    *'===GUIDANCE==='*)
      guidance=$(printf '%s\n' "${rest#*===GUIDANCE===}" | _ceo_trim_blanks)
      rest="${rest%%===GUIDANCE===*}"
      ;;
  esac
  # Phase 4: the contract is BODY, then ===ISSUE=== blocks, then ===QUESTION===
  # blocks. Split issues (before the first question) from questions (from it on)
  # so neither parser swallows the other's blocks.
  case "$rest" in
    *'===QUESTION==='*)
      issues_part="${rest%%===QUESTION===*}"
      questions_part="===QUESTION===${rest#*===QUESTION===}"
      ;;
    *)
      issues_part="$rest"
      questions_part=""
      ;;
  esac
  # Digest body = up to the FIRST of ===ISSUE=== or ===QUESTION===.
  body="${rest%%===ISSUE===*}"
  body="${body%%===QUESTION===*}"
  printf '%s' "$body" | grep -q '[^[:space:]]' || return 1
  body=$(printf '%s\n' "$body" | _ceo_trim_blanks)
  subject_line=$(printf '%s' "$head" | sed -n 's/^SUBJECT:[[:space:]]*//p' | head -1)
  issues=$(_ceo_parse_issues "$issues_part")
  questions=$(_ceo_parse_questions "$questions_part")
  jq -n --arg s "$subject_line" --arg b "$body" --argjson i "${issues:-[]}" \
        --argjson q "${questions:-[]}" --arg g "$guidance" \
    '{subject:$s, body:$b, issues:$i, questions:$q, guidance:$g}'
}

# ceo_render_html <<< <markdown>
# Minimal markdown->HTML for the email's html part (raw markdown ships as the
# text/plain part). Same renderer the sports digest uses.
ceo_render_html() {
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

# ---- per-repo weekly slot state (.ceo in discretionary-state.json) ----
# Dedicated .ceo object keyed by repo -> ISO week, matching the per-subsystem
# shape of .seo/.sports. Per-repo so several managed repos each get
# their own weekly stamp; one digest per repo per ISO week, self-healing.
ceo_state_file() {
  printf '%s/discretionary-state.json' "${AGENT_STATE_DIR:-$HOME/.local/state/agent}"
}
ceo_week_done() {  # <repo> -- 0 if this repo was digested already this ISO week
  local repo="$1" f last
  f=$(ceo_state_file); [ -f "$f" ] || return 1
  last=$(jq -r --arg r "$repo" '.ceo[$r] // ""' "$f" 2>/dev/null)
  [ -n "$last" ] && [ "$last" = "$(date +%G-W%V)" ]
}
ceo_mark_week_done() {  # <repo>
  local repo="$1" f tmp
  f=$(ceo_state_file)
  [ -f "$f" ] || echo '{}' > "$f"
  tmp=$(mktemp)
  if jq --arg r "$repo" --arg w "$(date +%G-W%V)" \
      '.ceo //= {} | .ceo[$r] = $w' "$f" > "$tmp"; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp"   # jq failed -- drop the temp instead of leaking it
  fi
}

# ---- Phase 4: live product metrics (the data the CEO decides AGAINST) ----
# Opt-in per repo via agent.json `.ceo.metrics_url` -- a public JSON endpoint.
# Generic: nothing here knows the field names; the mandate explains what the
# numbers mean. Each reading is stamped under .ceo_metrics[repo] so the NEXT cycle
# can show the delta (the trend). A missing key or an unreachable endpoint is a
# clean no-op / a one-line note -- never a crash.
ceo_metrics_load() {  # <repo> -- echo the previously-stored reading JSON, empty if none
  local repo="$1" f
  f=$(ceo_state_file); [ -f "$f" ] || return 0
  jq -c --arg r "$repo" '.ceo_metrics[$r].data // empty' "$f" 2>/dev/null || true
}
ceo_metrics_store() {  # <repo> <reading-json>
  local repo="$1" data="$2" f tmp now
  f=$(ceo_state_file); [ -f "$f" ] || echo '{}' > "$f"
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  tmp=$(mktemp)
  if jq --arg r "$repo" --arg at "$now" --argjson d "$data" \
      '.ceo_metrics //= {} | .ceo_metrics[$r] = {at: $at, data: $d}' "$f" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp"   # bad/oversized reading -- skip the store rather than corrupt state
  fi
}
# ceo_read_metrics <repo> -- markdown of the current + prior reading from the repo's
# agent.json `.ceo.metrics_url`. Empty (return 0) when no metrics_url is declared,
# so repos without it digest exactly as before.
ceo_read_metrics() {
  local repo="$1" url cur prev
  url=$(forgejo_repo_get_file "$repo" "${AGENT_CONFIG_FILE:-agent.json}" 2>/dev/null \
    | jq -r '.ceo.metrics_url // empty' 2>/dev/null || true)
  [ -n "$url" ] || return 0
  printf '## Live metrics (judge yourself against THESE, not the prose)\n\n'
  # Harden this outbound fetch (a config-declared URL): https ONLY -- never let it
  # reach file://, http://internal, or a cloud-metadata endpoint -- and cap the body
  # so a huge/hostile response can't bloat the prompt (an oversize body that no longer
  # parses as JSON falls through to the "unavailable" path below).
  case "$url" in
    https://*) ;;
    *) printf -- '- metrics_url is not https -- refusing to fetch it. Fix agent.json; do NOT guess numbers.\n'
       return 0 ;;
  esac
  cur=$(curl -fsS --max-time 20 "$url" 2>/dev/null | head -c 65536 || true)
  if [ -z "$cur" ] || ! jq -e . >/dev/null 2>&1 <<<"$cur"; then
    printf -- '- metrics unavailable this cycle -- the endpoint did not answer with JSON. Note it; do NOT guess numbers.\n'
    return 0
  fi
  prev=$(ceo_metrics_load "$repo")
  printf '### Current reading (just fetched)\n```json\n%s\n```\n' \
    "$(jq -S . <<<"$cur" 2>/dev/null || printf '%s' "$cur")"
  if [ -n "$prev" ] && [ "$prev" != "null" ]; then
    printf '\n### Previous reading -- the trend baseline; compute the delta\n```json\n%s\n```\n' "$prev"
  else
    printf '\n_(no prior reading -- this is the baseline data point)_\n'
  fi
  ceo_metrics_store "$repo" "$cur"
}

# _ceo_gsc_totals <gsc-response-json> -- aggregate {clicks,impressions,ctr,position}
# over the response rows. CTR = clicks/impressions; position = impression-weighted
# average. Empty/garbage in -> all-zero totals (never errors).
_ceo_gsc_totals() {
  jq -c '
    (.rows // []) as $r
    | ($r | map(.impressions) | add // 0) as $imp
    | ($r | map(.clicks)      | add // 0) as $clk
    | { clicks: $clk, impressions: $imp,
        ctr:      (if $imp > 0 then ($clk / $imp) else 0 end),
        position: (if $imp > 0 then (($r | map(.position * .impressions) | add // 0) / $imp) else 0 end) }
  ' <<<"$1" 2>/dev/null || printf '{"clicks":0,"impressions":0,"ctr":0,"position":0}'
}

# ceo_read_gsc <repo> -- markdown of the repo's Google Search Console scoreboard
# (clicks / impressions / CTR / avg position), current 28-day window vs the prior
# 28 days. Fetched ON DEMAND every time the CEO runs -- it does NOT wait for the
# monthly SEO pass; the boss reads the scoreboard whenever it wants. Keyed on
# agent.json `.seo.domain` (the same field the SEO pass uses); empty (return 0)
# when no domain is declared, so non-SEO repos digest exactly as before. Reuses
# the SEO window + the GSC client; both windows come from this one call, so the
# trend is self-contained (no persisted state). A missing/failed fetch is a
# "scoreboard dark, do NOT guess" note, never a crash.
ceo_read_gsc() {
  local repo="$1" domain token start end pstart pend cur prev ctot ptot
  domain=$(forgejo_repo_get_file "$repo" "${AGENT_CONFIG_FILE:-agent.json}" 2>/dev/null \
    | jq -r '.seo.domain // empty' 2>/dev/null || true)
  [ -n "$domain" ] || return 0
  printf '## Search Console -- the scoreboard (%s)\n\n' "$domain"
  if [ -z "${GOOGLE_SERVICE_ACCOUNT:-}" ]; then
    printf -- '- GSC is not configured this run -- no numbers. Note it; do NOT guess.\n'
    return 0
  fi
  token=$(gsc_access_token 2>/dev/null) || {
    printf -- '- GSC token mint failed -- no numbers this cycle. Note it; do NOT guess.\n'
    return 0
  }
  read -r start end pstart pend <<<"$(seo_window)"
  cur=$(gsc_query "$token" "$domain" "$start" "$end" "date" 2>/dev/null || printf '{"rows":[]}')
  prev=$(gsc_query "$token" "$domain" "$pstart" "$pend" "date" 2>/dev/null || printf '{"rows":[]}')
  ctot=$(_ceo_gsc_totals "$cur"); ptot=$(_ceo_gsc_totals "$prev")
  printf '28-day window **%s -> %s** vs the prior 28 days (**%s -> %s**). Lead with these and the delta; lower avg position is better.\n\n' \
    "$start" "$end" "$pstart" "$pend"
  printf '| metric | current | prior |\n|---|---|---|\n'
  printf '| clicks | %s | %s |\n'      "$(jq -r '.clicks'                   <<<"$ctot")" "$(jq -r '.clicks'                   <<<"$ptot")"
  printf '| impressions | %s | %s |\n' "$(jq -r '.impressions'              <<<"$ctot")" "$(jq -r '.impressions'              <<<"$ptot")"
  printf '| CTR | %s%% | %s%% |\n'     "$(jq -r '(.ctr * 10000 | round) / 100'  <<<"$ctot")" "$(jq -r '(.ctr * 10000 | round) / 100'  <<<"$ptot")"
  printf '| avg position | %s | %s |\n' "$(jq -r '(.position * 100 | round) / 100' <<<"$ctot")" "$(jq -r '(.position * 100 | round) / 100' <<<"$ptot")"
}

# ceo_read_ga <repo> -- markdown of the repo's Google Analytics on-site
# behavior (sessions / engagement / conversions), current 28-day window vs
# the prior 28 days. Sibling to ceo_read_gsc: same agent.json `.seo.domain`
# key, same GOOGLE_SERVICE_ACCOUNT gate, same seo_window. Unlike GSC (one
# domain = one site), GA4 property resolution is per-domain
# (ga_property_for_domain, no static map) so an unmatched domain is its own
# "note it, do NOT guess" branch rather than a crash. Reuses seo_ga_metrics
# (lib/seo-analysis.sh) to parse the aggregate report -- the same parser the
# SEO pass's GA fold-in uses.
ceo_read_ga() {
  local repo="$1" domain property start end pstart pend cur prev cm pm
  domain=$(forgejo_repo_get_file "$repo" "${AGENT_CONFIG_FILE:-agent.json}" 2>/dev/null \
    | jq -r '.seo.domain // empty' 2>/dev/null || true)
  [ -n "$domain" ] || return 0
  printf '## Analytics -- on-site behavior (%s)\n\n' "$domain"
  if [ -z "${GOOGLE_SERVICE_ACCOUNT:-}" ]; then
    printf -- '- Analytics is not configured this run -- no numbers. Note it; do NOT guess.\n'
    return 0
  fi
  if ! property=$(ga_property_for_domain "$domain" 2>/dev/null); then
    printf -- '- Analytics token mint failed -- no numbers this cycle. Note it; do NOT guess.\n'
    return 0
  fi
  if [ -z "$property" ]; then
    printf -- '- No GA4 property matches %s -- no numbers this cycle. Note it; do NOT guess.\n' "$domain"
    return 0
  fi
  read -r start end pstart pend <<<"$(seo_window)"
  cur=$(ga_run_report "$property" "$start" "$end" "" \
          "sessions,engagedSessions,engagementRate,totalUsers,keyEvents" 2>/dev/null || printf '{"rows":[]}')
  prev=$(ga_run_report "$property" "$pstart" "$pend" "" \
          "sessions,engagedSessions,engagementRate,totalUsers,keyEvents" 2>/dev/null || printf '{"rows":[]}')
  cm=$(seo_ga_metrics "$cur"); pm=$(seo_ga_metrics "$prev")
  printf '28-day window **%s -> %s** vs the prior 28 days (**%s -> %s**). Lead with these and the delta.\n\n' \
    "$start" "$end" "$pstart" "$pend"
  printf '| metric | current | prior |\n|---|---|---|\n'
  printf '| sessions | %s | %s |\n'          "$(jq -r '.sessions // 0'          <<<"$cm")" "$(jq -r '.sessions // 0'          <<<"$pm")"
  printf '| engaged sessions | %s | %s |\n'  "$(jq -r '.engagedSessions // 0'   <<<"$cm")" "$(jq -r '.engagedSessions // 0'   <<<"$pm")"
  printf '| engagement rate | %s%% | %s%% |\n' \
    "$(jq -r '((.engagementRate // 0) * 10000 | round) / 100' <<<"$cm")" "$(jq -r '((.engagementRate // 0) * 10000 | round) / 100' <<<"$pm")"
  printf '| users | %s | %s |\n'             "$(jq -r '.totalUsers // 0'        <<<"$cm")" "$(jq -r '.totalUsers // 0'        <<<"$pm")"
  printf '| conversions (key events) | %s | %s |\n' "$(jq -r '.keyEvents // 0'  <<<"$cm")" "$(jq -r '.keyEvents // 0'         <<<"$pm")"
}

# ---- Phase 2: proposing work (issues the board greenlights) ----
# The CEO files up to two UNLABELED issues assigned to the human, each carrying
# CEO_PROPOSAL_MARKER. They become real work only when the human adds the Agent
# label (and unassigns). The throttle: a fresh batch is filed only once the
# previous one is triaged (no open proposals), so they never pile up.

# ceo_open_proposals_count <repo> -- count open issues carrying the marker.
ceo_open_proposals_count() {
  local repo="$1"
  _fj GET "/repos/${repo}/issues?state=open&type=issues&limit=50" 2>/dev/null \
    | jq -r --arg m "$CEO_PROPOSAL_MARKER" \
        '[ .[]? | select(.pull_request == null) | select((.body // "") | contains($m)) ] | length' \
        2>/dev/null || echo 0
}

# ceo_file_proposal <repo> <title> <body> <assignee> -- file an UNLABELED issue
# assigned to <assignee>, stamped as a CEO proposal. Returns 0 on success.
ceo_file_proposal() {
  local repo="$1" title="$2" body="$3" assignee="$4" full payload
  full=$(printf '%s\n\n---\n_Proposed by the CEO against the mandate priorities. **Greenlight:** add the `Agent` label and unassign. **Decline:** close._\n%s' \
    "$body" "$CEO_PROPOSAL_MARKER")
  payload=$(jq -n --arg t "$title" --arg b "$full" --arg a "$assignee" \
    '{title: $t, body: $b, assignees: [$a]}')
  _fj POST "/repos/${repo}/issues" "$payload" >/dev/null 2>&1
}

# ---- Phase 4: the two-way board-question channel ----
# A board QUESTION is an issue assigned to the reviewer + labeled
# Status/Need More Info + stamped CEO_QUESTION_MARKER. The reviewer answers in a
# comment and UNASSIGNS themselves to hand it back; the next tick sees the
# unassigned-but-still-open question, reads the thread, and acts on it. The open
# question issues ARE the CEO's memory of what it asked.

# ceo_file_question <repo> <title> <body> <reviewer> -- file the question issue
# (assigned + Status/Need More Info label + marker). Returns 0 on a created issue
# (label is best-effort), 1 if the create itself failed.
ceo_file_question() {
  local repo="$1" title="$2" body="$3" reviewer="$4" full payload resp num
  full=$(printf '%s\n\n---\n_The CEO needs a decision. **Answer in a comment, then unassign yourself** to hand it back. **Decline / N-A:** close._\n%s' \
    "$body" "$CEO_QUESTION_MARKER")
  payload=$(jq -n --arg t "$title" --arg b "$full" --arg a "$reviewer" \
    '{title: $t, body: $b, assignees: [$a]}')
  resp=$(_fj POST "/repos/${repo}/issues" "$payload" 2>/dev/null) || return 1
  num=$(jq -r '.number // empty' <<<"$resp" 2>/dev/null || true)
  if [ -n "$num" ]; then
    forgejo_add_label "$repo" "$num" "Status/Need More Info" 2>/dev/null || true
  fi
  return 0
}

# ceo_answered_question_numbers <repo> <reviewer> -- newline list of open
# question-issue numbers the reviewer has UNASSIGNED themselves from (their
# go-signal: answered, hand it back). Empty when nothing is answered.
ceo_answered_question_numbers() {
  local repo="$1" reviewer="$2"
  _fj GET "/repos/${repo}/issues?state=open&type=issues&limit=50" 2>/dev/null \
    | jq -r --arg m "$CEO_QUESTION_MARKER" --arg r "$reviewer" '
        .[]? | select(.pull_request == null) | select((.body // "") | contains($m))
        | select(([.assignees[]?.login] | index($r)) | not) | .number' 2>/dev/null || true
}

# ceo_open_questions <repo> <reviewer> -- markdown the digest/answer prompt reads:
# ANSWERED questions (reviewer unassigned -> title + body + every comment, the
# board's reply) and PENDING questions (still assigned -> title only, so the CEO
# knows not to re-ask). "- (no open questions)" when there are none.
ceo_open_questions() {
  local repo="$1" reviewer="$2" issues q answered pending num title body comments
  issues=$(_fj GET "/repos/${repo}/issues?state=open&type=issues&limit=50" 2>/dev/null)
  q=$(jq -c --arg m "$CEO_QUESTION_MARKER" \
        '[ .[]? | select(.pull_request == null) | select((.body // "") | contains($m)) ]' \
        <<<"${issues:-[]}" 2>/dev/null || echo '[]')
  printf '### Your open board questions\n'
  if [ "$(jq 'length' <<<"$q" 2>/dev/null || echo 0)" -eq 0 ]; then
    printf -- '- (no open questions)\n'; return 0
  fi
  answered=$(jq -c --arg r "$reviewer" '[ .[] | select(([.assignees[]?.login] | index($r)) | not) ]' <<<"$q")
  pending=$(jq -c  --arg r "$reviewer" '[ .[] | select(([.assignees[]?.login] | index($r))) ]' <<<"$q")
  if [ "$(jq 'length' <<<"$answered")" -gt 0 ]; then
    printf '\n#### ANSWERED -- act on these now\n'
    while IFS= read -r num; do
      [ -n "$num" ] || continue
      title=$(jq -r --argjson n "$num" '.[] | select(.number==$n) | .title' <<<"$q")
      body=$(jq -r  --argjson n "$num" '.[] | select(.number==$n) | .body'  <<<"$q")
      comments=$(_fj GET "/repos/${repo}/issues/${num}/comments" 2>/dev/null \
        | jq -r '.[]? | "  > [\(.user.login)] \(.body)"' 2>/dev/null || true)
      printf '\n**#%s -- %s**\n%s\n\nBoard reply:\n%s\n' \
        "$num" "$title" "$body" "${comments:-(answered with no comment text)}"
    done < <(jq -r '.[].number' <<<"$answered")
  fi
  if [ "$(jq 'length' <<<"$pending")" -gt 0 ]; then
    printf '\n#### PENDING -- already asked, do NOT re-ask\n'
    jq -r '.[] | "- #\(.number) \(.title)"' <<<"$pending"
  fi
}

# ceo_open_items_count <repo> -- open issues carrying EITHER CEO marker (proposals
# + questions); the value the CEO_MAX_OPEN cap is checked against.
ceo_open_items_count() {
  local repo="$1"
  _fj GET "/repos/${repo}/issues?state=open&type=issues&limit=50" 2>/dev/null \
    | jq -r --arg p "$CEO_PROPOSAL_MARKER" --arg q "$CEO_QUESTION_MARKER" \
        '[ .[]? | select(.pull_request == null)
           | select(((.body // "") | contains($p)) or ((.body // "") | contains($q))) ] | length' \
        2>/dev/null || echo 0
}

# ---- Phase 4: the weekly digest as a respondable issue (retires the email) ----
# The brief moved off one-way email to the same two-way Forgejo channel as the
# questions/proposals: filed as an issue the board comments-to-steer / closes-to-drop,
# and the next week's digest folds in those comments. One open digest at a time.

# ceo_file_digest <repo> <title> <body> <reviewer> -- file the weekly board digest as
# a RESPONDABLE issue assigned to the reviewer, stamped with the digest marker. NOT a
# work item (no Agent label) and not counted toward CEO_MAX_OPEN.
ceo_file_digest() {
  local repo="$1" title="$2" body="$3" reviewer="$4" full payload
  full=$(printf '%s\n\n---\n_The weekly board digest. **Comment to steer** next week'"'"'s read; **close** to acknowledge or drop._\n%s' \
    "$body" "$CEO_DIGEST_MARKER")
  payload=$(jq -n --arg t "$title" --arg b "$full" --arg a "$reviewer" \
    '{title: $t, body: $b, assignees: [$a]}')
  _fj POST "/repos/${repo}/issues" "$payload" >/dev/null 2>&1
}

# ceo_prior_digest_number <repo> -- the number of the open ceo-digest issue (last
# week's, awaiting the board's steering), empty if none.
ceo_prior_digest_number() {
  local repo="$1"
  _fj GET "/repos/${repo}/issues?state=open&type=issues&limit=50" 2>/dev/null \
    | jq -r --arg m "$CEO_DIGEST_MARKER" \
        '[ .[]? | select(.pull_request == null) | select((.body // "") | contains($m)) | .number ] | .[0] // empty' \
        2>/dev/null || true
}

# ceo_prior_digest_steering <repo> -- last week's open digest body + the board's
# comments, as a markdown block the next digest folds in. Empty if no prior digest.
ceo_prior_digest_steering() {
  local repo="$1" issues num title body comments
  issues=$(_fj GET "/repos/${repo}/issues?state=open&type=issues&limit=50" 2>/dev/null)
  num=$(jq -r --arg m "$CEO_DIGEST_MARKER" \
    '[ .[]? | select(.pull_request == null) | select((.body // "") | contains($m)) | .number ] | .[0] // empty' \
    <<<"${issues:-[]}" 2>/dev/null)
  [ -n "$num" ] || return 0
  title=$(jq -r --argjson n "$num" '[ .[]? | select(.number == $n) | .title ] | .[0] // ""' <<<"$issues" 2>/dev/null)
  body=$(jq -r --argjson n "$num" '[ .[]? | select(.number == $n) | .body ] | .[0] // ""' <<<"$issues" 2>/dev/null)
  comments=$(_fj GET "/repos/${repo}/issues/${num}/comments" 2>/dev/null \
    | jq -r '.[]? | "> [\(.user.login)] \(.body)"' 2>/dev/null || true)
  printf '## Last week'"'"'s digest + the board'"'"'s steering (incorporate this)\n\n### Your digest #%s -- %s\n\n%s\n\n### The board commented\n%s\n' \
    "$num" "$title" "$body" "${comments:-(no comments -- the board read it without steering)}"
}

# ---- Phase 4 follow-up: reconsidering a proposal the board handed back ----
# A proposal is filed assigned to the reviewer. Greenlight = add the Agent label
# (+ unassign); decline = close. A THIRD path: the reviewer comments feedback and
# unassigns WITHOUT the Agent label -- handing it back to reconsider, not approving
# and not killing. The CEO reads the feedback and WITHDRAWs / REVISEs / HOLDs. This
# is NOT doing the proposed work (that stays the Agent-label-then-grind path).

# ceo_responded_proposal_numbers <repo> <reviewer> -- newline list of open proposal
# issues the reviewer unassigned themselves from, did NOT Agent-label, and left at
# least one comment on (the "reconsider this with my feedback" signal).
ceo_responded_proposal_numbers() {
  local repo="$1" reviewer="$2"
  _fj GET "/repos/${repo}/issues?state=open&type=issues&limit=50" 2>/dev/null \
    | jq -r --arg m "$CEO_PROPOSAL_MARKER" --arg r "$reviewer" '
        .[]? | select(.pull_request == null) | select((.body // "") | contains($m))
        | select(([.assignees[]?.login] | index($r)) | not)
        | select(([.labels[]?.name] | index("Agent")) | not)
        | select((.comments // 0) > 0)
        | .number' 2>/dev/null || true
}

# ceo_proposal_thread <repo> <number> -- the proposal body + the board's comment
# thread, as the markdown the reconsider prompt reads.
ceo_proposal_thread() {
  local repo="$1" num="$2" issue title body comments
  issue=$(_fj GET "/repos/${repo}/issues/${num}" 2>/dev/null)
  title=$(jq -r '.title // ""' <<<"$issue" 2>/dev/null)
  body=$(jq -r '.body // ""' <<<"$issue" 2>/dev/null)
  comments=$(_fj GET "/repos/${repo}/issues/${num}/comments" 2>/dev/null \
    | jq -r '.[]? | "> [\(.user.login)] \(.body)"' 2>/dev/null || true)
  printf '### Your proposal #%s -- %s\n\n%s\n\n### The board handed it back with this feedback\n%s\n' \
    "$num" "$title" "$body" "${comments:-(handed back with no comment text)}"
}

# ceo_build_reconsider_prompt <repo> <mandate> <thread> -- the user prompt for the
# reconsider model call. Self-contained output contract (DECISION / ===REPLY=== /
# optional ===ISSUE===), distinct from the digest format.
ceo_build_reconsider_prompt() {
  local repo="$1" mandate="$2" thread="$3"
  printf 'You filed a proposal for **%s**; the board did NOT greenlight it -- they left feedback and handed it back to reconsider. A focused decision, not a digest.

## Your mandate (CEO.md)

%s

## The proposal + the board feedback

%s

## Your call

Reconsider it against the feedback and the mandate, and choose ONE:
- WITHDRAW -- the board is right (redundant, wrong-premised, or not worth it). Close it gracefully.
- REVISE -- the goal stands but the shape should change. Re-file a sharper version that answers the feedback.
- HOLD -- you still back it as-is; make the case briefly.

Be a real partner: concede when they are right, push back with reasons when you are. Conversational, in your own voice -- not a form letter, and never sign off (no `-- CEO` or closing signature).

## Output format (parsed exactly)

- First line: DECISION: WITHDRAW (or REVISE or HOLD).
- Then a line exactly ===REPLY===, then your reply to the board in Markdown -- a few sentences addressed to them, acknowledging their point and explaining your call.
- THEN, only for REVISE, a line exactly ===ISSUE===, then TITLE: <single-line title>, then the revised proposal body (your read first, then scope, acceptance criteria, the priority it serves).
- Nothing else; no code fence around the whole response.' \
    "$repo" "$mandate" "$thread"
}

# ceo_parse_reconsider <raw> -- parse the reconsider response into harness-built JSON
# {decision, reply, issue:{title,body}|null}. rc=1 if the DECISION line or ===REPLY===
# body is missing (caller retries). Never model-written JSON.
ceo_parse_reconsider() {
  local raw="$1" decision after reply issue
  decision=$(printf '%s\n' "$raw" | sed -n 's/^[[:space:]]*DECISION:[[:space:]]*//p' \
    | head -1 | tr '[:lower:]' '[:upper:]' | grep -oE 'WITHDRAW|REVISE|HOLD' | head -1)
  [ -n "$decision" ] || return 1
  case "$raw" in *'===REPLY==='*) ;; *) return 1 ;; esac
  after="${raw#*===REPLY===}"
  reply="${after%%===ISSUE===*}"
  reply=$(printf '%s\n' "$reply" | _ceo_trim_blanks)
  [ -n "$reply" ] || return 1
  issue='null'
  case "$after" in
    *'===ISSUE==='*) issue=$(_ceo_parse_issues "$after" | jq -c '.[0] // null') ;;
  esac
  jq -n --arg d "$decision" --arg r "$reply" --argjson i "${issue:-null}" \
    '{decision:$d, reply:$r, issue:$i}'
}

# ---- Phase 4 follow-up: code-check gate (vet a proposal against the real code) ----
# The CEO drafts proposals BLIND to the code (mandate + metrics + tracker activity,
# never the repo), so it can pitch already-done work (porksicle #101: per-game SEO
# meta that already existed). Before filing, vet each proposal against the repo's
# CURRENT code and DROP what's already implemented -- the sharp dev going "you know
# we already do that, right?"
#
# TOOL-FREE by design: two `claude_call` passes (keywords, then verdict) + a
# `git grep` -- NO agentic tools, so the gate can never be an exfiltration channel
# (see the #241 "read-only != safe" finding). Its ONLY outward effect is the
# keep/drop decision; the reason is logged LOCALLY and never posted, emailed, or fed
# into any model call whose output escapes. Fail-OPEN (KEEP) on any error or
# uncertainty -- the gate suppresses busywork, it must never silently eat a real
# proposal.

# ceo_codecheck_clone_path <repo> -- the harness's local clone path, empty if absent.
ceo_codecheck_clone_path() {
  local repo="$1" p="${AGENT_STATE_DIR:-$HOME/.local/state/agent}/repos/${repo}"
  [ -d "$p/.git" ] && printf '%s' "$p"
}

# ceo_codecheck_proposal <repo> <title> <body> -- echo KEEP or DROP. DROP only when
# confident the work already exists in the code; KEEP on any error or uncertainty.
ceo_codecheck_proposal() {
  local repo="$1" title="$2" body="$3" clone model terms grepout verdict decision reason
  clone=$(ceo_codecheck_clone_path "$repo")
  [ -n "$clone" ] || { echo KEEP; return 0; }   # no clone -> can't vet -> file it
  model="${AGENT_MODEL_REVIEW:-${AGENT_MODEL:-}}"
  git -C "$clone" fetch -q origin 2>/dev/null || true
  # 1) derive distinctive search keywords (tool-free).
  terms=$(claude_call "$model" "ceo-codecheck-terms" 400 \
    "Output ONLY search keywords, one per line. No prose, no numbering, no explanation." \
    "$(printf 'A CEO proposed this work for %s:\n\nTITLE: %s\n\n%s\n\nGive 4-6 short, distinctive keywords (plain words or paths, no regex) that grepped against the codebase would reveal whether this is ALREADY implemented.' "$repo" "$title" "$body")" \
    1 90) || { echo KEEP; return 0; }
  terms=$(printf '%s\n' "$terms" | grep -oE '[[:alnum:]_./-]{3,}' | head -6 || true)
  [ -n "$terms" ] || { echo KEEP; return 0; }
  # 2) grep origin/master directly (reads the ref, not a stale working tree).
  local args=() t
  while IFS= read -r t; do [ -n "$t" ] && args+=( -e "$t" ); done <<<"$terms"
  [ "${#args[@]}" -gt 0 ] || { echo KEEP; return 0; }
  grepout=$(git -C "$clone" grep -nI -i "${args[@]}" origin/master 2>/dev/null | head -c 8000 || true)
  # 3) verdict (tool-free).
  verdict=$(claude_call "$model" "ceo-codecheck" 500 \
    "You are a sharp engineer vetting a CEO proposal against the real codebase. Reply with EXACTLY two lines: 'VERDICT: KEEP' or 'VERDICT: DROP', then 'REASON: <short>'. DROP only if the proposal is ALREADY implemented in the code shown, or clearly redundant/invalid. If the evidence is thin or ambiguous, KEEP. Nothing else." \
    "$(printf 'Proposal for %s:\nTITLE: %s\n\n%s\n\n--- codebase grep (origin/master), relevant keywords ---\n%s\n--- end ---\n\nAlready implemented? KEEP (worth doing) or DROP (already done / redundant).' "$repo" "$title" "$body" "${grepout:-(no matches found)}")" \
    1 120) || { echo KEEP; return 0; }
  decision=$(printf '%s\n' "$verdict" | sed -n 's/.*VERDICT:[[:space:]]*//p' | grep -oiE 'KEEP|DROP' | head -1 | tr '[:lower:]' '[:upper:]' || true)
  if [ "$decision" = "DROP" ]; then
    reason=$(printf '%s\n' "$verdict" | sed -n 's/.*REASON:[[:space:]]*//p' | head -1)
    log "ceo: code-check DROPPED proposal '${title}' on ${repo} -- ${reason:-already implemented in the code}"
    echo DROP
  else
    echo KEEP
  fi
}

# ceo_revise_refile <repo> <rnum> <issue_json> <assignee>
# REVISE reconsider path: runs the code-check gate on the revised title/body.
# KEEP -> file the new proposal (returns 0); DROP -> post a one-line comment on
# the old (already-closed) issue and skip re-file (returns 1). Fail-open: any
# error inside the gate echoes KEEP so no real proposal is silently eaten.
ceo_revise_refile() {
  local repo="$1" rnum="$2" rissue_json="$3" assignee="$4" rtitle rbody
  rtitle=$(jq -r '.title' <<<"$rissue_json")
  rbody=$(jq -r '.body' <<<"$rissue_json")
  if [ "$(ceo_codecheck_proposal "$repo" "$rtitle" "$rbody")" = "DROP" ]; then
    _fj POST "/repos/${repo}/issues/${rnum}/comments" \
      "$(jq -n '{body:"Revised proposal dropped by the code-check gate -- the work appears to already be covered in the code."}')" >/dev/null 2>&1 || true
    return 1
  fi
  ceo_file_proposal "$repo" "$rtitle" "$rbody" "$assignee"
}

# ---- Phase 3: decision-guidance redlines (the CEO drafts, the board ratifies) ----
# Weekly, the CEO observes how the board ruled on its prior proposals -- greenlit
# (Agent-labeled), declined (closed, no label), pending -- distills ONE
# decision-guidance entry, and opens a PR appending it to a "## Decision guidance"
# section in CEO.md. APPEND-ONLY: it adds what it's learned, never rewrites or
# erases existing guidance (a bad entry is at worst a bullet the board declines).
# Josh prunes on merge. Throttled to one open PR so redlines never stack.
CEO_GUIDANCE_MARKER="<!-- ceo-guidance -->"

# ceo_proposal_outcomes <repo> -- markdown summary of the board's verdicts on the
# CEO's prior proposals: the revealed-decision signal the model distills.
ceo_proposal_outcomes() {
  local repo="$1"
  printf '### Board verdicts on prior CEO proposals\n'
  _fj GET "/repos/${repo}/issues?state=all&type=issues&limit=50" 2>/dev/null \
    | jq -r --arg m "$CEO_PROPOSAL_MARKER" '
        [ .[]? | select(.pull_request == null) | select((.body // "") | contains($m)) ] as $p
        | if ($p | length) == 0 then "- (no prior proposals yet)"
          else ( $p[]
            | (.labels // [] | map(.name)) as $l
            | if ($l | index("Agent")) then "- GREENLIT: \(.title)"
              elif .state == "closed" then "- DECLINED: \(.title)"
              else "- PENDING: \(.title)" end ) end
      ' 2>/dev/null || printf -- '- (none)\n'
}

# ceo_guidance_pr_open <repo> -- exit 0 if an open CEO guidance PR already exists
# (head branch ceo-guidance-*), so we never stack unratified redlines.
ceo_guidance_pr_open() {
  local repo="$1"
  forgejo_list_open_bot_prs "$repo" "$BOT_USER" 2>/dev/null \
    | jq -e '[ .[]? | select((.head.ref // "") | startswith("ceo-guidance")) ] | length > 0' \
        >/dev/null 2>&1
}

# ceo_open_guidance_pr <repo> <guidance> <reviewer> -- append <guidance> to the
# "## Decision guidance" section of CEO.md (creating it if absent) and open a PR
# assigned to <reviewer>. API-driven (contents PUT + new_branch, no clone).
ceo_open_guidance_pr() {
  local repo="$1" guidance="$2" reviewer="$3"
  local meta sha content week branch base new_b64 put_body pr_body
  meta=$(_fj GET "/repos/${repo}/contents/${CEO_MANDATE_PATH}" 2>/dev/null) || return 1
  sha=$(jq -r '.sha // empty' <<<"$meta")
  content=$(jq -r '.content // empty' <<<"$meta" | base64 -d 2>/dev/null)
  [ -n "$sha" ] && [ -n "$content" ] || return 1
  # Append-only: ensure the section exists, then append the bullet at the END of
  # the file. Assumes "## Decision guidance" stays the LAST section of CEO.md (the
  # harness only ever appends there); if a human moves it above other sections,
  # new bullets would land under the wrong heading.
  grep -q '^## Decision guidance' <<<"$content" \
    || content="${content}"$'\n## Decision guidance\n'
  week=$(date +%G-W%V)
  content="${content}"$'\n- '"${week}: ${guidance}"
  # week + epoch so a merged-but-undeleted same-week branch can't block a later
  # redline on the new_branch PUT (the open-PR throttle doesn't cover that case).
  branch="ceo-guidance-${week}-$(date +%s)"
  base=$(_fj GET "/repos/${repo}" 2>/dev/null | jq -r '.default_branch // "master"')
  new_b64=$(printf '%s\n' "$content" | base64 -w0 2>/dev/null || printf '%s\n' "$content" | base64 | tr -d '\n')
  put_body=$(jq -n --arg c "$new_b64" --arg m "chore(ceo): decision-guidance redline (${week})" \
    --arg b "$base" --arg nb "$branch" --arg s "$sha" \
    '{content:$c, message:$m, branch:$b, new_branch:$nb, sha:$s}')
  _fj PUT "/repos/${repo}/contents/${CEO_MANDATE_PATH}" "$put_body" >/dev/null 2>&1 || return 1
  pr_body=$(printf 'The CEO drafts; the board ratifies. Distilled from this week'"'"'s verdicts on its proposals -- proposed addition to **Decision guidance** in `%s`:\n\n> %s\n\nMerge to ratify, edit to refine, close to decline.\n%s' \
    "$CEO_MANDATE_PATH" "$guidance" "$CEO_GUIDANCE_MARKER")
  forgejo_open_pr "$repo" "$branch" "$base" \
    "chore(ceo): decision-guidance redline (${week})" "$pr_body" "$reviewer" >/dev/null 2>&1
}
