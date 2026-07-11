#!/usr/bin/env bash
# test-forgejo.sh -- unit tests for forgejo_find_claimable (lib/forgejo.sh), the
# greenlight gate. The `Agent` label is REQUIRED and re-verified client-side, so
# the gate fails CLOSED even when Forgejo ignores the `labels=Agent` API filter
# -- which it does on a repo that has no `Agent` label, returning every open
# issue instead of none. Skip-safe: needs jq; exits 0 with a notice if absent.
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "test-forgejo: jq absent -- skipping"; exit 0; }

HERE="$(cd "$(dirname "$0")" && pwd)"
export FORGEJO_URL="https://example.invalid" FORGEJO_TOKEN="test-token"
# shellcheck source=../lib/forgejo.sh
. "$HERE/../lib/forgejo.sh"

FAIL=0
eq() {  # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then printf '  + %s\n' "$1"
  else printf '  x %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi
}

# Fixture: what Forgejo returns when it IGNORES the labels=Agent filter (a repo
# with no Agent label) -- a mix of Agent-labeled and unlabeled/other issues,
# assignees, and a blocked one.
FIXTURE='[
  {"number":1,"created_at":"2026-01-01T00:00:00Z","assignees":[],"labels":[{"name":"Agent"}]},
  {"number":2,"created_at":"2026-01-02T00:00:00Z","assignees":[],"labels":[]},
  {"number":3,"created_at":"2026-01-03T00:00:00Z","assignees":[],"labels":[{"name":"Kind/Bug"}]},
  {"number":4,"created_at":"2026-01-04T00:00:00Z","assignees":[{"login":"josh"}],"labels":[{"name":"Agent"}]},
  {"number":5,"created_at":"2026-01-05T00:00:00Z","assignees":[{"login":"someone"}],"labels":[{"name":"Agent"}]},
  {"number":6,"created_at":"2026-01-06T00:00:00Z","assignees":[],"labels":[{"name":"Agent"},{"name":"Status/Blocked"}]},
  {"number":7,"created_at":"2025-12-31T00:00:00Z","assignees":[],"labels":[{"name":"Agent"}]}
]'
_fj() { printf '%s' "$FIXTURE"; }

echo "== forgejo_find_claimable: Agent label required, fails closed =="

OUT=$(forgejo_find_claimable acme/x josh)
eq "only Agent-labeled survive (unlabeled #2, other-label #3 dropped)" \
  "1 4 7" "$(jq -r '[.[].number] | sort | join(" ")' <<<"$OUT")"
eq "oldest-first ordering" "7 1 4" "$(jq -r '[.[].number] | join(" ")' <<<"$OUT")"
eq "assigned-to-reviewer kept, assigned-to-other dropped" \
  "true" "$(jq -r '([.[].number] | index(4) != null) and ([.[].number] | index(5) == null)' <<<"$OUT")"
eq "Status/Blocked dropped even with Agent" \
  "true" "$(jq -r '[.[].number] | index(6) == null' <<<"$OUT")"

OUT=$(forgejo_find_claimable acme/x "")
eq "no reviewer -> only unassigned Agent issues" \
  "1 7" "$(jq -r '[.[].number] | sort | join(" ")' <<<"$OUT")"

# The regression this guards: a repo with NO Agent label makes Forgejo return
# every open issue (filter ignored). The client-side check must drop them all.
NOAGENT='[
  {"number":10,"created_at":"2026-02-01T00:00:00Z","assignees":[],"labels":[]},
  {"number":11,"created_at":"2026-02-02T00:00:00Z","assignees":[],"labels":[{"name":"Kind/Feature"}]}
]'
_fj() { printf '%s' "$NOAGENT"; }
eq "repo missing Agent label -> nothing claimable (fails CLOSED)" \
  "[]" "$(forgejo_find_claimable acme/x josh | jq -c '[.[].number]')"

if [ "$FAIL" -eq 0 ]; then echo "test-forgejo: all checks passed"; exit 0; fi
echo "test-forgejo: $FAIL check(s) FAILED"
exit 1
