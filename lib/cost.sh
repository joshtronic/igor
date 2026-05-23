# lib/cost.sh -- cost-ledger helpers.
#
# Append-only JSONL ledger of every model call the agent makes. One
# line per call, both Anthropic-direct (curl) and Claude Code CLI.
#
# Pricing strategy: if the call surface returns an authoritative
# USD (the Claude Code CLI does via total_cost_usd in the result
# event), we store it -- it accounts for tool-use overhead and
# sub-agent costs we'd otherwise have to re-derive. Direct API
# calls don't get a precomputed USD, so we stash tokens only and
# bin/cost-report.sh computes USD at query time from a single
# price table living there.
#
# Net: one price table (in cost-report.sh) used only for the direct-
# API entries, and the CLI's authoritative numbers passed through
# verbatim. Rate changes apply retroactively to API entries; CLI
# entries stay as-shipped (which is correct -- they were billed
# at whatever rate was in effect then).
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
#     "usd": float,     // present ONLY for cli (authoritative).
#                       // absent for api (computed at report time).
#     "source": "api" | "cli"
#   }
#
# Direct-API callers: cost_record_api <call_site> <model> <response_json>
# Claude Code callers: cost_record_cli <call_site> <stream_log_path>

: "${AGENT_STATE_DIR:?AGENT_STATE_DIR must be set before sourcing lib/cost.sh}"

COST_LEDGER_PATH="$AGENT_STATE_DIR/cost-ledger.jsonl"

# Write one ledger line. If usd is "" we omit the field entirely;
# cost-report.sh computes USD for these from its price table.
_cost_write_line() {
  local site="$1" model="$2" input="$3" output="$4" cc="$5" cr="$6" usd="$7" source="$8"
  mkdir -p "$(dirname "$COST_LEDGER_PATH")"
  if [ -n "$usd" ]; then
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
  else
    jq -cn \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg pid "${TICK_PID:-$$}" \
      --arg site "$site" \
      --arg model "$model" \
      --argjson input "$input" \
      --argjson output "$output" \
      --argjson cc "$cc" \
      --argjson cr "$cr" \
      --arg source "$source" \
      '{timestamp: $ts, tick_pid: $pid, call_site: $site, model: $model,
        input_tokens: $input, output_tokens: $output,
        cache_creation_input_tokens: $cc, cache_read_input_tokens: $cr,
        source: $source}' \
      >> "$COST_LEDGER_PATH" 2>/dev/null || true
  fi
}

# Direct-API call: extract usage from the response JSON we already
# parse for the model output. No precomputed USD (the Messages API
# doesn't return one); cost-report.sh derives it from the price
# table. Best-effort: silently no-ops if the response shape is
# unexpected (don't break ticks for the ledger).
cost_record_api() {
  local call_site="$1" model="$2" response="$3"
  [ -n "$response" ] || return 0
  local input output cache_create cache_read
  input=$(jq -r '.usage.input_tokens // 0' <<<"$response" 2>/dev/null) || input=0
  output=$(jq -r '.usage.output_tokens // 0' <<<"$response" 2>/dev/null) || output=0
  cache_create=$(jq -r '.usage.cache_creation_input_tokens // 0' <<<"$response" 2>/dev/null) || cache_create=0
  cache_read=$(jq -r '.usage.cache_read_input_tokens // 0' <<<"$response" 2>/dev/null) || cache_read=0
  # If no tokens at all, response wasn't a successful call -- skip.
  [ "$input" = "0" ] && [ "$output" = "0" ] && return 0
  _cost_write_line "$call_site" "$model" "$input" "$output" "$cache_create" "$cache_read" "" "api"
}

# Claude Code CLI call: pull the final "result" event from the
# stream-json log. It contains both `usage` and `total_cost_usd`
# (precomputed by the CLI, accounts for tool-use accounting). We
# store the precomputed USD verbatim -- authoritative wins. Token
# counts come along for the ride so reports can show breakdowns.
# Best-effort: missing/malformed log silently skips.
cost_record_cli() {
  local call_site="$1" stream_log="$2"
  [ -f "$stream_log" ] || return 0
  local result_line
  result_line=$(grep -E '^\{"type":"result"' "$stream_log" 2>/dev/null | tail -1)
  [ -n "$result_line" ] || return 0
  local model input output cache_create cache_read usd
  model=$(jq -r '.model // empty' <<<"$result_line" 2>/dev/null)
  [ -n "$model" ] || model="${AGENT_MODEL:-unknown}"
  input=$(jq -r '.usage.input_tokens // 0' <<<"$result_line" 2>/dev/null) || input=0
  output=$(jq -r '.usage.output_tokens // 0' <<<"$result_line" 2>/dev/null) || output=0
  cache_create=$(jq -r '.usage.cache_creation_input_tokens // 0' <<<"$result_line" 2>/dev/null) || cache_create=0
  cache_read=$(jq -r '.usage.cache_read_input_tokens // 0' <<<"$result_line" 2>/dev/null) || cache_read=0
  usd=$(jq -r '.total_cost_usd // empty' <<<"$result_line" 2>/dev/null)
  [ -n "$usd" ] || usd=""
  _cost_write_line "$call_site" "$model" "$input" "$output" "$cache_create" "$cache_read" "$usd" "cli"
}
