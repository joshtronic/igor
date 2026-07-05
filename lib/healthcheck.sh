#!/usr/bin/env bash
# healthcheck.sh -- dead-man's-switch pings for an external monitor (e.g.
# healthchecks.io). Sourced by bin/tick.sh. Purely opt-in: with its URL
# unset, hc_ping is a silent no-op (no curl, no network) -- same posture
# as the SMTP2GO / GSC gates. Best-effort even when configured: a ping
# NEVER affects tick outcome, so callers don't need to guard the call.
#
# Two independent checks, wired by bin/tick.sh:
#   HEALTHCHECK_HEARTBEAT_URL -- plain ping at the top of every tick
#     (check A: proves the timer + script are still firing at all).
#   HEALTHCHECK_TASK_URL -- start/success/fail around the cascade's
#     real-work path (check B: a start with no matching success/fail
#     means the tick crashed or hung mid-cascade).
#
# Requires on PATH: curl.

# hc_ping <which> [start|success|fail]
# <which> selects the URL: "heartbeat" -> HEALTHCHECK_HEARTBEAT_URL,
# "task" -> HEALTHCHECK_TASK_URL. [state] defaults to a plain ping (the
# healthchecks.io convention: start/fail hit "<url>/start" and
# "<url>/fail"; a bare/"success" ping hits the base URL). Always
# returns 0 -- an unset URL or a failed curl are both silent no-ops.
hc_ping() {
  local which="$1" state="${2:-success}" url=""
  case "$which" in
    heartbeat) url="${HEALTHCHECK_HEARTBEAT_URL:-}" ;;
    task)      url="${HEALTHCHECK_TASK_URL:-}" ;;
  esac
  [ -n "$url" ] || return 0
  case "$state" in
    start) url="${url}/start" ;;
    fail)  url="${url}/fail" ;;
    *) : ;;
  esac
  curl -fsS --max-time 10 -o /dev/null "$url" 2>/dev/null || true
  return 0
}
