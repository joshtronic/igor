#!/usr/bin/env bash
# Unit tests for lib/needsyou.sh -- the "what is waiting on the operator" set
# and its event semantics (igor#439, detection half).
#
# The property that matters: only ADDITIONS are announceable. An unchanged set
# must produce nothing, or the notification becomes a periodic digest that says
# "nothing needs you" and trains the reader to ignore it.
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "test-needsyou: jq absent -- skipping"; exit 0; }
HERE=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/needsyou.sh
. "$HERE/lib/needsyou.sh"

FAIL=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi; }
has() { case "$2" in *"$3"*) ok "$1";; *) bad "$1: [$2] lacks [$3]";; esac; }
rc0() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d (expected rc 0)"; fi; }
rcn() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d (expected nonzero)"; else ok "$d"; fi; }

K1=$(needsyou_key acme/site pr 12)
K2=$(needsyou_key acme/site issue 12)
echo "== keys =="
eq "key shape" "acme/site/pr/12" "$K1"
if [ "$K1" != "$K2" ]; then ok "a PR and an issue with the SAME number are distinct keys"
else bad "pr and issue #12 collided -- Forgejo shares the number space"; fi

set_of() { # set_of <key> <json-item> [<key> <json-item> ...]
  local out='{}' k v
  while [ $# -gt 0 ]; do
    k="$1"; v="$2"; shift 2
    out=$(jq -c --arg k "$k" --argjson v "$v" '. + {($k): $v}' <<<"$out")
  done
  printf '%s' "$out"
}

NOW=1000000
I1=$(needsyou_item acme/site pr 12 "shadow verdict COMMENT -- needs your call" "$NOW")
I2=$(needsyou_item acme/site issue 5 "Status/Blocked" "$NOW")
PREV=$(set_of "$K1" "$I1")
CUR=$(set_of "$K1" "$I1" "acme/site/issue/5" "$I2")

echo "== additions are the only announceable event =="
eq "a new item is an addition" "acme/site/issue/5" "$(needsyou_added "$PREV" "$CUR")"
eq "an UNCHANGED set announces nothing" "" "$(needsyou_added "$CUR" "$CUR")"
eq "an item leaving is NOT an addition" "" "$(needsyou_added "$CUR" "$PREV")"
eq "and leaving is reported as a removal" "acme/site/issue/5" "$(needsyou_removed "$CUR" "$PREV")"
eq "empty -> empty announces nothing" "" "$(needsyou_added '{}' '{}')"
eq "first ever scan announces everything in it" "acme/site/pr/12" "$(needsyou_added '{}' "$PREV")"

echo "== merge preserves 'since' so wait time is real =="
# The item was first seen at NOW; a later scan must NOT reset its clock, or
# nothing can ever be reported as having waited days.
LATER=$((NOW + 86400))
MERGED=$(needsyou_merge "$PREV" "$CUR" "$LATER")
eq "an existing item keeps its original since" "$NOW" "$(jq -r '."acme/site/pr/12".since' <<<"$MERGED")"
eq "a newly seen item takes the current time" "$LATER" "$(jq -r '."acme/site/issue/5".since' <<<"$MERGED")"
eq "merge keeps exactly the CURRENT keys" "acme/site/issue/5 acme/site/pr/12" \
  "$(jq -r 'keys | join(" ")' <<<"$MERGED")"
# An item that left and came back is genuinely new again.
BACK=$(needsyou_merge '{}' "$PREV" "$LATER")
eq "an item that left and returned resets its clock" "$LATER" "$(jq -r '."acme/site/pr/12".since' <<<"$BACK")"

echo "== describe: what the operator actually reads =="
D=$(needsyou_describe "$MERGED" "acme/site/pr/12" "$LATER")
has "names the repo and number" "$D" "acme/site#12"
has "says why it is waiting" "$D" "shadow verdict COMMENT"
has "reports the wait in days once it is old" "$D" "waiting 1d"
D2=$(needsyou_describe "$MERGED" "acme/site/issue/5" "$((LATER + 1800))")
has "a fresh item reports minutes" "$D2" "waiting 30m"
eq "an unknown key describes to nothing" "" "$(needsyou_describe "$MERGED" "nope/x/1" "$LATER")"

# The unit switches at 60 and 1440 minutes, so those are the two lines worth
# pinning: an off-by-one there reads as "waiting 0h" on something an hour old.
has "59 minutes still reads in minutes" "$(needsyou_describe "$MERGED" "$K1" "$((NOW + 3540))")" "waiting 59m"
has "60 minutes flips to hours"         "$(needsyou_describe "$MERGED" "$K1" "$((NOW + 3600))")" "waiting 1h"
has "23h59 is still hours"              "$(needsyou_describe "$MERGED" "$K1" "$((NOW + 86340))")" "waiting 23h"
has "24 hours flips to days"            "$(needsyou_describe "$MERGED" "$K1" "$((NOW + 86400))")" "waiting 1d"

echo "== a negative age (clock skew) clamps to zero =="
eq "since in the future does not render -1m" "" "$(needsyou_describe "$MERGED" "acme/site/pr/12" "$((NOW - 600))" | grep -o -- '-[0-9]*m' || true)"
has "it reads as zero instead" "$(needsyou_describe "$MERGED" "acme/site/pr/12" "$((NOW - 600))")" "waiting 0m"

echo "== which PR states are actually the OPERATOR's turn =="
# The distinction that matters: "auto-merge will not take it" is much broader
# than "you are the blocker". A PR nobody has reviewed yet is the shadow
# reviewer's turn, and a PR in the rework loop is Igor's -- announcing either
# is exactly the every-scan noise this feature exists to avoid.
eq "an UNREVIEWED PR is the reviewer's turn, not yours" "" "$(needsyou_pr_why "" false 0 true)"
eq "so is a PR whose verdict never parsed" "" "$(needsyou_pr_why "none" false 0 true)"
eq "an APPROVE on a shadow-gated repo merges itself" "" "$(needsyou_pr_why APPROVE false 0 true)"
has "an APPROVE on a human-pinned repo IS yours" "$(needsyou_pr_why APPROVE true 0 true)" "pinned to your review"
has "a COMMENT is yours -- auto-merge won't take it" "$(needsyou_pr_why COMMENT false 0 true)" "COMMENT"
eq "REQUEST_CHANGES inside the rework loop is IGOR's turn" "" "$(needsyou_pr_why REQUEST_CHANGES false 0 true)"
eq "still Igor's on the last round before escalation" "" "$(needsyou_pr_why REQUEST_CHANGES false 2 true)"
has "but an escalation after 3 rounds is yours" "$(needsyou_pr_why REQUEST_CHANGES false 3 true)" "without converging"
has "and REQUEST_CHANGES on an unverifiable repo is yours" \
  "$(needsyou_pr_why REQUEST_CHANGES false 0 false)" "CI-verified"
eq "a garbage round count is treated as zero, not an error" "" "$(needsyou_pr_why REQUEST_CHANGES false '' true)"

echo "== the PR list is an ARRAY, not one number per line =="
# The regression this exists for: the first cut fed forgejo_list_open_bot_prs'
# output straight into `while read`, so every "PR number" was a fragment of
# pretty-printed JSON ("[", "  {", "\"number\": 449,") and needsyou_pr_why was
# never once called with a real number. A dry-run against the live fleet found
# zero waiting PRs -- correctly, because the scan could not see any.
PULLS='[
  {
    "number": 449,
    "title": "feat: detect what is waiting on the operator",
    "head": "feat/439-needsyou-detection"
  },
  {
    "number": 12,
    "title": "WIP: issue #7 checkpoint -- half a thing",
    "head": "agent/7"
  }
]'
eq "pulls JSON yields bare numbers, not JSON fragments" "449" "$(needsyou_pr_numbers "$PULLS")"
eq "an empty list yields nothing" "" "$(needsyou_pr_numbers '[]')"
eq "garbage yields nothing rather than fragments" "" "$(needsyou_pr_numbers 'not json')"
eq "an empty argument yields nothing" "" "$(needsyou_pr_numbers '')"
# A WIP: checkpoint PR is Igor mid-task, exactly like the rework loop -- and it
# can carry a stale verdict from before it checkpointed, which would otherwise
# read as "escalated to you" while Igor is still working.
eq "a WIP: checkpoint PR is Igor's turn, not yours" "" \
  "$(needsyou_pr_numbers '[{"number":12,"title":"WIP: issue #7 checkpoint"}]')"
