#!/usr/bin/env bash
# Unit tests for lib/deferred.sh -- the deferred-ticket gate pass.
# Skip-safe: exits 0 with a notice if a required tool is missing. Only the PURE
# helpers are exercised (no network, no model calls, no _fj).
set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/deferred.sh
. "$HERE/lib/deferred.sh"

for t in jq sed; do
  command -v "$t" >/dev/null 2>&1 || { echo "test-deferred: $t unavailable -- skipping"; exit 0; }
done

FAIL=0
eq() { if [ "$2" = "$3" ]; then printf '  + %s\n' "$1"; else printf '  x %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi; }

GATE='some intro text
<!-- gate
url: https://docs.example.com/release-notes/
condition: Example lists a working Ubuntu 26.04 LTS image
-->
trailing text'

echo "== gate parsing =="
eq "extracts url"         "https://docs.example.com/release-notes/" "$(deferred_parse_gate_url "$GATE")"
eq "extracts condition"   "Example lists a working Ubuntu 26.04 LTS image" "$(deferred_parse_gate_condition "$GATE")"
eq "no gate -> empty url"  "" "$(deferred_parse_gate_url "just a normal body, no gate here")"

WS='  <!-- gate
   url:     https://x.test/p
   condition:   the thing happened
  -->'
eq "url tolerates whitespace"       "https://x.test/p" "$(deferred_parse_gate_url "$WS")"
eq "condition tolerates whitespace" "the thing happened" "$(deferred_parse_gate_condition "$WS")"

echo "== verdict parsing (FAIL CLOSED) =="
eq "MET parses"                  "MET"   "$(deferred_parse_verdict 'GATE: MET
EVIDENCE: image is listed')"
eq "UNMET not mistaken for MET"  "UNMET" "$(deferred_parse_verdict 'GATE: UNMET
EVIDENCE: still coming soon')"
eq "lowercase value handled"     "MET"   "$(deferred_parse_verdict 'GATE: met')"
eq "garbage -> UNMET (closed)"   "UNMET" "$(deferred_parse_verdict 'I think it might be ready, hard to say')"
eq "empty -> UNMET (closed)"     "UNMET" "$(deferred_parse_verdict '')"
eq "evidence extracted"          "image is listed" "$(deferred_parse_evidence 'GATE: MET
EVIDENCE: image is listed')"

echo "== fetch hardening (HTTPS ONLY, no network) =="
eq "http:// rejected -> empty"   "" "$(deferred_fetch 'http://insecure.test/x')"
eq "file:// rejected -> empty"   "" "$(deferred_fetch 'file:///etc/passwd')"
eq "bare host rejected -> empty" "" "$(deferred_fetch 'not-a-url')"

if [ "$FAIL" -eq 0 ]; then
  echo "test-deferred: all checks passed"
else
  echo "test-deferred: $FAIL FAILED"
  exit 1
fi
