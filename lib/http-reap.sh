#!/usr/bin/env bash
# http-reap.sh -- kill stale static-file-server process trees at the top
# of every tick. In-tick static-build verification (checking
# that a route resolves under `_site`/`dist`/etc.) has been done by
# spawning a throwaway `python3 -m http.server`-style listener and never
# reaping it (igor#418): four such orphans were found live on the host,
# reparented to init, bound to 0.0.0.0, the oldest over 8 hours old. One
# of them squatted on a port and answered a LATER tick's verification
# request with a stale build from a different repo. A legitimate
# static-file check is a curl or two and finishes in seconds, so age is
# where the hunt starts -- but age alone is not the verdict: see
# http_reap_select_victims for the parentage and cgroup guards that keep
# a server somebody is actually running out of the victim set.
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
# "http-server") ever reaping the thing running the reaper. Protecting
# `node` wholesale is why node-hosted servers that don't expose their own
# argv[0] (`npx serve`) are directive-only, never reaped: the reaper is a
# backstop for the common leaks, and mistaking the harness's own node for
# a leak is worse than missing one.
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

# Interpreters that are a static-file server only when their ARGS say so
# (`python3 -m http.server`, `php -S`). The cmdline substring match below
# is gated on one of these basenames so an unrelated long-lived process
# that merely MENTIONS a signature in its args -- `tail -F
# http-server.log`, `grep -r http.server src/`, an editor open on this
# file -- can never become a SIGKILL candidate.
_http_reap_is_interpreter() {
  case "$1" in
    python* | php*) return 0 ;;
    *) return 1 ;;
  esac
}

# Cmdline substrings that mark an interpreter process as a throwaway
# static-file server even when the binary basename doesn't match one of
# the above (e.g. `python3 -m http.server`, where the basename is just
# `python3`).
_http_reap_cmd_matches() {
  case "$1" in
    *http.server* | *SimpleHTTPServer* | *http-server* | *"php -S"*) return 0 ;;
    *) return 1 ;;
  esac
}

# _http_reap_cgroup_path <pid|self> -- the process's cgroup-v2 path (the
# `0::` line of /proc/<pid>/cgroup, e.g.
# "/user.slice/user-1001.slice/user@1001.service/app.slice/agent.service"),
# or empty when it can't be read: the process exited mid-sweep, or the
# host is cgroup-v1-only and has no unified line. Empty means "unknown",
# never "protected" -- see the walk below.
_http_reap_cgroup_path() {
  local content line
  content=$(cat "/proc/$1/cgroup" 2>/dev/null) || return 0
  while IFS= read -r line; do
    case "$line" in
      0::*)
        printf '%s\n' "${line#0::}"
        return 0
        ;;
    esac
  done <<<"$content"
}

# _http_reap_supervising_unit <cgroup-path> -- the systemd SERVICE unit
# that supervises a process living in <cgroup-path>, or empty when
# nothing does. Walks the path innermost-outward so a unit's own
# subdirectory (systemd-udevd.service/udev) still resolves to the unit,
# and STOPS at the first `.scope`: a scope is a transient unit tracking a
# login session or a one-off spawn, so the `user@N.service` above it
# supervises the SESSION, not this process -- a leak in there is still a
# leak.
_http_reap_supervising_unit() {
  local path="$1" leaf
  while [ -n "$path" ] && [ "$path" != "/" ]; do
    leaf=${path##*/}
    case "$leaf" in
      *.scope) return 0 ;;
      *.service)
        printf '%s\n' "$leaf"
        return 0
        ;;
    esac
    path=${path%/*}
  done
}

# http_reap_select_victims -- selection predicate, no side effects (it
# reads /proc for each candidate's cgroup but never kills anything, so
# it's safe to unit-test against a mock table). Reads a ps-style table on
# stdin, one process per line: "pid ppid etimes cmd..." (whitespace
# separated; cmd is the remainder of the line, so internal spaces in the
# command survive). Echoes one pid per line for every process that is
# parented to init (ppid 1) AND stale (etimes >= HTTP_REAP_STALE_SECS)
# AND matches a static-file server signature (a known server binary
# basename, or an interpreter basename whose args carry a server
# signature) AND isn't protected AND isn't supervised by a systemd
# service other than the harness's own.
#
# The ppid check is what separates a LEAK from a server somebody is
# using. Every orphan in igor#418 was reparented to init when its tick
# exited, so ppid 1 is the leak's signature; age and cmdline alone would
# also select `python3 -m http.server` that the operator started from a
# shell five minutes ago and still has open, and SIGKILL it out from
# under them with nothing but a journal line to show for it. It's a
# necessary condition, not a sufficient one, and it's specifically about
# the DIRECT parent: a leak double-forked via setsid/nohup is ppid 1 with
# its tick still running, and a leak whose parent shell outlives it is
# never reaped at all. Both are deliberate -- this is a backstop, and
# under-reaping is the cheap failure.
#
# The cgroup check covers ppid 1's other meaning: on a systemd host every
# supervised service is ppid 1 too, and a service is stale-by-definition
# (uptime is the point). Reaping one wouldn't even stick -- systemd
# restarts it -- so the sweep would flap somebody's static server once a
# tick with only a journal line to show for it. A candidate under a
# foreign `.service` cgroup is therefore left alone; one under the
# harness's own unit, under a session/tmux scope, or with no readable
# cgroup at all is fair game. `HTTP_REAP_OWN_UNIT` pins "the harness's
# own unit" instead of reading it from /proc/self -- the seam the unit
# tests use, and an escape hatch if the sweep ever runs outside its
# unit.
http_reap_select_victims() {
  local pid ppid etimes cmd base own unit
  own=${HTTP_REAP_OWN_UNIT:-}
  [ -n "$own" ] || own=$(_http_reap_supervising_unit "$(_http_reap_cgroup_path self)")
  while read -r pid ppid etimes cmd; do
    [ -z "$pid" ] && continue
    case "$pid" in *[!0-9]*) continue ;; esac
    [ "$ppid" = "1" ] || continue
    [ -n "$etimes" ] || continue
    case "$etimes" in *[!0-9]*) continue ;; esac
    [ "$etimes" -ge "$HTTP_REAP_STALE_SECS" ] || continue

    # `--` guards against a login shell's leading-dash argv[0] (ps shows it
    # as `-bash`), which basename would otherwise parse as an option and
    # error on.
    base=$(basename -- "${cmd%% *}")
    _http_reap_is_protected "$base" && continue

    if _http_reap_is_server_binary "$base" \
      || { _http_reap_is_interpreter "$base" && _http_reap_cmd_matches "$cmd"; }; then
      # Cheapest-last: the /proc read only happens for a row that already
      # matches every other criterion.
      unit=$(_http_reap_supervising_unit "$(_http_reap_cgroup_path "$pid")")
      [ -n "$unit" ] && [ "$unit" != "$own" ] && continue
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
# tick. Snapshots the process table, selects victims via the
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
