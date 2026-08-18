#!/usr/bin/env bash
# test-landed.sh -- unit tests for lib/landed.sh: the host-state
# landed-verification companion to the deploy barrier for url-less
# auto-merge repos (igor#512, genericized igor#538). The repo -> kind
# binding lives in each repo's own dossier (`landed-kind`); this module is
# a dispatcher over the two IMPLEMENTED kinds, self-pull and context-cache.
#   landed_kind/landed_applies  -- dispatches on the declared landed-kind
#                                   dossier value; undeclared is quiet,
#                                   unrecognized is loud, both are "no watch".
#   landed_record/landed_clear/landed_pending_* -- the .landed state round-trip.
#   landed_assert_self_pull     -- ancestor check against a REAL fixture repo.
#   landed_assert_context_cache -- exact-match check against a fixture cache dir.
#   do_landed_tick              -- landed -> note+clear; not-landed -> attempts++;
#                                   grace exceeded -> alert+clear.
#   do_automerge_tick wiring    -- a url-less merge on a kind-declaring repo
#                                   stamps .landed (not .deploy); a url-bearing
#                                   repo's merge is untouched (still .deploy only).
#
# Every boundary this suite reaches beyond lib/landed.sh itself (forgejo_*,
# email_send, do_automerge_tick's approval/CI/mergeable checks) is STUBBED --
# no network, no real Forgejo state. landed_kind's dossier read goes through
# lib/dossier.sh for real (that wiring is the point of this genericization),
# with forgejo_repo_get_file the one stubbed boundary underneath it -- see
# the fixture repos below. BOT_USER and FORGEJO_REVIEWER are exported
# explicitly (igor#512 review of the prior attempt, PR #525:
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
# PASS is reported at the end so a "N checks passed" claim about this suite is
# checkable against the run rather than carried over from an earlier one.
PASS=0
pass() { PASS=$((PASS + 1)); printf '  + %s\n' "$1"; }
ok()  { local d="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else printf '  x %s (expected rc0)\n' "$d"; FAIL=$((FAIL + 1)); fi; }
no()  { local d="$1"; shift; if "$@" >/dev/null 2>&1; then printf '  x %s (expected rc!=0)\n' "$d"; FAIL=$((FAIL + 1)); else pass "$d"; fi; }
eq()  { if [ "$2" = "$3" ]; then pass "$1"; else printf '  x %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi; }
has() { case "$2" in *"$3"*) pass "$1" ;; *) printf '  x %s: [%s] lacks [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)) ;; esac; }

# Fixture repos, none of which have adopted the AGENTS.md dossier (legacy
# agent.json `.landed.kind` path only) -- reused across every section below.
SELF_REPO="$AUTOMERGE_SELF_REPO"    # joshtronic/igor -- declares landed-kind: self-pull, for real
CACHE_REPO="joshtronic/distillery"  # declares landed-kind: context-cache
PLAIN_REPO="acme/plain"             # declares no landed-kind at all
WEIRD_REPO="acme/weird"             # declares an unrecognized landed-kind value

forgejo_repo_get_file() {
  local repo="$1" path="$2"
  [ "$path" = "AGENTS.md" ] && return 1   # no fixture repo has adopted the dossier
  case "$repo" in
    "$SELF_REPO")  printf '%s' '{"landed":{"kind":"self-pull"}}' ;;
    "$CACHE_REPO") printf '%s' '{"landed":{"kind":"context-cache"}}' ;;
    "$WEIRD_REPO") printf '%s' '{"landed":{"kind":"quantum-tunnel"}}' ;;
    *)             return 1 ;;
  esac
}

echo "== landed_kind / landed_applies: dispatches over the declared landed-kind dossier value =="
eq "kind: self-pull repo"                 "self-pull"     "$(landed_kind "$SELF_REPO")"
eq "kind: context-cache repo"             "context-cache" "$(landed_kind "$CACHE_REPO")"
eq "kind: undeclared repo echoes nothing" ""               "$(landed_kind "$PLAIN_REPO")"
ok "applies: self-pull repo"              landed_applies "$SELF_REPO"
ok "applies: context-cache repo"          landed_applies "$CACHE_REPO"
no "applies: undeclared repo"             landed_applies "$PLAIN_REPO"

