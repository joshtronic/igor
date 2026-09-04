#!/usr/bin/env bash
# test-request.sh -- unit tests for lib/request.sh, the caching,
# backing-off HTTP GET/HEAD layer. No network: curl is doubled as a
# shell function, the pattern already used at bin/test-forgejo.sh:27.
# Call/sleep counts are recorded to temp FILES rather than shell
# variables: most assertions capture request_get/request_fetch's stdout
# via `$(...)`, which forks the whole call into a subshell, so any plain
# variable the doubled curl()/sleep() would increment is lost the moment
# that subshell exits. A file write survives it.
# Skip-safe: needs mktemp; exits 0 with a notice if absent (should
# always be present, but mirrors the repo's skip-safe convention).
set -uo pipefail

command -v mktemp >/dev/null 2>&1 || { echo "test-request: mktemp absent -- skipping"; exit 0; }

HERE="$(cd "$(dirname "$0")" && pwd)"

TMP_STATE=$(mktemp -d)
CURL_LOG=$(mktemp)
CURL_ARGS_LOG=$(mktemp)
SLEEP_LOG=$(mktemp)
trap 'rm -rf "$TMP_STATE" "$CURL_LOG" "$CURL_ARGS_LOG" "$SLEEP_LOG"' EXIT
export AGENT_STATE_DIR="$TMP_STATE"

# shellcheck source=../lib/request.sh
. "$HERE/../lib/request.sh"

FAIL=0
eq() {  # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then printf '  + %s\n' "$1"
  else printf '  x %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi
}

