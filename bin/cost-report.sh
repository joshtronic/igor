#!/usr/bin/env bash
# cost-report.sh -- slice the cost ledger.
#
# The ledger ($AGENT_STATE_DIR/cost-ledger.jsonl) is append-only
# JSONL, one line per model call. This script is read-only over it.
#
# Usage:
#   bin/cost-report.sh                  # last 7 days, daily totals
#   bin/cost-report.sh --day YYYY-MM-DD # that day, hourly breakout
#   bin/cost-report.sh --day today      # today so far, hourly breakout
#   bin/cost-report.sh --by-mode        # group by call_site (last 7d)
#   bin/cost-report.sh --by-model       # group by model (last 7d)
#   bin/cost-report.sh --by-mode --day YYYY-MM-DD     # combine
#
# Output: small text tables with right-aligned cents columns and a
# totals row. No JSON-output mode.

set -euo pipefail

AGENT_STATE_DIR="${AGENT_STATE_DIR:-$HOME/.local/state/agent}"
LEDGER="$AGENT_STATE_DIR/cost-ledger.jsonl"

MODE="default"       # default | by-mode | by-model
RANGE="last7"        # last7 | day
RANGE_DAY=""

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --day)
      RANGE="day"
      if [ "${2:-}" = "today" ]; then
        RANGE_DAY=$(date +%Y-%m-%d)
      else
        RANGE_DAY="${2:-}"
      fi
      [ -n "$RANGE_DAY" ] || { echo "--day requires YYYY-MM-DD or 'today'" >&2; exit 2; }
      shift 2
      ;;
    --by-mode)  MODE="by-mode"; shift ;;
    --by-model) MODE="by-model"; shift ;;
    -h|--help)  usage 0 ;;
    *) echo "unknown flag: $1" >&2; usage 2 ;;
  esac
done

if [ ! -f "$LEDGER" ]; then
  echo "no ledger at $LEDGER -- has any tick fired with cost tracking yet?" >&2
  exit 1
fi

# Range filter. Either entries from a specific day, or last 7 days.
if [ "$RANGE" = "day" ]; then
  RANGE_FILTER='select(.timestamp[:10] == $rday)'
  RANGE_LABEL="day $RANGE_DAY"
  RANGE_ARGS=(--arg rday "$RANGE_DAY")
else
  CUTOFF=$(date -u -d "7 days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
           || date -u -v-7d +%Y-%m-%dT%H:%M:%SZ)
  RANGE_FILTER='select(.timestamp >= $cutoff)'
  RANGE_LABEL="last 7 days"
  RANGE_ARGS=(--arg cutoff "$CUTOFF")
fi

# jq aggregation: pick the bucket key, group, sum -- emit TSV
# (key\tcalls\tusd) sorted by usd descending. awk just formats.
_aggregate() {
  local key_jq="$1"   # the jq expression for the bucket key
  jq -r --slurp "${RANGE_ARGS[@]}" "
    map($RANGE_FILTER)
    | group_by($key_jq)
    | map({k: (.[0] | $key_jq), calls: length, usd: (map(.usd) | add)})
    | sort_by(-.usd)
    | .[] | [.k, .calls, .usd] | @tsv
  " "$LEDGER" 2>/dev/null
}

# Format: header + rows + totals. AWK does the column alignment.
_format() {
  local header="$1" width="$2"
  awk -F'\t' -v header="$header" -v width="$width" '
    BEGIN {
      fmt_h = "  %-" width "s %8s %12s\n"
      fmt_r = "  %-" width "s %8d %12.4f\n"
      fmt_t = "  %-" width "s %8s %12.4f\n"
      printf fmt_h, header, "calls", "usd"
    }
    { printf fmt_r, $1, $2, $3; total += $3; calls += $2 }
    END { printf fmt_t, "TOTAL", calls, total }
  '
}

case "$MODE:$RANGE" in
  by-mode:*)
    echo "== cost by mode ($RANGE_LABEL) =="
    _aggregate '.call_site' | _format "mode" 22
    ;;
  by-model:*)
    echo "== cost by model ($RANGE_LABEL) =="
    _aggregate '.model' | _format "model" 32
    ;;
  default:day)
    echo "== cost by hour ($RANGE_LABEL) =="
    _aggregate '.timestamp[11:13]' | sort -k1 | _format "hour" 6
    ;;
  default:last7)
    echo "== cost by day ($RANGE_LABEL) =="
    _aggregate '.timestamp[:10]' | sort -k1 | _format "day" 12
    ;;
esac
