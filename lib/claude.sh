#!/usr/bin/env bash
# lib/claude.sh -- shared model-invocation primitives.
#
# Every surface that talks to a model goes through here, and every
# call is a `claude` CLI invocation billed to the operator's Claude
# subscription (OAuth login on the host), NOT an API key. Both
# runners strip ANTHROPIC_API_KEY from the child env -- an inherited
# key silently flips the CLI to pay-as-you-go API billing.
#
#   claude_run_with_cost   -- the agentic CLI runner (stream-json ->
#                             display text + raw cost log). Used by
#                             tick.sh and site-work-block.sh.
#   claude_call            -- one-shot no-tools `claude -p` call. Used
#                             by the reading/ideation pipelines, the
#                             security gate, and tick.sh's PR-text
#                             helpers. Same signature/contract as the
#                             retired-from-service anthropic_call.
#   claude_health_*        -- durable auth/usage-limit health state
#                             shared by both runners (see below).
#   anthropic_call         -- one-shot Messages-API client. No live
#                             call sites; kept as the documented
#                             escape hatch back to API-key billing
#                             (rollback = rename claude_call ->
#                             anthropic_call at a call site and set
#                             ANTHROPIC_API_KEY in .env).
#   looks_like_conventional_commit / normalize_subject /
#   pr_body_first_item     -- pure text helpers for deriving a PR title
#                             from a PR body. Used by tick.sh and
#                             site-work-block.sh.
#
# Source order: expects lib/cost.sh already sourced (cost_record_cli /
# cost_record_api) and a `log` function defined by the caller.
# anthropic_call additionally needs ANTHROPIC_API_KEY in the env.

# -- Auth/usage health state -------------------------------------
#
# Durable record of whether `claude` can currently get a completion
# on the subscription login. Lives under a ".health" key in
# discretionary-state.json (same one-key-per-subsystem shape as
# .slots/.seo):
#   { last_ok, first_failure, kind, detail, cooldown_until,
#     emailed_on, probed_on }
# Only AUTH and USAGE-LIMIT failures count toward health -- an
# ordinary nonzero exit (timeout, max-turns, transient 5xx) is the
# calling surface's own problem and must not trip a global backoff.
# Any successful call clears the failure state. tick.sh checks
# claude_health_blocked at the top of the cascade and skips ALL
# model work while a cooldown is live (scripted work -- the SEO
# report -- still runs); do_health_tick owns the daily probe and the
# once-daily operator alert email.
#
# Cooldowns are deliberately short: a blocked tick costs nothing
# (the gate fast-fails before any call), and subscription usage
# windows reset on their own, so we just re-test on the next
# organic call after the cooldown lapses.

CLAUDE_HEALTH_LIMIT_COOLDOWN_SECS="${CLAUDE_HEALTH_LIMIT_COOLDOWN_SECS:-1800}"   # 30 min
CLAUDE_HEALTH_AUTH_COOLDOWN_SECS="${CLAUDE_HEALTH_AUTH_COOLDOWN_SECS:-3600}"     # 60 min

# Same file tick.sh's discretionary_state_file() points at, but
# computed locally so the pipelines (separate processes that source
# this lib without tick.sh) can record health too.
claude_health_state_file() {
  echo "${AGENT_STATE_DIR:-$HOME/.local/state/agent}/discretionary-state.json"
}

# Classify a failure message: "limit" (subscription usage window
# exhausted), "auth" (logged out / token revoked / billing), or
# "other" (anything else -- NOT health-relevant). Patterns are
# best-effort over CLI error text; an unrecognized message lands in
# "other" and is handled by the calling surface like any failure.
claude_health_classify() {
  local text="$1"
  if grep -qiE 'usage limit|rate.?limit|limit (reached|exceeded)|out of extra usage|extra usage' <<<"$text"; then
    echo limit
  elif grep -qiE 'not logged in|logged out|/login|log in again|oauth|authentication|unauthorized|invalid (api key|bearer)|revoked|credit balance|billing' <<<"$text"; then
    echo auth
  else
    echo other
  fi
}

