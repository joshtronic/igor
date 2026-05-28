#!/usr/bin/env bash
# lib/claude.sh -- shared model-invocation primitives.
#
# Every surface that talks to a model goes through here:
#   claude_run_with_cost   -- the agentic CLI runner (stream-json ->
#                             display text + raw cost log). Used by
#                             tick.sh and site-work-block.sh.
#   anthropic_call         -- one-shot Messages-API client. Used by the
#                             reading/ideation pipelines and tick.sh's
#                             PR-text helpers.
#   looks_like_conventional_commit / normalize_subject /
#   pr_body_first_item     -- pure text helpers for deriving a PR title
#                             from a PR body. Used by tick.sh and
#                             site-work-block.sh.
#
# Source order: expects lib/cost.sh already sourced (cost_record_cli /
# cost_record_api) and a `log` function defined by the caller.
# anthropic_call additionally needs ANTHROPIC_API_KEY in the env.

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
  # stderr inline with stdout (old behavior); jq filter drops
  # non-JSON lines so stray stderr doesn't break the pipeline.
  # --verbose is required by Claude Code when using stream-json
  # with --print (it refuses without it).
  set +e
  set -o pipefail
  timeout --kill-after=30s "$timeout_spec" \
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
  set -e
  cost_record_cli "$call_site" "$stream_log"
  return "$rc"
}

# Anthropic Messages API call. Builds the payload via tempfiles to
# dodge ARG_MAX, POSTs via curl, records cost, echoes the content text
# with any code fences stripped. Non-zero on any failure.
anthropic_call() {
  local model="$1" call_site="$2" max_tokens="$3" system="$4" user="$5"
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
  printf '%s' "$text" | sed -E '/^```/d'
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
