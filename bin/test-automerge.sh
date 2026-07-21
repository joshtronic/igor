#!/usr/bin/env bash
# test-automerge.sh -- unit tests for lib/automerge.sh: the agent.json opt-in, the
# approval/CI/mergeable gates, the live-URL smoke, the deploy-barrier state
# machine (the riskiest logic), and do_automerge_tick's merge decision. Skip-safe:
# needs jq; exits 0 with a notice if absent, like the other bin/test-*.sh. Every
# boundary (_fj, curl, forgejo_*, email) is stubbed -- no network, no real state.
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "test-automerge: jq absent -- skipping"; exit 0; }

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/automerge.sh
. "$HERE/../lib/automerge.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export AGENT_STATE_DIR="$TMP"
STATE="$TMP/discretionary-state.json"

FAIL=0
ok() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then printf '  + %s\n' "$d"; else printf '  x %s (expected rc0)\n' "$d"; FAIL=$((FAIL + 1)); fi; }
no() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then printf '  x %s (expected rc!=0)\n' "$d"; FAIL=$((FAIL + 1)); else printf '  + %s\n' "$d"; fi; }
eq() { if [ "$2" = "$3" ]; then printf '  + %s\n' "$1"; else printf '  x %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi; }
has() { case "$2" in *"$3"*) printf '  + %s\n' "$1" ;; *) printf '  x %s: [%s] lacks [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)) ;; esac; }

echo "== agent.json (.smoke.url) opt-in =="
forgejo_repo_get_file() { printf '%s' '{"smoke":{"url":"https://porksicle.com"}}'; }
eq "smoke_url: extracts .smoke.url"        "https://porksicle.com" "$(automerge_smoke_url acme/site)"
eq "smoke_url: self repo never eligible"   ""                      "$(automerge_smoke_url "$AUTOMERGE_SELF_REPO")"
forgejo_repo_get_file() { printf '%s' '{"feedback":{"csv":"x"}}'; }
eq "smoke_url: agent.json without .smoke -> empty" ""              "$(automerge_smoke_url acme/site)"
forgejo_repo_get_file() { return 1; }
eq "smoke_url: no agent.json -> empty"     ""                      "$(automerge_smoke_url acme/site)"

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
forgejo_repo_get_file() { printf '%s' '{"smoke":{"url":"x"}}'; }   # default (shadow-gated) repo
ok "will_take: default repo + APPROVE -> auto-merge takes it"     automerge_will_take acme/site APPROVE
no "will_take: default repo + COMMENT -> human still asked"       automerge_will_take acme/site COMMENT
no "will_take: default repo + REQUEST_CHANGES -> not a take"      automerge_will_take acme/site REQUEST_CHANGES
forgejo_repo_get_file() { printf '%s' '{"automerge":{"require_human":true}}'; }   # carve-out
no "will_take: carve-out + APPROVE -> human is the gate"          automerge_will_take acme/site APPROVE

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

echo "== do_automerge_tick merge decision =="
export FORGEJO_REVIEWER=josh BOT_USER=igor
export VALIDATED_REPOS_JSON='{"full_name":"acme/site"}'
automerge_smoke_url() { echo "https://x"; }
forgejo_list_open_bot_prs() { echo '[{"number":7}]'; }
forgejo_commit_status() { echo success; }
automerge_mergeable() { return 0; }
automerge_behind_count() { echo 0; }                       # up to date by default
automerge_update_branch() { UPDATED="$1#$2"; return 0; }
automerge_do_merge() { echo "mergesha7"; }
_fj() { echo '{"head":{"sha":"headsha7"}}'; }
automerge_require_human() { return 1; }      # default: shadow-gated repo
automerge_approved_by() { return 1; }        # no human review -> exercises the shadow path

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
automerge_approved_by() { return 1; }        # reset: no human for the sections below

echo "== do_automerge_tick multi-repo iteration (production stream shape) =="
# VALIDATED_REPOS_JSON is a NEWLINE-DELIMITED STREAM, not an array. The loop must
# iterate every line: skip the first repo (no agent.json -> ineligible) and merge
# the eligible second one. A single-object stub can't catch a broken iteration.
VALIDATED_REPOS_JSON="$(printf '%s\n%s\n' '{"full_name":"acme/first"}' '{"full_name":"acme/second"}')"
automerge_smoke_url() { case "$1" in acme/second) echo "https://x" ;; *) echo "" ;; esac; }
echo '{"review":{"acme/second#7":{"verdict":"APPROVE","sha":"headsha7"}}}' > "$STATE"
ok "automerge: iterates stream, skips ineligible, merges 2nd"  do_automerge_tick
eq "automerge: merged the eligible repo"   "acme/second" "$(jq -r '.deploy.repo // ""' "$STATE")"

echo "== do_automerge_tick: behind base -> update branch, do NOT merge =="
export VALIDATED_REPOS_JSON='{"full_name":"acme/site"}'
automerge_smoke_url() { echo "https://x"; }
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
automerge_smoke_url() { echo "https://x"; }
forgejo_list_open_bot_prs() { echo '[{"number":7}]'; }
automerge_approved_by() { return 0; }
automerge_behind_count() { echo 0; }
_fj() { echo '{"head":{"sha":"headsha7"}}'; }
MERGED=0; automerge_do_merge() { MERGED=1; echo "sha"; }
echo '{"review":{"acme/site#7":{"verdict":"APPROVE","sha":"headsha7"}}}' > "$STATE"
AUTOMERGE_BLOCK_COOLDOWN_SECS=3600
automerge_block_record "$STATE" "acme/site#7" "headsha7" "HTTP 405: nope"
AUTOMERGE_OUT=$(do_automerge_tick 2>&1); AUTOMERGE_RC=$?
if [ "$AUTOMERGE_RC" -ne 0 ]; then printf '  + %s\n' "automerge: active block -> no merge (rc1)"
else printf '  x %s\n' "automerge: active block -> no merge (rc1)"; FAIL=$((FAIL + 1)); fi
eq "automerge: active block did NOT call automerge_do_merge" "0" "$MERGED"
has "automerge: active block logs the skip"     "$AUTOMERGE_OUT" "still backing off a prior rejected merge"

echo "== do_automerge_tick: review-gate paths (human-flagged vs default) =="
export VALIDATED_REPOS_JSON='{"full_name":"acme/site"}'
automerge_smoke_url() { echo "https://x"; }
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

if [ "$FAIL" -eq 0 ]; then echo "test-automerge: all checks passed"; exit 0; fi
echo "test-automerge: $FAIL check(s) FAILED"
exit 1
