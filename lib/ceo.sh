#!/usr/bin/env bash
# ceo.sh -- the CEO pass's READ side: convention-driven opt-in via a repo's
# .agent/ceo.md mandate, plus a weekly activity gather for the board digest.
#
# Opt-in is the mandate's mere presence -- exactly like logwatch keys off a
# root systemd/ dir and the review tick keys off the merge. A repo that grows a
# .agent/ceo.md is under autonomous CEO management; no env knob, no hardcoded
# repo. (See the mandate itself: "the mandate's mere presence in the repo is
# what opts [it] into autonomous CEO management.")
#
# Phase 1 is strictly read-only: read the mandate, gather the week, hand both to
# one model call that writes the board digest. No issue-filing / steering /
# doc-edits yet -- those are later phases, per the mandate's "start tight,
# loosen as trust earns it" rope.
#
# Sourced by tick.sh; depends on _fj (lib/forgejo.sh) + jq.

CEO_MANDATE_PATH=".agent/ceo.md"
# Stamped (HTML comment) into every CEO-proposed issue body so the next week's
# pass can tell whether the last batch has been triaged -- the proposal throttle.
CEO_PROPOSAL_MARKER="<!-- ceo-proposal -->"

# ceo_read_mandate <repo> -- echo the mandate's raw content, empty if absent.
# This IS the opt-in probe: a present .agent/ceo.md returns its body, a missing
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
  local prs issues_recent agent_queue

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

  printf '### Open Agent queue\n'
  agent_queue=$(_fj GET "/repos/${repo}/issues?state=open&type=issues&labels=Agent&limit=50" 2>/dev/null)
  jq -r '
    [ (.[]? | select(.pull_request == null)) ]
    | if length==0 then "- (none)" else (.[] | "- #\(.number) \(.title)") end
  ' <<<"${agent_queue:-[]}" 2>/dev/null || printf -- '- (none)\n'
}

# ---- digest assembly: prompt, parse, render (mirrors sports-digest.sh) ----

# ceo_build_prompt <repo> <mandate> <activity> <since_iso>
# Assembles the USER prompt: the board mandate (the north-star) + the week's
# activity. The SYSTEM prompt (CEO persona, what the digest must do, the output
# contract) lives in bin/lib/ceo-digest-directive.md.
ceo_build_prompt() {
  local repo="$1" mandate="$2" activity="$3" since="$4"
  printf 'You are writing the weekly board digest for **%s**, covering activity since %s.

## The mandate (.agent/ceo.md) -- your north-star

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
  printf '%s' "$issues"
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
  local raw="$1" head rest body subject_line issues
  case "$raw" in
    *'===BODY==='*) ;;
    *) return 1 ;;
  esac
  head="${raw%%===BODY===*}"
  rest="${raw#*===BODY===}"
  body="${rest%%===ISSUE===*}"            # digest = up to the first proposal block
  printf '%s' "$body" | grep -q '[^[:space:]]' || return 1
  body=$(printf '%s\n' "$body" | _ceo_trim_blanks)
  subject_line=$(printf '%s' "$head" | sed -n 's/^SUBJECT:[[:space:]]*//p' | head -1)
  issues=$(_ceo_parse_issues "$rest")
  jq -n --arg s "$subject_line" --arg b "$body" --argjson i "${issues:-[]}" \
    '{subject:$s, body:$b, issues:$i}'
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
# shape of .seo/.market/.sports. Per-repo so several managed repos each get
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
