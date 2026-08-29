#!/usr/bin/env bash
# test-landed.sh -- unit tests for lib/landed.sh: the host-state
# landed-verification companion to the deploy barrier for url-less
# auto-merge repos (igor#512, genericized igor#538). The repo -> kind
# binding lives in each repo's own dossier (`landed-kind`); this module is
# a dispatcher over the two IMPLEMENTED kinds, self-pull and context-cache.
#   landed_kind/landed_applies  -- dispatches on the declared landed-kind
#                                   dossier value, read off EITHER an adopted
#                                   AGENTS.md `## Metadata` row or the legacy
#                                   agent.json; undeclared is quiet,
#                                   unrecognized is loud (all the way out to
#                                   the journal, through do_automerge_tick),
#                                   both are "no watch", and an UNREADABLE
#                                   dossier is neither (rc2) -- the watch is
#                                   kept, never dropped.
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
# the fixture repos below, whose one stubbed boundary is
# forgejo_repo_get_file_status. BOT_USER and FORGEJO_REVIEWER are exported
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
# AUTOMERGE_SELF_REPO is REQUIRED-AND-EXPLICIT, no default (igor#558) --
# lib/automerge.sh fails fast at source time without it.
export AUTOMERGE_SELF_REPO="joshtronic/igor"
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

# Fixture repos. All but DOSSIER_REPO are on the legacy agent.json
# `.landed.kind` path -- which is what the fleet actually has on disk today.
# DOSSIER_REPO is on the ADOPTED path (a root AGENTS.md `## Metadata` block
# carrying `landed-kind:`), the shape this genericization exists to establish
# and the one distillery#7 will add. Reused across every section below.
SELF_REPO="$AUTOMERGE_SELF_REPO"    # joshtronic/igor -- declares landed-kind: self-pull, for real
CACHE_REPO="joshtronic/distillery"  # declares landed-kind: context-cache
PLAIN_REPO="acme/plain"             # declares no landed-kind at all
WEIRD_REPO="acme/weird"             # declares an unrecognized landed-kind value
BLIP_REPO="acme/blip"               # dossier unreadable -- Forgejo blip, NOT "declares nothing"
DOSSIER_REPO="acme/adopted"         # declares landed-kind in an AGENTS.md Metadata block
# Sorts after SELF_REPO so the ordering section below sees the landing first.
ZZ_CACHE_REPO="joshtronic/zz-distillery"

# DOSSIER_REPO's root AGENTS.md, spec-shaped (docs/agents-md-spec.md). Its
# legacy agent.json below deliberately declares a DIFFERENT kind, so an
# assertion that reads back `context-cache` proves the Metadata block is what
# answered rather than the fallback.
DOSSIER_AGENTS_MD=$(cat <<'MD'
# acme/adopted

## KPIs

(none yet)

## Metadata

```
type: infra
landed-kind: context-cache
```
MD
)

forgejo_repo_get_file_status() {
  local repo="$1" path="$2"
  [ "$repo" = "$BLIP_REPO" ] && { printf 'error\t'; return 0; }   # transport failure, both files
  if [ "$path" = "AGENTS.md" ]; then
    [ "$repo" = "$DOSSIER_REPO" ] && { printf 'found\t%s' "$DOSSIER_AGENTS_MD"; return 0; }
    printf 'missing\t'; return 0   # every other fixture repo is still un-adopted
  fi
  case "$repo" in
    "$SELF_REPO")   printf 'found\t%s' '{"landed":{"kind":"self-pull"}}' ;;
    "$CACHE_REPO"|"$ZZ_CACHE_REPO") printf 'found\t%s' '{"landed":{"kind":"context-cache"}}' ;;
    "$WEIRD_REPO")  printf 'found\t%s' '{"landed":{"kind":"quantum-tunnel"}}' ;;
    "$DOSSIER_REPO") printf 'found\t%s' '{"landed":{"kind":"self-pull"}}' ;;
    *)              printf 'missing\t' ;;
  esac
}

# rc <fn...> -- echoes the exit status, for the three-way landed_kind contract.
rc() { "$@" >/dev/null 2>&1; echo $?; }

echo "== landed_kind / landed_applies: dispatches over the declared landed-kind dossier value =="
eq "kind: self-pull repo"                 "self-pull"     "$(landed_kind "$SELF_REPO")"
eq "kind: context-cache repo"             "context-cache" "$(landed_kind "$CACHE_REPO")"
eq "kind: undeclared repo echoes nothing" ""               "$(landed_kind "$PLAIN_REPO")"
ok "applies: self-pull repo"              landed_applies "$SELF_REPO"
ok "applies: context-cache repo"          landed_applies "$CACHE_REPO"
no "applies: undeclared repo"             landed_applies "$PLAIN_REPO"

echo "== landed_kind: the ADOPTED path -- an AGENTS.md '## Metadata' landed-kind row =="
# The path this genericization exists to establish (and the one distillery#7
# adds). The fixture's legacy agent.json says `self-pull`; the Metadata block
# says `context-cache`. Reading back `context-cache` is what proves the
# Metadata row answered, rather than the block being ignored and the legacy
# fallback quietly carrying the test.
eq "kind: adopted repo reads landed-kind out of the Metadata block, not the legacy agent.json" \
  "context-cache" "$(landed_kind "$DOSSIER_REPO")"
