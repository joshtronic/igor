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
    if [ -z "$wt" ] || [ ! -f "$wt/.agent/claude-in-flight" ]; then continue; fi
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

# crashlog_preserve_scratch <rc> <state_dir> <call_site> <scratch_dir>
# Preserve a KNOWN .agent scratch's stream + display log on a NONZERO claude
# exit (igor#326). crashlog_preserve (above) only fires on a tick DEATH -- it
# scans worktrees for a lingering in-flight marker. But when claude exits
# nonzero, claude_run_with_cost returns CLEANLY (marker cleared), so that path
# never runs and the worktree (with the stream) is torn down by the caller --
# losing any post-mortem for WHY claude exited nonzero -- a blind spot that has
# swallowed real crash causes. This is called by claude_run_with_cost itself,
# with the scratch dir it already has. Best-effort throughout; must never break
# the caller.
crashlog_preserve_scratch() {
  local rc="$1" state_dir="$2" call_site="$3" scratch="$4" dest stamp safe
  [ -n "$scratch" ] && [ -d "$scratch" ] || return 0
  [ -n "$state_dir" ] || return 0
  stamp=$(date +%Y%m%dT%H%M%S 2>/dev/null) || return 0
  safe=$(printf '%s' "${call_site:-call}" | tr -c 'A-Za-z0-9._-' '_')
  dest="$state_dir/crash-logs/${stamp}-rc${rc}-${safe}"
  mkdir -p "$dest" 2>/dev/null || return 0
  printf '%s\n' "${call_site:-}"    > "$dest/call-site"           2>/dev/null || true
  cp "$scratch/claude-stream.jsonl" "$dest/claude-stream.jsonl"   2>/dev/null || true
  cp "$scratch/claude-output.log"   "$dest/claude-output.log"     2>/dev/null || true
  if command -v log >/dev/null 2>&1; then
    log "crash: claude exited rc=$rc (${call_site}); stream preserved to $dest for post-mortem"
  fi
  crashlog_prune "$state_dir"
}

# crashlog_prune <state_dir>
# Keep only the CRASHLOG_KEEP newest crash dirs; remove the rest.
crashlog_prune() {
  local dir="$1/crash-logs" old
  [ -d "$dir" ] || return 0
  find "$dir" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | cut -d' ' -f2- | tail -n +"$((CRASHLOG_KEEP + 1))" | while IFS= read -r old; do
    if [ -n "$old" ]; then rm -rf "$old" 2>/dev/null; fi
  done
  return 0
}
