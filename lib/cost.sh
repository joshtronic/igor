# lib/cost.sh -- cost-ledger helpers.
#
# Append-only JSONL ledger of every model call the agent makes. One
# line per call, both Anthropic-direct (curl) and Claude Code CLI
# (which precomputes total_cost_usd for us).
#
# Schema (one JSON object per line):
#   {
#     "timestamp": "2026-05-22T22:55:15Z",
#     "tick_pid": "83810",
#     "call_site": "agent-read" | "tier-1-issue" | ...,
#     "model": "claude-sonnet-4-6" | ...,
#     "input_tokens": int,
#     "output_tokens": int,
#     "cache_creation_input_tokens": int,
#     "cache_read_input_tokens": int,
#     "usd": float,
#     "source": "api" | "cli"
#   }
#
# Ledger lives at $AGENT_STATE_DIR/cost-ledger.jsonl. Append-only by
# design -- the file is the source of truth; bin/cost-report.sh
# slices it with jq.
#
# Direct-API callers: cost_record_api <call_site> <model> <response_json>
# Claude Code callers: cost_record_cli <call_site> <stream_log_path>

: "${AGENT_STATE_DIR:?AGENT_STATE_DIR must be set before sourcing lib/cost.sh}"

COST_LEDGER_PATH="$AGENT_STATE_DIR/cost-ledger.jsonl"

# Per-million-token pricing table (USD). Cache writes are +25% of
# input, cache reads are -90% of input. If you change models in
# .env, add the matching row here -- unknown models fall through to
# 0 (the call still gets logged with token counts; the missing
# dollar amount is loud in the report).
_cost_price() {
  local model="$1" kind="$2"
  case "$model" in
    claude-sonnet-4-6|claude-sonnet-4-6-*)
      case "$kind" in
        input)        echo "3.00" ;;
        output)       echo "15.00" ;;
        cache_create) echo "3.75" ;;
        cache_read)   echo "0.30" ;;
        *)            echo "0" ;;
      esac ;;
    claude-opus-4-7|claude-opus-4-7-*)
      case "$kind" in
        input)        echo "15.00" ;;
        output)       echo "75.00" ;;
        cache_create) echo "18.75" ;;
        cache_read)   echo "1.50" ;;
        *)            echo "0" ;;
      esac ;;
    claude-haiku-4-5|claude-haiku-4-5-*)
      case "$kind" in
        input)        echo "1.00" ;;
        output)       echo "5.00" ;;
        cache_create) echo "1.25" ;;
        cache_read)   echo "0.10" ;;
        *)            echo "0" ;;
      esac ;;
    *)
      echo "0"
      ;;
  esac
}

_cost_compute_usd() {
  local model="$1" input="$2" output="$3" cache_create="$4" cache_read="$5"
  awk -v i="$input" -v o="$output" -v cc="$cache_create" -v cr="$cache_read" \
      -v pi="$(_cost_price "$model" input)" \
      -v po="$(_cost_price "$model" output)" \
      -v pcc="$(_cost_price "$model" cache_create)" \
      -v pcr="$(_cost_price "$model" cache_read)" \
      'BEGIN { printf "%.6f", (i*pi + o*po + cc*pcc + cr*pcr) / 1000000 }'
}

_cost_write_line() {
  local site="$1" model="$2" input="$3" output="$4" cc="$5" cr="$6" usd="$7" source="$8"
  mkdir -p "$(dirname "$COST_LEDGER_PATH")"
  # --argjson for numbers, --arg for strings. Writes one compact line.
  jq -cn \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg pid "${TICK_PID:-$$}" \
    --arg site "$site" \
    --arg model "$model" \
    --argjson input "$input" \
    --argjson output "$output" \
    --argjson cc "$cc" \
    --argjson cr "$cr" \
    --argjson usd "$usd" \
    --arg source "$source" \
    '{timestamp: $ts, tick_pid: $pid, call_site: $site, model: $model,
      input_tokens: $input, output_tokens: $output,
      cache_creation_input_tokens: $cc, cache_read_input_tokens: $cr,
      usd: $usd, source: $source}' \
    >> "$COST_LEDGER_PATH" 2>/dev/null || true
}

# Direct-API call: extract usage from the response JSON we already
# parse for the model output, compute USD from the price table.
# Best-effort: silently no-ops if the response shape is unexpected
# (don't break ticks for the ledger).
cost_record_api() {
  local call_site="$1" model="$2" response="$3"
  [ -n "$response" ] || return 0
  local input output cache_create cache_read usd
  input=$(jq -r '.usage.input_tokens // 0' <<<"$response" 2>/dev/null) || input=0
  output=$(jq -r '.usage.output_tokens // 0' <<<"$response" 2>/dev/null) || output=0
  cache_create=$(jq -r '.usage.cache_creation_input_tokens // 0' <<<"$response" 2>/dev/null) || cache_create=0
  cache_read=$(jq -r '.usage.cache_read_input_tokens // 0' <<<"$response" 2>/dev/null) || cache_read=0
  # If no tokens at all, response wasn't a successful call -- skip.
  [ "$input" = "0" ] && [ "$output" = "0" ] && return 0
  usd=$(_cost_compute_usd "$model" "$input" "$output" "$cache_create" "$cache_read")
  _cost_write_line "$call_site" "$model" "$input" "$output" "$cache_create" "$cache_read" "$usd" "api"
}

# Claude Code CLI call: pull the final "result" event from the
# stream-json log; it contains total_cost_usd (precomputed) and
# usage. Best-effort -- a missing/malformed log silently skips.
cost_record_cli() {
  local call_site="$1" stream_log="$2"
  [ -f "$stream_log" ] || return 0
  local result_line
  # Final "result" event is the last line of a well-formed stream;
  # tail-1 with a type filter handles trailing partial data too.
  result_line=$(grep -E '^\{"type":"result"' "$stream_log" 2>/dev/null | tail -1)
  [ -n "$result_line" ] || return 0
  local model input output cache_create cache_read usd
  model=$(jq -r '.model // empty' <<<"$result_line" 2>/dev/null)
  [ -n "$model" ] || model="${AGENT_MODEL:-unknown}"
  input=$(jq -r '.usage.input_tokens // 0' <<<"$result_line" 2>/dev/null) || input=0
  output=$(jq -r '.usage.output_tokens // 0' <<<"$result_line" 2>/dev/null) || output=0
  cache_create=$(jq -r '.usage.cache_creation_input_tokens // 0' <<<"$result_line" 2>/dev/null) || cache_create=0
  cache_read=$(jq -r '.usage.cache_read_input_tokens // 0' <<<"$result_line" 2>/dev/null) || cache_read=0
  usd=$(jq -r '.total_cost_usd // 0' <<<"$result_line" 2>/dev/null) || usd=0
  _cost_write_line "$call_site" "$model" "$input" "$output" "$cache_create" "$cache_read" "$usd" "cli"
}
