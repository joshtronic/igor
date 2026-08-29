#!/usr/bin/env bash
# test-automerge.sh -- unit tests for lib/automerge.sh: the agent.json opt-in, the
# approval/CI/mergeable gates, the live-URL smoke, the deploy-barrier state
# machine (the riskiest logic), and do_automerge_tick's merge decision. Skip-safe:
# needs jq; exits 0 with a notice if absent, like the other bin/test-*.sh. Every
# boundary (_fj, curl, forgejo_*, email) is stubbed -- no network, no real state.
set -uo pipefail

command -v jq  >/dev/null 2>&1 || { echo "test-automerge: jq absent -- skipping"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "test-automerge: git absent -- skipping"; exit 0; }

HERE="$(cd "$(dirname "$0")" && pwd)"
# AUTOMERGE_SELF_REPO is REQUIRED-AND-EXPLICIT, no default (igor#558) --
# lib/automerge.sh fails fast at source time without it. Set it here the
# same way the production .env would, so the rest of this suite's fixtures
# (which assume "joshtronic/igor" is the self-repo) are unaffected.
export AUTOMERGE_SELF_REPO="joshtronic/igor"
# shellcheck source=../lib/dossier.sh
. "$HERE/../lib/dossier.sh"
# shellcheck source=../lib/automerge.sh
. "$HERE/../lib/automerge.sh"

# Sections below stub automerge_url_status wholesale. Keep a copy of the real
# one under another name so the self-repo carve-out can be exercised for real,
# rather than simulated by a stub returning what it is supposed to return.
eval "$(declare -f automerge_url_status | sed '1s/^automerge_url_status/_real_url_status/')"
# Same deal for automerge_reviewer_blocks: the review-gate section below
# permanently stubs it to `return 1` (never resetting it to the real
# definition), so the maintenance-tier tests -- which need the REAL function
# reading a live human REQUEST_CHANGES off _fj -- restore it from this copy.
eval "$(declare -f automerge_reviewer_blocks | sed '1s/^automerge_reviewer_blocks/_real_reviewer_blocks/')"
# Same deal for _automerge_maintenance_path_allowed: the igor#558 negative
# test below severs it temporarily to prove the guard-rejection belt is what
# refuses a net-gain diff, then restores it from this copy.
eval "$(declare -f _automerge_maintenance_path_allowed | sed '1s/^_automerge_maintenance_path_allowed/_real_maintenance_path_allowed/')"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export AGENT_STATE_DIR="$TMP"
STATE="$TMP/discretionary-state.json"

FAIL=0
ok() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then printf '  + %s\n' "$d"; else printf '  x %s (expected rc0)\n' "$d"; FAIL=$((FAIL + 1)); fi; }
no() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then printf '  x %s (expected rc!=0)\n' "$d"; FAIL=$((FAIL + 1)); else printf '  + %s\n' "$d"; fi; }
eq() { if [ "$2" = "$3" ]; then printf '  + %s\n' "$1"; else printf '  x %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi; }
has() { case "$2" in *"$3"*) printf '  + %s\n' "$1" ;; *) printf '  x %s: [%s] lacks [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)) ;; esac; }

echo "== AUTOMERGE_SELF_REPO: required-and-explicit, no default (igor#558) =="
# A clean shell sourcing lib/automerge.sh without AUTOMERGE_SELF_REPO set must
# fail fast and loudly -- the whole point of dropping the hardcoded
# joshtronic/igor default. Runs in an isolated subshell (env -i) so it can't
# inherit this suite's own export above.
SELFREPO_OUT=$(env -i HOME="$HOME" PATH="$PATH" bash -c '
  set -uo pipefail
  . "'"$HERE"'/../lib/dossier.sh"
  . "'"$HERE"'/../lib/automerge.sh"
' 2>&1); SELFREPO_RC=$?
if [ "$SELFREPO_RC" -ne 0 ]; then printf '  + %s\n' "self-repo: unset AUTOMERGE_SELF_REPO fails fast sourcing automerge.sh"
else printf '  x %s\n' "self-repo: unset AUTOMERGE_SELF_REPO fails fast sourcing automerge.sh"; FAIL=$((FAIL + 1)); fi
has "self-repo: failure names the var" "$SELFREPO_OUT" "AUTOMERGE_SELF_REPO"

echo "== agent.json (.smoke.url) opt-in (legacy fallback -- no repo has adopted the dossier yet) =="
forgejo_repo_get_file_status() { printf 'found\t%s' '{"smoke":{"url":"https://porksicle.com"}}'; }
eq "url_status: extracts .smoke.url"       "$(printf 'ok\thttps://porksicle.com')" "$(automerge_url_status acme/site)"
eq "url_status: self repo always ok, url-less" "$(printf 'ok\t')" "$(automerge_url_status "$AUTOMERGE_SELF_REPO")"
forgejo_repo_get_file_status() { printf 'found\t%s' '{"feedback":{"csv":"x"}}'; }
eq "url_status: agent.json without .smoke -> ok, empty url" "$(printf 'ok\t')" "$(automerge_url_status acme/site)"
forgejo_repo_get_file_status() { printf 'missing\t'; }
eq "url_status: no agent.json -> ok, empty url (genuinely url-less)" "$(printf 'ok\t')" "$(automerge_url_status acme/site)"
forgejo_repo_get_file_status() { printf 'error\t'; }
eq "url_status: dossier fetch failure -> error, not 'no url'" "$(printf 'error\t')" "$(automerge_url_status acme/site)"

echo "== automerge_url_status is dossier_get_repo_status (igor#473/#520): adopted AGENTS.md vs legacy fallback =="
# A repo that HAS adopted the spec: root AGENTS.md carries the fence, no
# agent.json involved at all.
DOSSIER=$'# dossier.example\n\n## Metadata\n\n```yaml\ntype: tool\nurl: https://dossier.example\n```\n'
forgejo_repo_get_file_status() {
  case "$2" in
    AGENTS.md) printf 'found\t%s' "$DOSSIER" ;;
    *) printf 'missing\t' ;;
  esac
}
eq "url_status: adopted dossier -> reads root AGENTS.md Metadata" \
  "$(printf 'ok\thttps://dossier.example')" "$(automerge_url_status acme/site)"

# A repo that has NOT adopted the spec (the whole fleet today): no root
# AGENTS.md dossier, so it falls back to legacy agent.json -- same value as
# the pre-#473 direct read, i.e. fleet behavior is unchanged.
forgejo_repo_get_file_status() {
  case "$2" in
    agent.json) printf 'found\t%s' '{"smoke":{"url":"https://porksicle.com"}}' ;;
    *) printf 'missing\t' ;;
  esac
}
eq "url_status: un-adopted repo -> falls back to legacy agent.json (fleet-neutral)" \
  "$(printf 'ok\thttps://porksicle.com')" "$(automerge_url_status acme/site)"

# An adopted dossier is AUTHORITATIVE: it does not fall back to agent.json for
# a key it omits (the inherited dossier_get contract). A repo that adopts the
# fence and forgets `url` is intentionally url-less, not silently legacy.
forgejo_repo_get_file_status() {
  case "$2" in
    AGENTS.md)  printf 'found\t%s' $'# x\n\n## Metadata\n\n```yaml\ntype: tool\n```\n' ;;
    agent.json) printf 'found\t%s' '{"smoke":{"url":"https://legacy.example"}}' ;;
  esac
}
eq "url_status: adopted dossier missing url -> ok+empty, NOT the agent.json value" \
  "$(printf 'ok\t')" "$(automerge_url_status acme/site)"

# ...and it costs one API call, not two: agent.json is never fetched when the
# dossier answers.
# (the tally goes through a file: dossier_get_repo_status's fetches run in
# command substitutions, so a shell var set in the stub would not survive)
FETCHED="$TMP/fetched"; : >"$FETCHED"
forgejo_repo_get_file_status() {
  echo "$2" >>"$FETCHED"
  case "$2" in AGENTS.md) printf 'found\t%s' "$DOSSIER" ;; *) printf 'missing\t' ;; esac
}
automerge_url_status acme/site >/dev/null
eq "url_status: adopted dossier short-circuits the legacy fetch" "AGENTS.md" "$(cat "$FETCHED")"

# A repo genuinely declaring nothing (both fetches answer "missing", i.e. a
# real 404) is a clean "ok, url-less" -- distinct from a fetch that errored.
forgejo_repo_get_file_status() { printf 'missing\t'; }
eq "url_status: neither file exists -> ok, url-less (not an error)" \
  "$(printf 'ok\t')" "$(automerge_url_status acme/site)"

# A transport failure on EITHER leg must propagate as error, never be read as
# "declares no url" -- the exact conflation igor#520's amendment called out.
forgejo_repo_get_file_status() {
  case "$2" in
    AGENTS.md) printf 'error\t' ;;
    *) printf 'found\t%s' '{"smoke":{"url":"https://x"}}' ;;
  esac
}
eq "url_status: AGENTS.md fetch errors -> error (never falls back to agent.json)" \
  "$(printf 'error\t')" "$(automerge_url_status acme/site)"
forgejo_repo_get_file_status() {
  case "$2" in
    AGENTS.md) printf 'missing\t' ;;
    agent.json) printf 'error\t' ;;
  esac
}
eq "url_status: agent.json fetch errors after a missing AGENTS.md -> error" \
  "$(printf 'error\t')" "$(automerge_url_status acme/site)"

echo "== dossier.sh wiring (igor#473): the dependency must be sourced, and loud when it isn't =="
# The runtime caller graph is bin/tick.sh -> lib/automerge.sh. This test file
# sources lib/dossier.sh itself, so it would pass even if production never did
# -- assert the production wiring directly instead.
ok "tick.sh sources lib/dossier.sh" grep -q 'lib/dossier\.sh"$' "$HERE/tick.sh"
# And if it ever stops: an undefined dossier_get_repo_status must LOG and fail
# CLOSED (error, not "ok" with an empty url) -- reading it as "every repo is
# url-less" would flip every url-bearing repo onto the un-watched merge path,
# silently disabling the deploy barrier fleet-wide instead of just refusing.
BARE=$(bash -c '. "$1/../lib/automerge.sh"; automerge_url_status acme/site' _ "$HERE" 2>&1)
has "url_status: missing lib/dossier.sh logs instead of failing silently" "$BARE" "lib/dossier.sh not sourced"
eq "url_status: missing lib/dossier.sh fails CLOSED (error)" "error" \
  "$(bash -c '. "$1/../lib/automerge.sh"; automerge_url_status acme/site' _ "$HERE" 2>/dev/null | cut -f1)"

echo "== end-to-end: automerge_url_status -> dossier -> forgejo, curl the only stub =="
# Everything above stubs one of the three layers, so the real chain
# (automerge_url_status -> dossier_get_repo_status -> forgejo_repo_get_file_status
# -> curl) is never run whole. It is what production runs, and the HTTP-status
# discrimination it rests on lives at the bottom layer -- so exercise it here in
# a fresh shell sourcing the libs in tick.sh's order, with only curl replaced.
E2E_SCRIPT=$(cat <<'EOS'
set -uo pipefail
HERE="$1"; MODE="$2"
export FORGEJO_URL="https://example.invalid" FORGEJO_TOKEN="test-token"
. "$HERE/../lib/forgejo.sh"
. "$HERE/../lib/dossier.sh"
. "$HERE/../lib/automerge.sh"
B64=$(printf '%s' '{"smoke":{"url":"https://e2e.example"}}' | base64 | tr -d '\n')
curl() {
  local url="${*: -1}"
  case "$MODE:$url" in
    legacy:*/contents/AGENTS.md)  printf '{"errors":["object does not exist"]}\n404' ;;
    legacy:*/contents/agent.json) printf '{"content":"%s"}\n200' "$B64" ;;
    forbidden:*)                  printf '{"message":"token does not have at least one of required scope(s)"}\n403' ;;
    bare:*)                       printf '{"errors":["object does not exist"]}\n404' ;;
    # Answers with a real url. Garbage would ALSO produce "ok\t" -- via jq
    # failing to parse it -- so the assertion below would survive deleting the
    # short-circuit. This way the un-short-circuited chain resolves a url and
    # the expected "ok\t" only holds if the carve-out fired first.
    self:*)                       printf '{"content":"%s"}\n200' "$B64" ;;
  esac
}
case "$MODE" in
  self) automerge_url_status "$AUTOMERGE_SELF_REPO" ;;
  *)    automerge_url_status acme/site ;;
esac
EOS
)
e2e() { bash -c "$E2E_SCRIPT" _ "$HERE" "$1" 2>/dev/null; }
eq "e2e: a 404 on AGENTS.md still resolves the legacy agent.json url" \
  "$(printf 'ok\thttps://e2e.example')" "$(e2e legacy)"
