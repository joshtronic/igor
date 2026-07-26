#!/usr/bin/env bash
# tick.sh -- discover and work one Agent-labeled Forgejo issue across
# every repo the bot user has push access to. One invocation = one tick.
#
# Usage: tick.sh
#
# Behavior:
#   1. Acquire global flock -- only one tick at a time.
#   2. Resolve bot identity from Forgejo (whoami).
#   3. Recovery -- any open issue still assigned to the bot from a
#      previous interrupted tick gets a comment and is unassigned so
#      the next tick re-claims it.
#   4. Discovery -- list every repo the bot has push access to, find
#      the globally oldest claimable issue across them.
#   5. Claim, clone-if-needed, preflight (CLAUDE.md present), worktree,
#      invoke Claude, classify outcome.
#
# Exits 0 on success or no-work-found. Non-zero on config/infra errors.

set -euo pipefail

# -- Paths ------------------------------------------------------

AGENT_HOME="$(cd "$(dirname "$0")/.." && pwd)"
AGENT_STATE_DIR="$HOME/.local/state/agent"
AGENT_REPO_ROOT="$AGENT_STATE_DIR/repos"

# -- Self-update -----------------------------------------------
#
# Pull the harness's own latest code before doing anything else.
# If it changed, exec the new tick.sh so we don't run a mixed-
# version tick (old tick.sh body + new lib/* sourced below).
# AGENT_RESPAWNED guards against infinite re-exec loops if the
# pull fails to advance HEAD for some reason.
#
# Skip via AGENT_SKIP_SELF_PULL=1 for local dev / interactive
# debugging where the operator wants to run a specific worktree
# state without surprise updates.

if [ -z "${AGENT_RESPAWNED:-}" ] && [ -z "${AGENT_SKIP_SELF_PULL:-}" ] \
    && [ -d "$AGENT_HOME/.git" ]; then
  PREV_HEAD=$(git -C "$AGENT_HOME" rev-parse HEAD 2>/dev/null || echo "")
  git -C "$AGENT_HOME" pull --rebase --quiet --autostash origin master 2>/dev/null \
    || echo "[agent] warning: harness self-pull failed; using on-disk code" >&2
  NEW_HEAD=$(git -C "$AGENT_HOME" rev-parse HEAD 2>/dev/null || echo "")
  if [ -n "$PREV_HEAD" ] && [ -n "$NEW_HEAD" ] && [ "$PREV_HEAD" != "$NEW_HEAD" ]; then
    echo "[agent] self-update: ${PREV_HEAD:0:7} -> ${NEW_HEAD:0:7}, re-execing" >&2
    export AGENT_RESPAWNED=1
    exec "$0" "$@"
  fi
fi

# -- Secrets ----------------------------------------------------

if [ ! -f "$AGENT_HOME/.env" ]; then
  echo "agent: missing $AGENT_HOME/.env -- copy .env.example and fill it in" >&2
  exit 2
fi
set -a
# shellcheck source=/dev/null
. "$AGENT_HOME/.env"
set +a

# Every var in .env.example is required -- no defaults, fail fast if
# anything is missing. The env_file_hint surfaces in the error so the
# operator knows exactly where to fix it.
env_file_hint="$AGENT_HOME/.env"
: "${AGENT_MODEL:?must be set in $env_file_hint}"
: "${AGENT_MODEL_REVIEW:?must be set in $env_file_hint}"
: "${AGENT_MODEL_SECURITY:?must be set in $env_file_hint}"
: "${FORGEJO_URL:?must be set in $env_file_hint}"
: "${FORGEJO_TOKEN:?must be set in $env_file_hint}"
: "${FORGEJO_HOST:?must be set in $env_file_hint}"
: "${FORGEJO_REVIEWER:?must be set in $env_file_hint}"
: "${TICK_TIMEOUT:?must be set in $env_file_hint}"
: "${AGENT_RECALL_DAYS:?must be set in $env_file_hint}"
unset env_file_hint

# -- Library ----------------------------------------------------

# shellcheck source=lib/forgejo.sh
. "$AGENT_HOME/lib/forgejo.sh"
# shellcheck source=lib/checkpoint.sh
. "$AGENT_HOME/lib/checkpoint.sh"
# shellcheck source=lib/repo-checks.sh
. "$AGENT_HOME/lib/repo-checks.sh"
# shellcheck source=lib/maintenance-checks.sh
. "$AGENT_HOME/lib/maintenance-checks.sh"
# shellcheck source=lib/browser-reap.sh
. "$AGENT_HOME/lib/browser-reap.sh"
# shellcheck source=lib/cost.sh
. "$AGENT_HOME/lib/cost.sh"
# shellcheck source=lib/claude.sh
. "$AGENT_HOME/lib/claude.sh"
# shellcheck source=lib/crashlog.sh
. "$AGENT_HOME/lib/crashlog.sh"
# shellcheck source=lib/healthcheck.sh
. "$AGENT_HOME/lib/healthcheck.sh"
# shellcheck source=../lib/security-gate.sh
. "$AGENT_HOME/lib/security-gate.sh"
# shellcheck source=lib/google-auth.sh
. "$AGENT_HOME/lib/google-auth.sh"
# shellcheck source=lib/gsc.sh
. "$AGENT_HOME/lib/gsc.sh"
# shellcheck source=lib/ga.sh
. "$AGENT_HOME/lib/ga.sh"
# shellcheck source=lib/email.sh
. "$AGENT_HOME/lib/email.sh"
# shellcheck source=lib/seo-analysis.sh
. "$AGENT_HOME/lib/seo-analysis.sh"
# shellcheck source=lib/espn.sh
. "$AGENT_HOME/lib/espn.sh"
# shellcheck source=lib/sports-digest.sh
. "$AGENT_HOME/lib/sports-digest.sh"
. "$AGENT_HOME/lib/ceo.sh"
# shellcheck source=lib/automerge.sh
. "$AGENT_HOME/lib/automerge.sh"
. "$AGENT_HOME/lib/ship-report.sh"
# shellcheck source=lib/feedback.sh
. "$AGENT_HOME/lib/feedback.sh"
# shellcheck source=lib/deferred.sh
. "$AGENT_HOME/lib/deferred.sh"
# shellcheck source=lib/logwatch.sh
. "$AGENT_HOME/lib/logwatch.sh"

# Children invocations (agent-* helper scripts) share our tick id
# so cost-ledger entries from child processes group with the
# parent tick's entries.
export TICK_PID=$$

# -- Resolve bot identity --------------------------------------

# This gates the ENTIRE tick, so a transient /api/v1/user blip must not
# hard-abort the unit: forgejo_resolve_bot_user retries with backoff, so a
# one-off hiccup rides through on a later attempt instead of crashing systemd
# with exit 3 (igor#383). Only a PERSISTENT failure (retries exhausted) falls
# through to exit 3 -- a sustained outage or revoked token SHOULD surface as a
# failed unit. The assignment stays guarded because forgejo_whoami's curl | jq
# pipeline can surface curl's raw exit code under pipefail, which would kill the
# tick BEFORE the check below runs, bypassing this diagnostic (igor#346).
BOT_USER=$(forgejo_resolve_bot_user) || BOT_USER=""
[ -n "$BOT_USER" ] || {
  echo "agent: failed to resolve bot user from $FORGEJO_URL/api/v1/user" >&2
  exit 3
}

# Export bot-identity vars early so helper scripts (agent-ask.sh,
# agent-block.sh, agent-report.sh) called by Claude from any tick
# shape can find them.
export BOT_USER
export FORGEJO_REVIEWER
export AGENT_HOME

# -- Cleanup on exit (installed EARLY) -------------------------
# Set here, before ANY worktree-creating stage, so a crash in the PR-review/rework
# or maintenance paths -- not just issue-work -- still fires crashlog capture and
# worktree cleanup. The trap used to be installed just before the issue-work
# worktree (far below), so the earlier model-call stages ran uninstrumented: a tick
# that died mid-PR-rework (igor#291) left NO crash trap to preserve its stream.
# Vars are pre-initialized + AGENT_STATE_DIR is guarded so the handler is a safe
# no-op on early/clean exits.
WORKTREE=""
PR_WORKTREE=""
cleanup() {
  local rc=$?
  # Task heartbeat (check B): pair the start ping (fired once the tick
  # clears the health/deploy gates -- see HC_TASK_STARTED) with a
  # success/fail ping here so every exit path reports honestly, not just
  # the happy one. Guarded so a tick that never reached the cascade (e.g.
  # a health cooldown, or an error before it) doesn't falsely report.
  if [ -n "${HC_TASK_STARTED:-}" ]; then
    if [ "$rc" -eq 0 ]; then
      hc_ping task success
    else
      hc_ping task fail
    fi
  fi
  # Post-mortem: if a model call was in-flight when the tick died (the #279
  # signature -- abnormal exit, no "claude exited" line), preserve its raw stream
  # before the worktree is removed below or reused next tick. Best-effort.
  if [ "$rc" -ne 0 ]; then
    crashlog_preserve "$rc" "${AGENT_STATE_DIR:-}" "${WORKTREE:-}" "${PR_WORKTREE:-}" 2>/dev/null || true
  fi
  if [ -n "$WORKTREE" ] && [ -d "$WORKTREE" ]; then
    log "removing worktree $WORKTREE"
    (cd "$REPO_PATH" && git worktree remove "$WORKTREE" --force) 2>/dev/null || true
  fi
  if [ -n "${ISSUE_NUMBER:-}" ] && [ -d "$REPO_PATH/.git" ]; then
    cleanup_agent_branches "$ISSUE_NUMBER" "$REPO_PATH"
  fi
  exit "$rc"
}
trap cleanup EXIT

# (Phase 6 of the refactor retired AGENT_BRAIN_PATH and the brain
# repo bootstrap. The agent's memory now lives in
# ~/.local/state/agent/brain.sqlite; no markdown repo to clone.)

# Website is OPT-IN via WEBSITE_REPO. If set, name the Forgejo
# repo path (e.g. "joshtronic/igor.bot") and the harness will
# bootstrap + run the reading pipeline + run the site-work block
# against it. If unset, ALL website work is disabled: no clone,
# no reading-pipeline post drafting, no site-work block. The
# agent still works issues + maintenance + PR-review on any
# other repo it has access to.
export WEBSITE_REPO="${WEBSITE_REPO:-}"
if [ -n "$WEBSITE_REPO" ]; then
  export AGENT_WEBSITE_PATH="$AGENT_REPO_ROOT/${WEBSITE_REPO}"
fi

# Email delivery (SMTP2GO) -- shared by every opt-in report subsystem
# (SEO, sports, CEO). All default to empty so referencing them under `set -u`
# is safe when nothing is configured; each report tick no-ops cleanly if
# its required creds (incl. these) are unset.
export SMTP2GO_API_KEY="${SMTP2GO_API_KEY:-}"
export SMTP2GO_SENDER="${SMTP2GO_SENDER:-}"

# SEO analysis pass -- opt-in via a Google service account + SMTP2GO creds.
# do_seo_tick no-ops cleanly if any required one is unset. Floor/top-K
# carry tuning defaults. GOOGLE_SERVICE_ACCOUNT is the service-account key
# (base64 | file path | inline JSON); see lib/google-auth.sh.
export GOOGLE_SERVICE_ACCOUNT="${GOOGLE_SERVICE_ACCOUNT:-}"
export PRIMARY_RECIPIENTS="${PRIMARY_RECIPIENTS:-}"
export SEO_RECIPIENTS="${SEO_RECIPIENTS:-}"
# Agentic SEO sites are declared per-repo in agent.json (`.seo.domain` +
# `.seo.agentic`); see seo_agentic_repo_for in lib/seo-analysis.sh.
export SEO_IMPRESSION_FLOOR="${SEO_IMPRESSION_FLOOR:-50}"
export SEO_TOP_K="${SEO_TOP_K:-10}"
export SEO_DEBUG_DOMAIN="${SEO_DEBUG_DOMAIN:-}"

# Claude health alerts -- where the once-daily "claude auth/usage is
# broken" email goes (see do_health_tick). PRIMARY_RECIPIENTS always gets
# it; HEALTH_RECIPIENTS adds extra subscribers. With no recipients at all
# (or no SMTP2GO creds) the alert is log-only.
export HEALTH_RECIPIENTS="${HEALTH_RECIPIENTS:-}"

# Auto-merge deploy alerts -- where the "auto-merged #N but the post-merge
# deploy/smoke failed" email goes (see do_deploy_barrier). Additive like the
# rest: PRIMARY_RECIPIENTS always gets it; ALERT_RECIPIENTS adds others.
export ALERT_RECIPIENTS="${ALERT_RECIPIENTS:-}"

# Sports digest -- opt-in daily (7 days; sports don't take weekends off)
# ELI5 sports-tutor email: scripted ESPN fetch, ONE distill call on
# AGENT_MODEL, sent via SMTP2GO. do_sports_tick no-ops cleanly if any
# required var is unset. Leagues are ESPN {sport}/{league} paths (e.g.
# football/nfl, hockey/nhl, soccer/fifa.world, racing/nascar-premier,
# football/college-football); one flat list -- the directive weights
# coverage by significance, so a quiet league costs nothing and a
# college championship outranks a routine pro slate on its own merits.
# Unlike the scripted SEO pass, this one USES the model, so it waits out
# a Claude health cooldown like every other model surface.
export SPORTS_RECIPIENTS="${SPORTS_RECIPIENTS:-}"
export SPORTS_LEAGUES="${SPORTS_LEAGUES:-}"

# Healthcheck pings (dead-man's switch) -- opt-in, inert, non-model (plain
# curl via lib/healthcheck.sh). Both default to empty so referencing them
# under `set -u` is safe; hc_ping no-ops silently when its URL is unset.
# HEARTBEAT proves the tick is still firing at all; TASK's start/success/
# fail pair (wired below + in cleanup()) catches a crash/hang mid-cascade.
# See #297 for the operator-side healthchecks.io setup that activates them.
export HEALTHCHECK_HEARTBEAT_URL="${HEALTHCHECK_HEARTBEAT_URL:-}"
export HEALTHCHECK_TASK_URL="${HEALTHCHECK_TASK_URL:-}"

# Put the harness's bin dir on PATH for every Claude invocation in
# this script. Without this, Claude can't call agent-enqueue.sh /
# agent-ask.sh / agent-block.sh / agent-report.sh by name -- it
# either uses an absolute path (and trips the permission hook's
# static analysis around command substitution) or shells out via a
# temp script as a workaround. Allowlist already permits these by
# name in agent-settings.json; PATH just needs to find them.
export PATH="$AGENT_HOME/bin:$PATH"

# -- Global lock (one tick at a time) --------------------------

mkdir -p "$AGENT_STATE_DIR"
LOCK="$AGENT_STATE_DIR/lock"
exec 200>"$LOCK"
if ! flock -n 200; then
  echo "agent: another tick is running -- exiting" >&2
  exit 0
fi

log() { printf '[agent] %s\n' "$*"; }

# Dead-man's-switch heartbeat (check A) -- unconditional, every tick that
# gets this far (i.e. actually holds the lock). No-op when
# HEALTHCHECK_HEARTBEAT_URL is unset.
hc_ping heartbeat

