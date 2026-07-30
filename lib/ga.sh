#!/usr/bin/env bash
# ga.sh -- Google Analytics (GA4) API client for the SEO analysis pass.
# Mirrors lib/gsc.sh. Sourced by bin/tick.sh.
#
# GA is additive and OPTIONAL: a domain with no matching GA4 property must
# leave the SEO report unchanged (see lib/seo-analysis.sh). Auth is
# delegated to lib/google-auth.sh (google_sa_access_token) -- the same
# service account GSC uses, just a different scope.
#
# Requires on PATH: curl, jq.

# Fallback logger so this module is sourceable standalone (tests).
if ! declare -F log >/dev/null; then
  log() { printf '[agent] %s\n' "$*" >&2; }
fi

GA_ADMIN_API="https://analyticsadmin.googleapis.com/v1beta"
GA_DATA_API="https://analyticsdata.googleapis.com/v1beta"
GA_SCOPE="https://www.googleapis.com/auth/analytics.readonly"

# ga_access_token
# Echoes a fresh access token on stdout; empty + rc=1 on failure. Delegates
# to the shared service-account minter (lib/google-auth.sh).
ga_access_token() {
  google_sa_access_token "$GA_SCOPE"
}

# ga_property_for_domain <domain>
# Resolves the numeric GA4 property id dynamically: GETs accountSummaries
# and returns the propertySummaries[].property (with the "properties/"
# prefix stripped) whose displayName == <domain>. Empty if none, or on
# any auth/network failure. No static map -- mirrors GSC's zero-config
# domain enumeration.
ga_property_for_domain() {
  local domain="$1" token resp
  token=$(ga_access_token) || return 1
  resp=$(curl -fsS -H "Authorization: Bearer $token" \
    "$GA_ADMIN_API/accountSummaries?pageSize=200" 2>/dev/null) || return 1
  jq -e . >/dev/null 2>&1 <<<"$resp" || return 1
  jq -r --arg d "$domain" '
    [ .accountSummaries[]?.propertySummaries[]?
      | select(.displayName == $d)
      | (.property | sub("^properties/"; "")) ]
    | first // empty
  ' <<<"$resp" 2>/dev/null
}

# ga_run_report <property_id> <start> <end> <dimensions_csv> <metrics_csv>
# Runs a GA4 Data API report (POST properties/<id>:runReport) and echoes
# the raw JSON response. dimensions_csv may be empty (aggregate-only
# report). Echoes '{"rows":[]}' and rc=1 on failure, matching gsc_query's
# error posture so callers can use the result unconditionally.
ga_run_report() {
  local property="$1" start="$2" end="$3" dims="$4" metrics="$5"
  local token dims_json metrics_json body resp
  token=$(ga_access_token) || { printf '%s' '{"rows":[]}'; return 1; }
  if [ -n "$dims" ]; then
    dims_json=$(printf '%s' "$dims" | jq -Rc 'split(",") | map({name:.})')
  else
    dims_json='[]'
  fi
  metrics_json=$(printf '%s' "$metrics" | jq -Rc 'split(",") | map({name:.})')
  body=$(jq -n --arg s "$start" --arg e "$end" \
            --argjson d "$dims_json" --argjson m "$metrics_json" \
            '{dateRanges:[{startDate:$s, endDate:$e}], dimensions:$d, metrics:$m}')
  resp=$(curl -fsS -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "$GA_DATA_API/properties/${property}:runReport" 2>/dev/null) || {
      printf '%s' '{"rows":[]}'; return 1;
    }
  # Guard against a non-JSON/empty body.
  jq -e . >/dev/null 2>&1 <<<"$resp" || { printf '%s' '{"rows":[]}'; return 1; }
  printf '%s' "$resp"
}
