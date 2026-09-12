#!/usr/bin/env bash
# test-cost.sh -- unit tests for lib/cost.sh's cost_record_cli parse (igor#612:
# the CLI reordered the result event's JSON keys, and a text-anchored grep on
# `^\{"type":"result"` silently stopped matching for seven weeks). Pins the
# parse against BOTH the current key order and a shuffled one, so the next
# reorder can't repeat the bug -- and pins the warn-once behavior on a
# missing/malformed log, so the failure mode is visible instead of silent.
#
# Skip-safe: needs jq; exits 0 with a notice if absent, like the other
# bin/test-*.sh.
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "test-cost: jq absent -- skipping"; exit 0; }

HERE="$(cd "$(dirname "$0")/.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export AGENT_STATE_DIR="$TMP/state"
mkdir -p "$AGENT_STATE_DIR"

LOGFILE="$TMP/log.txt"
log() { printf '[agent] %s\n' "$*" >> "$LOGFILE"; }

# shellcheck source=lib/cost.sh
. "$HERE/lib/cost.sh"

FAIL=0
eq() { if [ "$2" = "$3" ]; then printf '  + %s\n' "$1"; else printf '  x %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi; }
ok() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then printf '  + %s\n' "$d"; else printf '  x %s (expected rc0)\n' "$d"; FAIL=$((FAIL + 1)); fi; }

# A real result event, current key order (from a preserved igor#612 crash
# log): is_error, duration_api_ms, num_turns, stop_reason, session_id,
# total_cost_usd, usage, modelUsage, permission_denials, terminal_reason,
# fast_mode_state, fast_mode_disabled_reason, subtype, errors, type,
# duration_ms, uuid -- `type` is the 15th key, not the 1st.
CURRENT_ORDER='{"is_error":false,"duration_api_ms":1000,"num_turns":4,"stop_reason":"end_turn","session_id":"sess-1","total_cost_usd":9.427110749999999,"usage":{"input_tokens":100,"output_tokens":200,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"modelUsage":{},"permission_denials":[],"terminal_reason":"normal","fast_mode_state":"off","fast_mode_disabled_reason":null,"subtype":"success","errors":[],"type":"result","duration_ms":1200,"uuid":"u-1","model":"claude-sonnet-4-6"}'

# The same event, keys shuffled into a different order again -- pins that the
# parse depends on no particular position, not just "not position 1".
SHUFFLED_ORDER='{"uuid":"u-2","model":"claude-sonnet-4-6","type":"result","total_cost_usd":3.5,"usage":{"input_tokens":50,"output_tokens":75,"cache_creation_input_tokens":1,"cache_read_input_tokens":2},"is_error":false,"session_id":"sess-2"}'

echo "== cost_record_cli: parses the result event regardless of key order =="

STREAM1="$TMP/stream1.jsonl"
{
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}'
  printf '%s\n' "$CURRENT_ORDER"
} > "$STREAM1"
cost_record_cli "tier-1-issue" "$STREAM1"
LINE1=$(tail -1 "$COST_LEDGER_PATH")
eq "current key order: call_site recorded"  "tier-1-issue"           "$(jq -r '.call_site' <<<"$LINE1")"
eq "current key order: usd recorded"        "9.427110749999999"      "$(jq -r '.usd' <<<"$LINE1")"
eq "current key order: model recorded"      "claude-sonnet-4-6"      "$(jq -r '.model' <<<"$LINE1")"
eq "current key order: input tokens"        "100"                    "$(jq -r '.input_tokens' <<<"$LINE1")"

STREAM2="$TMP/stream2.jsonl"
printf '%s\n' "$SHUFFLED_ORDER" > "$STREAM2"
cost_record_cli "review" "$STREAM2"
LINE2=$(tail -1 "$COST_LEDGER_PATH")
eq "shuffled key order: call_site recorded" "review" "$(jq -r '.call_site' <<<"$LINE2")"
eq "shuffled key order: usd recorded"       "3.5"    "$(jq -r '.usd' <<<"$LINE2")"
eq "shuffled key order: output tokens"      "75"     "$(jq -r '.output_tokens' <<<"$LINE2")"

