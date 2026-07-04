#!/usr/bin/env bash
# lib/logwatch.sh -- pure helper for the hourly logwatch pass
# (bin/tick.sh do_logwatch_tick). Split out from tick.sh only so it's
# unit-testable in isolation; the rest of the pass (journal reads, the
# review-tier model call, ticket filing) stays in tick.sh.
#
# Source order: no dependencies beyond jq.

# logwatch_health_backoff_in_window <state_file> <win_start_epoch> <win_end_epoch>
# 0 (true) when the CURRENT Claude health record (lib/claude.sh's
# .health: first_failure/cooldown_until/kind) shows an auth/limit
# backoff that overlapped [win_start_epoch, win_end_epoch) -- the
# clock hour do_logwatch_tick is about to review. Deliberately reads
# claude_health_blocked-style raw state rather than that function
# itself: claude_health_blocked answers "is a backoff live right now",
# but logwatch reviews the hour that already closed, by which the
# backoff may have lifted.
#
# Known MVP gap: a successful call after the cooldown lapses resets
# first_failure/cooldown_until to 0 (claude_health_record_ok), which
# erases the overlap this checks for. Accepted for now -- the common
# case (a cooldown still live, or just-lapsed with no successful call
# yet) is caught; recovering the erased-history case is a follow-up.
logwatch_health_backoff_in_window() {
  local state_file="$1" win_start_epoch="$2" win_end_epoch="$3"
  local kind first_failure cooldown_until
  [ -f "$state_file" ] || return 1
  kind=$(jq -r '.health.kind // ""' "$state_file" 2>/dev/null)
  case "$kind" in
    auth|limit) ;;
    *) return 1 ;;
  esac
  first_failure=$(jq -r '.health.first_failure // 0' "$state_file" 2>/dev/null)
  cooldown_until=$(jq -r '.health.cooldown_until // 0' "$state_file" 2>/dev/null)
  [ "$first_failure" -gt 0 ] || return 1
  [ "$first_failure" -lt "$win_end_epoch" ] && [ "$cooldown_until" -gt "$win_start_epoch" ]
}
