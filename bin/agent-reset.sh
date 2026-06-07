#!/usr/bin/env bash
# agent-reset.sh -- clear discretionary-work state for testing.
#
# The harness throttles its own scheduled work via stamps in
# discretionary-state.json (daily slots, weekly slots, per-repo
# maintenance, per-domain SEO). During a test session you often want to
# re-trigger a pass without waiting for the day/week to roll. This zeroes
# the relevant stamps so the next tick treats the work as due again.
#
# Usage:
#   bin/agent-reset.sh maintenance   # re-arm the weekly dep/security audit (all repos)
#   bin/agent-reset.sh seo           # re-arm the weekly SEO pass (all domains)
#   bin/agent-reset.sh slots         # re-open today's daily slots (reading, post)
#   bin/agent-reset.sh weekly        # re-open this week's weekly slots (/now, site-work)
#   bin/agent-reset.sh all           # all of the above + the SEO opportunity log
#
# Safe and idempotent: resetting state the harness can rebuild. Does not
# touch Forgejo, clones, or the brain. Run on the server (or wherever
# AGENT_STATE_DIR lives).

set -euo pipefail

AGENT_STATE_DIR="${AGENT_STATE_DIR:-$HOME/.local/state/agent}"
STATE_FILE="$AGENT_STATE_DIR/discretionary-state.json"
SEO_LOG="$AGENT_STATE_DIR/seo-opportunities.jsonl"

target="${1:-}"
case "$target" in
  maintenance|seo|slots|weekly|all) ;;
  *)
    echo "usage: $(basename "$0") {maintenance|seo|slots|weekly|all}" >&2
    exit 2
    ;;
esac

if [ ! -f "$STATE_FILE" ]; then
  echo "agent-reset: no state file at $STATE_FILE -- nothing to reset (next tick starts fresh)"
  exit 0
fi

# Map the target to the jq deletions to apply.
filter='.'
case "$target" in
  maintenance) filter='del(.maintenance)' ;;
  seo)         filter='del(.seo)' ;;
  slots)       filter='del(.slots)' ;;
  weekly)      filter='del(.weekly)' ;;
  all)         filter='del(.maintenance, .seo, .slots, .weekly)' ;;
esac

tmp=$(mktemp)
jq "$filter" "$STATE_FILE" > "$tmp"
mv "$tmp" "$STATE_FILE"
echo "agent-reset: cleared '$target' state in $STATE_FILE"

if [ "$target" = "all" ] && [ -f "$SEO_LOG" ]; then
  rm -f "$SEO_LOG"
  echo "agent-reset: removed SEO opportunity log $SEO_LOG"
fi