eq "e2e: a 403 on AGENTS.md is an error, NOT a url-less repo" \
  "$(printf 'error\t')" "$(e2e forbidden)"
eq "e2e: 404 on both files -> ok, genuinely url-less" \
  "$(printf 'ok\t')" "$(e2e bare)"
eq "e2e: the self repo short-circuits before any fetch" \
  "$(printf 'ok\t')" "$(e2e self)"

echo "== approval / mergeable gates =="
_fj() { printf '%s' "$FJ"; }
FJ='[{"user":{"login":"josh"},"state":"APPROVED"}]'
ok "approved_by: josh APPROVED"            automerge_approved_by acme/x 1 josh
FJ='[{"user":{"login":"josh"},"state":"COMMENT"}]'
no "approved_by: only a COMMENT"           automerge_approved_by acme/x 1 josh
FJ='[{"user":{"login":"bot"},"state":"APPROVED"}]'
no "approved_by: someone else approved"    automerge_approved_by acme/x 1 josh
# latest-review-wins: an APPROVED later walked back to REQUEST_CHANGES is NOT approval.
FJ='[{"user":{"login":"josh"},"state":"APPROVED","submitted_at":"2026-01-01T00:00:00Z"},{"user":{"login":"josh"},"state":"REQUEST_CHANGES","submitted_at":"2026-02-01T00:00:00Z"}]'
no "approved_by: APPROVED then later RC -> walked back" automerge_approved_by acme/x 1 josh
FJ='[{"user":{"login":"josh"},"state":"REQUEST_CHANGES","submitted_at":"2026-01-01T00:00:00Z"},{"user":{"login":"josh"},"state":"APPROVED","submitted_at":"2026-02-01T00:00:00Z"}]'
ok "approved_by: RC then later APPROVED -> approved"   automerge_approved_by acme/x 1 josh
# a later COMMENT review does not withdraw a standing APPROVED.
FJ='[{"user":{"login":"josh"},"state":"APPROVED","submitted_at":"2026-01-01T00:00:00Z"},{"user":{"login":"josh"},"state":"COMMENT","submitted_at":"2026-02-01T00:00:00Z"}]'
ok "approved_by: later COMMENT keeps APPROVED"         automerge_approved_by acme/x 1 josh
# a dismissed RC drops out; the prior APPROVED still stands.
FJ='[{"user":{"login":"josh"},"state":"APPROVED","submitted_at":"2026-01-01T00:00:00Z"},{"user":{"login":"josh"},"state":"REQUEST_CHANGES","submitted_at":"2026-02-01T00:00:00Z","dismissed":true}]'
ok "approved_by: dismissed RC -> prior APPROVED stands" automerge_approved_by acme/x 1 josh
# a stale APPROVED (head moved past what was reviewed) is not a merge signal.
# A stale-but-NOT-dismissed APPROVED still counts: Forgejo's `dismissed` flag, not
# `stale`, is the authoritative "no longer counts." A repo that doesn't dismiss
# stale approvals keeps them -- so this un-strands a base-merge-staled approval.
FJ='[{"user":{"login":"josh"},"state":"APPROVED","submitted_at":"2026-01-01T00:00:00Z","stale":true,"dismissed":false,"official":true}]'
ok "approved_by: stale but NOT dismissed APPROVED -> still counts"  automerge_approved_by acme/x 1 josh
# A DISMISSED APPROVED does not count (the repo dismissed it on a new commit).
FJ='[{"user":{"login":"josh"},"state":"APPROVED","submitted_at":"2026-01-01T00:00:00Z","stale":true,"dismissed":true}]'
no "approved_by: dismissed APPROVED -> does not count"  automerge_approved_by acme/x 1 josh
FJ='{"state":"open","mergeable":true}'
ok "mergeable: open + mergeable"           automerge_mergeable acme/x 1
FJ='{"state":"open","mergeable":false}'
no "mergeable: conflict"                   automerge_mergeable acme/x 1
FJ='{"state":"closed","mergeable":true}'
no "mergeable: closed"                     automerge_mergeable acme/x 1

echo "== automerge_require_human (review-gate flag) =="
forgejo_repo_get_file() { printf '%s' '{"automerge":{"require_human":true}}'; }
ok "require_human: flagged true -> human gate"        automerge_require_human acme/site
forgejo_repo_get_file() { printf '%s' '{"automerge":{"require_human":false}}'; }
no "require_human: explicit false -> shadow gate"     automerge_require_human acme/site
forgejo_repo_get_file() { printf '%s' '{"smoke":{"url":"x"}}'; }
no "require_human: no automerge key -> shadow gate"   automerge_require_human acme/site
forgejo_repo_get_file() { return 1; }
no "require_human: no agent.json -> shadow gate"      automerge_require_human acme/site

echo "== automerge_will_take (do_review_tick suppresses the human request) =="
automerge_url_status() { printf 'ok\thttps://x'; }   # url-bearing repo throughout this section
forgejo_repo_get_file() { printf '%s' '{"automerge":{"require_human":false}}'; }   # default (shadow-gated) repo
ok "will_take: default repo + APPROVE -> auto-merge takes it"     automerge_will_take acme/site APPROVE
no "will_take: default repo + COMMENT -> human still asked"       automerge_will_take acme/site COMMENT
no "will_take: default repo + REQUEST_CHANGES -> not a take"      automerge_will_take acme/site REQUEST_CHANGES
forgejo_repo_get_file() { printf '%s' '{"automerge":{"require_human":true}}'; }   # carve-out, still url-bearing
no "will_take: carve-out + APPROVE -> human is the gate"          automerge_will_take acme/site APPROVE
forgejo_repo_get_file() { printf '%s' '{"automerge":{"require_human":false}}'; }   # reset
automerge_url_status() { printf 'ok\t'; }   # url-LESS repo -- igor#520: never a shadow-alone take
no "will_take: url-less repo + APPROVE -> never a shadow take"    automerge_will_take acme/site APPROVE
automerge_url_status() { printf 'error\t'; }   # dossier fetch failed this tick -- unknown, not a take
no "will_take: dossier fetch error + APPROVE -> not a take"       automerge_will_take acme/site APPROVE
automerge_url_status() { printf 'ok\thttps://x'; }   # reset

echo "== automerge_reviewer_blocks (human veto on a shadow-gated repo) =="
_fj() { printf '%s' "$FJ"; }
FJ='[{"user":{"login":"josh"},"state":"REQUEST_CHANGES","submitted_at":"2026-02-01T00:00:00Z"}]'
ok "reviewer_blocks: live RC -> blocks"                  automerge_reviewer_blocks acme/x 1 josh
FJ='[{"user":{"login":"josh"},"state":"REQUEST_CHANGES","submitted_at":"2026-01-01T00:00:00Z"},{"user":{"login":"josh"},"state":"APPROVED","submitted_at":"2026-02-01T00:00:00Z"}]'
no "reviewer_blocks: RC then later APPROVED -> no block" automerge_reviewer_blocks acme/x 1 josh
FJ='[{"user":{"login":"josh"},"state":"APPROVED","submitted_at":"2026-02-01T00:00:00Z"}]'
no "reviewer_blocks: only APPROVED -> no block"          automerge_reviewer_blocks acme/x 1 josh
FJ='[{"user":{"login":"josh"},"state":"REQUEST_CHANGES","submitted_at":"2026-02-01T00:00:00Z","stale":true}]'
no "reviewer_blocks: stale RC -> no block"               automerge_reviewer_blocks acme/x 1 josh
FJ='[{"user":{"login":"other"},"state":"REQUEST_CHANGES","submitted_at":"2026-02-01T00:00:00Z"}]'
no "reviewer_blocks: someone else RC -> no block"        automerge_reviewer_blocks acme/x 1 josh

echo "== automerge_approval_covers_head (a stale approval must still be the approved net diff) =="
# _fj dispatches by path: reviews, the PR object (.base.ref), the base branch tip,
# the head/parent commits (COMMITS: sha -> {parents}), and the base-membership
# check (COMPARE: sha -> commits ahead of base tip; 0 = on the base branch). Order
# matters -- */reviews before */pulls/* so the reviews path wins.
_fj() {
  case "$2" in
    */reviews)       printf '%s' "$REVIEWS" ;;
    */branches/*)    printf '%s' '{"commit":{"id":"basetip"}}' ;;
    */compare/*)     printf '%s' "$(jq -rn --arg k "${2##*...}" --argjson m "$COMPARE" '{total_commits: ($m[$k] // -1)}')" ;;
    */git/commits/*) printf '%s' "$(jq -rn --arg k "${2##*/}" --argjson m "$COMMITS" '$m[$k] // {"parents":[]}')" ;;
    */pulls/*)       printf '%s' '{"base":{"ref":"master"}}' ;;
  esac
}
# base1/base2 sit on the base branch (0 ahead of the tip); evil1 carries 3 unreviewed commits.
COMPARE='{"base1":0,"base2":0,"evil1":3}'
COMMITS='{
  "m2":{"parents":[{"sha":"m1"},{"sha":"base2"}]},
  "m1":{"parents":[{"sha":"aaa"},{"sha":"base1"}]},
  "bbb":{"parents":[{"sha":"aaa"}]},
  "evilm":{"parents":[{"sha":"aaa"},{"sha":"evil1"}]}
}'
# josh approved commit aaa; the approval is now stale (head moved) but not dismissed.
REVIEWS='[{"user":{"login":"josh"},"state":"APPROVED","commit_id":"aaa","stale":true,"dismissed":false,"submitted_at":"2026-01-01T00:00:00Z"}]'
ok "covers_head: head IS the approved commit (live) -> covers"        automerge_approval_covers_head acme/x 1 josh aaa
ok "covers_head: single base-merge of the approved commit -> covers"  automerge_approval_covers_head acme/x 1 josh m1
# The multi-level case the #409 direct-parent helper broke on: aaa is 2 base-merges back.
ok "covers_head: MULTI-LEVEL base-merge chain -> covers"              automerge_approval_covers_head acme/x 1 josh m2
# A merge with a NON-base (hostile) parent adds unreviewed content -> must NOT cover.
no "covers_head: merge with an off-base parent -> not covered"        automerge_approval_covers_head acme/x 1 josh evilm
# A real new single-parent commit pushed after approval -> not covered (the reviewer's scenario).
no "covers_head: real new commit after approval -> not covered"       automerge_approval_covers_head acme/x 1 josh bbb
# No commit_id on the approval -> fail closed (can't prove same net diff).
REVIEWS='[{"user":{"login":"josh"},"state":"APPROVED","stale":true,"submitted_at":"2026-01-01T00:00:00Z"}]'
no "covers_head: approval without commit_id -> fail closed"          automerge_approval_covers_head acme/x 1 josh m1
# Latest counting review is a REQUEST_CHANGES (not APPROVED) -> not covered.
REVIEWS='[{"user":{"login":"josh"},"state":"REQUEST_CHANGES","commit_id":"aaa","submitted_at":"2026-01-01T00:00:00Z"}]'
no "covers_head: latest review is RC -> not covered"                 automerge_approval_covers_head acme/x 1 josh aaa

echo "== live-URL smoke (real fn, stubbed curl) =="
curl() { echo "$SMOKE_CODE"; }
SMOKE_CODE=200; ok "smoke: 200 -> up"          automerge_smoke https://x
SMOKE_CODE=301; ok "smoke: 301 -> up"          automerge_smoke https://x
SMOKE_CODE=503; no "smoke: 503 -> down"        automerge_smoke https://x
SMOKE_CODE=000; no "smoke: unreachable -> down" automerge_smoke https://x

echo "== deploy barrier state machine =="
ALERTS=0
export SMTP2GO_API_KEY=k SMTP2GO_SENDER=s
recipients_with_primary() { printf 'josh@x'; }
email_send() { ALERTS=$((ALERTS + 1)); return 0; }
COMMENTS=0; COMMENT_BODY=""
forgejo_comment() { COMMENTS=$((COMMENTS + 1)); COMMENT_BODY="$3"; return 0; }
seed() { jq -n --arg r "$1" --argjson a "${2:-0}" --argjson c "${3:-0}" \
  '{deploy:{repo:$r,pr:"1",sha:"sha1",url:"https://x",smoke_attempts:$a,ci_attempts:$c}}' > "$STATE"; }

forgejo_commit_status() { echo pending; }
seed acme/x
ok "barrier: CI pending -> ends tick (rc0)"          do_deploy_barrier
eq "barrier: pending keeps .deploy"        "acme/x"  "$(jq -r '.deploy.repo // ""' "$STATE")"
eq "barrier: pending bumps ci_attempts"    "1"       "$(jq -r '.deploy.ci_attempts' "$STATE")"

# CI that never reports success/failure must self-heal, not wedge forever.
seed acme/x 0 $((AUTOMERGE_CI_MAX_ATTEMPTS - 1)); ALERTS=0
no "barrier: CI pending exhausted -> falls through (rc1)" do_deploy_barrier
eq "barrier: CI-pending-exhausted alerted" "1"       "$ALERTS"
eq "barrier: CI-pending-exhausted cleared" ""        "$(jq -r '.deploy.repo // ""' "$STATE")"

forgejo_commit_status() { echo failure; }
seed acme/x; ALERTS=0; COMMENTS=0; COMMENT_BODY=""
no "barrier: CI failure -> falls through (rc1)"       do_deploy_barrier
eq "barrier: CI failure alerted"           "1"       "$ALERTS"
eq "barrier: CI failure posts a comment"   "1"       "$COMMENTS"
has "barrier: failure comment says so"     "$COMMENT_BODY" "did NOT verify"
eq "barrier: CI failure cleared .deploy"   ""        "$(jq -r '.deploy.repo // ""' "$STATE")"

forgejo_commit_status() { echo success; }
automerge_smoke() { return 0; }
seed acme/x; ALERTS=0; COMMENTS=0; COMMENT_BODY=""
no "barrier: CI green + smoke ok -> falls through"    do_deploy_barrier
eq "barrier: healthy cleared .deploy"      ""        "$(jq -r '.deploy.repo // ""' "$STATE")"
eq "barrier: healthy did not alert"        "0"       "$ALERTS"
eq "barrier: healthy posts a confirm comment" "1"    "$COMMENTS"
has "barrier: confirm comment says verified"  "$COMMENT_BODY" "verified"

automerge_smoke() { return 1; }
seed acme/x 0
ok "barrier: smoke not live yet -> ends tick (rc0)"   do_deploy_barrier
eq "barrier: bumped smoke_attempts"        "1"       "$(jq -r '.deploy.smoke_attempts' "$STATE")"

seed acme/x $((AUTOMERGE_SMOKE_MAX_ATTEMPTS - 1)); ALERTS=0
no "barrier: smoke exhausted -> falls through (rc1)"  do_deploy_barrier
eq "barrier: smoke-exhausted alerted"      "1"       "$ALERTS"
eq "barrier: smoke-exhausted cleared"      ""        "$(jq -r '.deploy.repo // ""' "$STATE")"

echo '{}' > "$STATE"
no "barrier: nothing pending -> falls through (rc1)"  do_deploy_barrier

echo "== automerge_live_sha (extract the deploy-sha meta) =="
curl() { printf '%s' "$LIVE_HTML"; }
LIVE_HTML='<html><head><meta name="deploy-sha" content="abc123def"><title>x</title></head></html>'
eq "live_sha: extracts the meta value" "abc123def" "$(automerge_live_sha https://x)"
LIVE_HTML='<html><head><title>no marker here</title></head></html>'
eq "live_sha: no meta -> empty"        "" "$(automerge_live_sha https://x)"

echo "== automerge_sitemap_failures (walk + flag non-2xx) =="
curl() {
  local u="${*: -1}"
  case "$u" in
    */sitemap.xml) printf '<urlset><url><loc>https://x/ok</loc></url><url><loc>https://x/bad</loc></url></urlset>' ;;
    */bad)         echo 500 ;;
    *)             echo 200 ;;
  esac
}
smf=$(automerge_sitemap_failures https://x)
has "sitemap: flags the failing page"      "$smf" "/bad"
has "sitemap: includes the status code"    "$smf" "500"
case "$smf" in *"/ok"*) printf '  x %s\n' "sitemap: wrongly flagged the 200 page"; FAIL=$((FAIL + 1)) ;; *) printf '  + %s\n' "sitemap: leaves the 200 page alone" ;; esac
curl() { return 1; }
eq "sitemap: no sitemap.xml -> empty (skip)" "" "$(automerge_sitemap_failures https://x)"