ok "applies: adopted repo"  landed_applies "$DOSSIER_REPO"
landed_record "$DOSSIER_REPO" 7 dsha7
eq "record: the adopted repo's kind is resolved and persisted" \
  "context-cache" "$(jq -r '.kind' <<<"$(landed_pending_entry "$DOSSIER_REPO")")"
export CONTEXT_CACHE_DIR="$TMP/adopted-cache"
mkdir -p "$CONTEXT_CACHE_DIR/current"; printf 'dsha7' > "$CONTEXT_CACHE_DIR/current/HEAD"
do_landed_tick
eq "do_landed_tick dispatches the adopted repo's kind and confirms the landing" \
  "{}" "$(landed_pending_entry "$DOSSIER_REPO")"
has "the adopted repo's note names its kind's check" \
  "$(jq -r '.landed_notes[0].detail' "$STATE")" "context-cache"
unset CONTEXT_CACHE_DIR
echo '{}' > "$STATE"

echo "== landed_kind: an unreadable dossier is rc2 (unknown), NOT rc1 (absent) =="
eq "kind: undeclared repo is rc1 -- a real answer" "1" "$(rc landed_kind "$PLAIN_REPO")"
eq "kind: unrecognized value is rc1 -- also a real answer" "1" "$(rc landed_kind "$WEIRD_REPO")"
eq "kind: unreadable dossier is rc2"               "2" "$(rc landed_kind "$BLIP_REPO")"
eq "kind: unreadable dossier echoes nothing"       ""  "$(landed_kind "$BLIP_REPO" 2>/dev/null)"
ok "applies: unreadable dossier still stamps a watch (resolved later, never dropped)" \
  landed_applies "$BLIP_REPO"

echo "== landed_kind: unrecognized value is fail-fast (logs loudly), undeclared is quiet =="
no "kind: unrecognized value fails"          landed_kind "$WEIRD_REPO"
eq "kind: unrecognized value echoes nothing" "" "$(landed_kind "$WEIRD_REPO" 2>/dev/null)"
LOUD=$(landed_kind "$WEIRD_REPO" 2>&1 1>/dev/null)
has "kind: unrecognized value logs loudly, names the repo and the bad value" \
  "$LOUD" "$WEIRD_REPO declares unrecognized landed-kind 'quantum-tunnel'"
# landed_applies is the wrapper the production dispatch path actually calls,
# and it discards landed_kind's stdout. It must NOT discard its stderr too, or
# the loud line dies before the journal ever sees it. (Asserted end to end
# through do_automerge_tick in the wiring section at the bottom of this file --
# this is the unit-level half.)
APPLIES_LOUD=$(landed_applies "$WEIRD_REPO" 2>&1 1>/dev/null)
has "applies: the unrecognized-kind line SURVIVES the wrapper's redirection" \
  "$APPLIES_LOUD" "declares unrecognized landed-kind 'quantum-tunnel'"
QUIET=$(landed_kind "$PLAIN_REPO" 2>&1 1>/dev/null)
eq "kind: undeclared repo logs nothing -- quiet, same as any other unwatched repo" "" "$QUIET"
APPLIES_QUIET=$(landed_applies "$PLAIN_REPO" 2>&1 1>/dev/null)
eq "applies: an undeclared repo stays silent through the wrapper too (no per-tick noise)" \
  "" "$APPLIES_QUIET"

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
eq "pending_entry: kind resolved and persisted AT RECORD TIME (no per-tick re-query)" \
  "self-pull" "$(jq -r '.kind' <<<"$(landed_pending_entry "$SELF_REPO")")"
landed_record "$BLIP_REPO" 9 sha9
eq "pending_entry: an unreadable dossier stamps an EMPTY kind, resolved later" \
  "" "$(jq -r '.kind' <<<"$(landed_pending_entry "$BLIP_REPO")")"
landed_clear "$BLIP_REPO"
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
# matters: landed_pending_repos yields jq `keys` (sorted), so ZZ_CACHE_REPO is
# named to sort AFTER the self-pull repo's, putting the landing first.
export CONTEXT_CACHE_DIR="$TMP/unseeded-cache"
echo '{}' > "$STATE"
landed_record "$SELF_REPO"      521 "$SHA2"
landed_record "$ZZ_CACHE_REPO"  4   "distsha-never-served"
do_landed_tick
eq "the landed repo cleared"        "{}" "$(landed_pending_entry "$SELF_REPO")"
eq "the other repo stays pending"   "1"  "$(jq -r '.attempts' <<<"$(landed_pending_entry "$ZZ_CACHE_REPO")")"
eq "exactly one note queued"        "1"  "$(jq -r '.landed_notes | length' "$STATE")"
eq "the note is the repo that DID land" "$SELF_REPO" "$(jq -r '.landed_notes[0].repo' "$STATE")"
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

