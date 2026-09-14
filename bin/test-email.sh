#!/usr/bin/env bash
# test-email.sh -- unit tests for lib/email.sh's email_send: it must
# distinguish a transport failure (curl itself errored) from an HTTP-level
# rejection (SMTP2GO answered with a non-2xx or a "no delivery" body), and
# log the actual status + body for both -- see igor#633, where a bare
# "request to SMTP2GO failed" gave no way to diagnose a real failure.
# curl is doubled as a shell function (the pattern at bin/test-request.sh).
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "test-email: jq absent -- skipping"; exit 0; }

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/email.sh
. "$HERE/../lib/email.sh"

LOG_FILE=$(mktemp)
trap 'rm -f "$LOG_FILE"' EXIT
log() { printf '%s\n' "$*" >>"$LOG_FILE"; }

FAIL=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1: [$2] lacks [$3]" ;; esac; }

export SMTP2GO_API_KEY="super-secret-key"
export SMTP2GO_SENDER="bot@example.com"

echo "== email_send: success (HTTP 200, succeeded:1) =="
: >"$LOG_FILE"
curl() { printf '{"data":{"succeeded":1,"failed":0}}\n200'; return 0; }
email_send "subj" "<p>hi</p>" "hi" "a@example.com"
eq "returns 0" "0" "$?"
eq "logs nothing" "" "$(cat "$LOG_FILE")"
unset -f curl

echo "== email_send: transport failure (curl itself errors) =="
: >"$LOG_FILE"
curl() { echo "curl: (7) Failed to connect" >&2; return 7; }
email_send "subj" "<p>hi</p>" "hi" "a@example.com"
RC=$?
eq "returns nonzero" "1" "$RC"
has "log names the curl exit code" "$(cat "$LOG_FILE")" "curl exit 7"
has "log carries curl's own error text" "$(cat "$LOG_FILE")" "Failed to connect"
if grep -q "super-secret-key" "$LOG_FILE"; then
  bad "log never leaks the API key (transport failure)"
else
  ok "log never leaks the API key (transport failure)"
fi
unset -f curl

echo "== email_send: HTTP-level rejection (curl succeeds, SMTP2GO says 401) =="
: >"$LOG_FILE"
curl() { printf '{"error":"invalid API key"}\n401'; return 0; }
email_send "subj" "<p>hi</p>" "hi" "a@example.com"
RC=$?
eq "returns nonzero" "1" "$RC"
has "log carries the HTTP status" "$(cat "$LOG_FILE")" "401"
has "log carries the response body" "$(cat "$LOG_FILE")" "invalid API key"
if grep -q "super-secret-key" "$LOG_FILE"; then
  bad "log never leaks the API key (HTTP rejection)"
else
  ok "log never leaks the API key (HTTP rejection)"
fi
unset -f curl

echo "== email_send: HTTP 200 but SMTP2GO reports zero succeeded (a quota/oversize style rejection) =="
: >"$LOG_FILE"
curl() { printf '{"data":{"succeeded":0,"failed":1,"errors":["quota exceeded"]}}\n200'; return 0; }
email_send "subj" "<p>hi</p>" "hi" "a@example.com"
RC=$?
eq "returns nonzero" "1" "$RC"
has "log carries the HTTP status" "$(cat "$LOG_FILE")" "200"
has "log carries the reported error detail" "$(cat "$LOG_FILE")" "quota exceeded"
unset -f curl

echo "== email_send: no recipients -> skips the send entirely, curl never called =="
CURL_CALLED=0
curl() { CURL_CALLED=1; }
email_send "subj" "<p>hi</p>" "hi" " "
RC=$?
eq "returns nonzero" "1" "$RC"
eq "curl never invoked" "0" "$CURL_CALLED"
unset -f curl

[ "$FAIL" -eq 0 ] && { echo "test-email: all checks passed"; exit 0; }
echo "test-email: $FAIL check(s) FAILED"
exit 1
