#!/usr/bin/env bash
# send-market-email.sh -- send the market report NOW from the latest
# completed EOD session, ignoring every schedule gate. Use it to recover a
# day the automated tick skips -- e.g. the holiday-naive freshness gate
# holds the Monday after a Friday holiday and no report goes out.
#
# Independent of the scheduled send by design:
#   - It touches NO state file (discretionary-state.json). It can't flip
#     the daily "sent" flag, so it can neither block nor double-count a
#     scheduled send -- the cron path behaves exactly as if this never ran.
#   - It only SOURCES the shared libs (read-only) to reuse the exact
#     fetch/build/render/email logic.
#   - It always sends, regardless of whether today's scheduled report
#     already went out.
#
# Config comes from the environment, falling back to the repo's .env (the
# same file tick.sh reads): MARKETSTACK_API_KEY, MARKET_SYMBOLS,
# MARKET_RECIPIENTS, SMTP2GO_API_KEY, SMTP2GO_SENDER.
#
# Usage:
#   bin/send-market-email.sh            # send
#   bin/send-market-email.sh --dry-run  # render + print, don't send
#
# Requires on PATH: curl, jq.

set -euo pipefail

AGENT_HOME="$(cd "$(dirname "$0")/.." && pwd)"

dry_run=0
case "${1:-}" in
  --dry-run|-n) dry_run=1 ;;
  "")           ;;
  *) echo "usage: $(basename "$0") [--dry-run]" >&2; exit 2 ;;
esac

# Load .env if the vars aren't already exported (mirrors tick.sh).
if [ -z "${MARKETSTACK_API_KEY:-}" ]; then
  if [ -f "$AGENT_HOME/.env" ]; then
    set -a
    # shellcheck source=/dev/null
    . "$AGENT_HOME/.env"
    set +a
  fi
fi

: "${MARKETSTACK_API_KEY:?set MARKETSTACK_API_KEY (or add it to $AGENT_HOME/.env)}"
: "${MARKET_SYMBOLS:?set MARKET_SYMBOLS (or add it to $AGENT_HOME/.env)}"
: "${MARKET_RECIPIENTS:?set MARKET_RECIPIENTS (or add it to $AGENT_HOME/.env)}"
: "${SMTP2GO_API_KEY:?set SMTP2GO_API_KEY (or add it to $AGENT_HOME/.env)}"
: "${SMTP2GO_SENDER:?set SMTP2GO_SENDER (or add it to $AGENT_HOME/.env)}"

log() { printf '[market-send] %s\n' "$*" >&2; }

# shellcheck source=../lib/marketstack.sh
. "$AGENT_HOME/lib/marketstack.sh"
# shellcheck source=../lib/market-report.sh
. "$AGENT_HOME/lib/market-report.sh"
# shellcheck source=../lib/email.sh
. "$AGENT_HOME/lib/email.sh"

today=$(date +%F)
log "fetching latest EOD for ${MARKET_SYMBOLS}"
eod=$(marketstack_eod_latest "$MARKET_SYMBOLS") || eod='{"data":[]}'
report=$(market_build_report "$eod" "$MARKET_SYMBOLS")
report=$(jq --arg today "$today" '. + {report_date: $today}' <<<"$report")

if [ "$(jq -r '.count // 0' <<<"$report")" -eq 0 ]; then
  echo "market-send: no EOD rows returned for ${MARKET_SYMBOLS} -- nothing to send" >&2
  exit 1
fi

session=$(jq -r '.session_date // "unknown"' <<<"$report")
subject="[Market] $(date -d "$today" +'%A, %B %-d, %Y' 2>/dev/null || echo "$today")"
md=$(market_render_markdown <<<"$report")
html=$(market_render_html <<<"$report")

if [ "$dry_run" -eq 1 ]; then
  printf 'Subject: %s\nTo:      %s\nSession: %s\n\n%s\n' \
    "$subject" "$MARKET_RECIPIENTS" "$session" "$md"
  echo "(dry run -- no email sent)" >&2
  exit 0
fi

if email_send "$subject" "$html" "$md" "$MARKET_RECIPIENTS"; then
  log "emailed report (${session}) to ${MARKET_RECIPIENTS}"
else
  echo "market-send: email send FAILED -- see log above" >&2
  exit 1
fi
