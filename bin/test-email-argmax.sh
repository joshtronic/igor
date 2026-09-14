#!/usr/bin/env bash
# test-email-argmax.sh -- red-tests the ARG_MAX transport cliff (igor#635):
# lib/email.sh used to pass the whole JSON payload as a curl argv entry
# (`-d "$payload"`), so a payload larger than ARG_MAX made the kernel refuse
# to exec curl at all (E2BIG, curl exit 126) before any request could be
# attempted -- SMTP2GO never even saw it. Real curl is used here (not the
# shell-function double bin/test-email.sh uses) because argv-size is a
# kernel exec-time limit a mocked curl can't reproduce. EMAIL_API points at
# an unroutable loopback port so the test needs no network: with the body on
# stdin, curl execs fine and only fails to CONNECT (ECONNREFUSED); with the
# old argv path, curl never even execs.
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "test-email-argmax: jq absent -- skipping"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "test-email-argmax: curl absent -- skipping"; exit 0; }
command -v getconf >/dev/null 2>&1 || { echo "test-email-argmax: getconf absent -- skipping"; exit 0; }

HERE="$(cd "$(dirname "$0")" && pwd)"

export SMTP2GO_API_KEY="super-secret-key"
export SMTP2GO_SENDER="bot@example.com"
# Nothing listens here -- curl fails fast with ECONNREFUSED, no network needed.
export EMAIL_API="http://127.0.0.1:1/v3/email/send"

# shellcheck source=../lib/email.sh
. "$HERE/../lib/email.sh"

LOG_FILE=$(mktemp)
trap 'rm -f "$LOG_FILE"' EXIT
log() { printf '%s\n' "$*" >>"$LOG_FILE"; }

FAIL=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; FAIL=$((FAIL + 1)); }

ARG_MAX=$(getconf ARG_MAX 2>/dev/null || echo 2097152)
OVERSIZE=$((ARG_MAX + 200000))
BIG_BODY=$(printf '%*s' "$OVERSIZE" '' | tr ' ' 'a')

echo "== email_send: payload larger than ARG_MAX (${OVERSIZE} bytes) must not hit E2BIG =="
: >"$LOG_FILE"
email_send "subj" "<p>hi</p>" "$BIG_BODY" "a@example.com"
RC=$?

if [ "$RC" -eq 0 ]; then
  bad "unexpected success against an unroutable address"
else
  ok "returns nonzero (as expected -- nothing is listening)"
fi

if grep -q "Argument list too long" "$LOG_FILE" || grep -q "curl exit 126" "$LOG_FILE"; then
  bad "still dies with E2BIG (curl exit 126 / Argument list too long) -- body must go on stdin, not argv"
else
  ok "does not die with E2BIG -- payload is no longer a curl argv entry"
fi

if grep -q "curl exit 7" "$LOG_FILE" && grep -qi "connect" "$LOG_FILE"; then
  ok "fails at the connection stage instead (curl actually execs and tries the request)"
else
  bad "expected a connection-stage curl failure (exit 7, connection refused), got: $(cat "$LOG_FILE")"
fi

[ "$FAIL" -eq 0 ] && { echo "test-email-argmax: all checks passed"; exit 0; }
echo "test-email-argmax: $FAIL check(s) FAILED"
exit 1
