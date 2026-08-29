#!/usr/bin/env bash
# Unit tests for the maintenance re-file-on-close fingerprint
# (lib/maintenance-checks.sh) + the open/closed dedup match it drives.
# Skip-safe: exits 0 with a notice if a required tool is missing.
set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
TICK="$HERE/bin/tick.sh"
# shellcheck source=../lib/maintenance-checks.sh
. "$HERE/lib/maintenance-checks.sh"

for t in sha256sum sort tr sed grep jq mktemp; do
  command -v "$t" >/dev/null 2>&1 || { echo "test-maint-fp: $t unavailable -- skipping"; exit 0; }
done

# maint_file_deduped_issue lives inline in bin/tick.sh (which has top-level
# side-effecting code, so it can't be sourced directly) -- lifted out the
# same way test-maintenance.sh does for its do_maintenance_* functions.
MFDI_SRC=$(sed -n '/^maint_file_deduped_issue() {$/,/^}$/p' "$TICK")
[ -n "$MFDI_SRC" ] || { echo "test-maint-fp: could not extract maint_file_deduped_issue() from bin/tick.sh -- skipping"; exit 0; }
eval "$MFDI_SRC"
MAINT_TRIAGE_MARKER="<!-- agent:maint-triage -->"
MAINT_BUMPS_MARKER="<!-- agent:maint-bumps -->"