# issue #364 regression: a >500-url sitemap must cap at 500 WITHOUT the old
# `printf | head -500` broken-pipe spew. The call runs under `trap '' PIPE` to
# reproduce production: systemd sets IgnoreSIGPIPE=yes, so head's early close
# (after 500 of these >64KB-total padded urls) makes the still-writing printf's
# write() return EPIPE -> "printf: write error: Broken pipe" instead of a silent
# SIGPIPE. The array-slice fix never pipes into a truncating reader.
sm_pad="$(printf 'p%.0s' {1..160})"
curl() {
  local u="${*: -1}" i
  case "$u" in
    */sitemap.xml)
      # 1200 urls so the overflow past the first 500 (>64KB of padded urls) can't
      # fit the pipe buffer -- forcing the old printf to still be writing when
      # head closes. bad-within (#250) is checked; bad-beyond (#900) is past cap.
      printf '<urlset>'
      for i in $(seq 1 1200); do
        case "$i" in
          250) printf '<url><loc>https://x/ubad-within-%s</loc></url>' "$sm_pad" ;;
          900) printf '<url><loc>https://x/ubad-beyond-%s</loc></url>' "$sm_pad" ;;
          *)   printf '<url><loc>https://x/u%s-%s</loc></url>' "$i" "$sm_pad" ;;
        esac
      done
      printf '</urlset>' ;;
    */ubad-*) echo 500 ;;
    *)        echo 200 ;;
  esac
}
sm_err="$(mktemp)"
sm_big="$( ( trap '' PIPE; automerge_sitemap_failures https://x ) 2>"$sm_err" )"
has "sitemap: flags a bad url inside the first 500" "$sm_big" "ubad-within"
case "$sm_big" in
  *ubad-beyond*) printf '  x %s\n' "sitemap: did NOT cap at 500 (flagged url #550)"; FAIL=$((FAIL + 1)) ;;
  *)             printf '  + %s\n' "sitemap: caps the walk at 500 urls" ;;
esac
if grep -qi 'broken pipe' "$sm_err"; then
  printf '  x %s\n' "sitemap: SIGPIPE broken-pipe spew on a >500-url sitemap (#364)"; FAIL=$((FAIL + 1))
else
  printf '  + %s\n' "sitemap: no broken-pipe spew on a >500-url sitemap (#364)"
fi
rm -f "$sm_err"

echo "== deploy barrier: propagation gate =="
forgejo_commit_status() { echo success; }
automerge_sitemap_failures() { return 0; }     # sitemap clean unless a test says otherwise
seedsha() { jq -n --arg r "$1" --arg s "$2" --argjson a "${3:-0}" \
  '{deploy:{repo:$r,pr:"1",sha:$s,url:"https://x",smoke_attempts:$a,ci_attempts:0}}' > "$STATE"; }
automerge_live_sha() { echo "mergedsha"; }      # live build == merged commit
seedsha acme/x mergedsha; ALERTS=0; COMMENTS=0; COMMENT_BODY=""
no  "barrier: propagated (live==merged) -> verified (rc1)" do_deploy_barrier
eq  "barrier: propagated cleared .deploy"  ""       "$(jq -r '.deploy.repo // ""' "$STATE")"
eq  "barrier: propagated did not alert"    "0"      "$ALERTS"
has "barrier: confirm cites the merged commit" "$COMMENT_BODY" "merged commit"
automerge_live_sha() { echo "oldsha"; }         # old build still serving
seedsha acme/x mergedsha 0; ALERTS=0
ok  "barrier: stale build live -> grace (rc0)"  do_deploy_barrier
eq  "barrier: stale bumped attempts"       "1"      "$(jq -r '.deploy.smoke_attempts' "$STATE")"
eq  "barrier: stale did not alert yet"     "0"      "$ALERTS"
eq  "barrier: stale keeps .deploy"         "acme/x" "$(jq -r '.deploy.repo // ""' "$STATE")"
seedsha acme/x mergedsha $((AUTOMERGE_SMOKE_MAX_ATTEMPTS - 1)); ALERTS=0
no  "barrier: stale exhausted -> alert (rc1)"  do_deploy_barrier
eq  "barrier: stale-exhausted alerted"     "1"      "$ALERTS"

echo "== deploy barrier: sitemap gate =="
automerge_live_sha() { echo "mergedsha"; }          # propagation passes
automerge_sitemap_failures() { echo "https://x/dead (500)"; }
seedsha acme/x mergedsha; ALERTS=0
no  "barrier: sitemap page failed -> alert (rc1)"  do_deploy_barrier
eq  "barrier: sitemap-failure alerted"     "1"      "$ALERTS"
eq  "barrier: sitemap-failure cleared"     ""       "$(jq -r '.deploy.repo // ""' "$STATE")"
automerge_sitemap_failures() { return 0; }          # restore clean for any later use

