#!/usr/bin/env bash
# test-landed.sh -- unit tests for lib/landed.sh: the host-state
# landed-verification companion to the deploy barrier for the two url-less
# repos (igor#512) -- igor itself (self-pull HEAD) and the distillery
# (context-cache generation marker).
#   landed_kind/landed_applies  -- the two hardcoded repos, nothing else.
#   landed_record/landed_clear/landed_pending_* -- the .landed state round-trip.
#   landed_assert_igor          -- ancestor check against a REAL fixture repo.
#   landed_assert_distillery    -- exact-match check against a fixture cache dir.
#   do_landed_tick              -- landed -> note+clear; not-landed -> attempts++;
#                                   grace exceeded -> alert+clear.
#   do_automerge_tick wiring    -- a url-less merge on igor/distillery stamps
#                                   .landed (not .deploy); a url-bearing repo's
#                                   merge is untouched (still .deploy only).
#
# Every boundary this suite reaches beyond lib/landed.sh itself (_fj,
# forgejo_*, email_send, do_automerge_tick's approval/CI/mergeable checks) is
# STUBBED -- no network, no real Forgejo state. BOT_USER and FORGEJO_REVIEWER
# are exported explicitly (igor#512 review of the prior attempt, PR #525:
# do_automerge_tick reaches forgejo_list_open_bot_prs "$repo" "$BOT_USER" --
# an unexported BOT_USER is an unbound-variable crash under a clean shell's
# `set -u`, even though it silently inherits a value when run from a shell
# that already has the harness's own env loaded). Verify with:
#   env -i HOME="$HOME" PATH="$PATH" bash bin/test-landed.sh
#
# Skip-safe: needs jq + git; exits 0 with a notice if either is absent.
set -uo pipefail

command -v jq  >/dev/null 2>&1 || { echo "test-landed: jq absent -- skipping";  exit 0; }
command -v git >/dev/null 2>&1 || { echo "test-landed: git absent -- skipping"; exit 0; }

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/dossier.sh
. "$HERE/../lib/dossier.sh"
# shellcheck source=../lib/landed.sh
. "$HERE/../lib/landed.sh"
# shellcheck source=../lib/automerge.sh
. "$HERE/../lib/automerge.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export AGENT_STATE_DIR="$TMP"
STATE="$TMP/discretionary-state.json"

FAIL=0
ok()  { local d="$1"; shift; if "$@" >/dev/null 2>&1; then printf '  + %s\n' "$d"; else printf '  x %s (expected rc0)\n' "$d"; FAIL=$((FAIL + 1)); fi; }
no()  { local d="$1"; shift; if "$@" >/dev/null 2>&1; then printf '  x %s (expected rc!=0)\n' "$d"; FAIL=$((FAIL + 1)); else printf '  + %s\n' "$d"; fi; }
eq()  { if [ "$2" = "$3" ]; then printf '  + %s\n' "$1"; else printf '  x %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi; }
has() { case "$2" in *"$3"*) printf '  + %s\n' "$1" ;; *) printf '  x %s: [%s] lacks [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)) ;; esac; }

echo "== landed_kind / landed_applies: the two hardcoded repos, nothing else =="
eq "kind: igor self-repo"        "igor"       "$(landed_kind "$AUTOMERGE_SELF_REPO")"
eq "kind: distillery"            "distillery" "$(landed_kind "$LANDED_DISTILLERY_REPO")"
eq "kind: an unrelated repo"     ""           "$(landed_kind acme/site)"
ok "applies: igor"               landed_applies "$AUTOMERGE_SELF_REPO"
ok "applies: distillery"         landed_applies "$LANDED_DISTILLERY_REPO"
no "applies: an unrelated repo"  landed_applies acme/site

