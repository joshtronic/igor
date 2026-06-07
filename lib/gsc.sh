#!/usr/bin/env bash
# gsc.sh -- Google Search Console API client for the SEO analysis pass.
# Isolates every GSC network call. Sourced by bin/tick.sh.
#
# The SEO subsystem is opt-in; callers gate on these being set:
#   GSC_OAUTH_CLIENT_ID, GSC_OAUTH_CLIENT_SECRET, GSC_OAUTH_REFRESH_TOKEN
# (mint the refresh token once with bin/gsc-auth.sh).
#
# Requires on PATH: curl, jq.
#
# Auth model: the durable refresh token is exchanged for a short-lived
# access token at the start of each pass. Access tokens are never stored.

# Fallback logger so this module is sourceable standalone (tests).
if ! declare -F log >/dev/null; then
  log() { printf '[agent] %s\n' "$*"; }
fi

GSC_TOKEN_EP="https://oauth2.googleapis.com/token"
GSC_API="https://www.googleapis.com/webmasters/v3"

# gsc_access_token
# Echoes a fresh OAuth access token on stdout; empty + rc=1 on failure.
gsc_access_token() {
  local resp tok
  resp=$(curl -fsS -X POST "$GSC_TOKEN_EP" \
    --data-urlencode "client_id=${GSC_OAUTH_CLIENT_ID}" \
    --data-urlencode "client_secret=${GSC_OAUTH_CLIENT_SECRET}" \
    --data-urlencode "refresh_token=${GSC_OAUTH_REFRESH_TOKEN}" \
    --data-urlencode "grant_type=refresh_token" 2>/dev/null) || return 1
  tok=$(jq -r '.access_token // empty' <<<"$resp" 2>/dev/null)
  [ -n "$tok" ] || return 1
  printf '%s' "$tok"
}

# gsc_list_domains <access_token>
# Echoes one domain per line for every sc-domain: property. URL-prefix
# ("site") properties are intentionally ignored -- domain properties only.
gsc_list_domains() {
  local token="$1"
  curl -fsS -H "Authorization: Bearer $token" "$GSC_API/sites" 2>/dev/null \
    | jq -r '.siteEntry[]?
              | select(.siteUrl | startswith("sc-domain:"))
              | .siteUrl | sub("^sc-domain:"; "")' 2>/dev/null
}

# gsc_query <access_token> <domain> <start> <end> <dimensions_csv> [row_limit]
# Runs a Search Analytics query and echoes the raw JSON response (a
# {rows:[{keys,clicks,impressions,ctr,position}]} object). Echoes
# '{"rows":[]}' and rc=1 on failure so callers can use the result
# unconditionally. dimensions_csv e.g. "query" | "page" | "query,page".
gsc_query() {
  local token="$1" domain="$2" start="$3" end="$4" dims="$5" limit="${6:-25000}"
  local site_enc dims_json body resp
  # Path segment is the URL-encoded property id ("sc-domain:example.com").
  site_enc=$(jq -rn --arg s "sc-domain:$domain" '$s|@uri')
  dims_json=$(printf '%s' "$dims" | jq -Rc 'split(",")')
  body=$(jq -n --arg s "$start" --arg e "$end" \
            --argjson d "$dims_json" --argjson l "$limit" \
            '{startDate:$s, endDate:$e, dimensions:$d, rowLimit:$l}')
  resp=$(curl -fsS -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "$GSC_API/sites/${site_enc}/searchAnalytics/query" 2>/dev/null) || {
      printf '%s' '{"rows":[]}'; return 1;
    }
  # Guard against a non-JSON/empty body.
  jq -e . >/dev/null 2>&1 <<<"$resp" || { printf '%s' '{"rows":[]}'; return 1; }
  printf '%s' "$resp"
}
