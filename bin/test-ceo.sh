#!/usr/bin/env bash
# test-ceo.sh -- unit tests for the pure functions in lib/ceo.sh.
#
# Covers the directly-testable surface the CEO digest leans on:
#   - ceo_parse_response  (sentinel parsing + blank-collapsing awk)
#   - ceo_render_html     (markdown -> HTML, with escaping)
#   - ceo_week_done / ceo_mark_week_done  (per-repo weekly state round-trip)
#   - ceo_gather_week     (the jq activity filters, with _fj stubbed)
#
# Run standalone (`bin/test-ceo.sh`) or via `make test` -- check-sync.sh
# discovers and runs every bin/test-*.sh. Skip-safe: if a required tool is
# absent it exits 0 with a notice, so a minimal CI image stays green while
# this acts as a real gate wherever the deps exist.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"

for tool in jq awk sed date mktemp; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "test-ceo: $tool not installed -- skipping"; exit 0; }
done

# shellcheck source=lib/ceo.sh
. "$HERE/lib/ceo.sh"

fails=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; fails=$((fails + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi; }
has()    { case "$2" in *"$3"*) ok "$1";; *) bad "$1: missing [$3]";; esac; }
hasnt()  { case "$2" in *"$3"*) bad "$1: unexpected [$3]";; *) ok "$1";; esac; }

# ---- ceo_parse_response -------------------------------------------------
echo "== ceo_parse_response =="
run_parse() {  # <raw> -- sets RC and OUT (RC=1 on parse failure)
  if OUT=$(ceo_parse_response "$1"); then RC=0; else RC=1; fi
}

run_parse "$(printf 'SUBJECT: Week of Jun 18\n===BODY===\nFirst line.\nSecond line.')"
eq "happy: rc 0"     0 "$RC"
eq "happy: subject"  "Week of Jun 18"                   "$(jq -r '.subject' <<<"$OUT")"
eq "happy: body"     "$(printf 'First line.\nSecond line.')" "$(jq -r '.body' <<<"$OUT")"

run_parse "$(printf 'SUBJECT: x\nno sentinel anywhere')"
eq "missing ===BODY===: rc 1" 1 "$RC"

run_parse "$(printf 'SUBJECT: x\n===BODY===\n   \n\t')"
eq "whitespace-only body: rc 1" 1 "$RC"

run_parse "$(printf '===BODY===\nBody with no subject line.')"
eq "no SUBJECT: rc 0"        0 "$RC"
eq "no SUBJECT: empty subj"  "" "$(jq -r '.subject' <<<"$OUT")"
eq "no SUBJECT: body kept"   "Body with no subject line." "$(jq -r '.body' <<<"$OUT")"

run_parse "$(printf 'SUBJECT: t\n===BODY===\n\n\nAlpha.\n\nOmega.\n\n')"
eq "blank-collapse: leading/trailing trimmed, interior kept" \
   "$(printf 'Alpha.\n\nOmega.')" "$(jq -r '.body' <<<"$OUT")"

# ---- ceo_parse_response: proposals (===ISSUE=== blocks) -----------------
echo "== ceo_parse_response proposals =="

run_parse "$(printf 'SUBJECT: s\n===BODY===\nThe digest.')"
eq "no proposals: issues == []" "[]" "$(jq -c '.issues' <<<"$OUT")"

run_parse "$(printf 'SUBJECT: s\n===BODY===\nThe digest.\n===ISSUE===\nTITLE: Internal linking\nAdd related-games links.\nServes priority #1.\n===ISSUE===\nTITLE: Hub copy\nFlesh out category hubs.')"
eq "two proposals: count"         2 "$(jq '.issues | length' <<<"$OUT")"
eq "two proposals: title 1"       "Internal linking" "$(jq -r '.issues[0].title' <<<"$OUT")"
eq "two proposals: body 1"        "$(printf 'Add related-games links.\nServes priority #1.')" "$(jq -r '.issues[0].body' <<<"$OUT")"
eq "two proposals: title 2"       "Hub copy" "$(jq -r '.issues[1].title' <<<"$OUT")"
eq "two proposals: digest body excludes the issues" "The digest." "$(jq -r '.body' <<<"$OUT")"