FAIL=0
eq() { if [ "$2" = "$3" ]; then printf '  + %s\n' "$1"; else printf '  x %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi; }
ne() { if [ "$2" != "$3" ]; then printf '  + %s\n' "$1"; else printf '  x %s: expected != [%s]\n' "$1" "$2"; FAIL=$((FAIL + 1)); fi; }

TMP=$(mktemp -d) || { echo "test-maint-fp: mktemp unavailable -- skipping"; exit 0; }
trap 'rm -rf "$TMP"' EXIT

echo "== maint_findings_fingerprint: stable + order/case/whitespace-independent =="
printf 'CVE-2024-1\nreact\nGHSA-abc\n' > "$TMP/k1"
printf '  ghsa-abc \nreact\ncve-2024-1\n\n' > "$TMP/k2"   # reordered, recased, extra ws + blank
FP1=$(maint_findings_fingerprint "$TMP/k1")
FP2=$(maint_findings_fingerprint "$TMP/k2")
eq "non-empty hash for real keys" "1" "$([ -n "$FP1" ] && echo 1 || echo 0)"
eq "same finding-set -> same fingerprint" "$FP1" "$FP2"

echo "== sensitivity: a new finding -> a different fingerprint (still surfaces) =="
printf 'cve-2024-1\nreact\nghsa-abc\nlodash\n' > "$TMP/k3"   # added lodash
FP3=$(maint_findings_fingerprint "$TMP/k3")
ne "added finding changes the hash" "$FP1" "$FP3"

echo "== empty / missing / blank keys -> empty fingerprint (caller falls back) =="
: > "$TMP/empty"
eq "empty keys file -> empty" "" "$(maint_findings_fingerprint "$TMP/empty")"
eq "missing keys file -> empty" "" "$(maint_findings_fingerprint "$TMP/nope")"
printf '   \n\n  \n' > "$TMP/blanks"
eq "all-whitespace keys -> empty" "" "$(maint_findings_fingerprint "$TMP/blanks")"

echo "== maint_fp_marker =="
eq "marker format" "<!-- maint-fp:deadbeef -->" "$(maint_fp_marker deadbeef)"
eq "empty fp -> empty marker" "" "$(maint_fp_marker "")"

echo "== open/closed match: a CLOSED ticket carrying the fingerprint is found (=> stays dismissed) =="
MK=$(maint_fp_marker "$FP1")
# Same jq predicate forgejo_find_marked_issue uses (bot-authored, body contains marker), state=all.
ISSUES=$(jq -n --arg mk "$MK" '[
  {number:7, state:"closed", user:{login:"igor"}, body:("judged + dismissed\n" + $mk)},
  {number:9, state:"open",   user:{login:"igor"}, body:"unrelated maint-bumps ticket"}
]')
HIT=$(jq -r --arg b "igor" --arg m "$MK" '[.[] | select(.user.login==$b and ((.body//"")|contains($m)))][0].number // ""' <<<"$ISSUES")
eq "closed dismissed ticket matched -> skip refile" "7" "$HIT"
ISSUES2=$(jq -n '[{number:9, state:"open", user:{login:"igor"}, body:"no fingerprint here"}]')
MISS=$(jq -r --arg b "igor" --arg m "$MK" '[.[] | select(.user.login==$b and ((.body//"")|contains($m)))][0].number // ""' <<<"$ISSUES2")
eq "no matching fingerprint -> would file" "" "$MISS"

# -- maint_file_deduped_issue end-to-end (igor#554) -----------------
#
# Mock Forgejo API surface. MOCK_EXISTING is the JSON forgejo_find_marked_issue
# should return for whatever marker the test sets up (a real repo would filter
# by marker itself; here each test just sets what the one query it triggers
# should find). forgejo_open_issue is called inside `$(...)` by
# maint_file_deduped_issue, so it runs in a subshell -- an in-process counter
# variable wouldn't survive that, hence the call log file. forgejo_add_label /
# forgejo_assign are called directly (no subshell), so plain arrays work for
# those. mock_open_calls() reads the log; reset_open_log() clears it between
# scenarios.
MOCK_EXISTING=""
MOCK_OPEN_LOG="$TMP/open_calls.log"
MOCK_LABELS=()
MOCK_ASSIGNS=()
forgejo_find_marked_issue() { printf '%s' "$MOCK_EXISTING"; return 0; }
forgejo_open_issue() { echo called >> "$MOCK_OPEN_LOG"; echo 42; }
forgejo_add_label() { MOCK_LABELS+=("$3"); return 0; }
forgejo_assign() { MOCK_ASSIGNS+=("$3"); return 0; }
log() { :; }
# Read only by the eval'd maint_file_deduped_issue, which shellcheck can't see
# through.
# shellcheck disable=SC2034
BOT_USER="igor"
# shellcheck disable=SC2034
FORGEJO_REVIEWER="reviewer"
reset_open_log() { : > "$MOCK_OPEN_LOG"; }
mock_open_calls() { wc -l < "$MOCK_OPEN_LOG" | tr -d '[:space:]'; }

echo "== maint_file_deduped_issue: a dismissed (closed) finding-set is NOT re-filed =="
MOCK_EXISTING='{"number":7,"state":"closed"}'
reset_open_log
maint_file_deduped_issue repo "$MAINT_TRIAGE_MARKER" "t" "b" true "" "$FP1"
eq "closed ticket carrying this fingerprint -> no new issue opened" "0" "$(mock_open_calls)"

echo "== maint_file_deduped_issue: a genuinely new finding-set still files after a prior dismissal =="
MOCK_EXISTING=""
reset_open_log
maint_file_deduped_issue repo "$MAINT_TRIAGE_MARKER" "t" "b" true "" "$FP3"
eq "no ticket carries the new fingerprint -> filed" "1" "$(mock_open_calls)"

echo "== maint_file_deduped_issue: maint-bumps (no fingerprint) still re-audits fresh once its ticket closes =="
MOCK_EXISTING='{"number":9,"state":"open"}'
reset_open_log
maint_file_deduped_issue repo "$MAINT_BUMPS_MARKER" "t" "b" true ""
eq "an OPEN bumps ticket -> not re-filed (still in progress)" "0" "$(mock_open_calls)"
MOCK_EXISTING='{"number":9,"state":"closed"}'
reset_open_log
maint_file_deduped_issue repo "$MAINT_BUMPS_MARKER" "t" "b" true ""
eq "a CLOSED bumps ticket (merged PR) -> re-audits fresh (regression check)" "1" "$(mock_open_calls)"

echo "== maint_file_deduped_issue: maint-triage routes by validation -- Agent-labeled when validated =="
MOCK_EXISTING=""
MOCK_LABELS=(); MOCK_ASSIGNS=()
maint_file_deduped_issue repo "$MAINT_TRIAGE_MARKER" "t" "b" true "" "$FP1"
eq "validated repo -> Agent label applied" "Agent" "${MOCK_LABELS[0]:-}"
eq "validated repo -> left unassigned for the claimable grind" "0" "${#MOCK_ASSIGNS[@]}"

echo "== maint_file_deduped_issue: maint-triage routes by validation -- human-assigned when NOT validated =="
MOCK_EXISTING=""
MOCK_LABELS=(); MOCK_ASSIGNS=()
maint_file_deduped_issue repo "$MAINT_TRIAGE_MARKER" "t" "b" false "" "$FP2"
eq "unvalidated repo -> Status/Need More Info label applied" "Status/Need More Info" "${MOCK_LABELS[0]:-}"
eq "unvalidated repo -> assigned to the reviewer" "reviewer" "${MOCK_ASSIGNS[0]:-}"

echo "== negative test: sever the dismissal memory (drop the fingerprint arg) -- the dismissed finding IS re-filed =="
# Same closed ticket as the first scenario above, but called the way a
# skip-if-open (no fingerprint) caller would: proves the fingerprint arg is
# what suppresses the re-file, not something else about a closed ticket.
MOCK_EXISTING='{"number":7,"state":"closed"}'
reset_open_log
maint_file_deduped_issue repo "$MAINT_TRIAGE_MARKER" "t" "b" true ""
eq "no fingerprint passed -> closed ticket no longer suppresses -- re-filed" "1" "$(mock_open_calls)"

if [ "$FAIL" -eq 0 ]; then
  echo "test-maint-fp: all checks passed"
else
  echo "test-maint-fp: $FAIL FAILED"
  exit 1
fi