echo "== landed_kind: unrecognized value is fail-fast (logs loudly), undeclared is quiet =="
no "kind: unrecognized value fails"          landed_kind "$WEIRD_REPO"
eq "kind: unrecognized value echoes nothing" "" "$(landed_kind "$WEIRD_REPO" 2>/dev/null)"
LOUD=$(landed_kind "$WEIRD_REPO" 2>&1 1>/dev/null)
has "kind: unrecognized value logs loudly, names the repo and the bad value" \
  "$LOUD" "$WEIRD_REPO declares unrecognized landed-kind 'quantum-tunnel'"
QUIET=$(landed_kind "$PLAIN_REPO" 2>&1 1>/dev/null)
eq "kind: undeclared repo logs nothing -- quiet, same as any other unwatched repo" "" "$QUIET"

echo "== landed_kind: a missing lib/dossier.sh dependency fails CLOSED and logs =="
BARE=$(bash -c '. "$1/../lib/landed.sh"; landed_kind acme/site' _ "$HERE" 2>&1)
has "kind: missing lib/dossier.sh logs instead of failing silently" "$BARE" "lib/dossier.sh not sourced"
BARE_RC=$(bash -c '. "$1/../lib/landed.sh"; landed_kind acme/site >/dev/null 2>&1; echo $?' _ "$HERE")
eq "kind: missing lib/dossier.sh fails CLOSED (rc1, no watch)" "1" "$BARE_RC"

echo "== landed_record / landed_clear / landed_pending_* round-trip =="
landed_record "$SELF_REPO" 521 sha521
eq "pending_repos lists the stamped repo" "$SELF_REPO" "$(landed_pending_repos)"
eq "pending_entry: pr"       "521"   "$(jq -r '.pr' <<<"$(landed_pending_entry "$SELF_REPO")")"
eq "pending_entry: sha"      "sha521" "$(jq -r '.sha' <<<"$(landed_pending_entry "$SELF_REPO")")"
eq "pending_entry: attempts starts at 0" "0" "$(jq -r '.attempts' <<<"$(landed_pending_entry "$SELF_REPO")")"
landed_attempts_set "$SELF_REPO" 3
eq "attempts_set persists"   "3"     "$(jq -r '.attempts' <<<"$(landed_pending_entry "$SELF_REPO")")"
landed_record "$SELF_REPO" 522 sha522
eq "re-record on the same repo resets attempts" "0" "$(jq -r '.attempts' <<<"$(landed_pending_entry "$SELF_REPO")")"
landed_clear "$SELF_REPO"
eq "clear drops the entry" "{}" "$(landed_pending_entry "$SELF_REPO")"
eq "clear leaves no pending repos" "" "$(landed_pending_repos)"
echo '{"unrelated":1}' > "$STATE"
landed_clear "$SELF_REPO"
eq "clear on a state with no .landed writes no null key" "false" "$(jq -r 'has("landed")' "$STATE")"
eq "clear leaves the rest of the state alone"            "1"     "$(jq -r '.unrelated' "$STATE")"

echo "== landed_assert_self_pull: ancestor check against a REAL fixture git repo =="
FIXTURE="$TMP/igor-fixture"
git init -q -b master "$FIXTURE"
git -C "$FIXTURE" config user.email t@t
git -C "$FIXTURE" config user.name  t
: > "$FIXTURE/a.txt"; git -C "$FIXTURE" add -A; git -C "$FIXTURE" commit -q -m one
SHA1=$(git -C "$FIXTURE" rev-parse HEAD)
: > "$FIXTURE/b.txt"; git -C "$FIXTURE" add -A; git -C "$FIXTURE" commit -q -m two
SHA2=$(git -C "$FIXTURE" rev-parse HEAD)
ok "assert_self_pull: HEAD equals the merged sha"        landed_assert_self_pull "$SHA2" "$FIXTURE"
ok "assert_self_pull: HEAD DESCENDS from an earlier merged sha" landed_assert_self_pull "$SHA1" "$FIXTURE"
no "assert_self_pull: a sha never reached by HEAD fails" landed_assert_self_pull "deadbeef0000000000000000000000000000dead" "$FIXTURE"
eq "self_pull_observed: reports the fixture's real HEAD" "$SHA2" "$(landed_self_pull_observed "$FIXTURE")"
no "assert_self_pull: no repo at the path fails"         landed_assert_self_pull "$SHA1" "$TMP/no-such-repo"

