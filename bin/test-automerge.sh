#!/usr/bin/env bash
# test-automerge.sh -- unit tests for lib/automerge.sh: the smoke-url opt-in, the
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

echo "== smoke-url opt-in =="
forgejo_repo_get_file() { printf '%s\n' "https://porksicle.com"; }
eq "smoke_url: extracts the URL"          "https://porksicle.com" "$(automerge_smoke_url acme/site)"
eq "smoke_url: self repo never eligible"  ""                      "$(automerge_smoke_url "$AUTOMERGE_SELF_REPO")"
forgejo_repo_get_file() { return 1; }
eq "smoke_url: no file -> empty"          ""                      "$(automerge_smoke_url acme/site)"

echo "== approval / mergeable gates =="
_fj() { printf '%s' "$FJ"; }
FJ='[{"user":{"login":"josh"},"state":"APPROVED"}]'
ok "approved_by: josh APPROVED"            automerge_approved_by acme/x 1 josh
FJ='[{"user":{"login":"josh"},"state":"COMMENT"}]'
no "approved_by: only a COMMENT"           automerge_approved_by acme/x 1 josh
FJ='[{"user":{"login":"bot"},"state":"APPROVED"}]'
no "approved_by: someone else approved"    automerge_approved_by acme/x 1 josh
FJ='{"state":"open","mergeable":true}'
ok "mergeable: open + mergeable"           automerge_mergeable acme/x 1
FJ='{"state":"open","mergeable":false}'
no "mergeable: conflict"                   automerge_mergeable acme/x 1
FJ='{"state":"closed","mergeable":true}'
no "mergeable: closed"                     automerge_mergeable acme/x 1

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
seed() { jq -n --arg r "$1" --argjson a "${2:-0}" \
  '{deploy:{repo:$r,pr:"1",sha:"sha1",url:"https://x",smoke_attempts:$a}}' > "$STATE"; }

forgejo_commit_status() { echo pending; }
seed acme/x
ok "barrier: CI pending -> ends tick (rc0)"          do_deploy_barrier
eq "barrier: pending keeps .deploy"        "acme/x"  "$(jq -r '.deploy.repo // ""' "$STATE")"

forgejo_commit_status() { echo failure; }
seed acme/x; ALERTS=0
no "barrier: CI failure -> falls through (rc1)"       do_deploy_barrier
eq "barrier: CI failure alerted"           "1"       "$ALERTS"
eq "barrier: CI failure cleared .deploy"   ""        "$(jq -r '.deploy.repo // ""' "$STATE")"

forgejo_commit_status() { echo success; }
automerge_smoke() { return 0; }
seed acme/x; ALERTS=0
no "barrier: CI green + smoke ok -> falls through"    do_deploy_barrier
eq "barrier: healthy cleared .deploy"      ""        "$(jq -r '.deploy.repo // ""' "$STATE")"
eq "barrier: healthy did not alert"        "0"       "$ALERTS"

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

echo "== do_automerge_tick merge decision =="
export FORGEJO_REVIEWER=josh BOT_USER=igor
export VALIDATED_REPOS_JSON='{"full_name":"acme/site"}'
automerge_smoke_url() { echo "https://x"; }
forgejo_list_open_bot_prs() { echo '[{"number":7}]'; }
forgejo_commit_status() { echo success; }
automerge_mergeable() { return 0; }
automerge_do_merge() { echo "mergesha7"; }
_fj() { echo '{"head":{"sha":"headsha7"}}'; }

echo '{}' > "$STATE"; automerge_approved_by() { return 0; }
ok "automerge: all gates pass -> merges (rc0)"        do_automerge_tick
eq "automerge: recorded deploy repo"       "acme/site" "$(jq -r '.deploy.repo // ""' "$STATE")"
eq "automerge: recorded merge sha"         "mergesha7" "$(jq -r '.deploy.sha // ""' "$STATE")"

echo '{}' > "$STATE"; automerge_approved_by() { return 1; }
no "automerge: not approved -> no merge (rc1)"        do_automerge_tick
eq "automerge: not-approved records nothing" ""        "$(jq -r '.deploy.repo // ""' "$STATE")"

echo '{"review":{"acme/site#7":{"verdict":"REQUEST_CHANGES"}}}' > "$STATE"
automerge_approved_by() { return 0; }
no "automerge: shadow RC blocks merge (rc1)"          do_automerge_tick
eq "automerge: RC records nothing"          ""        "$(jq -r '.deploy.repo // ""' "$STATE")"

if [ "$FAIL" -eq 0 ]; then echo "test-automerge: all checks passed"; exit 0; fi
echo "test-automerge: $FAIL check(s) FAILED"
exit 1