eq "two ready PRs both come through" "1
2" "$(needsyou_pr_numbers '[{"number":1,"title":"a"},{"number":2,"title":"b"}]')"

echo "== which issues are parked on the operator =="
ISSUES='[{"number":1,"labels":[{"name":"Agent"}]},
         {"number":2,"labels":[{"name":"Status/Blocked"},{"name":"Priority/High"}]},
         {"number":3,"labels":[]},
         {"number":4,"labels":[{"name":"Status/Need More Info"}]},
         {"number":5,"labels":[{"name":"Status/In Progress"}]}]'
LINES=$(needsyou_issue_lines "$ISSUES")
eq "only Blocked and Need More Info qualify" "2
4" "$(cut -d'|' -f1 <<<"$LINES")"
has "the why names the status label" "$LINES" "2|Status/Blocked"
eq "a non-Status label does not ride along in the why" "2|Status/Blocked" "$(grep '^2|' <<<"$LINES")"
eq "no issues -> nothing waiting" "" "$(needsyou_issue_lines '[]')"
eq "garbage issue payload -> nothing waiting" "" "$(needsyou_issue_lines 'not json')"

echo "== malformed input degrades to empty, never crashes =="
eq "garbage previous -> everything reads as new" "acme/site/pr/12" "$(needsyou_added 'not json' "$PREV")"
eq "garbage current -> nothing announced" "" "$(needsyou_added "$PREV" 'not json')"
eq "garbage both -> nothing" "" "$(needsyou_added 'not json' 'also not json')"
eq "merge over garbage does not explode" "{}" "$(needsyou_merge 'not json' 'not json' "$NOW")"
# A non-numeric `since` used to make jq fail and print {}, which the scan then
# folded into the set under a valid key -- so describe rendered "null#null".
eq "a non-numeric since falls back to 0 rather than voiding the item" "0" \
  "$(needsyou_item acme/site pr 12 why 'not-a-number' | jq -r '.since')"
