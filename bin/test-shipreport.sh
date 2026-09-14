#!/usr/bin/env bash
# test-shipreport.sh -- unit tests for lib/ship-report.sh: bucketing, the
# shadow-vs-human gate tag, empty-window handling, the daily stamp round-trip,
# and that the module makes NO model call (it's fully scripted). Also drives
# bin/tick.sh's shipreport_gather_judgment, lifted out and stubbed -- the one
# part of igor#610 that isn't pure. Skip-safe: needs jq; exits 0 with a notice
# if absent, like the other bin/test-*.sh.
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "test-shipreport: jq absent -- skipping"; exit 0; }

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/ship-report.sh
. "$HERE/../lib/ship-report.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export AGENT_STATE_DIR="$TMP"

FAIL=0
eq()  { if [ "$2" = "$3" ]; then printf '  + %s\n' "$1"; else printf '  x %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi; }
ok()  { local d="$1"; shift; if "$@" >/dev/null 2>&1; then printf '  + %s\n' "$d"; else printf '  x %s (expected rc0)\n' "$d"; FAIL=$((FAIL + 1)); fi; }
no()  { local d="$1"; shift; if "$@" >/dev/null 2>&1; then printf '  x %s (expected rc!=0)\n' "$d"; FAIL=$((FAIL + 1)); else printf '  + %s\n' "$d"; fi; }
has() { case "$2" in *"$3"*) printf '  + %s\n' "$1" ;; *) printf '  x %s: [%s] lacks [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)) ;; esac; }

echo "== shipreport_build: bucketing + gate tag =="
ITEMS='[
  {"repo":"acme/deffo","number":1,"title":"shadow merge","url":"u1","state":"merged","gate":"shadow","require_human":false},
  {"repo":"acme/carve","number":2,"title":"human merge","url":"u2","state":"merged","gate":"human","require_human":true},
  {"repo":"acme/carve","number":3,"title":"awaiting reviewer","url":"u3","state":"open","gate":"","require_human":true},
  {"repo":"acme/deffo","number":4,"title":"in the loop","url":"u4","state":"open","gate":"","require_human":false}
]'
REPORT=$(printf '%s' "$ITEMS" | shipreport_build)
eq "shipped: both merges"           "1 2" "$(jq -r '[.shipped[].number]|join(" ")' <<<"$REPORT")"
eq "needs_you: open carve-out PR"   "3"   "$(jq -r '[.needs_you[].number]|join(" ")' <<<"$REPORT")"
eq "inflight: open default PR"      "4"   "$(jq -r '[.inflight[].number]|join(" ")' <<<"$REPORT")"

echo "== shipreport_is_empty =="
ok "is_empty: all buckets empty"    shipreport_is_empty '{"needs_you":[],"shipped":[],"inflight":[]}'
no "is_empty: something present"    shipreport_is_empty "$REPORT"

echo "== renderers (text + html) =="
TEXT=$(printf '%s' "$REPORT" | shipreport_render_text)
has "text: NEEDS YOU section"       "$TEXT" "NEEDS YOU"
has "text: SHIPPED section"         "$TEXT" "SHIPPED"
has "text: tags a shadow merge"     "$TEXT" "[shadow]"
has "text: tags a human merge"      "$TEXT" "[you]"
has "text: lists the needs-you PR"  "$TEXT" "acme/carve#3"
HTML=$(printf '%s' "$REPORT" | shipreport_render_html)
has "html: wraps in a div"          "$HTML" "<div"
has "html: links a shipped PR"      "$HTML" 'href="u1"'
has "html: links the needs-you PR"  "$HTML" 'href="u3"'
has "html: escapes titles via @html" "$HTML" "shadow merge"

echo "== empty report renders cleanly (no crash, says so) =="
EMPTY=$(printf '%s' '{"needs_you":[],"shipped":[],"inflight":[]}' | shipreport_render_text)
has "empty text: nothing shipped"   "$EMPTY" "nothing shipped"

echo "== daily stamp round-trip =="
no "sent_today: fresh -> not sent"  shipreport_sent_today
shipreport_mark_sent
ok "sent_today: after mark -> sent" shipreport_sent_today

