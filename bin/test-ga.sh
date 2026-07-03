#!/usr/bin/env bash
# test-ga.sh -- unit tests for lib/ga.sh (GA4 client) and its SEO fold-in
# (lib/seo-analysis.sh: seo_ga_metrics, seo_build_report's ga passthrough,
# and the "On-site behavior (GA)" section in both renderers).
#
# Covers, against fixture JSON (curl stubbed -- no network):
#   - ga_property_for_domain: match, no-match, non-JSON/failure
#   - ga_run_report: request shape (empty dims -> []), happy parse, failure
#   - seo_ga_metrics: full metric set, keyEvents absent, empty rows
#   - the SEO GA branches: with-property renders the section (both
#     renderers), without-property renders exactly as today (GSC-only)
#
# Run standalone (`bin/test-ga.sh`) or via `make test`. Skip-safe: exits 0
# with a notice if jq is absent.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
command -v jq >/dev/null 2>&1 || { echo "test-ga: jq not installed -- skipping"; exit 0; }

log() { :; }   # tick.sh provides log() at runtime; no-op here
# shellcheck source=lib/ga.sh
. "$HERE/lib/ga.sh"
# shellcheck source=lib/seo-analysis.sh
. "$HERE/lib/seo-analysis.sh"

# ga_access_token is delegated to lib/google-auth.sh (not sourced here) --
# stub it directly so ga_property_for_domain / ga_run_report can run
# without real auth.
ga_access_token() { printf 'fake-token'; }

FAIL=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi; }
has()    { case "$2" in *"$3"*) ok "$1";; *) bad "$1: missing [$3]";; esac; }
hasnt()  { case "$2" in *"$3"*) bad "$1: unexpected [$3]";; *) ok "$1";; esac; }
no() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d (rc!=0 expected)"; else ok "$d"; fi; }

echo "== ga_property_for_domain =="

ACCOUNT_SUMMARIES='{
  "accountSummaries": [
    { "account":"accounts/1", "propertySummaries": [
        {"property":"properties/535124688","displayName":"certifiedtradejobs.com"},
        {"property":"properties/487911904","displayName":"vpsshowdown.com"} ] },
    { "account":"accounts/2", "propertySummaries": [
        {"property":"properties/404967917","displayName":"sharktank.co"} ] }
  ]
}'
curl() { printf '%s' "$ACCOUNT_SUMMARIES"; }
eq "match -> strips properties/ prefix" "535124688" "$(ga_property_for_domain certifiedtradejobs.com)"
eq "match -> second account"            "404967917" "$(ga_property_for_domain sharktank.co)"
eq "no match -> empty"                  ""          "$(ga_property_for_domain nomatch.com)"
unset -f curl

curl() { return 1; }
no "curl failure -> rc 1" ga_property_for_domain sharktank.co
unset -f curl

curl() { printf 'not json'; }
no "non-JSON response -> rc 1" ga_property_for_domain sharktank.co
unset -f curl

echo "== ga_run_report =="