echo "== _fj_merge: sends the merge payload, splits code/message =="
export FORGEJO_TOKEN=test-token FORGEJO_URL=http://localhost   # _fj_merge reads these (set -u)
# Test the REAL _fj_merge here, BEFORE the automerge_do_merge block below stubs
# it out. It runs curl inside $(...), a subshell -- capture the payload to a FILE
# (a var set in the subshell would be lost in the parent).
curl() { local b=""; while [ $# -gt 0 ]; do [ "$1" = "-d" ] && { b="$2"; shift; }; shift; done; printf '%s' "$b" > "$TMP/merge_payload"; printf 'ignored\n200'; }
: > "$TMP/merge_payload"; _fj_merge acme/x 5 >/dev/null; PAYLOAD=$(cat "$TMP/merge_payload")
has "_fj_merge: sends Do=merge"        "$PAYLOAD" '"Do":"merge"'
has "_fj_merge: sends delete_branch"   "$PAYLOAD" '"delete_branch_after_merge":true'
curl() { printf '{"message":"User not allowed to merge PR"}\n405'; }
eq  "_fj_merge: splits 405 + message"  "$(printf '405\tUser not allowed to merge PR')" "$(_fj_merge acme/x 5)"

echo "== automerge_do_merge: sha on success, reason on failure =="
_fj() { printf '%s' '{"merge_commit_sha":"deadbeef"}'; }   # the follow-up GET
_fj_merge() { printf '200\t'; }
eq  "do_merge: 2xx -> merge sha echoed"  "deadbeef" "$(automerge_do_merge acme/x 5)"
automerge_do_merge acme/x 5 >/dev/null; eq "do_merge: 2xx -> rc0" "0" "$?"
_fj_merge() { printf '405\tUser not allowed to merge PR'; }
eq  "do_merge: reject -> reason echoed" "$(printf 'HTTP 405: User not allowed to merge PR')" "$(automerge_do_merge acme/x 5)"
automerge_do_merge acme/x 5 >/dev/null; eq "do_merge: reject -> rc1" "1" "$?"

echo "== automerge_block: backoff on a rejected head =="
BSF="$TMP/block-state.json"; echo '{}' > "$BSF"
AUTOMERGE_BLOCK_COOLDOWN_SECS=3600
automerge_block_record "$BSF" "acme/x#5" "headA" "HTTP 405: nope"
ok "block: same head within cooldown -> active(skip)" automerge_block_active "$BSF" "acme/x#5" "headA"
no "block: different head -> retry"                   automerge_block_active "$BSF" "acme/x#5" "headB"
no "block: unknown key -> retry"                      automerge_block_active "$BSF" "other/y#1" "headA"
eq "block: reason recorded" "HTTP 405: nope" "$(jq -r '.automerge_block["acme/x#5"].reason' "$BSF")"
automerge_block_clear "$BSF" "acme/x#5"
no "block: after clear -> retry"                      automerge_block_active "$BSF" "acme/x#5" "headA"
# shellcheck disable=SC2034  # read by automerge_block_active (lib/automerge.sh)
AUTOMERGE_BLOCK_COOLDOWN_SECS=0
automerge_block_record "$BSF" "acme/x#5" "headA" "reason"
no "block: cooldown elapsed -> retry"                 automerge_block_active "$BSF" "acme/x#5" "headA"

echo "== automerge_behind_count (the require-up-to-date gate) =="
_fj() {
  case "$1 $2" in
    "GET "*/compare/*) printf '%s' '{"total_commits":4}' ;;
    *)                 printf '%s' '{"head":{"sha":"abc"},"base":{"ref":"master"}}' ;;
  esac
}
eq "behind_count: reads total_commits" "4" "$(automerge_behind_count acme/x 7)"
_fj() { case "$1 $2" in "GET "*/compare/*) printf '%s' '{"total_commits":0}' ;; *) printf '%s' '{"head":{"sha":"abc"},"base":{"ref":"master"}}' ;; esac; }
eq "behind_count: up-to-date -> 0" "0" "$(automerge_behind_count acme/x 7)"
_fj() { return 1; }
eq "behind_count: API error -> -1" "-1" "$(automerge_behind_count acme/x 7)"

echo "== automerge_update_branch (POSTs /pulls/N/update) =="
UP=""; _fj() { case "$1 $2" in "POST "*/update) UP="$2" ;; esac; return 0; }
automerge_update_branch acme/x 9 >/dev/null 2>&1
has "update_branch: POSTs to /pulls/N/update" "$UP" "/pulls/9/update"

echo "== automerge_risk_gate (size cap + deny-list, igor#514) =="
forgejo_pr_files() { printf '%s' "$FILES"; }
FILES='[{"filename":"foo.txt","additions":10,"deletions":5}]'
ok "risk_gate: small PR -> within bounds"          automerge_risk_gate acme/x 7
FILES=$(jq -n '[range(0;25) | {filename: ("f" + (. | tostring) + ".txt"), additions:1, deletions:0}]')
no "risk_gate: >20 files -> blocked"               automerge_risk_gate acme/x 7
has "risk_gate: reason mentions files="            "$(automerge_risk_gate acme/x 7 2>&1)" "files=25"
FILES='[{"filename":"big.txt","additions":300,"deletions":300}]'
no "risk_gate: >500 total lines -> blocked"        automerge_risk_gate acme/x 7
has "risk_gate: reason mentions lines="            "$(automerge_risk_gate acme/x 7 2>&1)" "lines=600"
FILES='[{"filename":"small.txt","additions":250,"deletions":250}]'
ok "risk_gate: exactly 500 lines -> within bounds" automerge_risk_gate acme/x 7
FILES='[{"filename":".forgejo/workflows/ci.yml","additions":1,"deletions":1}]'
no "risk_gate: deny-listed workflow path -> blocked" automerge_risk_gate acme/x 7
has "risk_gate: reason mentions the path"          "$(automerge_risk_gate acme/x 7 2>&1)" ".forgejo/workflows/ci.yml"
FILES='[{"filename":"agent.json","additions":1,"deletions":1}]'
no "risk_gate: agent.json -> blocked"              automerge_risk_gate acme/x 7
FILES='[{"filename":"AGENTS.md","additions":1,"deletions":1}]'
no "risk_gate: AGENTS.md -> blocked"               automerge_risk_gate acme/x 7
FILES='[{"filename":"install.sh","additions":1,"deletions":1}]'
no "risk_gate: install.sh -> blocked"              automerge_risk_gate acme/x 7
FILES='[{"filename":"scripts/deploy-prod.sh","additions":1,"deletions":1}]'
no "risk_gate: scripts/deploy* -> blocked"         automerge_risk_gate acme/x 7
FILES='[{"filename":"migrations/001_init.sql","additions":1,"deletions":1}]'
no "risk_gate: **/*.sql -> blocked"                automerge_risk_gate acme/x 7
FILES='[{"filename":"scripts/other.sh","additions":1,"deletions":1}]'
ok "risk_gate: scripts/ non-deploy file -> ok"     automerge_risk_gate acme/x 7
FILES=$(jq -n '[range(0;20) | {filename: ("f" + (. | tostring) + ".txt"), additions:1, deletions:0}]')
ok "risk_gate: exactly 20 files -> within bounds"  automerge_risk_gate acme/x 7
# A response shape WITHOUT per-file counts must refuse, not score lines=0 and
# pass -- defaulting a missing count to zero is the one way this gate could
# open rather than close.
FILES='[{"filename":"a.txt"},{"filename":"b.txt"}]'
no "risk_gate: no additions/deletions fields -> fail closed" automerge_risk_gate acme/x 7
has "risk_gate: shape refusal is not phrased as a bound" \
  "$(automerge_risk_gate acme/x 7 2>&1)" "no additions/deletions counts"
FILES='[{"filename":"a.txt","additions":1,"deletions":1},{"filename":"b.txt","additions":2}]'
no "risk_gate: one element missing deletions -> fail closed" automerge_risk_gate acme/x 7
# igor#517: a filename-less element must refuse too -- a shape change that
# drops filenames must not quietly make the deny-list walk vacuous.
FILES='[{"additions":1,"deletions":1}]'
no "risk_gate: element with no filename -> fail closed" automerge_risk_gate acme/x 7
has "risk_gate: filename-less refusal is not phrased as a bound" \
  "$(automerge_risk_gate acme/x 7 2>&1)" "no filename"
# A rename FROM a denied path (Forgejo's actual field is previous_filename,
# not old_filename) must still be caught by the deny-list.
FILES='[{"filename":"ci.yml","previous_filename":".forgejo/workflows/ci.yml","additions":1,"deletions":1}]'
no "risk_gate: rename from denied previous_filename -> blocked" automerge_risk_gate acme/x 7
has "risk_gate: reason mentions the denied previous_filename" \
  "$(automerge_risk_gate acme/x 7 2>&1)" ".forgejo/workflows/ci.yml"
FILES=""
forgejo_pr_files() { return 1; }
no "risk_gate: API failure -> fail closed (blocked)" automerge_risk_gate acme/x 7
# forgejo_pr_files is nonzero when the listing can't be walked to the end
# (including a truncated/capped page walk), so an unwalkable list refuses here
# rather than being read as a small PR. The paging itself is covered by
# bin/test-forgejo.sh.
has "risk_gate: fetch refusal is not phrased as a bound" \
  "$(automerge_risk_gate acme/x 7 2>&1)" "unable to fetch changed files"

echo "== do_automerge_tick merge decision =="
export FORGEJO_REVIEWER=josh BOT_USER=igor
export VALIDATED_REPOS_JSON='{"full_name":"acme/site"}'
automerge_url_status() { printf 'ok\thttps://x'; }   # url-bearing repo throughout this section
forgejo_list_open_bot_prs() { echo '[{"number":7}]'; }
forgejo_commit_status() { echo success; }
automerge_mergeable() { return 0; }
automerge_behind_count() { echo 0; }                       # up to date by default
automerge_update_branch() { UPDATED="$1#$2"; return 0; }
automerge_do_merge() { echo "mergesha7"; }
_fj() { echo '{"head":{"sha":"headsha7"}}'; }
automerge_require_human() { return 1; }      # default: shadow-gated repo
automerge_approved_by() { return 1; }        # no human review -> exercises the shadow path
automerge_approval_covers_head() { return 0; }  # default: the approval covers the head (base-merge/live)
forgejo_pr_files() { printf '[{"filename":"x.txt","additions":1,"deletions":1}]'; }  # small diff by default

# Default (shadow-gated) repo: the shadow verdict APPROVE is the gate.
echo '{"review":{"acme/site#7":{"verdict":"APPROVE","sha":"headsha7"}}}' > "$STATE"
ok "automerge: default repo + shadow APPROVE -> merges (rc0)"  do_automerge_tick
eq "automerge: recorded deploy repo"       "acme/site" "$(jq -r '.deploy.repo // ""' "$STATE")"
eq "automerge: recorded merge sha"         "mergesha7" "$(jq -r '.deploy.sha // ""' "$STATE")"

# APPROVE-only: a shadow COMMENT (no affirmative sign-off) routes to human, no merge.
echo '{"review":{"acme/site#7":{"verdict":"COMMENT"}}}' > "$STATE"
no "automerge: shadow COMMENT -> no auto-merge (rc1)"          do_automerge_tick
eq "automerge: comment records nothing"     ""        "$(jq -r '.deploy.repo // ""' "$STATE")"

echo '{"review":{"acme/site#7":{"verdict":"REQUEST_CHANGES"}}}' > "$STATE"
no "automerge: shadow RC blocks merge (rc1)"          do_automerge_tick
eq "automerge: RC records nothing"          ""        "$(jq -r '.deploy.repo // ""' "$STATE")"

# Stale APPROVE: the verdict is APPROVE but recorded for an OLDER sha than the
# current head (a real new commit landed and hasn't been re-reviewed) -> must NOT
# merge the unreviewed head. This is the fail-open the sha-binding closes.
echo '{"review":{"acme/site#7":{"verdict":"APPROVE","sha":"oldsha0"}}}' > "$STATE"
no "automerge: shadow APPROVE for a STALE sha -> no merge (rc1)"  do_automerge_tick
eq "automerge: stale-APPROVE records nothing" ""      "$(jq -r '.deploy.repo // ""' "$STATE")"

# Human override: the shadow only COMMENTed, but a human FORGEJO_REVIEWER APPROVED
# -> merges (a human can merge any repo by approving). This is the #59/#61 case.
automerge_approved_by() { return 0; }        # human approved
echo '{"review":{"acme/site#7":{"verdict":"COMMENT"}}}' > "$STATE"
ok "automerge: human APPROVED overrides a shadow COMMENT -> merges"  do_automerge_tick
eq "automerge: human-override recorded deploy" "acme/site" "$(jq -r '.deploy.repo // ""' "$STATE")"
# ... but a shadow REQUEST_CHANGES blocks even a human approve (overriding a
# flagged problem is a deliberate MANUAL merge, not an auto-merge).
echo '{"review":{"acme/site#7":{"verdict":"REQUEST_CHANGES"}}}' > "$STATE"
no "automerge: shadow RC blocks even a human approve"  do_automerge_tick
# The reviewer's scenario (#410): a human approved, then a NEW commit landed that
# the approval no longer covers (not a base-merge). automerge_approved_by still
# counts the stale approval, but covers_head vetoes -- unreviewed code must NOT
# merge on a stale approval. Shadow COMMENT (no fresh sha-bound APPROVE) -> no merge.
automerge_approved_by() { return 0; }        # human approved (now stale)
automerge_approval_covers_head() { return 1; }  # ...but the head is new, unreviewed content
echo '{"review":{"acme/site#7":{"verdict":"COMMENT"}}}' > "$STATE"
no "automerge: human approve staled by new content -> no merge"  do_automerge_tick
eq "automerge: staled-approve records nothing" ""     "$(jq -r '.deploy.repo // ""' "$STATE")"
# Same PR, but the shadow HAS a fresh APPROVE bound to the current head: the shadow
# reviewed this exact code, so the merge still proceeds via the shadow path.
echo '{"review":{"acme/site#7":{"verdict":"APPROVE","sha":"headsha7"}}}' > "$STATE"
ok "automerge: staled human approve but fresh shadow APPROVE -> merges"  do_automerge_tick
automerge_approval_covers_head() { return 0; }  # reset
automerge_approved_by() { return 1; }        # reset: no human for the sections below

echo "== do_automerge_tick multi-repo iteration (production stream shape) =="
# VALIDATED_REPOS_JSON is a NEWLINE-DELIMITED STREAM, not an array. The loop must
# iterate every line: the first repo is url-less with no human approval (so it
# stops at the approval gate, never merging) and the second is url-bearing and
# shadow-approved. A single-object stub can't catch a broken iteration.
VALIDATED_REPOS_JSON="$(printf '%s\n%s\n' '{"full_name":"acme/first"}' '{"full_name":"acme/second"}')"
automerge_url_status() { case "$1" in acme/second) printf 'ok\thttps://x' ;; *) printf 'ok\t' ;; esac; }
echo '{"review":{"acme/second#7":{"verdict":"APPROVE","sha":"headsha7"}}}' > "$STATE"
ok "automerge: iterates stream, skips the unapproved url-less repo, merges 2nd"  do_automerge_tick
eq "automerge: merged the eligible repo"   "acme/second" "$(jq -r '.deploy.repo // ""' "$STATE")"

echo "== do_automerge_tick: behind base -> update branch, do NOT merge =="
export VALIDATED_REPOS_JSON='{"full_name":"acme/site"}'
automerge_url_status() { printf 'ok\thttps://x'; }
forgejo_list_open_bot_prs() { echo '[{"number":7}]'; }
echo '{"review":{"acme/site#7":{"verdict":"APPROVE","sha":"headsha7"}}}' > "$STATE"
MERGED=0; automerge_do_merge() { MERGED=1; echo "sha"; }
UPDATED=""; automerge_update_branch() { UPDATED="$1#$2"; return 0; }
automerge_behind_count() { echo 3; }
ok "automerge: behind base -> processes the tick (rc0)"          do_automerge_tick
eq "automerge: behind base did NOT merge"        "0"             "$MERGED"
eq "automerge: behind base updated the branch"   "acme/site#7"   "$UPDATED"
eq "automerge: behind base recorded no deploy"   ""              "$(jq -r '.deploy.repo // ""' "$STATE")"
automerge_behind_count() { echo -1; }   # can't determine -> skip, never blind-update
UPDATED=""; echo '{"review":{"acme/site#7":{"verdict":"APPROVE","sha":"headsha7"}}}' > "$STATE"
no "automerge: inconclusive up-to-date -> no merge/update (rc1)"  do_automerge_tick
eq "automerge: inconclusive did not update"      ""              "$UPDATED"

