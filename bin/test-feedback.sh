#!/usr/bin/env bash
# test-feedback.sh -- unit tests for lib/feedback.sh: CSV parse (quoted fields),
# the seen-set, oldest-unprocessed selection, the DROP/FILE response parse, issue
# filing, and do_feedback_tick's decision. Skip-safe: needs jq + python3 +
# sha1sum; exits 0 with a notice if absent. All boundaries stubbed -- no network.
set -uo pipefail

for t in jq python3 sha1sum; do
  command -v "$t" >/dev/null 2>&1 || { echo "test-feedback: $t absent -- skipping"; exit 0; }
done

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/feedback.sh
. "$HERE/../lib/feedback.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export AGENT_STATE_DIR="$TMP"; STATE="$TMP/discretionary-state.json"

FAIL=0
ok() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then printf '  + %s\n' "$d"; else printf '  x %s (rc0 expected)\n' "$d"; FAIL=$((FAIL + 1)); fi; }
no() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then printf '  x %s (rc!=0 expected)\n' "$d"; FAIL=$((FAIL + 1)); else printf '  + %s\n' "$d"; fi; }
eq() { if [ "$2" = "$3" ]; then printf '  + %s\n' "$1"; else printf '  x %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi; }
has() { case "$2" in *"$3"*) printf '  + %s\n' "$1" ;; *) printf '  x %s: [%s] lacks [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)) ;; esac; }

echo "== CSV parse (quoted commas + the real Google-Form header) =="
CSV=$(printf '%s\n%s\n' \
  'Timestamp,Game,Device / browser,Type of feedback,Tell us more' \
  '2026-06-01,Slam Pig,Chrome,Bug or glitch,"freezes, then crashes, on level 2"')
rows=$(printf '%s' "$CSV" | python3 -c 'import csv,json,sys; print(json.dumps(list(csv.DictReader(sys.stdin))))')
eq "csv: one data row"          "1"        "$(jq 'length' <<<"$rows")"
eq "csv: keeps embedded commas" "freezes, then crashes, on level 2" "$(jq -r '.[0]."Tell us more"' <<<"$rows")"
eq "csv: keyed by header"       "Slam Pig" "$(jq -r '.[0].Game' <<<"$rows")"

echo "== seen-set =="
row='{"Timestamp":"t1","Game":"g","Tell us more":"x"}'
k=$(feedback_row_key "$row")
eq "row_key: 40-hex sha1" "40" "${#k}"
eq "row_key: stable"      "$k" "$(feedback_row_key "$row")"
no "seen: unknown key not seen" feedback_seen "$k"
feedback_mark_seen "$k"
ok "seen: marked key now seen"  feedback_seen "$k"

echo "== attempt counter + give-up escape hatch (anti-livelock) =="
echo '{}' > "$STATE"
bk=$(feedback_row_key '{"Timestamp":"p","Game":"g","Tell us more":"poison"}')
eq "bump: first attempt -> 1"  "1" "$(feedback_bump_attempt "$bk")"
eq "bump: second attempt -> 2" "2" "$(feedback_bump_attempt "$bk")"
echo '{}' > "$STATE"
no "fail #1 -> defer (rc1), row not given up"  _feedback_fail acme/x "$bk" "bad"
no "fail #2 -> defer (rc1)"                    _feedback_fail acme/x "$bk" "bad"
no "give-up not yet -> row not seen"           feedback_seen "$bk"
ok "fail #3 (>= MAX) -> give up (rc0)"         _feedback_fail acme/x "$bk" "bad"
ok "give-up marks the poison row seen"         feedback_seen "$bk"
eq "give-up cleared the attempt counter" "null" "$(jq -r --arg k "$bk" '.feedback.attempts[$k] // "null"' "$STATE")"

echo "== next_unprocessed (oldest unseen) =="
ROWS='[{"Timestamp":"t1","Game":"g","Tell us more":"a"},{"Timestamp":"t2","Game":"g","Tell us more":"b"}]'
feedback_mark_seen "$(feedback_row_key '{"Timestamp":"t1","Game":"g","Tell us more":"a"}')"
eq "next: skips seen, returns oldest unseen" "b" "$(feedback_next_unprocessed "$ROWS" | jq -r '."Tell us more"')"