echo "== landed_assert_context_cache: exact-match against a fixture cache dir =="
CACHE="$TMP/context-cache"
mkdir -p "$CACHE/current"
printf 'distsha123' > "$CACHE/current/HEAD"
eq "context_cache_observed: reads the generation marker" "distsha123" "$(landed_context_cache_observed "$CACHE")"
ok "assert_context_cache: marker equals the merged sha"      landed_assert_context_cache "distsha123" "$CACHE"
no "assert_context_cache: marker is a DIFFERENT sha (stale generation)" landed_assert_context_cache "distsha999" "$CACHE"
no "assert_context_cache: cache never seeded (no HEAD file)" landed_assert_context_cache "distsha123" "$TMP/unseeded-cache"

echo "== do_landed_tick: landed -> queues a ship-report note and clears =="
echo '{}' > "$STATE"
landed_record "$SELF_REPO" 521 "$SHA2"
# Point the checker at the fixture repo, not the real AGENT_HOME, by
# overriding AGENT_HOME for the duration of this section (landed_assert_self_pull
# / landed_self_pull_observed default to it).
export AGENT_HOME="$FIXTURE"
ok "do_landed_tick returns 0" do_landed_tick
eq "landed entry cleared after confirming"    "{}" "$(landed_pending_entry "$SELF_REPO")"
NOTES=$(jq -c '.landed_notes' "$STATE")
eq "one note queued"                          "1"  "$(jq -r 'length' <<<"$NOTES")"
eq "note names the repo"                      "$SELF_REPO" "$(jq -r '.[0].repo' <<<"$NOTES")"
eq "note names the pr"                        "521" "$(jq -r '.[0].pr' <<<"$NOTES")"
has "note detail mentions self-pull"          "$(jq -r '.[0].detail' <<<"$NOTES")" "self-pull"

echo "== do_landed_tick: not landed yet -> attempts increments, stays pending =="
echo '{}' > "$STATE"
landed_record "$SELF_REPO" 521 "deadbeef0000000000000000000000000000dead"
ok "do_landed_tick returns 0 even mid-wait" do_landed_tick
eq "entry still pending"                    "1" "$(jq -r '.attempts' <<<"$(landed_pending_entry "$SELF_REPO")")"
eq "no note queued yet"                     "0" "$(jq -r '.landed_notes // [] | length' "$STATE")"
do_landed_tick
eq "second miss -> attempts=2"              "2" "$(jq -r '.attempts' <<<"$(landed_pending_entry "$SELF_REPO")")"

echo "== do_landed_tick: a landed repo does not mark a later not-landed one =="
# The confirmed-landing detail must not carry across loop iterations. Order
# matters: landed_pending_repos yields jq `keys` (sorted), so the second repo
# is named to sort AFTER the self-pull repo's, putting the landing first.
ZZ_CACHE_REPO="joshtronic/zz-distillery"
_saved_forgejo_repo_get_file=$(declare -f forgejo_repo_get_file)
forgejo_repo_get_file() {
  local repo="$1" path="$2"
  [ "$path" = "AGENTS.md" ] && return 1
  case "$repo" in
    "$SELF_REPO")     printf '%s' '{"landed":{"kind":"self-pull"}}' ;;
    "$ZZ_CACHE_REPO") printf '%s' '{"landed":{"kind":"context-cache"}}' ;;
    *)                return 1 ;;
  esac
}
export CONTEXT_CACHE_DIR="$TMP/unseeded-cache"
echo '{}' > "$STATE"
landed_record "$SELF_REPO"      521 "$SHA2"
landed_record "$ZZ_CACHE_REPO"  4   "distsha-never-served"
do_landed_tick
eq "the landed repo cleared"        "{}" "$(landed_pending_entry "$SELF_REPO")"
eq "the other repo stays pending"   "1"  "$(jq -r '.attempts' <<<"$(landed_pending_entry "$ZZ_CACHE_REPO")")"
eq "exactly one note queued"        "1"  "$(jq -r '.landed_notes | length' "$STATE")"
eq "the note is the repo that DID land" "$SELF_REPO" "$(jq -r '.landed_notes[0].repo' "$STATE")"
eval "$_saved_forgejo_repo_get_file"
unset CONTEXT_CACHE_DIR