echo "== do_automerge_tick: active block skips AND logs it (igor#386) =="
# A prior rejected merge on this exact head must skip silently on the merge
# side (no re-POST) but NOT silently on the log side -- the initial rejection
# log line scrolls out of view long before the hour-long cooldown clears, so
# every skipped tick during the cooldown must say so too, or a human staring
# at the log during the block window sees nothing and assumes the tick never
# reached this PR at all.
export VALIDATED_REPOS_JSON='{"full_name":"acme/site"}'
automerge_url_status() { printf 'ok\thttps://x'; }
forgejo_list_open_bot_prs() { echo '[{"number":7}]'; }
automerge_approved_by() { return 0; }
automerge_behind_count() { echo 0; }
_fj() { echo '{"head":{"sha":"headsha7"}}'; }
MERGED=0; automerge_do_merge() { MERGED=1; echo "sha"; }
echo '{"review":{"acme/site#7":{"verdict":"APPROVE","sha":"headsha7"}}}' > "$STATE"
# shellcheck disable=SC2034  # read by lib/automerge.sh (sourced above), not by this file
AUTOMERGE_BLOCK_COOLDOWN_SECS=3600
automerge_block_record "$STATE" "acme/site#7" "headsha7" "HTTP 405: nope"
AUTOMERGE_OUT=$(do_automerge_tick 2>&1); AUTOMERGE_RC=$?
if [ "$AUTOMERGE_RC" -ne 0 ]; then printf '  + %s\n' "automerge: active block -> no merge (rc1)"
else printf '  x %s\n' "automerge: active block -> no merge (rc1)"; FAIL=$((FAIL + 1)); fi
eq "automerge: active block did NOT call automerge_do_merge" "0" "$MERGED"
has "automerge: active block logs the skip"     "$AUTOMERGE_OUT" "still backing off a prior rejected merge"

echo "== do_automerge_tick: review-gate paths (human-flagged vs default) =="
export VALIDATED_REPOS_JSON='{"full_name":"acme/site"}'
automerge_url_status() { printf 'ok\thttps://x'; }
forgejo_list_open_bot_prs() { echo '[{"number":7}]'; }
forgejo_commit_status() { echo success; }
automerge_mergeable() { return 0; }
automerge_behind_count() { echo 0; }
automerge_do_merge() { echo "mergesha7"; }
_fj() { echo '{"head":{"sha":"headsha7"}}'; }
# Human-flagged repo: the HUMAN's APPROVED gates; NO shadow verdict needed.
automerge_require_human() { return 0; }
automerge_approved_by() { return 0; }
echo '{}' > "$STATE"
ok "automerge: flagged repo + human APPROVED (no shadow verdict) -> merges" do_automerge_tick
eq "automerge: flagged merge recorded"     "acme/site" "$(jq -r '.deploy.repo // ""' "$STATE")"
# Flagged repo, human approved but the approval no longer covers the head (new
# content since) -> no merge, no shadow fallback on a require_human repo.
automerge_approval_covers_head() { return 1; }
echo '{}' > "$STATE"
no "automerge: flagged repo, approve staled by new content -> no merge" do_automerge_tick
eq "automerge: flagged staled-approve records nothing" "" "$(jq -r '.deploy.repo // ""' "$STATE")"
automerge_approval_covers_head() { return 0; }  # reset
# Flagged repo, human has NOT approved -> no merge, even with a shadow APPROVE present.
automerge_approved_by() { return 1; }
echo '{"review":{"acme/site#7":{"verdict":"APPROVE","sha":"headsha7"}}}' > "$STATE"
no "automerge: flagged repo, no human approve -> no merge"     do_automerge_tick
# Default repo, shadow APPROVE but the HUMAN requested changes -> veto, no merge.
automerge_require_human() { return 1; }
automerge_reviewer_blocks() { return 0; }
echo '{"review":{"acme/site#7":{"verdict":"APPROVE","sha":"headsha7"}}}' > "$STATE"
no "automerge: default repo, human RC vetoes shadow APPROVE"   do_automerge_tick
automerge_reviewer_blocks() { return 1; }

echo "== do_automerge_tick: risk gate on the shadow-only APPROVE path (igor#514) =="
export VALIDATED_REPOS_JSON='{"full_name":"acme/site"}'
automerge_url_status() { printf 'ok\thttps://x'; }
forgejo_list_open_bot_prs() { echo '[{"number":7}]'; }
forgejo_commit_status() { echo success; }
automerge_mergeable() { return 0; }
automerge_behind_count() { echo 0; }
automerge_do_merge() { echo "mergesha7"; }
automerge_require_human() { return 1; }      # default (shadow-gated) repo
automerge_approved_by() { return 1; }        # no human review -> shadow-only merge path
automerge_approval_covers_head() { return 0; }
REQUESTS=0; forgejo_request_review() { REQUESTS=$((REQUESTS + 1)); return 0; }

# Under the cap -> merges exactly as before, no human requested.
_fj() { echo '{"head":{"sha":"headsha7"}}'; }
forgejo_pr_files() { printf '[{"filename":"x.txt","additions":1,"deletions":1}]'; }
echo '{"review":{"acme/site#7":{"verdict":"APPROVE","sha":"headsha7"}}}' > "$STATE"
ok "risk-gate: under-limit shadow APPROVE -> merges"        do_automerge_tick
eq "risk-gate: under-limit recorded deploy" "acme/site" "$(jq -r '.deploy.repo // ""' "$STATE")"
eq "risk-gate: under-limit did not request human" "0" "$REQUESTS"

# Over the line-count cap -> refuses to merge, requests the human instead.
_fj() { echo '{"head":{"sha":"headsha7"}}'; }
forgejo_pr_files() { printf '[{"filename":"big.txt","additions":400,"deletions":400}]'; }
echo '{"review":{"acme/site#7":{"verdict":"APPROVE","sha":"headsha7"}}}' > "$STATE"
REQUESTS=0
RGOUTFILE="$TMP/rgout1"
do_automerge_tick >"$RGOUTFILE" 2>&1; RGRC=$?
RGOUT=$(cat "$RGOUTFILE")
if [ "$RGRC" -ne 0 ]; then printf '  + %s\n' "risk-gate: over line-count cap -> refuses merge (rc1)"
else printf '  x %s\n' "risk-gate: over line-count cap -> refuses merge (rc1)"; FAIL=$((FAIL + 1)); fi
eq "risk-gate: over-cap recorded no deploy" ""             "$(jq -r '.deploy.repo // ""' "$STATE")"
eq "risk-gate: over-cap requested human once"  "1"          "$REQUESTS"
# igor#517: the first tick that notifies logs "requesting human review", not
# the repeat-tick wording -- the notify happened just now, on this tick.
has "risk-gate: first refusal logs requesting human review" "$RGOUT" "requesting human review"

# Same PR, same head, next tick -> still refuses, but does NOT nag the human again.
RGOUTFILE2="$TMP/rgout2"
do_automerge_tick >"$RGOUTFILE2" 2>&1; RGRC2=$?
RGOUT2=$(cat "$RGOUTFILE2")
if [ "$RGRC2" -ne 0 ]; then printf '  + %s\n' "risk-gate: same head next tick -> still refuses (rc1)"
else printf '  x %s\n' "risk-gate: same head next tick -> still refuses (rc1)"; FAIL=$((FAIL + 1)); fi
eq "risk-gate: same head does not re-request"  "1"          "$REQUESTS"
# igor#517: a repeat tick on the same already-notified head must NOT repeat
# "requesting human review" -- forgejo_request_review is deduped, so the log
# must say so rather than overstating that a new request went out.
has "risk-gate: repeat tick logs already-requested wording" "$RGOUT2" "risk-gated (human already requested)"
case "$RGOUT2" in
  *"requesting human review"*) printf '  x %s\n' "risk-gate: repeat tick does not say requesting human review"; FAIL=$((FAIL + 1)) ;;
  *) printf '  + %s\n' "risk-gate: repeat tick does not say requesting human review" ;;
esac

# A new commit lands (head moves) -> the gate re-evaluates and may notify again.
_fj() { echo '{"head":{"sha":"headsha7b"}}'; }
echo '{"review":{"acme/site#7":{"verdict":"APPROVE","sha":"headsha7b"}}}' > "$STATE"
no "risk-gate: new head re-evaluates -> still refuses (rc1)" do_automerge_tick
eq "risk-gate: new head requests the human again" "2"        "$REQUESTS"

# Deny-listed path -> refuses to merge, requests the human.
_fj() { echo '{"head":{"sha":"headsha8"}}'; }
forgejo_pr_files() { printf '[{"filename":"agent.json","additions":1,"deletions":1}]'; }
echo '{"review":{"acme/site#7":{"verdict":"APPROVE","sha":"headsha8"}}}' > "$STATE"
REQUESTS=0
no "risk-gate: deny-listed path -> refuses merge (rc1)"     do_automerge_tick
eq "risk-gate: deny-listed recorded no deploy" ""            "$(jq -r '.deploy.repo // ""' "$STATE")"
eq "risk-gate: deny-listed requested human once" "1"         "$REQUESTS"

# A human-approved merge (live approval, not the shadow) is UNAFFECTED by the risk
# gate -- a human already saw the diff, oversized or not.
_fj() { echo '{"head":{"sha":"headsha9"}}'; }
automerge_approved_by() { return 0; }
automerge_approval_covers_head() { return 0; }
forgejo_pr_files() { printf '[{"filename":"big.txt","additions":1000,"deletions":1000}]'; }
echo '{"review":{"acme/site#7":{"verdict":"COMMENT"}}}' > "$STATE"
REQUESTS=0
ok "risk-gate: human-approved path unaffected by size -> merges" do_automerge_tick
eq "risk-gate: human-approved recorded deploy" "acme/site"   "$(jq -r '.deploy.repo // ""' "$STATE")"
eq "risk-gate: human-approved path never re-requests" "0"    "$REQUESTS"
automerge_approved_by() { return 1; }   # reset

# A PR that isn't merge-ready anyway stops at the CI check ABOVE the gate, so a
# red-CI head never pulls the human in on size.
_fj() { echo '{"head":{"sha":"headshaC"}}'; }
forgejo_commit_status() { echo failure; }
forgejo_pr_files() { printf '[{"filename":"big.txt","additions":400,"deletions":400}]'; }
echo '{"review":{"acme/site#7":{"verdict":"APPROVE","sha":"headshaC"}}}' > "$STATE"
REQUESTS=0
no "risk-gate: red CI stops above the gate (rc1)"           do_automerge_tick
eq "risk-gate: red CI does not request the human" "0"        "$REQUESTS"
forgejo_commit_status() { echo success; }   # reset

# The notification stamp is per-PR state, dropped when the PR merges -- it must
# not accumulate a key per PR forever.
CSF="$TMP/risk-clear-state.json"; echo '{}' > "$CSF"
automerge_risk_notify_record "$CSF" "acme/x#5" "headA"
ok "risk-gate: stamp recorded"                    automerge_risk_notified "$CSF" "acme/x#5" "headA"
automerge_block_clear "$CSF" "acme/x#5"
no "risk-gate: merge clears the stamp"            automerge_risk_notified "$CSF" "acme/x#5" "headA"

echo "== do_automerge_tick: URL-less human-approval path (igor#520) =="
# A repo that genuinely declares no url (a clean fetch, no key) gets a merge
# path too -- gated on a live human APPROVED review, like automerge.require_human,
# but skipping the deploy stamp entirely (nothing to smoke-test).
VALIDATED_REPOS_JSON='{"full_name":"acme/urlless"}'
automerge_url_status() { printf 'ok\t'; }
forgejo_list_open_bot_prs() { echo '[{"number":11}]'; }
forgejo_commit_status() { echo success; }
automerge_mergeable() { return 0; }
automerge_behind_count() { echo 0; }
automerge_do_merge() { echo "mergesha11"; }
_fj() { echo '{"head":{"sha":"headsha11"}}'; }
automerge_require_human() { return 1; }   # irrelevant -- url-less overrides this unconditionally
automerge_approved_by() { return 0; }     # human APPROVED
automerge_approval_covers_head() { return 0; }
echo '{}' > "$STATE"   # no shadow review at all -- the human approval alone gates it
AUTOMERGE_OUT=$(do_automerge_tick 2>&1); AUTOMERGE_RC=$?
if [ "$AUTOMERGE_RC" -eq 0 ]; then printf '  + %s\n' "url-less: human APPROVED + CI green -> merges (rc0)"
else printf '  x %s\n' "url-less: human APPROVED + CI green -> merges (rc0)"; FAIL=$((FAIL + 1)); fi
eq "url-less: merge recorded NO deploy (nothing to watch)" "" "$(jq -r '.deploy.repo // ""' "$STATE")"
has "url-less: log says it skipped the deploy watch" "$AUTOMERGE_OUT" "skipping deploy watch"

