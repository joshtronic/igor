#!/usr/bin/env bash
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

# Fallback logger so this module is sourceable standalone (tests) and so
# the new warn-once lines below (igor#612) work even if this is ever
# sourced before tick.sh's own log() is defined.
if ! declare -F log >/dev/null; then
  log() { printf '[agent] %s\n' "$*" >&2; }
fi

COST_LEDGER_PATH="$AGENT_STATE_DIR/cost-ledger.jsonl"

# Write one ledger line. If usd is "" we omit the field entirely;
# cost-report.sh computes USD for these from its price table.
_cost_write_line() {
  local site="$1" model="$2" input="$3" output="$4" cc="$5" cr="$6" usd="$7" source="$8"
  mkdir -p "$(dirname "$COST_LEDGER_PATH")"
  jq -cn \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg pid "${TICK_PID:-$$}" \
    --arg site "$site" \
    --arg model "$model" \
    --argjson input "$input" \
    --argjson output "$output" \
    --argjson cc "$cc" \
    --argjson cr "$cr" \
    --arg usd "$usd" \
    --arg source "$source" \
    '{timestamp: $ts, tick_pid: $pid, call_site: $site, model: $model,
      input_tokens: $input, output_tokens: $output,
      cache_creation_input_tokens: $cc, cache_read_input_tokens: $cr,
      source: $source}
     + (if $usd != "" then {usd: ($usd | tonumber)} else {} end)' \
    >> "$COST_LEDGER_PATH" 2>/dev/null || true
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

# Warn-once markers (igor#612): a broken parse here is a SILENT
# multi-week data loss (seven weeks, undetected -- the charter case for
# "no logging without visibility"). Each condition warns at most once
# per process -- one tick.sh invocation may call cost_record_cli many
# times (one per model call in the tick), and re-warning on every one
# of them would just be a different kind of noise.
_COST_WARNED_NO_STREAM_LOG=""
_COST_WARNED_NO_RESULT_EVENT=""

# cost_result_event <stream_log> -- the last `type == "result"` event in a
# Claude CLI log, or empty. Shared by cost_record_cli and claude.sh's health
# classification: both read the same log, so a parse bug here is a bug in both.
#
# Line-oriented (`-R 'fromjson?'`) because the stream log is NOT pure JSON --
# the CLI's plain-text output (auth failures, rate-limit notices, node
# warnings) is merged into it via 2>&1, which is exactly why claude.sh greps
# `-vE '^\{'` to harvest those lines. A whole-file `jq 'select(...)'` ABORTS on
# the first non-JSON byte and stops reading, so a result event printed after
# any stderr leak would be silently missed -- the same silent-parse-failure
# class as igor#612 itself. `fromjson?` drops unparseable lines and reads on.
#
# The fallback handles the one log that ISN'T line-delimited: claude_call's
# `--output-format json` envelope, a single JSON document the CLI may
# pretty-print across lines. It only runs when the line pass found nothing,
# and that file is a clean rc-0 capture with no interleaved text.
cost_result_event() {
  local stream_log="$1" line
  line=$(jq -c -R 'fromjson? | select(.type == "result")' "$stream_log" 2>/dev/null | tail -1)
  [ -n "$line" ] || line=$(jq -c 'select(.type == "result")' "$stream_log" 2>/dev/null | tail -1)
  printf '%s' "$line"
}