echo "== landed-note drain (igor#512): read / merge / is_empty / clear =="
eq "landed_read: nothing queued -> empty array" "[]" "$(shipreport_landed_read)"
MERGED_EMPTY=$(shipreport_merge_landed '{"needs_you":[],"shipped":[],"inflight":[]}' "[]")
eq "merge_landed with an empty array adds an empty landed key" "0" "$(jq -r '.landed | length' <<<"$MERGED_EMPTY")"
ok "is_empty: landed key present but empty still counts as empty" shipreport_is_empty "$MERGED_EMPTY"
ETEXT=$(shipreport_render_text <<<"$MERGED_EMPTY")
has "text: an explicitly-merged empty bucket renders an empty section" "$ETEXT" "(nothing landed)"
EHTML=$(shipreport_render_html <<<"$MERGED_EMPTY")
has "html: an explicitly-merged empty bucket renders an empty section" "$EHTML" "nothing landed"

LANDED_JSON='[{"repo":"joshtronic/igor","pr":"521","sha":"c0ffee1234567890","detail":"self-pull HEAD is c0ffee12"}]'
MERGED=$(shipreport_merge_landed '{"needs_you":[],"shipped":[],"inflight":[]}' "$LANDED_JSON")
no "is_empty: landed notes alone -> NOT empty (still sends)" shipreport_is_empty "$MERGED"
eq "merge_landed: one landed note present" "1" "$(jq -r '.landed | length' <<<"$MERGED")"

LTEXT=$(shipreport_render_text <<<"$MERGED")
has "text: LANDED section appears"          "$LTEXT" "LANDED"
has "text: names the landed repo#pr"        "$LTEXT" "joshtronic/igor#521"
has "text: truncates the sha to 8 chars"    "$LTEXT" "c0ffee12"
LHTML=$(shipreport_render_html <<<"$MERGED")
has "html: Landed heading appears"          "$LHTML" "Landed"
has "html: names the landed repo#pr"        "$LHTML" "joshtronic/igor#521"

NO_LANDED_TEXT=$(shipreport_render_text <<<"$REPORT")
if printf '%s' "$NO_LANDED_TEXT" | grep -q 'LANDED'; then
  printf '  x %s\n' "text: no LANDED section when the report never merged one in"; FAIL=$((FAIL + 1))
else
  printf '  + %s\n' "text: no LANDED section when the report never merged one in"
fi

sf="$AGENT_STATE_DIR/discretionary-state.json"
jq -n --argjson l "$LANDED_JSON" '{landed_notes: $l}' > "$sf"
eq "landed_read: reads back what was queued" "$LANDED_JSON" "$(shipreport_landed_read)"
shipreport_landed_clear
eq "landed_clear: drains the queue" "[]" "$(shipreport_landed_read)"
eq "landed_clear: is a no-op when the state file is missing" "[]" "$(rm -f "$sf"; shipreport_landed_clear; shipreport_landed_read)"

echo "== shipreport_metrics_build: merges cost/timing/version into one object =="
COST_NOW='{"count":2,"has_data":true,"total_usd":12.3,"by_site":[{"site":"tier-1-issue","usd":9.43,"count":1},{"site":"review","usd":2.87,"count":1}]}'
COST_PREV='{"count":1,"has_data":true,"total_usd":8.0,"by_site":[]}'
COST_PREV_NONE='{"count":0,"has_data":false,"total_usd":0,"by_site":[]}'
TIMING_NOW='{"count":1440,"has_data":true,"median_s":12,"p90_s":45,"max_s":3612}'
TIMING_PREV='{"count":1440,"has_data":true,"median_s":10,"p90_s":40,"max_s":3600}'
CV_BEHIND='{"installed":"2.1.229","latest":"2.1.269","checked_ok":true,"behind":true,"since_days":31}'
CV_CURRENT='{"installed":"2.1.269","latest":"2.1.269","checked_ok":true,"behind":false,"since_days":1}'
CV_UNKNOWN='{"installed":null,"latest":null,"checked_ok":false,"behind":false,"since_days":null}'

METRICS=$(shipreport_metrics_build "$COST_NOW" "$COST_PREV" "$TIMING_NOW" "$TIMING_PREV" "$CV_BEHIND")
eq "metrics: delta_usd computed"    "4.3" "$(jq -r '.metrics.cost.delta_usd' <<<"$METRICS")"
eq "metrics: delta_median_s computed" "2" "$(jq -r '.metrics.timing.delta_median_s' <<<"$METRICS")"
eq "metrics: claude_version passed through" "2.1.229" "$(jq -r '.claude_version.installed' <<<"$METRICS")"