# Approval dismissed (automerge_approved_by reads Forgejo's `dismissed` flag) ->
# no counting approval -> no merge.
automerge_approved_by() { return 1; }
echo '{}' > "$STATE"
no "url-less: dismissed approval -> no merge (rc1)"                do_automerge_tick
eq "url-less: dismissed-approval records nothing" "" "$(jq -r '.deploy.repo // ""' "$STATE")"
automerge_approved_by() { return 0; }   # reset

# Approval stands, but the head carries content the human never saw (a real
# new commit, not a base-merge). The url-less path inherits the same staleness
# rule as the require_human carve-out -- an approval only counts for the net
# diff it was given.
automerge_approval_covers_head() { return 1; }
echo '{}' > "$STATE"
AUTOMERGE_OUT=$(do_automerge_tick 2>&1); AUTOMERGE_RC=$?
if [ "$AUTOMERGE_RC" -ne 0 ]; then printf '  + %s\n' "url-less: approval predating the head's content -> no merge (rc1)"
else printf '  x %s\n' "url-less: approval predating the head's content -> no merge (rc1)"; FAIL=$((FAIL + 1)); fi
eq "url-less: stale-approval records nothing" "" "$(jq -r '.deploy.repo // ""' "$STATE")"
has "url-less: log names the staleness" "$AUTOMERGE_OUT" "approval predates the current head"
automerge_approval_covers_head() { return 0; }   # reset

# Human approved, but the shadow verdict on THIS head is REQUEST_CHANGES ->
# veto, exactly like the require_human carve-out path.
echo '{"review":{"acme/urlless#11":{"verdict":"REQUEST_CHANGES"}}}' > "$STATE"
no "url-less: human approved but shadow RC vetoes -> no merge (rc1)" do_automerge_tick
eq "url-less: RC-vetoed records nothing" "" "$(jq -r '.deploy.repo // ""' "$STATE")"

# Shadow APPROVE ALONE (no human review at all) must NEVER merge a url-less
# repo -- deliverable 2's core guarantee.
automerge_approved_by() { return 1; }
echo '{"review":{"acme/urlless#11":{"verdict":"APPROVE","sha":"headsha11"}}}' > "$STATE"
no "url-less: shadow APPROVE alone never merges (rc1)"              do_automerge_tick
eq "url-less: shadow-APPROVE-alone records nothing" "" "$(jq -r '.deploy.repo // ""' "$STATE")"
automerge_approved_by() { return 0; }   # reset

# The harness's own repo takes the SAME human-approval path as any other
# url-less repo -- merges on approval, no deploy stamp, never shadow-gated.
# The REAL automerge_url_status runs here, over a dossier layer that answers
# "url-BEARING": only the self-repo short-circuit can produce a url-less merge
# from that, so this fails if the carve-out ever stops applying.
automerge_url_status() { _real_url_status "$@"; }
dossier_get_repo_status() { printf 'ok\thttps://x'; }
eq "self-repo: that same dossier answer on any OTHER repo is url-BEARING" \
  "$(printf 'ok\thttps://x')" "$(automerge_url_status acme/other)"
VALIDATED_REPOS_JSON="{\"full_name\":\"${AUTOMERGE_SELF_REPO}\"}"
echo '{}' > "$STATE"
ok "self-repo: human APPROVED -> merges even though the dossier declares a url" do_automerge_tick
eq "self-repo: merge recorded NO deploy" "" "$(jq -r '.deploy.repo // ""' "$STATE")"

echo "== do_automerge_tick: dossier fetch failure -> skip entirely, retry next tick (igor#520 amendment) =="
# A repo with a pending human-APPROVED, CI-green PR whose dossier fetch FAILS
# this tick must not merge via EITHER path -- the empty url from a flaky
# fetch must never be read as "declares no url".
VALIDATED_REPOS_JSON='{"full_name":"acme/flaky"}'
automerge_url_status() { printf 'error\t'; }
echo '{}' > "$STATE"
AUTOMERGE_OUT=$(do_automerge_tick 2>&1); AUTOMERGE_RC=$?
if [ "$AUTOMERGE_RC" -ne 0 ]; then printf '  + %s\n' "flaky-dossier: no merge (rc1)"
else printf '  x %s\n' "flaky-dossier: no merge (rc1)"; FAIL=$((FAIL + 1)); fi
eq "flaky-dossier: recorded no deploy" "" "$(jq -r '.deploy.repo // ""' "$STATE")"
has "flaky-dossier: logs the skip"      "$AUTOMERGE_OUT" "dossier fetch failed"
automerge_url_status() { printf 'ok\thttps://x'; }   # reset

echo "== automerge_maintenance_declaration: REQUIRED-AND-EXPLICIT dossier opt-in (igor#537) =="
JY_DECL='{"branch":"review","allowlist":["src/_data/sites.json","src/_data/feeds.json","src/_data/rejected.json","src/images/screenshots/*"],"data_file":"src/_data/sites.json","rejected_category":"no-josh-visible"}'
forgejo_repo_get_file() { printf '%s' "$(jq -n --argjson d "$JY_DECL" '{automerge:{require_human:true,maintenance:$d}}')"; }
eq "declaration: full valid declaration -> echoes it" \
  "$(jq -c . <<<"$JY_DECL")" "$(jq -c . <<<"$(automerge_maintenance_declaration joshtronic/joshing.you)")"
forgejo_repo_get_file() { printf '%s' '{"automerge":{"require_human":true}}'; }
no "declaration: no automerge.maintenance key -> tier off"  automerge_maintenance_declaration acme/x
forgejo_repo_get_file() { return 1; }
no "declaration: no agent.json -> tier off"                 automerge_maintenance_declaration acme/x
PARTIAL='{"branch":"review","allowlist":["src/_data/sites.json"]}'   # missing data_file
forgejo_repo_get_file() { printf '%s' "$(jq -n --argjson d "$PARTIAL" '{automerge:{maintenance:$d}}')"; }
DECL_OUT=$(automerge_maintenance_declaration acme/x 2>&1); DECL_RC=$?
if [ "$DECL_RC" -ne 0 ]; then printf '  + %s\n' "declaration: partial (no data_file) -> tier off"
else printf '  x %s\n' "declaration: partial (no data_file) -> tier off"; FAIL=$((FAIL + 1)); fi
has "declaration: partial declaration logs one loud line" "$DECL_OUT" "partial automerge.maintenance"
EMPTYLIST='{"branch":"review","allowlist":[],"data_file":"src/_data/sites.json"}'
forgejo_repo_get_file() { printf '%s' "$(jq -n --argjson d "$EMPTYLIST" '{automerge:{maintenance:$d}}')"; }
no "declaration: empty allowlist array -> tier off"         automerge_maintenance_declaration acme/x
BLANKENTRY='{"branch":"review","allowlist":["src/_data/sites.json",""],"data_file":"src/_data/sites.json"}'
forgejo_repo_get_file() { printf '%s' "$(jq -n --argjson d "$BLANKENTRY" '{automerge:{maintenance:$d}}')"; }
no "declaration: blank allowlist entry -> tier off"         automerge_maintenance_declaration acme/x

DOSSIER_IN_ALLOW='{"branch":"review","allowlist":["src/_data/sites.json","agent.json"],"data_file":"src/_data/sites.json"}'
forgejo_repo_get_file() { printf '%s' "$(jq -n --argjson d "$DOSSIER_IN_ALLOW" '{automerge:{maintenance:$d}}')"; }
DECL_OUT=$(automerge_maintenance_declaration acme/x 2>&1); DECL_RC=$?
if [ "$DECL_RC" -ne 0 ]; then printf '  + %s\n' "declaration: agent.json literally in allowlist -> refused"
else printf '  x %s\n' "declaration: agent.json literally in allowlist -> refused"; FAIL=$((FAIL + 1)); fi
has "declaration: dossier-in-allowlist logs the refusal reason" "$DECL_OUT" "own dossier"

GLOB_CATCHES_DOSSIER='{"branch":"review","allowlist":["*"],"data_file":"src/_data/sites.json"}'
forgejo_repo_get_file() { printf '%s' "$(jq -n --argjson d "$GLOB_CATCHES_DOSSIER" '{automerge:{maintenance:$d}}')"; }
no "declaration: a wildcard allowlist entry that would match agent.json -> refused" \
  automerge_maintenance_declaration acme/x

DATA_FILE_IS_DOSSIER='{"branch":"review","allowlist":["AGENTS.md"],"data_file":"AGENTS.md"}'
forgejo_repo_get_file() { printf '%s' "$(jq -n --argjson d "$DATA_FILE_IS_DOSSIER" '{automerge:{maintenance:$d}}')"; }
no "declaration: data_file itself is a dossier file -> refused" \
  automerge_maintenance_declaration acme/x

echo "== automerge_maintenance_declaration: rejected_category opt-in belt (igor#558) =="
# A repo opts AUTOMERGE_MAINTENANCE_REJECTED_FILE into its allowlist but
# declares no category -- must refuse the WHOLE declaration, not silently
# skip the belt.
NOCAT_DECL='{"branch":"review","allowlist":["src/_data/sites.json","src/_data/rejected.json"],"data_file":"src/_data/sites.json"}'
forgejo_repo_get_file() { printf '%s' "$(jq -n --argjson d "$NOCAT_DECL" '{automerge:{maintenance:$d}}')"; }
DECL_OUT=$(automerge_maintenance_declaration acme/x 2>&1); DECL_RC=$?
if [ "$DECL_RC" -ne 0 ]; then printf '  + %s\n' "declaration: rejected.json in allowlist without rejected_category -> refused"
else printf '  x %s\n' "declaration: rejected.json in allowlist without rejected_category -> refused"; FAIL=$((FAIL + 1)); fi
has "declaration: missing-category refusal names the reason" "$DECL_OUT" "rejected_category"

# The same file/allowlist WITH a declared category -> the tier is on, and the
# category rides along in the echoed declaration.
WITHCAT_DECL='{"branch":"review","allowlist":["src/_data/sites.json","src/_data/rejected.json"],"data_file":"src/_data/sites.json","rejected_category":"off-brand"}'
forgejo_repo_get_file() { printf '%s' "$(jq -n --argjson d "$WITHCAT_DECL" '{automerge:{maintenance:$d}}')"; }
eq "declaration: rejected.json in allowlist WITH a declared category -> echoes it" \
  "$(jq -c . <<<"$WITHCAT_DECL")" "$(jq -c . <<<"$(automerge_maintenance_declaration acme/x)")"

# A category that is DECLARED but isn't a non-empty string is refused just as
# hard as a missing one: `jq -r` renders an array/number/object to a non-empty
# string that no string in rejected.json can ever equal, so the belt would
# count zero rejections on both sides and pass trivially -- the same silent
# no-op, reached by mistyping instead of omission.
BADCAT_DECL='{"branch":"review","allowlist":["src/_data/sites.json","src/_data/rejected.json"],"data_file":"src/_data/sites.json","rejected_category":["no-josh-visible"]}'
forgejo_repo_get_file() { printf '%s' "$(jq -n --argjson d "$BADCAT_DECL" '{automerge:{maintenance:$d}}')"; }
DECL_OUT=$(automerge_maintenance_declaration acme/x 2>&1); DECL_RC=$?
if [ "$DECL_RC" -ne 0 ]; then printf '  + %s\n' "declaration: array rejected_category -> refused"
else printf '  x %s\n' "declaration: array rejected_category -> refused"; FAIL=$((FAIL + 1)); fi
has "declaration: non-string-category refusal names the field" "$DECL_OUT" "rejected_category"

# Same for a number, and with rejected.json NOT in the allowlist: the field is
# inert there, but a malformed declaration is still a malformed declaration.
NUMCAT_DECL='{"branch":"review","allowlist":["src/_data/sites.json"],"data_file":"src/_data/sites.json","rejected_category":123}'
forgejo_repo_get_file() { printf '%s' "$(jq -n --argjson d "$NUMCAT_DECL" '{automerge:{maintenance:$d}}')"; }
no "declaration: numeric rejected_category -> refused even with the file un-allowlisted" \
  automerge_maintenance_declaration acme/x