# Title -> branch-safe slug. ASCII alphanumerics survive; everything
# else collapses to '-'. Capped at 50 chars, preferring to cut on a
# hyphen boundary. Empty for titles with no alphanumerics.
slugify() {
  local s
  s=$(printf '%s' "$1" \
    | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | LC_ALL=C sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
  if [ ${#s} -gt 50 ]; then
    s="${s:0:50}"
    s="${s%-*}"
    s="${s%-}"
  fi
  printf '%s' "$s"
}

# Delete local agent branches for issue N: bare `agent/N` plus any
# `agent/N-<slug>` left over from a previous run (the title may have
# been edited since, so glob rather than match exactly).
cleanup_agent_branches() {
  local n="$1" repo="$2" refs
  refs=$(cd "$repo" && git for-each-ref --format='%(refname:short)' \
    "refs/heads/agent/${n}" "refs/heads/agent/${n}-*" 2>/dev/null) || return 0
  [ -z "$refs" ] && return 0
  (cd "$repo" && echo "$refs" | xargs git branch -D) >/dev/null 2>&1 || true
}

# Local clone path: nests by owner under the harness state dir.
# Lives in state (not in ~/Code) because these are harness-managed
# working copies, distinct from any interactive clones the operator
# keeps in their own workspace.
repo_path_for() { echo "$AGENT_REPO_ROOT/$1"; }

# Build the SSH clone URL for a given <owner>/<name>. Handles
# FORGEJO_HOST in "host" form (default port 22) or "host:port"
# form (non-default port via ssh:// URL syntax). The shorthand
# git@host:path syntax can't express ports; ssh:// can.
ssh_clone_url() {
  local repo="$1"
  if [[ "$FORGEJO_HOST" == *:* ]]; then
    echo "ssh://git@${FORGEJO_HOST}/${repo}.git"
  else
    echo "git@${FORGEJO_HOST}:${repo}.git"
  fi
}

# Create the .agent/ scratch dir inside a worktree and drop a local
# gitignore so its contents (PR_BODY.md, AGENT_JOURNAL.md, claude-
# output.log, AGENT_MAINTENANCE_*) never get picked up by `git add .`
# or `git add -A`. Also untrack any .agent/* files that base happens
# to have tracked -- gitignore only blocks NEW additions, but
# modifications to already-tracked files still get staged. Untracking
# at worktree creation flips them so the gitignore actually applies.
init_igor_scratch() {
  local worktree="$1"
  mkdir -p "$worktree/.agent"
  printf '*\n' > "$worktree/.agent/.gitignore"
  (cd "$worktree" && git rm --cached -r --quiet --ignore-unmatch .agent/ 2>/dev/null) || true
}

# Build the full system prompt for issue-work Claude invocations.
#
# Two pieces, in order:
#   bin/lib/voice.md  -- shared voice anchor (2 paragraphs)
#   AGENTS.md         -- slim, issue-work-specific protocol/rules
#
# Per-repo CLAUDE.md is NOT concatenated here; Claude Code auto-
# loads it from the worktree root when invoked there. The legacy
# pattern of catting identity.md + memories/MEMORY.md + blog-ideas
# is retired in Phase 5 of the refactor: brain has been replaced
# by ~/.local/state/agent/brain.sqlite, and persona/voice now
# lives in voice.md.
#
# Used by issue work (tier-1) and PR-review pickup. Maintenance
# triage uses a task-specific inline prompt (no voice anchor --
# classification work); the reading pipeline and site-work block
# each compose their own prompts inside their executor scripts.
issue_system_prompt() {
  local voice="$AGENT_HOME/bin/lib/voice.md"
  if [ -f "$voice" ]; then
    cat "$voice" "$AGENT_HOME/AGENTS.md"
  else
    cat "$AGENT_HOME/AGENTS.md"
  fi
}


# Single-shot completion via the Anthropic Messages API. No tool
# use, no agentic loop -- just send a prompt, get text back. Used
# for in-harness "thinking" tasks where Claude Code's tool runtime
# is overkill (commit-subject generation, classification, etc.).
# Hits the API directly with curl so we don't pay the Claude Code
# overhead.
#
# Normalize Unicode dashes that Claude tends to emit. Forgejo
# highlights U+2013 (en-dash) as an "ambiguous code point" because
# it looks like a hyphen but isn't; the warning fires on every
# PR/file that has one, which becomes constant background noise
# given how often model output uses en-/em-dashes for emphasis.
# Replace both with the ASCII "--" we use in prose anyway. Safe
# for code, since en/em dashes are never load-bearing in code.
#
# Two flavors: arg form (text -> stdout) and in-place file form.
normalize_unicode_dashes() {
  printf '%s' "$*" | sed -e 's/–/--/g' -e 's/—/--/g'
}

normalize_unicode_dashes_in_file() {
  local path="$1"
  [ -f "$path" ] || return 0
  local tmp; tmp=$(mktemp)
  sed -e 's/–/--/g' -e 's/—/--/g' "$path" > "$tmp" && mv "$tmp" "$path"
}

# Sweep the well-known Claude-output files in a worktree's .agent/
# scratch dir. Idempotent and silent on missing files. Called once
# after each Claude invocation returns; catches PR_BODY.md / journal
# / maintenance findings before any downstream step reads them.
normalize_worktree_dashes() {
  local worktree="$1"
  [ -n "$worktree" ] || return 0
  local f
  for f in PR_BODY.md AGENT_JOURNAL.md \
           AGENT_MAINTENANCE_FINDINGS.md \
           AGENT_MAINTENANCE_SECURITY.md AGENT_MAINTENANCE_BUMPS.md; do
    normalize_unicode_dashes_in_file "$worktree/.agent/$f"
  done
}

# The Claude invocation primitives -- claude_run_with_cost (agentic
# CLI runner), claude_call (one-shot no-tools completion), the
# claude_health_* state helpers, and the PR-subject text helpers
# (looks_like_conventional_commit / normalize_subject /
# pr_body_first_item) -- live in lib/claude.sh, sourced above. Both
# runners bill the operator's Claude subscription (OAuth login), not
# an API key.

# Derive a commit subject for the harness commit. Three tiers,
# tried in order:
#   1. First "What this PR does" checklist item from PR_BODY.md,
#      normalized to ensure a conventional-commit prefix. Claude
#      writes the item with full context -- best signal.
#   2. Model-generated subject from the staged diff ($AGENT_MODEL
#      one-shot call). Used when PR_BODY is missing or
#      empty. Response must match conventional-commit shape or
#      it's rejected (catches "I'm ready to generate..." chat
#      replies the API sometimes returns on empty input).
#   3. Passed-in fallback string (last resort).
#
# IMPORTANT: caller should run `git add -A` BEFORE calling, so
# the staged diff (git diff --cached) sees new files. `git diff
# HEAD` alone would miss untracked files.
#
# The chosen subject becomes both the commit message AND the PR
# title via `git log -1 --pretty=%s` later.
derive_commit_subject() {
  local pr_body="$1" worktree="$2" fallback="${3:-chore: tick work}"

  # Tier 1: PR_BODY.md first item
  if [ -f "$pr_body" ]; then
    local subject
    subject=$(pr_body_first_item "$pr_body")
    if [ -n "$subject" ]; then
      normalize_subject "$subject"
      return 0
    fi
  fi

  # Tier 2: model-generated from the staged diff
  if [ -n "$worktree" ] && [ -d "$worktree" ]; then
    local diff_summary
    diff_summary=$( (
      cd "$worktree" && {
        git diff --cached --stat 2>/dev/null
        echo "---"
        git diff --cached 2>/dev/null | head -200
      }
    ) 2>/dev/null)
    # Only call the model if we actually have changes to describe.
    # `--stat` is empty when nothing's staged; the divider alone
    # without it isn't worth burning a call on.
    if printf '%s' "$diff_summary" | grep -q "files\? changed"; then
      local api_subject
      api_subject=$(claude_call \
        "$AGENT_MODEL" \
        "commit-subject" \
        80 \
        "You generate ONE single-line conventional-commit subject. Output ONLY the subject line -- no quotes, no preamble, no explanation, no questions. Format: 'type: description' where type is one of feat/fix/chore/docs/style/refactor/test. Under 72 chars. Imperative mood ('Add X' not 'Added X'). Be specific about what changed. If the input is empty or you cannot tell what changed, output exactly: chore: tick work" \
        "$diff_summary")
      # Strip surrounding whitespace and any stray quotes
      api_subject=$(printf '%s' "$api_subject" \
        | head -1 \
        | sed -E 's/^[[:space:]"'\'']+|[[:space:]"'\'']+$//g')
      # Only accept if it actually looks like a conventional commit
      # subject. Catches conversational responses like "I'm ready
      # to generate conventional commit subjects. Please provide..."
      if [ -n "$api_subject" ] && looks_like_conventional_commit "$api_subject"; then
        printf '%s' "$api_subject"
        return 0
      fi
    fi
  fi

  # Tier 3: fallback (already conventional-commit shaped by convention)
  printf '%s' "$fallback"
}

# Derive a full PR body (two-checklist Markdown) from the diff. Used
# as a fallback when Claude exited without writing .agent/PR_BODY.md
# this tick -- AGENTS.md says it's mandatory but compliance is
# probabilistic, and a thin git-log-derived body wastes the
# reviewer's time. Better to spend one cheap completion synthesizing
# a real description than ship a one-liner.
#
# Args:
#   $1 -- worktree path (used to compute the diff against base)
#   $2 -- base branch (e.g., "master")
#
# Returns: a markdown body string on stdout, or empty on failure.
# Callers should fall back to git-log-derived body if this returns
# empty. The returned body includes a visible note at the top so the
# human reviewer knows it was harness-generated, not claude-written.
derive_pr_body() {
  local worktree="$1" base="$2"
  [ -n "$worktree" ] && [ -d "$worktree" ] || return 1

  local diff_summary
  diff_summary=$( (
    cd "$worktree" && {
      git diff --stat "origin/${base}..HEAD" 2>/dev/null
      echo "---"
      git diff "origin/${base}..HEAD" 2>/dev/null | head -400
    }
  ) 2>/dev/null)

  printf '%s' "$diff_summary" | grep -q "files\? changed" || return 1

  local body
  body=$(claude_call \
    "$AGENT_MODEL" \
    "pr-body-fallback" \
    800 \
    "You generate Forgejo PR bodies from git diffs. Output EXACTLY this format and nothing else -- no preamble, no explanation, no fenced code blocks around the output:

## What this PR does

- [x] type: short imperative description (conventional commit subject -- types: feat/fix/chore/docs/style/refactor/test)
- [x] (additional bullets describing what changed, one per logical change)

## Test plan

- [x] (what was verified during the run, e.g., \`npm test\` passes locally)
- [ ] (manual steps the human reviewer should run, if any -- be specific)

Rules:
- First 'What this PR does' bullet MUST have a conventional commit prefix (feat:/fix:/chore:/docs:/style:/refactor:/test:) and be under 72 chars.
- Pre-check ([x]) anything verifiable from the diff (tests added, lint expected to pass, scripted assertions).
- Leave unchecked ([ ]) for steps that need a human (manual UI checks, comparing against external systems).
- If the diff is purely doc/refactor with no manual testing needed, Test plan can be just '- [x] No manual verification needed; CI is the gate'.
- Be terse and accurate. Don't invent context not in the diff." \
    "$diff_summary")

  # Strip leading/trailing whitespace and any fenced-code wrappers
  # the model occasionally adds despite instructions.
  body=$(printf '%s' "$body" \
    | sed -E '/^```/d' \
    | awk 'NF || found { found=1; print }' \
    | sed -E ':a;/^\n*$/{$d;N;ba}')

  # Sanity check: it must contain both required headings or we
  # don't trust it.
  if ! printf '%s' "$body" | grep -q "## What this PR does" \
     || ! printf '%s' "$body" | grep -q "## Test plan"; then
    return 1
  fi

  # No "harness-generated, claude didn't write this" marker. The
  # signal lives in the harness log ("WARNING: PR_BODY.md was NOT
  # written by claude this tick"). PR bodies don't need to advertise
  # their provenance to the reviewer -- the body is the body.
  printf '%s' "$(normalize_unicode_dashes "$body")"
}

# Returns a newline-separated list of off-limits paths touched in the
# diff against the given base ref, or empty if none. Off-limits paths
# are CI workflow files (.forgejo/workflows/, .github/workflows/) --
# Claude shouldn't be modifying CI from inside a tick. Callers should
# abandon (don't push) when this returns non-empty.
list_offlimits_violations() {
  # WORKFLOW BAN LIFTED (2026-07-01, Josh's call). The agent may now touch
  # `.forgejo/workflows/` -- so the agent can maintain CI workflows instead
  # of bouncing every workflow change to a human ticket. What still guards
  # it: the security_gate reviews every diff before
  # it ships, the human reviews and merges every PR, and the secret-bearing
  # deploy workflow runs on `push: master` only (never on a PR), so a
  # workflow change can't run with secrets before the human's merge gates it.
  # Returns empty (nothing off-limits); the callers keep their guard blocks so
  # re-enabling the ban is a one-line revert of this function.
  : "${1:-}"   # base ref -- unused now (kept for signature stability)
  return 0
}

# Conflict-marker gate. When the harness stages a base-branch merge into
# a reopened PR (see PR-review pickup), a botched resolution can leave
# literal git conflict markers in a committed file -- exactly how PR #191
# shipped <<<<<<< / ======= / >>>>>>> straight to master because nothing
# checked. Scan the new commits' delta for an ADDED line beginning with
# git's 7-character angle marker (anchored at line start + a trailing
# space/EOL, so a Python ">>> " prompt or a markdown "> " quote can't
# false-trigger; a real conflict always carries both angle markers, so
# the noisier bare "=======" separator needn't be matched). Returns the
# offending lines; a non-empty result fails the push closed.
list_conflict_marker_violations() {
  local base="$1"
  # shellcheck disable=SC2016  # the $ is a regex end-anchor, not a shell var
  git diff "origin/${base}..HEAD" 2>/dev/null \
    | grep -E '^\+(<<<<<<<|>>>>>>>)( |$)' \
    | sed 's/^+//' || true
}



# Idempotent clone-if-missing + ref refresh. Creates the owner subdir
# as needed.
#
# The clone is an ANCHOR, not a workspace: every surface (issue work,
# maintenance, PR review, site-work) carves a disposable `git worktree`
# off `origin/<ref>` and runs its own `git fetch` first, so nothing
# reads this clone's own working tree. We only keep its refs current --
# `git fetch`, never a working-tree-mutating `git pull --rebase`. That
# is also why a stray dirty or untracked file here (e.g. a build
# remnant) can't wedge the tick the way the old pull could: fetch never
# touches the working tree, so there is nothing to conflict and no
# recovery dance to run.
ensure_repo_local() {
  local repo="$1" local_path
  local_path=$(repo_path_for "$repo")
  if [ ! -d "$local_path/.git" ]; then
    log "bootstrap: cloning $repo to $local_path"
    mkdir -p "$(dirname "$local_path")"
    git clone "$(ssh_clone_url "$repo")" "$local_path"
    return
  fi

  (cd "$local_path" && git fetch --prune --quiet origin 2>/dev/null) \
    || log "warning: fetch of $repo failed; worktrees fall back to last-fetched refs"
}

# -- Discretionary-work state (maintenance + post cooldowns) ----
#
# Tracks per-repo "last maintained" timestamps so we don't run
# maintenance on the same repo every empty tick. Lives at
# $AGENT_STATE_DIR/discretionary-state.json. Regenerable -- losing
# it just makes every repo eligible again.

discretionary_state_file() { echo "$AGENT_STATE_DIR/discretionary-state.json"; }

maintenance_last_run() {
  local repo="$1" state_file
  state_file=$(discretionary_state_file)
  [ -f "$state_file" ] || { echo ""; return; }
  jq -r --arg r "$repo" '.maintenance[$r] // ""' "$state_file" 2>/dev/null || echo ""
}

maintenance_mark_done() {
  local repo="$1" state_file tmp ts
  ts=$(date +%Y-%m-%dT%H:%M:%S%z)
  state_file=$(discretionary_state_file)
  [ -f "$state_file" ] || echo '{}' > "$state_file"
  tmp=$(mktemp)
  jq --arg r "$repo" --arg t "$ts" \
    '.maintenance //= {} | .maintenance[$r] = $t' "$state_file" > "$tmp"
  mv "$tmp" "$state_file"
}

# -- Daily site-work slots --------------------------------------
#
# Four discretionary slots, at most one fired per tick, each at
# most once per local calendar day: reading, ideation, feature,
# design.
# State lives in the same discretionary-state.json under a "slots"
# object: { "date": "YYYY-MM-DD", "reading": "done", ... }.
# Regenerable -- losing it just re-opens today's slots, and the
# work gets re-attempted (acceptable; one wasted pass at worst).
#
# A slot is marked done once ATTEMPTED, whether or not it shipped
# a PR. That's deliberate: a clean "nothing to do" is a valid
# answer for the day, and marking done prevents a retry storm of
# LLM calls across the rest of the shift.

slot_today() { date +%Y-%m-%d; }

# Reset the slot slate when the local date rolls over. Idempotent;
# call at the top of the discretionary cascade every tick.
slot_rollover() {
  local state_file tmp today stored
  state_file=$(discretionary_state_file)
  today=$(slot_today)
  [ -f "$state_file" ] || echo '{}' > "$state_file"
  stored=$(jq -r '.slots.date // ""' "$state_file" 2>/dev/null || echo "")
  if [ "$stored" != "$today" ]; then
    tmp=$(mktemp)
    jq --arg d "$today" '.slots = {date: $d}' "$state_file" > "$tmp"
    mv "$tmp" "$state_file"
  fi
}

# 0 if the named slot is already done today, 1 otherwise.
slot_is_done() {
  local slot="$1" state_file
  state_file=$(discretionary_state_file)
  [ -f "$state_file" ] || return 1
  [ "$(jq -r --arg s "$slot" '.slots[$s] // ""' "$state_file" 2>/dev/null)" = "done" ]
}

# Stamp the named slot done for today. slot_rollover owns the
# date key; this only flips the slot bit.
slot_mark_done() {
  local slot="$1" state_file tmp
  state_file=$(discretionary_state_file)
  [ -f "$state_file" ] || echo '{}' > "$state_file"
  tmp=$(mktemp)
  jq --arg s "$slot" '.slots //= {} | .slots[$s] = "done"' "$state_file" > "$tmp"
  mv "$tmp" "$state_file"
}

# Per-day attempt counter for a slot. The post slot uses this to retry
# until a post ships without retrying forever. slot_rollover wipes
# .slots each day, so the counter resets at midnight automatically.
# Echoes the new count.
slot_attempt_inc() {
  local slot="$1" state_file tmp n key
  key="${slot}_attempts"
  state_file=$(discretionary_state_file)
  [ -f "$state_file" ] || echo '{}' > "$state_file"
  n=$(jq -r --arg k "$key" '.slots[$k] // 0' "$state_file" 2>/dev/null)
  n=$((n + 1))
  tmp=$(mktemp)
  jq --arg k "$key" --argjson n "$n" '.slots //= {} | .slots[$k] = $n' "$state_file" > "$tmp"
  mv "$tmp" "$state_file"
  echo "$n"
}

# -- Weekly slots (now, site-work) ------------------------------
#
# ISO-week (Monday-anchored, local) eligibility for single-target
# Igor work that runs once a week rather than once a day. Mirrors
# maintenance's ISO-week gate but keyed by name under a "weekly"
# object in discretionary-state.json. Regenerable -- losing it just
# re-opens this week's weekly work.

weekly_done() {
  local name="$1" state_file last this_week
  state_file=$(discretionary_state_file)
  [ -f "$state_file" ] || return 1
  last=$(jq -r --arg n "$name" '.weekly[$n] // ""' "$state_file" 2>/dev/null)
  [ -z "$last" ] && return 1
  this_week=$(date +%G-W%V)
  [ "$last" = "$this_week" ]
}

weekly_mark_done() {
  local name="$1" state_file tmp this_week
  state_file=$(discretionary_state_file)
  this_week=$(date +%G-W%V)
  [ -f "$state_file" ] || echo '{}' > "$state_file"
  tmp=$(mktemp)
  jq --arg n "$name" --arg w "$this_week" \
    '.weekly //= {} | .weekly[$n] = $w' "$state_file" > "$tmp"
  mv "$tmp" "$state_file"
}

# -- SEO per-domain monthly state -------------------------------
#
# A per-GSC-domain cadence gate, keyed under a "seo" object in
# discretionary-state.json. One domain is analyzed per tick
# (do_seo_tick), so this stamps each as it's done and the next
# eligible domain is picked next tick. Regenerable.
#
# Cadence: once per CALENDAR MONTH. The analysis window is 28 days
# (seo_window), so a monthly beat hands each run a fresh,
# near-non-overlapping window -- and gives any fix from last month's
# ticket time to land before the page is re-evaluated (a weekly beat
# re-flagged the same pages before their CTR could move). Self-healing:
# eligibility is "stamp != current period", NOT a hard day-of-month
# window, so a transient early-month failure just re-runs on the next
# tick instead of skipping the whole month. seo_period is the ONLY
# place the cadence lives -- switch it to "%G-W%V" (weekly) or a
# quarter computation and every call site below follows.

seo_period() { date +%Y-%m; }

seo_eligible() {
  local domain="$1" state_file last this_period
  state_file=$(discretionary_state_file)
  [ -f "$state_file" ] || return 0
  last=$(jq -r --arg d "$domain" '.seo[$d] // ""' "$state_file" 2>/dev/null)
  [ -z "$last" ] && return 0
  this_period=$(seo_period)
  [ "$last" != "$this_period" ]
}

seo_mark_done() {
  local domain="$1" state_file tmp this_period
  state_file=$(discretionary_state_file)
  this_period=$(seo_period)
  [ -f "$state_file" ] || echo '{}' > "$state_file"
  tmp=$(mktemp)
  jq --arg d "$domain" --arg w "$this_period" \
    '.seo //= {} | .seo[$d] = $w' "$state_file" > "$tmp"
  mv "$tmp" "$state_file"
}

# format_report_date <YYYY-MM-DD>
# Returns a human-readable date like "Tuesday, June 9th, 2026".
format_report_date() {
  local date_str="$1" day suffix weekday month year
  day="${date_str##*-}"; day="${day#0}"
  case "$day" in
    1|21|31) suffix="st" ;;
    2|22)    suffix="nd" ;;
    3|23)    suffix="rd" ;;
    *)       suffix="th" ;;
  esac
  weekday=$(date -d "$date_str" +%A 2>/dev/null || date -jf "%Y-%m-%d" "$date_str" +%A 2>/dev/null)
  month=$(date -d "$date_str" +%B 2>/dev/null || date -jf "%Y-%m-%d" "$date_str" +%B 2>/dev/null)
  year="${date_str%%-*}"
  printf '%s, %s %s%s, %s' "$weekday" "$month" "$day" "$suffix" "$year"
}

# -- Sports digest state (discretionary-state.json `.sports`) -----
#
# A day-keyed object (one report per day, retry-on-cooldown until it
# sends, bounded hard-failure budget):
#   .sports = { date, sent, failures, last_attempt }
# Here the metered resource being protected is the model call, not an
# API quota -- ESPN is free, but a parse-flaky day must not re-run the
# distill call every minute. The taught-concepts curriculum ledger
# lives in its own file (see lib/sports-digest.sh), NOT here, so
# clearing `.sports` to force a re-send never wipes it.
# Regenerable -- losing it just re-opens today's send.

SPORTS_RETRY_COOLDOWN_SECS="${SPORTS_RETRY_COOLDOWN_SECS:-900}"  # 15 min

# jq fragment: normalize .sports to today, resetting if the day rolled.
# shellcheck disable=SC2016  # $d is a jq --arg, not shell -- must not expand
SPORTS_ROLL='(if (.sports.date // "") == $d then .sports
              else {date:$d, sent:false, failures:0, last_attempt:0} end)'

sports_sent_today() {
  local state_file today
  state_file=$(discretionary_state_file)
  [ -f "$state_file" ] || return 1
  today=$(date +%Y-%m-%d)
  [ "$(jq -r --arg d "$today" \
        '(.sports.date == $d) and (.sports.sent == true)' \
        "$state_file" 2>/dev/null)" = "true" ]
}

sports_mark_sent() {
  local state_file tmp today
  state_file=$(discretionary_state_file)
  today=$(date +%Y-%m-%d)
  [ -f "$state_file" ] || echo '{}' > "$state_file"
  tmp=$(mktemp)
  jq --arg d "$today" ".sports = ($SPORTS_ROLL | .sent = true)" \
    "$state_file" > "$tmp"
  mv "$tmp" "$state_file"
}

# Echo today's failure count (0 if unset or the day rolled). Read-only --
# the cap that consumes it lives in do_sports_tick.
sports_failures() {
  local state_file today n
  state_file=$(discretionary_state_file)
  [ -f "$state_file" ] || { echo 0; return; }
  today=$(date +%Y-%m-%d)
  n=$(jq -r --arg d "$today" \
    'if (.sports.date // "") == $d then (.sports.failures // 0) else 0 end' \
    "$state_file" 2>/dev/null)
  [ -n "$n" ] && [ "$n" != "null" ] || n=0
  echo "$n"
}

# Stamp last_attempt=now (resetting on a day rollover). Called once per
# digest attempt, before any fetch/model work -- it's what the cooldown
# reads.
sports_mark_attempt() {
  local state_file tmp today now
  state_file=$(discretionary_state_file)
  today=$(date +%Y-%m-%d)
  now=$(date +%s)
  [ -f "$state_file" ] || echo '{}' > "$state_file"
  tmp=$(mktemp)
  jq --arg d "$today" --argjson now "$now" \
    ".sports = ($SPORTS_ROLL | .last_attempt = \$now)" \
    "$state_file" > "$tmp"
  mv "$tmp" "$state_file"
}

# Bump today's HARD-failure count (empty fetch / failed or unparseable
# distill call / send failure) and echo the new value.
sports_failure_inc() {
  local state_file tmp today n
  state_file=$(discretionary_state_file)
  today=$(date +%Y-%m-%d)
  [ -f "$state_file" ] || echo '{}' > "$state_file"
  tmp=$(mktemp)
  jq --arg d "$today" ".sports = ($SPORTS_ROLL | .failures += 1)" \
    "$state_file" > "$tmp"
  mv "$tmp" "$state_file"
  n=$(jq -r '.sports.failures' "$state_file" 2>/dev/null)
  echo "$n"
}

# True when it's OK to attempt the digest again today: either no attempt
# yet (the first post-03:00 tick fires immediately) or the cooldown since
# the last attempt has elapsed.
sports_retry_ready() {
  local state_file today last now
  state_file=$(discretionary_state_file)
  [ -f "$state_file" ] || return 0
  today=$(date +%Y-%m-%d)
  last=$(jq -r --arg d "$today" \
    'if (.sports.date // "") == $d then (.sports.last_attempt // 0) else 0 end' \
    "$state_file" 2>/dev/null)
  [ -n "$last" ] && [ "$last" != "null" ] || last=0
  now=$(date +%s)
  [ "$((now - last))" -ge "$SPORTS_RETRY_COOLDOWN_SECS" ]
}

# -- Review state ----------------------------------------
#
# Keyed per PR under ".review" in discretionary-state.json (same file
# as .slots/.seo/...), shaped { "<repo>#<num>": {sha, verdict,
# ci, at} }. Dedup is by HEAD SHA, not by PR: the reviewer reviews each
# distinct head once, so a PR that gets new commits (the author
# addressed feedback, or the human pushed) is re-reviewed, but a PR
# sitting idle isn't re-reviewed every minute. Regenerable -- losing it
# just re-posts a verdict on heads it already covered (the per-sha
# comment marker is the crash-safety net against a duplicate).

# Echo the head sha the reviewer last recorded a verdict for on this
# PR, or empty if never (or state missing). Caller compares to the live
# head sha to decide whether this head still needs a review.
review_reviewed_sha() {
  local key="$1" state_file
  state_file=$(discretionary_state_file)
  [ -f "$state_file" ] || { printf ''; return; }
  jq -r --arg k "$key" '.review[$k].sha // ""' "$state_file" 2>/dev/null || printf ''
}

# Echo the patch-id stored alongside the last verdict, or empty if none.
review_reviewed_patchid() {
  local key="$1" state_file
  state_file=$(discretionary_state_file)
  [ -f "$state_file" ] || { printf ''; return; }
  jq -r --arg k "$key" '.review[$k].patch_id // ""' "$state_file" 2>/dev/null || printf ''
}

# Record the verdict for a PR's head. epoch `at` is passed in (the
# caller already has `date +%s` from timing the review) so this stays a
# pure read-modify-write with no clock of its own. patch_id is optional
# (empty string is fine for recovery paths that don't have it).
review_record() {
  local key="$1" sha="$2" verdict="$3" ci="$4" at="$5" patch_id="${6:-}" state_file tmp
  state_file=$(discretionary_state_file)
  [ -f "$state_file" ] || echo '{}' > "$state_file"
  tmp=$(mktemp)
  jq --arg k "$key" --arg s "$sha" --arg v "$verdict" --arg c "$ci" --argjson t "$at" --arg p "$patch_id" \
    '.review //= {} | .review[$k] = ((.review[$k] // {}) + {sha:$s, verdict:$v, ci:$c, at:$t, patch_id:$p})' \
    "$state_file" > "$tmp"
  mv "$tmp" "$state_file"
}

# Update only the sha for a PR whose head advanced without a content
# change (base-merge). Keeps verdict/ci/at/patch_id intact so the
# recorded verdict still reflects the unchanged content.
review_update_sha() {
  local key="$1" sha="$2" state_file tmp
  state_file=$(discretionary_state_file)
  [ -f "$state_file" ] || return
  tmp=$(mktemp)
  jq --arg k "$key" --arg s "$sha" \
    '.review //= {} | .review[$k].sha = $s' \
    "$state_file" > "$tmp"
  mv "$tmp" "$state_file"
}

# Echo rework_rounds for a PR from review state, defaulting to 0.
review_rework_rounds() {
  local key="$1" state_file n
  state_file=$(discretionary_state_file)
  [ -f "$state_file" ] || { echo 0; return; }
  n=$(jq -r --arg k "$key" '.review[$k].rework_rounds // 0' "$state_file" 2>/dev/null)
  [ -n "$n" ] && [ "$n" != "null" ] || n=0
  echo "$n"
}

# Echo rework_crashes (ticks that died mid-rework without reaching a verdict) for a
# PR. Distinct from rework_rounds (rejections): a crash never completes, so it is
# counted crash-safely -- stamped BEFORE the rework call, reset only on a clean
# return -- and once it caps, the rework is escalated instead of looping (igor#291).
review_rework_crashes() {
  local key="$1" state_file n
  state_file=$(discretionary_state_file)
  [ -f "$state_file" ] || { echo 0; return; }
  n=$(jq -r --arg k "$key" '.review[$k].rework_crashes // 0' "$state_file" 2>/dev/null)
  [ -n "$n" ] && [ "$n" != "null" ] || n=0
  echo "$n"
}

# Set rework_crashes for a PR (preserves all other review fields).
review_set_rework_crashes() {
  local key="$1" n="$2" state_file tmp
  state_file=$(discretionary_state_file)
  [ -f "$state_file" ] || echo '{}' > "$state_file"
  tmp=$(mktemp)
  if jq --arg k "$key" --argjson n "$n" \
    '.review //= {} | .review[$k].rework_crashes = $n' "$state_file" > "$tmp"; then
    mv "$tmp" "$state_file"
  else
    rm -f "$tmp"
  fi
}

# Echo pending_rc_body for a PR from review state, or empty string.
review_pending_rc_body() {
  local key="$1" state_file
  state_file=$(discretionary_state_file)
  [ -f "$state_file" ] || { printf ''; return; }
  jq -r --arg k "$key" '.review[$k].pending_rc_body // ""' "$state_file" 2>/dev/null || printf ''
}

# Set rework_rounds for a PR (preserves all other review fields).
review_set_rework_rounds() {
  local key="$1" n="$2" state_file tmp
  state_file=$(discretionary_state_file)
  [ -f "$state_file" ] || echo '{}' > "$state_file"
  tmp=$(mktemp)
  jq --arg k "$key" --argjson n "$n" \
    '.review //= {} | .review[$k].rework_rounds = $n' "$state_file" > "$tmp"
  mv "$tmp" "$state_file"
}

# Set pending_rc_body for a PR (preserves all other review fields).
review_set_pending_rc_body() {
  local key="$1" body="$2" state_file tmp
  state_file=$(discretionary_state_file)
  [ -f "$state_file" ] || echo '{}' > "$state_file"
  tmp=$(mktemp)
  jq --arg k "$key" --arg b "$body" \
    '.review //= {} | .review[$k].pending_rc_body = $b' "$state_file" > "$tmp"
  mv "$tmp" "$state_file"
}

# Reset rework state: rework_rounds=0 and pending_rc_body="" (preserves other fields).
review_reset_rework() {
  local key="$1" state_file tmp
  state_file=$(discretionary_state_file)
  [ -f "$state_file" ] || return 0
  tmp=$(mktemp)
  jq --arg k "$key" \
    '.review //= {} | .review[$k].rework_rounds = 0 | .review[$k].pending_rc_body = ""' \
    "$state_file" > "$tmp"
  mv "$tmp" "$state_file"
}

# Every level these two ladders emit -- high, xhigh, max -- is a member of the
# CLI's --effort enum (`claude --help`: low, medium, high, xhigh, max), so a
# bad-token failure that would silently kill the merge gate can't arise from
# the values below. Verified against the enum and by a clean live -p run of
# each of the three deployed tokens (igor#308).
#
# reviewer_effort <rework_rounds> -- reasoning effort for the shadow review
# at this rework round (igor#308). FLAT ("high") during the loop -- a stable
# bar the worker can converge on (a reviewer that got pickier every round
# would move the goalposts and the PR would never land) -- then "max" for the
# LAST look before the human takes over (the "final boss": rare, and the
# alternative is Josh's time, so max effort is the cheap bet). Escalation to
# the human fires at rounds >= 3 (see the REQUEST_CHANGES handler), so the
# review at rounds>=3 is the one that maxes. Hardcoded, not a knob.
reviewer_effort() {
  local rounds="${1:-0}"
  if [ "${rounds:-0}" -ge 3 ]; then printf 'max'; else printf 'high'; fi
}

# worker_effort <rework_rounds> -- reasoning effort for the bot's PR rework
# at this round (igor#308). Climbs each pass -- try harder as the problem
# proves hard: high -> xhigh -> max (round 3 is the last rework before the
# reviewer escalates to the human). Hardcoded, not a knob.
worker_effort() {
  case "${1:-0}" in
    0|1) printf 'high' ;;
    2)   printf 'xhigh' ;;
    *)   printf 'max' ;;
  esac
}

# -- Validation pass cache --------------------------------------
#
# The validation sweep runs every tick. At a 1-minute cadence across
# many repos that's a lot of redundant API calls re-proving the same
# repos pass. Cache the PASS result for a cooldown window so
# validation effectively runs ~once per window per repo regardless of
# tick frequency. Failures are NOT cached -- a not-ready repo re-checks
# every tick, so it starts getting worked the moment the operator fixes
# it. Stored as epoch seconds under a "validation" object.
VALIDATION_COOLDOWN_SECS="${VALIDATION_COOLDOWN_SECS:-900}"  # 15 min

validation_mark_ok() {
  local repo="$1" state_file tmp ts
  ts=$(date +%s)
  state_file=$(discretionary_state_file)
  [ -f "$state_file" ] || echo '{}' > "$state_file"
  tmp=$(mktemp)
  jq --arg r "$repo" --argjson t "$ts" \
    '.validation //= {} | .validation[$r] = $t' "$state_file" > "$tmp"
  mv "$tmp" "$state_file"
}

# 0 if the repo passed validation within the cooldown window.
validation_fresh() {
  local repo="$1" state_file last now
  state_file=$(discretionary_state_file)
  [ -f "$state_file" ] || return 1
  last=$(jq -r --arg r "$repo" '.validation[$r] // ""' "$state_file" 2>/dev/null)
  [ -z "$last" ] && return 1
  now=$(date +%s)
  [ "$((now - last))" -lt "$VALIDATION_COOLDOWN_SECS" ]
}

# True if a blog post dated today already exists -- on the website's
# origin/master or in an open bot PR. Mirrors ideation-pipeline.sh's
# own daily refrain so the post slot only counts as done once a post
# actually shipped. Requires WEBSITE_REPO.
post_shipped_today() {
  [ -n "$WEBSITE_REPO" ] || return 1
  local today re wt count open_prs pr_num
  today=$(date +%Y-%m-%d)
  re="^src/posts/[0-9]{4}/${today}-.+\.md$"
  wt=$(repo_path_for "$WEBSITE_REPO")
  if [ -d "$wt/.git" ]; then
    (cd "$wt" && git fetch --quiet origin master 2>/dev/null) || true
    count=$(cd "$wt" && git ls-tree --name-only -r origin/master 2>/dev/null \
      | grep -cE "$re" 2>/dev/null) || count=0
    [ "${count:-0}" -gt 0 ] && return 0
  fi
  open_prs=$(forgejo_list_open_bot_prs "$WEBSITE_REPO" "$BOT_USER" 2>/dev/null || echo '[]')
  while read -r pr_num; do
    [ -z "$pr_num" ] && continue
    if forgejo_pr_files "$WEBSITE_REPO" "$pr_num" 2>/dev/null \
        | jq -e --arg re "$re" \
            '[.[] | select(.filename | test($re))] | length > 0' \
            >/dev/null 2>&1; then
      return 0
    fi
  done < <(jq -r '.[].number' <<<"$open_prs" 2>/dev/null)
  return 1
}

# Build the /now digest: the last week's reflections (reading +
# thoughts) straight from brain.sqlite, newest first. Empty string
# if there's no brain or nothing this week -- the now-directive
# handles a thin digest. This is the "last week of digestion" the
# /now page is rebuilt from.
build_now_digest() {
  local brain="$AGENT_STATE_DIR/brain.sqlite"
  [ -f "$brain" ] || { echo ""; return 0; }
  sqlite3 "$brain" \
    "SELECT '- (' || date(ts) || ', ' || kind || ') '
            || CASE WHEN source_url IS NOT NULL AND source_url != ''
                    THEN source_url || char(10) || '  ' ELSE '' END
            || substr(replace(replace(content, char(10), ' '), char(13), ' '), 1, 300)
     FROM reflections
     WHERE ts >= date('now','-7 days')
       AND kind IN ('reading','thought')
     ORDER BY ts DESC
     LIMIT 50;" 2>/dev/null
}

# Daily-post retry ceiling: leave the post slot open across this many
# ticks until a post ships, then give up for the day so a wedged
# pipeline can't starve the ticket grind.
POST_MAX_ATTEMPTS="${POST_MAX_ATTEMPTS:-8}"


# Eligible if not run this ISO week (weeks start Monday, local time).
# Any tick all week can pick up an eligible repo -- no shift-window
# gate. Resilient to Monday-tick failures and to new repos added
# mid-week.
#
# Deliberately does NOT skip repos that failed validation (aren't ready
# for work). The maintenance audit is read-only -- it only files an
# issue, never commits -- so a not-ready repo still gets its
# dependencies audited (matching the ANALYSIS_REPOS_JSON set
# do_maintenance_tick loops). Validation gates WORK pickup, not this.
maintenance_eligible() {
  local repo="$1" last last_week this_week

  last=$(maintenance_last_run "$repo")
  [ -z "$last" ] && return 0
  # ISO week (YYYY-Www): local time, same week = blocked
  last_week=$(date -d "$last" +%G-W%V 2>/dev/null \
    || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last" +%G-W%V 2>/dev/null \
    || echo "")
  this_week=$(date +%G-W%V)
  [ "$last_week" != "$this_week" ]
}

# Scheduled maintenance/analysis pass.
# Loops EVERY bot-accessible repo eligible this ISO week -- the
# ANALYSIS set (ANALYSIS_REPOS_JSON), NOT the validated WORK set.
# Analysis is read-only (it files tickets, never commits), so it is
# deliberately decoupled from validation: a repo that fails validation
# (isn't ready for work) still gets its dependencies audited. The
# two-tier split lives one level down, in
# do_maintenance_for_repo: a finding becomes an Agent-labeled bump
# ticket (-> reviewed PR via the work flow) ONLY on a validated repo;
# otherwise it's a human triage ticket. So audit reach ignores
# validation, but PR-routing honors it. Returns 0 if any maintenance
# ran, 1 if nothing was eligible this week.
#
# Each repo's maintenance is its own self-contained pass in
# do_maintenance_for_repo, with its own worktree + cleanup. The
# previous "one repo, exit 0 when done" shape became a per-repo
# return so the loop continues. maintenance_mark_done stamps each
# repo so re-runs within the same ISO week skip already-audited
# repos (resilience if a tick crashes mid-loop).
#
# Igor-driven (scheduled chore). Runs after Igor's own daily work in
# the cascade; no time-of-day gate (the shift window was removed).
do_maintenance_tick() {
  # Stale headless-browser reap runs first and unconditionally, ahead of
  # the weekly per-repo eligibility gate below -- it's not itself a
  # per-repo audit, just a host-level cleanup that should self-heal every
  # time this function is reached (igor#388). Non-model (ps + kill only);
  # silent no-op when nothing is stale.
  browser_reap_sweep

  local repo_line r_name
  local eligible=()
  while IFS= read -r repo_line; do
    [ -z "$repo_line" ] && continue
    r_name=$(jq -r '.full_name' <<<"$repo_line")
    if maintenance_eligible "$r_name"; then
      eligible+=("$r_name")
    fi
  done <<<"$ANALYSIS_REPOS_JSON"

  if [ "${#eligible[@]}" -eq 0 ]; then
    log "maintenance: no repos eligible this week -- continuing"
    return 1
  fi

  log "maintenance: ${#eligible[@]} repo(s) eligible this week"
  local target
  for target in "${eligible[@]}"; do
    do_maintenance_for_repo "$target" \
      || log "warning: maintenance for $target returned non-zero (continuing)"
  done
  return 0
}

# -- Maintenance issue routing -----------------------------------
#
# The audit fans its results out to up to four DEDUPED tickets, each
# keyed by an HTML-comment marker (same mechanism as the SEO
# tickets). Dedup is skip-if-open: a repo is audited at most once
# per ISO week (maintenance_eligible), so the only thing to guard is
# last week's ticket still being open -- we don't stack a second one.
#
# Two tiers, decided by validation. A repo that PASSES validation has
# (provably) a test signal + a CI workflow -- so a dependency bump can
# be opened as a PR and actually verified. Those repos get Agent-labeled
# "apply these bumps" tickets that the normal claimable-work flow turns
# into a reviewed PR (the maintenance pass never commits; the work flow
# does, gated by validation). Repos that don't validate -- or findings
# that need human judgment -- get a triage ticket instead: audit reach
# is preserved for every repo, but nothing lands as an unverifiable PR.
MAINT_SECURITY_MARKER="<!-- agent:maint-security -->"  # Agent: clean security fix -> PR
MAINT_BUMPS_MARKER="<!-- agent:maint-bumps -->"        # Agent: routine drift bumps -> PR
MAINT_TRIAGE_MARKER="<!-- agent:maint-triage -->"      # human: majors + judgment + unvalidated
MAINT_TOOLING_MARKER="<!-- agent:maint-tooling -->"    # human: an audit tool could not run

# True if <repo> is in the validated WORK set (has tests + CI per
# validate_repo_local). VALIDATED_REPOS_JSON is the newline-delimited
# repo set the per-tick validation sweep builds before the cascade runs.
maintenance_repo_validated() {
  local target="$1"
  printf '%s' "$VALIDATED_REPOS_JSON" | jq -r '.full_name' 2>/dev/null \
    | grep -qxF "$target"
}

# critical|high|medium|low -> Priority/* label ("" for anything else).
maint_priority_label() {
  case "$1" in
    critical) echo "Priority/Critical" ;;
    high)     echo "Priority/High" ;;
    medium)   echo "Priority/Medium" ;;
    low)      echo "Priority/Low" ;;
    *)        echo "" ;;
  esac
}

