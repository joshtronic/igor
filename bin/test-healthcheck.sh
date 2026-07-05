#!/usr/bin/env bash
# test-healthcheck.sh -- unit tests for lib/healthcheck.sh (hc_ping).
#
# Covers:
#   - unset URL -> no-op, curl never invoked
#   - set URL -> builds the right request (base URL / /start / /fail)
#   - a curl failure never changes hc_ping's own return code
#
# Run standalone (`bin/test-healthcheck.sh`) or via `make test`.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/healthcheck.sh
. "$HERE/lib/healthcheck.sh"

FAIL=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi; }

echo "== hc_ping: unset URL -> no-op =="

CURL_CALLED=0
curl() { CURL_CALLED=1; }

unset HEALTHCHECK_HEARTBEAT_URL HEALTHCHECK_TASK_URL
hc_ping heartbeat
eq "heartbeat: curl not invoked when URL unset" "0" "$CURL_CALLED"

HEALTHCHECK_HEARTBEAT_URL=""
hc_ping heartbeat
eq "heartbeat: curl not invoked when URL empty" "0" "$CURL_CALLED"

HEALTHCHECK_TASK_URL=""
hc_ping task start
eq "task: curl not invoked when URL empty" "0" "$CURL_CALLED"

unset -f curl

echo "== hc_ping: URL set -> builds the right curl call =="

CURL_URL=""
curl() { CURL_URL="${*: -1}"; }

HEALTHCHECK_HEARTBEAT_URL="https://hc.example/ping/abc"
hc_ping heartbeat
eq "heartbeat: plain ping hits the base URL" "https://hc.example/ping/abc" "$CURL_URL"

HEALTHCHECK_TASK_URL="https://hc.example/ping/task"
hc_ping task start
eq "task start -> /start suffix" "https://hc.example/ping/task/start" "$CURL_URL"

hc_ping task success
eq "task success -> base URL" "https://hc.example/ping/task" "$CURL_URL"

hc_ping task fail
eq "task fail -> /fail suffix" "https://hc.example/ping/task/fail" "$CURL_URL"

hc_ping task
eq "task (state omitted) -> defaults to base URL (plain ping)" "https://hc.example/ping/task" "$CURL_URL"

unset -f curl

echo "== hc_ping: a curl failure never changes rc =="

curl() { return 1; }
hc_ping heartbeat
eq "curl failure -> hc_ping still rc0" "0" "$?"
unset -f curl

if [ "$FAIL" -eq 0 ]; then
  echo "test-healthcheck: all passed"
else
  echo "test-healthcheck: $FAIL FAILED"
  exit 1
fi