RUN_REPORT='{
  "metricHeaders": [
    {"name":"sessions"},{"name":"engagedSessions"},{"name":"engagementRate"},
    {"name":"totalUsers"},{"name":"keyEvents"} ],
  "rows": [ { "metricValues": [
      {"value":"1000"},{"value":"650"},{"value":"0.65"},{"value":"800"},{"value":"12"} ] } ],
  "rowCount": 1
}'
BODY_FILE=$(mktemp)
trap 'rm -f "$BODY_FILE"' EXIT
curl() {
  local i j; for ((i=1; i<=$#; i++)); do
    [ "${!i}" = "-d" ] && { j=$((i+1)); printf '%s' "${!j}" > "$BODY_FILE"; }
  done
  printf '%s' "$RUN_REPORT"
}
resp=$(ga_run_report 404967917 2026-06-01 2026-06-28 "" "sessions,engagedSessions,engagementRate,totalUsers,keyEvents")
BODY_SEEN=$(cat "$BODY_FILE")
eq "happy: echoes the fixture" "$(jq -c . <<<"$RUN_REPORT")" "$(jq -c . <<<"$resp")"
eq "empty dims -> dimensions:[]" "[]" "$(jq -c '.dimensions' <<<"$BODY_SEEN")"
eq "metrics threaded into the request body" \
   '["sessions","engagedSessions","engagementRate","totalUsers","keyEvents"]' \
   "$(jq -c '[.metrics[].name]' <<<"$BODY_SEEN")"
eq "date range threaded into the request body" \
   '{"startDate":"2026-06-01","endDate":"2026-06-28"}' \
   "$(jq -c '.dateRanges[0]' <<<"$BODY_SEEN")"
unset -f curl

curl() { return 1; }
if out=$(ga_run_report 1 2026-06-01 2026-06-28 "" "sessions"); then
  bad "curl failure -> rc 1"
else
  ok "curl failure -> rc 1"
fi
eq "curl failure -> empty-rows JSON" '{"rows":[]}' "$out"
unset -f curl

echo "== seo_ga_metrics =="

eq "full metric set parsed" \
   '{"sessions":1000,"engagedSessions":650,"engagementRate":0.65,"totalUsers":800,"keyEvents":12}' \
   "$(seo_ga_metrics "$RUN_REPORT")"

NO_KEY_EVENTS='{
  "metricHeaders":[{"name":"sessions"},{"name":"engagedSessions"},{"name":"engagementRate"},{"name":"totalUsers"}],
  "rows":[{"metricValues":[{"value":"10"},{"value":"5"},{"value":"0.5"},{"value":"9"}]}],
  "rowCount":1
}'
eq "keyEvents absent -> null" "null" "$(jq -r '.keyEvents' <<<"$(seo_ga_metrics "$NO_KEY_EVENTS")")"
eq "keyEvents absent -> other fields still parsed" "10" "$(jq -r '.sessions' <<<"$(seo_ga_metrics "$NO_KEY_EVENTS")")"

eq "empty rows -> null" "null" "$(seo_ga_metrics '{"rows":[]}')"

echo "== seo_build_report: ga passthrough =="

EMPTY='{"rows":[]}'
report_default=$(seo_build_report example.com "$EMPTY" "$EMPTY" "$EMPTY" "$EMPTY" "$EMPTY" \
                    2026-06-01 2026-06-28 2026-05-01 2026-05-28)
eq "ga arg omitted -> defaults to null" "null" "$(jq -c '.ga' <<<"$report_default")"

GA_METRICS='{"sessions":1000,"engagedSessions":650,"engagementRate":0.65,"totalUsers":800,"keyEvents":12}'
report_ga=$(seo_build_report example.com "$EMPTY" "$EMPTY" "$EMPTY" "$EMPTY" "$EMPTY" \
              2026-06-01 2026-06-28 2026-05-01 2026-05-28 "$GA_METRICS")
eq "ga arg threaded through" "$(jq -c . <<<"$GA_METRICS")" "$(jq -c '.ga' <<<"$report_ga")"

echo "== SEO renderers: GA section is additive/optional =="

md_no_ga=$(seo_render_markdown <<<"$report_default")
md_ga=$(seo_render_markdown <<<"$report_ga")
html_no_ga=$(seo_render_html <<<"$report_default")
html_ga=$(seo_render_html <<<"$report_ga")

hasnt "no GA property: markdown has no GA section" "$md_no_ga" "On-site behavior"
hasnt "no GA property: html has no GA section"     "$html_no_ga" "On-site behavior"
has   "with GA: markdown section header"    "$md_ga" "## On-site behavior (GA)"
has   "with GA: markdown sessions"          "$md_ga" "1000 sessions"
has   "with GA: markdown engagement rate"   "$md_ga" "65% engagement rate"
has   "with GA: markdown key events"        "$md_ga" "12 key events"
has   "with GA: html section header"        "$html_ga" "<h3>On-site behavior (GA)</h3>"
has   "with GA: html sessions"              "$html_ga" "1000 sessions"

if [ "$FAIL" -eq 0 ]; then echo "test-ga: all passed"; else echo "test-ga: $FAIL FAILED"; exit 1; fi