METRICS_NO_PREV=$(shipreport_metrics_build "$COST_NOW" "$COST_PREV_NONE" "$TIMING_NOW" "$TIMING_PREV" "$CV_BEHIND")
eq "metrics: no prior data -> delta_usd null" "null" "$(jq -r '.metrics.cost.delta_usd' <<<"$METRICS_NO_PREV")"

echo "== shipreport_is_empty: metrics/version can keep an otherwise-quiet report NOT empty =="
QUIET='{"needs_you":[],"shipped":[],"inflight":[]}'
WITH_COST=$(jq -c --argjson m "$METRICS" '. + $m' <<<"$QUIET")
no "is_empty: real cost data present -> NOT empty" shipreport_is_empty "$WITH_COST"

COST_ZERO=$(shipreport_metrics_build "$COST_PREV_NONE" "$COST_PREV_NONE" "$COST_PREV_NONE" "$COST_PREV_NONE" "$CV_CURRENT")
WITH_NO_DATA=$(jq -c --argjson m "$COST_ZERO" '. + $m' <<<"$QUIET")
ok "is_empty: no cost/timing data + version current -> still empty" shipreport_is_empty "$WITH_NO_DATA"

COST_ZERO_BEHIND=$(shipreport_metrics_build "$COST_PREV_NONE" "$COST_PREV_NONE" "$COST_PREV_NONE" "$COST_PREV_NONE" "$CV_BEHIND")
WITH_BEHIND_ONLY=$(jq -c --argjson m "$COST_ZERO_BEHIND" '. + $m' <<<"$QUIET")
no "is_empty: version behind alone -> NOT empty" shipreport_is_empty "$WITH_BEHIND_ONLY"

echo "== renderers: cost/timing + version sections =="
FULL_REPORT=$(jq -c --argjson m "$METRICS" '. + $m' <<<"$REPORT")
FTEXT=$(shipreport_render_text <<<"$FULL_REPORT")
has "text: COST & TIMING heading"      "$FTEXT" "COST & TIMING"
has "text: total spend"                "$FTEXT" '$12.3'
has "text: delta vs prior period"      "$FTEXT" "vs prior 24h"
has "text: per-call-site breakdown"    "$FTEXT" "tier-1-issue: \$9.43"
has "text: tick count + median/p90"    "$FTEXT" "median 12s"
has "text: BEHIND version line"        "$FTEXT" "BEHIND latest 2.1.269"
FHTML=$(shipreport_render_html <<<"$FULL_REPORT")
has "html: cost/timing block present"  "$FHTML" "COST & TIMING"
has "html: version line present"       "$FHTML" "BEHIND latest 2.1.269"

echo "== renderers: no metrics key -> no cost/version section (existing plain report) =="
NO_METRICS_TEXT=$(shipreport_render_text <<<"$REPORT")
if printf '%s' "$NO_METRICS_TEXT" | grep -q 'COST & TIMING'; then
  printf '  x %s\n' "text: no COST & TIMING section when metrics was never merged in"; FAIL=$((FAIL + 1))
else
  printf '  + %s\n' "text: no COST & TIMING section when metrics was never merged in"
fi

echo "== renderers: stale ledger says so explicitly, never a bare \$0.00 =="
NO_DATA_METRICS=$(shipreport_metrics_build "$COST_PREV_NONE" "$COST_PREV_NONE" "$COST_PREV_NONE" "$COST_PREV_NONE" "$CV_UNKNOWN")
STALE_REPORT=$(jq -c --argjson m "$NO_DATA_METRICS" '. + $m' <<<"$REPORT")
STEXT=$(shipreport_render_text <<<"$STALE_REPORT")
has "text: says no cost data recorded"   "$STEXT" "no cost data recorded"
has "text: says no tick-timing data"     "$STEXT" "no tick-timing data recorded"
has "text: says could not check version" "$STEXT" "could not check"
if printf '%s' "$STEXT" | grep -q '\$0\.00'; then
  printf '  x %s\n' "text: never prints a bare \$0.00 for missing data"; FAIL=$((FAIL + 1))
else
  printf '  + %s\n' "text: never prints a bare \$0.00 for missing data"
fi

echo "== renderers: version current -> one quiet line, not silence =="
CURRENT_METRICS=$(shipreport_metrics_build "$COST_NOW" "$COST_PREV" "$TIMING_NOW" "$TIMING_PREV" "$CV_CURRENT")
CURRENT_REPORT=$(jq -c --argjson m "$CURRENT_METRICS" '. + $m' <<<"$REPORT")
CTEXT=$(shipreport_render_text <<<"$CURRENT_REPORT")
has "text: up to date line"  "$CTEXT" "up to date"
if printf '%s' "$CTEXT" | grep -q 'BEHIND'; then
  printf '  x %s\n' "text: does not shout BEHIND when current"; FAIL=$((FAIL + 1))