# 0 when a health cooldown is live (callers should skip model work).
claude_health_blocked() {
  local f until now
  f=$(claude_health_state_file)
  [ -f "$f" ] || return 1
  until=$(jq -r '.health.cooldown_until // 0' "$f" 2>/dev/null)
  [ -n "$until" ] && [ "$until" != "null" ] || return 1
  now=$(date +%s)
  [ "$now" -lt "$until" ]
}

# Echo the live failure kind ("limit"/"auth"), empty when healthy.
claude_health_kind() {
  local f
  f=$(claude_health_state_file)
  [ -f "$f" ] || { echo ""; return; }
  jq -r 'if (.health.first_failure // 0) > 0 then (.health.kind // "") else "" end' \
    "$f" 2>/dev/null || echo ""
}

# A successful call proves auth + quota work: clear any failure
# streak (keep emailed_on/probed_on -- those are per-day stamps).
claude_health_record_ok() {
  local f tmp now
  f=$(claude_health_state_file)
  now=$(date +%s)
  mkdir -p "$(dirname "$f")"
  [ -f "$f" ] || echo '{}' > "$f"
  tmp=$(mktemp)
  jq --argjson now "$now" \
    '.health = ((.health // {})
      + {last_ok: $now, first_failure: 0, kind: "", detail: "", cooldown_until: 0})' \
    "$f" > "$tmp" 2>/dev/null && mv "$tmp" "$f" || rm -f "$tmp"
}