eq "and the item is still well formed" "acme/site" \
  "$(needsyou_item acme/site pr 12 why 'not-a-number' | jq -r '.repo')"
# A set that parses but isn't an object has no keys worth naming. Untightened,
# `keys` on an array yields its INDICES, so a stray array announced "0", "1".
eq "an array where a set belongs announces nothing" "" "$(needsyou_added '{}' '[1,2,3]')"
eq "and does not read array indices as keys" "" "$(needsyou_added '[1,2,3]' '[1,2,3]')"

# -- the glue ------------------------------------------------------------
# Everything above tests pure functions. What shipped broken last round was the
# layer BELOW them -- the scan that turns fleet API payloads into a set -- so it
# is stubbed at its seams here rather than left to a manual run.
echo "== the scan: fleet payloads in, a set out =="
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/discretionary-state.json"
discretionary_state_file() { printf '%s' "$STATE"; }
LOGGED=""
log() { LOGGED="${LOGGED}$*"$'\n'; }
# BOT_USER and every ANALYSIS_REPOS_JSON below are read by needsyou_scan_set in
# the sourced lib, which shellcheck does not follow into.
# shellcheck disable=SC2034
BOT_USER=igor
# acme/site: one ready bot PR carrying a COMMENT verdict, one Status/Blocked
# issue -- both the operator's. acme/blog: no bot PRs, and an issue that is
# merely Agent-labelled -- neither is.
PULLS_SITE='[{"number":7,"title":"feat: a thing","head":"agent/7"},
             {"number":8,"title":"WIP: issue #8 checkpoint","head":"agent/8"}]'
forgejo_list_open_bot_prs() {
  case "$1" in
    acme/site) printf '%s' "$PULLS_SITE" ;;
    acme/blog) printf '%s' '[]' ;;
    *) return 1 ;;   # a repo whose list call does not answer
  esac
}
_fj() {
  case "$2" in
    */acme/site/issues*) printf '%s' '[{"number":3,"labels":[{"name":"Status/Blocked"}]}]' ;;
    */acme/blog/issues*) printf '%s' '[{"number":9,"labels":[{"name":"Agent"}]}]' ;;
    *) return 1 ;;
  esac
}
automerge_require_human()   { return 1; }
automerge_url_status()      { printf 'ok\thttps://x'; }   # url-bearing by default
maintenance_repo_validated() { return 0; }
review_rework_rounds()      { printf '0'; }
echo '{"review":{"acme/site#7":{"verdict":"COMMENT"}}}' > "$STATE"