echo "== response parse =="
run() { OUT=$(feedback_parse_response "$1"); }
run "$(printf 'DECISION: DROP\nREASON: spam')"
eq "parse: DROP decision" "DROP" "$(jq -r '.decision' <<<"$OUT")"
eq "parse: DROP reason"   "spam" "$(jq -r '.reason' <<<"$OUT")"
run "$(printf 'DECISION: DROP -- already worked\nREASON: dup of #5')"
eq "parse: DROP with trailing text on the line" "DROP" "$(jq -r '.decision' <<<"$OUT")"
run "$(printf 'DECISION: FILE\nTITLE: Slam Pig: freezes on level 2\n===BODY===\nThe pig freezes.')"
eq "parse: FILE decision" "FILE" "$(jq -r '.decision' <<<"$OUT")"
eq "parse: FILE title"    "Slam Pig: freezes on level 2" "$(jq -r '.title' <<<"$OUT")"
eq "parse: FILE body"     "The pig freezes." "$(jq -r '.body' <<<"$OUT")"
no "parse: no DECISION -> rc1"   feedback_parse_response "garbage"
no "parse: FILE w/o body -> rc1" feedback_parse_response "$(printf 'DECISION: FILE\nTITLE: x')"

echo "== csv_url (agent.json .feedback.csv) =="
forgejo_repo_get_file() { printf '%s' '{"feedback":{"csv":"https://x/pub?output=csv"}}'; }
eq "csv_url: extracts .feedback.csv" "https://x/pub?output=csv" "$(feedback_csv_url acme/x)"
forgejo_repo_get_file() { printf '%s' '{"smoke":{"url":"y"}}'; }
eq "csv_url: no feedback key -> empty" "" "$(feedback_csv_url acme/x)"

echo "== feedback_search_prior (generic targeted dedup search) =="
_fj() {
  case "$1 $2" in
    "GET "*/commits*) printf '%s' '[{"commit":{"message":"fix(games): tap to start (Boar Dungeon + 4 more)\n\nbody"}}]' ;;
    *)                printf '%s' '[]' ;;
  esac
}
search_out=$(feedback_search_prior acme/x "Boar Dungeon")
has "search: finds older prior work by name (commit grep)" "$search_out" "Boar Dungeon"
eq  "search: empty subject -> nothing"  "" "$(feedback_search_prior acme/x "")"

# A closed feedback-triage ticket is NOT proof of a fix -- it must be filtered out,
# or the dedup drops real bugs as dupes of its own prior (or rejected) triage.
_fj() {
  case "$1 $2" in
    "GET "*/issues*) printf '%s' '[{"number":99,"pull_request":null,"title":"Slide Swine: wrong tile","body":"x <!-- agent:feedback-triage -->"},{"number":12,"pull_request":null,"title":"Slide Swine real fix","body":"done"}]' ;;
    *)               printf '%s' '[]' ;;
  esac
}
sp=$(feedback_search_prior acme/x "Slide Swine")
case "$sp" in
  *"#99"*) printf '  x %s\n' "search: leaked our own feedback-triage ticket #99"; FAIL=$((FAIL + 1)) ;;
  *)       printf '  + %s\n' "search: excludes our own feedback-triage ticket #99" ;;
esac
has "search: keeps the real (non-triage) closed issue #12" "$sp" "#12"

echo "== classification labels: repo_labels excludes the workflow labels =="
_fj() { case "$1 $2" in "GET "*/labels*) printf '%s' '[{"id":1,"name":"Agent"},{"id":2,"name":"bug"},{"id":3,"name":"enhancement"},{"id":4,"name":"Status/Blocked"},{"id":5,"name":"onboarding"}]' ;; *) printf '%s' '[]' ;; esac; }
rl=$(feedback_repo_labels acme/x)
eq "repo_labels: keeps only descriptive labels" "bug,enhancement" "$(jq -r '[.[].name]|join(",")' <<<"$rl")"
case "$rl" in
  *Agent*) printf '  x %s\n' "repo_labels: leaked the Agent greenlight label"; FAIL=$((FAIL + 1)) ;;
  *)       printf '  + %s\n' "repo_labels: excludes Agent (the greenlight gate)" ;;
esac
eq "repo_labels: no labels -> []" "[]" "$(_fj() { printf '%s' ''; }; feedback_repo_labels acme/x)"