echo "== do_landed_tick: an UNREADABLE dossier keeps the watch pending (it is not 'undeclared') =="
# The regression the #542 review caught: a Forgejo blip must not read as "no
# longer a watched repo" and abandon the watch silently. Entry carries no
# kind, so the tick has to go ask -- and gets rc2, not rc1.
echo '{}' > "$STATE"
jq -n --arg r "$BLIP_REPO" '{landed: {($r): {pr:"7", sha:"blipsha", kind:"", attempts:0}}}' > "$STATE"
BLIP_LOG=$(do_landed_tick 2>&1 1>/dev/null)
eq "entry SURVIVES the failed read"     "$BLIP_REPO" "$(landed_pending_repos)"
eq "attempt counted, so it still expires out of the grace window eventually" \
  "1" "$(jq -r '.attempts' <<<"$(landed_pending_entry "$BLIP_REPO")")"
eq "no bogus kind persisted"            "" "$(jq -r '.kind' <<<"$(landed_pending_entry "$BLIP_REPO")")"
has "the skipped check is logged, not silent" "$BLIP_LOG" "landed-kind unreadable this tick"

echo "== do_landed_tick: an entry with no kind (stamped before this was persisted) resolves it once =="
export AGENT_HOME="$FIXTURE"
echo '{}' > "$STATE"
jq -n --arg r "$SELF_REPO" --arg s "$SHA2" '{landed: {($r): {pr:"9", sha:$s, attempts:0}}}' > "$STATE"
do_landed_tick
eq "the kind-less entry was resolved and confirmed" "{}" "$(landed_pending_entry "$SELF_REPO")"
eq "its landing queued a note" "$SELF_REPO" "$(jq -r '.landed_notes[0].repo' "$STATE")"
echo '{}' > "$STATE"
jq -n --arg r "$SELF_REPO" '{landed: {($r): {pr:"9", sha:"deadbeef", attempts:0}}}' > "$STATE"
do_landed_tick
eq "a still-pending kind-less entry has its kind persisted for later ticks" \
  "self-pull" "$(jq -r '.kind' <<<"$(landed_pending_entry "$SELF_REPO")")"
unset AGENT_HOME

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
PLAIN_MERGE_LOG=$(do_automerge_tick 2>&1 1>/dev/null)
case "$PLAIN_MERGE_LOG" in
  *"landed-kind"*) printf '  x undeclared repo merge stays quiet about landed-kind\n'; FAIL=$((FAIL + 1)) ;;
  *) pass "undeclared repo merge stays quiet about landed-kind (no per-merge noise)" ;;
esac

echo "== do_automerge_tick wiring: an unrecognized landed-kind reaches the OPERATOR on the merge path =="
# The production dispatch path is do_automerge_tick -> landed_applies. Asserting
# the loud line only against a direct landed_kind call proves nothing about the
# path that runs: landed_applies discards stdout, and if it discarded stderr the
# operator would get no watch AND no notice -- a silent default inside the module
# whose entire job (igor#512) is catching silent failures.
echo '{}' > "$STATE"
export VALIDATED_REPOS_JSON="{\"full_name\":\"${WEIRD_REPO}\"}"
WEIRD_MERGE_LOG=$(do_automerge_tick 2>&1 1>/dev/null)
has "the merge logs the unrecognized kind, naming the repo and the bad value" \
  "$WEIRD_MERGE_LOG" "$WEIRD_REPO declares unrecognized landed-kind 'quantum-tunnel'"
eq "no .landed entry created (unrecognized -- loud, but still no watch)" \
  "" "$(jq -r '.landed // {} | keys | join(",")' "$STATE")"

echo "== do_automerge_tick wiring: an ADOPTED-dossier repo's merge stamps a watch carrying its kind =="
echo '{}' > "$STATE"
export VALIDATED_REPOS_JSON="{\"full_name\":\"${DOSSIER_REPO}\"}"
ok "do_automerge_tick merges the url-less adopted repo" do_automerge_tick
eq ".landed stamped for the adopted repo" \
  "mergedsha521" "$(jq -r --arg r "$DOSSIER_REPO" '.landed[$r].sha // ""' "$STATE")"
eq "the stamped kind came from the AGENTS.md Metadata block" \
  "context-cache" "$(jq -r --arg r "$DOSSIER_REPO" '.landed[$r].kind // ""' "$STATE")"

echo "== do_automerge_tick wiring: a url-less merge whose dossier read FAILS still stamps a watch =="
# Merge-time half of the same regression: an unreadable dossier must not merge
# with no watch at all. Stamp it kind-less; do_landed_tick resolves it.
echo '{}' > "$STATE"
export VALIDATED_REPOS_JSON="{\"full_name\":\"${BLIP_REPO}\"}"
ok "do_automerge_tick merges the url-less repo with the unreadable dossier" do_automerge_tick
eq ".landed stamped despite the failed read" "mergedsha521" "$(jq -r --arg r "$BLIP_REPO" '.landed[$r].sha // ""' "$STATE")"
eq "stamped kind is empty, for a later tick to resolve" "" "$(jq -r --arg r "$BLIP_REPO" '.landed[$r].kind' "$STATE")"

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