echo "== cost_record_cli: a single-object envelope (claude_call's --output-format json path) parses too =="
STREAM3="$TMP/stream3.jsonl"
printf '%s' "$CURRENT_ORDER" > "$STREAM3"   # one object, no trailing newline, no other lines
cost_record_cli "security" "$STREAM3" "fallback-model"
LINE3=$(tail -1 "$COST_LEDGER_PATH")
eq "envelope: usd recorded" "9.427110749999999" "$(jq -r '.usd' <<<"$LINE3")"

echo "== cost_record_cli: a result event AFTER plain-text stderr still parses =="
# The stream log is `claude ... 2>&1`, so the CLI's plain-text output (auth
# failure, rate-limit notice, node warning) is interleaved with the JSONL. A
# whole-file `jq 'select(...)'` aborts on the first non-JSON byte and STOPS
# READING, so a result event printed after any such line would be silently
# missed -- the same silent-parse-failure class igor#612 is about.
STREAM4="$TMP/stream4.jsonl"
{
  printf '%s\n' 'API Error: Connection error.'
  printf '%s\n' '(node:1234) Warning: something deprecated'
  printf '%s\n' '{"type":"assistant","message":{"content":[]}}'
  printf '%s\n' "$SHUFFLED_ORDER"
} > "$STREAM4"
cost_record_cli "mixed-content" "$STREAM4"
LINE4=$(tail -1 "$COST_LEDGER_PATH")
eq "leading non-JSON: call_site recorded" "mixed-content" "$(jq -r '.call_site' <<<"$LINE4")"
eq "leading non-JSON: usd still recorded" "3.5"           "$(jq -r '.usd' <<<"$LINE4")"

echo "== cost_record_cli: a pretty-printed single-object envelope parses =="
# claude_call captures `--output-format json` verbatim; if the CLI ever
# pretty-prints that envelope it spans lines, which the line-oriented pass
# can't read. The whole-file fallback covers it.
STREAM5="$TMP/stream5.json"
jq -n --argjson e "$CURRENT_ORDER" '$e' > "$STREAM5"   # multi-line, indented
eq "envelope really is multi-line" "true" "$([ "$(wc -l < "$STREAM5")" -gt 1 ] && echo true || echo false)"
cost_record_cli "pretty-envelope" "$STREAM5" "fallback-model"
LINE5=$(tail -1 "$COST_LEDGER_PATH")
eq "pretty envelope: usd recorded" "9.427110749999999" "$(jq -r '.usd' <<<"$LINE5")"

echo "== cost_result_event: a valid-JSON NON-OBJECT line doesn't hide the result event =="
# `fromjson?` guards the PARSE but not the INDEX. A stream-log line can be
# valid JSON and still not be an object (a bare number, a quoted string), and
# `.type` on those raises -- jq 1.7 reports the error and reads on, jq 1.6
# (what CI runs) is less forgiving. `objects` drops them before the index.
STREAM6="$TMP/stream6.jsonl"
{
  printf '%s\n' '42'
  printf '%s\n' '"a bare json string"'
  printf '%s\n' "$SHUFFLED_ORDER"
} > "$STREAM6"
eq "non-object lines: result event still found" "result" \
   "$(cost_result_event "$STREAM6" | jq -r '.type')"
cost_record_cli "non-object-lines" "$STREAM6"
LINE6=$(tail -1 "$COST_LEDGER_PATH")
eq "non-object lines: usd recorded" "3.5" "$(jq -r '.usd' <<<"$LINE6")"

BEFORE_COUNT=$(wc -l < "$COST_LEDGER_PATH")