echo "== classification labels: resolve names -> ids (only what exists) =="
LJ='[{"id":2,"name":"bug"},{"id":3,"name":"enhancement"}]'
eq "resolve: maps names to ids"        "[2,3]" "$(feedback_resolve_labels "$LJ" "bug, Enhancement")"
eq "resolve: case-insensitive + trims" "[2]"   "$(feedback_resolve_labels "$LJ" "  BUG ")"
eq "resolve: unknown name dropped"     "[]"    "$(feedback_resolve_labels "$LJ" "wontfix")"
eq "resolve: empty -> []"              "[]"    "$(feedback_resolve_labels "$LJ" "")"
eq "resolve: a non-listed label (e.g. Agent) can't be applied" "[]" "$(feedback_resolve_labels "$LJ" "Agent")"

echo "== parse: optional LABELS line =="
run "$(printf 'DECISION: FILE\nTITLE: x\nLABELS: bug, enhancement\n===BODY===\nbody.')"
eq "parse: FILE captures LABELS"          "bug, enhancement" "$(jq -r '.labels' <<<"$OUT")"
run "$(printf 'DECISION: FILE\nTITLE: x\n===BODY===\nbody.')"
eq "parse: FILE without LABELS -> empty"  "" "$(jq -r '.labels' <<<"$OUT")"

echo "== file_issue (UNLABELED + assigned + marker) =="
POST_BODY=""
_fj() { case "$1 $2" in "POST "*/issues) POST_BODY="$3" ;; esac; }
feedback_file_issue acme/x "T" "B" "josh" >/dev/null 2>&1
eq  "file: title in payload"    "T"    "$(jq -r '.title' <<<"$POST_BODY")"
eq  "file: assigned to human"   "josh" "$(jq -r '.assignees[0]' <<<"$POST_BODY")"
has "file: body carries marker" "$(jq -r '.body' <<<"$POST_BODY")" "$FEEDBACK_MARKER"
eq  "file: UNLABELED at open"   "null" "$(jq -r '.labels // "null"' <<<"$POST_BODY")"
# The greenlight footer must NOT tell the human to unassign -- the Agent label
# alone is the claimable gate (find_claimable accepts assigned-to-reviewer).
case "$(jq -r '.body' <<<"$POST_BODY")" in
  *unassign*) printf '  x %s\n' "file: footer still instructs unassign"; FAIL=$((FAIL + 1)) ;;
  *)          printf '  + %s\n' "file: footer does not instruct unassign" ;;
esac
feedback_file_issue acme/x "T" "B" "josh" "[2,3]" >/dev/null 2>&1
eq "file: applies resolved label ids to the payload" "[2,3]" "$(jq -c '.labels' <<<"$POST_BODY")"

echo "== do_feedback_tick decision =="
export FORGEJO_REVIEWER=josh AGENT_MODEL_REVIEW=m
export ANALYSIS_REPOS_JSON='{"full_name":"acme/x"}'
AGENT_HOME="$TMP"; mkdir -p "$TMP/bin/lib"; echo "directive" > "$TMP/bin/lib/feedback-directive.md"
feedback_csv_url()      { echo "https://x"; }
feedback_fetch_rows()   { echo '[{"Timestamp":"u1","Game":"g","Tell us more":"a real, specific bug"}]'; }
feedback_gather_context() { echo "ctx"; }
FILED=0
_fj() { case "$1 $2" in "POST "*/issues) FILED=$((FILED + 1)) ;; esac; }

echo '{}' > "$STATE"
claude_call() { printf 'DECISION: FILE\nTITLE: g bug\n===BODY===\nbody.'; }
ok "tick: FILE -> processed a row (rc0)" do_feedback_tick
eq "tick: FILE filed an issue" "1" "$FILED"
eq "tick: FILE stamped seen"   "1" "$(jq '(.feedback.seen // []) | length' "$STATE")"

echo '{}' > "$STATE"; FILED=0
claude_call() { printf 'DECISION: DROP\nREASON: already fixed'; }
ok "tick: DROP -> processed a row (rc0)" do_feedback_tick
eq "tick: DROP filed nothing" "0" "$FILED"
eq "tick: DROP stamped seen"  "1" "$(jq '(.feedback.seen // []) | length' "$STATE")"

if [ "$FAIL" -eq 0 ]; then echo "test-feedback: all checks passed"; exit 0; fi
echo "test-feedback: $FAIL check(s) FAILED"
exit 1