else
  printf '  + %s\n' "text: does not shout BEHIND when current"
fi

echo "== shipreport_judgment_build + rendering (igor#610) =="
eq "judgment_build with no arg defaults to an empty array" "[]" "$(jq -c '.judgment_items' <<<"$(shipreport_judgment_build)")"

NO_JUDGMENT_TEXT=$(shipreport_render_text <<<"$REPORT")
has "text: JUDGMENT ITEMS section renders even when never merged in (mandatory)" \
  "$NO_JUDGMENT_TEXT" "JUDGMENT ITEMS"
has "text: says nothing unresolved when absent" \
  "$NO_JUDGMENT_TEXT" "no unresolved judgment items"
NO_JUDGMENT_HTML=$(shipreport_render_html <<<"$REPORT")
has "html: Judgment items heading renders even when never merged in (mandatory)" \
  "$NO_JUDGMENT_HTML" "Judgment items"
has "html: says nothing unresolved when absent" \
  "$NO_JUDGMENT_HTML" "no unresolved judgment items"

JUDGMENT_JSON='[{"repo":"acme/x","number":12,"title":"Fix thing","url":"https://forge/acme/x/pulls/12","items":[
  {"kind":"review","verdict":"REQUEST_CHANGES","comment_url":"https://forge/acme/x/pulls/12#issuecomment-1","created_at":"2026-01-01T00:00:00Z","body":"This silently drops errors on line 42."},
  {"kind":"dismissal","verdict":null,"comment_url":"","created_at":"2026-01-01T01:00:00Z","body":"Dismissed: the caller already guards against it."}
]}]'
JUDGMENT=$(shipreport_judgment_build "$JUDGMENT_JSON")
eq "judgment_build: one PR carried through" "1" "$(jq -r '.judgment_items | length' <<<"$JUDGMENT")"

REPORT_WITH_JUDGMENT=$(jq -c --argjson j "$JUDGMENT" '. + $j' <<<"$REPORT")
JTEXT=$(shipreport_render_text <<<"$REPORT_WITH_JUDGMENT")
has "text: JUDGMENT ITEMS count in heading"  "$JTEXT" "1 PR(s), 2 item(s)"
has "text: names the repo#PR"                "$JTEXT" "acme/x#12"
has "text: shows the review's verdict"       "$JTEXT" "[REQUEST_CHANGES]"
has "text: deep-links the review comment"    "$JTEXT" "issuecomment-1"
has "text: body kept verbatim"               "$JTEXT" "This silently drops errors on line 42."
has "text: shows a dismissal as unresolved"  "$JTEXT" "[dismissed]"
has "text: dismissal reasoning kept verbatim" "$JTEXT" "Dismissed: the caller already guards against it."
has "text: no direct link falls back to a plain note" "$JTEXT" "(no direct link)"

JHTML=$(shipreport_render_html <<<"$REPORT_WITH_JUDGMENT")
has "html: names the repo#PR"                "$JHTML" "acme/x#12"
has "html: links the review comment"         "$JHTML" 'href="https://forge/acme/x/pulls/12#issuecomment-1"'
has "html: shows the dismissal verdict badge" "$JHTML" "[dismissed]"
has "html: body kept verbatim"               "$JHTML" "This silently drops errors on line 42."

echo "== judgment: a PR that could not be checked says so IN THE REPORT =="
# The whole point of the section is that silence is unambiguous. A PR whose
# comment thread never got read is not evidence of a clean PR, so it cannot be
# reported the same way -- a WARN in the journal is not something the human
# reading the email sees.
eq "judgment_build: unchecked defaults to an empty array" "[]" \
  "$(jq -c '.judgment_unchecked' <<<"$(shipreport_judgment_build)")"
UNCHECKED_JSON='[{"repo":"acme/x","number":13,"title":"Unreadable","url":"https://forge/acme/x/pulls/13","reason":"comment fetch failed"}]'
UNCHECKED_ONLY=$(shipreport_judgment_build '[]' "$UNCHECKED_JSON")
eq "judgment_build: unchecked carried through" "1" \
  "$(jq -r '.judgment_unchecked | length' <<<"$UNCHECKED_ONLY")"
