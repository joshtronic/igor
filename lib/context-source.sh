#!/usr/bin/env bash
# context-source.sh -- sources igor's prompt surfaces from the Distillery
# (joshtronic/distillery) at origin/master, LIVE: no pins, no submodules, a
# change merged to distillery master is live on igor's next tick, exactly
# like igor's own self-pull. The in-repo copies under bin/lib/ and
# AGENTS.md are the FALLBACK, not the source -- see CLAUDE.md and igor#485.
#
# Read via `git show origin/master:...` ONLY -- never the clone's working
# tree, same read-the-ref-never-the-checkout pattern rc_local_init uses
# (lib/repo-checks.sh). The per-tick validation sweep is what keeps the
# distillery clone fetched; this module only reads it.
#
# Fail-open by design: a broken distillery skill (missing, malformed, or
# suspiciously thin) must never mean no prompt at all -- it degrades to
# the in-repo fallback and logs once, so the fleet keeps working on
# yesterday's rules instead of stalling at 3am on nobody watching.

# Fallback logger so this module is sourceable standalone (tests).
if ! declare -F log >/dev/null; then log() { printf '[agent] %s\n' "$*" >&2; }; fi

CONTEXT_MIN_LINES=10   # context_surface's "non-trivial" bar

# CONTEXT_DISTILLERY_PATH is overridable (tests point it at a fixture
# clone); the real per-tick sweep keeps the default fetched.
_context_distillery_path() {
  printf '%s' "${CONTEXT_DISTILLERY_PATH:-${AGENT_STATE_DIR:-$HOME/.local/state/agent}/repos/distillery}"
}

# context_skill_body <skill-name>
#
# Reads skills/<skill-name>/SKILL.md from the distillery clone at
# origin/master and echoes the body with the YAML frontmatter (the opening
# `---` fence through the closing one, plus one blank line) stripped.
#
# Nonzero when: clone missing, skill missing, no frontmatter, or empty body.
# The failure reason goes to STDERR, not a global -- context_surface calls
# this via `$( )`, which forks a subshell, so a global set in here would
# never make it back to the caller.
context_skill_body() {
  local skill="$1" path raw
  path="$(_context_distillery_path)"

  if [ -z "$skill" ]; then
    printf 'no skill name given\n' >&2
    return 1
  fi
  if [ ! -d "$path/.git" ]; then
    printf 'no readable distillery clone at %s\n' "$path" >&2
    return 1
  fi
  # `|| true`: a caller running under `set -e` (bin/tick.sh) must not abort
  # here -- `git show` failing is the ordinary "skill absent" case this
  # module exists to fall open on, not an error to propagate as a crash.
  raw=$(git -C "$path" show "origin/master:skills/${skill}/SKILL.md" 2>/dev/null) || true
  if [ -z "$raw" ]; then
    printf 'skills/%s/SKILL.md not found on origin/master\n' "$skill" >&2
    return 1
  fi

  local -a lines
  mapfile -t lines <<<"$raw"

  if [ "${lines[0]:-}" != "---" ]; then
    printf 'no YAML frontmatter (no opening --- fence)\n' >&2
    return 1
  fi

  local n=${#lines[@]} i close=-1
  for ((i = 1; i < n; i++)); do
    if [ "${lines[i]}" = "---" ]; then
      close=$i
      break
    fi
  done
  if [ "$close" -lt 0 ]; then
    printf 'frontmatter never closes (no closing --- fence)\n' >&2
    return 1
  fi

  local start=$((close + 1))
  if [ "$start" -lt "$n" ] && [ -z "${lines[$start]}" ]; then
    start=$((start + 1))   # one blank line after the fence, if present
  fi

  local body
  body=$(printf '%s\n' "${lines[@]:$start}")
  if [ -z "$(printf '%s' "$body" | tr -d '[:space:]')" ]; then
    printf 'body is empty\n' >&2
    return 1
  fi
  printf '%s\n' "$body"
}

# context_surface <skill-name> <fallback-path>
#
# Echoes context_skill_body's output when it succeeds AND is non-trivial
# (>= CONTEXT_MIN_LINES lines); otherwise echoes the fallback file's
# content and logs ONE warn line naming the skill and the reason.
context_surface() {
  local skill="$1" fallback="$2" body reason line_count errfile rc

  # Guarded by `if`, not a bare assignment: a caller running under `set -e`
  # (bin/tick.sh) must not abort on context_skill_body's ordinary failure --
  # that's the exact case this function exists to fall open on.
  errfile=$(mktemp)
  if body=$(context_skill_body "$skill" 2>"$errfile"); then
    rc=0
  else
    rc=$?
  fi
  reason=$(cat "$errfile" 2>/dev/null)
  rm -f "$errfile"

  if [ "$rc" -eq 0 ] && [ -n "$body" ]; then
    line_count=$(printf '%s\n' "$body" | wc -l)
    if [ "$line_count" -ge "$CONTEXT_MIN_LINES" ]; then
      printf '%s\n' "$body"
      return 0
    fi
    reason="body too short (${line_count} line(s), need >= ${CONTEXT_MIN_LINES})"
  fi
  [ -n "$reason" ] || reason="context_skill_body failed"

  log "context-source: ${skill} fell back -- ${reason}"
  # `|| true`: same set -e concern as above -- a missing/unreadable fallback
  # must degrade to empty output, never propagate a nonzero exit.
  cat "$fallback" 2>/dev/null || true
}
