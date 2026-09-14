#!/usr/bin/env bash
# email.sh -- transactional email via the SMTP2GO HTTP API. Sourced by
# bin/tick.sh for report delivery (SEO, sports, ...).
#
# Email delivery is shared across opt-in subsystems; callers gate on
# these being set:
#   SMTP2GO_API_KEY, SMTP2GO_SENDER
# Requires on PATH: curl, jq.

# Fallback logger so this module is sourceable standalone (tests).
if ! declare -F log >/dev/null; then
  log() { printf '[agent] %s\n' "$*" >&2; }
fi

# recipients_with_primary <extra_csv> -- the To line for any harness email:
# PRIMARY_RECIPIENTS (the operator, always) plus the surface's extra
# subscribers, comma-joined and deduped, empties dropped. Empty only if
# PRIMARY_RECIPIENTS is unset and there are no extras. Every report surface
# routes through this so PRIMARY is always copied and per-surface lists are
# purely additive.
recipients_with_primary() {
  local extra="${1:-}"
  printf '%s\n' "${PRIMARY_RECIPIENTS:-}" "$extra" \
    | tr ',' '\n' | awk 'NF && !seen[$0]++' | paste -sd, -
}

EMAIL_API="${EMAIL_API:-https://api.smtp2go.com/v3/email/send}"

# email_send <subject> <html_body> <text_body> <to_csv> [cc_csv]
# to_csv / cc_csv are comma-separated address lists. Returns 0 if
# SMTP2GO reports at least one delivery, 1 otherwise (logs the error).
# Idempotency is the caller's concern -- SMTP2GO has no dedup, so the
# caller must not re-send the same report.
email_send() {
  local subject="$1" html="$2" text="$3" to_csv="$4" cc_csv="${5:-}"
  local to_json cc_json payload ok

  to_json=$(printf '%s' "$to_csv" | jq -Rc 'split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length>0))')
  if [ "$(jq 'length' <<<"$to_json" 2>/dev/null || echo 0)" -eq 0 ]; then
    log "email: no recipients -- skipping send"
    return 1
  fi

  # igor#635: html/text can each run past ARG_MAX on their own (a large ship
  # report), and jq's --arg puts its value on jq's OWN argv same as curl's -d
  # did -- so a big body blew up the exec building the payload, before curl
  # was ever reached. --rawfile takes a PATH on argv and reads the content
  # via a read(), so neither body ever becomes an argv entry.
  local html_file text_file jq_rc=0
  html_file=$(mktemp); text_file=$(mktemp)
  printf '%s' "$html" >"$html_file"
  printf '%s' "$text" >"$text_file"
  payload=$(jq -n \
    --arg key "$SMTP2GO_API_KEY" \
    --arg sender "$SMTP2GO_SENDER" \
    --arg subject "$subject" \
    --rawfile html "$html_file" \
    --rawfile text "$text_file" \
    --argjson to "$to_json" \
    '{api_key:$key, sender:$sender, to:$to, subject:$subject,
      html_body:$html, text_body:$text}') || jq_rc=$?
  # Guarded rather than bare so the temp files are removed on the failure
  # path too -- under a caller's `set -e` a failing jq would otherwise abort
  # the function mid-way and leak both in a long-running tick loop. An empty
  # payload must also never reach curl as if it were a real body.
  rm -f "$html_file" "$text_file"
  if [ "$jq_rc" -ne 0 ] || [ -z "$payload" ]; then
    log "email: failed to build the JSON payload (jq exit ${jq_rc})"
    return 1
  fi

  if [ -n "$cc_csv" ]; then
    cc_json=$(printf '%s' "$cc_csv" | jq -Rc 'split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length>0))')
    if [ "$(jq 'length' <<<"$cc_json" 2>/dev/null || echo 0)" -gt 0 ]; then
      payload=$(jq -c --argjson cc "$cc_json" '. + {cc:$cc}' <<<"$payload")
    fi
  fi

  # igor#633: no bare -f, no 2>/dev/null -- both used to throw away exactly
  # the information needed to diagnose a failed send. -w appends the HTTP
  # status on its own trailing line so a transport failure (curl itself
  # errors, no round trip happened) and an HTTP-level rejection (a round
  # trip happened, SMTP2GO said no) log differently and both carry the
  # response body. Nothing but $payload ever carries the API key, and
  # $payload is never logged.
  # igor#635: the payload goes to curl on STDIN (--data-binary @-), never as
  # an argv entry -- a curl -d "$payload" made the kernel refuse to exec curl
  # at all (E2BIG) once the payload passed ARG_MAX, before any request was
  # attempted. Piping removes the ceiling for every email_send caller.
  local resp rc err_file curl_err http_code body
  err_file=$(mktemp)
  resp=$(printf '%s' "$payload" | curl -sS -w '\n%{http_code}' -X POST -H "Content-Type: application/json" \
    --data-binary @- "$EMAIL_API" 2>"$err_file")
  rc=$?
  curl_err=$(cat "$err_file" 2>/dev/null)
  rm -f "$err_file"
  if [ "$rc" -ne 0 ]; then
    log "email: request to SMTP2GO failed (curl exit ${rc}): ${curl_err:-no error output}"
    return 1
  fi
  http_code=$(printf '%s' "$resp" | tail -n1)
  body=$(printf '%s' "$resp" | sed '$d')
  case "$http_code" in
    2??) ;;
    *) log "email: SMTP2GO HTTP ${http_code:-?}: ${body:-<empty body>}"; return 1 ;;
  esac

  # Success shape: {"data":{"succeeded":N,"failed":M,...}}
  ok=$(jq -r '.data.succeeded // 0' <<<"$body" 2>/dev/null)
  if [ "${ok:-0}" -ge 1 ] 2>/dev/null; then
    return 0
  fi
  log "email: SMTP2GO HTTP ${http_code} reported no delivery: $(jq -c '.data // .' <<<"$body" 2>/dev/null || printf '%s' "$body")"
  return 1
}
