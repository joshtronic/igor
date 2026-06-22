#!/usr/bin/env bash
# market-probe.sh -- ad-hoc inspector for the marketstack EOD data that
# feeds the daily market report. Hits the SAME v2 endpoints the harness
# uses (see lib/marketstack.sh) and prints the raw payload so the operator
# can eyeball it. It does NOT build or send the email and touches no
# state -- purely read-only against the metered API.
#
# Credentials/symbols come from the environment; if MARKETSTACK_API_KEY or
# MARKET_SYMBOLS aren't already exported it sources the repo's .env (the
# same file tick.sh reads), so on the host you can just run it.
#
# Usage:
#   bin/market-probe.sh [date_from] [date_to]
# Dates are YYYY-MM-DD. Defaults: a ~5-day window ending today, which
# spans a holiday weekend so you can see the gap.
#
# Requires on PATH: curl, jq.

set -euo pipefail

AGENT_HOME="$(cd "$(dirname "$0")/.." && pwd)"

# Pull key/symbols from .env only if the caller didn't already export them
# -- mirrors how tick.sh loads the same file.
if [ -z "${MARKETSTACK_API_KEY:-}" ] || [ -z "${MARKET_SYMBOLS:-}" ]; then
  if [ -f "$AGENT_HOME/.env" ]; then
    set -a
    # shellcheck source=/dev/null
    . "$AGENT_HOME/.env"
    set +a
  fi
fi

: "${MARKETSTACK_API_KEY:?set MARKETSTACK_API_KEY (or add it to $AGENT_HOME/.env)}"
: "${MARKET_SYMBOLS:?set MARKET_SYMBOLS (or add it to $AGENT_HOME/.env)}"

# Same default base URL as lib/marketstack.sh; override for the free tier.
BASE_URL="${MARKETSTACK_BASE_URL:-https://api.marketstack.com/v2}"

# Portable date helpers (GNU date on the Linux host, BSD date on macOS
# dev), mirroring the fallback pattern in tick.sh.
days_ago() {  # days_ago N -> YYYY-MM-DD
  date -d "-$1 days" +%F 2>/dev/null || date -v-"$1"d +%F 2>/dev/null
}
last_friday() {  # most recent Friday on or before today -> YYYY-MM-DD
  local dow back
  dow=$(date +%u)            # 1=Mon .. 7=Sun
  back=$(( (dow - 5 + 7) % 7 ))
  days_ago "$back"
}

FROM="${1:-$(days_ago 5)}"
TO="${2:-$(date +%F)}"
SPOTLIGHT="$(last_friday)"

# ms_get <path> [extra curl args...]
# Always sends access_key + symbols + limit=1000 (the harness's params).
# Uses -sS (not -f) so marketstack's own error envelope is shown, not
# swallowed -- seeing the error body is the point of a probe.
ms_get() {
  curl -sS -G "$BASE_URL/$1" \
    --data-urlencode "access_key=$MARKETSTACK_API_KEY" \
    --data-urlencode "symbols=$MARKET_SYMBOLS" \
    --data-urlencode "limit=1000" "${@:2}"
}

echo "== marketstack probe =="
echo "base:      $BASE_URL"
echo "symbols:   $MARKET_SYMBOLS"
echo "range:     $FROM .. $TO"
echo "spotlight: $SPOTLIGHT (most recent Friday)"
echo

echo "== 1) /eod/latest -- what Monday's tick fetches (most recent completed bar per symbol) =="
ms_get "eod/latest" | jq . || echo "  (request failed -- see error above)"
echo

echo "== 2) /eod for $SPOTLIGHT -- holiday/closed-day spotlight (a bar? empty? stale dupe?) =="
ms_get "eod" \
  --data-urlencode "date_from=$SPOTLIGHT" \
  --data-urlencode "date_to=$SPOTLIGHT" | jq . || echo "  (request failed -- see error above)"
echo

echo "== 3) /eod range $FROM .. $TO -- one line per bar, sorted =="
ms_get "eod" \
  --data-urlencode "date_from=$FROM" \
  --data-urlencode "date_to=$TO" \
  | jq -r '(.data // [])[] | "\(.date[0:10])  \(.symbol)  O=\(.open) H=\(.high) L=\(.low) C=\(.close) vol=\(.volume)"' \
  | sort || echo "  (request failed -- see error above)"
echo

echo "(no email sent, no state changed)"