run_parse "$(printf 'SUBJECT: s\n===BODY===\nD.\n===ISSUE===\nTITLE: Only one\nbody here')"
eq "one proposal: count" 1 "$(jq '.issues | length' <<<"$OUT")"
eq "one proposal: title" "Only one" "$(jq -r '.issues[0].title' <<<"$OUT")"

run_parse "$(printf 'SUBJECT: s\n===BODY===\nD.\n===ISSUE===\nno title line\n===ISSUE===\nTITLE: Valid\nok')"
eq "malformed block (no TITLE:) skipped: count" 1 "$(jq '.issues | length' <<<"$OUT")"
eq "malformed block skipped: keeps the valid one" "Valid" "$(jq -r '.issues[0].title' <<<"$OUT")"

run_parse "$(printf 'SUBJECT: s\n===BODY===\nD.\n===ISSUE===\nTITLE: One\na\n===ISSUE===\nTITLE: Two\nb\n===ISSUE===\nTITLE: Three\nc')"
eq "clamp: 3 blocks capped to 2" 2     "$(jq '.issues | length' <<<"$OUT")"
eq "clamp: keeps the first two"  "Two" "$(jq -r '.issues[1].title' <<<"$OUT")"

# Phase 3: the ===GUIDANCE=== section
run_parse "$(printf 'SUBJECT: s\n===BODY===\nThe digest.')"
eq "guidance: absent -> empty" "" "$(jq -r '.guidance' <<<"$OUT")"
run_parse "$(printf 'SUBJECT: s\n===BODY===\nThe digest.\n===GUIDANCE===\nFavor growth-lever work over volume.')"
eq "guidance: parsed"           "Favor growth-lever work over volume." "$(jq -r '.guidance' <<<"$OUT")"
eq "guidance: body excludes it" "The digest."                          "$(jq -r '.body' <<<"$OUT")"
run_parse "$(printf 'SUBJECT: s\n===BODY===\nD.\n===ISSUE===\nTITLE: X\nbody\n===GUIDANCE===\nG line.')"
eq "guidance: coexists with an issue (count)"    1        "$(jq '.issues | length' <<<"$OUT")"
eq "guidance: coexists with an issue (guidance)" "G line." "$(jq -r '.guidance' <<<"$OUT")"

# ---- ceo_parse_response: questions (===QUESTION=== blocks, Phase 4) ------
echo "== ceo_parse_response questions =="

run_parse "$(printf 'SUBJECT: s\n===BODY===\nThe digest.')"
eq "no questions: questions == []" "[]" "$(jq -c '.questions' <<<"$OUT")"

run_parse "$(printf 'SUBJECT: s\n===BODY===\nThe digest.\n===QUESTION===\nTITLE: Pricing call\nAds or no ads?\n===QUESTION===\nTITLE: Brand\nRename the pig?')"
eq "two questions: count"            2               "$(jq '.questions | length' <<<"$OUT")"
eq "two questions: title 1"          "Pricing call"  "$(jq -r '.questions[0].title' <<<"$OUT")"
eq "two questions: body 1"           "Ads or no ads?" "$(jq -r '.questions[0].body' <<<"$OUT")"
eq "two questions: body excludes them" "The digest."  "$(jq -r '.body' <<<"$OUT")"

run_parse "$(printf 'SUBJECT: s\n===BODY===\nD.\n===QUESTION===\nTITLE: Q1\na\n===QUESTION===\nTITLE: Q2\nb\n===QUESTION===\nTITLE: Q3\nc')"
eq "questions: 3 blocks capped to 2" 2 "$(jq '.questions | length' <<<"$OUT")"

# Issues AND questions together (contract order: issues, then questions).
run_parse "$(printf 'SUBJECT: s\n===BODY===\nD.\n===ISSUE===\nTITLE: Work\nwork body\n===QUESTION===\nTITLE: Ask\nask body')"
eq "mixed: issues count"    1      "$(jq '.issues | length' <<<"$OUT")"
eq "mixed: issue body excludes the question" "work body" "$(jq -r '.issues[0].body' <<<"$OUT")"
eq "mixed: questions count" 1      "$(jq '.questions | length' <<<"$OUT")"
eq "mixed: question title"  "Ask"  "$(jq -r '.questions[0].title' <<<"$OUT")"
eq "mixed: digest body"     "D."   "$(jq -r '.body' <<<"$OUT")"

