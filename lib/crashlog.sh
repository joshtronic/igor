#!/usr/bin/env bash
# lib/crashlog.sh -- post-mortem capture for ticks that die mid-model-call.
#
# claude_run_with_cost (lib/claude.sh) drops a `.agent/claude-in-flight` marker
# for the duration of every CLI call and clears it on a clean return. If the tick
# exits abnormally while that marker is still present, the model invocation never
# returned -- the #279 signature: status=1, no "claude exited" line, and the
# worktree about to be removed (issue work) or overwritten next tick (PR rework).
# crashlog_preserve copies the raw stream (which carries claude's merged stderr)
# somewhere durable so the cause is inspectable instead of lost.
#
# Best-effort throughout: capturing a post-mortem must NEVER itself break
# cleanup, so every step is guarded. Needs a `log` function from the caller
# (tick.sh) -- used only if present.

# How many crash dirs to retain (a post-mortem must not be able to fill disk).
CRASHLOG_KEEP=20

# crashlog_preserve <rc> <state_dir> <worktree...>
# For each worktree still carrying an in-flight marker, copy its .agent stream +
# display log + the marker (call-site) into <state_dir>/crash-logs/<stamp>/.
crashlog_preserve() {
  local rc="$1" state_dir="$2"
  shift 2
  local wt scratch dest stamp base
  stamp=$(date +%Y%m%dT%H%M%S 2>/dev/null) || return 0
  for wt in "$@"; do
    [ -n "$wt" ] && [ -f "$wt/.agent/claude-in-flight" ] || continue
    scratch="$wt/.agent"
    base=$(basename "$wt" 2>/dev/null || echo worktree)
    dest="$state_dir/crash-logs/${stamp}-rc${rc}-${base}"
    mkdir -p "$dest" 2>/dev/null || continue
    cp "$scratch/claude-in-flight"    "$dest/call-site"           2>/dev/null || true
    cp "$scratch/claude-stream.jsonl" "$dest/claude-stream.jsonl" 2>/dev/null || true
    cp "$scratch/claude-output.log"   "$dest/claude-output.log"   2>/dev/null || true
    if command -v log >/dev/null 2>&1; then
      log "crash: claude call did not return (rc=$rc); stream preserved to $dest for post-mortem"
    fi
  done
  crashlog_prune "$state_dir"
}

# crashlog_prune <state_dir>
# Keep only the CRASHLOG_KEEP newest crash dirs; remove the rest.
crashlog_prune() {
  local dir="$1/crash-logs" old
  [ -d "$dir" ] || return 0
  ls -1dt "$dir"/*/ 2>/dev/null | tail -n +"$((CRASHLOG_KEEP + 1))" | while IFS= read -r old; do
    [ -n "$old" ] && rm -rf "$old" 2>/dev/null || true
  done
  return 0
}