# -- curl double ------------------------------------------------------
# Scripted per-call via parallel arrays, indexed by call number (0-based,
# derived from how many lines are already in CURL_LOG). CURL_RCS: curl's
# own exit code for that call (0 = transport succeeded). CURL_CODES /
# CURL_BODIES: the HTTP status + body for a successful call. CURL_HEADERS:
# raw bytes written to the -D header file for that call. Separate arrays
# (rather than one delimited string) so a JSON body's own colons/newlines
# never collide with the encoding. These arrays are only ever READ inside
# curl(), populated by the test before the call, so the subshell-visibility
# problem above doesn't apply to them -- a subshell inherits a snapshot of
# the parent's variables at fork time.
CURL_RCS=()
CURL_CODES=()
CURL_BODIES=()
CURL_HEADERS=()
curl() {
  local args=("$@") header_file="" i idx
  for ((i = 0; i < ${#args[@]}; i++)); do
    [ "${args[$i]}" = "-D" ] && header_file="${args[$((i + 1))]}"
  done
  idx=$(wc -l <"$CURL_LOG" | tr -d '[:space:]')
  echo "$idx" >>"$CURL_LOG"
  printf '%s\n' "$*" >>"$CURL_ARGS_LOG"
  [ -n "$header_file" ] && printf '%s' "${CURL_HEADERS[$idx]:-}" >"$header_file"
  local rc="${CURL_RCS[$idx]:-0}"
  [ "$rc" != "0" ] && return "$rc"
  printf '%s\n%s' "${CURL_BODIES[$idx]:-}" "${CURL_CODES[$idx]:-200}"
  return 0
}
sleep() { echo "$1" >>"$SLEEP_LOG"; }

# tr -d: BSD/macOS wc pads its count with leading spaces, which would
# break the string comparisons in eq().
curl_calls() { wc -l <"$CURL_LOG" | tr -d '[:space:]'; }
curl_args_at() { sed -n "$(($1 + 1))p" "$CURL_ARGS_LOG"; }
sleep_at() { sed -n "$(($1 + 1))p" "$SLEEP_LOG"; }

# has_arg <argline> <flag...> -- "true" when the flag sequence appears as
# whole words in that call's argv.
has_arg() {
  local line=" $1 " needle=" ${*:2} "
  [[ "$line" == *"$needle"* ]] && echo true || echo false
}

reset_mocks() {
  : >"$CURL_LOG"
  : >"$CURL_ARGS_LOG"
  : >"$SLEEP_LOG"
  CURL_RCS=()
  CURL_CODES=()
  CURL_BODIES=()
  CURL_HEADERS=()
}

echo "== request_get: 200 returns the body, exactly one call =="
reset_mocks
CURL_RCS=(0)
CURL_CODES=(200)
CURL_BODIES=('{"ok":true}')
OUT=$(request_get "http://x.test/a" 0)
eq "body returned" '{"ok":true}' "$OUT"
eq "exactly one curl call" "1" "$(curl_calls)"

echo "== request_fetch GET: transport failure retries to the bound, then fails =="
reset_mocks
CURL_RCS=(7 7 7)
request_fetch GET "http://x.test/b" 0 >/dev/null
RC=$?
eq "nonzero rc after exhausting retries" "true" "$([ "$RC" -ne 0 ] && echo true || echo false)"
eq "attempt bound is 1 + REQUEST_RETRY_COUNT" "$((REQUEST_RETRY_COUNT + 1))" "$(curl_calls)"

echo "== request_fetch GET: a 404 makes exactly one call (an answer, not a hiccup) =="
reset_mocks
CURL_RCS=(0)
CURL_CODES=(404)
CURL_BODIES=("not found")
request_fetch GET "http://x.test/c" 0 >/dev/null
RC=$?
eq "nonzero rc on 404" "true" "$([ "$RC" -ne 0 ] && echo true || echo false)"
eq "exactly one call -- 404 is not retried" "1" "$(curl_calls)"

echo "== request_fetch GET: a 429 is retried, honouring Retry-After =="
reset_mocks
CURL_RCS=(0 0)
CURL_CODES=(429 200)
CURL_BODIES=("rate limited" '{"ok":1}')
CURL_HEADERS=($'Retry-After: 7\r\n' "")
OUT=$(request_fetch GET "http://x.test/d" 0)
eq "body from the retried attempt" '{"ok":1}' "$OUT"
eq "exactly two calls" "2" "$(curl_calls)"
eq "slept the Retry-After value (7), not the default backoff (1)" "7" "$(sleep_at 0)"

echo "== request_fetch GET: backoff grows between attempts =="
reset_mocks
CURL_RCS=(7 7 7)
request_fetch GET "http://x.test/e" 0 >/dev/null 2>&1
eq "first delay" "1" "$(sleep_at 0)"
eq "second delay grows past the first" "2" "$(sleep_at 1)"

echo "== request_get: a second call inside the TTL makes zero curl calls =="
reset_mocks
CURL_RCS=(0)
CURL_CODES=(200)
CURL_BODIES=("cached-body")
OUT1=$(request_get "http://x.test/f" 60)
CALLS_AFTER_FIRST=$(curl_calls)
OUT2=$(request_get "http://x.test/f" 60)
eq "same body served from cache" "$OUT1" "$OUT2"
eq "first call fetched once" "1" "$CALLS_AFTER_FIRST"
eq "second call made zero additional curl calls" "$CALLS_AFTER_FIRST" "$(curl_calls)"

echo "== request_get: a call after the TTL expires refetches =="
reset_mocks
CURL_RCS=(0 0)
CURL_CODES=(200 200)
CURL_BODIES=("first-body" "second-body")
OUT1=$(request_get "http://x.test/g" 1000)
KEY=$(_request_cache_key GET "http://x.test/g")
# Backdate the cache's fetch stamp well past the TTL instead of sleeping in
# a test -- same effect, no wall-clock cost.
echo 1 >"$(_request_cache_dir)/$KEY.meta"
OUT2=$(request_get "http://x.test/g" 1000)
eq "first fetch body" "first-body" "$OUT1"
eq "expired entry refetched" "second-body" "$OUT2"
eq "exactly two curl calls total" "2" "$(curl_calls)"

echo "== request_get: a failed fetch never falls back to a stale cache entry =="
reset_mocks
CURL_RCS=(0)
CURL_CODES=(200)
CURL_BODIES=("stale-body")
OUT1=$(request_get "http://x.test/h" 1000)
KEY=$(_request_cache_key GET "http://x.test/h")
echo 1 >"$(_request_cache_dir)/$KEY.meta"
reset_mocks
CURL_RCS=(7 7 7)
OUT2=$(request_get "http://x.test/h" 1000)
RC=$?
eq "priming fetch got the stale body" "stale-body" "$OUT1"
eq "failed refetch returns nonzero" "true" "$([ "$RC" -ne 0 ] && echo true || echo false)"
eq "failed refetch does not serve the stale body" "true" "$([ "$OUT2" != "stale-body" ] && echo true || echo false)"

echo "== request_fetch POST: never retried, even on a transport failure =="
reset_mocks
CURL_RCS=(7)
request_fetch POST "http://x.test/i" 0 >/dev/null 2>&1
RC=$?
eq "nonzero rc" "true" "$([ "$RC" -ne 0 ] && echo true || echo false)"
eq "exactly one call -- POST is never retried" "1" "$(curl_calls)"

echo "== request_fetch HEAD: sends -I, never -X HEAD =="
# -X HEAD leaves curl expecting a body the server never sends, so the
# call only unblocks when --max-time trips -- curl exit 28, which is in
# REQUEST_RETRY_CURL_CODES, so every HEAD would burn the full retry
# budget and report a transport failure that never happened.
reset_mocks
CURL_RCS=(0)
CURL_CODES=(200)
CURL_BODIES=("")
request_fetch HEAD "http://x.test/j" 0 >/dev/null
eq "exactly one call" "1" "$(curl_calls)"
ARGS=$(curl_args_at 0)
eq "passes -I" "true" "$(has_arg "$ARGS" -I)"
eq "does not pass -X HEAD" "false" "$(has_arg "$ARGS" -X HEAD)"
eq "discards the header block -I writes to stdout" "true" "$(has_arg "$ARGS" -o /dev/null)"

echo "== request_fetch GET: sends -X GET, never -I =="
reset_mocks
CURL_RCS=(0)
CURL_CODES=(200)
CURL_BODIES=("body")
request_fetch GET "http://x.test/j2" 0 >/dev/null
ARGS=$(curl_args_at 0)
eq "passes -X GET" "true" "$(has_arg "$ARGS" -X GET)"
eq "does not pass -I" "false" "$(has_arg "$ARGS" -I)"

echo "== request_fetch HEAD: retries a transport failure like a GET =="
reset_mocks
CURL_RCS=(7 7 7)
request_fetch HEAD "http://x.test/k" 0 >/dev/null 2>&1
eq "attempt bound is 1 + REQUEST_RETRY_COUNT" "$((REQUEST_RETRY_COUNT + 1))" "$(curl_calls)"

echo "== request_fetch HEAD: never cached, even with a TTL =="
# A HEAD has no body to serve back, so a cache entry would only ever
# replay "some HEAD succeeded recently" as an empty body.
reset_mocks
CURL_RCS=(0 0)
CURL_CODES=(200 200)
request_fetch HEAD "http://x.test/l" 60 >/dev/null
request_fetch HEAD "http://x.test/l" 60 >/dev/null
eq "second call refetched" "2" "$(curl_calls)"

echo "== request_get: a cache hit and a live fetch print identically =="
reset_mocks
CURL_RCS=(0)
CURL_CODES=(200)
CURL_BODIES=("line-body")
request_get "http://x.test/m" 60 >"$TMP_STATE/live.out"
request_get "http://x.test/m" 60 >"$TMP_STATE/hit.out"
eq "zero curl calls on the hit" "1" "$(curl_calls)"
eq "byte-identical output" "true" \
  "$(cmp -s "$TMP_STATE/live.out" "$TMP_STATE/hit.out" && echo true || echo false)"

echo "=========================================="
if [ "$FAIL" -eq 0 ]; then
  echo "test-request: all checks passed"
  exit 0
else
  echo "test-request: $FAIL check(s) failed"
  exit 1
fi