echo "== cost_record_cli: missing stream log warns once, records nothing =="
cost_record_cli "tier-1-issue" "$TMP/does-not-exist.jsonl"
cost_record_cli "tier-1-issue" "$TMP/does-not-exist.jsonl"
cost_record_cli "tier-1-issue" "$TMP/does-not-exist.jsonl"
AFTER_COUNT=$(wc -l < "$COST_LEDGER_PATH")
eq "missing log: no ledger line added" "$BEFORE_COUNT" "$AFTER_COUNT"
WARN_COUNT=$(grep -c 'no stream log at' "$LOGFILE" || true)
eq "missing log: warns exactly once per process" "1" "$WARN_COUNT"

echo "== cost_record_cli: a log with no result event warns once, records nothing =="
: > "$LOGFILE"
STREAM_NO_RESULT="$TMP/stream-no-result.jsonl"
printf '%s\n' '{"type":"assistant","message":{"content":[]}}' > "$STREAM_NO_RESULT"
cost_record_cli "tier-1-issue" "$STREAM_NO_RESULT"
cost_record_cli "tier-1-issue" "$STREAM_NO_RESULT"
AFTER_COUNT2=$(wc -l < "$COST_LEDGER_PATH")
eq "no result event: no ledger line added" "$AFTER_COUNT" "$AFTER_COUNT2"
WARN_COUNT2=$(grep -c 'no result event found' "$LOGFILE" || true)
eq "no result event: warns exactly once per process" "1" "$WARN_COUNT2"

echo "== cost_record_cli: a truncated/malformed log (mid-write crash) warns, doesn't crash the caller =="
STREAM_TRUNCATED="$TMP/stream-truncated.jsonl"
printf '%s' '{"type":"result","total_cost_' > "$STREAM_TRUNCATED"
ok "truncated log: cost_record_cli itself returns 0" cost_record_cli "tier-1-issue" "$STREAM_TRUNCATED"

echo "== cost_ledger_summary: window filter + has_data =="
: > "$COST_LEDGER_PATH"
cat >> "$COST_LEDGER_PATH" <<'EOF'
{"timestamp":"2026-09-11T10:00:00Z","tick_pid":"1","call_site":"tier-1-issue","model":"claude-sonnet-4-6","usd":1.5,"source":"cli"}
{"timestamp":"2026-09-11T11:00:00Z","tick_pid":"1","call_site":"review","model":"claude-sonnet-4-6","usd":0.5,"source":"cli"}
{"timestamp":"2026-09-10T10:00:00Z","tick_pid":"1","call_site":"tier-1-issue","model":"claude-sonnet-4-6","usd":2.0,"source":"cli"}
EOF
S=$(cost_ledger_summary "2026-09-11T00:00:00Z" "2026-09-12T00:00:00Z")
eq "summary: count in window"        "2"   "$(jq -r '.count' <<<"$S")"
eq "summary: has_data true"          "true" "$(jq -r '.has_data' <<<"$S")"
eq "summary: total_usd sums window"  "2"   "$(jq -r '.total_usd' <<<"$S")"
eq "summary: by_site has 2 entries"  "2"   "$(jq -r '.by_site | length' <<<"$S")"

EMPTY=$(cost_ledger_summary "2020-01-01T00:00:00Z" "2020-01-02T00:00:00Z")
eq "summary: empty window has_data false" "false" "$(jq -r '.has_data' <<<"$EMPTY")"
eq "summary: empty window total_usd zero" "0"     "$(jq -r '.total_usd' <<<"$EMPTY")"