U_REPORT=$(jq -c --argjson j "$UNCHECKED_ONLY" '. + $j' <<<"$REPORT")
UTEXT=$(shipreport_render_text <<<"$U_REPORT")
has "text: flags the section as incomplete" "$UTEXT" "could not be checked"
has "text: names the unchecked PR"          "$UTEXT" "acme/x#13"
has "text: gives the reason"                "$UTEXT" "comment fetch failed"
has "text: qualifies the nothing-found line rather than claiming a clean day" \
  "$UTEXT" "among the PRs that could be checked"
UHTML=$(shipreport_render_html <<<"$U_REPORT")
has "html: flags the section as incomplete" "$UHTML" "could not be checked"
has "html: names the unchecked PR"          "$UHTML" "acme/x#13"
has "html: gives the reason"                "$UHTML" "comment fetch failed"

echo "== forgejo_pr_comments: the helper the gather loop calls exists, with that signature =="
# The gather loop's only network call. If the name or the argument order ever
# drifts, bash returns 127, the `if !` swallows it, and the feature goes inert
# while the email still reads "no unresolved judgment items" -- so pin both
# against the real lib rather than against the stub two blocks below.
if bash -c 'set -uo pipefail; . "$1/../lib/forgejo.sh"; declare -F forgejo_pr_comments >/dev/null' _ "$HERE"; then
  printf '  + %s\n' "forgejo_pr_comments is defined by lib/forgejo.sh"
else
  printf '  x %s\n' "forgejo_pr_comments is not defined by lib/forgejo.sh"; FAIL=$((FAIL + 1))
fi
FJ_SIG=$(sed -n '/^forgejo_pr_comments() {$/,/^}$/p' "$HERE/../lib/forgejo.sh")
has "it takes <repo> then <number>, the order the loop passes" \
  "$FJ_SIG" 'local repo="$1" number="$2"'

echo "== shipreport_gather_judgment: the real loop from bin/tick.sh, driven with stubs =="
# Lift the function out of tick.sh and run it (the idiom bin/test-cascade.sh
# uses for cascade_run). The loop is half of igor#610 and CI covered none of
# it while this was a grep over source text.
TICK_SRC="$HERE/tick.sh"
GATHER_SRC=$(sed -n '/^shipreport_gather_judgment() {$/,/^}$/p' "$TICK_SRC")
if [ -z "$GATHER_SRC" ]; then
  printf '  x %s\n' "could not extract shipreport_gather_judgment() from bin/tick.sh"
  FAIL=$((FAIL + 1))
else
  eval "$GATHER_SRC"
  # shellcheck source=../lib/review-corpus.sh
  . "$HERE/../lib/review-corpus.sh"

  # A file, not a variable: every call below is a command substitution, so a
  # log sink in the shell's own memory would be written in the subshell and
  # thrown away with it.
  GATHER_LOG="$TMP/gather.log"; : >"$GATHER_LOG"
  log() { printf '%s\n' "$*" >>"$GATHER_LOG"; }

  # A copy of the harness's own review-comment template (bin/tick.sh), header
  # and footer included, so the parser's header match is exercised rather than
  # bypassed. bin/test-review-corpus.sh is where that header is pinned against
  # source; here it just has to be real enough to parse.
  REVIEW_BODY='### 🤖 Review — `REQUEST_CHANGES` _(automated)_

CI for `abc12345`: **success**

### Blocking (1)

- Drops errors on line 42.