WANT="acme/site/issue/3 acme/site/pr/7"
ANALYSIS_REPOS_JSON='{"full_name":"acme/site"}
{"full_name":"acme/blog"}'
SET=$(needsyou_scan_set)
eq "the scan keeps only what is the operator's turn" "$WANT" "$(jq -r 'keys|join(" ")' <<<"$SET")"
has "the PR item carries the why the verdict table gave it" "$SET" "COMMENT"
has "and the issue item carries its status label" "$SET" "Status/Blocked"
rc0 "a scan that reached every repo reports itself complete" needsyou_scan_set

# The regression finding #1 is about: bin/tick.sh assigns this as newline-
# delimited compact objects (`jq -c '.[]'`), but reading a plain ARRAY line by
# line yields "[", "  {" and never a repo -- so the scan would go blind
# fleet-wide while "nothing needs you" still looked like a legitimate answer.
ANALYSIS_REPOS_JSON='[{"full_name":"acme/site"},{"full_name":"acme/blog"}]'
eq "a compact ARRAY repo set scans the same" "$WANT" "$(needsyou_scan_set | jq -r 'keys|join(" ")')"
ANALYSIS_REPOS_JSON='[
  { "full_name": "acme/site" },
  { "full_name": "acme/blog" }
]'
eq "a PRETTY-PRINTED array too" "$WANT" "$(needsyou_scan_set | jq -r 'keys|join(" ")')"

ANALYSIS_REPOS_JSON=''
eq "no repos -> an empty set, not a crash" "{}" "$(needsyou_scan_set || true)"
rcn "and no repos is reported as INCOMPLETE, not as 'nothing waiting'" needsyou_scan_set
ANALYSIS_REPOS_JSON='{"full_name":"acme/nope"}'
rcn "a list call that did not answer is incomplete too" needsyou_scan_set

echo "== a url-less repo is implicitly human-gated (igor#520) =="
# do_automerge_tick never merges a url-less repo on the shadow verdict alone
# (a human must approve). Without this, the digest would say "nothing needs
# you" on exactly the PR whose merge is stuck waiting on a click -- the bug
# igor#520 exists to fix.
PULLS_URLLESS='[{"number":11,"title":"fix: a thing","head":"agent/11"}]'
forgejo_list_open_bot_prs() {
  case "$1" in
    acme/site)    printf '%s' "$PULLS_SITE" ;;
    acme/blog)    printf '%s' '[]' ;;
    acme/urlless) printf '%s' "$PULLS_URLLESS" ;;
    *) return 1 ;;
  esac
}
_fj() {
  case "$2" in
    */acme/site/issues*)    printf '%s' '[{"number":3,"labels":[{"name":"Status/Blocked"}]}]' ;;
    */acme/blog/issues*)    printf '%s' '[{"number":9,"labels":[{"name":"Agent"}]}]' ;;
    */acme/urlless/issues*) printf '%s' '[]' ;;
    *) return 1 ;;
  esac
}
automerge_url_status() {
  case "$1" in
    acme/urlless) printf 'ok\t' ;;              # genuinely no url
    *)            printf 'ok\thttps://x' ;;
  esac
}
echo '{"review":{"acme/site#7":{"verdict":"COMMENT"},"acme/urlless#11":{"verdict":"APPROVE","sha":""}}}' > "$STATE"
ANALYSIS_REPOS_JSON='{"full_name":"acme/site"}
{"full_name":"acme/blog"}
{"full_name":"acme/urlless"}'
SET=$(needsyou_scan_set)
has "a url-less repo's shadow APPROVE still needs the operator" \
  "$(jq -r 'keys|join(" ")' <<<"$SET")" "acme/urlless/pr/11"
has "...because it reads as pinned to your review" \
  "$(jq -r '."acme/urlless/pr/11".why' <<<"$SET")" "pinned to your review"
