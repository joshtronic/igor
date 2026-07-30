#!/usr/bin/env bash
# google-auth.sh -- mint a short-lived Google API access token from a SERVICE
# ACCOUNT (GOOGLE_SERVICE_ACCOUNT), shared by the GSC and (soon) GA clients.
#
# This replaces the old GSC OAuth refresh-token flow: server-to-server, no user
# consent, no durable refresh token to babysit. The service account is granted
# read access in Search Console / Analytics; here we just sign a JWT with its
# key and exchange it for a scoped access token.
#
# GOOGLE_SERVICE_ACCOUNT holds the service-account key JSON, accepted in any of:
#   - base64 of the JSON  (recommended: one clean .env line, no quoting pain)
#   - a path to the JSON file
#   - the raw JSON inline
#
# Requires on PATH: curl, jq, openssl, base64. The private key is used only to
# sign (via openssl over a process substitution) -- never written to disk,
# never logged.

# Fallback logger so this module is sourceable standalone (tests).
if ! declare -F log >/dev/null; then
  log() { printf '[agent] %s\n' "$*" >&2; }
fi

GOOGLE_TOKEN_EP_DEFAULT="https://oauth2.googleapis.com/token"

# base64url (no padding), for the JWT segments.
_google_b64url() { openssl base64 -A 2>/dev/null | tr '+/' '-_' | tr -d '='; }

# google_sa_json -- echo the service-account key JSON resolved from
# GOOGLE_SERVICE_ACCOUNT (base64 | file path | inline). Empty + rc=1 if unset or
# unparseable.
google_sa_json() {
  local sa="${GOOGLE_SERVICE_ACCOUNT:-}" json=""
  [ -n "$sa" ] || return 1
  if [ -f "$sa" ]; then
    json=$(cat "$sa" 2>/dev/null)
  elif jq -e . >/dev/null 2>&1 <<<"$sa"; then
    json="$sa"
  else
    json=$(printf '%s' "$sa" | base64 -d 2>/dev/null)
  fi
  jq -e . >/dev/null 2>&1 <<<"$json" || return 1
  printf '%s' "$json"
}

# google_sa_access_token <scope> -- echo an access token for <scope> (space-
# separated for multiple scopes). Empty + rc=1 on any failure.
google_sa_access_token() {
  local scope="$1" json ce tu pk now exp header claims si sig jwt resp tok
  [ -n "$scope" ] || return 1
  json=$(google_sa_json) || return 1
  ce=$(jq -r '.client_email // empty' <<<"$json"); [ -n "$ce" ] || return 1
  tu=$(jq -r --arg d "$GOOGLE_TOKEN_EP_DEFAULT" '.token_uri // $d' <<<"$json")
  pk=$(jq -r '.private_key // empty' <<<"$json"); [ -n "$pk" ] || return 1
  now=$(date +%s); exp=$((now + 3600))
  header=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | _google_b64url)
  claims=$(jq -cn --arg iss "$ce" --arg sc "$scope" --arg aud "$tu" \
             --argjson iat "$now" --argjson exp "$exp" \
             '{iss:$iss, scope:$sc, aud:$aud, iat:$iat, exp:$exp}' | _google_b64url)
  si="${header}.${claims}"
  sig=$(printf '%s' "$si" | openssl dgst -sha256 -sign <(printf '%s' "$pk") 2>/dev/null | _google_b64url) || return 1
  [ -n "$sig" ] || return 1
  jwt="${si}.${sig}"
  resp=$(curl -fsS -X POST "$tu" \
    --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
    --data-urlencode "assertion=${jwt}" 2>/dev/null) || return 1
  tok=$(jq -r '.access_token // empty' <<<"$resp" 2>/dev/null)
  [ -n "$tok" ] || return 1
  printf '%s' "$tok"
}