BLANKCAT_DECL='{"branch":"review","allowlist":["src/_data/sites.json","src/_data/rejected.json"],"data_file":"src/_data/sites.json","rejected_category":""}'
forgejo_repo_get_file() { printf '%s' "$(jq -n --argjson d "$BLANKCAT_DECL" '{automerge:{maintenance:$d}}')"; }
no "declaration: blank rejected_category -> refused" automerge_maintenance_declaration acme/x

# A repo that never opts rejected.json into its allowlist at all doesn't need
# a category -- undeclared/unrelated repos behave exactly as before igor#558.
NOFILE_DECL='{"branch":"review","allowlist":["src/_data/sites.json"],"data_file":"src/_data/sites.json"}'
forgejo_repo_get_file() { printf '%s' "$(jq -n --argjson d "$NOFILE_DECL" '{automerge:{maintenance:$d}}')"; }
ok "declaration: repo that never opts rejected.json in doesn't need a category" \
  automerge_maintenance_declaration acme/x

forgejo_repo_get_file() { printf '%s' "$(jq -n --argjson d "$JY_DECL" '{automerge:{require_human:true,maintenance:$d}}')"; }   # reset

echo "== automerge_maintenance_tier_branch_ok: same-repo <branch>->master pin (igor#516/#537) =="
PRJ='{"head":{"ref":"review","repo":{"full_name":"joshtronic/joshing.you"}},"base":{"ref":"master","repo":{"full_name":"joshtronic/joshing.you"}}}'
ok "branch_ok: review->master, same repo"          automerge_maintenance_tier_branch_ok "$PRJ" review
PRJ='{"head":{"ref":"checkpoint/foo","repo":{"full_name":"joshtronic/joshing.you"}},"base":{"ref":"master","repo":{"full_name":"joshtronic/joshing.you"}}}'
no "branch_ok: non-declared head branch -> rejected"  automerge_maintenance_tier_branch_ok "$PRJ" review
PRJ='{"head":{"ref":"review","repo":{"full_name":"joshtronic/joshing.you"}},"base":{"ref":"develop","repo":{"full_name":"joshtronic/joshing.you"}}}'
no "branch_ok: non-master base -> rejected"         automerge_maintenance_tier_branch_ok "$PRJ" review
PRJ='{"head":{"ref":"review","repo":{"full_name":"forker/joshing.you"}},"base":{"ref":"master","repo":{"full_name":"joshtronic/joshing.you"}}}'
no "branch_ok: fork head repo -> rejected"          automerge_maintenance_tier_branch_ok "$PRJ" review
PRJ='{"head":{"ref":"review"},"base":{"ref":"master","repo":{"full_name":"joshtronic/joshing.you"}}}'
no "branch_ok: missing head repo -> fail closed"    automerge_maintenance_tier_branch_ok "$PRJ" review

echo "== automerge_maintenance_tier_files_ok: the DECLARED maintenance data allowlist (igor#516/#537) =="
MTALLOW='["src/_data/sites.json","src/_data/feeds.json","src/_data/rejected.json","src/images/screenshots/*"]'
forgejo_pr_files() { printf '%s' "$MTFILES"; }
MTFILES='[{"filename":"src/_data/sites.json"}]'
has "files_ok: sites.json alone -> ok, echoes count" "$(automerge_maintenance_tier_files_ok acme/x 1 "$MTALLOW")" "1"
MTFILES='[{"filename":"src/_data/sites.json"},{"filename":"src/_data/feeds.json"},{"filename":"src/_data/rejected.json"},{"filename":"src/images/screenshots/a/b.png"}]'
ok "files_ok: full allowlist set -> ok"             automerge_maintenance_tier_files_ok acme/x 1 "$MTALLOW"
MTFILES='[{"filename":"src/_data/sites.json"},{"filename":"scripts/refresh.sh"}]'
no "files_ok: out-of-allowlist path -> rejected"    automerge_maintenance_tier_files_ok acme/x 1 "$MTALLOW"
MTFILES='[{"filename":".forgejo/workflows/refresh.yml"}]'
no "files_ok: workflow path -> rejected"            automerge_maintenance_tier_files_ok acme/x 1 "$MTALLOW"
MTFILES='[{"filename":"src/images/screenshots/new.png","previous_filename":"scripts/old.sh"}]'
no "files_ok: rename from out-of-allowlist -> rejected" automerge_maintenance_tier_files_ok acme/x 1 "$MTALLOW"
MTFILES='[{"foo":"bar"}]'
no "files_ok: filename-less element -> fail closed" automerge_maintenance_tier_files_ok acme/x 1 "$MTALLOW"
forgejo_pr_files() { return 1; }
no "files_ok: unwalkable listing -> fail closed"    automerge_maintenance_tier_files_ok acme/x 1 "$MTALLOW"
forgejo_pr_files() { printf '%s' '[{"filename":"other/data.json"}]'; }
OTHERALLOW='["other/data.json"]'
ok "files_ok: a DIFFERENT repo's own allowlist is honored (agnostic pin, igor#537)" \
  automerge_maintenance_tier_files_ok acme/x 1 "$OTHERALLOW"

echo "== automerge_maintenance_tier_data_ok: data_file / rejected.json structural diff, real git (igor#516/#537) =="
DP="$(mktemp -d "$TMP/data.XXXXXX")"
git init -q -b master "$DP"
git -C "$DP" config user.email t@t; git -C "$DP" config user.name t
mkdir -p "$DP/src/_data"
cat > "$DP/src/_data/sites.json" <<'JSON'
[
  {"url":"https://a.example","addedDate":"2026-01-01","title":"A","updatedDate":"2026-01-01"},
  {"url":"https://b.example","addedDate":"2026-01-02","title":"B","updatedDate":"2026-01-02"}
]
JSON
echo '[{"url":"https://c.example","reason":"no-josh-visible"}]' > "$DP/src/_data/rejected.json"
git -C "$DP" add -A; git -C "$DP" commit -q -m base
BASE_SHA="$(git -C "$DP" rev-parse HEAD)"

# Metadata-only churn (title/updatedDate on an existing entry) -> ok.
sed -i 's/"title":"A"/"title":"A2"/' "$DP/src/_data/sites.json"
git -C "$DP" commit -qam metadata
ok "data_ok: metadata-only churn -> ok" \
  automerge_maintenance_tier_data_ok "$DP" "$BASE_SHA" "$(git -C "$DP" rev-parse HEAD)" "src/_data/sites.json" "$MTALLOW" "no-josh-visible"

# Added listing (new addedDate line, count grows) -> rejected.
git -C "$DP" reset -q --hard "$BASE_SHA"
cat > "$DP/src/_data/sites.json" <<'JSON'
[
  {"url":"https://a.example","addedDate":"2026-01-01","title":"A"},
  {"url":"https://b.example","addedDate":"2026-01-02","title":"B"},
  {"url":"https://n.example","addedDate":"2026-02-01","title":"New"}
]
JSON
git -C "$DP" commit -qam added
no "data_ok: added listing -> rejected" \
  automerge_maintenance_tier_data_ok "$DP" "$BASE_SHA" "$(git -C "$DP" rev-parse HEAD)" "src/_data/sites.json" "$MTALLOW" "no-josh-visible"

# Added listing that OMITS addedDate entirely -- the exact igor#516 security
# review gap (a textual "did an addedDate line appear" check would miss this;
# the core-identity structural compare does not).
git -C "$DP" reset -q --hard "$BASE_SHA"
cat > "$DP/src/_data/sites.json" <<'JSON'
[
  {"url":"https://a.example","addedDate":"2026-01-01","title":"A"},
  {"url":"https://b.example","addedDate":"2026-01-02","title":"B"},
  {"url":"https://n.example","title":"New, no addedDate"}
]
JSON
git -C "$DP" commit -qam added-no-addeddate
no "data_ok: added listing with no addedDate field -> still rejected" \
  automerge_maintenance_tier_data_ok "$DP" "$BASE_SHA" "$(git -C "$DP" rev-parse HEAD)" "src/_data/sites.json" "$MTALLOW" "no-josh-visible"

# Removed listing -> rejected.
git -C "$DP" reset -q --hard "$BASE_SHA"
echo '[{"url":"https://a.example","addedDate":"2026-01-01","title":"A"}]' > "$DP/src/_data/sites.json"
git -C "$DP" commit -qam removed
no "data_ok: removed listing -> rejected" \
  automerge_maintenance_tier_data_ok "$DP" "$BASE_SHA" "$(git -C "$DP" rev-parse HEAD)" "src/_data/sites.json" "$MTALLOW" "no-josh-visible"

# Same-count swap (one removed, a different one added) -> the core-identity
# set comparison catches this even though a bare element-count check would not.
git -C "$DP" reset -q --hard "$BASE_SHA"
cat > "$DP/src/_data/sites.json" <<'JSON'
[
  {"url":"https://a.example","addedDate":"2026-01-01","title":"A"},
  {"url":"https://swap.example","addedDate":"2026-02-01","title":"Swap"}
]
JSON
git -C "$DP" commit -qam swap
no "data_ok: same-count swap -> rejected" \
  automerge_maintenance_tier_data_ok "$DP" "$BASE_SHA" "$(git -C "$DP" rev-parse HEAD)" "src/_data/sites.json" "$MTALLOW" "no-josh-visible"

# Guard rejection gained (rejected.json) -> rejected, even reformatted onto
# one line (jq-structural, not a line count -- igor#516 security review).
git -C "$DP" reset -q --hard "$BASE_SHA"
printf '%s' '[{"url":"https://c.example","reason":"no-josh-visible"},{"url":"https://d.example","reason":"no-josh-visible"}]' > "$DP/src/_data/rejected.json"
git -C "$DP" commit -qam guard
no "data_ok: gained guard-rejection entry -> rejected" \
  automerge_maintenance_tier_data_ok "$DP" "$BASE_SHA" "$(git -C "$DP" rev-parse HEAD)" "src/_data/sites.json" "$MTALLOW" "no-josh-visible"

# A DROP in guard rejections is not itself suspicious (no listing implicated).
git -C "$DP" reset -q --hard "$BASE_SHA"
echo '[]' > "$DP/src/_data/rejected.json"
git -C "$DP" commit -qam unguard
ok "data_ok: fewer guard rejections -> ok" \
  automerge_maintenance_tier_data_ok "$DP" "$BASE_SHA" "$(git -C "$DP" rev-parse HEAD)" "src/_data/sites.json" "$MTALLOW" "no-josh-visible"

# igor#537/#558: the guard-rejection belt's FILE PATH stays hardcoded to
# AUTOMERGE_MAINTENANCE_REJECTED_FILE and applies ONLY when the repo's OWN
# allowlist opts that literal path in. A repo whose allowlist doesn't
# mention it gets no belt -- a gained guard-rejection entry is simply not
# evaluated, regardless of what rejected_category it passes (or doesn't).
git -C "$DP" reset -q --hard "$BASE_SHA"
printf '%s' '[{"url":"https://c.example","reason":"no-josh-visible"},{"url":"https://d.example","reason":"no-josh-visible"}]' > "$DP/src/_data/rejected.json"
git -C "$DP" commit -qam guard-unwatched
NOREJALLOW='["src/_data/sites.json"]'
ok "data_ok: gained guard-rejection entry is a no-op when allowlist omits rejected.json (igor#537)" \
  automerge_maintenance_tier_data_ok "$DP" "$BASE_SHA" "$(git -C "$DP" rev-parse HEAD)" "src/_data/sites.json" "$NOREJALLOW" ""

echo "== automerge_maintenance_tier_data_ok: belt is scoped to the DECLARED category, not hardcoded (igor#558) =="
# Same net-gain shape as above, but the fixture's rejected.json entries carry
# a DIFFERENT category ("off-brand") than joshing.you's. Proves the belt
# reads whatever category the caller passes, not a baked-in string.
git -C "$DP" reset -q --hard "$BASE_SHA"
echo '[{"url":"https://c.example","reason":"off-brand"}]' > "$DP/src/_data/rejected.json"
git -C "$DP" commit -qam other-category-base
OTHERCAT_BASE="$(git -C "$DP" rev-parse HEAD)"
printf '%s' '[{"url":"https://c.example","reason":"off-brand"},{"url":"https://d.example","reason":"off-brand"}]' > "$DP/src/_data/rejected.json"
git -C "$DP" commit -qam other-category-gain
OTHERCAT_HEAD="$(git -C "$DP" rev-parse HEAD)"
no "data_ok: net gain in the DECLARED category (off-brand) -> rejected" \
  automerge_maintenance_tier_data_ok "$DP" "$OTHERCAT_BASE" "$OTHERCAT_HEAD" "src/_data/sites.json" "$MTALLOW" "off-brand"
