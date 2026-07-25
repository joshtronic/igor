#!/usr/bin/env bash
# http-reap.sh -- kill stale static-file-server process trees at the top
# of every maintenance tick. In-tick static-build verification (checking
# that a route resolves under `_site`/`dist`/etc.) has been done by
# spawning a throwaway `python3 -m http.server`-style listener and never
# reaping it (igor#418): four such orphans were found live on the host,
# reparented to init, bound to 0.0.0.0, the oldest over 8 hours old. One
# of them squatted on a port and answered a LATER tick's verification
# request with a stale build from a different repo. A legitimate
# static-file check is a curl or two and finishes in seconds -- anything
# alive past the threshold is a leak, full stop.
#
# This is a backstop, not the fix: the directive (AGENTS.md,
# site-work-directive.md) tells the agent not to spawn one of these at
# all. This sweep catches whatever slips through anyway.
#
# Requires bash; sourced by bin/tick.sh.

if ! declare -F log >/dev/null; then
  log() { printf '[agent] %s\n' "$*"; }
fi

# Hardcoded per the "strong opinions" convention -- not an env knob. A
# real static-file verification is a curl or two against localhost and
# finishes in seconds; 5 minutes is ample headroom before calling it a
# leak.
HTTP_REAP_STALE_SECS=300

# Never selected, no matter the age or cmdline -- the harness's own
# driver process. Guards against a false-positive substring match (e.g.
# an MCP node process whose module path happens to contain
# "http-server") ever reaping the thing running the reaper.
_http_reap_is_protected() {
  case "$1" in
    claude | node) return 0 ;;
    *) return 1 ;;
  esac
}

# Binary basenames that are ALWAYS a static-file server.
_http_reap_is_server_binary() {
  case "$1" in
    http-server) return 0 ;;
    *) return 1 ;;
  esac
}

# Cmdline substrings that mark a process as a throwaway static-file
# server even when the binary basename doesn't match one of the above
# (e.g. `python3 -m http.server`, where the basename is just `python3`).
_http_reap_cmd_matches() {
  case "$1" in
    *http.server* | *SimpleHTTPServer* | *http-server* | *"php -S"*) return 0 ;;
    *) return 1 ;;
  esac
}

# http_reap_select_victims -- pure predicate. Reads a ps-style table on
# stdin, one process per line: "pid ppid etimes cmd..." (whitespace
# separated; cmd is the remainder of the line, so internal spaces in the
# command survive). Echoes one pid per line for every process that is
# BOTH stale (etimes >= HTTP_REAP_STALE_SECS) AND matches a static-file
# server signature (binary basename or cmdline substring) AND isn't
# protected. No side effects -- never kills anything, so it's safe to
# unit-test against a mock table.
http_reap_select_victims() {
  local pid etimes cmd base
  while read -r pid _ etimes cmd; do
    [ -z "$pid" ] && continue
    case "$pid" in *[!0-9]*) continue ;; esac
    [ -n "$etimes" ] || continue
    case "$etimes" in *[!0-9]*) continue ;; esac
    [ "$etimes" -ge "$HTTP_REAP_STALE_SECS" ] || continue

    # `--` guards against a login shell's leading-dash argv[0] (ps shows it
    # as `-bash`), which basename would otherwise parse as an option and
    # error on.
    base=$(basename -- "${cmd%% *}")
    _http_reap_is_protected "$base" && continue

    if _http_reap_is_server_binary "$base" || _http_reap_cmd_matches "$cmd"; then
      echo "$pid"
    fi
  done
}

# _http_reap_kill_tree <pid> -- SIGKILL pid and every descendant. A
# static-file server can fork worker/reloader children, so this walks
# children by PPID (via ps) rather than assuming a process-group
# invariant.
_http_reap_kill_tree() {
  local pid="$1" child
  for child in $(ps -eo pid=,ppid= 2>/dev/null | awk -v p="$pid" '$2==p{print $1}'); do
    _http_reap_kill_tree "$child"
  done
  kill -9 "$pid" 2>/dev/null || true
}

# http_reap_sweep -- effectful entry point, called at the top of every
# maintenance tick. Snapshots the process table, selects victims via the
# pure predicate above, kills each victim's whole tree, and logs one
# line per victim (pid, etime, truncated cmdline). Silent no-op when
# nothing is stale -- the normal case.
http_reap_sweep() {
  local table victims pid row etimes cmd
  table=$(ps -eo pid=,ppid=,etimes=,args= 2>/dev/null) || return 0
  [ -z "$table" ] && return 0

  victims=$(http_reap_select_victims <<<"$table")
  [ -z "$victims" ] && return 0

  while read -r pid; do
    [ -z "$pid" ] && continue
    row=$(grep -E "^[[:space:]]*${pid}[[:space:]]" <<<"$table" | head -n1)
    read -r _ _ etimes cmd <<<"$row"
    log "http-reap: killing pid=$pid etime=${etimes}s cmd=${cmd:0:120}"
    _http_reap_kill_tree "$pid"
  done <<<"$victims"
}
