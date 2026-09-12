#!/usr/bin/env bash
# lib/claude-version.sh -- installed-vs-latest Claude Code CLI check.
#
# igor#612, section 4: autoUpdates is deliberately OFF (see CLAUDE.md) so
# updates are a manual operator step -- and that step had quietly stopped
# (installed pinned since Aug 12, 40 releases behind by 2026-09-12). This
# is a report line, not a gate: it never auto-updates and nothing here
# blocks a tick. Fully scripted (claude --version + `npm view ... version`),
# so it costs no model call and runs even during a Claude health cooldown.
#
# "Fail loudly-but-harmlessly" (the ticket's words): a registry lookup that
# fails must read as "could not check", never as silence -- silence here is
# exactly the class of bug this whole ticket exists to fix.

if ! declare -F log >/dev/null; then
  log() { printf '[agent] %s\n' "$*" >&2; }
fi

# _claude_version_installed -- bare X.Y.Z from `claude --version`. Greps
# for a version-shaped token rather than assuming a fixed output layout
# (e.g. "2.1.229 (Claude Code)") -- same "don't trust incidental formatting"
# lesson as the cost-ledger parse fix in this same ticket.
_claude_version_installed() {
  command -v claude >/dev/null 2>&1 || return 1
  claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# _claude_version_latest -- bare X.Y.Z from the npm registry. Non-zero (and
# empty stdout) on any failure -- offline host, registry outage, npm absent.
#
# Bounded by `timeout`: this is a network call on the ship-report tick's path,
# and a registry connection that hangs rather than refuses would stall the
# tick. A timeout kills the lookup, stdout is empty, and checked_ok goes false
# -- "could not check", which is the designed degradation.
_claude_version_latest() {
  command -v npm >/dev/null 2>&1 || return 1
  timeout "${CLAUDE_VERSION_LOOKUP_TIMEOUT_SECS:-20}" \
    npm view @anthropic-ai/claude-code version 2>/dev/null \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# claude_version_check -- {installed, latest, checked_ok, behind, since_days}
#   installed/latest : version string, or null if unavailable.
#   checked_ok        : false means "could not check" -- render that, not a
#                        stale/zero-looking value.
#   behind            : true only when both versions are known and differ.
#   since_days        : days since the `claude` binary on PATH last changed
#                        (its symlink mtime) -- null if it can't be stat'd.
#                        "how long the installed version has been current."
claude_version_check() {
  local installed latest bin_path since_epoch since_days
  installed=$(_claude_version_installed) || installed=""
  latest=$(_claude_version_latest) || latest=""

  since_days="null"
  bin_path=$(command -v claude 2>/dev/null) || bin_path=""
  if [ -n "$bin_path" ]; then
    since_epoch=$(stat -c %Y "$bin_path" 2>/dev/null || stat -f %m "$bin_path" 2>/dev/null || echo "")
    if [ -n "$since_epoch" ]; then
      since_days=$(( ($(date +%s) - since_epoch) / 86400 ))
    fi
  fi

  jq -cn \
    --arg installed "$installed" \
    --arg latest "$latest" \
    --argjson since_days "$since_days" \
    '{
       installed: (if $installed == "" then null else $installed end),
       latest: (if $latest == "" then null else $latest end),
       checked_ok: ($installed != "" and $latest != ""),
       behind: ($installed != "" and $latest != "" and $installed != $latest),
       since_days: $since_days
     }'
}