echo "== landed_record / landed_clear / landed_pending_* round-trip =="
landed_record "$AUTOMERGE_SELF_REPO" 521 sha521
eq "pending_repos lists the stamped repo" "$AUTOMERGE_SELF_REPO" "$(landed_pending_repos)"
eq "pending_entry: pr"       "521"   "$(jq -r '.pr' <<<"$(landed_pending_entry "$AUTOMERGE_SELF_REPO")")"
eq "pending_entry: sha"      "sha521" "$(jq -r '.sha' <<<"$(landed_pending_entry "$AUTOMERGE_SELF_REPO")")"
eq "pending_entry: attempts starts at 0" "0" "$(jq -r '.attempts' <<<"$(landed_pending_entry "$AUTOMERGE_SELF_REPO")")"
landed_attempts_set "$AUTOMERGE_SELF_REPO" 3
eq "attempts_set persists"   "3"     "$(jq -r '.attempts' <<<"$(landed_pending_entry "$AUTOMERGE_SELF_REPO")")"
landed_record "$AUTOMERGE_SELF_REPO" 522 sha522
eq "re-record on the same repo resets attempts" "0" "$(jq -r '.attempts' <<<"$(landed_pending_entry "$AUTOMERGE_SELF_REPO")")"
landed_clear "$AUTOMERGE_SELF_REPO"
eq "clear drops the entry" "{}" "$(landed_pending_entry "$AUTOMERGE_SELF_REPO")"
eq "clear leaves no pending repos" "" "$(landed_pending_repos)"

echo "== landed_assert_igor: ancestor check against a REAL fixture git repo =="
FIXTURE="$TMP/igor-fixture"
git init -q -b master "$FIXTURE"
git -C "$FIXTURE" config user.email t@t
git -C "$FIXTURE" config user.name  t
: > "$FIXTURE/a.txt"; git -C "$FIXTURE" add -A; git -C "$FIXTURE" commit -q -m one
SHA1=$(git -C "$FIXTURE" rev-parse HEAD)
: > "$FIXTURE/b.txt"; git -C "$FIXTURE" add -A; git -C "$FIXTURE" commit -q -m two
SHA2=$(git -C "$FIXTURE" rev-parse HEAD)
ok "assert_igor: HEAD equals the merged sha"        landed_assert_igor "$SHA2" "$FIXTURE"
ok "assert_igor: HEAD DESCENDS from an earlier merged sha" landed_assert_igor "$SHA1" "$FIXTURE"
no "assert_igor: a sha never reached by HEAD fails" landed_assert_igor "deadbeef0000000000000000000000000000dead" "$FIXTURE"
eq "igor_observed: reports the fixture's real HEAD" "$SHA2" "$(landed_igor_observed "$FIXTURE")"
no "assert_igor: no repo at the path fails"         landed_assert_igor "$SHA1" "$TMP/no-such-repo"

echo "== landed_assert_distillery: exact-match against a fixture cache dir =="
CACHE="$TMP/context-cache"
mkdir -p "$CACHE/current"
printf 'distsha123' > "$CACHE/current/HEAD"
eq "distillery_observed: reads the generation marker" "distsha123" "$(landed_distillery_observed "$CACHE")"
ok "assert_distillery: marker equals the merged sha"      landed_assert_distillery "distsha123" "$CACHE"
no "assert_distillery: marker is a DIFFERENT sha (stale generation)" landed_assert_distillery "distsha999" "$CACHE"
no "assert_distillery: cache never seeded (no HEAD file)" landed_assert_distillery "distsha123" "$TMP/unseeded-cache"

echo "== do_landed_tick: landed -> queues a ship-report note and clears =="
echo '{}' > "$STATE"
landed_record "$AUTOMERGE_SELF_REPO" 521 "$SHA2"
# Point the checker at the fixture repo, not the real AGENT_HOME, by
# overriding AGENT_HOME for the duration of this section (landed_assert_igor
# / landed_igor_observed default to it).
export AGENT_HOME="$FIXTURE"
ok "do_landed_tick returns 0" do_landed_tick
eq "landed entry cleared after confirming"    "{}" "$(landed_pending_entry "$AUTOMERGE_SELF_REPO")"
NOTES=$(jq -c '.landed_notes' "$STATE")
eq "one note queued"                          "1"  "$(jq -r 'length' <<<"$NOTES")"
eq "note names the repo"                      "$AUTOMERGE_SELF_REPO" "$(jq -r '.[0].repo' <<<"$NOTES")"
eq "note names the pr"                        "521" "$(jq -r '.[0].pr' <<<"$NOTES")"
has "note detail mentions self-pull"          "$(jq -r '.[0].detail' <<<"$NOTES")" "self-pull"