# Body must stop at a leading ===QUESTION=== even with no issues.
run_parse "$(printf 'SUBJECT: s\n===BODY===\nJust the digest.\n===QUESTION===\nTITLE: Q\nq body')"
eq "question-only: body stops at the question" "Just the digest." "$(jq -r '.body' <<<"$OUT")"
eq "question-only: issues empty"               "[]"               "$(jq -c '.issues' <<<"$OUT")"
eq "question-only: question parsed"            "Q"                "$(jq -r '.questions[0].title' <<<"$OUT")"

# Questions coexist with guidance (order: issues, questions, guidance).
run_parse "$(printf 'SUBJECT: s\n===BODY===\nD.\n===QUESTION===\nTITLE: Q\nqb\n===GUIDANCE===\nG.')"
eq "q+guidance: question parsed" "Q"  "$(jq -r '.questions[0].title' <<<"$OUT")"
eq "q+guidance: guidance parsed" "G." "$(jq -r '.guidance' <<<"$OUT")"
eq "q+guidance: body clean"      "D." "$(jq -r '.body' <<<"$OUT")"

# ---- ceo_render_html ----------------------------------------------------
echo "== ceo_render_html =="
html="$(ceo_render_html <<<"$(printf '## The win\n- ship **verify**\n\nA <tag> & co.')")"
has "render: h3 heading"        "$html" "<h3>The win</h3>"
has "render: list item + bold"  "$html" "<li>ship <strong>verify</strong></li>"
has "render: html-escapes < > &" "$html" "A &lt;tag&gt; &amp; co."

# ---- ceo_week_done / ceo_mark_week_done ---------------------------------
echo "== ceo_week_done / ceo_mark_week_done =="
state_dir="$(mktemp -d)"
trap 'rm -rf "$state_dir"' EXIT
export AGENT_STATE_DIR="$state_dir"
state_file="$state_dir/discretionary-state.json"
repo="acme/widgets"

if ceo_week_done "$repo"; then bad "fresh: not done"; else ok "fresh: not done"; fi
ceo_mark_week_done "$repo"
if ceo_week_done "$repo"; then ok "after mark: done"; else bad "after mark: done"; fi
if ceo_week_done "acme/other"; then bad "other repo: not done"; else ok "other repo: not done"; fi
eq "stamp = this ISO week" "$(date +%G-W%V)" "$(jq -r --arg r "$repo" '.ceo[$r]' "$state_file")"

# A stale stamp (different ISO week) must read as not-done.
tmp="$(mktemp)"
jq --arg r "$repo" '.ceo[$r] = "1999-W01"' "$state_file" > "$tmp" && mv "$tmp" "$state_file"
if ceo_week_done "$repo"; then bad "stale stamp: not done"; else ok "stale stamp: not done"; fi

# Re-marking is idempotent and restores done.
ceo_mark_week_done "$repo"
if ceo_week_done "$repo"; then ok "re-mark: done again"; else bad "re-mark: done again"; fi

# ---- ceo_gather_week (jq filters, with _fj stubbed) ---------------------
echo "== ceo_gather_week =="
_fj() {  # override forgejo.sh's API caller: route canned JSON by URL path
  case "$2" in
    */pulls*)        printf '%s' "$STUB_PULLS" ;;
    *labels=Agent*)  printf '%s' "$STUB_AGENT" ;;
    */issues*)       printf '%s' "$STUB_ISSUES" ;;
    *)               printf '[]' ;;
  esac
}
since="2026-06-18T00:00:00Z"
STUB_PULLS='[{"number":46,"title":"Add verify","merged_at":"2026-06-20T00:00:00Z","user":{"login":"igor"}},
             {"number":40,"title":"Stale","merged_at":"2026-01-01T00:00:00Z","user":{"login":"igor"}}]'