echo "== do_landed_tick: grace exceeded -> alerts and clears =="
EMAIL_CALLS=0
email_send() { EMAIL_CALLS=$((EMAIL_CALLS + 1)); return 0; }
forgejo_comment() { COMMENT_BODY="$3"; return 0; }
export PRIMARY_RECIPIENTS=josh@example.com SMTP2GO_API_KEY=k SMTP2GO_SENDER=s@example.com
echo '{}' > "$STATE"
landed_record "$SELF_REPO" 521 "deadbeef0000000000000000000000000000dead"
jq '.landed[$r].attempts = ($n|tonumber)' --arg r "$SELF_REPO" --arg n "$((LANDED_GRACE_TICKS - 1))" "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
ok "do_landed_tick returns 0 on the grace-exceeding check" do_landed_tick
eq "entry cleared after the alert"          "{}" "$(landed_pending_entry "$SELF_REPO")"
eq "exactly one alert email sent"           "1"  "$EMAIL_CALLS"
has "PR comment names the merged sha"       "$COMMENT_BODY" "deadbeef"
unset -f email_send forgejo_comment
unset AGENT_HOME

echo "== do_landed_tick: an entry for a repo landed.sh no longer recognizes is dropped =="
echo '{}' > "$STATE"
jq -n --arg r "acme/orphan" '{landed: {($r): {pr:"1", sha:"x", attempts:0}}}' > "$STATE"
do_landed_tick
eq "orphaned entry dropped, no crash" "" "$(landed_pending_repos)"

echo "== do_automerge_tick wiring: a url-less merge on a kind-declaring repo stamps .landed, not .deploy =="
export FORGEJO_REVIEWER=josh BOT_USER=igor
echo '{}' > "$STATE"
automerge_url_status() { printf 'ok\t'; }   # url-less, like SELF_REPO's real dossier answer
export VALIDATED_REPOS_JSON="{\"full_name\":\"${SELF_REPO}\"}"
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
ok "do_automerge_tick merges the url-less self-pull repo" do_automerge_tick
eq "no .deploy stamped (nothing to smoke-test)" "" "$(jq -r '.deploy.repo // ""' "$STATE")"
eq ".landed stamped for the repo"               "mergedsha521" "$(jq -r --arg r "$SELF_REPO" '.landed[$r].sha // ""' "$STATE")"
eq ".landed pr recorded"                        "521" "$(jq -r --arg r "$SELF_REPO" '.landed[$r].pr // ""' "$STATE")"

echo "== do_automerge_tick wiring: a url-less merge on a repo with NO landed-kind skips the watch entirely =="
echo '{}' > "$STATE"
export VALIDATED_REPOS_JSON="{\"full_name\":\"${PLAIN_REPO}\"}"
ok "do_automerge_tick merges the url-less undeclared repo" do_automerge_tick
eq "no .deploy stamped"   "" "$(jq -r '.deploy.repo // ""' "$STATE")"
eq "no .landed entry created (undeclared -- same as before this repo ever opted in)" \
  "" "$(jq -r '.landed // {} | keys | join(",")' "$STATE")"

echo "== do_automerge_tick wiring: a url-BEARING repo's merge is untouched (still .deploy only) =="
echo '{}' > "$STATE"
automerge_url_status() { printf 'ok\thttps://porksicle.com'; }
export VALIDATED_REPOS_JSON='{"full_name":"acme/site"}'
ok "do_automerge_tick merges the url-bearing repo" do_automerge_tick
eq ".deploy stamped as before"    "acme/site" "$(jq -r '.deploy.repo // ""' "$STATE")"
eq "no .landed entry created"     "" "$(jq -r '.landed // {} | keys | join(",")' "$STATE")"

[ "$FAIL" -eq 0 ] && { echo "test-landed: all $PASS checks passed"; exit 0; }
echo "test-landed: $FAIL of $((PASS + FAIL)) check(s) FAILED"
exit 1
