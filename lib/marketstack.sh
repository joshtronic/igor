#!/usr/bin/env bash
# marketstack.sh -- marketstack EOD (end-of-day) API client for the
# daily market report. Isolates every marketstack network call, the way
# lib/gsc.sh does for Search Console. Sourced by bin/tick.sh.
#
# The market report is opt-in; callers gate on these being set:
#   MARKETSTACK_API_KEY, MARKET_SYMBOLS
# Requires on PATH: curl, jq.
#
# Uses the v2 API (the current marketstack surface; v1 is legacy).
# Auth model: marketstack takes the access key as a query-string param
# (access_key). On a paid plan the base URL is HTTPS, so the key is
# encrypted in transit; MARKETSTACK_BASE_URL can override it (e.g. to the
# free-tier HTTP host) but then the key crosses the wire in plaintext.

# Fallback logger so this module is sourceable standalone (tests).
if ! declare -F log >/dev/null; then
  log() { printf '[agent] %s\n' "$*"; }
fi

# Paid-plan v2 default; override via MARKETSTACK_BASE_URL for the
# HTTP-only free tier or a different API version. No trailing slash.
MARKETSTACK_BASE_URL="${MARKETSTACK_BASE_URL:-https://api.marketstack.com/v2}"

# marketstack_eod_latest <symbols_csv>
# Fetches the latest end-of-day bar for each symbol -- i.e. the most
# recent completed trading session (the "previous trading day": Friday's
# data on a Monday, the pre-holiday session after a market holiday). All
# symbols come back in ONE request (no per-symbol fan-out); the once-per-
# day gate in do_market_tick is the rate limit. EOD is not subject to
# the real-time endpoints' 1-call/minute throttle. limit=1000 (the API
# max) lifts the default 100-row pagination so a large MARKET_SYMBOLS
# list isn't silently truncated. Echoes the raw JSON response object
# ({ "data": [ {open,high,low,close,volume,symbol,exchange,date}, ... ] })
# on stdout. Echoes '{"data":[]}' and rc=1 on any failure so callers can
# branch on the row count rather than parse errors.
marketstack_eod_latest() {
  local symbols="$1" resp
  if [ -z "${MARKETSTACK_API_KEY:-}" ] || [ -z "$symbols" ]; then
    printf '%s' '{"data":[]}'; return 1
  fi
  resp=$(curl -fsS -G "$MARKETSTACK_BASE_URL/eod/latest" \
    --data-urlencode "access_key=${MARKETSTACK_API_KEY}" \
    --data-urlencode "symbols=${symbols}" \
    --data-urlencode "limit=1000" 2>/dev/null) || {
      log "marketstack: request to $MARKETSTACK_BASE_URL/eod/latest failed"
      printf '%s' '{"data":[]}'; return 1
    }
  # Guard against a non-JSON/empty body, and surface marketstack's own
  # error envelope ({ "error": {...} }) as a failure rather than passing
  # it downstream as "no data".
  if ! jq -e . >/dev/null 2>&1 <<<"$resp"; then
    log "marketstack: non-JSON response"
    printf '%s' '{"data":[]}'; return 1
  fi
  if jq -e '.error' >/dev/null 2>&1 <<<"$resp"; then
    log "marketstack: API error: $(jq -c '.error' <<<"$resp" 2>/dev/null)"
    printf '%s' '{"data":[]}'; return 1
  fi
  printf '%s' "$resp"
}