STUB_ISSUES='[{"number":51,"title":"Login bug","state":"open","created_at":"2026-06-19T00:00:00Z","closed_at":null,"pull_request":null},
              {"number":12,"title":"PR in disguise","created_at":"2026-06-19T00:00:00Z","pull_request":{"merged":false}}]'
STUB_AGENT='[{"number":51,"title":"Login bug","pull_request":null}]'

out="$(ceo_gather_week "$repo" "$since")"
has   "gather: merged PR in window"      "$out" "- #46 Add verify (by igor)"
hasnt "gather: pre-window PR excluded"   "$out" "#40"
has   "gather: opened issue rendered"    "$out" "- #51 [open] Login bug (opened)"
hasnt "gather: PR filtered from issues"  "$out" "#12"
has   "gather: open Agent queue"         "$out" "- #51 Login bug"

# ---- proposals: throttle (open count) + filing (unlabeled/assigned/marked) ---
echo "== ceo proposals: throttle + file =="
PROPOSAL_GET='[]'; POST_BODY=''
_fj() {  # GET issues -> canned; POST issues -> capture the payload, succeed
  case "$1 $2" in
    "GET "*/issues*)  printf '%s' "$PROPOSAL_GET" ;;
    "POST "*/issues*) POST_BODY="$3" ;;
    *)                printf '%s' '{}' ;;
  esac
}
PROPOSAL_GET=$(jq -c -n --arg m "$CEO_PROPOSAL_MARKER" '[
  {number:1, pull_request:null, body:("proposal a\n"+$m)},
  {number:2, pull_request:null, body:"human-filed, no marker"},
  {number:3, pull_request:null, body:("proposal b\n"+$m)}]')
eq "throttle: counts only marked proposals" 2 "$(ceo_open_proposals_count acme/x)"
PROPOSAL_GET='[]'
eq "throttle: none open -> 0"               0 "$(ceo_open_proposals_count acme/x)"

ceo_file_proposal "acme/x" "Add related-games links" "scope + acceptance" "joshtronic"
eq  "file: title in payload"      "Add related-games links" "$(jq -r '.title' <<<"$POST_BODY")"
eq  "file: assigned to the human" "joshtronic"              "$(jq -r '.assignees[0]' <<<"$POST_BODY")"
eq  "file: unlabeled"             "0"                       "$(jq -r '(.labels // []) | length' <<<"$POST_BODY")"
has "file: body carries marker"   "$(jq -r '.body' <<<"$POST_BODY")" "$CEO_PROPOSAL_MARKER"

# ---- ceo_proposal_outcomes (board verdicts -> the Phase-3 signal) --------
echo "== ceo_proposal_outcomes =="
PROPOSAL_GET=$(jq -c -n --arg m "$CEO_PROPOSAL_MARKER" '[
  {title:"SEO links",   state:"open",   pull_request:null, labels:[{name:"Agent"}], body:("p\n"+$m)},
  {title:"Catalog pad", state:"closed", pull_request:null, labels:[],               body:("p\n"+$m)},
  {title:"Smoke test",  state:"open",   pull_request:null, labels:[],               body:("p\n"+$m)},
  {title:"Human issue", state:"open",   pull_request:null, labels:[],               body:"no marker"}]')
out="$(ceo_proposal_outcomes acme/x)"
has   "outcomes: greenlit = Agent-labeled"    "$out" "- GREENLIT: SEO links"
has   "outcomes: declined = closed, no label" "$out" "- DECLINED: Catalog pad"
has   "outcomes: pending = open, no label"    "$out" "- PENDING: Smoke test"
hasnt "outcomes: ignores non-proposals"       "$out" "Human issue"