ok "data_ok: the SAME diff is a no-op against a category it doesn't touch (no-josh-visible)" \
  automerge_maintenance_tier_data_ok "$DP" "$OTHERCAT_BASE" "$OTHERCAT_HEAD" "src/_data/sites.json" "$MTALLOW" "no-josh-visible"
no "data_ok: rejected.json allowlisted but rejected_category empty -> fails closed (defensive)" \
  automerge_maintenance_tier_data_ok "$DP" "$OTHERCAT_BASE" "$OTHERCAT_HEAD" "src/_data/sites.json" "$MTALLOW" ""
# A 5-arg caller must REFUSE, not abort: `local x="$6"` under `set -u` kills
# the calling shell (the tick), turning a fail-closed gate into a crash. Run
# it in a subshell so a regression reads as a failed assertion here rather
# than taking this whole suite down with it -- and check stderr, since an
# unbound-variable abort exits nonzero too and rc alone can't tell them apart.
FIVEARG_RC=0
( automerge_maintenance_tier_data_ok "$DP" "$OTHERCAT_BASE" "$OTHERCAT_HEAD" "src/_data/sites.json" "$MTALLOW" ) \
  2>"$TMP/5arg.err" >/dev/null || FIVEARG_RC=$?
eq "data_ok: a 5-arg caller returns rc1" "1" "$FIVEARG_RC"
no "data_ok: a 5-arg caller fails closed, not an unbound-variable abort" \
  grep -q "unbound variable" "$TMP/5arg.err"

echo "== negative test: sever the belt trigger -> the net-gain case now merges (igor#558) =="
# Proves the belt is what refuses the classic net-gain fixture: with
# _automerge_maintenance_path_allowed stubbed to never match, the
# rejected.json branch is never entered, and the same diff that was refused
# above (with the belt intact) now passes.
_automerge_maintenance_path_allowed() { return 1; }
ok "severed: identical net-gain fixture now merges once the belt-trigger is stubbed off" \
  automerge_maintenance_tier_data_ok "$DP" "$OTHERCAT_BASE" "$OTHERCAT_HEAD" "src/_data/sites.json" "$MTALLOW" "off-brand"
_automerge_maintenance_path_allowed() { _real_maintenance_path_allowed "$@"; }   # restore

echo "== do_automerge_tick: joshing.you maintenance-tier carve-out end to end (igor#516) =="
# Restore the REAL automerge_reviewer_blocks -- the review-gate section above
# permanently stubbed it to `return 1`, but this section needs it reading a
# live human REQUEST_CHANGES off _fj for the amendment-2 veto test below.
automerge_reviewer_blocks() { _real_reviewer_blocks "$@"; }
MTDIR="$(mktemp -d "$TMP/joshing.XXXXXX")"
git init -q -b master "$MTDIR"
git -C "$MTDIR" config user.email t@t; git -C "$MTDIR" config user.name t
mkdir -p "$MTDIR/src/_data"
echo '[{"url":"https://a.example","addedDate":"2026-01-01","title":"A"}]' > "$MTDIR/src/_data/sites.json"
echo '[]' > "$MTDIR/src/_data/rejected.json"
git -C "$MTDIR" add -A; git -C "$MTDIR" commit -q -m base
MTBASE="$(git -C "$MTDIR" rev-parse HEAD)"
sed -i 's/"title":"A"/"title":"A-updated"/' "$MTDIR/src/_data/sites.json"
git -C "$MTDIR" commit -qam metadata
MTHEAD="$(git -C "$MTDIR" rev-parse HEAD)"

MTPR=$(jq -n --arg h "$MTHEAD" --arg b "$MTBASE" \
  '{head:{ref:"review",sha:$h,repo:{full_name:"joshtronic/joshing.you"}},base:{ref:"master",sha:$b,repo:{full_name:"joshtronic/joshing.you"}}}')
MTREVIEWS='[]'
repo_path_for() { echo "$MTDIR"; }
ensure_repo_local() { :; }
_fj() {
  case "$1 $2" in
    "GET /repos/joshtronic/joshing.you/pulls/42")         printf '%s' "$MTPR" ;;
    "GET /repos/joshtronic/joshing.you/pulls/42/reviews") printf '%s' "$MTREVIEWS" ;;
    *) printf '{}' ;;
  esac
}
MTFILES='[{"filename":"src/_data/sites.json"}]'
forgejo_pr_files() { printf '%s' "$MTFILES"; }
# joshing.you's OWN dossier declaration (igor#537) -- automerge_maintenance_tier_ok
# now reads this via automerge_maintenance_declaration instead of matching a
# hardcoded repo constant.
forgejo_repo_get_file() { printf '%s' "$(jq -n --argjson d "$JY_DECL" '{automerge:{require_human:true,maintenance:$d}}')"; }

export VALIDATED_REPOS_JSON='{"full_name":"joshtronic/joshing.you"}'
automerge_url_status() { printf 'ok\thttps://joshing.you'; }
automerge_require_human() { [ "$1" = "joshtronic/joshing.you" ]; }
forgejo_list_open_bot_prs() { echo '[{"number":42}]'; }
forgejo_commit_status() { echo success; }
automerge_mergeable() { return 0; }
automerge_behind_count() { echo 0; }
automerge_do_merge() { echo "mtsha"; }
automerge_approved_by() { return 1; }   # no human review anywhere in this section

echo "{\"review\":{\"joshtronic/joshing.you#42\":{\"verdict\":\"APPROVE\",\"sha\":\"${MTHEAD}\"}}}" > "$STATE"
AUTOMERGE_OUT=$(do_automerge_tick 2>&1); AUTOMERGE_RC=$?
if [ "$AUTOMERGE_RC" -eq 0 ]; then printf '  + %s\n' "maint-tier: metadata-only + shadow APPROVE-on-head, no human -> merges"
else printf '  x %s\n' "maint-tier: metadata-only + shadow APPROVE-on-head, no human -> merges"; FAIL=$((FAIL + 1)); fi
eq "maint-tier: merge recorded deploy"   "joshtronic/joshing.you" "$(jq -r '.deploy.repo // ""' "$STATE")"
has "maint-tier: log names the tier"     "$AUTOMERGE_OUT" "maintenance-tier"
has "maint-tier: log says no human gate" "$AUTOMERGE_OUT" "merging without human gate"

# Amendment 1: an absent/non-APPROVE shadow verdict never qualifies -- falls
# back to the (unmet) human gate, no merge.
echo '{"review":{"joshtronic/joshing.you#42":{"verdict":"COMMENT"}}}' > "$STATE"
no "maint-tier: shadow COMMENT (not APPROVE) -> no merge" do_automerge_tick
eq "maint-tier: shadow-COMMENT records nothing" "" "$(jq -r '.deploy.repo // ""' "$STATE")"

# Amendment 2: a live human REQUEST_CHANGES vetoes the maintenance tier even
# though the diff and shadow verdict both qualify.
MTREVIEWS='[{"user":{"login":"josh"},"state":"REQUEST_CHANGES","stale":false,"dismissed":false}]'
echo "{\"review\":{\"joshtronic/joshing.you#42\":{\"verdict\":\"APPROVE\",\"sha\":\"${MTHEAD}\"}}}" > "$STATE"
no "maint-tier: live human REQUEST_CHANGES vetoes -> no merge" do_automerge_tick
eq "maint-tier: human-veto records nothing" "" "$(jq -r '.deploy.repo // ""' "$STATE")"
MTREVIEWS='[]'   # reset

# Non-review head branch -> falls back to the human gate (no human approve
# stubbed in this section, so it stays unmerged).
NRPR=$(jq -n --arg h "$MTHEAD" --arg b "$MTBASE" \
  '{head:{ref:"some-other-branch",sha:$h,repo:{full_name:"joshtronic/joshing.you"}},base:{ref:"master",sha:$b,repo:{full_name:"joshtronic/joshing.you"}}}')
_fj() {
  case "$1 $2" in
    "GET /repos/joshtronic/joshing.you/pulls/42")         printf '%s' "$NRPR" ;;
    "GET /repos/joshtronic/joshing.you/pulls/42/reviews") printf '%s' "$MTREVIEWS" ;;
    *) printf '{}' ;;
  esac
}
echo "{\"review\":{\"joshtronic/joshing.you#42\":{\"verdict\":\"APPROVE\",\"sha\":\"${MTHEAD}\"}}}" > "$STATE"
no "maint-tier: non-review head branch -> falls back to human gate, no merge" do_automerge_tick
eq "maint-tier: non-review branch recorded no deploy" "" "$(jq -r '.deploy.repo // ""' "$STATE")"

echo "== do_automerge_tick: maintenance tier requires the repo's OWN declaration (igor#537) =="
# The repo pin is no longer a hardcoded constant -- it's "does this repo's
# OWN agent.json declare a complete automerge.maintenance." Uses the REAL
# automerge_maintenance_tier_ok (not stubbed): a require_human repo that
# never declared the tier -- even with a metadata-only diff that would
# otherwise qualify -- still needs human approval.
export VALIDATED_REPOS_JSON='{"full_name":"acme/flagged"}'
automerge_url_status() { printf 'ok\thttps://x'; }
automerge_require_human() { return 0; }   # acme/flagged is require_human-pinned
forgejo_repo_get_file() { printf '%s' '{"automerge":{"require_human":true}}'; }   # NO .maintenance key
forgejo_list_open_bot_prs() { echo '[{"number":9}]'; }
forgejo_commit_status() { echo success; }
automerge_mergeable() { return 0; }
automerge_behind_count() { echo 0; }
automerge_do_merge() { echo "sha9"; }
_fj() { echo '{"head":{"sha":"head9"},"base":{"sha":"base9","ref":"master"}}'; }
automerge_approved_by() { return 1; }   # no human approval
echo '{"review":{"acme/flagged#9":{"verdict":"APPROVE","sha":"head9"}}}' > "$STATE"
no "maint-scope: require_human repo with no automerge.maintenance declared still needs human approval" do_automerge_tick
eq "maint-scope: no deploy recorded" "" "$(jq -r '.deploy.repo // ""' "$STATE")"

# The same repo, now WITH a complete declaration whose allowlist doesn't
# cover this PR's changed file (foo.txt isn't in the allowlist) -- proves
# a declaring repo still gets refused on a diff outside its OWN allowlist,
# not just an undeclared one.
OWNALLOW='{"branch":"review","allowlist":["src/_data/sites.json"],"data_file":"src/_data/sites.json"}'
forgejo_repo_get_file() { printf '%s' "$(jq -n --argjson d "$OWNALLOW" '{automerge:{require_human:true,maintenance:$d}}')"; }
forgejo_pr_files() { printf '%s' '[{"filename":"foo.txt"}]'; }
_fj() { echo '{"head":{"ref":"review","sha":"head9","repo":{"full_name":"acme/flagged"}},"base":{"ref":"master","sha":"base9","repo":{"full_name":"acme/flagged"}}}'; }
echo '{"review":{"acme/flagged#9":{"verdict":"APPROVE","sha":"head9"}}}' > "$STATE"
no "maint-scope: declared repo, out-of-allowlist file -> still needs human approval" do_automerge_tick
eq "maint-scope: out-of-allowlist diff recorded no deploy" "" "$(jq -r '.deploy.repo // ""' "$STATE")"

# The same repo, now WITH a complete declaration that opts rejected.json into
# its allowlist but declares no rejected_category (igor#558). The tier must
# refuse -- not silently skip the belt -- so this still needs human approval
# even though the diff itself only touches the (allowlisted) sites file.
NOCAT_OWNALLOW='{"branch":"review","allowlist":["src/_data/sites.json","src/_data/rejected.json"],"data_file":"src/_data/sites.json"}'
forgejo_repo_get_file() { printf '%s' "$(jq -n --argjson d "$NOCAT_OWNALLOW" '{automerge:{require_human:true,maintenance:$d}}')"; }
forgejo_pr_files() { printf '%s' '[{"filename":"src/_data/sites.json"}]'; }
_fj() { echo '{"head":{"ref":"review","sha":"head9","repo":{"full_name":"acme/flagged"}},"base":{"ref":"master","sha":"base9","repo":{"full_name":"acme/flagged"}}}'; }
echo '{"review":{"acme/flagged#9":{"verdict":"APPROVE","sha":"head9"}}}' > "$STATE"
no "maint-scope: rejected.json allowlisted with no rejected_category -> refused, not skipped" do_automerge_tick
eq "maint-scope: no-category refusal recorded no deploy" "" "$(jq -r '.deploy.repo // ""' "$STATE")"

if [ "$FAIL" -eq 0 ]; then echo "test-automerge: all checks passed"; exit 0; fi
echo "test-automerge: $FAIL check(s) FAILED"
exit 1