# maint_file_deduped_issue <repo> <marker> <title> <body> <agent-bool> <priority-label|""> [fingerprint]
# Files <body> (which MUST already contain <marker>) as an issue, deduped.
# Without a fingerprint: skip-if-OPEN (re-files once the prior ticket closes --
# right for work tickets, whose ticket closes when their PR merges -> re-audit).
# WITH a fingerprint (maint-triage): skip if ANY issue, OPEN or CLOSED, already
# carries that finding-set's fingerprint -- so a judged-and-dismissed (closed)
# finding-set STAYS dismissed, while a genuinely-new finding-set (new fingerprint)
# still surfaces. The fingerprint marker is appended to <body> so future audits
# recognize it.
# agent-bool=true -> Agent-labeled + left UNASSIGNED so claimable
# discovery works it into a PR; false -> Status/Need More Info for a
# human. No-op-safe: logs and returns 0 on any Forgejo hiccup so the
# audit loop continues.
maint_file_deduped_issue() {
  local repo="$1" marker="$2" title="$3" body="$4" agent="$5" pri="$6" fp="${7:-}"
  local existing
  if [ -n "$fp" ]; then
    local fpmarker; fpmarker=$(maint_fp_marker "$fp")
    existing=$(forgejo_find_marked_issue "$repo" "$BOT_USER" "$fpmarker" 2>/dev/null) \
      || { log "warning: maintenance: can't check fingerprint on $repo (API error) -- skipping"; return 0; }
    if [ -n "$existing" ] && [ "$existing" != "null" ]; then
      log "maintenance: $repo finding-set already filed/dismissed (#$(jq -r '.number' <<<"$existing") [$(jq -r '.state' <<<"$existing")]) -- not refiling ${marker}"
      return 0
    fi
    body="${body}
${fpmarker}"
  else
    existing=$(forgejo_find_marked_issue "$repo" "$BOT_USER" "$marker" 2>/dev/null) \
      || { log "warning: maintenance: can't check existing ticket on $repo (API error) -- skipping"; return 0; }
    if [ -n "$existing" ] && [ "$existing" != "null" ] \
       && [ "$(jq -r '.state' <<<"$existing" 2>/dev/null)" = "open" ]; then
      log "maintenance: $repo already has an open ticket #$(jq -r '.number' <<<"$existing") for ${marker} -- not refiling"
      return 0
    fi
  fi
  local num
  num=$(forgejo_open_issue "$repo" "$title" "$body") \
    || { log "warning: maintenance ticket open failed on $repo (continuing)"; return 0; }
  if [ "$agent" = "true" ]; then
    forgejo_add_label "$repo" "$num" "Agent" 2>/dev/null \
      || log "warning: could not apply 'Agent' on $repo#$num"
  else
    forgejo_add_label "$repo" "$num" "Status/Need More Info" 2>/dev/null \
      || log "warning: could not apply 'Status/Need More Info' on $repo#$num"
    # Human-triage tickets (maint-triage, maint-tooling) need to land in the
    # reviewer's queue -- assign them, the same as logwatch/feedback. Agent work
    # tickets (the if-branch) stay unassigned for the claimable grind to pick up.
    forgejo_assign "$repo" "$num" "$FORGEJO_REVIEWER" 2>/dev/null \
      || log "warning: could not assign $repo#$num to $FORGEJO_REVIEWER"
  fi
  if [ -n "$pri" ]; then
    forgejo_add_label "$repo" "$num" "$pri" 2>/dev/null \
      || log "warning: could not apply '$pri' on $repo#$num"
  fi
  log "maintenance: filed #$num on $repo (${marker})"
}

