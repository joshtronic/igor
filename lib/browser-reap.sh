#!/usr/bin/env bash
# browser-reap.sh -- kill stale headless-browser (chrome/playwright) process
# trees at the top of every maintenance tick. This is a headless server:
# there is no desktop browser, so every chrome/chromium/headless_shell/
# playwright process is automation (screenshots, visual self-verification,
# deploy smoke). A legitimate capture finishes in seconds to low
# single-digit minutes -- anything alive past the threshold is a leak,
# full stop.
#
# Requires bash; sourced by bin/tick.sh.

if ! declare -F log >/dev/null; then
  log() { printf '[agent] %s\n' "$*"; }
fi

# Hardcoded per the "strong opinions" convention -- not an env knob. 60 min
# is ~10x any real capture and matches the "1-2h is too long" bar.
BROWSER_REAP_STALE_SECS=3600

# Never selected, no matter the age or cmdline -- the harness's own driver
# process. Guards against a false-positive signature match (e.g. an MCP
# node process that happens to carry "playwright" somewhere in its argv)
# ever reaping the thing running the reaper.
_browser_reap_is_protected() {
  case "$1" in
    claude | node) return 0 ;;
    *) return 1 ;;
  esac
}

# Binary basenames that are ALWAYS automation on this headless host.
_browser_reap_is_browser_binary() {
  case "$1" in
    headless_shell | chrome | chromium | chromium-browser | chrome_crashpad_handler) return 0 ;;
    *) return 1 ;;
  esac
}

# Cmdline substrings that mark a process as browser automation even when
# the binary basename doesn't match one of the above (e.g. a wrapped or
# renamed launcher).
_browser_reap_cmd_matches() {
  case "$1" in
    *--headless* | *--remote-debugging-port* | *--user-data-dir=/tmp* | *playwright* | *puppeteer*) return 0 ;;
    *) return 1 ;;
  esac
}

# browser_reap_select_victims -- pure predicate. Reads a ps-style table on
# stdin, one process per line: "pid ppid etimes cmd..." (whitespace
# separated; cmd is the remainder of the line, so internal spaces in the
# command survive). Echoes one pid per line for every process that is
# BOTH stale (etimes >= BROWSER_REAP_STALE_SECS) AND matches an automation
# signature (binary basename or cmdline substring) AND isn't protected.
# No side effects -- never kills anything, so it's safe to unit-test
# against a mock table.
browser_reap_select_victims() {
  local pid etimes cmd base
  while read -r pid _ etimes cmd; do
    [ -z "$pid" ] && continue
    case "$pid" in *[!0-9]*) continue ;; esac
    [ -n "$etimes" ] || continue
    case "$etimes" in *[!0-9]*) continue ;; esac
    [ "$etimes" -ge "$BROWSER_REAP_STALE_SECS" ] || continue

    base=$(basename "${cmd%% *}")
    _browser_reap_is_protected "$base" && continue

    if _browser_reap_is_browser_binary "$base" || _browser_reap_cmd_matches "$cmd"; then
      echo "$pid"
    fi
  done
}

# _browser_reap_kill_tree <pid> -- SIGKILL pid and every descendant.
# Chrome forks a renderer/GPU/zygote tree; killing just the parent orphans
# the children, so this walks children by PPID (via ps) rather than
# assuming a process-group invariant.
_browser_reap_kill_tree() {
  local pid="$1" child
  for child in $(ps -eo pid=,ppid= 2>/dev/null | awk -v p="$pid" '$2==p{print $1}'); do
    _browser_reap_kill_tree "$child"
  done
  kill -9 "$pid" 2>/dev/null || true
}

# browser_reap_sweep -- effectful entry point, called at the top of every
# maintenance tick. Snapshots the process table, selects victims via the
# pure predicate above, kills each victim's whole tree, and logs one line
# per victim (pid, etime, truncated cmdline). Silent no-op when nothing is
# stale -- the normal case.
browser_reap_sweep() {
  local table victims pid row etimes cmd
  table=$(ps -eo pid=,ppid=,etimes=,args= 2>/dev/null) || return 0
  [ -z "$table" ] && return 0

  victims=$(browser_reap_select_victims <<<"$table")
  [ -z "$victims" ] && return 0

  while read -r pid; do
    [ -z "$pid" ] && continue
    row=$(grep -E "^[[:space:]]*${pid}[[:space:]]" <<<"$table" | head -n1)
    read -r _ _ etimes cmd <<<"$row"
    log "browser-reap: killing pid=$pid etime=${etimes}s cmd=${cmd:0:120}"
    _browser_reap_kill_tree "$pid"
  done <<<"$victims"
}