---
<sub>Independent review by the harness.</sub>
<!-- review sha=abc12345 verdict=REQUEST_CHANGES ci=success -->'

  # #12 reviews clean-ly; #13 fails to fetch; #14 returns an EMPTY body on a
  # ZERO exit (the stdin-drain hazard: review_corpus_judgment_items reads stdin
  # when its argument is empty, and stdin here is the process substitution
  # feeding the loop, so an unguarded #14 swallows #15 and #16); #15 proves the
  # loop survived it; #16 returns a non-array, which the extractor chokes on.
  forgejo_pr_comments() {
    case "$2" in
      13) return 1 ;;
      14) printf '' ;;
      16) printf '{"message":"not an array"}' ;;
      *) jq -n -c --arg b "$REVIEW_BODY" --arg u "c$2" \
           '[{user:{login:"igor"}, created_at:"2026-01-01T00:00:00Z", html_url:$u, body:$b}]' ;;
    esac
  }
  MERGED='[
    {"repo":"acme/x","number":12,"title":"Fix thing","url":"u12"},
    {"repo":"acme/x","number":13,"title":"Unreadable","url":"u13"},
    {"repo":"acme/x","number":14,"title":"Empty thread","url":"u14"},
    {"repo":"acme/x","number":15,"title":"After the empty one","url":"u15"},
    {"repo":"acme/x","number":16,"title":"Garbage thread","url":"u16"}
  ]'
  GATHERED=$(shipreport_gather_judgment "acme/x" "$MERGED")
  eq "items: only the PRs with unresolved findings" "12 15" \
    "$(jq -r '[.items[].number] | join(" ")' <<<"$GATHERED")"
  eq "the PR after an empty-but-successful fetch is still reached" "15" \
    "$(jq -r '[.items[].number] | last' <<<"$GATHERED")"
  eq "an empty thread yields no item and no unchecked entry" "0" \
    "$(jq -r '[(.items[], .unchecked[]) | select(.number == 14)] | length' <<<"$GATHERED")"
  eq "unchecked: the fetch failure and the extraction failure" "13 16" \
    "$(jq -r '[.unchecked[].number] | join(" ")' <<<"$GATHERED")"
  eq "unchecked carries a reason the report can print" "comment fetch failed" \
    "$(jq -r '.unchecked[] | select(.number == 13) | .reason' <<<"$GATHERED")"
  eq "an extraction failure is a distinct reason" "judgment extraction failed" \
    "$(jq -r '.unchecked[] | select(.number == 16) | .reason' <<<"$GATHERED")"
  eq "the PR's own metadata rides along for the report" "Fix thing u12" \
    "$(jq -r '.items[] | select(.number == 12) | "\(.title) \(.url)"' <<<"$GATHERED")"
  eq "the review verdict survives extraction" "REQUEST_CHANGES" \
    "$(jq -r '.items[] | select(.number == 12) | .items[0].verdict' <<<"$GATHERED")"
  has "the comment deep-link survives extraction" \
    "$(jq -r '.items[] | select(.number == 12) | .items[0].comment_url' <<<"$GATHERED")" "c12"
  has "a failed fetch is logged too, not only reported" \
    "$(cat "$GATHER_LOG")" "comment fetch failed for acme/x#13"
  has "a failed extraction is logged too" \
    "$(cat "$GATHER_LOG")" "judgment extraction failed for acme/x#16"

  # Accumulator threading: the tick calls this once per repo, so a second call
  # must add to the first's result rather than replace it.
  SECOND=$(shipreport_gather_judgment "acme/y" '[{"repo":"acme/y","number":20,"title":"Elsewhere","url":"u20"}]' "$GATHERED")
  eq "a second repo's items are appended, not replaced" "12 15 20" \
    "$(jq -r '[.items[].number] | join(" ")' <<<"$SECOND")"
  eq "a second repo keeps the first's unchecked entries" "13 16" \
    "$(jq -r '[.unchecked[].number] | join(" ")' <<<"$SECOND")"
  eq "no merged PRs at all -> an empty gather, not an error" '{"items":[],"unchecked":[]}' \
    "$(shipreport_gather_judgment "acme/x" '[]')"

  # errexit-safe early-continue: `[ -z "$x" ] && continue` is exempt from
  # `set -e` (a non-final && element), but the file's convention is the `||`
  # form and it reads as safe without having to know that rule.
  has "the empty-line skip uses the || form" "$GATHER_SRC" '[ -n "$pr_line" ] || continue'

  unset -f forgejo_pr_comments
fi

echo "== do_shipreport_tick wires the gather into the report =="
has "the tick calls the gather loop" \
  "$(sed -n '/^do_shipreport_tick() {$/,/^}$/p' "$TICK_SRC")" "shipreport_gather_judgment"
has "both halves of the gather reach shipreport_judgment_build" \
  "$(sed -n '/^do_shipreport_tick() {$/,/^}$/p' "$TICK_SRC")" 'shipreport_judgment_build "$'

echo "== fully scripted: no model call in the module =="
if grep -qE "claude_call|claude_run|anthropic_call" "$HERE/../lib/ship-report.sh"; then
  printf '  x %s\n' "ship-report.sh contains a model call"; FAIL=$((FAIL + 1))
else
  printf '  + %s\n' "ship-report.sh makes no model call"
fi

[ "$FAIL" -eq 0 ] && { echo "test-shipreport: all checks passed"; exit 0; }
echo "test-shipreport: $FAIL check(s) FAILED"
exit 1