# claude_health_record_failure <kind> <detail>
# kind is "limit" or "auth" (callers classify first and skip "other").
# Starts/extends the cooldown; first_failure survives until an ok.
claude_health_record_failure() {
  local kind="$1" detail="$2" f tmp now cooldown
  f=$(claude_health_state_file)
  now=$(date +%s)
  case "$kind" in
    auth) cooldown="$CLAUDE_HEALTH_AUTH_COOLDOWN_SECS" ;;
    *)    cooldown="$CLAUDE_HEALTH_LIMIT_COOLDOWN_SECS" ;;
  esac
  detail=$(printf '%s' "$detail" | tr '\n' ' ' | head -c 300)
  mkdir -p "$(dirname "$f")"
  [ -f "$f" ] || echo '{}' > "$f"
  tmp=$(mktemp)
  jq --argjson now "$now" --argjson cd "$cooldown" \
     --arg kind "$kind" --arg detail "$detail" \
    '.health = ((.health // {})
      + {kind: $kind, detail: $detail, cooldown_until: ($now + $cd)}
      + (if (.health.first_failure // 0) > 0 then {} else {first_failure: $now} end))' \
    "$f" > "$tmp" 2>/dev/null && mv "$tmp" "$f" || rm -f "$tmp"
  log "claude health: $kind failure recorded, backing off ${cooldown}s -- $detail"
}

# Run `claude --print` with stream-json output so the tick keeps live
# progress in journalctl AND we can extract the precomputed
# total_cost_usd from the final result event for the ledger.
#
# Pipeline shape:
#   claude (stream-json) -> tee raw-stream-log -> jq display-text -> tee display-log
#
# Raw stream log holds every event (one JSON object per line) for
# post-run cost extraction + debugging. Display log + journalctl get
# the same readable text the old plain --print mode produced.
#
# Args: <call_site> <display_log_path> <timeout_spec> <claude_args...>
# Returns: claude's exit code (PIPESTATUS[0] captured into $?)
claude_run_with_cost() {
  local call_site="$1" display_log="$2" timeout_spec="$3"
  shift 3
  local scratch
  scratch=$(dirname "$display_log")
  local stream_log="$scratch/claude-stream.jsonl"
  : > "$stream_log"
  : > "$display_log"
  # Remember the caller's errexit so our internal toggling never leaks back to
  # it. Every caller wraps this call in `set +e` to capture and handle a nonzero
  # exit (a recoverable model crash mid-stream). If we restore errexit with an
  # unconditional `set -e` below, that ON state is the shell's state when this
  # function returns -- so a nonzero `return` trips errexit in the CALLER and
  # takes the whole tick down (status=1, no "claude exited" line) BEFORE it can
  # capture our exit. That is the igor#291 / #279 crash: the very `set -e` added
  # to protect the bookkeeping is what defeats the caller's guard.
  local _caller_errexit=0; case $- in *e*) _caller_errexit=1 ;; esac
  # Mark this call in-flight. cleanup() (via crashlog_preserve) keeps the raw
  # stream for a post-mortem if the tick dies before we return here -- the #279
  # signature (status=1, no "claude exited" line). Cleared on a clean return.
  printf '%s\t%s\n' "$call_site" "$(date +%s)" > "$scratch/claude-in-flight" 2>/dev/null || true
  # stderr inline with stdout (old behavior); jq filter drops
  # non-JSON lines so stray stderr doesn't break the pipeline.
  # --verbose is required by Claude Code when using stream-json
  # with --print (it refuses without it).
  # env -u: keep the CLI on the subscription login -- an inherited
  # ANTHROPIC_API_KEY would silently flip it to API billing.
  set +e
  set -o pipefail
  timeout --kill-after=30s "$timeout_spec" \
    env -u ANTHROPIC_API_KEY \
    claude --output-format stream-json --verbose "$@" 2>&1 \
    | tee "$stream_log" \
    | jq -r --unbuffered '
        if (try .type catch null) == "assistant" then
          (.message.content // [])[]
          | if .type == "text" then .text
            elif .type == "tool_use" then "[tool: \(.name)]"
            else empty
            end
        elif (try .type catch null) == "user" then
          (.message.content // [])[]
          | if .type == "tool_result" then "[tool_result]"
            else empty
            end
        else empty
        end
      ' 2>/dev/null \
    | tee "$display_log"
  local rc=${PIPESTATUS[0]}
  set +o pipefail
  # Restore the caller's errexit -- NOT an unconditional `set -e`, which leaks
  # into the caller and aborts it on our nonzero `return` (igor#291). The
  # bookkeeping below is `|| true`-guarded throughout, so it is safe to run with
  # errexit off when the caller had it off.
  if [ "$_caller_errexit" -eq 1 ]; then set -e; else set +e; fi
  # Bookkeeping must NEVER kill the tick. If claude crashes mid-stream the JSONL is
  # truncated, so the cost parse can fail -- guard it (|| true), exactly like the
  # health classification below, or set -e turns a recoverable model crash into a
  # raw status=1 that bypasses the caller's exit handling and re-does the work.
  cost_record_cli "$call_site" "$stream_log" || true
  # Health bookkeeping: a clean exit clears any failure streak; a
  # nonzero exit only counts when the ERROR CHANNELS say auth/limit
  # (timeouts and ordinary task failures stay the surface's problem).
  # Classify only stderr leaks (non-JSON lines in the merged stream)
  # and the final error result event -- never arbitrary event content,
  # where agent/tool text about "authentication" or "rate limits"
  # would false-positive a global backoff.
  if [ "$rc" -eq 0 ]; then
    claude_health_record_ok || true
  else
    local err_text kind
    # `|| true` everywhere: this runs under set -e, and a no-match
    # grep or a truncated-by-timeout final JSON line must degrade to
    # "nothing classifiable", never kill the tick.
    err_text=$(
      {
        { grep -vE '^\{' "$stream_log" || true; } | tail -c 1000
        { grep -E '^\{"type":"result"' "$stream_log" || true; } | tail -1 \
          | { jq -r 'select(.is_error == true) | .result // empty' 2>/dev/null || true; }
      } 2>/dev/null
    ) || true
    kind=$(claude_health_classify "$err_text")
    if [ "$kind" != "other" ]; then
      claude_health_record_failure "$kind" "$call_site: $(printf '%s' "$err_text" | tail -c 200)"
    fi
  fi
  # Returned cleanly -- clear the in-flight marker so cleanup() won't treat this
  # worktree as a crash. (If we never reach here, the marker lingers and the
  # stream is preserved -- exactly the case we want to capture.)
  rm -f "$scratch/claude-in-flight" 2>/dev/null || true
  return "$rc"
}

# One-shot, no-tools `claude -p` completion -- the subscription-billed
# replacement for anthropic_call, same signature and contract:
#
#   claude_call <model> <call_site> <max_tokens> <system> <user> [strip_fences] [timeout_secs]
#
# Echoes the completion text; nonzero on any failure. strip_fences
# (default "1") drops ``` fence lines, exactly like anthropic_call.
#
# Invocation shape, and why each flag is there:
#   - runs from an empty scratch dir so no CLAUDE.md is auto-loaded
#     into the context (these prompts are tuned standalone -- voice
#     fidelity depends on nothing else leaking in)
#   - --system-prompt REPLACES Claude Code's default agentic system
#     prompt (same reason)
#   - --tools "" / --strict-mcp-config: pure text completion
#   - --no-session-persistence: at the 1-minute cadence we'd litter
#     thousands of session files otherwise
#   - user prompt via stdin: dodges ARG_MAX for big payloads (diffs);
#     system prompts are small, so an arg is fine there
#   - max_tokens gets +8192 headroom: on the CLI, THINKING tokens
#     share the output budget (the Messages API's max_tokens only
#     bounded visible text), so an unpadded cap can starve the
#     visible text -- seen in the wild as draft responses with the
#     tail (or all) of the expected output missing. The padded value
#     is a runaway ceiling, not a target; prompts still control
#     length, and on subscription billing the old cost-capping role
#     is moot. (It also clears the API's ~1024 minimum thinking
#     budget, which rejects very low caps outright.)
claude_call() {
  local model="$1" call_site="$2" max_tokens="$3" system="$4" user="$5"
  local strip_fences="${6:-1}"
  local timeout_secs="${7:-${CLAUDE_CALL_TIMEOUT_SECS:-300}}"
  local scratch envelope rc text err kind
  # Optional `model:effort` suffix (e.g. "claude-opus-4-8:high") sets the CLI
  # reasoning effort (igor#308). Model ids carry no colon, so the split is
  # unambiguous; a bare model passes no --effort (unchanged behavior).
  local -a effort_args=()
  case "$model" in
    *:*) effort_args=(--effort "${model##*:}"); model="${model%:*}" ;;
  esac

  if claude_health_blocked; then
    log "claude $call_site: health backoff active -- skipping call"
    return 1
  fi
  max_tokens=$((max_tokens + 8192))

  scratch=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$scratch'" RETURN

  envelope=$(printf '%s' "$user" \
    | (cd "$scratch" && env -u ANTHROPIC_API_KEY \
        CLAUDE_CODE_MAX_OUTPUT_TOKENS="$max_tokens" \
        timeout "$timeout_secs" \
        claude -p \
          --model "$model" \
          "${effort_args[@]}" \
          --system-prompt "$system" \
          --tools "" \
          --strict-mcp-config \
          --no-session-persistence \
          --output-format json \
        2>"$scratch/stderr")) && rc=0 || rc=$?

  # is_error rides inside a rc-0 envelope (e.g. API 4xx) -- treat
  # both shapes as the same failure path.
  if [ "$rc" -ne 0 ] \
     || [ "$(jq -r '.is_error // false' <<<"$envelope" 2>/dev/null)" = "true" ]; then
    err="$(jq -r '.result // empty' <<<"$envelope" 2>/dev/null) $(head -c 500 "$scratch/stderr" 2>/dev/null)"
    kind=$(claude_health_classify "$err")
    if [ "$kind" != "other" ]; then
      claude_health_record_failure "$kind" "$call_site: $(printf '%s' "$err" | head -c 200)"
    fi
    log "claude $call_site: failed (rc=$rc) -- $(printf '%s' "$err" | tr '\n' ' ' | head -c 200)"
    return 1
  fi

  printf '%s' "$envelope" > "$scratch/envelope.json"
  cost_record_cli "$call_site" "$scratch/envelope.json" "$model"
  claude_health_record_ok

  text=$(jq -r '.result // empty' <<<"$envelope" 2>/dev/null)
  [ -z "$text" ] && { log "claude $call_site: empty result"; return 1; }
  if [ "$strip_fences" = "1" ]; then
    printf '%s' "$text" | sed -E '/^```/d'
  else
    printf '%s' "$text"
  fi
}

# Anthropic Messages API call. Builds the payload via tempfiles to
# dodge ARG_MAX, POSTs via curl, records cost, echoes the content text.
# Non-zero on any failure.
#
# Optional 6th arg strip_fences (default "1"): strip lines starting with
# a ``` code fence from the output. Callers expecting STRICT JSON keep
# the default. Callers that want raw markdown back (a body that may
# legitimately contain fenced code blocks) pass "0".
anthropic_call() {
  local model="$1" call_site="$2" max_tokens="$3" system="$4" user="$5"
  local strip_fences="${6:-1}"
  local sys_file user_file payload_file response_file http_status text
  sys_file=$(mktemp); user_file=$(mktemp)
  payload_file=$(mktemp); response_file=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$sys_file' '$user_file' '$payload_file' '$response_file'" RETURN

  printf '%s' "$system" > "$sys_file"
  printf '%s' "$user"   > "$user_file"
  jq -n \
    --arg m "$model" \
    --argjson mt "$max_tokens" \
    --rawfile s "$sys_file" \
    --rawfile u "$user_file" \
    '{model: $m, max_tokens: $mt, system: $s,
      messages: [{role: "user", content: $u}]}' \
    > "$payload_file" || return 1

  http_status=$(curl -sS \
    -X POST https://api.anthropic.com/v1/messages \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "Content-Type: application/json" \
    --max-time 120 \
    -w '%{http_code}' -o "$response_file" \
    --data-binary "@$payload_file" 2>/dev/null) || return 1

  if [ "$http_status" != "200" ]; then
    log "anthropic $call_site: HTTP $http_status -- $(jq -r '.error.message // .error.type // empty' < "$response_file" 2>/dev/null | head -c 200)"
    return 1
  fi

  cost_record_api "$call_site" "$model" "$(cat "$response_file")"

  text=$(jq -r '.content[0].text // empty' < "$response_file" 2>/dev/null)
  [ -z "$text" ] && { log "anthropic $call_site: empty content"; return 1; }
  if [ "$strip_fences" = "1" ]; then
    printf '%s' "$text" | sed -E '/^```/d'
  else
    printf '%s' "$text"
  fi
}