# ---- ceo_open_guidance_pr (the redline builder -- the riskiest path) -----
echo "== ceo_open_guidance_pr =="
PUT_BODY=""
GUIDANCE_CONTENTS=$(jq -c -n --arg c "$(printf '# CEO Mandate\n\n## Success metrics\n\nstuff\n' | base64 -w0)" '{content:$c, sha:"deadbeef"}')
_fj() {  # GET contents -> canned; PUT contents -> capture the body; PR-open -> succeed
  case "$1 $2" in
    "GET "*/contents/*)  printf '%s' "$GUIDANCE_CONTENTS" ;;
    "PUT "*/contents/*)  PUT_BODY="$3" ;;
    "POST "*/pulls*)     printf '%s' '{"number":999}' ;;
    "GET "*)             printf '%s' '{"default_branch":"master"}' ;;
    *)                   printf '%s' '{}' ;;
  esac
}
forgejo_open_pr() { return 0; }   # not under test here -- just succeed; we assert on the PUT body
ceo_open_guidance_pr "acme/x" "Favor growth-lever work." "joshtronic" >/dev/null 2>&1 || true
new="$(jq -r '.content' <<<"$PUT_BODY" | base64 -d 2>/dev/null)"
has "redline: creates the Decision guidance header" "$new" "## Decision guidance"
has "redline: appends the guidance bullet"          "$new" ": Favor growth-lever work."
has "redline: new_branch is ceo-guidance-*"         "$(jq -r '.new_branch' <<<"$PUT_BODY")" "ceo-guidance-"
eq  "redline: PUTs with the file sha"               "deadbeef" "$(jq -r '.sha' <<<"$PUT_BODY")"

PUT_BODY=""
GUIDANCE_CONTENTS=$(jq -c -n --arg c "$(printf '# CEO Mandate\n\n## Decision guidance\n\n- old entry\n' | base64 -w0)" '{content:$c, sha:"deadbeef"}')
ceo_open_guidance_pr "acme/x" "Second entry." "joshtronic" >/dev/null 2>&1 || true
new="$(jq -r '.content' <<<"$PUT_BODY" | base64 -d 2>/dev/null)"
eq  "redline: header not duplicated when present" 1 "$(grep -c '## Decision guidance' <<<"$new")"
has "redline: keeps the existing entry"           "$new" "- old entry"
has "redline: appends the new entry"              "$new" ": Second entry."

echo "== ceo_guidance_pr_open (throttle) =="
BOT_USER="${BOT_USER:-igor}"   # ceo_guidance_pr_open passes it to the (stubbed) lister; bind it under set -u
forgejo_list_open_bot_prs() { printf '%s' "$BOT_PRS"; }
BOT_PRS='[{"head":{"ref":"ceo-guidance-2026-W26-1"}}]'
if ceo_guidance_pr_open acme/x; then r=throttled; else r=open; fi
eq "throttle: open ceo-guidance PR -> throttles" "throttled" "$r"
BOT_PRS='[{"head":{"ref":"agent/12-fix"}}]'
if ceo_guidance_pr_open acme/x; then r=throttled; else r=open; fi
eq "throttle: no ceo-guidance PR -> proceeds"    "open"      "$r"

# ---- Phase 4: ceo_file_question + ceo_open_items_count + answered ---------
# (Last, so its _fj redefinition doesn't leak into the sections above.)
echo "== ceo Phase 4: questions + open-item cap =="
Q_POST_FILE="$(mktemp)"; LABEL_NUM=''; LABEL_NAME=''; ITEMS_GET='[]'
_fj() {  # POST issues -> capture body to a FILE (survives the $() subshell in
         # ceo_file_question) + return a number; GET issues -> canned.
  case "$1 $2" in
    "POST "*/issues*) printf '%s' "$3" > "$Q_POST_FILE"; printf '%s' '{"number":77}' ;;
    "GET "*/issues*)  printf '%s' "$ITEMS_GET" ;;
    *)                printf '%s' '{}' ;;
  esac
}
forgejo_add_label() { LABEL_NUM="$2"; LABEL_NAME="$3"; }   # capture, succeed

ceo_file_question "acme/x" "Ads or no ads?" "options A/B" "joshtronic"
Q_POST_BODY="$(cat "$Q_POST_FILE")"
eq  "question: title in payload"        "Ads or no ads?"        "$(jq -r '.title' <<<"$Q_POST_BODY")"
eq  "question: assigned to reviewer"    "joshtronic"            "$(jq -r '.assignees[0]' <<<"$Q_POST_BODY")"
has "question: body carries marker"     "$(jq -r '.body' <<<"$Q_POST_BODY")" "$CEO_QUESTION_MARKER"
eq  "question: labels issue #77"        "77"                    "$LABEL_NUM"
eq  "question: applies Status/Need More Info" "Status/Need More Info" "$LABEL_NAME"