# Per-repo maintenance executor. Audits ONE repo via
# lib/maintenance-checks.sh and routes the result. Worktree is created
# here and cleaned via a RETURN trap so we don't leak when the function
# unwinds.
#
# Hybrid execution:
#   - Harness runs the audit tools (npm audit + outdated, cargo
#     audit + outdated, pip-audit + pip list --outdated,
#     govulncheck + go list -m -u all, bundle-audit + bundle
#     outdated).
#   - A tool that could NOT run (skipped/error) -> deduped operational
#     ticket: the host should be able to run its own tooling, and a
#     skipped tool is a blind spot, not a clean bill.
#   - Clean week / no recognized stack -> no LLM, no ticket.
#   - Findings -> ONE Claude pass CLASSIFIES them (it does not fix), and
#     the harness files up to three deduped tickets from its output:
#     security bumps + drift bumps (Agent-labeled, validated repos only,
#     -> reviewed PR) and a human triage ticket (majors/judgment, or
#     everything when the repo isn't validated).
do_maintenance_for_repo() {
  local target="$1"

  log "maintenance: pass on $target"
  ensure_repo_local "$target"
  local target_path target_base
  target_path=$(repo_path_for "$target")

  # Detached-HEAD worktree on the repo's current default branch.
  # No feature branch -- maintenance doesn't commit; it writes
  # raw audit output to .agent/audit-output/ for either templated
  # or LLM-triaged downstream handling.
  target_base=$(cd "$target_path" && git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
  target_base="${target_base:-master}"
  local m_worktree="$AGENT_STATE_DIR/worktrees/maintenance-${target//\//_}-$$"
  mkdir -p "$AGENT_STATE_DIR/worktrees"
  (cd "$target_path" && git fetch --prune origin) || return 1
  (cd "$target_path" && git worktree add --detach "$m_worktree" "origin/${target_base}") || return 1
  init_igor_scratch "$m_worktree"

  # Cleanup on ANY return path. Restore cwd to a known-safe place
  # too so the outer loop doesn't sit in a removed directory.
  # shellcheck disable=SC2064
  trap "cd '$AGENT_HOME' 2>/dev/null; (cd '$target_path' && git worktree remove --force '$m_worktree') 2>/dev/null || true" RETURN

  cd "$m_worktree"

  local audit_dir="$m_worktree/.agent/audit-output"
  mkdir -p "$audit_dir"

  log "maintenance: running audit tools on $target"
  local audit_rc=0
  set +e
  maintenance_audit_repo "$m_worktree" "$audit_dir"
  audit_rc=$?
  set -e

  # Broken-tool reporting, independent of findings. A tool that could
  # not run -- not installable (:skipped) or crashed mid-scan (:error,
  # e.g. govulncheck failing to build the project) -- means those deps
  # were NOT actually audited: a blind spot, not a clean bill. Surface
  # it as a deduped operational ticket so the host gets fixed instead of
  # the gap passing silently as "clean".
  local summary_file="$audit_dir/AUDIT_SUMMARY.txt"
  local broken
  broken=$(grep -hE ':(skipped|error)$' "$summary_file" 2>/dev/null || true)
  if [ -n "$broken" ]; then
    local ops_body tool_line tool_name
    ops_body="The scheduled maintenance audit on \`$target\` could not run one or more tools, so the dependencies those tools cover were NOT actually audited -- a blind spot, not a clean bill of health. The agent's host should be able to run its own audit tooling: install the missing tool, or fix whatever makes the scan fail.

"
    while IFS= read -r tool_line; do
      [ -z "$tool_line" ] && continue
      tool_name="${tool_line%%:*}"
      ops_body+="### ${tool_line}

\`\`\`
$(tail -n 30 "$audit_dir/${tool_name}.txt" 2>/dev/null || echo "(no output captured)")
\`\`\`

"
    done <<<"$broken"
    ops_body+="$MAINT_TOOLING_MARKER"
    maint_file_deduped_issue "$target" "$MAINT_TOOLING_MARKER" \
      "[maintenance] audit tooling can't run on $target" "$ops_body" false "Priority/Low"
  fi

  # rc==2: no recognized stack manifests. Templated "no audit
  # surface" outcome. Still mark done so we don't try again
  # this week.
  if [ "$audit_rc" -eq 2 ]; then
    log "maintenance: no recognized stack at $target -- nothing to audit"
    maintenance_mark_done "$target"
    return 0
  fi

  # rc==0: every audit/outdated check came back clean. No LLM,
  # no Forgejo issue. Just mark done.
  if [ "$audit_rc" -eq 0 ]; then
    log "maintenance: all checks clean on $target"
    maintenance_mark_done "$target"
    return 0
  fi

  # rc==1: findings in at least one tool. ONE Claude pass classifies
  # them into lanes (it classifies, it does not fix); the harness files
  # the resulting deduped tickets. Raw output is in .agent/audit-output/.
  log "maintenance: findings detected on $target, invoking claude for triage"

  local validated=false
  maintenance_repo_validated "$target" && validated=true
  log "maintenance: $target validated=$validated (validated -> bump PRs; else triage ticket)"

  local m_user_msg
  m_user_msg=$(cat <<EOF
You are triaging a scheduled dependency/security audit on $target. The
harness already ran the audit tools in this worktree; their raw output
is in .agent/audit-output/ -- one file per tool, plus AUDIT_SUMMARY.txt
listing clean/findings/skipped/error per check.

You are CLASSIFYING and ROUTING findings, NOT fixing them. Do not edit
code, do not commit, do not open PRs. The harness files tickets from
the files you write; a separate work flow makes any actual change.

This repo's validation status: VALIDATED=$validated.
  - true:  it has tests + CI, so a safe bump can be opened as a PR and
           verified. You MAY route safe bumps to the work tickets below.
  - false: do NOT write bump tickets -- everything actionable goes to
           the human triage file (no unverifiable PR against a no-CI repo).

Steps:
  1. Read AUDIT_SUMMARY.txt, then each file marked "findings". Ignore
     "clean". The harness already handles "skipped"/"error" tools --
     don't report those.
  2. Sort each real finding into a lane:
       SECURITY  -- a CVE/advisory WITH a clean fix (a patch/minor bump,
                    no code change). Reachability matters: govulncheck
                    only flags called vulns; for others, judge whether
                    the vulnerable path is actually used.
       DRIFT     -- an outdated dependency that is a patch/minor bump.
       JUDGMENT  -- anything that is NOT a clean mechanical bump: major
                    versions, fixes needing a major bump or code change,
                    vulns you judge unreachable, or anything uncertain.
  3. Write these files (OMIT a file entirely when its lane is empty):
       .agent/AGENT_MAINTENANCE_SECURITY.md   (only if VALIDATED=true)
         A short work ticket -- "Apply these security fixes and open a
         PR." Per item: package, current -> target, advisory id, one
         line on why it is safe. Tell the worker: update lockfiles, run
         the test suite, keep the diff minimal, no unrelated changes.
       .agent/AGENT_MAINTENANCE_BUMPS.md      (only if VALIDATED=true)
         Same work-ticket shape, grouping the routine patch/minor DRIFT
         bumps into one ticket. Same worker instructions.
       .agent/AGENT_MAINTENANCE_FINDINGS.md
         The triage report: JUDGMENT items, plus -- when VALIDATED=false --
         everything actionable. Lead with what matters, bury noise. Be
         specific enough to act on (a validated repo's triage is worked by
         the agent; an unvalidated one's is read by a human).
       .agent/AGENT_MAINTENANCE_FINDINGS_KEYS   (write WHENEVER you write FINDINGS.md)
         One STABLE dedup key per JUDGMENT finding in FINDINGS.md, one per
         line: the advisory ID (CVE-..., GHSA-..., RUSTSEC-..., PYSEC-...,
         GO-...) when it has one; else the bare package name; append
         "@<major>" ONLY when the finding is specifically about moving to a
         new MAJOR version. Lowercase, nothing else -- no prose, severity,
         dates, or patch/minor versions. The SAME findings MUST yield the
         SAME keys every run: this is what lets a dismissed finding-set stay
         dismissed instead of being re-filed every week.
       .agent/AGENT_MAINTENANCE_PRIORITY
         One word -- critical | high | medium | low -- severity of the
         most serious finding overall:
           critical: actively-exploited vulns, leaked secrets in deps
           high:     reachable/unfixed CVEs, moderate severity or worse
           medium:   outdated-but-functional, low-severity advisories
           low:      minor version bumps, nice-to-haves

If nothing is real after you look (all noise), write nothing.
EOF
)

  # Maintenance triage is classification work, not agent work: no voice
  # anchor, no AGENTS.md -- the user message is self-contained. Claude
  # Code's built-in system prompt is fine; we don't append our own.
  log "invoking claude for maintenance triage (timeout ${TICK_TIMEOUT})"
  local m_log="$m_worktree/.agent/claude-output.log"
  local m_start; m_start=$(date +%s)
  local m_exit
  set +e
  claude_run_with_cost "maintenance" "$m_log" "$TICK_TIMEOUT" \
    --model "$AGENT_MODEL_REVIEW" \
    --settings "$AGENT_HOME/agent-settings.json" \
    --max-turns 100 \
    --print "$m_user_msg"
  m_exit=$?
  set -e
  log "claude exited $m_exit after $(( $(date +%s) - m_start ))s"

  normalize_worktree_dashes "$m_worktree"

  # Severity label, shared by the security + triage tickets.
  local m_pri_label=""
  local m_priority_file="$m_worktree/.agent/AGENT_MAINTENANCE_PRIORITY"
  if [ -s "$m_priority_file" ]; then
    local m_priority
    m_priority=$(tr -d '[:space:]' < "$m_priority_file" | tr '[:upper:]' '[:lower:]')
    m_pri_label=$(maint_priority_label "$m_priority")
  fi

  # Route the triage output. Each file is optional; each maps to one
  # deduped ticket. SECURITY + BUMPS are Agent-labeled work tickets (only
  # produced for validated repos -> the work flow opens the PR); FINDINGS
  # is the human triage ticket.
  local sec_file="$m_worktree/.agent/AGENT_MAINTENANCE_SECURITY.md"
  local bumps_file="$m_worktree/.agent/AGENT_MAINTENANCE_BUMPS.md"
  local findings_file="$m_worktree/.agent/AGENT_MAINTENANCE_FINDINGS.md"
  local filed=0

  if [ -s "$sec_file" ]; then
    maint_file_deduped_issue "$target" "$MAINT_SECURITY_MARKER" \
      "[deps] security fixes for $target" \
      "$(cat "$sec_file")

$MAINT_SECURITY_MARKER" \
      true "${m_pri_label:-Priority/High}"
    filed=1
  fi
  if [ -s "$bumps_file" ]; then
    maint_file_deduped_issue "$target" "$MAINT_BUMPS_MARKER" \
      "[deps] dependency bumps for $target" \
      "$(cat "$bumps_file")

$MAINT_BUMPS_MARKER" \
      true ""
    filed=1
  fi
  if [ -s "$findings_file" ]; then
    # Re-file-on-close fix: fingerprint the judgment findings so a dismissed
    # (closed) finding-set stays quiet while a genuinely-new one still surfaces.
    # Validated routing: a validated repo can be worked by the grind, so route
    # triage to the agent there (it works-or-judges, the human gates the PR/close);
    # human-only (assigned) when unvalidated, where the grind can't open a
    # CI-verifiable PR.
    local m_fp
    m_fp=$(maint_findings_fingerprint "$m_worktree/.agent/AGENT_MAINTENANCE_FINDINGS_KEYS")
    maint_file_deduped_issue "$target" "$MAINT_TRIAGE_MARKER" \
      "[maintenance] findings needing triage for $target" \
      "$(cat "$findings_file")

$MAINT_TRIAGE_MARKER" \
      "$validated" "$m_pri_label" "$m_fp"
    filed=1
  fi

  if [ "$filed" -eq 0 ]; then
    log "maintenance: claude produced no routable findings for $target -- nothing filed"
  fi

  maintenance_mark_done "$target"
  return 0
}


# -- SEO analysis pass --------------------------------------------
#
# Monthly, GSC-driven (NOT repo-driven and NOT WEBSITE_REPO-gated):
# enumerate Search Console domain properties, analyze ONE per tick,
# email the owner a graded report, and -- for sites listed as agentic
# -- file ONE curated, deduped, Agent-labeled ticket the normal
# discovery/work flow can later pick up. Read-only by itself; the
# eventual fixes flow through the standard issue machinery (gated by
# validation). All analysis is scripted (lib/seo-analysis.sh) -- no
# LLM. See docs/architecture.md.

SEO_TICKET_MARKER="<!-- agent:seo-opportunities -->"

# Comma-separated extra recipients subscribed to this domain, parsed
# from SEO_RECIPIENTS ("email=site1,site2|email2=site3").
seo_extra_recipients_for() {
  local domain="$1" entry email sites out=""
  local IFS='|'
  for entry in ${SEO_RECIPIENTS:-}; do
    [ -z "$entry" ] && continue
    email="${entry%%=*}"
    sites="${entry#*=}"
    case ",$sites," in
      *",$domain,"*) out="${out:+$out,}$email" ;;
    esac
  done
  printf '%s' "$out"
}

# Full recipient list for an SEO domain: PRIMARY always, plus any extras
# subscribed to this domain (PRIMARY gets every domain, so it's always
# copied -- no separate CC needed).
seo_recipients_for() {
  recipients_with_primary "$(seo_extra_recipients_for "$1")"
}

# seo_agentic_repo_for() lives in lib/seo-analysis.sh -- it resolves the agentic
# domain->repo from each repo's agent.json `.seo`.

# File ONE curated SEO ticket per domain, one open at a time. Dedup is
# check-then-act on a per-domain marker: if an OPEN ticket already
# exists we don't refile (so a non-validated agentic repo accrues at
# most one). The Agent label lets discovery pick it up once the repo is
# validated; until then it just waits.
seo_file_ticket() {
  local repo="$1" domain="$2" body_md="$3"
  if ! forgejo_repo_exists "$repo"; then
    log "seo: agentic repo $repo not accessible to bot -- emailed only, no ticket"
    return 0
  fi
  local marker existing
  marker="${SEO_TICKET_MARKER} ${domain}"
  existing=$(forgejo_find_marked_issue "$repo" "$BOT_USER" "$marker" 2>/dev/null) \
    || { log "warning: seo: can't check existing ticket on $repo (API error) -- skipping ticket"; return 0; }
  if [ -n "$existing" ] && [ "$existing" != "null" ] && [ "$existing" != "empty" ] \
     && [ "$(jq -r '.state' <<<"$existing" 2>/dev/null)" = "open" ]; then
    log "seo: $repo already has an open SEO ticket #$(jq -r '.number' <<<"$existing") for $domain -- not refiling"
    return 0
  fi
  local title body num
  title="SEO opportunities: ${domain} ($(date +%Y-%m-%d))"
  body="${body_md}

${marker}"
  num=$(forgejo_open_issue "$repo" "$title" "$body") \
    || { log "warning: seo ticket open failed on $repo (continuing)"; return 0; }
  forgejo_add_label "$repo" "$num" "Agent" 2>/dev/null \
    || log "warning: could not apply 'Agent' label on $repo#$num"
  log "seo: filed ticket #$num on $repo for $domain"
}

# One monthly SEO pass over a single eligible domain. Returns 0 if a
# domain was processed (caller exits the tick), 1 if the subsystem is
# unconfigured or nothing was eligible (caller falls through).
do_seo_tick() {
  # Opt-in gate: every required credential must be present.
  if [ -z "${GOOGLE_SERVICE_ACCOUNT:-}" ] || [ -z "${SMTP2GO_API_KEY:-}" ] \
     || [ -z "${SMTP2GO_SENDER:-}" ] || [ -z "${PRIMARY_RECIPIENTS:-}" ]; then
    return 1
  fi

  local token
  token=$(gsc_access_token) || { log "seo: GSC service-account token mint failed -- skipping this tick"; return 1; }

  # SEO_DEBUG_DOMAIN restricts the pass to a single domain for isolated
  # testing before the full sweep. Everything else is identical to a
  # normal day -- same monthly gate, same email/ticket/record path -- so a
  # debug run still stamps the domain done. To re-run, clear its stamp
  # under .seo in discretionary-state.json. Bare domain, e.g.
  # "joshtronic.com".
  local domains target="" d
  if [ -n "${SEO_DEBUG_DOMAIN:-}" ]; then
    domains="$SEO_DEBUG_DOMAIN"
    log "seo: DEBUG mode -- restricted to ${SEO_DEBUG_DOMAIN} (unset SEO_DEBUG_DOMAIN for the full sweep)"
  else
    domains=$(gsc_list_domains "$token" || true)
    if [ -z "$domains" ]; then
      log "seo: no sc-domain properties visible to this account -- nothing to do"
      return 1
    fi
  fi
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    if seo_eligible "$d"; then target="$d"; break; fi
  done <<<"$domains"
  if [ -z "$target" ]; then
    log "seo: all domains analyzed this month -- continuing"
    return 1
  fi

  log "seo: analyzing $target"
  local start end pstart pend
  read -r start end pstart pend <<<"$(seo_window)"

  local cur_qp cur_page prev_page cur_query prev_query
  cur_qp=$(gsc_query "$token" "$target" "$start" "$end" "query,page")    || cur_qp='{"rows":[]}'
  cur_page=$(gsc_query "$token" "$target" "$start" "$end" "page")        || cur_page='{"rows":[]}'
  prev_page=$(gsc_query "$token" "$target" "$pstart" "$pend" "page")     || prev_page='{"rows":[]}'
  cur_query=$(gsc_query "$token" "$target" "$start" "$end" "query")      || cur_query='{"rows":[]}'
  prev_query=$(gsc_query "$token" "$target" "$pstart" "$pend" "query")   || prev_query='{"rows":[]}'

  local report count grade upside
  report=$(seo_build_report "$target" "$cur_qp" "$cur_page" "$prev_page" \
             "$cur_query" "$prev_query" "$start" "$end" "$pstart" "$pend")
  count=$(jq -r '.count // 0' <<<"$report" 2>/dev/null || echo 0)
  grade=$(jq -r '.grade // "INDIFFERENT"' <<<"$report" 2>/dev/null || echo INDIFFERENT)
  upside=$(jq -r '.total_upside // 0' <<<"$report" 2>/dev/null || echo 0)

  if [ "${count:-0}" -eq 0 ]; then
    log "seo: $target -- nothing above the impression floor this month (no email/ticket)"
    seo_mark_done "$target"
    return 0
  fi

  # Record baselines for future Layer-2 outcome grading (append-only).
  local period agentic_repo agentic_bool=false
  period=$(seo_period)
  agentic_repo=$(seo_agentic_repo_for "$target")
  [ -n "$agentic_repo" ] && agentic_bool=true
  seo_record_opportunities "$report" "$agentic_bool" "$period"

  # GA is additive and optional: no matching property (or a fetch
  # failure) leaves report.ga at its "null" default, and both renderers
  # fall back to GSC-only output, unchanged.
  local ga_property ga_report ga_metrics
  ga_property=$(ga_property_for_domain "$target") || ga_property=""
  if [ -n "$ga_property" ]; then
    ga_report=$(ga_run_report "$ga_property" "$start" "$end" "" \
                  "sessions,engagedSessions,engagementRate,totalUsers,keyEvents") \
      || ga_report='{"rows":[]}'
    ga_metrics=$(seo_ga_metrics "$ga_report")
    report=$(jq --argjson ga "$ga_metrics" '.ga = $ga' <<<"$report")
  fi

  # Render once, reuse for email (text+html) and ticket (markdown).
  local md html recipients subject
  md=$(seo_render_markdown <<<"$report")
  html=$(seo_render_html <<<"$report")
  recipients=$(seo_recipients_for "$target")
  subject="[SEO] ${target} -- ${grade} (${count} opportunities, ~${upside} est. clicks)"
  if email_send "$subject" "$html" "$md" "$recipients"; then
    log "seo: emailed $target report ($grade, $count opps) to $recipients"
  else
    log "warning: seo email for $target failed (continuing)"
  fi

  # Agentic sites also get the curated ticket.
  if [ -n "$agentic_repo" ]; then
    seo_file_ticket "$agentic_repo" "$target" "$md"
  fi

  seo_mark_done "$target"
  return 0
}

# -- Daily fleet ship-report (opt-in) -----------------------------
#
# The safety valve for shadow-review auto-merge: once the human is out of the
# per-PR gate, this once-a-day email is how they stay in control by exception --
# what shipped (tagged shadow vs human), what still needs them, what's in flight.
# FULLY SCRIPTED (no model), so it sits ABOVE the health gate and sends even
# during a Claude cooldown. Daily stamp under .shipreport; clear it to resend.
# Assembly/render/stamp live in lib/ship-report.sh; the Forgejo gathering is
# here, like do_seo_tick's.
do_shipreport_tick() {
  # Opt-in gate: same email creds as the other digests.
  if [ -z "${PRIMARY_RECIPIENTS:-}" ] || [ -z "${SMTP2GO_API_KEY:-}" ] \
     || [ -z "${SMTP2GO_SENDER:-}" ]; then
    return 1
  fi
  # Morning send: yesterday's 24h window is complete. 10#: %H must not parse octal.
  local hour; hour=$((10#$(date +%H)))
  if [ "$hour" -lt 7 ]; then
    return 1
  fi
  if shipreport_sent_today; then
    return 1
  fi
  [ -n "${ANALYSIS_REPOS_JSON:-}" ] || return 1

  local since; since=$(date -u -d "-1 days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
                        || date -u -v-1d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
  local items='[]' line repo reqh merged open
  while IFS= read -r line; do
    repo=$(jq -r '.full_name // empty' <<<"$line" 2>/dev/null); [ -n "$repo" ] || continue
    # Read the carve-out flag directly (no dependency on the auto-merge module).
    reqh=$(forgejo_repo_get_file "$repo" "${AGENT_CONFIG_FILE:-agent.json}" 2>/dev/null \
            | jq -r '.automerge.require_human // false' 2>/dev/null)
    [ "$reqh" = "true" ] || reqh=false
    merged=$(_fj GET "/repos/${repo}/pulls?state=closed&sort=recentupdate&limit=30" 2>/dev/null \
      | jq -c --arg u "$BOT_USER" --arg since "$since" --arg repo "$repo" --argjson rh "$reqh" '
          [ .[]? | select(.user.login == $u)
            | select((.merged_at // "") != "" and .merged_at >= $since)
            | {repo:$repo, number, title, url:.html_url, state:"merged",
               gate:(if $rh then "human" else "shadow" end), require_human:$rh} ]' 2>/dev/null) \
      || merged='[]'
    open=$(_fj GET "/repos/${repo}/pulls?state=open&sort=oldest&limit=30" 2>/dev/null \
      | jq -c --arg u "$BOT_USER" --arg repo "$repo" --argjson rh "$reqh" '
          [ .[]? | select(.user.login == $u)
            | {repo:$repo, number, title, url:.html_url, state:"open", gate:"", require_human:$rh} ]' 2>/dev/null) \
      || open='[]'
    items=$(jq -c --argjson m "${merged:-[]}" --argjson o "${open:-[]}" '. + $m + $o' <<<"$items" 2>/dev/null || printf '%s' "$items")
  done <<<"$ANALYSIS_REPOS_JSON"

  local report; report=$(printf '%s' "$items" | shipreport_build)
  if shipreport_is_empty "$report"; then
    log "shipreport: quiet 24h -- nothing to report (stamping done)"
    shipreport_mark_sent
    return 0
  fi

  local ns nsh nif html text subject recipients
  ns=$(jq -r '.needs_you | length' <<<"$report")
  nsh=$(jq -r '.shipped | length' <<<"$report")
  nif=$(jq -r '.inflight | length' <<<"$report")
  html=$(shipreport_render_html <<<"$report")
  text=$(shipreport_render_text <<<"$report")
  subject="[Ship Report] $(date +%F) -- ${nsh} shipped, ${ns} need you, ${nif} in flight"
  recipients=$(recipients_with_primary "${SHIPREPORT_RECIPIENTS:-}")
  if email_send "$subject" "$html" "$text" "$recipients"; then
    log "shipreport: sent (${nsh} shipped, ${ns} needs-you, ${nif} in-flight) to $recipients"
  else
    log "warning: shipreport email failed (continuing)"
  fi
  shipreport_mark_sent
  return 0
}

# -- Sports digest (daily, opt-in) --------------------------------
#
# The ELI5 sports-tutor email: harness-side ESPN fetch (lib/espn.sh),
# ONE claude_call distill on AGENT_MODEL, email via SMTP2GO. Email-only
# and not repo-driven, like the SEO pass -- but unlike SEO it USES the
# model, so it lives below the global health gate (a blocked tick
# skips it) and is the reason it can't join the SEO blocked-tick
# carve-out.
#
# Fires on the first tick after 03:00 -- a window-completeness gate
# like logwatch's, not a send-hour: the digest covers YESTERDAY, and
# west-coast NBA/NHL games routinely end past midnight CT. By 03:00
# every previous-day event is final and recapped. Runs 7 days a week.
#
# Retry semantics (.sports = {date, sent, failures, last_attempt}):
# sent flips only on a successful send, attempts are spaced by
# SPORTS_RETRY_COOLDOWN_SECS, and a hardcoded 5-hard-failure cap
# abandons the day. There is deliberately no clear-on-good-fetch:
# ESPN being up says nothing about the distill call, and clearing
# would let a parse-flaky day burn unbounded model calls -- the cap
# must count every hard failure.
#
# The taught-concepts curriculum ledger (what makes the digest a
# course, not a loop) is appended only after a successful send and
# lives in its own file -- see lib/sports-digest.sh.
#
# Returns 0 if a digest was sent (caller exits the tick), 1 otherwise
# (caller falls through).
do_sports_tick() {
  # Opt-in gate: every required config must be present.
  if [ -z "${PRIMARY_RECIPIENTS:-}" ] || [ -z "${SPORTS_LEAGUES:-}" ] \
     || [ -z "${SMTP2GO_API_KEY:-}" ] || [ -z "${SMTP2GO_SENDER:-}" ]; then
    return 1
  fi

  # Window-completeness gate. 10#: zero-padded %H must not parse as octal.
  local hour; hour=$((10#$(date +%H)))
  if [ "$hour" -lt 3 ]; then
    log "sports: yesterday's late games may not be final/recapped yet -- holding until 03:00"
    return 1
  fi

  if sports_sent_today; then
    log "sports: digest already sent today -- continuing"
    return 1
  fi

  # Failure budget (hardcoded, not an env knob -- keep the .env surface
  # small). Checked before the cooldown so an abandoned day stops cheaply.
  local max_failures=5 failures
  failures=$(sports_failures)
  if [ "$failures" -ge "$max_failures" ]; then
    log "sports: abandoned for the day (${failures}/${max_failures} hard failures; clear .sports in discretionary-state.json to retry) -- continuing"
    return 1
  fi

  if ! sports_retry_ready; then
    log "sports: not sent yet today, waiting out the retry cooldown -- continuing"
    return 1
  fi
  sports_mark_attempt  # start the cooldown clock for this attempt

  # Yesterday, both shapes (dashed for humans/prompt, compact for ESPN).
  # Portable across GNU (Linux server) and BSD (macOS dev) date.
  local ydash ycompact
  ydash=$(date -d "-1 days" +%F 2>/dev/null || date -v-1d +%F 2>/dev/null)
  ycompact=${ydash//-/}

  # Fetch + slim every configured league -- ESPN is free, and the
  # PROMPT curates by significance, so a quiet league rides along at
  # no cost. fetched_ok distinguishes "quiet day" from "ESPN/network
  # down": only a day where at least one endpoint answered may be
  # skipped as genuinely quiet.
  log "sports: fetching ESPN payloads for ${ycompact}"
  local payload='[]' entry sb nw slim fetched_ok=0
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    sb=$(espn_scoreboard "$entry" "$ycompact") && fetched_ok=1 || sb='{"events":[]}'
    nw=$(espn_news "$entry") && fetched_ok=1 || nw='{"articles":[]}'
    slim=$(espn_slim_league "$entry" "$sb" "$nw")
    payload=$(jq -c --argjson item "$slim" '. + [$item]' <<<"$payload")
  done < <(tr ',' '\n' <<<"$SPORTS_LEAGUES" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

  if [ "$fetched_ok" -eq 0 ]; then
    failures=$(sports_failure_inc)
    log "sports: every ESPN fetch failed -- not sending (failure ${failures}/${max_failures}, retry after cooldown)"
    return 1
  fi

  local items
  items=$(jq '[.[] | (.events | length) + (.headlines | length)] | add // 0' <<<"$payload")
  if [ "${items:-0}" -eq 0 ]; then
    # ESPN answered and there is genuinely nothing -- a quiet day, not
    # a failure. Don't email an empty digest; close the day.
    log "sports: no events or headlines across all leagues -- quiet day, no digest"
    sports_mark_sent
    return 1
  fi

  # One distill call; the label-line + sentinel response is parsed
  # harness-side (sports_parse_response), never model-written JSON.
  # strip_fences=0: the body is markdown prose, not a JSON envelope.
  #
  # max_tokens 16000: the digest is a long-output call (a busy day
  # runs 2-3k visible tokens) and on the CLI thinking shares the
  # output budget. A starved cap doesn't fail loudly -- the visible
  # text gets cut mid-stream and the envelope's result keeps only the
  # final segment, which surfaces here as an "unparseable" response
  # whose head starts mid-sentence with no CONCEPTS/sentinel. Thinking
  # length varies run to run, which is exactly the flaky-parse shape.
  #
  # timeout 600s (SPORTS_CALL_TIMEOUT_SECS): busy-day payloads -- a
  # full MLB slate plus concurrent playoff series (NHL/NBA/CWS in June)
  # push thinking tokens high enough to timeout at the 300s default.
  # espn_slim_league already caps events at 10 and headlines at 8, but
  # 12 leagues * 10 events is still a large input. 600s gives the model
  # room to finish without compromising the 900s retry cooldown.
  local covered prompt directive raw parsed attempt snippet tail_snip
  covered=$(sports_concepts_load)
  prompt=$(sports_build_prompt "$payload" "$covered" "$ydash")
  directive=$(cat "$AGENT_HOME/bin/lib/sports-digest-directive.md")
  parsed=""
  for attempt in 1 2; do
    raw=$(claude_call "$AGENT_MODEL" "sports-digest" 16000 "$directive" "$prompt" 0 "${SPORTS_CALL_TIMEOUT_SECS:-600}") || {
      log "sports: distill call failed (attempt $attempt)"
      continue
    }
    if parsed=$(sports_parse_response "$raw"); then
      break
    fi
    parsed=""
    # Say WHY it didn't parse: the head/tail of the response make
    # "model skipped the sentinel" vs "output truncated" legible from
    # the journal alone.
    snippet=$(printf '%s' "$raw" | tr '\n' ' ')
    tail_snip=""
    [ "${#snippet}" -gt 160 ] && tail_snip=${snippet:$(( ${#snippet} - 160 ))}
    log "sports: unparseable distill response (attempt $attempt, ${#raw} chars; head: ${snippet:0:160} [...] tail: ${tail_snip})"
  done
  if [ -z "$parsed" ]; then
    failures=$(sports_failure_inc)
    log "sports: no parseable digest after 2 attempts (failure ${failures}/${max_failures}, retry after cooldown)"
    return 1
  fi

  # Subject carries TODAY's date: it's today's digest of yesterday's
  # action, and the body already frames the content as yesterday's
  # highlights.
  local body concepts html subject today formatted
  body=$(jq -r '.body' <<<"$parsed")
  concepts=$(jq -c '.concepts' <<<"$parsed")
  html=$(sports_render_html <<<"$body")
  today=$(date +%Y-%m-%d)
  formatted=$(format_report_date "$today")
  subject="[Sports] ${formatted:-$today}"
  local recipients; recipients=$(recipients_with_primary "${SPORTS_RECIPIENTS:-}")
  if email_send "$subject" "$html" "$body" "$recipients"; then
    sports_mark_sent
    sports_concepts_append "$concepts" "$(date +%Y-%m-%d)" \
      || log "warning: sports: curriculum ledger update failed (digest sent fine)"
    log "sports: emailed digest for ${ydash} ($(jq 'length' <<<"$concepts") new concepts) to $recipients"
    return 0
  fi
  failures=$(sports_failure_inc)
  if [ "$failures" -ge "$max_failures" ]; then
    log "sports: ${max_failures} consecutive failures today -- abandoning the digest for the day"
  else
    log "warning: sports email failed (failure ${failures}/${max_failures}) -- will retry after cooldown"
  fi
  return 1
}

# -- CEO weekly board digest (weekly, per-repo, convention opt-in) ------
#
# For each analysis-set repo carrying a CEO.md mandate -- the
# mandate's mere presence IS the opt-in, like logwatch's systemd/ dir --
# once per ISO week: read the mandate + gather the week's activity, one
# claude_call writes the board digest, emailed to PRIMARY_RECIPIENTS plus
# any CEO_RECIPIENTS extras. Phase 1 is strictly read-only -- no issue-
# filing/steering yet, per the mandate's "start tight, loosen as trust
# earns it" rope.
#
# One repo per tick (return 0 exits the cascade), so several managed repos
# digest over successive ticks; per-repo weekly stamp under .ceo. Uses
# claude_call, so it's already below the tick's health gate. Returns 0 if a
# digest was sent, 1 otherwise.
# _ceo_file_outputs <repo> <parsed-json> <allow_questions:yes|no>
# Shared by both do_ceo_tick paths: file the parsed proposals (and, when allowed,
# the board questions) up to the CEO_MAX_OPEN open-item cap, then open the
# decision-guidance redline PR if one was distilled. The cap (Phase 4) replaces
# the old "no new work until zero open" throttle so the CEO can actually grind.
_ceo_file_outputs() {
  local repo="$1" parsed="$2" allow_questions="${3:-yes}"
  [ -n "${FORGEJO_REVIEWER:-}" ] || return 0

  local proposals nprop prop ptitle pbody filed open_items
  proposals=$(jq -c '.issues // []' <<<"$parsed")
  nprop=$(jq 'length' <<<"$proposals" 2>/dev/null || echo 0)
  if [ "${nprop:-0}" -gt 0 ]; then
    filed=0
    while IFS= read -r prop; do
      open_items=$(ceo_open_items_count "$repo")
      if [ "${open_items:-0}" -ge "$CEO_MAX_OPEN" ]; then
        log "ceo: open-item cap (${CEO_MAX_OPEN}) reached on ${repo} -- holding remaining proposals"
        break
      fi
      ptitle=$(jq -r '.title' <<<"$prop"); pbody=$(jq -r '.body' <<<"$prop")
      # Code-check gate: vet against the real code; DROP already-done work (the
      # reason is logged locally inside the gate, never posted). Fail-open = KEEP.
      if [ "$(ceo_codecheck_proposal "$repo" "$ptitle" "$pbody")" = "DROP" ]; then
        continue
      fi
      if ceo_file_proposal "$repo" "$ptitle" "$pbody" "$FORGEJO_REVIEWER"; then
        filed=$((filed + 1))
      else
        log "warning: ceo: failed to file a proposal on ${repo}"
      fi
    done < <(jq -c '.[]' <<<"$proposals")
    [ "$filed" -gt 0 ] && log "ceo: filed ${filed} proposal(s) on ${repo} for ${FORGEJO_REVIEWER} to greenlight"
  fi

  if [ "$allow_questions" = "yes" ]; then
    local questions nq q qtitle qbody qfiled
    questions=$(jq -c '.questions // []' <<<"$parsed")
    nq=$(jq 'length' <<<"$questions" 2>/dev/null || echo 0)
    if [ "${nq:-0}" -gt 0 ]; then
      qfiled=0
      while IFS= read -r q; do
        open_items=$(ceo_open_items_count "$repo")
        if [ "${open_items:-0}" -ge "$CEO_MAX_OPEN" ]; then
          log "ceo: open-item cap (${CEO_MAX_OPEN}) reached on ${repo} -- holding remaining questions"
          break
        fi
        qtitle=$(jq -r '.title' <<<"$q"); qbody=$(jq -r '.body' <<<"$q")
        if ceo_file_question "$repo" "$qtitle" "$qbody" "$FORGEJO_REVIEWER"; then
          qfiled=$((qfiled + 1))
        else
          log "warning: ceo: failed to file a board question on ${repo}"
        fi
      done < <(jq -c '.[]' <<<"$questions")
      [ "$qfiled" -gt 0 ] && log "ceo: asked ${qfiled} board question(s) on ${repo} for ${FORGEJO_REVIEWER}"
    fi
  fi

  local guidance
  guidance=$(jq -r '.guidance // ""' <<<"$parsed")
  if [ -n "$guidance" ]; then
    if ceo_guidance_pr_open "$repo"; then
      log "ceo: held a guidance redline for ${repo} -- one already open"
    elif ceo_open_guidance_pr "$repo" "$guidance" "$FORGEJO_REVIEWER"; then
      log "ceo: opened a decision-guidance redline PR on ${repo} for ${FORGEJO_REVIEWER}"
    else
      log "warning: ceo: failed to open the guidance redline on ${repo}"
    fi
  fi
  return 0
}

do_ceo_tick() {
  # The weekly digest is now a respondable Forgejo issue, not email -- no SMTP2GO
  # gate; opt-in is purely the CEO.md mandate (read per-repo below).
  local since directive repo_line repo mandate activity prompt raw parsed subject body attempt pdnum
  local answered qblock n closed
  since=$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)
  directive=$(cat "$AGENT_HOME/bin/lib/ceo-digest-directive.md")

  while IFS= read -r repo_line; do
    [ -n "$repo_line" ] || continue
    repo=$(jq -r '.full_name' <<<"$repo_line" 2>/dev/null)
    [ -n "$repo" ] || continue

    # Convention opt-in: the CEO.md mandate's mere presence. Reading it and
    # testing non-empty IS the opt-in gate -- one GET, no separate probe. Both
    # paths below need the mandate, so it's read before either.
    mandate=$(ceo_read_mandate "$repo")
    [ -n "$mandate" ] || continue

    # --- Path 1 (Phase 4): act on ANSWERED questions -- EVERY tick, not
    # week-gated. The board answered in a comment and unassigned themselves;
    # turn each decision into the work it implies, then close the question.
    if [ -n "${FORGEJO_REVIEWER:-}" ]; then
      answered=$(ceo_answered_question_numbers "$repo" "$FORGEJO_REVIEWER")
      if [ -n "$answered" ]; then
        qblock=$(ceo_open_questions "$repo" "$FORGEJO_REVIEWER")
        prompt=$(ceo_build_answer_prompt "$repo" "$mandate" "$qblock")
        parsed=""
        for attempt in 1 2; do
          raw=$(claude_call "$AGENT_MODEL" "ceo-answer" 8000 "$directive" "$prompt" 0) \
            || { log "ceo: answer call failed for ${repo} (attempt ${attempt})"; continue; }
          if parsed=$(ceo_parse_response "$raw"); then break; fi
          parsed=""
        done
        if [ -n "$parsed" ]; then
          _ceo_file_outputs "$repo" "$parsed" "no"   # act path never asks NEW questions
        else
          log "ceo: unparseable answer-action for ${repo} -- closing answered questions anyway"
        fi
        # Input incorporated -- close the answered questions so they don't re-fire.
        closed=0
        while IFS= read -r n; do
          [ -n "$n" ] || continue
          _fj PATCH "/repos/${repo}/issues/${n}" '{"state":"closed"}' >/dev/null 2>&1 \
            && closed=$((closed + 1))
        done <<<"$answered"
        log "ceo: acted on ${closed} answered board question(s) on ${repo}"
        return 0   # one model-backed piece of work per tick
      fi

      # --- Path 1b (Phase 4 follow-up): reconsider a PROPOSAL the board commented
      # on + handed back (unassigned, NOT Agent-labeled). Read the feedback and
      # WITHDRAW / REVISE / HOLD -- distinct from doing the work (the Agent-label path).
      local responded rnum rparsed rdecision rreply rissue
      responded=$(ceo_responded_proposal_numbers "$repo" "$FORGEJO_REVIEWER")
      if [ -n "$responded" ]; then
        rnum=$(printf '%s\n' "$responded" | head -1)   # one per tick
        prompt=$(ceo_build_reconsider_prompt "$repo" "$mandate" "$(ceo_proposal_thread "$repo" "$rnum")")
        rparsed=""
        for attempt in 1 2; do
          raw=$(claude_call "$AGENT_MODEL" "ceo-reconsider" 8000 \
            "You are the CEO reconsidering your own proposal after the board handed it back. Be a real partner -- concede when they are right, argue back with reasons when you are not. Conversational, in your own voice. Follow the output format in the prompt exactly." \
            "$prompt" 0) \
            || { log "ceo: reconsider call failed for ${repo}#${rnum} (attempt ${attempt})"; continue; }
          if rparsed=$(ceo_parse_reconsider "$raw"); then break; fi
          rparsed=""
        done
        if [ -z "$rparsed" ]; then
          # Re-assign so it leaves the responded-set (no per-tick reconsider loop)
          # and lands back in the reviewer's queue.
          forgejo_assign "$repo" "$rnum" "$FORGEJO_REVIEWER" 2>/dev/null || true
          log "ceo: unparseable reconsider for ${repo}#${rnum} -- handed back to the reviewer"
          return 0
        fi
        rdecision=$(jq -r '.decision' <<<"$rparsed")
        rreply=$(jq -r '.reply' <<<"$rparsed")
        _fj POST "/repos/${repo}/issues/${rnum}/comments" \
          "$(jq -n --arg b "$rreply" '{body:$b}')" >/dev/null 2>&1 || true
        case "$rdecision" in
          WITHDRAW)
            _fj PATCH "/repos/${repo}/issues/${rnum}" '{"state":"closed"}' >/dev/null 2>&1 || true
            log "ceo: withdrew proposal ${repo}#${rnum} after board feedback" ;;
          REVISE)
            _fj PATCH "/repos/${repo}/issues/${rnum}" '{"state":"closed"}' >/dev/null 2>&1 || true
            rissue=$(jq -c '.issue // empty' <<<"$rparsed")
            if [ -n "$rissue" ] && [ "$rissue" != "null" ] \
               && [ "$(ceo_open_items_count "$repo")" -lt "$CEO_MAX_OPEN" ]; then
              if ceo_revise_refile "$repo" "$rnum" "$rissue" "$FORGEJO_REVIEWER"; then
                log "ceo: revised + re-filed proposal (was ${repo}#${rnum})"
              else
                log "ceo: REVISE on ${repo}#${rnum} -- code-check dropped revised proposal"
              fi
            else
              log "ceo: REVISE on ${repo}#${rnum} -- closed the old; no re-file (no issue block or cap reached)"
            fi ;;
          *)
            # HOLD: made the case, hand the call back to the board. Re-assigning
            # also drops it out of the responded-set so it can't reconsider-loop;
            # a fresh comment + unassign from the board re-opens the dialogue.
            forgejo_assign "$repo" "$rnum" "$FORGEJO_REVIEWER" 2>/dev/null || true
            log "ceo: holding proposal ${repo}#${rnum} -- replied + handed back to the board" ;;
        esac
        return 0   # one model-backed action per tick
      fi
    fi

    # --- Path 2: the weekly board digest (once per ISO week). ---
    ceo_week_done "$repo" && continue
    # The activity opens with live metrics, the week, the CEO's OPEN questions (so it
    # won't re-ask a pending one), and last week's digest + the board's comments so the
    # brief incorporates their steering. One open digest at a time.
    pdnum=$(ceo_prior_digest_number "$repo")
    activity=$(ceo_read_gsc "$repo"; ceo_read_ga "$repo"; ceo_read_metrics "$repo"; \
               ceo_gather_week "$repo" "$since"; \
               ceo_proposal_outcomes "$repo"; \
               ceo_open_questions "$repo" "${FORGEJO_REVIEWER:-}"; \
               ceo_prior_digest_steering "$repo")
    prompt=$(ceo_build_prompt "$repo" "$mandate" "$activity" "$since")

    parsed=""
    for attempt in 1 2; do
      raw=$(claude_call "$AGENT_MODEL" "ceo-digest" 8000 "$directive" "$prompt" 0) || {
        log "ceo: digest call failed for ${repo} (attempt ${attempt})"; continue; }
      if parsed=$(ceo_parse_response "$raw"); then break; fi
      log "ceo: unparseable digest for ${repo} (attempt ${attempt})"
      parsed=""
    done
    [ -n "$parsed" ] || { log "ceo: no usable digest for ${repo} this tick"; continue; }

    subject=$(jq -r '.subject // ""' <<<"$parsed")
    [ -n "$subject" ] && subject="[CEO] ${subject}" || subject="[CEO] ${repo} -- weekly board digest"
    body=$(jq -r '.body' <<<"$parsed")
    if ceo_file_digest "$repo" "$subject" "$body" "${FORGEJO_REVIEWER:-}"; then
      ceo_mark_week_done "$repo"
      # One open digest at a time: close last week's now its steering is incorporated.
      [ -n "$pdnum" ] && _fj PATCH "/repos/${repo}/issues/${pdnum}" '{"state":"closed"}' >/dev/null 2>&1
      log "ceo: filed weekly board digest issue for ${repo} (closed prior #${pdnum:-none})"
      _ceo_file_outputs "$repo" "$parsed" "yes"   # proposals + questions + guidance
      return 0
    fi
    log "warning: ceo: could not file the digest issue for ${repo} -- will retry next tick"
  done <<<"$ANALYSIS_REPOS_JSON"

  return 1
}

# -- Claude auth/usage health canary -----------------------------
#
# Every model call now bills the operator's Claude subscription; if
# the login drops or the usage window is exhausted, every model
# surface goes dark at once. The claude_health_* state helpers live
# in lib/claude.sh (both runners record ok/auth/limit outcomes on
# every organic call); this tick-side canary adds the two pieces
# that need the tick's context:
#
#   1. Daily probe: one tiny no-tools completion on the first tick
#      after midnight, so a broken login is noticed even on a day
#      with no organic model calls -- and noticed BEFORE the nightly
#      batch (reading/post slots) rather than by it.
#   2. Once-daily alert email while a failure is live. Routed to
#      HEALTH_RECIPIENTS via the shared SMTP2GO creds; without
#      either, log-only. One email per local day, re-armed only
#      after a day rollover (at-most-once-daily).
#
# Runs every tick, before the backoff gate, so a blocked day still
# probes (the inner claude_call fast-skips while blocked) and still
# emails.
do_health_tick() {
  local f today
  f=$(claude_health_state_file)
  today=$(date +%Y-%m-%d)

  # Daily probe. Stamped attempted up front regardless of outcome --
  # organic calls keep recording health the rest of the day, so a
  # failed probe must not retry every tick.
  local probed tmp probe_out
  probed=$(jq -r '.health.probed_on // ""' "$f" 2>/dev/null || echo "")
  if [ "$probed" != "$today" ]; then
    [ -f "$f" ] || echo '{}' > "$f"
    tmp=$(mktemp)
    jq --arg d "$today" '.health = ((.health // {}) + {probed_on: $d})' \
      "$f" > "$tmp" && mv "$tmp" "$f"
    # On failure claude_call's diagnostics land on stdout -- captured
    # here so the journal shows WHY (auth/limit failures also start
    # the backoff via the health state).
    if probe_out=$(claude_call "$AGENT_MODEL" "health-probe" 32 \
        "You are a liveness probe for an unattended agent. Reply with exactly: ok" \
        "ping"); then
      log "health: daily probe ok"
    else
      log "health: daily probe FAILED${probe_out:+ -- $probe_out}"
    fi
  fi

  # Once-daily alert while a failure is live.
  local first kind detail emailed since subject body
  first=$(jq -r '.health.first_failure // 0' "$f" 2>/dev/null || echo 0)
  [ -n "$first" ] && [ "$first" != "null" ] && [ "$first" -gt 0 ] 2>/dev/null || return 0
  emailed=$(jq -r '.health.emailed_on // ""' "$f" 2>/dev/null || echo "")
  if [ "$emailed" = "$today" ]; then return 0; fi
  kind=$(jq -r '.health.kind // "unknown"' "$f" 2>/dev/null)
  detail=$(jq -r '.health.detail // ""' "$f" 2>/dev/null)
  since=$(date -d "@$first" +'%Y-%m-%d %H:%M %Z' 2>/dev/null || echo "$first")

  local recipients; recipients=$(recipients_with_primary "${HEALTH_RECIPIENTS:-}")
  if [ -z "$recipients" ] || [ -z "$SMTP2GO_API_KEY" ] || [ -z "$SMTP2GO_SENDER" ]; then
    log "health: $kind failure live since $since but alert email not configured (PRIMARY_RECIPIENTS + SMTP2GO) -- log-only"
    return 0
  fi

  subject="[Agent] Claude ${kind} problem on $(hostname -s 2>/dev/null || echo agent)"
  body="The agent's Claude CLI calls are failing.

Kind:   ${kind} (auth = login/token problem, limit = subscription usage window exhausted)
Since:  ${since}
Detail: ${detail:-n/a}

Model work (issues, PR review, pipelines, security gate) is paused on
a backoff and re-tests automatically; scripted reports still run.
If kind is auth: re-login on the host (claude auth login, or mint a
fresh setup-token). If kind is limit: it clears when the usage window
resets, or enable/raise extra usage on the plan.

This alert is sent at most once per day; the agent recovers on its
own once calls succeed again."
  if email_send "$subject" "<pre>${body}</pre>" "$body" "$recipients"; then
    tmp=$(mktemp)
    jq --arg d "$today" '.health = ((.health // {}) + {emailed_on: $d})' \
      "$f" > "$tmp" && mv "$tmp" "$f"
    log "health: $kind alert emailed to $recipients"
  else
    log "warning: health alert email failed -- will retry next tick"
  fi
  return 0
}

# -- Logwatch: daily review of repo-declared service journals ----
#
# Convention-driven, no env knob: a repo that ships systemd units in
# a root-level systemd/ directory has declared "I run as a service
# somewhere". Once a day, after the midnight batch hour has closed,
# the pass sweeps every bot-accessible repo for systemd/*.service,
# reads each unit's LOCAL user journal for the 00:00-01:00 window
# (most jobs, the harness included, run in the first hour), and has
# a one-shot review-tier model call hunt for HARD failures. The
# harness itself is discovered the same way -- this repo declares
# systemd/agent.service -- it just carries an extra known-benign
# context blurb (keyed off the unit name, not the repo).
#
# No canary semantics: a declared unit with an empty journal here is
# a unit that runs on some other host (or didn't run) -- log one line
# and move on. No news is good news; uptime is not this pass's job.
#
# The reviewer's contract is failure-SMELL, not log narration: a
# retry that then succeeded is the system working; an empty findings
# list is the expected common case. Open issue titles and recent
# commit subjects on the owning repo ride along as dedup signals so a
# chronic (or already-fixed) condition gets ONE ticket, not one per
# day. Tickets are filed on the owning repo UNLABELED and ASSIGNED to
# FORGEJO_REVIEWER: the "Agent" label is the human's triage stamp,
# never the filing default. Greenlighting a ticket for Igor = add the
# Agent label -- that's the gate. An Agent-labeled ticket still assigned
# to the reviewer is claimable too (find_claimable accepts unassigned OR
# assigned-to-reviewer), so unassigning is optional. Review time is
# logged on each filed ticket.
#
# State: one ".logwatch" object {hour, backoff_days} in
# discretionary-state.json. Stamped once ATTEMPTED (slot semantics): a
# wedged pass must not retry model calls every tick for the rest of
# the day. The after-01:00 gate is window-completeness (the hour being
# analyzed must have closed), not a send-hour preference.
#
# A Claude health backoff (auth/limit, lib/claude.sh's .health) that
# overlapped the reviewed hour -- see lib/logwatch.sh's
# logwatch_health_backoff_in_window -- gets its own narration lines
# stripped from the journal rather than suppressing the whole pass, so
# an unrelated failure in the same window still files (igor#340). Once
# the backoff has recurred on >=2 distinct calendar days
# (logwatch_chronic_backoff, tracked in ".logwatch.backoff_days"), the
# stripping stops: chronic isn't noise, and the once-daily health email
# under-surfaces a recurring problem.

LOGWATCH_MARKER='<!-- agent:logwatch -->'

logwatch_done_this_hour() {
  local state_file hour
  state_file=$(discretionary_state_file)
  [ -f "$state_file" ] || return 1
  hour=$(date -d '1 hour ago' +%Y-%m-%dT%H)   # the just-closed hour we review
  [ "$(jq -r '.logwatch.hour // ""' "$state_file" 2>/dev/null)" = "$hour" ]
}

logwatch_mark_done() {
  local state_file tmp hour
  state_file=$(discretionary_state_file)
  hour=$(date -d '1 hour ago' +%Y-%m-%dT%H)
  [ -f "$state_file" ] || echo '{}' > "$state_file"
  tmp=$(mktemp)
  # Merge, not replace -- a bare `.logwatch = {hour: ...}` would wipe
  # `.logwatch.backoff_days` (igor#340's chronic-day tracking) every
  # single hour, since this stamp runs before that tracking is read.
  jq --arg h "$hour" '.logwatch = ((.logwatch // {}) + {hour: $h})' "$state_file" > "$tmp"
  mv "$tmp" "$state_file"
}

# logwatch_review_unit <repo> <unit> [suppress_noise] [timer_unit] [timer_subhourly]
# Review ONE unit's just-closed-hour journal; file tickets on <repo>.
# suppress_noise=1 strips lines that are pure narration of a
# TRANSIENT Claude health backoff (logwatch_strip_backoff_noise)
# before review, so a genuine unrelated failure in the same window
# still files even while the backoff itself stays unticketed; omit
# (or a chronic backoff, see do_logwatch_tick) to review the journal
# as-is. timer_unit, when the unit has a companion *.timer file
# declared alongside it, disambiguates a silent window instead of
# leaving the reviewer to guess from timestamps (igor#420) -- see
# logwatch_timer_verdict. timer_subhourly=1 says that timer's DECLARED
# schedule fires at least once an hour, which is what makes one silent
# hour evidence of anything at all (logwatch_timer_subhourly); a daily
# timer is silent by design. Returns 0 if a model call ran (the tick
# did real work), 1 if the unit was skipped (empty journal, or one a
# paused/unverifiable timer explains).
logwatch_review_unit() {
  local repo="$1" unit="$2" suppress_noise="${3:-0}" timer_unit="${4:-}" timer_subhourly="${5:-0}"
  local win_start win_end win_label start journal
  win_start=$(date -d '1 hour ago' '+%Y-%m-%d %H:00:00')   # the just-closed clock hour
  win_end=$(date '+%Y-%m-%d %H:00:00')
  win_label="$(date -d '1 hour ago' '+%Y-%m-%d %H:00')-$(date '+%H:00')"
  start=$(date +%s)

  journal=$(journalctl --user -u "$unit" \
    --since "$win_start" --until "$win_end" \
    --no-pager 2>/dev/null | grep -v '^-- No entries --$' | tail -c 60000)
  if [ "$suppress_noise" = "1" ]; then
    journal=$(logwatch_strip_backoff_noise "$journal")
  fi

  # Three signals, not one: a transition since the window opened, the
  # timer's last state change BEFORE it, and its state right now. A
  # transition-in-window check on its own reads every hour after the
  # first of a multi-hour pause as "continuously active" -- the
  # opposite of the truth, once per hour. See logwatch_timer_verdict.
  local timer_state="" timer_note="" timer_section=""
  if [ -n "$timer_unit" ]; then
    local tj_since tj_prior tj_state prior_since
    prior_since=$(logwatch_timer_lookback_since "$win_start")
    tj_since=$(journalctl --user -u "$timer_unit" --since "$win_start" \
      --no-pager 2>/dev/null | grep -v '^-- No entries --$' || true)
    tj_prior=$(journalctl --user -u "$timer_unit" \
      --since "$prior_since" --until "$win_start" \
      --no-pager 2>/dev/null | grep -v '^-- No entries --$' || true)
    tj_state=$(systemctl --user is-active "$timer_unit" 2>/dev/null || true)
    timer_state=$(logwatch_timer_verdict "$tj_since" "$tj_prior" "$tj_state" "$timer_unit")
  fi

  if [ -z "$journal" ]; then
    if [ "$timer_state" = "active" ] && [ "$timer_subhourly" = "1" ]; then
      # The timer provably ran the whole window AND its declared
      # schedule fires at least hourly, yet the unit produced
      # nothing -- itself the failure, not something to skip past.
      journal="(no journal entries for ${unit} in this window)"
      timer_note="${timer_unit} was active for this entire window (no Stopped/Started transition since it opened, and still active now) and its unit file declares a schedule that fires at least once an hour. ${unit} is driven by it and expected to produce journal entries every time it fires. This silence is NOT explained by the timer and is itself failure-worthy."
    else
      log "logwatch: ${unit}: no entries in the past hour -- skipping (timer: ${timer_state:-none})"
      return 1
    fi
  elif [ "$timer_state" = "paused" ]; then
    timer_note="${timer_unit} was not active for this entire window (a Stopped/Started transition, or it is stopped right now) -- an operator-initiated pause. Any apparent gap in ${unit}'s activity is explained by that pause. Do NOT file a tick-gap/silence finding for it."
  fi

  if [ -n "$timer_note" ]; then
    timer_section="## Timer status for ${win_label}

${timer_note}

"
  fi

  local open_titles recent_commits
  open_titles=$(forgejo_list_open_issue_titles "$repo" 2>/dev/null || true)
  recent_commits=$(forgejo_recent_commit_subjects "$repo" 20 2>/dev/null || true)

  # Known-benign context is keyed off the UNIT, not the repo: the
  # harness's own journal is full of idioms (holds, skips, idle
  # ticks) a generic service reviewer would misread as failures.
  local blurb=""
  if [ "$unit" = "agent.service" ]; then
    blurb=$(cat <<'EOF'

Service-specific context -- this unit is the agent harness ITSELF
(a cron tick every minute). Additional known-benign patterns, never
ticket-worthy: report already-sent statuses; "not ready for agentic
work -- skipping" validation lines; single "indeterminate (no readable
clone)" validation lines; "no claimable work -- idle" ticks; cooldown
waits; "already ran this hour" logwatch statuses. Claude auth/usage-limit
backoffs and health alert emails ARE ticket-worthy.
EOF
)
  fi

  local system user
  system="You are the hourly log reviewer for systemd services owned by an
unattended agent's operator. Each repo that runs as a service
declares its unit files in-repo; you receive ONE service's journal
for the clock hour that just closed, plus dedup
signals from the owning repo: open issue titles and recent commit
subjects.

Your job: find HARD failures and unresolved anomalies worth filing
as tickets on the owning repo. You are a failure-smell detector, not
a log narrator.

Do NOT file for:
- a retry that subsequently succeeded -- retrying is the system
  working as designed
- routine successful output, however verbose
- one-off blips that self-healed within the window
- anything substantially covered by an already-open issue (titles
  provided) -- chronic conditions get ONE ticket, not one per day
- a symptom that a recent commit (subjects provided) plausibly
  already fixes -- when a commit subject and a log symptom line up,
  the fix wins: do not file
- a gap or silence in this journal when a \"Timer status\" section
  below says the paired timer was paused -- trust that over inferring
  a long-running or stuck process from timestamps alone
${blurb}

DO file for:
- a run that exhausted its retries or abandoned the window
- an error with no subsequent success in the window
- the unit crashing or exiting nonzero with no benign explanation
- output indicative of a bug: stack traces, unbound variables,
  parse errors, shell warnings
- a \"Timer status\" section below stating the paired timer was active
  for the entire window on an at-least-hourly schedule while this unit
  produced no journal entries at all -- that silence is itself the
  failure

Output STRICT JSON only -- no preamble, no fences:
{\"findings\": [{\"title\": \"...\", \"severity\": \"low|medium|high\", \"body\": \"...\"}]}

- findings: [] when the hour was clean. This is the expected common
  case; do not invent work.
- At most 2 findings; pick the most material.
- title: terse, specific, greppable -- it becomes a Forgejo issue
  title (no prefix, no date).
- body: markdown -- a short diagnosis, the evidence log lines quoted
  verbatim in a fenced block, and what \"fixed\" would look like."

  user="Service under review: ${unit} (declared by ${repo})

## Currently open issues on ${repo} (do NOT refile these)

${open_titles:-(none)}

## Recent commit subjects on ${repo} (fixes here may already cover symptoms below)

${recent_commits:-(none)}

${timer_section}## Journal: ${unit}, ${win_label}

${journal}"

  local raw findings attempt
  findings=""
  for attempt in 1 2; do
    raw=$(claude_call "$AGENT_MODEL_REVIEW" "logwatch" 4000 "$system" "$user") || {
      log "logwatch: ${unit}: review call failed (attempt $attempt)"
      continue
    }
    if findings=$(jq -ce '.findings // []' <<<"$raw" 2>/dev/null); then
      break
    fi
    findings=""
    log "logwatch: ${unit}: unparseable review response (attempt $attempt)"
  done
  if [ -z "$findings" ]; then
    log "logwatch: ${unit}: no parseable review after 2 attempts -- giving up until next hour"
    return 0
  fi

  local count
  count=$(jq 'length' <<<"$findings")
  if [ "$count" -eq 0 ]; then
    log "logwatch: ${unit}: clean hour -- nothing to file"
    return 0
  fi
  if [ "$count" -gt 2 ]; then
    log "logwatch: ${unit}: reviewer returned $count findings -- filing the first 2 only"
  fi

  local elapsed f title sev fbody body num
  elapsed=$(( $(date +%s) - start ))
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    title=$(jq -r '.title // empty' <<<"$f" | head -1 | head -c 120)
    [ -n "$title" ] || continue
    sev=$(jq -r '.severity // "unknown"' <<<"$f")
    fbody=$(jq -r '.body // ""' <<<"$f")
    body="${fbody}

---
service: ${unit}
severity: ${sev}
window: ${win_label} (filed by the hourly logwatch pass)
${LOGWATCH_MARKER}"
    num=$(forgejo_open_issue "$repo" "$title" "$body") \
      || { log "warning: logwatch ticket open failed on $repo (continuing)"; continue; }
    # Deliberately NO "Agent" label here: the label is the human's
    # triage stamp, not the filing default. The operator greenlights a
    # ticket for Igor by adding the label -- that's the gate. An
    # Agent-labeled ticket still assigned to the reviewer is claimable
    # (find_claimable accepts unassigned OR assigned-to-reviewer), so
    # unassigning is optional, not required.
    forgejo_assign "$repo" "$num" "$FORGEJO_REVIEWER" 2>/dev/null \
      || log "warning: could not assign ${repo}#${num} to $FORGEJO_REVIEWER"
    forgejo_log_time "$repo" "$num" "$elapsed" 2>/dev/null \
      || log "warning: could not log time on ${repo}#${num}"
    log "logwatch: filed ticket ${repo}#${num} (${elapsed}s logged): $title"
  done < <(jq -c '.[0:2][]' <<<"$findings")

  return 0
}

do_logwatch_tick() {
  # We review the most recently CLOSED clock hour, so the window is always
  # complete -- no partial reads, no midnight gate. Once per hour per unit.
  if logwatch_done_this_hour; then
    log "logwatch: this hour's pass already ran -- continuing"
    return 1
  fi

  if ! command -v journalctl >/dev/null 2>&1; then
    log "logwatch: journalctl not available on this host -- marking done for this hour"
    logwatch_mark_done
    return 1
  fi

  # Attempted = done for this hour, BEFORE any model call (see header).
  logwatch_mark_done

  # A Claude health backoff (auth/limit) that overlapped the hour we're
  # about to review means its own review-call failures and the
  # backoff/alert lines in agent.service's journal are all downstream of
  # that one event -- the health-alert email already owns auth/limit
  # notification (igor#332/#333 double-report). A TRANSIENT backoff (its
  # first distinct day) gets only its own narration lines stripped from
  # the journal (logwatch_strip_backoff_noise), so a genuine unrelated
  # failure in the same window still files. A CHRONIC backoff (recurring
  # on >=2 distinct days, igor#340) is left unfiltered instead -- the
  # once-daily health email under-surfaces a recurring problem, so the
  # backoff narration stays visible for the reviewer to ticket (the
  # agent.service known-benign blurb already says these lines ARE
  # ticket-worthy; per-open-issue-title dedup keeps it to one ticket).
  local win_start_str win_end_str win_start_epoch win_end_epoch suppress_noise=0
  win_start_str=$(date -d '1 hour ago' '+%Y-%m-%d %H:00:00')
  win_end_str=$(date '+%Y-%m-%d %H:00:00')
  win_start_epoch=$(date -d "$win_start_str" +%s)
  win_end_epoch=$(date -d "$win_end_str" +%s)
  if logwatch_health_backoff_in_window "$(discretionary_state_file)" "$win_start_epoch" "$win_end_epoch"; then
    logwatch_record_backoff_day "$(discretionary_state_file)" "$(date -d '1 hour ago' +%Y-%m-%d)"
    if logwatch_chronic_backoff "$(discretionary_state_file)"; then
      log "logwatch: Claude health backoff chronic (>=${LOGWATCH_CHRONIC_BACKOFF_DAYS} distinct days) -- leaving backoff narration visible to the reviewer"
    else
      log "logwatch: Claude health backoff active in window -- stripping backoff narration lines only (health channel owns auth/limit alerting)"
      suppress_noise=1
    fi
  fi

  # Discovery: every bot-accessible repo that declares systemd units.
  # ANALYSIS_REPOS_JSON (not the validated set) -- like maintenance,
  # this pass only reads and files issues, never commits. A unit with a
  # companion <base>.timer file in the same dir is timer-driven; that
  # pairing is what lets logwatch_review_unit disambiguate a silent
  # window instead of guessing (igor#420). The timer file's own
  # contents settle whether it's even expected to fire within an hour --
  # most repos' timers are not. The `|| true` on the listing is
  # defensive: a repo with no systemd/ dir is the COMMON case and
  # forgejo_repo_list_dir returns nonzero for it, which errexit would
  # abort on -- today the sole call site (`if do_logwatch_tick`)
  # suppresses errexit inside the function, so the guard costs nothing
  # and survives that call site changing.
  local reviewed=0 repo_line r_name dir_listing units timers unit base
  local timer_unit timer_file timer_subhourly
  while IFS= read -r repo_line; do
    [ -z "$repo_line" ] && continue
    r_name=$(jq -r '.full_name' <<<"$repo_line")
    dir_listing=$(forgejo_repo_list_dir "$r_name" "systemd" 2>/dev/null || true)
    units=$(grep -E '\.service$' <<<"$dir_listing" || true)
    [ -z "$units" ] && continue
    timers=$(grep -E '\.timer$' <<<"$dir_listing" || true)
    while IFS= read -r unit; do
      [ -z "$unit" ] && continue
      base="${unit%.service}"
      timer_unit=""
      timer_subhourly=0
      if grep -qxF "${base}.timer" <<<"$timers"; then
        timer_unit="${base}.timer"
        timer_file=$(forgejo_repo_get_file "$r_name" "systemd/${base}.timer" 2>/dev/null || true)
        logwatch_timer_subhourly "$timer_file" && timer_subhourly=1
      fi
      if logwatch_review_unit "$r_name" "$unit" "$suppress_noise" "$timer_unit" "$timer_subhourly"; then
        reviewed=$((reviewed + 1))
      fi
    done <<<"$units"
  done <<<"$ANALYSIS_REPOS_JSON"

  if [ "$reviewed" -eq 0 ]; then
    log "logwatch: no service journals to review this hour -- continuing"
    return 1
  fi
  log "logwatch: reviewed $reviewed service journal(s)"
  return 0
}

# -- Shadow code review (non-binding) ---------------------------
#
# A step toward auto-merge. Convention-driven, NO env knob (like
# logwatch, its closest sibling): once this is on master it just runs,
# because the merge IS the opt-in and a non-binding comment's blast
# radius is trivial. For each open bot PR whose CURRENT head hasn't been
# reviewed yet, one review-tier model call produces an independent
# verdict (APPROVE /
# REQUEST_CHANGES / COMMENT) which is posted as a NON-BINDING comment --
# a human still merges. The point is to collect the data that proves
# the reviewer agrees with the human often enough to, eventually, let
# its APPROVE be the merge signal on the safest repos. The review NEVER
# merges, pushes, or labels anything; it only comments.
#
# Independence is the whole value: it runs on AGENT_MODEL_REVIEW (the
# non-author, higher-stakes tier) from a fresh context with an
# adversarial directive -- the thing under review does not get to audit
# itself. The verdict is a label-line + ===BODY=== sentinel parsed
# harness-side, never model-written JSON.

# Parse the reviewer's response: a leading `VERDICT:` line and a
# `===BODY===` sentinel before the markdown review. Echoes
# {verdict, body} JSON; returns non-zero (unparseable -> retry) if the
# sentinel is missing, the body is blank, or the verdict isn't one of
# the three valid values. Mirrors sports_parse_response.
review_parse_response() {
  local raw="$1" head body verdict
  case "$raw" in
    *'===BODY==='*) ;;
    *) return 1 ;;
  esac
  head="${raw%%===BODY===*}"
  body="${raw#*===BODY===}"
  printf '%s' "$body" | grep -q '[^[:space:]]' || return 1
  verdict=$(printf '%s' "$head" | sed -n 's/^[[:space:]]*VERDICT:[[:space:]]*//p' | head -1)
  # Normalize to a canonical token: uppercase, spaces->underscore, drop
  # any stray punctuation (trailing periods, backticks the model adds).
  verdict=$(printf '%s' "$verdict" | tr '[:lower:]' '[:upper:]' | tr ' ' '_' | tr -cd 'A-Z_')
  case "$verdict" in
    APPROVE|REQUEST_CHANGES|COMMENT) ;;
    *) return 1 ;;
  esac
  # Trim blank lines off both ends (interior blanks survive).
  body=$(printf '%s\n' "$body" | awk '
    NF { if (started) for (i = 0; i < blanks; i++) print ""
         blanks = 0; started = 1; print; next }
    started { blanks++ }')
  jq -n --arg v "$verdict" --arg b "$body" '{verdict:$v, body:$b}'
}

# Request the human reviewer on a PR and log the outcome TRUTHFULLY: a success
# line only when the request actually landed, otherwise ONE warning carrying the
# API reason. Replaces the old "request || warn; log success anyway" pattern,
# which emitted a contradictory warning-then-"requested" pair when the request
# failed (#377). $3 is a short context label (e.g. "verdict=APPROVE").
review_request_human() {
  local repo="$1" number="$2" ctx="$3" reason
  [ -n "${FORGEJO_REVIEWER:-}" ] || return 0
  if reason=$(forgejo_request_review "$repo" "$number" "$FORGEJO_REVIEWER" 2>&1); then
    log "review: ${repo}#${number} requested review from ${FORGEJO_REVIEWER} (${ctx})"
  else
    log "warning: review: review-request to ${FORGEJO_REVIEWER} failed on ${repo}#${number} (${ctx}): ${reason:-unknown}"
  fi
}

do_review_tick() {
  # Find the first open bot PR -- across the VALIDATED set -- whose live
  # head hasn't been reviewed yet. Unvalidated repos (not ready for
  # work) are skipped: a verdict there can never become a merge signal,
  # so it's just bot footprint on a not-ready repo.
  # One review per tick; first un-reviewed head wins, then we exit the
  # cascade like every other pass.
  local repo_line repo prs pr_num pr_json head_sha key reviewed_sha
  local target_repo="" target_num="" target_sha="" target_json="" target_ci=""
  while IFS= read -r repo_line; do
    [ -n "$target_repo" ] && break
    [ -z "$repo_line" ] && continue
    repo=$(jq -r '.full_name' <<<"$repo_line")
    maintenance_repo_validated "$repo" || continue
    prs=$(forgejo_list_open_bot_prs "$repo" "$BOT_USER" 2>/dev/null || echo '[]')
    while read -r pr_num; do
      [ -n "$target_repo" ] && break
      [ -z "$pr_num" ] && continue
      pr_json=$(forgejo_get_pr "$repo" "$pr_num" 2>/dev/null || echo '{}')
      # Skip turn-cap checkpoint drafts: a WIP PR is paused mid-work, not ready
      # to review. It finalizes (WIP dropped) when the agent completes it, and
      # gets reviewed then.
      checkpoint_is_wip "$(jq -r '.title // ""' <<<"$pr_json")" && continue
      head_sha=$(jq -r '.head.sha // ""' <<<"$pr_json")
      [ -z "$head_sha" ] && continue
      key="${repo}#${pr_num}"
      reviewed_sha=$(review_reviewed_sha "$key")
      [ "$reviewed_sha" = "$head_sha" ] && continue
      # Wait for CI to settle before reviewing: a pending build can't be
      # assessed, and reviewing now burns the head on a useless "CI pending,
      # re-run" verdict. Skip this candidate; re-check it (or a now-ready one)
      # next tick.
      target_ci=$(forgejo_commit_status "$repo" "$head_sha" 2>/dev/null)
      case "$target_ci" in
        success|failure|error) ;;
        *) log "review: ${repo}#${pr_num} head ${head_sha:0:8} CI not settled (${target_ci:-none}) -- waiting"; continue ;;
      esac
      target_repo="$repo"; target_num="$pr_num"; target_sha="$head_sha"; target_json="$pr_json"
    done < <(jq -r '.[].number' <<<"$prs" 2>/dev/null)
  done <<<"$ANALYSIS_REPOS_JSON"

  # No open bot PR with an un-reviewed head -- the common idle case.
  # Stay silent (this runs every tick); the cascade just falls through.
  [ -n "$target_repo" ] || return 1
  key="${target_repo}#${target_num}"

  # Idempotency net: if a prior tick posted this exact head's verdict
  # but died before recording state, the per-sha marker is already on
  # the PR. Reconcile state and skip rather than double-post and re-burn
  # a model call. (Primary dedup is the local .review sha above; this
  # only catches the post-succeeded-state-write-crashed window.)
  local old_marker="<!-- shadow-review sha=${target_sha}"
  local new_marker="<!-- review sha=${target_sha}"
  local old_count new_count
  old_count=$(forgejo_pr_has_comment_containing "$target_repo" "$target_num" "$BOT_USER" "$old_marker" 2>/dev/null || echo 0)
  new_count=$(forgejo_pr_has_comment_containing "$target_repo" "$target_num" "$BOT_USER" "$new_marker" 2>/dev/null || echo 0)
  if [ "$old_count" -gt 0 ] || [ "$new_count" -gt 0 ]; then
    log "review: ${key} head ${target_sha:0:8} already carries a verdict comment -- reconciling state"
    review_record "$key" "$target_sha" "unknown" "unknown" "$(date +%s)"
    return 1
  fi

  local start ci title body diff truncated_note directive user patch_id reviewed_patch_id
  start=$(date +%s)

  # Fetch the diff first; used for patch-id dedup AND the review itself.
  # Cap it so a runaway PR can't blow the model's input budget; tell the
  # reviewer when truncated so an unreviewable diff becomes an explicit
  # "can't confirm" rather than a false APPROVE.
  # `|| true`: with pipefail, a failed fetch would abort the tick via
  # set -e. Empty -> skip + retry next tick.
  diff=$(forgejo_pr_diff "$target_repo" "$target_num" 2>/dev/null | head -c 200000 || true)
  if [ -z "$diff" ]; then
    log "review: ${key} empty/failed diff fetch -- skipping this tick (will retry)"
    return 1
  fi
  truncated_note=""
  [ "${#diff}" -ge 200000 ] && truncated_note=" (TRUNCATED at 200000 chars -- review what you can see and say so)"

  # Patch-id dedup: when the head sha changed but the net diff is the
  # same (base-merge, rebase without content change), record the new sha
  # so we don't re-fetch every tick, but do NOT re-review or re-request
  # the human. Fall back to sha-only dedup if patch-id comes back empty.
  patch_id=$(printf '%s' "$diff" | git patch-id --stable 2>/dev/null | awk '{print $1}')
  reviewed_patch_id=$(review_reviewed_patchid "$key")
  if [ -n "$patch_id" ] && [ -n "$reviewed_patch_id" ] && [ "$patch_id" = "$reviewed_patch_id" ]; then
    log "review: ${key} head advanced to ${target_sha:0:8} but patch-id unchanged -- skipping re-review"
    review_update_sha "$key" "$target_sha"
    return 1
  fi

  ci="$target_ci"   # already fetched + confirmed settled during selection
  [ -n "$ci" ] || ci="unknown"
  title=$(jq -r '.title // ""' <<<"$target_json")
  body=$(jq -r '.body // ""' <<<"$target_json")

  directive=$(cat "$AGENT_HOME/bin/lib/review-directive.md")
  user="PR under review: ${target_repo}#${target_num}
Head commit: ${target_sha}
CI status for head: ${ci}

## PR title

${title}

## PR description

${body:-(none)}

## Unified diff${truncated_note}

\`\`\`diff
${diff}
\`\`\`"

  log "review: examining ${key} head ${target_sha:0:8} (ci=${ci}, ${#diff} chars of diff${truncated_note:+, truncated})"

  # max_tokens 8000: review prose is short, but thinking shares the CLI
  # output budget -- size ~5x expected so a long think can't truncate
  # the head off the result (which surfaces as a flaky parse failure).
  # strip_fences=0: the body is markdown prose, not a JSON envelope.
  local raw parsed attempt verdict review_body snippet tail_snip
  # igor#308: run the shadow review at an escalating effort -- flat "high"
  # during the rework loop, "max" for the final look before escalation.
  local rev_rounds rev_effort
  rev_rounds=$(review_rework_rounds "$key")
  rev_effort=$(reviewer_effort "$rev_rounds")
  parsed=""
  for attempt in 1 2; do
    raw=$(claude_call "${AGENT_MODEL_REVIEW}:${rev_effort}" "review" 8000 "$directive" "$user" 0) || {
      log "review: ${key} review call failed (attempt $attempt)"
      continue
    }
    if parsed=$(review_parse_response "$raw"); then
      break
    fi
    parsed=""
    snippet=$(printf '%s' "$raw" | tr '\n' ' ')
    tail_snip=""
    [ "${#snippet}" -gt 160 ] && tail_snip=${snippet:$(( ${#snippet} - 160 ))}
    log "review: ${key} unparseable response (attempt $attempt, ${#raw} chars; head: ${snippet:0:160} [...] tail: ${tail_snip})"
  done
  if [ -z "$parsed" ]; then
    log "review: ${key} no parseable verdict after 2 attempts -- leaving head un-recorded (will retry next tick)"
    return 1
  fi

  verdict=$(jq -r '.verdict' <<<"$parsed")
  review_body=$(jq -r '.body' <<<"$parsed")

  local elapsed comment
  elapsed=$(( $(date +%s) - start ))
  comment="### 🤖 Review — \`${verdict}\` _(automated)_

CI for \`${target_sha:0:8}\`: **${ci}**

${review_body}

---
<sub>Independent review by the harness on \`${AGENT_MODEL_REVIEW}\` (effort: ${rev_effort}). The human reviewer is requested once Igor has reviewed; a human still merges.</sub>
<!-- review sha=${target_sha} verdict=${verdict} ci=${ci} -->"

  if forgejo_comment "$target_repo" "$target_num" "$comment"; then
    review_record "$key" "$target_sha" "$verdict" "$ci" "$(date +%s)" "$patch_id"
    forgejo_log_time "$target_repo" "$target_num" "$elapsed" 2>/dev/null \
      || log "warning: review: could not log time on ${key}"
    log "review: ${key} head ${target_sha:0:8} -> ${verdict} (ci=${ci}, ${elapsed}s)"
    local rc_rounds
    rc_rounds=$(review_rework_rounds "$key")
    case "$verdict" in
      APPROVE|COMMENT)
        review_reset_rework "$key"
        # Only request the human when the auto-merge won't handle it: a default
        # (shadow-gated) repo with an APPROVE merges on this signal, so requesting
        # the human is just noise for a PR that merges itself (awareness comes via
        # the daily ship-report). A COMMENT (won't auto-merge) or a carve-out
        # (human review IS the gate) still routes to the human.
        if [ -n "${FORGEJO_REVIEWER:-}" ]; then
          if automerge_will_take "$target_repo" "$verdict"; then
            log "review: ${key} shadow APPROVE on a shadow-gated repo -- auto-merge handles it, not requesting a human"
          else
            review_request_human "$target_repo" "$target_num" "verdict=${verdict}"
          fi
        fi
        ;;
      REQUEST_CHANGES)
        local repo_validated=false
        maintenance_repo_validated "$target_repo" && repo_validated=true
        if [ "$repo_validated" = "false" ]; then
          log "review: ${key} REQUEST_CHANGES on unvalidated repo -- requesting human instead of rework"
          if [ -n "${FORGEJO_REVIEWER:-}" ]; then
            forgejo_comment "$target_repo" "$target_num" \
              "${target_repo} is not in the validated set (no CI / not validated), so autonomous rework cannot be CI-verified. Handing to you." 2>/dev/null \
              || log "warning: review: unvalidated-repo comment failed on ${key}"
            review_request_human "$target_repo" "$target_num" "unvalidated repo"
          fi
        elif [ "$rc_rounds" -ge 3 ]; then
          log "review: ${key} REQUEST_CHANGES rework_rounds=${rc_rounds} >= 3 -- escalating to human"
          if [ -n "${FORGEJO_REVIEWER:-}" ]; then
            forgejo_comment "$target_repo" "$target_num" \
              "Igor requested changes ${rc_rounds} times without converging -- handing this to you." 2>/dev/null \
              || log "warning: review: escalation comment failed on ${key}"
            review_request_human "$target_repo" "$target_num" "escalation after ${rc_rounds} rework rounds"
          fi
        else
          local new_rounds
          new_rounds=$(( rc_rounds + 1 ))
          review_set_rework_rounds "$key" "$new_rounds"
          review_set_pending_rc_body "$key" "$review_body"
          forgejo_assign "$target_repo" "$target_num" "$BOT_USER" 2>/dev/null \
            || log "warning: review: bot assignment failed on ${key} (rework round ${new_rounds})"
          log "review: ${key} REQUEST_CHANGES -> rework round ${new_rounds}/3, bot assigned"
        fi
        ;;
    esac
    return 0
  fi
  log "warning: review: comment post failed on ${key} -- not recording (will retry next tick)"
  return 1
}

# Worktree key: slash-free, unique per repo+issue.
worktree_key() { printf '%s-%s' "${1//\//_}" "$2"; }

# Build a "Dependencies changed" section from the diff. Empty output
# when no manifest/lockfile files changed. Trust boundary: the harness
# writes this, not Claude -- a thing under review must not be able to
# omit its own audit trail.
build_deps_section() {
  local base="$1" pattern files f counts
  pattern='^(.*/)?(package\.json|package-lock\.json|yarn\.lock|pnpm-lock\.yaml|requirements[^/]*\.txt|Pipfile(\.lock)?|pyproject\.toml|poetry\.lock|uv\.lock|Cargo\.(toml|lock)|go\.(mod|sum)|Gemfile(\.lock)?|composer\.(json|lock))$'
  files=$(git diff --name-only "origin/${base}..HEAD" | grep -E "$pattern" || true)
  [ -z "$files" ] && return 0

  printf '\n\n## Dependencies changed\n\n'
  printf 'Manifest or lockfile changes detected. Review carefully -- transitive\n'
  printf 'dependencies in lockfiles are the largest supply-chain attack surface.\n\n'
  printf 'Files changed:\n'
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    counts=$(git diff --numstat "origin/${base}..HEAD" -- "$f" \
      | awk '{printf "+%s -%s", $1, $2}')
    printf -- '- `%s` (%s)\n' "$f" "$counts"
  done <<<"$files"
}

# -- Work model --------------------------------------------------
#
# The tick always runs to completion, 24/7 -- there is no shift
# window. Within a tick the work cascade is strictly ordered:
# recovery + validation, then human-driven PR-review pickup, then
# Igor's own work (daily reading + post, weekly /now + site-work),
# then scheduled maintenance, then the claimable-issue grind. The
# daily/weekly slots are throttled so Igor's own work can't flood
# the day; tickets soak up whatever time is left and roll over.

# -- Claude health: probe, alert, global backoff gate ------------
#
# Before any work: run the daily canary (probe + once-daily alert
# email -- see do_health_tick), then bail out of ALL model work if a
# health cooldown is live (auth broken or subscription usage window
# exhausted -- see lib/claude.sh). A blocked tick still runs the
# scripted, no-LLM subsystems (the SEO report) so their emails
# aren't held hostage by a usage limit; everything else waits.
# `|| true`: the canary must never kill a tick.

do_health_tick || true

# -- Deploy barrier (non-model: API + curl, so it runs even during a Claude
# health cooldown). Watches an in-flight deploy and ENDS the tick until it
# verifies -- so no long work starts mid-deploy. Sits above the health gate.
do_deploy_barrier && exit 0

# -- Validation sweep ------------------------------------------
#
# Per-tick pre-flight. Every bot-accessible repo is CLONED (or its
# existing clone fetched) and then validated against that LOCAL clone --
# zero per-file API calls. Cloning is gated on ACCESS, not on validation:
# we pull down every repo the bot can see, then decide per-repo whether it
# is ready for WORK. Reading a git clone is all-or-nothing, so validation
# can't be fooled by one file's read blipping -- the old per-file API failure
# mode that filed bogus onboarding tickets on healthy repos. With NO clone
# yet, a blocked clone is `indeterminate` (skip + retry). Once a clone
# EXISTS, a failed refresh-fetch validates the last-fetched state --
# stale-but-valid ON PURPOSE: readiness barely changes tick-to-tick, and the
# WORK step re-fetches before it acts, so nothing is ever done on stale data.
# A repo that fails validation is simply skipped for work, SILENTLY;
# onboarding is a manual operator step (`bin/validate-repo.sh <repo>` prints
# a failing checklist).
#
# Builds VALIDATED_REPOS_JSON: newline-separated JSON lines, one per repo
# ready for work, same shape that `jq -c '.[]' <<<$(forgejo_list_bot_repos)`
# would produce. Downstream WORK loops iterate this set.
#
# Runs here, ABOVE the claude_health_blocked gate below (igor#386):
# do_automerge_tick needs this set and is itself non-model (API + curl
# only), so both the sweep and the merge must run even during a live
# Claude cooldown -- a cooldown can run for hours, and an approved,
# CI-green bot PR shouldn't sit unmerged that whole time just because
# Claude is unavailable. Before this fix the sweep (and therefore
# do_automerge_tick, which depends on VALIDATED_REPOS_JSON) sat below the
# gate, so a live cooldown silently skipped auto-merge fleet-wide for its
# entire duration with no error, no log, nothing to grep for.

log "validation sweep ($BOT_USER)"
ALL_REPOS=$(forgejo_list_bot_repos)

# Analysis set: every bot-accessible repo, in the same newline-delimited
# JSON-object shape as VALIDATED_REPOS_JSON. Validation gates WORK
# (issue pickup, PR pushes, site-work); it does NOT gate read-only
# ANALYSIS (the weekly security/dep audit, which only files tickets and
# never commits). do_maintenance_tick loops this set so a repo that isn't
# ready for work still gets its dependencies audited; whether a finding
# becomes a PR (validated) or a human triage ticket (not) is decided
# per-repo in do_maintenance_for_repo.
ANALYSIS_REPOS_JSON=$(jq -c '.[]' <<<"$ALL_REPOS")
VALIDATED_REPOS_JSON=""
VAL_PASS=0
VAL_CACHED=0
VAL_NOTREADY=0
VAL_INDET=0
while IFS= read -r repo_line; do
  [ -z "$repo_line" ] && continue
  R_NAME=$(jq -r '.full_name' <<<"$repo_line")

  # Cooldown: reuse a recent PASS instead of re-fetching + re-validating
  # every tick. Decouples validation cost from tick frequency (matters at
  # the 1-minute cadence as repos are added). Only PASSes are cached; a
  # not-ready or indeterminate repo re-checks next tick.
  if validation_fresh "$R_NAME"; then
    VALIDATED_REPOS_JSON+="${repo_line}"$'\n'
    VAL_CACHED=$((VAL_CACHED + 1))
    continue
  fi

  # Clone-on-access (clone-if-missing else fetch), then validate the clone.
  # Only a PASS is cached (above), so a not-ready/indeterminate repo re-fetches
  # every tick -- DELIBERATE: it means a repo starts getting worked the moment
  # the operator finishes onboarding it, with no cooldown lag. The fetch is a
  # cheap "already up to date" against the local Forgejo; revisit (e.g. a short
  # failure-cooldown) only if the not-ready set ever grows large.
  ensure_repo_local "$R_NAME" || true
  R_PATH=$(repo_path_for "$R_NAME")

  set +e
  validate_repo_local "$R_NAME" "$R_PATH" >/dev/null
  V_RC=$?
  set -e
  if [ "$V_RC" -eq 0 ]; then
    VALIDATED_REPOS_JSON+="${repo_line}"$'\n'
    validation_mark_ok "$R_NAME"
    VAL_PASS=$((VAL_PASS + 1))
  elif [ "$V_RC" -eq 2 ]; then
    # Indeterminate: no readable clone (the fetch likely failed), so no
    # check actually ran. Skip for work this tick only; nothing is cached,
    # so the next tick re-checks.
    log "validation: $R_NAME indeterminate (no readable clone) -- re-checking next tick"
    VAL_INDET=$((VAL_INDET + 1))
  else
    # Genuinely not ready (a real gap in the clone). No ticket -- onboarding
    # is a manual operator step. But blocked work must NOT vanish silently: if
    # the repo has open Agent-labeled tickets, they can't be picked up until
    # it's onboarded, so say so plainly (a bare "skipping" line is how
    # knowthetable/snail's audio tickets rotted unnoticed until a human caught
    # the missing feature). Best-effort API read; never aborts the sweep.
    NA_BLOCKED=$(forgejo_find_claimable "$R_NAME" "${FORGEJO_REVIEWER:-}" 2>/dev/null | jq 'length' 2>/dev/null || echo 0)
    if [ "${NA_BLOCKED:-0}" -gt 0 ]; then
      log "validation: $R_NAME not ready for agentic work but has $NA_BLOCKED open Agent-labeled issue(s) that CANNOT be picked up until it's onboarded (run bin/validate-repo.sh $R_NAME for the checklist)"
    else
      log "validation: $R_NAME not ready for agentic work -- skipping (run bin/validate-repo.sh $R_NAME for the checklist)"
    fi
    VAL_NOTREADY=$((VAL_NOTREADY + 1))
  fi
done < <(jq -c '.[]' <<<"$ALL_REPOS")
log "validation: ${VAL_PASS} pass, ${VAL_CACHED} cached, ${VAL_NOTREADY} not-ready, ${VAL_INDET} indeterminate"

# -- Auto-merge on approve (needs the validated set, just built above; non-model
# -- API only). Merges a human-approved bot PR on an opt-in repo and stamps the
# pending deploy that the barrier (top of the tick) then watches to healthy.
# One-thing-then-exit, like the rest of the cascade. Deliberately above the
# claude_health_blocked gate below -- see the validation-sweep comment above.
do_automerge_tick && exit 0

if claude_health_blocked; then
  log "claude health: backoff active (kind=$(claude_health_kind)) -- skipping all model work this tick"
  do_seo_tick || true
  do_shipreport_tick || true
  exit 0
fi

# Task heartbeat (check B) -- the gates above (health probe, deploy
# barrier, cooldown check) can end the tick before real work ever starts,
# so the start ping sits here, at the true top of the cascade. Paired
# success/fail ping lives in cleanup() (trap on EXIT), guarded on
# HC_TASK_STARTED so it only fires for a tick that reached this point --
# covers every exit path below (including the cascade's many early
# `exit 0`s) as well as a crash/hang. No-op when HEALTHCHECK_TASK_URL is
# unset.
HC_TASK_STARTED=1
hc_ping task start

# -- Bootstrap: ensure the website is cloned (if opt-in) ----------
#
# Brain repo bootstrap was retired in Phase 6 -- the agent's
# memory lives in ~/.local/state/agent/brain.sqlite now and the
# brain repo is archived on Forgejo. The website is the only
# repo the harness still proactively clones, and only when
# WEBSITE_REPO is set.

if [ -n "$WEBSITE_REPO" ]; then
  if forgejo_repo_exists "${WEBSITE_REPO}"; then
    ensure_repo_local "${WEBSITE_REPO}"
  else
    log "warning: WEBSITE_REPO=${WEBSITE_REPO} does not exist or bot lacks access -- website work disabled this tick"
  fi
else
  log "WEBSITE_REPO unset -- website work disabled (set in .env to enable)"
fi

# -- Recovery: clear orphaned bot assignments ------------------
#
# Invariant: we hold the global flock, so no other tick is
# currently running. Any open issue assigned to the bot right
# now is in one of two states:
#
#   (a) Orphan from a crashed previous tick. Needs the
#       re-queueing comment, unassign, and local worktree
#       cleanup.
#
#   (b) Leftover from a successful tick where post-PR cleanup
#       didn't unassign the bot -- e.g., issues whose PRs
#       opened before fix/issue-lifecycle-design landed. The
#       work is IN FLIGHT via the open bot PR. Unassign
#       quietly; no comment ("re-queueing" would be a lie
#       since discovery's PR-history check skips it), no
#       worktree cleanup (the work is on the remote branch).
#
# Distinguish via forgejo_bot_prs_for_issue: any open bot PR
# closing the issue -> case (b).

log "recovery sweep ($BOT_USER)"
ORPHANS=$(forgejo_my_assigned || echo '[]')
ORPHAN_COUNT=$(jq 'length' <<<"$ORPHANS")

if [ "$ORPHAN_COUNT" -gt 0 ]; then
  while read -r line; do
    [ -z "$line" ] && continue
    O_REPO=$(jq -r '.repo' <<<"$line")
    O_NUM=$(jq -r '.num' <<<"$line")

    # Case (b): open bot PR -> work in flight, quiet unassign only.
    O_PR_HISTORY=$(forgejo_bot_prs_for_issue "$O_REPO" "$O_NUM" "$BOT_USER" 2>/dev/null || echo '[]')
    O_OPEN_PR=$(jq '[.[] | select(.state == "open")] | length' <<<"$O_PR_HISTORY")
    if [ "$O_OPEN_PR" -gt 0 ]; then
      log "recovery: ${O_REPO}#${O_NUM} in flight (open bot PR), unassigning quietly"
      forgejo_unassign_all "$O_REPO" "$O_NUM"
      continue
    fi

    # Case (a): true orphan -> re-queue.
    log "recovery: ${O_REPO}#${O_NUM} orphaned, re-queueing"
    forgejo_comment "$O_REPO" "$O_NUM" \
      "Previous tick was interrupted before completion. Re-queueing -- the next tick will pick this up."
    forgejo_unassign_all "$O_REPO" "$O_NUM"

    O_LOCAL=$(repo_path_for "$O_REPO")
    O_WT="$AGENT_STATE_DIR/worktrees/$(worktree_key "$O_REPO" "$O_NUM")"
    if [ -d "$O_LOCAL/.git" ]; then
      if [ -d "$O_WT" ]; then
        (cd "$O_LOCAL" && git worktree remove "$O_WT" --force) 2>/dev/null || rm -rf "$O_WT"
      fi
      cleanup_agent_branches "$O_NUM" "$O_LOCAL"
    fi
  done < <(jq -c '.[] | {repo: .repository.full_name, num: .number}' <<<"$ORPHANS")
fi

# -- Validation sweep already ran above (igor#386) --------------
#
# VALIDATED_REPOS_JSON / ANALYSIS_REPOS_JSON were built earlier, above the
# claude_health_blocked gate, so do_automerge_tick could run during a
# Claude cooldown too. do_maintenance_tick below is NOT eligible for that
# treatment (it calls Claude), so its "nothing validated" fallback stays
# gated here, after the health check.

if [ -z "$VALIDATED_REPOS_JSON" ]; then
  # No repo is safe for agentic WORK this tick. Read-only analysis is
  # decoupled from validation, so still run the maintenance/analysis
  # pass over the full bot-accessible set before exiting -- everything
  # below here (PR-review, Igor's own work, the ticket grind) needs a
  # validated repo and is correctly skipped.
  log "validation: no repos passed -- running analysis-only pass, then done"
  do_maintenance_tick || true
  exit 0
fi

# -- Scheduled maintenance (moved) -----------------------------
#
# Maintenance used to run here, at the top of the cascade. It now
# runs lower down -- after PR-review pickup and after Igor's own
# daily/weekly work -- so the blog and site upkeep come first while
# maintenance still beats the claimable-issue grind. See the
# "Igor's own work + scheduled maintenance" block below.

# -- PR-review pickup ------------------------------------------
#
# Two pickup signals, in priority order:
#
# 1. Forgejo "Request changes" review on the current PR HEAD --
#    reviewer rejected the current state via Forgejo's native
#    review UI. Picked up automatically; no label/assignment
#    dance needed.
#
# 2. The "assignment dance" (legacy/manual override): reviewer
#    reassigns the PR back to the agent. Next tick finds it here and
#    reopens the work.
#
# Disabled when FORGEJO_REVIEWER is unset (testing / solo runs without
# a reviewer configured).

REVIEW_PR=""
REVIEW_PR_TRIGGER=""

# Signal 1: scan all validated repos for open bot PRs whose latest
# non-bot review is an unaddressed REQUEST_CHANGES. We trust
# Forgejo's own `stale` and `dismissed` flags instead of doing a
# manual review.commit_id == pr.head.sha comparison -- the sha
# comparison was stricter than Forgejo's own staleness tracking
# and tripped on benign things like merging master into the PR
# branch (which advances HEAD without invalidating the review).
# Repos that failed the validation sweep are excluded -- if the
# repo isn't safe to do new work in, it isn't safe to push
# follow-up commits to either.
while IFS= read -r repo_line; do
  [ -n "$REVIEW_PR" ] && break
  [ -z "$repo_line" ] && continue
  repo_full=$(jq -r '.full_name' <<<"$repo_line")
  rc_open_prs=$(forgejo_list_open_bot_prs "$repo_full" "$BOT_USER" 2>/dev/null || echo '[]')
  while read -r pr_num; do
    [ -n "$REVIEW_PR" ] && break
    [ -z "$pr_num" ] && continue
    pr_details_json=$(forgejo_get_pr "$repo_full" "$pr_num" 2>/dev/null || echo '{}')
    [ "$(jq -r '.number // ""' <<<"$pr_details_json")" = "" ] && continue
    # Best-effort by construction (igor#425): forgejo_pr_actionable_request_changes
    # degrades to empty on a fetch failure rather than propagating a nonzero
    # exit, so one transient timeout scanning a PR here can't abort the whole
    # tick under `set -e -o pipefail` -- it used to. The guarantee lives in the
    # helper (it ends in `return 0`), so no `|| echo` belt is added here on top
    # of it -- a fallback that can never fire only hides where the guarantee is.
    latest_review=$(forgejo_pr_actionable_request_changes "$repo_full" "$pr_num" "$BOT_USER" 2>/dev/null)
    [ -z "$latest_review" ] && continue
    # Synthesize the PR record into the same shape forgejo_my_assigned_prs
    # returns so the downstream flow can consume it uniformly.
    REVIEW_PR=$(jq -c --arg r "$repo_full" '. + {repository: {full_name: $r}}' <<<"$pr_details_json")
    REVIEW_PR_TRIGGER="REQUEST_CHANGES review (not stale, not dismissed)"
  done < <(jq -r '.[].number' <<<"$rc_open_prs" 2>/dev/null)
done <<<"$VALIDATED_REPOS_JSON"

# Signal 2: assignment dance (only if no request-changes signal fired)
# Filter to validated repos only -- same rule as Signal 1. A bot-assigned
# PR on an unvalidated repo must not be autonomously reworked+pushed.
if [ -z "$REVIEW_PR" ] && [ -n "${FORGEJO_REVIEWER:-}" ]; then
  REVIEW_PRS=$(forgejo_my_assigned_prs 2>/dev/null || echo '[]')
  REVIEW_COUNT=$(jq 'length' <<<"$REVIEW_PRS")
  if [ "$REVIEW_COUNT" -gt 0 ]; then
    while read -r candidate_pr; do
      [ -n "$REVIEW_PR" ] && break
      [ -z "$candidate_pr" ] && continue
      candidate_repo=$(jq -r '.repository.full_name' <<<"$candidate_pr")
      if maintenance_repo_validated "$candidate_repo"; then
        REVIEW_PR="$candidate_pr"
        REVIEW_PR_TRIGGER="reassigned back to bot"
      else
        log "PR-review: skipping bot-assigned ${candidate_repo}#$(jq -r '.number' <<<"$candidate_pr") -- repo not validated"
      fi
    done < <(jq -c '.[]' <<<"$REVIEW_PRS" 2>/dev/null)
  fi
fi

if [ -n "$REVIEW_PR" ]; then
    PR_NUMBER=$(jq -r .number <<<"$REVIEW_PR")
    PR_REPO=$(jq -r '.repository.full_name' <<<"$REVIEW_PR")
    PR_TITLE=$(jq -r .title <<<"$REVIEW_PR")

    log "PR-review: ${PR_REPO}#${PR_NUMBER} -- reopening (${REVIEW_PR_TRIGGER})"

    # Binding-flow rework: do_review_tick assigns the bot and stores the
    # requested-changes text in pending_rc_body. The normal comment-fetchers
    # filter out bot comments (.user.login != bot), so without this injection
    # the agent would rework blind on its own verdict. An empty body means
    # this is a legacy human-assignment pickup.
    REVIEW_KEY="${PR_REPO}#${PR_NUMBER}"
    BINDING_RC_BODY=$(review_pending_rc_body "$REVIEW_KEY")

    PR_DETAILS=$(forgejo_get_pr "$PR_REPO" "$PR_NUMBER" 2>/dev/null || echo '{}')
    PR_HEAD=$(jq -r '.head.ref // ""' <<<"$PR_DETAILS")
    PR_HEAD_SHA=$(jq -r '.head.sha // ""' <<<"$PR_DETAILS")
    PR_BASE=$(jq -r '.base.ref // ""' <<<"$PR_DETAILS")
    PR_BODY=$(jq -r '.body // ""' <<<"$PR_DETAILS")

    if [ -z "$PR_HEAD" ]; then
      log "PR-review: could not fetch PR details for ${PR_REPO}#${PR_NUMBER} -- skipping"
      exit 0
    fi

    # Crash-loop break (igor#291): a rework that keeps dying mid-run -- the heavy
    # in-worktree test suite taking the tick down before a verdict -- must not be
    # re-attempted forever; it starves the whole downstream cascade. Count crashes
    # crash-safely (stamp BEFORE the work, reset only on a clean return past the
    # claude call below); once capped, escalate to the human instead of looping.
    REWORK_CRASH_CAP=2
    RC_CRASHES=$(review_rework_crashes "$REVIEW_KEY")
    if [ "$RC_CRASHES" -ge "$REWORK_CRASH_CAP" ]; then
      log "PR-review: ${REVIEW_KEY} rework crashed ${RC_CRASHES}x without completing -- escalating to ${FORGEJO_REVIEWER}, not re-attempting"
      forgejo_comment "$PR_REPO" "$PR_NUMBER" \
        "Igor's automated rework has crashed ${RC_CRASHES} times on this PR without producing a result -- most likely the in-worktree test run is taking the tick down. Handing this to you rather than loop on it." 2>/dev/null \
        || log "warning: rework-crash escalation comment failed on ${REVIEW_KEY}"
      forgejo_unassign_all "$PR_REPO" "$PR_NUMBER" 2>/dev/null || true
      forgejo_assign "$PR_REPO" "$PR_NUMBER" "$FORGEJO_REVIEWER" 2>/dev/null || true
      review_set_rework_crashes "$REVIEW_KEY" 0
      exit 0
    fi
    # Stamp this attempt up front so a mid-rework crash is counted (the reset only
    # fires on a clean return past the claude call).
    review_set_rework_crashes "$REVIEW_KEY" "$(( RC_CRASHES + 1 ))"

    ensure_repo_local "$PR_REPO"
    PR_REPO_PATH=$(repo_path_for "$PR_REPO")

    (cd "$PR_REPO_PATH" && git fetch origin --prune)

    PR_WORKTREE="$AGENT_STATE_DIR/worktrees/$(worktree_key "$PR_REPO" "pr${PR_NUMBER}")"
    if [ -e "$PR_WORKTREE" ]; then
      (cd "$PR_REPO_PATH" && git worktree remove --force "$PR_WORKTREE") 2>/dev/null || rm -rf "$PR_WORKTREE"
    fi
    # Free the branch if the main clone is parked on it. The ideation pipeline
    # pushes its PR by checking the branch out in the MAIN clone (not a
    # worktree), so the clone can be sitting on PR_HEAD -- and git refuses to
    # check out a branch that's already checked out elsewhere. Detach the clone
    # first, then prune any stale worktree registrations.
    PR_CLONE_BRANCH=$(cd "$PR_REPO_PATH" && git symbolic-ref --quiet --short HEAD 2>/dev/null) || PR_CLONE_BRANCH=""
    if [ "$PR_CLONE_BRANCH" = "$PR_HEAD" ]; then
      (cd "$PR_REPO_PATH" && git checkout --detach --quiet) 2>/dev/null || true
    fi
    (cd "$PR_REPO_PATH" && git worktree prune) 2>/dev/null || true
    # Non-fatal: a worktree-add failure must not crash the whole tick (it used
    # to exit 128 and take the service down). Skip this PR for the tick; the
    # next tick retries with the branch now freed.
    if ! (cd "$PR_REPO_PATH" && git worktree add -B "$PR_HEAD" "$PR_WORKTREE" "origin/${PR_HEAD}"); then
      log "PR-review: worktree add failed for ${PR_REPO}#${PR_NUMBER} on ${PR_HEAD} -- skipping this tick (will retry)"
      rm -rf "$PR_WORKTREE" 2>/dev/null || true
      exit 0
    fi
    init_igor_scratch "$PR_WORKTREE"

    # Stage the base branch INTO the PR branch before handing it over.
    #
    # A PR that was clean when opened can go un-mergeable after a sibling
    # PR merges to the base -- a purely textual conflict, no fault of this
    # branch (this is precisely how #189 landing turned #190 into a
    # conflict the moment it was merged). The reviewer's ask is then
    # "resolve the conflict with <base>" -- but the worktree is checked
    # out on origin/$PR_HEAD ALONE, so there is nothing in the tree to
    # resolve and the agent correctly no-ops (AGENTS.md 1b: nothing
    # actionable -> exit without commits). That is the no-op that wasted a
    # review round-trip.
    #
    # So bring <base> in HERE, before the agent sees the tree:
    #   - clean merge (or already current) -> the branch is now up to date
    #     with base; any merge commit is a real change to push, not a no-op.
    #   - conflict -> leave the merge IN PROGRESS, markers and all, and the
    #     prompt (below) tells the agent it is mid-merge with real conflicts
    #     to resolve. The fail-closed marker gate before push backstops a
    #     botched resolution.
    # origin/$PR_BASE is current: ensure_repo_local + the fetch above
    # refreshed it, and the worktree shares the clone's object store.
    PR_MERGE_CONFLICT=""
    if [ -n "$PR_BASE" ]; then
      if (cd "$PR_WORKTREE" && git merge --no-edit "origin/${PR_BASE}" >/dev/null 2>&1); then
        log "PR-review: staged origin/${PR_BASE} into ${PR_HEAD} cleanly (or already current)"
      else
        PR_MERGE_CONFLICT=$(cd "$PR_WORKTREE" \
          && git diff --name-only --diff-filter=U 2>/dev/null | paste -sd ' ' -)
        log "PR-review: ${PR_HEAD} conflicts with origin/${PR_BASE} -- merge left in progress for the agent (conflicted: ${PR_MERGE_CONFLICT:-unknown})"
      fi
    fi

    # Fetch comments defensively -- a 404 on any endpoint shouldn't
    # kill the tick; just treat as no-comments.
    #
    # Three sources of reviewer signal, all need to be passed to
    # Claude:
    #   1. Issue-level comments (the "Conversation" tab text)
    #   2. Inline review comments (file/line-tied)
    #   3. Review BODIES -- the summary text attached to a formal
    #      review verdict (APPROVED / REQUEST_CHANGES / COMMENT).
    #      Forgejo's "Request changes" UI puts the reviewer's main
    #      message HERE, not in issue-level comments. Missing this
    #      = Claude sees "no comments" and exits without action.
    PR_ISSUE_RAW=$(forgejo_pr_comments "$PR_REPO" "$PR_NUMBER" 2>/dev/null || echo '[]')
    PR_INLINE_RAW=$(forgejo_pr_review_comments "$PR_REPO" "$PR_NUMBER" 2>/dev/null || echo '[]')
    PR_REVIEWS_RAW=$(forgejo_pr_non_bot_reviews "$PR_REPO" "$PR_NUMBER" "$BOT_USER" 2>/dev/null || echo '[]')

    PR_ISSUE_COMMENTS=$(jq -r --arg me "$BOT_USER" '
        [.[] | select(.user.login != $me)
          | "**" + (.user.login // "?") + "** (" + (.created_at // "") + "):\n\n" + (.body // "")]
        | join("\n\n---\n\n")' <<<"$PR_ISSUE_RAW" 2>/dev/null || echo "")
    PR_INLINE_COMMENTS=$(jq -r --arg me "$BOT_USER" '
        [.[] | select(.user.login != $me)
          | "**" + (.user.login // "?") + "** on `" + (.path // "?") + "`"
            + (if .original_line then " line " + (.original_line|tostring) else "" end)
            + " (" + (.created_at // "") + "):\n\n" + (.body // "")]
        | join("\n\n---\n\n")' <<<"$PR_INLINE_RAW" 2>/dev/null || echo "")
    # Review bodies: only include reviews that have a non-empty body
    # (a review with state but no comment is just an approval click).
    PR_REVIEW_BODIES=$(jq -r '
        [.[] | select((.body // "") | length > 0)
          | "**" + (.user.login // "?") + "** "
            + "(state: " + (.state // "?") + ", "
            + (.submitted_at // "") + "):\n\n"
            + (.body // "")]
        | join("\n\n---\n\n")' <<<"$PR_REVIEWS_RAW" 2>/dev/null || echo "")

    log "PR-review: ${#PR_ISSUE_COMMENTS} chars of issue comments, ${#PR_INLINE_COMMENTS} chars of inline review, ${#PR_REVIEW_BODIES} chars of review bodies"

    # When the harness staged a base merge that conflicted, the worktree
    # is mid-merge with real markers right now. Tell the agent so it does
    # NOT mistake a present conflict for the "nothing actionable" case.
    PR_MERGE_CONFLICT_MSG=""
    if [ -n "$PR_MERGE_CONFLICT" ]; then
      PR_MERGE_CONFLICT_MSG=$(cat <<CONFLICT_EOF

## RESOLVE THE MERGE CONFLICT FIRST (this is real, actionable work)

This PR went stale: the base branch (${PR_BASE}) moved after you opened
it -- almost certainly a sibling PR merged and edited the same lines. The
harness has ALREADY started the merge of origin/${PR_BASE} into your
branch and it conflicts. The conflicts are live in your working tree
RIGHT NOW -- run \`git status\` and you will see this merge in progress.
Conflicted files: ${PR_MERGE_CONFLICT}.

This is your PRIMARY task and it IS actionable -- do not treat it as
"nothing to change." Open each conflicted file, combine BOTH sides'
intent (keep both changes; do not just pick one side and do not drop
either), remove every conflict marker, make the project tests + lint
pass, then commit to complete the merge. The harness runs a fail-closed
check and will REFUSE to push if any conflict marker survives, so leaving
markers in just bounces the PR straight back.
CONFLICT_EOF
)
    fi

    # v16 goodie (igor#415): if the PR head's CI is RED, pull the failing Actions
    # job-log tails into the rework prompt so the agent fixes the build, not just
    # the review comments. Empty (no-op) when CI is green or on pre-v16 Forgejo,
    # so it's safe to build unconditionally. Mirrors the PR_MERGE_CONFLICT_MSG
    # pattern -- interpolated as a bare line in both heredoc branches below.
    PR_CI_FAILURE_MSG=$(forgejo_failing_ci_logs "$PR_REPO" "$PR_HEAD_SHA")

    if [ -n "$BINDING_RC_BODY" ]; then
      PR_USER_MSG=$(cat <<EOF
You opened PR ${PR_REPO}#${PR_NUMBER}: ${PR_TITLE}

The reviewer (Igor's automated review pass) requested changes to this PR.
Address the requested changes listed below with new commits on this branch (${PR_HEAD}),
then exit. The harness will push your commits and the reviewer will re-review
the new head automatically. The human is only brought in on APPROVE or after 3 rework
rounds without convergence.

If the requested changes are not actionable -- a fundamental design disagreement,
unclear requirements, or something you need the human to weigh in on -- exit without
commits. The harness will escalate to the human reviewer.
${PR_MERGE_CONFLICT_MSG}
${PR_CI_FAILURE_MSG}

Base: ${PR_BASE}
Branch: ${PR_HEAD}

PR body:
${PR_BODY}

## Requested changes (reviewer)

${BINDING_RC_BODY}

## Issue-level comments (the Conversation tab)

${PR_ISSUE_COMMENTS:-(no issue-level comments on this PR)}

## Inline review comments (file/line-tied)

${PR_INLINE_COMMENTS:-(no inline review comments on this PR)}

## How to address review feedback

**MAKE SURGICAL EDITS, NOT REWRITES.** This PR exists to refine,
not to restart. Each review comment is a targeted ask: incorporate
the reviewer's specific information into the relevant spot. Don't
restructure, simplify, or delete surrounding content beyond what
the comment directly addresses.

Same rules as PR mode (AGENTS.md): TDD where the repo supports it,
project tests + lint must pass before exit, /security-review on your
diff. Stay on this branch. Do not open a new PR -- this one already
exists.
EOF
)
    else
      PR_USER_MSG=$(cat <<EOF
You opened PR ${PR_REPO}#${PR_NUMBER}: ${PR_TITLE}

The human reviewer assigned the PR back to you for revisions. Read
the comments below, decide what is actionable, address them with new
commits on this branch (${PR_HEAD}), and exit. The harness will push
your commits and request the reviewer's review again (the PR is left
unassigned -- assigned-to-you means it's your turn, unassigned means
it's back in the human's court).
${PR_MERGE_CONFLICT_MSG}
${PR_CI_FAILURE_MSG}

If you genuinely have nothing to change -- for example the comments
were questions you can answer in a reply rather than code, or the
feedback is a "ship it" -- post a comment with your reply using
\`forgejo_comment\` semantics is not available; instead just exit
without commits and the harness will request review again with a note
that no changes were made. The human will close the loop manually.

Base: ${PR_BASE}
Branch: ${PR_HEAD}

PR body:
${PR_BODY}

## Review summaries (Forgejo "Request changes" / "Approve" / "Comment" verdicts)

These are the formal review bodies attached to a state change.
If a reviewer hit "Request changes" with a comment, the comment
is HERE (not in issue-level comments below). Address what's
actionable in these first.

${PR_REVIEW_BODIES:-(no formal review bodies on this PR)}

## Issue-level comments (the Conversation tab)

${PR_ISSUE_COMMENTS:-(no issue-level comments on this PR)}

## Inline review comments (file/line-tied)

${PR_INLINE_COMMENTS:-(no inline review comments on this PR)}

## How to address review feedback

**MAKE SURGICAL EDITS, NOT REWRITES.** This PR exists to refine,
not to restart. Each review comment is a targeted ask: incorporate
the reviewer's specific information into the relevant spot. Don't
restructure, simplify, or delete surrounding content beyond what
the comment directly addresses.

Examples of the right and wrong shape:

- Reviewer corrects "the NUC runs everything" -> "actually
  Forgejo is on a separate VPS, the NUC is just for the agent + base
  Linux."

  RIGHT: change the paragraph to describe the actual layout
  (4 boxes: NUC, web server VPS, Forgejo VPS, Forgejo runner
  VPS). Keep the surrounding texture about it being a physical
  box, the "I live on hardware" framing, etc.

  WRONG: delete the paragraph and replace with "Two boxes."

- Reviewer says "this section's tone is off."

  RIGHT: rewrite the section to fix the tone, keeping the
  same information.

  WRONG: delete the section.

When in doubt: prefer adding/correcting facts over removing
content. The reviewer can ask for further cuts in another round
if needed; over-deletion is hard to recover from.

Same rules as PR mode (AGENTS.md): TDD where the repo supports it,
project tests + lint must pass before exit, /security-review on your
diff. Stay on this branch. Do not open a new PR -- this one already
exists.
EOF
)
    fi

    PR_SYSTEM_PROMPT=$(issue_system_prompt)

    cd "$PR_WORKTREE"
    log "invoking claude for PR review (timeout ${TICK_TIMEOUT})"
    PR_LOG="$PR_WORKTREE/.agent/claude-output.log"
    PR_START=$(date +%s)
    # igor#308: escalate the rework effort each round (high -> xhigh -> max).
    # Cache the round once -- it can in principle move between reads.
    PR_REWORK_ROUND=$(review_rework_rounds "$REVIEW_KEY")
    PR_REWORK_EFFORT=$(worker_effort "$PR_REWORK_ROUND")
    log "PR-review: rework effort ${PR_REWORK_EFFORT} (round ${PR_REWORK_ROUND})"
    set +e
    claude_run_with_cost "pr-review" "$PR_LOG" "$TICK_TIMEOUT" \
      --model "$AGENT_MODEL_REVIEW" \
      --effort "$PR_REWORK_EFFORT" \
      --append-system-prompt "$PR_SYSTEM_PROMPT" \
      --settings "$AGENT_HOME/agent-settings.json" \
      --max-turns 100 \
      --print "$PR_USER_MSG"
    PR_EXIT=$?
    set -e
    PR_ELAPSED=$(( $(date +%s) - PR_START ))
    log "claude exited $PR_EXIT after ${PR_ELAPSED}s"
    # Clean return past the claude call -- the rework didn't take the tick down, so
    # clear the crash counter (the crash-loop break above only fires on repeated
    # mid-run deaths, not on an ordinary failed-but-completed rework).
    review_set_rework_crashes "$REVIEW_KEY" 0

    normalize_worktree_dashes "$PR_WORKTREE"

    cd "$PR_WORKTREE"

    # Harness-side auto-commit: if Claude made edits but forgot to
    # `git commit` (common -- the issue-work mode has the same
    # safety net), commit them ourselves with a derived subject.
    # Same pattern as issue-work: harness owns the procedural step,
    # Claude owns the content step.
    #
    # Excludes .agent/ (per-tick scratch, never committed).
    PR_DIRTY=$(git status --porcelain 2>/dev/null \
      | grep -vE '^.. \.agent/' \
      | head -c 1)
    if [ -n "$PR_DIRTY" ]; then
      log "PR-review: claude left dirty files in the worktree without committing -- harness committing"
      (cd "$PR_WORKTREE" && git add -A -- ':!.agent' 2>/dev/null) || true
      PR_AUTO_SUBJECT=$(derive_commit_subject \
        "$PR_WORKTREE/.agent/PR_BODY.md" \
        "$PR_WORKTREE" \
        "chore: PR-review revisions for ${PR_REPO}#${PR_NUMBER}")
      log "PR-review: harness-commit subject: $PR_AUTO_SUBJECT"
      (cd "$PR_WORKTREE" && git commit --quiet -m "$PR_AUTO_SUBJECT") \
        || log "warning: harness commit failed"
    fi

    PR_NEW=$(git rev-list --count "origin/${PR_HEAD}..HEAD" 2>/dev/null || echo 0)

    if [ "$PR_NEW" -gt 0 ]; then
      # igor#310: audit trail -- record this rework round (model + effort +
      # commits) on the PR so the ticket tells its own story, paired with the
      # review comments that log model+effort+verdict. One comment per round
      # reads as the journey: review -> rework -> review -> ...
      forgejo_comment "$PR_REPO" "$PR_NUMBER" \
"### 🔧 Rework — round ${PR_REWORK_ROUND} _(automated)_

Addressed the review on \`${AGENT_MODEL_REVIEW}\` at **effort ${PR_REWORK_EFFORT}** — ${PR_NEW} new commit(s).

<!-- audit:rework round=${PR_REWORK_ROUND} effort=${PR_REWORK_EFFORT} -->" 2>/dev/null \
        || log "warning: PR-review: rework audit comment failed on ${PR_REPO}#${PR_NUMBER}"

      # Conflict-marker gate before push. If the harness staged a base
      # merge and it conflicted, the agent (or the auto-commit above,
      # which `git add -A`s and completes a half-resolved merge) may have
      # committed literal markers into the resolution. Scanning the
      # committed delta catches that no matter who created the commit --
      # the exact shape that put <<<<<<< / ======= / >>>>>>> on master via
      # PR #191. Refuse it closed rather than ship broken code.
      PR_MARKERS=$(list_conflict_marker_violations "$PR_HEAD")
      if [ -n "$PR_MARKERS" ]; then
        log "PR-review: committed conflict markers detected, refusing push and bouncing back to $FORGEJO_REVIEWER"
        forgejo_comment "$PR_REPO" "$PR_NUMBER" \
          "The agent refused to push revisions: the new commits still contain unresolved conflict markers:

$(printf '%s\n' "$PR_MARKERS" | sed 's/^/    /')

Review requested so a human can resolve the conflict or re-trigger the agent." 2>/dev/null \
          || log "warning: comment failed on ${PR_REPO}#${PR_NUMBER}"
        forgejo_unassign_all "$PR_REPO" "$PR_NUMBER" 2>/dev/null || true
        forgejo_request_review "$PR_REPO" "$PR_NUMBER" "$FORGEJO_REVIEWER" 2>/dev/null || true
        (cd "$PR_REPO_PATH" && git worktree remove --force "$PR_WORKTREE") 2>/dev/null || true
        exit 0
      fi

      # Off-limits guard before push -- CI workflows shouldn't be
      # touched even in a review round-trip.
      PR_OFFLIMITS=$(list_offlimits_violations "$PR_HEAD")
      if [ -n "$PR_OFFLIMITS" ]; then
        log "PR-review: off-limits files modified, refusing push and bouncing back to $FORGEJO_REVIEWER"
        log "off-limits paths touched: $(echo "$PR_OFFLIMITS" | tr '\n' ' ')"
        forgejo_comment "$PR_REPO" "$PR_NUMBER" \
          "The agent refused to push revisions: the new commits modify CI workflow files, which are off-limits. Paths touched:

  - ${PR_OFFLIMITS//$'\n'/$'\n'  - }

Review requested so a human can review/discard." 2>/dev/null \
          || log "warning: comment failed on ${PR_REPO}#${PR_NUMBER}"
        forgejo_unassign_all "$PR_REPO" "$PR_NUMBER" 2>/dev/null || true
        forgejo_request_review "$PR_REPO" "$PR_NUMBER" "$FORGEJO_REVIEWER" 2>/dev/null || true
        (cd "$PR_REPO_PATH" && git worktree remove --force "$PR_WORKTREE") 2>/dev/null || true
        exit 0
      fi

      # Heartbeat before the security gate -- this is the second long
      # model call in the same tick (the rework claude_run_with_cost
      # above already ate up to TICK_TIMEOUT), so without this ping the
      # dead-man's-switch gap between heartbeats is the SUM of both
      # stages (~55m), not the longest single one (~30m). igor#360.
      hc_ping heartbeat
      # Security gate on the revision delta before pushing it back.
      if PR_SEC_FINDINGS=$(security_gate "$PR_WORKTREE" "$PR_HEAD" "security-gate-pr-review"); then
        :
      else
        log "PR-review: security review flagged the revisions, refusing push and bouncing back to $FORGEJO_REVIEWER"
        forgejo_comment "$PR_REPO" "$PR_NUMBER" \
          "The agent refused to push revisions: the harness security review flagged a material issue:

${PR_SEC_FINDINGS}

Review requested so a human can review/discard." 2>/dev/null \
          || log "warning: comment failed on ${PR_REPO}#${PR_NUMBER}"
        forgejo_unassign_all "$PR_REPO" "$PR_NUMBER" 2>/dev/null || true
        forgejo_request_review "$PR_REPO" "$PR_NUMBER" "$FORGEJO_REVIEWER" 2>/dev/null || true
        (cd "$PR_REPO_PATH" && git worktree remove --force "$PR_WORKTREE") 2>/dev/null || true
        exit 0
      fi

      # A failed push -- commonly a non-fast-forward because the remote branch
      # advanced after we checked it out -- must NOT be treated as a completed
      # rework. Clearing the rework state on a failed push silently drops the
      # work AND the round: the committed rework only lives in this (about-to-be-
      # removed) worktree, the remote head is unchanged, yet pending_rc_body gets
      # cleared and the PR unassigned (igor#301). So gate ALL the "rework landed"
      # bookkeeping on a CONFIRMED push. On failure, leave the bot assigned and
      # pending_rc_body intact; the next tick re-attempts the rework against the
      # now-current remote head. (A push is in an `if` condition, so set -e does
      # not abort on the rejection.)
      if git push origin "$PR_HEAD"; then
        forgejo_unassign_all "$PR_REPO" "$PR_NUMBER" 2>/dev/null \
          || log "warning: unassign failed on ${PR_REPO}#${PR_NUMBER}"
        if [ -n "$BINDING_RC_BODY" ]; then
          # Binding-flow rework: clear pending_rc_body and let do_review_tick
          # re-review the new head. The changed head means a new patch-id,
          # so the review fires next tick. Do NOT request the human.
          review_set_pending_rc_body "$REVIEW_KEY" ""
          log "PR-review: binding rework pushed -- cleared pending_rc_body, do_review_tick will re-review"
        else
          log "PR-review: pushing $PR_NEW new commits and requesting review from $FORGEJO_REVIEWER"
          forgejo_request_review "$PR_REPO" "$PR_NUMBER" "$FORGEJO_REVIEWER" 2>/dev/null \
            || log "warning: review-request-to-${FORGEJO_REVIEWER} failed on ${PR_REPO}#${PR_NUMBER}"
        fi
      else
        log "PR-review: rework push REJECTED on ${PR_REPO}#${PR_NUMBER} (remote advanced -- non-fast-forward); leaving the bot assigned + pending_rc_body intact so the next tick retries against the current head"
      fi
    else
      log "PR-review: no commits made -- requesting review from $FORGEJO_REVIEWER with a note"
      forgejo_comment "$PR_REPO" "$PR_NUMBER" \
        "The agent reopened this PR after reassignment but didn't make any new commits. Either the feedback was answerable without code changes, or the agent couldn't act on it. Review requested so a human can close the loop." 2>/dev/null \
        || log "warning: comment failed on ${PR_REPO}#${PR_NUMBER}"
      forgejo_unassign_all "$PR_REPO" "$PR_NUMBER" 2>/dev/null \
        || log "warning: unassign failed on ${PR_REPO}#${PR_NUMBER}"
      if [ -n "$BINDING_RC_BODY" ]; then
        # Binding-flow rework produced no commits: clear the pending body and
        # escalate to the human as a safety valve (the agent couldn't act).
        review_set_pending_rc_body "$REVIEW_KEY" ""
        forgejo_request_review "$PR_REPO" "$PR_NUMBER" "$FORGEJO_REVIEWER" 2>/dev/null \
          || log "warning: review-request-to-${FORGEJO_REVIEWER} failed on ${PR_REPO}#${PR_NUMBER} (no-commit binding rework)"
        log "PR-review: binding rework produced no commits -- escalating to ${FORGEJO_REVIEWER}"
      else
        forgejo_request_review "$PR_REPO" "$PR_NUMBER" "$FORGEJO_REVIEWER" 2>/dev/null \
          || log "warning: review-request-to-${FORGEJO_REVIEWER} failed on ${PR_REPO}#${PR_NUMBER}"
      fi
    fi

    if forgejo_log_time "$PR_REPO" "$PR_NUMBER" "$PR_ELAPSED"; then
      log "time logged: ${PR_ELAPSED}s on ${PR_REPO}#${PR_NUMBER}"
    else
      log "warning: could not log time on ${PR_REPO}#${PR_NUMBER}"
    fi

    (cd "$PR_REPO_PATH" && git worktree remove --force "$PR_WORKTREE") 2>/dev/null || true

    exit 0
fi

# -- Igor's own work + scheduled maintenance -------------------
#
# Reached only when no PR-review was picked up. Strictly ordered,
# fire-one-then-exit: each slot that's still pending today/this week
# fires, then the tick exits (one piece of work per tick). Only when
# every Igor slot AND maintenance is already done do we fall through
# to the claimable-issue grind below.
#
# Daily slots (reading, post): once per local day, reset at midnight
# by slot_rollover. Weekly slots (now, site-work) and maintenance:
# once per ISO week (Monday-anchored, self-healing if a Monday tick
# is missed). The post slot is special: it stays open and retries
# every tick until a post actually ships today, up to POST_MAX_ATTEMPTS
# so a wedged pipeline can't starve the ticket grind all day.

if [ -n "$WEBSITE_REPO" ]; then
  slot_rollover

  if ! slot_is_done reading; then
    log "slot: reading"
    "$AGENT_HOME/bin/reading-pipeline.sh" --live \
      || log "warning: reading-pipeline exited rc=$?"
    slot_mark_done reading
    exit 0
  fi

  if ! slot_is_done post; then
    log "slot: post"
    "$AGENT_HOME/bin/ideation-pipeline.sh" --live \
      || log "warning: ideation-pipeline exited rc=$?"
    if post_shipped_today; then
      log "slot: post shipped today -- marking done"
      slot_mark_done post
    else
      POST_ATTEMPTS=$(slot_attempt_inc post)
      if [ "$POST_ATTEMPTS" -ge "$POST_MAX_ATTEMPTS" ]; then
        log "WARNING: post slot reached ${POST_ATTEMPTS}/${POST_MAX_ATTEMPTS} attempts with no post shipped today -- marking done and moving on (investigate the ideation pipeline)"
        slot_mark_done post
      else
        log "slot: post not shipped (attempt ${POST_ATTEMPTS}/${POST_MAX_ATTEMPTS}) -- leaving slot open to retry next tick"
      fi
    fi
    exit 0
  fi

  if ! weekly_done now; then
    log "slot: now (weekly /now refresh)"
    NOW_DIGEST=$(build_now_digest) || NOW_DIGEST=""
    export NOW_DIGEST
    if "$AGENT_HOME/bin/site-work-block.sh" --directive now --live; then
      weekly_mark_done now
    else
      sw_rc=$?
      log "warning: now pass exited rc=$sw_rc -- leaving weekly slot open for retry"
    fi
    unset NOW_DIGEST
    exit 0
  fi

  if ! weekly_done site-work; then
    log "slot: site-work (weekly site pass)"
    if "$AGENT_HOME/bin/site-work-block.sh" --directive site-work --live; then
      weekly_mark_done site-work
    else
      sw_rc=$?
      log "warning: site-work pass exited rc=$sw_rc -- leaving weekly slot open for retry"
    fi
    exit 0
  fi
fi

# Shadow code review (non-binding PR verdicts; no env knob -- runs like
# logwatch). Sits below the health gate (it's a model call) and after Igor's own
# slotted work, before maintenance: a blocking human review is more
# time-sensitive than the dep-freshness grind, but Igor shipping his
# daily post still comes first. Posts ONE non-binding verdict per tick
# on an un-reviewed bot-PR head, then exits like any other pass. Never
# merges or pushes -- comment only.
if do_review_tick; then
  exit 0
fi

# Scheduled maintenance/analysis (weekly dep-freshness + security
# audit). Read-only, so it runs on EVERY bot-accessible repo (the
# analysis set), not just the validated work set -- validation gates
# work, not analysis. Repo-agnostic; runs even without a website
# configured. Runs after Igor's own work, before the claimable-issue
# grind. Loops every repo eligible this ISO week in one pass and exits;
# nothing eligible -> fall through to discovery.
if do_maintenance_tick; then
  exit 0
fi

# Scheduled SEO analysis (monthly, ONE domain per tick). Opt-in via the
# Google Search Console + SMTP2GO + PRIMARY_RECIPIENTS env; no-ops when
# unconfigured. GSC-driven, not repo-driven: emails the owner a graded
# report per domain, and for agentic sites files a deduped Agent-labeled
# ticket the discovery step below picks up once that repo is validated.
# One domain per tick spreads the GSC/email load across the 1-min beat.
if do_seo_tick; then
  exit 0
fi

# Daily fleet ship-report. Scripted (no model), so it ALSO runs in the
# health-blocked branch above -- it sends even during a Claude cooldown. Opt-in
# via PRIMARY_RECIPIENTS + SMTP2GO; no-ops before 07:00 local or once today's
# already sent. Once-daily; the safety valve for shadow-review auto-merge.
if do_shipreport_tick; then
  exit 0
fi

# Daily sports digest (7 days a week, first tick after 03:00 -- by
# then even west-coast games are final and recapped). Opt-in via
# SPORTS_RECIPIENTS + SPORTS_LEAGUES + SMTP2GO; no-ops when
# unconfigured or once today's already sent. ESPN fetch is scripted,
# but the distill is a model call -- so unlike the scripted SEO pass this
# one sits below the health gate and goes dark with the rest of the model
# work during a cooldown.
if do_sports_tick; then
  exit 0
fi

# Weekly CEO board digest. Convention opt-in, no env knob: any
# analysis-set repo carrying a CEO.md mandate is under CEO
# management (the mandate's presence IS the opt-in). Once per ISO week
# per repo, it reads the mandate + gathers the week and emails a board
# digest to CEO_RECIPIENTS. A model call, so it's below the health gate;
# Phase 1 is read-only (no issue-filing/steering yet).
if do_ceo_tick; then
  exit 0
fi

# Player-feedback triage: one CSV row per tick on repos whose agent.json declares
# .feedback.csv. Model work, so it sits below the health gate with the other
# model passes; files an UNLABELED issue for the human to greenlight (or drops a
# spam/dupe/already-worked row). See lib/feedback.sh.
if do_feedback_tick; then
  exit 0
fi

# Hourly logwatch sweep (once per clock hour, reviewing the hour that
# just closed -- always a complete window, no midnight gate).
# Convention-driven, no env knob: every bot-accessible repo declaring
# systemd/*.service gets each unit's local past-hour journal reviewed
# (one review-tier call per unit with entries; empty journal = runs
# elsewhere or didn't run = skip). Hard-failure tickets land on the owning repo unlabeled and
# assigned to FORGEJO_REVIEWER -- the human triages by adding the
# Agent label (that's the gate; an Agent-labeled ticket still assigned
# to the reviewer is claimable, so unassigning is optional).
if do_logwatch_tick; then
  exit 0
fi

# Deferred-ticket pass: work gated on an external data source. Convention opt-in,
# no env knob -- an OPEN issue carrying a <!-- gate --> block AND the built-in
# Status/Blocked label (the grind already skips Status/Blocked, so nothing works it
# early -- no custom label). Once per ISO day per ticket it fetches the gate's url
# and asks (tool-free) whether the condition is now met; on MET it removes
# Status/Blocked + the Agent greenlight and assigns the ticket to the reviewer for
# confirmation (the check can false-positive, so it isn't auto-worked). A model
# call, so below the health gate; fails CLOSED. See lib/deferred.sh.
if do_deferred_tick; then
  exit 0
fi

# -- Discovery: find globally oldest claimable -----------------
#
# Iterates VALIDATED_REPOS_JSON (built by the validation sweep at
# the top of the cascade). Repos that failed validation are already
# excluded; no need to re-validate here.

REPO_COUNT=$(grep -c '^{' <<<"$VALIDATED_REPOS_JSON" || true)
log "scanning $REPO_COUNT validated repo(s) for claimable work"

WINNER=""
WINNER_REPO=""
WINNER_PR_BASE=""
WINNER_CREATED=""

while IFS= read -r repo_line; do
  [ -z "$repo_line" ] && continue
  R_NAME=$(jq -r '.full_name' <<<"$repo_line")
  R_BASE=$(jq -r '.default_branch' <<<"$repo_line")
  R_PATH=$(repo_path_for "$R_NAME")

  # Iterate candidate issues for this repo (oldest first). The first
  # one that's actually claimable (not in flight, not over the
  # rejected-PR strike count) becomes this repo's contender against
  # other repos' contenders.
  CANDIDATES=$(forgejo_find_claimable "$R_NAME" "${FORGEJO_REVIEWER:-}" || echo '[]')
  REPO_CONTENDER=""
  while read -r candidate; do
    [ -z "$candidate" ] && continue
    C_NUM=$(jq -r .number <<<"$candidate")

    C_HISTORY=$(forgejo_bot_prs_for_issue "$R_NAME" "$C_NUM" "$BOT_USER" 2>/dev/null || echo '[]')
    # An open bot PR normally means work in flight -> skip. EXCEPT a WIP
    # checkpoint draft (turn-cap snapshot): that IS this issue, paused
    # mid-flight, and must be RESUMED, not skipped -- so it stays claimable.
    C_OPEN=$(jq --arg wip "$CHECKPOINT_WIP_PREFIX" \
      '[.[] | select(.state == "open" and ((.title // "") | startswith($wip) | not))] | length' \
      <<<"$C_HISTORY")
    if [ "$C_OPEN" -gt 0 ]; then
      log "skipping ${R_NAME}#${C_NUM} -- open bot PR (in flight)"
      continue
    fi
    C_REJECTED=$(jq '[.[] | select(.state == "closed" and .merged == false)] | length' <<<"$C_HISTORY")
    if [ "$C_REJECTED" -ge 2 ]; then
      log "skipping ${R_NAME}#${C_NUM} -- ${C_REJECTED} rejected bot PRs, applying Status/Blocked"
      forgejo_add_label "$R_NAME" "$C_NUM" "Status/Blocked" 2>/dev/null \
        || log "warning: could not apply Status/Blocked on ${R_NAME}#${C_NUM}"
      if [ -n "${FORGEJO_REVIEWER:-}" ]; then
        forgejo_assign "$R_NAME" "$C_NUM" "$FORGEJO_REVIEWER" 2>/dev/null \
          || log "warning: could not assign ${R_NAME}#${C_NUM} to $FORGEJO_REVIEWER"
      fi
      forgejo_comment "$R_NAME" "$C_NUM" \
        "The agent opened ${C_REJECTED} PRs for this issue, all closed without merging. Probably needs a different approach or more context. Status/Blocked applied; investigate and remove the label to re-queue." 2>/dev/null \
        || log "warning: could not comment on ${R_NAME}#${C_NUM}"
      continue
    fi
    # First passing candidate wins for this repo.
    REPO_CONTENDER="$candidate"
    break
  done < <(jq -c '.[]' <<<"$CANDIDATES")

  [ -n "$REPO_CONTENDER" ] || continue
  CREATED=$(jq -r '.created_at' <<<"$REPO_CONTENDER")
  if [ -z "$WINNER" ] || [[ "$CREATED" < "$WINNER_CREATED" ]]; then
    WINNER="$REPO_CONTENDER"
    WINNER_REPO="$R_NAME"
    WINNER_PR_BASE="$R_BASE"
    WINNER_CREATED="$CREATED"
  fi
done <<<"$VALIDATED_REPOS_JSON"

# -- No claimable work -> idle ---------------------------------
#
# Igor's own discretionary work (reading, post, /now, site-work) and
# scheduled maintenance already ran above, before discovery. If
# discovery also came up empty, there's genuinely nothing to do this
# tick.

if [ -z "$WINNER" ]; then
  log "no claimable work across any repo -- idle"
  exit 0
fi

FORGEJO_REPO="$WINNER_REPO"
PR_BASE="$WINNER_PR_BASE"
REPO_PATH=$(repo_path_for "$FORGEJO_REPO")

ISSUE_NUMBER=$(jq -r .number <<<"$WINNER")
ISSUE_TITLE=$(jq -r .title <<<"$WINNER")
ISSUE_BODY=$(jq -r '.body // ""' <<<"$WINNER")
ISSUE_LABELS=$(jq -r '[.labels[].name] | join(", ")' <<<"$WINNER")

SLUG=$(slugify "$ISSUE_TITLE")
if [ -n "$SLUG" ]; then
  BRANCH="agent/${ISSUE_NUMBER}-${SLUG}"
else
  BRANCH="agent/${ISSUE_NUMBER}"
fi

# -- Resume detection (turn-cap checkpoint) --------------------
# An open WIP checkpoint PR means a prior tick hit the turn cap and snapshotted
# its work-in-progress. Resume from that branch (Claude continues) instead of
# starting the issue over from the base. The WIP PR's head ref is authoritative
# for the branch name (in case the title-slug derivation ever changes). See
# lib/checkpoint.sh.
IS_RESUME=0; RESUME_PR=""; CHECKPOINT_N=0
CP_HISTORY=$(forgejo_bot_prs_for_issue "$FORGEJO_REPO" "$ISSUE_NUMBER" "$BOT_USER" 2>/dev/null || echo '[]')
RESUME_PR=$(jq -r --arg wip "$CHECKPOINT_WIP_PREFIX" \
  '[.[] | select(.state == "open" and ((.title // "") | startswith($wip)))] | first | .number // empty' \
  <<<"$CP_HISTORY" 2>/dev/null || echo "")
if [ -n "$RESUME_PR" ]; then
  IS_RESUME=1
  RESUME_OBJ=$(forgejo_get_pr "$FORGEJO_REPO" "$RESUME_PR" 2>/dev/null || echo '{}')
  RESUME_HEAD=$(jq -r '.head.ref // empty' <<<"$RESUME_OBJ")
  [ -n "$RESUME_HEAD" ] && BRANCH="$RESUME_HEAD"
  CHECKPOINT_N=$(checkpoint_read_count "$(jq -r '.body // ""' <<<"$RESUME_OBJ")")
fi

log "claiming ${FORGEJO_REPO}#${ISSUE_NUMBER}: ${ISSUE_TITLE}"
if [ "$IS_RESUME" = "1" ]; then
  log "branch: ${BRANCH} (RESUMING WIP checkpoint PR #${RESUME_PR}, checkpoint ${CHECKPOINT_N}/${CHECKPOINT_MAX})"
else
  log "branch: ${BRANCH}"
fi

# Export the tier-1 issue context so agent-block.sh / agent-report.sh
# can find the current issue. BOT_USER and FORGEJO_REVIEWER are
# exported earlier (right after bot-identity resolution) so they're
# available to agent-ask.sh from any tick shape (tier-1, tier-3,
# PR-review, maintenance). PATH is set at the top of the script so
# all Claude invocations -- not just tier-1 -- find the harness bin.
export ISSUE_NUMBER ISSUE_TITLE FORGEJO_REPO PR_BASE

# -- Cleanup on exit is installed EARLY (near the top, right after the bot-identity
# -- exports) so the PR-review/rework + maintenance stages above are covered too,
# -- not just issue-work below. WORKTREE was already initialized there; nothing to
# -- re-install here.

# -- Claim -----------------------------------------------------

forgejo_assign "$FORGEJO_REPO" "$ISSUE_NUMBER" "$BOT_USER"

# -- Clone if needed -------------------------------------------

if [ ! -d "$REPO_PATH/.git" ]; then
  CLONE_URL="$(ssh_clone_url "$FORGEJO_REPO")"
  log "cloning $CLONE_URL -> $REPO_PATH"
  mkdir -p "$(dirname "$REPO_PATH")"
  if ! git clone "$CLONE_URL" "$REPO_PATH"; then
    log "clone failed, blocking"
    agent-block.sh "The agent could not clone \`$CLONE_URL\`. Verify the bot user has SSH access to this repo and try again."
    exit 0
  fi
fi

# -- Preflight -------------------------------------------------
#
# CLAUDE.md must exist on the ref we actually branch from
# (origin/$PR_BASE) -- NOT the clone's working tree. The clone is a
# fetch-only anchor: nothing ever checks it out again, so a repo cloned
# before its CLAUDE.md landed keeps a stale tree forever and reading the
# tree here falsely blocks it -- the repo DOES have CLAUDE.md on its
# default branch (it passes API validation, and the worktree below is
# carved from origin/$PR_BASE, which is current). Fetch first so the
# check sees current remote state; on a fetch failure fall back to the
# last-known origin ref (still better than the local checkout).
git -C "$REPO_PATH" fetch origin --prune --quiet \
  || log "preflight: warning -- fetch failed; checking last-known origin/${PR_BASE}"
if ! git -C "$REPO_PATH" cat-file -e "origin/${PR_BASE}:CLAUDE.md" 2>/dev/null; then
  log "preflight: missing CLAUDE.md on origin/${PR_BASE}, blocking"
  agent-block.sh "The agent cannot work this repo: \`CLAUDE.md\` is missing at the repo root.

The agent relies on \`CLAUDE.md\` for project conventions (test commands, code style, gotchas). Add one, remove \`Status/Blocked\`, and the next tick will re-claim this issue."
  exit 0
fi

# -- Worktree --------------------------------------------------

mkdir -p "$AGENT_STATE_DIR/worktrees"
WORKTREE="$AGENT_STATE_DIR/worktrees/$(worktree_key "$FORGEJO_REPO" "$ISSUE_NUMBER")"

# Recovery should have cleared any stale path; this is a belt-and-braces check.
if [ -e "$WORKTREE" ]; then
  log "stale worktree at $WORKTREE -- aborting"
  forgejo_unassign_all "$FORGEJO_REPO" "$ISSUE_NUMBER"
  forgejo_comment "$FORGEJO_REPO" "$ISSUE_NUMBER" \
    "The agent aborted: stale worktree from a previous run was present at \`$WORKTREE\`. Investigate and clear before retrying."
  WORKTREE=""
  exit 4
fi

cd "$REPO_PATH"
# (origin refs already refreshed by the preflight fetch above)
# -B (not -b) + prune: an orphaned prior tick can leave the branch behind, and
# plain `-b` dies fatal (exit 255/EXCEPTION) on that collision -- crashing the
# whole unit on a recoverable condition. -B reuses/resets the leftover branch to
# the base; prune clears stale worktree registrations. The stale worktree *path*
# is already guarded above; this guards the stale *branch* (matches the -B used
# by the PR-rework and site-work worktree paths).
git worktree prune 2>/dev/null || true
# On resume, carve from the checkpoint branch (which holds the committed WIP) so
# Claude continues rather than starting over. The preflight fetch above already
# refreshed origin/$BRANCH. If the branch vanished (deleted/merged out of band),
# fall back to a fresh start from the base and drop the resume flag.
if [ "$IS_RESUME" = "1" ] && git rev-parse --verify --quiet "refs/remotes/origin/${BRANCH}" >/dev/null 2>&1; then
  git worktree add -B "$BRANCH" "$WORKTREE" "origin/${BRANCH}"
  log "worktree: resuming on origin/${BRANCH}"
else
  [ "$IS_RESUME" = "1" ] && { log "resume: origin/${BRANCH} gone -- starting fresh from ${PR_BASE}"; IS_RESUME=0; CHECKPOINT_N=0; RESUME_PR=""; }
  git worktree add -B "$BRANCH" "$WORKTREE" "origin/${PR_BASE}"
fi
init_igor_scratch "$WORKTREE"

# -- Invoke Claude ---------------------------------------------

cd "$WORKTREE"

# System prompt: voice anchor + slim AGENTS.md (issue-work-
# specific). Per-repo CLAUDE.md is auto-loaded by Claude Code
# from the worktree root.
SYSTEM_PROMPT=$(issue_system_prompt)

USER_MSG=$(cat <<EOF
You are working Forgejo issue #${ISSUE_NUMBER} in ${FORGEJO_REPO}.

Title: ${ISSUE_TITLE}
Labels: ${ISSUE_LABELS}

Body:
${ISSUE_BODY}
EOF
)

# On resume, tell Claude it's continuing paused work already committed on this
# branch -- not starting over. Its own prior progress is in the git history.
if [ "$IS_RESUME" = "1" ]; then
  USER_MSG="You are RESUMING work on this issue that you started earlier but did not finish -- the prior run hit its per-tick turn limit and its work-in-progress is ALREADY COMMITTED on this branch (\`${BRANCH}\`) and checked out in this worktree. Do NOT start over.

First run \`git log --oneline origin/${PR_BASE}..HEAD\` and \`git diff origin/${PR_BASE}...HEAD\` to see exactly what's already done, then continue from there toward completing the issue. Keep working on this same branch. When the issue is fully finished, make sure \`.agent/PR_BODY.md\` describes the WHOLE change (not just this session's part).

${USER_MSG}"
fi

log "invoking claude (timeout ${TICK_TIMEOUT})"
CLAUDE_LOG="$WORKTREE/.agent/claude-output.log"
START_TS=$(date +%s)
set +e
claude_run_with_cost "tier-1-issue" "$CLAUDE_LOG" "$TICK_TIMEOUT" \
  --model "$AGENT_MODEL" \
  --append-system-prompt "$SYSTEM_PROMPT" \
  --settings "$AGENT_HOME/agent-settings.json" \
  --max-turns 100 \
  --print "$USER_MSG"
CLAUDE_EXIT=$?
set -e
ELAPSED=$(( $(date +%s) - START_TS ))
log "claude exited $CLAUDE_EXIT (elapsed ${ELAPSED}s)"

normalize_worktree_dashes "$WORKTREE"

# Harness-owned commits: see derive_commit_subject + tier-3 comment.
# Auto-commit anything dirty outside .agent/ so Claude doesn't have
# to run git himself.
cd "$WORKTREE"

# Disposition of the worktree after the run (lib/checkpoint.sh):
#   commit     -- claude finished (exit 0): commit + finalize the PR
#   checkpoint -- turn cap hit, and either no stash or the stash was cleanly
#                 reconciled below: snapshot the WIP and resume next tick
#   discard    -- a real crash; or a turn-cap cut-off left with a `git stash`
#                 that could not be safely reconciled -> ship-safety discard
# The stash guard preserves the porksicle#114 invariant: a nonzero exit can mean
# the run died mid-workflow before restoring a `git stash` it took, so committing
# -A would ship a scratch tree OVER the stashed real edits. igor#411: that guard
# used to veto EVERY turn-cap checkpoint the instant a stash existed, discarding
# real green work over a stash that could simply be popped back in. On a
# confirmed turn cap we now attempt exactly that reconciliation first: a clean
# `git stash pop` merges the stash's content into the (already green) working
# tree, so the checkpoint commit captures both; a conflicted pop leaves the
# stash untouched and falls back to the original discard (the worktree is
# force-removed on exit regardless -- see `cleanup()` above -- so a tree left
# mid-conflict is harmless). The `:-1` default on CLAUDE_EXIT fails SAFE
# (unset/empty -> treated as nonzero).
CLAUDE_STREAM="$(dirname "$CLAUDE_LOG")/claude-stream.jsonl"
HIT_TURN_CAP=0; checkpoint_hit_turn_cap "$CLAUDE_STREAM" && HIT_TURN_CAP=1
HAS_STASH=0; [ -n "$(git stash list 2>/dev/null)" ] && HAS_STASH=1
STASH_RECONCILED=0
if [ "$HIT_TURN_CAP" = "1" ] && [ "$HAS_STASH" = "1" ]; then
  if git stash pop --quiet 2>/dev/null; then
    STASH_RECONCILED=1
    log "checkpoint: reconciled an outstanding git stash via 'git stash pop'"
  else
    log "checkpoint: git stash pop conflicted -- leaving it stashed, falling back to discard"
  fi
fi
DISPOSITION=$(checkpoint_decision "${CLAUDE_EXIT:-1}" "$HIT_TURN_CAP" "$HAS_STASH" "$STASH_RECONCILED")
log "disposition: $DISPOSITION (exit=${CLAUDE_EXIT:-?} turn_cap=${HIT_TURN_CAP} stash=${HAS_STASH} reconciled=${STASH_RECONCILED} resume=${IS_RESUME})"

DIRTY_PATHS=$(git status --porcelain 2>/dev/null \
  | awk '$2 !~ /^\.agent\// { print $2 }')
if [ -n "$DIRTY_PATHS" ]; then
  DIRTY_COUNT=$(echo "$DIRTY_PATHS" | wc -l | tr -d ' ')
  case "$DISPOSITION" in
    commit)
      # Stage first so derive_commit_subject can see new files via
      # `git diff --cached`. See tier-3 comment for the failure mode
      # without this.
      git add -A
      COMMIT_SUBJECT=$(derive_commit_subject "$WORKTREE/.agent/PR_BODY.md" "$WORKTREE" "chore: issue #${ISSUE_NUMBER} -- ${ISSUE_TITLE}")
      log "harness-commit: $DIRTY_COUNT file(s), subject: $COMMIT_SUBJECT"
      git commit --quiet -m "$COMMIT_SUBJECT" || log "warning: harness commit failed"
      ;;
    checkpoint)
      # Turn cap hit: snapshot the in-progress work as a WIP commit so it isn't
      # discarded. The checkpoint-routing block below pushes it + draft PR.
      git add -A
      log "checkpoint: turn cap hit -- snapshotting $DIRTY_COUNT dirty file(s) as WIP"
      git commit --quiet -m "WIP: issue #${ISSUE_NUMBER} checkpoint -- ${ISSUE_TITLE}" \
        || log "warning: checkpoint commit failed"
      ;;
    discard)
      log "ship-safety: claude exited ${CLAUDE_EXIT:-?} mid-run -- NOT committing partial worktree ($DIRTY_COUNT dirty file(s)); re-queuing"
      ;;
  esac
fi

# -- Checkpoint / resume routing (turn cap) --------------------
#
# A max-turns cut-off (or a crash mid-resume, where a prior checkpoint is
# already committed) does NOT run the normal ship gates -- the work is
# incomplete. It snapshots as a DRAFT ("WIP:") PR the review + merge loops skip,
# keeps the issue claimable, and resumes next tick. Both a checkpoint and a
# crash-mid-resume count against the resume budget; an exhausted budget escalates
# to the human instead of resuming forever. Only fires when there's committed
# work to preserve (COMMITS>0) -- a turn cap with zero commits is genuine no
# progress and falls through to the noop path. See lib/checkpoint.sh.
cd "$WORKTREE"
COMMITS=$(git rev-list --count "origin/${PR_BASE}..HEAD" 2>/dev/null || echo 0)

if { [ "$DISPOSITION" = "checkpoint" ] || { [ "$DISPOSITION" = "discard" ] && [ "$IS_RESUME" = "1" ]; }; } \
   && [ "$COMMITS" -gt 0 ]; then
  NEXT_N=$(( CHECKPOINT_N + 1 ))

  if [ "$DISPOSITION" = "checkpoint" ]; then
    # New snapshot commit -> push it. --force-with-lease: crash-retry safe, loud
    # if someone else moved the ref. On push failure, leave the worktree and
    # re-queue (the issue stays claimable; next tick retries).
    if ! git push --force-with-lease -u origin "$BRANCH"; then
      log "checkpoint: push failed on $BRANCH -- re-queuing (unassigning)"
      forgejo_unassign_all "$FORGEJO_REPO" "$ISSUE_NUMBER" 2>/dev/null || true
      exit 0
    fi
    log "checkpoint: pushed WIP snapshot to $BRANCH ($COMMITS commit(s))"
  else
    # discard + resume: no NEW commit this tick (HEAD == origin/$BRANCH already);
    # the prior checkpoint on the remote is preserved as-is. Nothing to push.
    log "checkpoint: crash during resume -- prior snapshot on $BRANCH preserved, not finalizing"
  fi

  # Ensure a draft (WIP) PR exists for the snapshot, then bump its counter.
  CP_PR="$RESUME_PR"
  [ -n "$CP_PR" ] || CP_PR=$(forgejo_find_pr_by_head "$FORGEJO_REPO" "$BRANCH")
  if [ -z "$CP_PR" ]; then
    CP_TITLE=$(checkpoint_wip_title "$(git log -1 --pretty=%s)")
    if [ -f .agent/PR_BODY.md ]; then
      CP_BODY=$(cat .agent/PR_BODY.md)
    else
      CP_BODY="Work-in-progress checkpoint. The agent hit its per-tick turn limit and snapshotted its progress here; it resumes automatically on the next tick. This PR is a draft (\`WIP:\`) -- the review and merge loops leave it alone until it's finished."
    fi
    CP_BODY=$(pr_body_ensure_closes "$CP_BODY" "$ISSUE_NUMBER")
    CP_BODY=$(checkpoint_set_count "$CP_BODY" "$NEXT_N")
    CP_PR=$(forgejo_open_pr "$FORGEJO_REPO" "$BRANCH" "$PR_BASE" "$CP_TITLE" "$CP_BODY")
    log "checkpoint: opened draft PR${CP_PR:+ #$CP_PR} (WIP; resuming next tick)"
  else
    CUR_BODY=$(forgejo_get_pr "$FORGEJO_REPO" "$CP_PR" 2>/dev/null | jq -r '.body // ""')
    forgejo_edit_pr "$FORGEJO_REPO" "$CP_PR" --body "$(checkpoint_set_count "$CUR_BODY" "$NEXT_N")" \
      || log "warning: could not bump checkpoint counter on PR #$CP_PR"
  fi

  forgejo_log_time "$FORGEJO_REPO" "$ISSUE_NUMBER" "$ELAPSED" 2>/dev/null || true

  if checkpoint_budget_exhausted "$NEXT_N"; then
    # OUTCOME: blocked
    # Too many checkpoints without finishing: stop resuming, hand to the human.
    log "outcome: blocked (checkpoint budget exhausted: $NEXT_N)"
    forgejo_add_label "$FORGEJO_REPO" "$ISSUE_NUMBER" "Status/Blocked" 2>/dev/null \
      || log "warning: could not apply Status/Blocked"
    if [ -n "${FORGEJO_REVIEWER:-}" ]; then
      forgejo_assign "$FORGEJO_REPO" "$ISSUE_NUMBER" "$FORGEJO_REVIEWER" 2>/dev/null || true
    fi
    forgejo_comment "$FORGEJO_REPO" "$ISSUE_NUMBER" \
      "This issue has checkpointed ${NEXT_N} times (turn cap) without completing -- the sign it's too large for the agent's per-tick budget. Draft PR #${CP_PR} holds the work so far. \`Status/Blocked\` applied: split this into smaller issues, then remove the label to resume." 2>/dev/null || true
  else
    # Keep it claimable so the next tick resumes it.
    forgejo_unassign_all "$FORGEJO_REPO" "$ISSUE_NUMBER" 2>/dev/null || true
    log "checkpoint: PR #${CP_PR} left as draft; issue re-queued for resume (${NEXT_N}/${CHECKPOINT_MAX})"
  fi
  exit 0
fi

# -- Determine outcome -----------------------------------------

cd "$WORKTREE"
COMMITS=$(git rev-list --count "origin/${PR_BASE}..HEAD" 2>/dev/null || echo 0)

CURRENT=$(forgejo_get_issue "$FORGEJO_REPO" "$ISSUE_NUMBER")
ISSUE_STATE=$(jq -r .state <<<"$CURRENT")
HAS_BLOCKED=$(jq -r '[.labels[].name] | index("Status/Blocked") != null' <<<"$CURRENT")

if [ "$ISSUE_STATE" = "closed" ]; then
  # OUTCOME: report
  log "outcome: report (issue closed by agent)"
  if forgejo_log_time "$FORGEJO_REPO" "$ISSUE_NUMBER" "$ELAPSED"; then
    log "time logged: ${ELAPSED}s on ${FORGEJO_REPO}#${ISSUE_NUMBER}"
  else
    log "warning: could not log time on ${FORGEJO_REPO}#${ISSUE_NUMBER}"
  fi

elif [ "$HAS_BLOCKED" = "true" ]; then
  # OUTCOME: blocked
  log "outcome: blocked (Status/Blocked applied by agent)"

elif [ "$COMMITS" -gt 0 ]; then
  # HEAD-equals-branch sanity check. AGENTS.md tells Claude to stay on
  # the agent branch, but trust-but-verify before we touch the remote.
  ACTUAL_BRANCH=$(git rev-parse --abbrev-ref HEAD)
  if [ "$ACTUAL_BRANCH" != "$BRANCH" ]; then
    # OUTCOME: blocked
    log "outcome: blocked (HEAD on $ACTUAL_BRANCH, expected $BRANCH)"
    agent-block.sh "The agent refused to push: HEAD ended up on \`$ACTUAL_BRANCH\` instead of \`$BRANCH\`. Something went sideways during the work -- investigate before re-queueing."
    exit 0
  fi

  # Scope cap. Big diffs and long commit chains get blocked instead of
  # shipped; the human splits the work into smaller issues. Generated/
  # lockfiles are excluded from the line count -- they're not
  # human-reviewed code and shouldn't burn the LoC budget (a lockfile
  # regen alone can dwarf a legitimately small change).
  CHANGED=$(git diff --shortstat "origin/${PR_BASE}..HEAD" -- . \
    ':(exclude,glob)**/package-lock.json' ':(exclude,glob)**/yarn.lock' \
    ':(exclude,glob)**/pnpm-lock.yaml' ':(exclude,glob)**/*.lock' \
    ':(exclude,glob)**/dist/**' ':(exclude,glob)**/build/**' 2>/dev/null \
    | awk '{ for (i=1;i<=NF;i++) if ($i ~ /insertion|deletion/) s+=$(i-1); print s+0 }')
  CHANGED=${CHANGED:-0}
  # For the commit-count cap, exclude the harness's own WIP-checkpoint commits:
  # they're resume artifacts, not history sprawl, and would otherwise block a
  # legitimately completed task that simply took several turn-cap checkpoints to
  # finish. The line cap (the real reviewability gate) still spans the whole
  # diff. Normal PRs have no WIP commits, so this is a no-op for them.
  # (grep -c prints 0 and exits 1 when every commit is a checkpoint; `|| true`
  # swallows that so pipefail/errexit don't abort, and the default catches an
  # empty result.)
  REVIEW_COMMITS=$(git log "origin/${PR_BASE}..HEAD" --pretty=%s 2>/dev/null \
    | grep -cvE '^WIP: issue #[0-9]+ checkpoint' || true)
  REVIEW_COMMITS=${REVIEW_COMMITS:-0}
  if [ "$REVIEW_COMMITS" -gt 10 ] || [ "$CHANGED" -gt 400 ]; then
    # OUTCOME: blocked
    log "outcome: blocked (scope: $REVIEW_COMMITS non-checkpoint commits / $COMMITS total, $CHANGED lines)"
    FILES=$(git diff --name-only "origin/${PR_BASE}..HEAD" | head -30 | sed 's/^/  - /')
    agent-block.sh "Scope exceeded: this branch reached **${REVIEW_COMMITS} commits / ${CHANGED} changed lines**, over the per-issue cap (10 commits / 400 lines).

Files touched (first 30):
${FILES}

Split this into smaller issues, then remove \`Status/Blocked\` and the next tick will re-claim what's left."
    exit 0
  fi

  # Off-limits guard: CI workflow files are operator-managed.
  OFFLIMITS=$(list_offlimits_violations "$PR_BASE")
  if [ -n "$OFFLIMITS" ]; then
    # OUTCOME: blocked
    log "outcome: blocked (off-limits files touched)"
    agent-block.sh "The agent refused to push: this PR modifies CI workflow files, which are operator-managed and off-limits to ticks. Paths touched:

  - ${OFFLIMITS//$'\n'/$'\n'  - }

Revert those changes (or do them yourself outside the agent) and remove \`Status/Blocked\` to re-queue. If a workflow change is genuinely needed, file a separate issue for the human to handle."
    exit 0
  fi

  # Vacuous-test heuristic. Catches the dumbest false positive: test
  # commands that exit 0 with zero tests run (jest --passWithNoTests,
  # pytest with no collected items, etc). Not a complete check -- still
  # relies on the project's test command being meaningful.
  if grep -qiE 'tests:[[:space:]]+0[[:space:]]+(passed|failed|of|total)|no tests (ran|found|collected)|collected 0 items|(^|[^0-9])0 passing([^0-9]|$)|running 0 tests|ran 0 tests' "$CLAUDE_LOG"; then
    # OUTCOME: blocked
    log "outcome: blocked (vacuous tests: 0 tests reported)"
    agent-block.sh "Tests ran but reported zero tests executed. Definition of done failed: the test suite must run at least one assertion. Either this repo's \`CLAUDE.md\` declares a meaningless test command, or the change skipped the relevant suite. Fix and remove \`Status/Blocked\` to re-queue."
    exit 0
  fi

  # Security gate. Independent review of the diff before it ships; a
  # material finding blocks like the guards above (work waits for the
  # human). The agent's own /security-review is the fix-early pass --
  # this is the unskippable one the harness owns.
  #
  # Heartbeat first -- this is the second long model call in the tick
  # (the tier-1 build claude_run_with_cost above already ate up to
  # TICK_TIMEOUT), so without this ping the dead-man's-switch gap is the
  # SUM of both stages (~55m), not the longest single one (~30m). igor#360.
  hc_ping heartbeat
  # OUTCOME: blocked
  if SEC_FINDINGS=$(security_gate "$WORKTREE" "$PR_BASE" "security-gate-issue"); then
    :
  else
    log "outcome: blocked (security review flagged the diff)"
    agent-block.sh "The harness security review flagged a material issue in this change, so it was NOT pushed:

${SEC_FINDINGS}

Address it, then remove \`Status/Blocked\` to re-queue. (If the note above says the gate could not complete, that's a transient error -- just re-queue.)"
    exit 0
  fi

  # OUTCOME: pr
  log "outcome: PR ($COMMITS commit(s), $CHANGED line(s))"

  # Idempotent push: --force-with-lease covers the crash-then-retry
  # case where a prior tick pushed but died before opening a PR. We
  # only overwrite the remote ref we last fetched; if anyone else has
  # touched it (human, another host), the push fails loud.
  git push --force-with-lease -u origin "$BRANCH"

  # Idempotent PR open: skip if one already exists for this branch.
  EXISTING_PR=$(forgejo_find_pr_by_head "$FORGEJO_REPO" "$BRANCH")
  if [ -n "$EXISTING_PR" ]; then
    log "PR #$EXISTING_PR already open for $BRANCH -- skipping open"
    NEW_PR_NUMBER="$EXISTING_PR"
    # Finalize a checkpoint draft: give it a clean (non-WIP) title + a real body,
    # which marks it ready so the review + merge loops (which skip WIP PRs) pick
    # it up. Prefer the newest real commit subject, skipping the harness's
    # "WIP: ... checkpoint" markers; the body comes from PR_BODY.md as usual.
    EX_JSON=$(forgejo_get_pr "$FORGEJO_REPO" "$EXISTING_PR" 2>/dev/null || echo '{}')
    EX_TITLE=$(printf '%s' "$EX_JSON" | jq -r '.title // ""')
    if checkpoint_is_wip "$EX_TITLE"; then
      FINAL_TITLE=$(git log "origin/${PR_BASE}..HEAD" --pretty=%s 2>/dev/null \
        | grep -vE '^WIP: issue #[0-9]+ checkpoint' | head -1)
      [ -n "$FINAL_TITLE" ] || FINAL_TITLE="issue #${ISSUE_NUMBER}: ${ISSUE_TITLE}"
      if [ -f .agent/PR_BODY.md ]; then
        FINAL_BODY=$(cat .agent/PR_BODY.md)
      else
        FINAL_BODY=$(git log "origin/${PR_BASE}..HEAD" --reverse --format='### %s%n%n%b%n')
      fi
      FINAL_BODY+=$(build_deps_section "$PR_BASE")
      FINAL_BODY=$(pr_body_ensure_closes "$FINAL_BODY" "$ISSUE_NUMBER")
      if forgejo_edit_pr "$FORGEJO_REPO" "$EXISTING_PR" --title "$FINAL_TITLE" --body "$FINAL_BODY"; then
        log "checkpoint: finalized -- PR #$EXISTING_PR ready for review (WIP dropped)"
      else
        log "warning: could not finalize checkpoint PR #$EXISTING_PR"
      fi
    else
      # Non-WIP existing PR (e.g. a reworked one): the WIP-finalize branch above
      # is skipped, and this path used to leave the body untouched -- so a PR
      # whose body lacks the closing keyword merges WITHOUT auto-closing its
      # issue (#372: #371 left #369 open). Guarantee it here, idempotently --
      # only edit when the keyword is actually missing.
      EX_BODY=$(printf '%s' "$EX_JSON" | jq -r '.body // ""')
      EX_NEW=$(pr_body_ensure_closes "$EX_BODY" "$ISSUE_NUMBER")
      if [ "$EX_NEW" != "$EX_BODY" ]; then
        if forgejo_edit_pr "$FORGEJO_REPO" "$EXISTING_PR" --body "$EX_NEW"; then
          log "ensured 'Closes #$ISSUE_NUMBER' on existing PR #$EXISTING_PR (#372)"
        else
          log "warning: could not add closing keyword to PR #$EXISTING_PR"
        fi
      fi
    fi
  else
    PR_TITLE=$(git log -1 --pretty=%s)
    if [ -f .agent/PR_BODY.md ]; then
      PR_BODY=$(cat .agent/PR_BODY.md)
    else
      log "WARNING: PR_BODY.md was NOT written by claude this tick. AGENTS.md requires it on every ship; this is not optional. Attempting harness-side fallback via $AGENT_MODEL."
      PR_BODY=$(derive_pr_body "$WORKTREE" "$PR_BASE")
      if [ -n "$PR_BODY" ]; then
        log "harness-side PR body synthesized via $AGENT_MODEL from diff"
      else
        log "WARNING: fallback body synthesis failed; using git-log-derived body. PR description will be thin."
        PR_BODY=$(git log "origin/${PR_BASE}..HEAD" --reverse --format='### %s%n%n%b%n')
      fi
    fi
    PR_BODY+=$(build_deps_section "$PR_BASE")
    PR_BODY=$(pr_body_ensure_closes "$PR_BODY" "$ISSUE_NUMBER")

    NEW_PR_NUMBER=$(forgejo_open_pr "$FORGEJO_REPO" "$BRANCH" "$PR_BASE" "$PR_TITLE" "$PR_BODY")
    log "PR opened${NEW_PR_NUMBER:+ (#$NEW_PR_NUMBER)}"
    # UI work: attach any screenshots the agent dropped in .agent/screenshots/
    # so the PR carries visual proof, not just a text reference. Best-effort.
    if [ -n "$NEW_PR_NUMBER" ] && [ -d "$WORKTREE/.agent/screenshots" ]; then
      SHOT_N=$(forgejo_attach_pr_screenshots "$FORGEJO_REPO" "$NEW_PR_NUMBER" "$WORKTREE/.agent/screenshots" 2>/dev/null || echo 0)
      [ "${SHOT_N:-0}" -gt 0 ] && log "attached $SHOT_N screenshot(s) to #$NEW_PR_NUMBER" || true
    fi
  fi

  # Record Claude's wall-clock on the ISSUE (Forgejo time tracking).
  # Split rationale: the agent's coding time belongs on the issue (his
  # work); reviewer time belongs on the PR (the human's work during
  # review). PR-review ticks log on the PR. Discretionary ticks (no
  # issue) log on the PR they create. Best-effort; never fail the
  # tick over this.
  if forgejo_log_time "$FORGEJO_REPO" "$ISSUE_NUMBER" "$ELAPSED"; then
    log "time logged: ${ELAPSED}s on ${FORGEJO_REPO}#${ISSUE_NUMBER} (issue)"
  else
    log "warning: could not log time on ${FORGEJO_REPO}#${ISSUE_NUMBER}"
  fi

  # Unassign the bot from the issue so the next tick's recovery
  # sweep stays quiet. Keep the Agent label intact -- the label is
  # the human's signal ("this needs an agent"); the open PR linked
  # via "Closes #N" is the harness's signal ("work in flight").
  # Discovery's PR-history check excludes issues with open bot PRs.
  forgejo_unassign_all "$FORGEJO_REPO" "$ISSUE_NUMBER" 2>/dev/null \
    || log "warning: could not unassign ${FORGEJO_REPO}#${ISSUE_NUMBER}"

else
  # Noop-loop guard. If the bot already left a "no work produced"
  # comment on this issue, this is the second attempt -- block rather
  # than burn another tick on it.
  NOOP_PREFIX="The agent completed with no work produced"
  PRIOR_NOOPS=$(forgejo_count_bot_comments_matching \
    "$FORGEJO_REPO" "$ISSUE_NUMBER" "$BOT_USER" "$NOOP_PREFIX")
  if [ "${PRIOR_NOOPS:-0}" -ge 1 ]; then
    # OUTCOME: blocked
    log "outcome: blocked (repeated noop, prior count: $PRIOR_NOOPS)"
    agent-block.sh "The agent produced no work on this issue twice. The issue is probably unclear, requires context Claude can't reach, or has a setup problem. Investigate, then remove \`Status/Blocked\` to re-queue."
    exit 0
  fi

  # OUTCOME: noop
  # Harness-commits flow: any dirty non-.agent files would already
  # be auto-committed by the block right after Claude exits, so a
  # 0-commits outcome here means Claude truly did nothing
  # commit-worthy. No "forgot to commit" path remains.
  log "outcome: no work produced (elapsed ${ELAPSED}s)"
  forgejo_unassign_all "$FORGEJO_REPO" "$ISSUE_NUMBER"

  TAIL="(no output captured)"
  [ -s "$CLAUDE_LOG" ] && TAIL=$(tail -c 4000 "$CLAUDE_LOG")

  forgejo_comment "$FORGEJO_REPO" "$ISSUE_NUMBER" \
"${NOOP_PREFIX} and no blocker reported. Investigate. (claude exit: ${CLAUDE_EXIT}, elapsed ${ELAPSED}s)

<details><summary>last bytes of claude output</summary>

\`\`\`
${TAIL}
\`\`\`
</details>"
fi

# Cleanup runs via trap on exit.
exit 0