# Return 0 if the subject looks like a conventional commit
# ("type: description" with a known type). Used to reject API
# responses that are conversational rather than subject-shaped.
looks_like_conventional_commit() {
  local s="$1"
  [[ "$s" =~ ^(feat|fix|chore|docs|style|refactor|test|perf|build|ci|revert):[[:space:]]+.+ ]]
}

# Ensure a conventional-commit prefix. If the subject already has
# one (feat:/fix:/chore:/etc.), return unchanged. Otherwise prepend
# `chore: ` as a safe default so the PR title isn't bare imperative
# prose like "Update X" with no type marker.
normalize_subject() {
  local s="$1"
  if looks_like_conventional_commit "$s"; then
    printf '%s' "$s"
  else
    printf 'chore: %s' "$s"
  fi
}

# Echo the first "## What this PR does" checklist item from a PR body
# file (the `- [x] ` / `- [ ] ` marker stripped), empty if the section
# or item is missing. The commit subject / PR title is derived from
# this on every surface that writes a PR body.
pr_body_first_item() {
  local pr_body="$1"
  awk '
    /^## What this PR does/ { in_section = 1; next }
    /^## / && in_section { exit }
    in_section && /^- \[[x ]\] / {
      sub(/^- \[[x ]\] /, "")
      print
      exit
    }
  ' "$pr_body"
}
