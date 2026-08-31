#!/usr/bin/env bash
# Unit tests for lib/deferred.sh -- the deferred-ticket gate pass.
# Skip-safe: exits 0 with a notice if a required tool is missing. Only the PURE
# helpers are exercised (no network, no model calls; forgejo_* boundaries stubbed).
set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/deferred.sh
. "$HERE/lib/deferred.sh"

for t in jq sed; do
  command -v "$t" >/dev/null 2>&1 || { echo "test-deferred: $t unavailable -- skipping"; exit 0; }
done

FAIL=0
eq() { if [ "$2" = "$3" ]; then printf '  + %s\n' "$1"; else printf '  x %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi; }
has() { case "$2" in *"$3"*) printf '  + %s\n' "$1" ;; *) printf '  x %s: [%s] lacks [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)) ;; esac; }

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

echo "== deferred_release_to_reviewer: gate MET hands to the human, not the grind =="
# Stub the forgejo boundaries (test-deferred sources only deferred.sh).
REMOVED=""; ASSIGNED="none"; COMMENTED=0
forgejo_remove_label() { REMOVED="$REMOVED $3"; }   # $3 = label name
forgejo_assign()       { ASSIGNED="$1#$2->$3"; }
forgejo_comment()      { COMMENTED=1; }
log() { :; }
deferred_release_to_reviewer acme/x 7 reviewer "the image is listed"
has "release: dropped Status/Blocked"      "$REMOVED" "Status/Blocked"
has "release: dropped Agent greenlight"     "$REMOVED" "Agent"
eq  "release: assigned the reviewer"        "acme/x#7->reviewer" "$ASSIGNED"
eq  "release: posted a comment"             "1" "$COMMENTED"

REMOVED=""; ASSIGNED="none"
deferred_release_to_reviewer acme/x 8 "" "evidence"   # no reviewer configured
has "release(no reviewer): still drops Status/Blocked" "$REMOVED" "Status/Blocked"
eq  "release(no reviewer): skips assign"               "none" "$ASSIGNED"

if [ "$FAIL" -eq 0 ]; then
  echo "test-deferred: all checks passed"
else
  echo "test-deferred: $FAIL FAILED"
  exit 1
fi
