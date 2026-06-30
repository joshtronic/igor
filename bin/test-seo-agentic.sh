#!/usr/bin/env bash
# test-seo-agentic.sh -- unit tests for seo_agentic_repo_for (lib/seo-analysis.sh).
#
# Resolves an agentic SEO domain -> Forgejo repo from each repo's agent.json
# `.seo` ({"domain":...,"agentic":true}). Covers: a domain match resolves, the
# agentic flag gates, a domain mismatch / a repo with no `.seo` / no match
# anywhere all return empty.
#
# Run standalone (`bin/test-seo-agentic.sh`) or via `make test`. Skip-safe.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
command -v jq >/dev/null 2>&1 || { echo "test-seo-agentic: jq not installed -- skipping"; exit 0; }

log() { :; }   # tick.sh provides log() at runtime; no-op here
# shellcheck source=lib/seo-analysis.sh
. "$HERE/lib/seo-analysis.sh"

fails=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; fails=$((fails + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi; }

# -- Stubs for the two forgejo helpers the resolver composes ----------------
STUB_REPOS='[{"full_name":"joshtronic/sharktank.co"},{"full_name":"joshtronic/igor"}]'
forgejo_list_bot_repos() { printf '%s' "$STUB_REPOS"; }
# shellcheck disable=SC2329  # invoked indirectly via the forgejo_repo_get_file stub
stub_cfg() { return 1; }                          # default: no agent.json anywhere
forgejo_repo_get_file() { stub_cfg "$1"; }        # <repo> <path> -> agent.json content

echo "== seo_agentic_repo_for =="

# 1. agent.json domain match + agentic:true -> that repo
stub_cfg() { case "$1" in
  joshtronic/sharktank.co) printf '{"seo":{"domain":"sharktank.co","agentic":true}}' ;;
  *) return 1 ;; esac; }
eq "match domain + agentic:true -> repo" "joshtronic/sharktank.co" \
   "$(seo_agentic_repo_for sharktank.co)"

# 2. domain matches but agentic:false -> no match
stub_cfg() { case "$1" in
  joshtronic/sharktank.co) printf '{"seo":{"domain":"sharktank.co","agentic":false}}' ;;
  *) return 1 ;; esac; }
eq "agentic:false -> empty" "" \
   "$(seo_agentic_repo_for sharktank.co)"

# 3. agentic repo exists but for a different domain -> no match
stub_cfg() { case "$1" in
  joshtronic/sharktank.co) printf '{"seo":{"domain":"sharktank.co","agentic":true}}' ;;
  *) return 1 ;; esac; }
eq "domain mismatch -> empty" "" \
   "$(seo_agentic_repo_for porksicle.com)"

# 4. no agentic repo matches anywhere -> empty
stub_cfg() { return 1; }
eq "no match anywhere -> empty" "" \
   "$(seo_agentic_repo_for sharktank.co)"

# 5. a repo with agent.json but no .seo block is ignored
STUB_REPOS='[{"full_name":"joshtronic/igor"}]'
stub_cfg() { case "$1" in
  joshtronic/igor) printf '{"smoke":{"url":"https://x"}}' ;;
  *) return 1 ;; esac; }
eq "agent.json without .seo -> empty" "" \
   "$(seo_agentic_repo_for sharktank.co)"

if [ "$fails" -eq 0 ]; then
  echo "test-seo-agentic: all checks passed"; exit 0
else
  echo "test-seo-agentic: $fails check(s) failed"; exit 1
fi