echo "== cost_ledger_summary: one malformed line doesn't blank the whole window =="
# Without `fromjson?` a single bad line aborts the stream and a full window of
# real spend renders as "no cost data recorded".
printf '%s\n' 'not json at all' >> "$COST_LEDGER_PATH"
printf '%s\n' '{"timestamp":"2026-09-11T12:00:00Z","call_site":"review","usd":1.0,"source":"cli"}' >> "$COST_LEDGER_PATH"
SM=$(cost_ledger_summary "2026-09-11T00:00:00Z" "2026-09-12T00:00:00Z")
eq "malformed line: still has_data"        "true" "$(jq -r '.has_data' <<<"$SM")"
eq "malformed line: good rows still count" "3"    "$(jq -r '.count' <<<"$SM")"
eq "malformed line: total_usd intact"      "3"    "$(jq -r '.total_usd' <<<"$SM")"

echo "== cost_ledger_summary: a valid-JSON NON-OBJECT line doesn't blank the window =="
# Worse than the unparseable line above: `fromjson?` accepts `7` and then
# `.timestamp` raises on it, which takes down the whole `[inputs | ...]`
# expression -- so a window full of real spend renders as "no cost data
# recorded". That is igor#612's own failure mode, relocated to the reader.
printf '%s\n' '7' >> "$COST_LEDGER_PATH"
printf '%s\n' '"a bare json string"' >> "$COST_LEDGER_PATH"
SN=$(cost_ledger_summary "2026-09-11T00:00:00Z" "2026-09-12T00:00:00Z")
eq "non-object line: still has_data"        "true" "$(jq -r '.has_data' <<<"$SN")"
eq "non-object line: good rows still count" "3"    "$(jq -r '.count' <<<"$SN")"
eq "non-object line: total_usd intact"      "3"    "$(jq -r '.total_usd' <<<"$SN")"

echo "== bin/tick.sh: the ship-report window bounds render the ledger's timestamp format =="
# cost_ledger_summary and tick_timing_summary compare timestamps as STRINGS,
# which is only chronological for this exact spelling. Any other RFC3339
# rendering (an offset form, sub-second precision, date-only) sorts wrong
# against the ledgers' own `date -u +%Y-%m-%dT%H:%M:%SZ` and reads EVERY
# window as empty -- a report that says "no cost data recorded" forever. The
# wiring lives in tick.sh, so pin it there rather than trusting it by eye.
WINDOW_FN=$(awk '/^do_shipreport_tick\(\) \{/,/^\}/' "$HERE/bin/tick.sh")
eq "shipreport window: 5 date -u invocations" "5" \
   "$(printf '%s\n' "$WINDOW_FN" | grep -c 'date -u')"
eq "shipreport window: none render a different format" "0" \
   "$(printf '%s\n' "$WINDOW_FN" | grep 'date -u' | grep -vc '+%Y-%m-%dT%H:%M:%SZ' || true)"

echo "== cost_ledger_summary: a just-recorded line falls inside a tick.sh-shaped window =="
# The one check with COMPUTED bounds rather than fixtured ones: it runs the
# real `date` renderings against a real _cost_write_line stamp.
: > "$COST_LEDGER_PATH"
cost_record_cli "roundtrip" "$STREAM2"
RT_SINCE=$(date -u -d "-1 days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1d +%Y-%m-%dT%H:%M:%SZ)
RT_UNTIL=$(date -u -d "+1 minute" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v+1M +%Y-%m-%dT%H:%M:%SZ)
RT=$(cost_ledger_summary "$RT_SINCE" "$RT_UNTIL")
eq "roundtrip: the fresh line is inside the 24h window" "1" "$(jq -r '.count' <<<"$RT")"

echo "== cost_ledger_summary: missing ledger file reads as no data, not an error =="
rm -f "$COST_LEDGER_PATH"
MISSING=$(cost_ledger_summary "2026-09-11T00:00:00Z" "2026-09-12T00:00:00Z")
eq "summary: missing ledger has_data false" "false" "$(jq -r '.has_data' <<<"$MISSING")"

[ "$FAIL" -eq 0 ] && { echo "test-cost: all checks passed"; exit 0; }
echo "test-cost: $FAIL check(s) FAILED"
exit 1