echo "== do_landed_tick: not landed yet -> attempts increments, stays pending =="
echo '{}' > "$STATE"
landed_record "$AUTOMERGE_SELF_REPO" 521 "deadbeef0000000000000000000000000000dead"
ok "do_landed_tick returns 0 even mid-wait" do_landed_tick
eq "entry still pending"                    "1" "$(jq -r '.attempts' <<<"$(landed_pending_entry "$AUTOMERGE_SELF_REPO")")"
eq "no note queued yet"                     "0" "$(jq -r '.landed_notes // [] | length' "$STATE")"
do_landed_tick
eq "second miss -> attempts=2"              "2" "$(jq -r '.attempts' <<<"$(landed_pending_entry "$AUTOMERGE_SELF_REPO")")"

echo "== do_landed_tick: grace exceeded -> alerts and clears =="
EMAIL_CALLS=0
email_send() { EMAIL_CALLS=$((EMAIL_CALLS + 1)); return 0; }
forgejo_comment() { COMMENT_BODY="$3"; return 0; }
export PRIMARY_RECIPIENTS=josh@example.com SMTP2GO_API_KEY=k SMTP2GO_SENDER=s@example.com
echo '{}' > "$STATE"
landed_record "$AUTOMERGE_SELF_REPO" 521 "deadbeef0000000000000000000000000000dead"
jq '.landed[$r].attempts = ($n|tonumber)' --arg r "$AUTOMERGE_SELF_REPO" --arg n "$((LANDED_GRACE_TICKS - 1))" "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
ok "do_landed_tick returns 0 on the grace-exceeding check" do_landed_tick
eq "entry cleared after the alert"          "{}" "$(landed_pending_entry "$AUTOMERGE_SELF_REPO")"
eq "exactly one alert email sent"           "1"  "$EMAIL_CALLS"
has "PR comment names the merged sha"       "$COMMENT_BODY" "deadbeef"
unset -f email_send forgejo_comment
unset AGENT_HOME

echo "== do_landed_tick: an entry for a repo landed.sh no longer recognizes is dropped =="
echo '{}' > "$STATE"
jq -n --arg r "acme/orphan" '{landed: {($r): {pr:"1", sha:"x", attempts:0}}}' > "$STATE"
do_landed_tick
eq "orphaned entry dropped, no crash" "" "$(landed_pending_repos)"

echo "== do_automerge_tick wiring: a url-less merge on igor stamps .landed, not .deploy =="
export FORGEJO_REVIEWER=josh BOT_USER=igor
echo '{}' > "$STATE"
automerge_url_status() { printf 'ok\t'; }   # url-less, like AUTOMERGE_SELF_REPO's real dossier answer
VALIDATED_REPOS_JSON="{\"full_name\":\"${AUTOMERGE_SELF_REPO}\"}"
forgejo_list_open_bot_prs() { echo '[{"number":521}]'; }
forgejo_commit_status() { echo success; }
automerge_mergeable() { return 0; }
automerge_behind_count() { echo 0; }
automerge_do_merge() { echo "mergedsha521"; }
_fj() { echo '{"head":{"sha":"headsha521"}}'; }
automerge_require_human() { return 1; }
automerge_approved_by() { return 0; }
automerge_approval_covers_head() { return 0; }
automerge_reviewer_blocks() { return 1; }
ok "do_automerge_tick merges the url-less igor repo" do_automerge_tick
eq "no .deploy stamped (nothing to smoke-test)" "" "$(jq -r '.deploy.repo // ""' "$STATE")"
eq ".landed stamped for igor"                   "mergedsha521" "$(jq -r --arg r "$AUTOMERGE_SELF_REPO" '.landed[$r].sha // ""' "$STATE")"
eq ".landed pr recorded"                        "521" "$(jq -r --arg r "$AUTOMERGE_SELF_REPO" '.landed[$r].pr // ""' "$STATE")"

echo "== do_automerge_tick wiring: a url-BEARING repo's merge is untouched (still .deploy only) =="
echo '{}' > "$STATE"
automerge_url_status() { printf 'ok\thttps://porksicle.com'; }
VALIDATED_REPOS_JSON='{"full_name":"acme/site"}'
ok "do_automerge_tick merges the url-bearing repo" do_automerge_tick
eq ".deploy stamped as before"    "acme/site" "$(jq -r '.deploy.repo // ""' "$STATE")"
eq "no .landed entry created"     "" "$(jq -r '.landed // {} | keys | join(",")' "$STATE")"

[ "$FAIL" -eq 0 ] && { echo "test-landed: all checks passed"; exit 0; }
echo "test-landed: $FAIL check(s) FAILED"
exit 1
