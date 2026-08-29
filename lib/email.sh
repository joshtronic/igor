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

EMAIL_API="https://api.smtp2go.com/v3/email/send"

# email_send <subject> <html_body> <text_body> <to_csv> [cc_csv]
# to_csv / cc_csv are comma-separated address lists. Returns 0 if
# SMTP2GO reports at least one delivery, 1 otherwise (logs the error).
# Idempotency is the caller's concern -- SMTP2GO has no dedup, so the
# caller must not re-send the same report.
email_send() {
  local subject="$1" html="$2" text="$3" to_csv="$4" cc_csv="${5:-}"
  local to_json cc_json payload resp ok

  to_json=$(printf '%s' "$to_csv" | jq -Rc 'split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length>0))')
  if [ "$(jq 'length' <<<"$to_json" 2>/dev/null || echo 0)" -eq 0 ]; then
    log "email: no recipients -- skipping send"
    return 1
  fi

  payload=$(jq -n \
    --arg key "$SMTP2GO_API_KEY" \
    --arg sender "$SMTP2GO_SENDER" \
    --arg subject "$subject" \
    --arg html "$html" \
    --arg text "$text" \
    --argjson to "$to_json" \
    '{api_key:$key, sender:$sender, to:$to, subject:$subject,
      html_body:$html, text_body:$text}')

  if [ -n "$cc_csv" ]; then
    cc_json=$(printf '%s' "$cc_csv" | jq -Rc 'split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length>0))')
    if [ "$(jq 'length' <<<"$cc_json" 2>/dev/null || echo 0)" -gt 0 ]; then
      payload=$(jq -c --argjson cc "$cc_json" '. + {cc:$cc}' <<<"$payload")
    fi
  fi

  resp=$(curl -fsS -X POST -H "Content-Type: application/json" \
    -d "$payload" "$EMAIL_API" 2>/dev/null) || {
      log "email: request to SMTP2GO failed"
      return 1
    }

  # Success shape: {"data":{"succeeded":N,"failed":M,...}}
  ok=$(jq -r '.data.succeeded // 0' <<<"$resp" 2>/dev/null)
  if [ "${ok:-0}" -ge 1 ] 2>/dev/null; then
    return 0
  fi
  log "email: SMTP2GO reported no delivery: $(jq -c '.data // .' <<<"$resp" 2>/dev/null || printf '%s' "$resp")"
  return 1
}