# A dossier fetch failure ("error") this tick is left alone, not flagged --
# it isn't actionable by the operator and self-heals.
automerge_url_status() {
  case "$1" in
    acme/urlless) printf 'error\t' ;;
    *)            printf 'ok\thttps://x' ;;
  esac
}
echo '{"review":{"acme/site#7":{"verdict":"COMMENT"},"acme/urlless#11":{"verdict":"APPROVE","sha":""}}}' > "$STATE"
SET=$(needsyou_scan_set)
case "$(jq -r 'keys|join(" ")' <<<"$SET")" in
  *acme/urlless/pr/11*) printf '  x %s\n' "a dossier fetch failure wrongly flags the PR"; FAIL=$((FAIL + 1)) ;;
  *) printf '  + %s\n' "a dossier fetch failure does not flag the PR" ;;
esac
automerge_url_status() { printf 'ok\thttps://x'; }   # reset to url-bearing for later sections
forgejo_list_open_bot_prs() {
  case "$1" in
    acme/site) printf '%s' "$PULLS_SITE" ;;
    acme/blog) printf '%s' '[]' ;;
    *) return 1 ;;
  esac
}
_fj() {
  case "$2" in
    */acme/site/issues*) printf '%s' '[{"number":3,"labels":[{"name":"Status/Blocked"}]}]' ;;
    */acme/blog/issues*) printf '%s' '[{"number":9,"labels":[{"name":"Agent"}]}]' ;;
    *) return 1 ;;
  esac
}
echo '{"review":{"acme/site#7":{"verdict":"COMMENT"}}}' > "$STATE"
ANALYSIS_REPOS_JSON='{"full_name":"acme/site"}
{"full_name":"acme/blog"}'

echo "== the pass: announce once, and never believe a partial scan =="
# shellcheck disable=SC2034  # read by needsyou_scan_set, via needsyou_pass
ANALYSIS_REPOS_JSON='{"full_name":"acme/site"}
{"full_name":"acme/blog"}'
LOGGED=""; needsyou_pass
has "a first pass announces the PR"    "$LOGGED" "acme/site#7"
has "and the blocked issue"            "$LOGGED" "acme/site#3"
eq  "the set is persisted under .needsyou" "$WANT" "$(jq -r '.needsyou|keys|join(" ")' "$STATE")"
eq  "the review state it read is left intact" "COMMENT" "$(jq -r '.review["acme/site#7"].verdict' "$STATE")"
SINCE=$(jq -r '.needsyou["acme/site/pr/7"].since' "$STATE")
LOGGED=""; needsyou_pass
eq "an unchanged set announces NOTHING on rescan" "" "$LOGGED"
eq "and the clock is not reset"                   "$SINCE" "$(jq -r '.needsyou["acme/site/pr/7"].since' "$STATE")"

# bin/tick.sh runs under `set -euo pipefail`; this suite does not. A nonzero
# return anywhere but a guarded position would abort the whole tick from inside
# the scan -- and only every NEEDSYOU_SCAN_EVERY ticks, so it would be rare and
# baffling. A subshell inherits the stub functions above, so both paths through
# the pass can be exercised under the flags production actually uses.
#
# Run as a STATEMENT, never as an `if` condition: bash suppresses errexit for
# the whole of a command it is testing, subshell and called functions included,
# so `if ( set -e; ... )` would pass no matter what the pass did.
errexit_rc() { ( set -euo pipefail; needsyou_pass ) >/dev/null 2>&1; printf '%s' "$?"; }
eq "the pass survives set -euo pipefail" "0" "$(errexit_rc)"

# The failure this guards: a transient blip empties the scan, the empty set is
# persisted, every item loses its `since`, and the next good scan re-announces
# the lot as new -- the "notification you learn to ignore" this feature exists
# to avoid.
forgejo_list_open_bot_prs() { return 1; }
LOGGED=""; needsyou_pass
has "an incomplete scan says so"  "$LOGGED" "scan incomplete"
eq  "it announces nothing"        "0" "$(grep -c 'needs-you: acme' <<<"$LOGGED" || true)"
eq  "and does NOT drop the set it could not re-confirm" "$WANT" \
  "$(jq -r '.needsyou|keys|join(" ")' "$STATE")"
eq "an incomplete scan bails cleanly under set -euo pipefail too" "0" "$(errexit_rc)"

if [ "$FAIL" -eq 0 ]; then
  echo "test-needsyou: all checks passed"
else
  echo "test-needsyou: $FAIL FAILED"
  exit 1
fi