# Claude Code CLI call: pull the final "result" event from the
# stream-json log. It contains both `usage` and `total_cost_usd`
# (precomputed by the CLI, accounts for tool-use accounting). We
# store the precomputed USD verbatim -- authoritative wins. Token
# counts come along for the ride so reports can show breakdowns.
#
# Parses as JSON (jq `select(.type == "result")`), NOT by grepping for
# a `{"type":"result"` prefix -- key order in the CLI's result event is
# not a contract (igor#612: a CLI update reordered it, `type` moved from
# 1st to 15th key, the old text-anchored grep silently stopped matching
# for seven weeks). Best-effort: a missing/malformed log still skips
# recording (failing open is right -- a bad ledger write must never
# break a tick), but now it says so instead of failing silently.
#
# Note: on a subscription login the CLI still computes total_cost_usd,
# so the ledger keeps working -- the number is dollars-EQUIVALENT used
# (a plan-consumption meter), not dollars billed.
#
# Optional $3: model fallback when the result event carries no .model
# (the `--output-format json` envelope claude_call records doesn't).
cost_record_cli() {
  local call_site="$1" stream_log="$2" model_fallback="${3:-}"
  if [ ! -f "$stream_log" ]; then
    if [ -z "$_COST_WARNED_NO_STREAM_LOG" ]; then
      log "cost: no stream log at $stream_log ($call_site) -- spend for this call was NOT recorded"
      _COST_WARNED_NO_STREAM_LOG=1
    fi
    return 0
  fi
  local result_line
  result_line=$(cost_result_event "$stream_log")
  if [ -z "$result_line" ]; then
    if [ -z "$_COST_WARNED_NO_RESULT_EVENT" ]; then
      log "cost: no result event found in $stream_log ($call_site) -- spend for this call was NOT recorded (malformed or truncated log?)"
      _COST_WARNED_NO_RESULT_EVENT=1
    fi
    return 0
  fi
  local model input output cache_create cache_read usd
  model=$(jq -r '.model // empty' <<<"$result_line" 2>/dev/null)
  [ -n "$model" ] || model="${model_fallback:-${AGENT_MODEL:-unknown}}"
  input=$(jq -r '.usage.input_tokens // 0' <<<"$result_line" 2>/dev/null) || input=0
  output=$(jq -r '.usage.output_tokens // 0' <<<"$result_line" 2>/dev/null) || output=0
  cache_create=$(jq -r '.usage.cache_creation_input_tokens // 0' <<<"$result_line" 2>/dev/null) || cache_create=0
  cache_read=$(jq -r '.usage.cache_read_input_tokens // 0' <<<"$result_line" 2>/dev/null) || cache_read=0
  usd=$(jq -r '.total_cost_usd // empty' <<<"$result_line" 2>/dev/null)
  [ -n "$usd" ] || usd=""
  _cost_write_line "$call_site" "$model" "$input" "$output" "$cache_create" "$cache_read" "$usd" "cli"
}

# cost_ledger_summary <since_iso> <until_iso> -- total spend + a per-call-site
# breakdown for entries in [since, until). Used by the ship report (igor#612)
# to show aggregate spend instead of leaving seven weeks of it unread again.
#
# Sums the authoritative `.usd` field only (the "cli" source, which is every
# live call site as of igor#612 -- anthropic_call/cost_record_api has no live
# call site, so a bare-API entry lacking `.usd` would undercount, but there
# is currently nothing to undercount). has_data distinguishes a genuinely
# quiet window from a missing/unreadable ledger -- the report must say "no
# cost data recorded", never a bare $0.00 that reads the same as "checked,
# spent nothing".
cost_ledger_summary() {
  local since="$1" until_="$2"
  if [ ! -f "$COST_LEDGER_PATH" ]; then
    printf '{"count":0,"has_data":false,"total_usd":0,"by_site":[]}'
    return 0
  fi
  jq -cnR --arg since "$since" --arg until "$until_" '
    [inputs | fromjson? | select(.timestamp >= $since and .timestamp < $until)] as $rows
    | {
        count: ($rows | length),
        has_data: ($rows | length > 0),
        total_usd: ($rows | map(.usd // 0) | add // 0),
        by_site: ($rows | group_by(.call_site)
                  | map({site: .[0].call_site, usd: (map(.usd // 0) | add), count: length})
                  | sort_by(-.usd))
      }
  ' "$COST_LEDGER_PATH" 2>/dev/null \
    || printf '{"count":0,"has_data":false,"total_usd":0,"by_site":[]}'
}