# open-item count: both markers, ignoring unmarked issues + PRs.
ITEMS_GET=$(jq -c -n --arg p "$CEO_PROPOSAL_MARKER" --arg q "$CEO_QUESTION_MARKER" '[
  {number:1, pull_request:null, body:("a\n"+$p)},
  {number:2, pull_request:null, body:("b\n"+$q)},
  {number:3, pull_request:null, body:"human, no marker"},
  {number:4, pull_request:{},   body:("pr\n"+$p)}]')
eq "open-items: counts proposals + questions, skips unmarked/PRs" 2 "$(ceo_open_items_count acme/x)"

# answered = reviewer has unassigned themselves from the (still-open) question.
ITEMS_GET=$(jq -c -n --arg q "$CEO_QUESTION_MARKER" '[
  {number:10, pull_request:null, assignees:[],                     body:("answered\n"+$q)},
  {number:11, pull_request:null, assignees:[{login:"joshtronic"}], body:("pending\n"+$q)},
  {number:12, pull_request:null, assignees:[{login:"someone"}],    body:("also answered\n"+$q)}]')
eq "answered: only reviewer-unassigned questions" "$(printf '10\n12')" "$(ceo_answered_question_numbers acme/x joshtronic)"

eq "cap: CEO_MAX_OPEN is 8" "8" "$CEO_MAX_OPEN"
rm -f "$Q_POST_FILE"

# ---- ceo_read_metrics (Phase 4: data-driven) ----------------------------
echo "== ceo_read_metrics =="
_M_TMP=$(mktemp -d); export AGENT_STATE_DIR="$_M_TMP"
_M_SF="$AGENT_STATE_DIR/discretionary-state.json"
_M_CFG=''   # what the agent.json read returns
_M_BODY=''  # what the metrics endpoint returns (empty => curl "fails")
forgejo_repo_get_file() { printf '%s' "$_M_CFG"; }
curl() { [ -n "$_M_BODY" ] && printf '%s' "$_M_BODY" || return 1; }

# no .ceo.metrics_url -> clean no-op (repo digests exactly as before)
_M_CFG='{"smoke":{"url":"https://x"}}'
eq "no metrics_url -> empty output" "" "$(ceo_read_metrics acme/x)"

# metrics_url + good reading -> surfaces numbers, stores, notes no prior yet
_M_CFG='{"ceo":{"metrics_url":"https://x/api/summary"}}'
_M_BODY='{"players":42,"plays":100,"ms_played":3600000}'
out=$(ceo_read_metrics acme/x)
has "good reading: header"        "$out" "Live metrics"
has "good reading: a live number" "$out" "42"
has "good reading: current label" "$out" "Current reading"
has "good reading: baseline note (no prior)" "$out" "baseline"
eq  "good reading: stored players=42" "42" "$(jq -r '.ceo_metrics["acme/x"].data.players' "$_M_SF" 2>/dev/null)"

# second call -> shows the PRIOR reading as the trend baseline
_M_BODY='{"players":50,"plays":130,"ms_played":4000000}'
out=$(ceo_read_metrics acme/x)
has "second call: previous-reading section" "$out" "Previous reading"
has "second call: prior number kept"        "$out" "42"
has "second call: new number present"       "$out" "50"
eq  "second call: stored advances to 50"     "50" "$(jq -r '.ceo_metrics["acme/x"].data.players' "$_M_SF" 2>/dev/null)"

# endpoint down -> unavailable note, prior reading NOT overwritten
_M_BODY=''
out=$(ceo_read_metrics acme/x)
has "endpoint down: unavailable note"        "$out" "unavailable"
eq  "endpoint down: prior reading preserved" "50" "$(jq -r '.ceo_metrics["acme/x"].data.players' "$_M_SF" 2>/dev/null)"

unset -f forgejo_repo_get_file curl; unset AGENT_STATE_DIR; rm -rf "$_M_TMP"

# ---- summary ------------------------------------------------------------
echo
if [ "$fails" -eq 0 ]; then
  echo "test-ceo: all checks passed"
  exit 0
fi
echo "test-ceo: $fails check(s) FAILED"
exit 1
