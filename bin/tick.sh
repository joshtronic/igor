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
# shellcheck source=lib/repo-checks.sh
. "$AGENT_HOME/lib/repo-checks.sh"
# shellcheck source=lib/maintenance-checks.sh
. "$AGENT_HOME/lib/maintenance-checks.sh"
# shellcheck source=lib/cost.sh
. "$AGENT_HOME/lib/cost.sh"
# shellcheck source=lib/claude.sh
. "$AGENT_HOME/lib/claude.sh"
# shellcheck source=../lib/security-gate.sh
. "$AGENT_HOME/lib/security-gate.sh"
# shellcheck source=lib/gsc.sh
. "$AGENT_HOME/lib/gsc.sh"
# shellcheck source=lib/email.sh
. "$AGENT_HOME/lib/email.sh"
# shellcheck source=lib/seo-analysis.sh
. "$AGENT_HOME/lib/seo-analysis.sh"
# shellcheck source=lib/marketstack.sh
. "$AGENT_HOME/lib/marketstack.sh"
# shellcheck source=lib/market-report.sh
. "$AGENT_HOME/lib/market-report.sh"
# shellcheck source=lib/espn.sh
. "$AGENT_HOME/lib/espn.sh"
# shellcheck source=lib/sports-digest.sh
. "$AGENT_HOME/lib/sports-digest.sh"

# Children invocations (agent-* helper scripts) share our tick id
# so cost-ledger entries from child processes group with the
# parent tick's entries.
export TICK_PID=$$

# -- Resolve bot identity --------------------------------------

BOT_USER=$(forgejo_whoami)
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
# (SEO, market). All default to empty so referencing them under `set -u`
# is safe when nothing is configured; each report tick no-ops cleanly if
# its required creds (incl. these) are unset.
export SMTP2GO_API_KEY="${SMTP2GO_API_KEY:-}"
export SMTP2GO_SENDER="${SMTP2GO_SENDER:-}"

# SEO analysis pass -- opt-in via Google Search Console + SMTP2GO creds.
# do_seo_tick no-ops cleanly if any required one is unset. Floor/top-K
# carry tuning defaults.
export GSC_OAUTH_CLIENT_ID="${GSC_OAUTH_CLIENT_ID:-}"
export GSC_OAUTH_CLIENT_SECRET="${GSC_OAUTH_CLIENT_SECRET:-}"
export GSC_OAUTH_REFRESH_TOKEN="${GSC_OAUTH_REFRESH_TOKEN:-}"
export SEO_PRIMARY_EMAIL="${SEO_PRIMARY_EMAIL:-}"
export SEO_EXTRA_RECIPIENTS="${SEO_EXTRA_RECIPIENTS:-}"
export SEO_AGENTIC_SITES="${SEO_AGENTIC_SITES:-}"
export SEO_IMPRESSION_FLOOR="${SEO_IMPRESSION_FLOOR:-50}"
export SEO_TOP_K="${SEO_TOP_K:-10}"
export SEO_DEBUG_DOMAIN="${SEO_DEBUG_DOMAIN:-}"

# Claude health alerts -- where the once-daily "claude auth/usage is
# broken" email goes (see do_health_tick). Optional; falls back to
# SEO_PRIMARY_EMAIL, and with neither set (or no SMTP2GO creds) the
# alert is log-only.
export HEALTH_RECIPIENTS="${HEALTH_RECIPIENTS:-${SEO_PRIMARY_EMAIL:-}}"

# Market report -- opt-in daily (Mon-Fri) previous-trading-day prices
# email via the marketstack EOD API + SMTP2GO. do_market_tick no-ops
# cleanly if any required one is unset. Tries on the first weekday tick
# after the midnight rollover -- no send-hour knob, matching the rest of
# the harness (midnight = a new day, no clock gating) -- but only emails
# once the latest EOD bar is the session it expects; until then it holds
# and re-checks on a cooldown (see MARKET_RETRY_COOLDOWN_SECS).
export MARKETSTACK_API_KEY="${MARKETSTACK_API_KEY:-}"
export MARKET_SYMBOLS="${MARKET_SYMBOLS:-}"
export MARKET_RECIPIENTS="${MARKET_RECIPIENTS:-}"

# Sports digest -- opt-in daily (7 days; sports don't take weekends off)
# ELI5 sports-tutor email: scripted ESPN fetch, ONE distill call on
# AGENT_MODEL, sent via SMTP2GO. do_sports_tick no-ops cleanly if any
# required var is unset. Leagues are ESPN {sport}/{league} paths (e.g.
# football/nfl, hockey/nhl, soccer/fifa.world, racing/nascar-premier,
# football/college-football); one flat list -- the directive weights
# coverage by significance, so a quiet league costs nothing and a
# college championship outranks a routine pro slate on its own merits.
# Unlike market, this pass USES the model, so it waits out a Claude
# health cooldown like every other model surface.
export SPORTS_RECIPIENTS="${SPORTS_RECIPIENTS:-}"
export SPORTS_LEAGUES="${SPORTS_LEAGUES:-}"

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
# Normalize Unicode dashes that Claude/Haiku tend to emit. Forgejo
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
#   2. API-generated subject from the staged diff (Haiku call,
#      ~$0.005, ~1-2s latency). Used when PR_BODY is missing or
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
  # Haiku occasionally adds despite instructions.
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
  local base="$1"
  git diff --name-only "origin/${base}..HEAD" 2>/dev/null \
    | grep -E '^\.(forgejo|github)/workflows/' || true
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

# -- Market report daily send state -----------------------------
#
# One ".market" object in discretionary-state.json (same file as
# .slots/.weekly/.maintenance/.seo), shaped { date, sent, failures,
# last_attempt } -- mirroring how .slots carries its date + flags +
# counters in a single namespaced key. The date drives a self-resetting
# daily rollover for every field; each mutator normalizes to today before
# touching it.
#
# The report sends at most once per local day (sent=true), and unlike
# the slots this is independent of WEBSITE_REPO. Two distinct concerns,
# decoupled on purpose:
#   - last_attempt (epoch secs) spaces EVERY marketstack hit by
#     MARKET_RETRY_COOLDOWN_SECS, so the midnight-boundary wait for fresh
#     EOD data doesn't poll the metered API every minute.
#   - failures counts only HARD failures (API error / empty read / send
#     failure) -- a broken key or outage. It's capped so the day is
#     abandoned rather than burning quota indefinitely; a successful fetch
#     clears it. Stale-but-valid data ("not published yet") is NOT a
#     failure: it just holds and re-checks on the next cooldown.
# Regenerable -- losing it just re-opens today's send.

# Space EVERY per-day marketstack hit so a stale/empty read (common at the
# midnight boundary, before EOD data is published) doesn't re-hit the
# metered API every tick. Override-with-default, mirroring
# VALIDATION_COOLDOWN_SECS; the first attempt of the day is never delayed.
MARKET_RETRY_COOLDOWN_SECS="${MARKET_RETRY_COOLDOWN_SECS:-900}"  # 15 min

# jq fragment: normalize .market to today, resetting if the day rolled.
# shellcheck disable=SC2016  # $d is a jq --arg, not shell -- must not expand
MARKET_ROLL='(if (.market.date // "") == $d then .market
              else {date:$d, sent:false, failures:0, last_attempt:0} end)'

market_sent_today() {
  local state_file today
  state_file=$(discretionary_state_file)
  [ -f "$state_file" ] || return 1
  today=$(date +%Y-%m-%d)
  [ "$(jq -r --arg d "$today" \
        '(.market.date == $d) and (.market.sent == true)' \
        "$state_file" 2>/dev/null)" = "true" ]
}

market_mark_sent() {
  local state_file tmp today
  state_file=$(discretionary_state_file)
  today=$(date +%Y-%m-%d)
  [ -f "$state_file" ] || echo '{}' > "$state_file"
  tmp=$(mktemp)
  jq --arg d "$today" ".market = ($MARKET_ROLL | .sent = true)" \
    "$state_file" > "$tmp"
  mv "$tmp" "$state_file"
}

# Echo today's failure count (0 if unset or the day rolled). Read-only --
# the cap that consumes it lives in do_market_tick.
market_failures() {
  local state_file today n
  state_file=$(discretionary_state_file)
  [ -f "$state_file" ] || { echo 0; return; }
  today=$(date +%Y-%m-%d)
  n=$(jq -r --arg d "$today" \
    'if (.market.date // "") == $d then (.market.failures // 0) else 0 end' \
    "$state_file" 2>/dev/null)
  [ -n "$n" ] && [ "$n" != "null" ] || n=0
  echo "$n"
}

# Stamp last_attempt=now (resetting on a day rollover). Called once per
# marketstack hit, before the request -- it's what the cooldown reads.
market_mark_attempt() {
  local state_file tmp today now
  state_file=$(discretionary_state_file)
  today=$(date +%Y-%m-%d)
  now=$(date +%s)
  [ -f "$state_file" ] || echo '{}' > "$state_file"
  tmp=$(mktemp)
  jq --arg d "$today" --argjson now "$now" \
    ".market = ($MARKET_ROLL | .last_attempt = \$now)" \
    "$state_file" > "$tmp"
  mv "$tmp" "$state_file"
}

# Bump today's HARD-failure count (API error / empty read / send failure)
# and echo the new value. Stale-but-valid reads do NOT call this.
market_failure_inc() {
  local state_file tmp today n
  state_file=$(discretionary_state_file)
  today=$(date +%Y-%m-%d)
  [ -f "$state_file" ] || echo '{}' > "$state_file"
  tmp=$(mktemp)
  jq --arg d "$today" ".market = ($MARKET_ROLL | .failures += 1)" \
    "$state_file" > "$tmp"
  mv "$tmp" "$state_file"
  n=$(jq -r '.market.failures' "$state_file" 2>/dev/null)
  echo "$n"
}

# Clear today's failure streak -- a successful fetch proves the API works,
# so any prior transient failures shouldn't count toward the cap.
market_clear_failures() {
  local state_file tmp today
  state_file=$(discretionary_state_file)
  [ -f "$state_file" ] || return 0
  today=$(date +%Y-%m-%d)
  tmp=$(mktemp)
  jq --arg d "$today" ".market = ($MARKET_ROLL | .failures = 0)" \
    "$state_file" > "$tmp"
  mv "$tmp" "$state_file"
}

# True when it's OK to hit marketstack again today: either no attempt yet
# today (first post-midnight tick fires immediately) or the cooldown since
# the last attempt has elapsed. Keeps a stale/failed read from re-polling
# the metered API every minute while we wait for fresh EOD data.
market_retry_ready() {
  local state_file today last now
  state_file=$(discretionary_state_file)
  [ -f "$state_file" ] || return 0
  today=$(date +%Y-%m-%d)
  last=$(jq -r --arg d "$today" \
    'if (.market.date // "") == $d then (.market.last_attempt // 0) else 0 end' \
    "$state_file" 2>/dev/null)
  [ -n "$last" ] && [ "$last" != "null" ] || last=0
  now=$(date +%s)
  [ "$((now - last))" -ge "$MARKET_RETRY_COOLDOWN_SECS" ]
}

# Echo the most recent completed trading session we expect EOD data for:
# the previous weekday (yesterday Tue-Fri, or Friday on a Monday). Holiday-
# naive -- on the trading day after a market holiday the real last session
# predates this, so the freshness gate won't match and the report holds for
# the day (see do_market_tick).
# Portable across GNU (Linux server) and BSD (macOS dev) date.
market_prev_trading_day() {
  local back=1
  [ "$(date +%u)" -eq 1 ] && back=3  # Monday -> Friday
  date -d "-${back} days" +%F 2>/dev/null || date -v-"${back}"d +%F 2>/dev/null
}

# market_format_date <YYYY-MM-DD>
# Returns a human-readable date like "Tuesday, June 9th, 2026".
market_format_date() {
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
# Same day-keyed shape and semantics as `.market` (one report per day,
# retry-on-cooldown until it sends, bounded hard-failure budget):
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

# -- Validation pass cache --------------------------------------
#
# The validation sweep runs every tick. At a 1-minute cadence across
# many repos that's a lot of redundant API calls re-proving the same
# repos pass. Cache the PASS result for a cooldown window so
# validation effectively runs ~once per window per repo regardless of
# tick frequency. Failures are NOT cached -- they fall through to the
# onboarding flow every tick for fast recovery once the human fixes
# the repo. Stored as epoch seconds under a "validation" object.
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
# Deliberately does NOT skip repos that failed validation or carry an
# open onboarding ticket. The maintenance audit is read-only -- it only
# files an issue, never commits -- so a not-yet-onboarded repo still
# gets its dependencies audited (matching the ANALYSIS_REPOS_JSON set
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
# -- or carries an open onboarding ticket -- still gets its
# dependencies audited. The two-tier split lives one level down, in
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
# keyed by an HTML-comment marker (same mechanism as the onboarding +
# SEO tickets). Dedup is skip-if-open: a repo is audited at most once
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
# validate_repo_via_api). VALIDATED_REPOS_JSON is the newline-delimited
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

# maint_file_deduped_issue <repo> <marker> <title> <body> <agent-bool> <priority-label|"">
# Files <body> (which MUST already contain <marker>) as an issue, unless
# an open issue carrying <marker> already exists (skip-if-open dedup).
# agent-bool=true -> Agent-labeled + left UNASSIGNED so claimable
# discovery works it into a PR; false -> Status/Need More Info for a
# human. No-op-safe: logs and returns 0 on any Forgejo hiccup so the
# audit loop continues.
maint_file_deduped_issue() {
  local repo="$1" marker="$2" title="$3" body="$4" agent="$5" pri="$6"
  local existing
  existing=$(forgejo_find_marked_issue "$repo" "$BOT_USER" "$marker" 2>/dev/null)
  if [ -n "$existing" ] && [ "$existing" != "null" ] \
     && [ "$(jq -r '.state' <<<"$existing" 2>/dev/null)" = "open" ]; then
    log "maintenance: $repo already has an open ticket #$(jq -r '.number' <<<"$existing") for ${marker} -- not refiling"
    return 0
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
         The human-triage report: JUDGMENT items, plus -- when
         VALIDATED=false -- everything actionable. Lead with what
         matters, bury noise. Prose for a human, not a work spec.
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
    --max-turns 50 \
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
    maint_file_deduped_issue "$target" "$MAINT_TRIAGE_MARKER" \
      "[maintenance] findings needing triage for $target" \
      "$(cat "$findings_file")

$MAINT_TRIAGE_MARKER" \
      false "$m_pri_label"
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
# from SEO_EXTRA_RECIPIENTS ("email=site1,site2|email2=site3").
seo_extra_recipients_for() {
  local domain="$1" entry email sites out=""
  local IFS='|'
  for entry in ${SEO_EXTRA_RECIPIENTS:-}; do
    [ -z "$entry" ] && continue
    email="${entry%%=*}"
    sites="${entry#*=}"
    case ",$sites," in
      *",$domain,"*) out="${out:+$out,}$email" ;;
    esac
  done
  printf '%s' "$out"
}

# Full recipient list for a domain: primary always, plus any subscribed
# extras. Primary getting every domain means it's always copied, so no
# separate CC is needed.
seo_recipients_for() {
  local domain="$1" extras out
  out="${SEO_PRIMARY_EMAIL:-}"
  extras=$(seo_extra_recipients_for "$domain")
  [ -n "$extras" ] && out="${out:+$out,}$extras"
  printf '%s' "$out"
}

# The Forgejo repo mapped to an agentic domain, or empty. Parsed from
# SEO_AGENTIC_SITES ("domain=owner/repo|domain2=owner/repo2").
seo_agentic_repo_for() {
  local domain="$1" entry d repo
  local IFS='|'
  for entry in ${SEO_AGENTIC_SITES:-}; do
    [ -z "$entry" ] && continue
    d="${entry%%=*}"
    repo="${entry#*=}"
    [ "$d" = "$domain" ] && { printf '%s' "$repo"; return 0; }
  done
  return 0
}

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
  existing=$(forgejo_find_marked_issue "$repo" "$BOT_USER" "$marker" 2>/dev/null)
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
  if [ -z "${GSC_OAUTH_CLIENT_ID:-}" ] || [ -z "${GSC_OAUTH_CLIENT_SECRET:-}" ] \
     || [ -z "${GSC_OAUTH_REFRESH_TOKEN:-}" ] || [ -z "${SMTP2GO_API_KEY:-}" ] \
     || [ -z "${SMTP2GO_SENDER:-}" ] || [ -z "${SEO_PRIMARY_EMAIL:-}" ]; then
    return 1
  fi

  local token
  token=$(gsc_access_token) || { log "seo: GSC token refresh failed -- skipping this tick"; return 1; }

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

# One daily (Mon-Fri) market report: the previous trading day's prices
# (high, low, close, volume) for MARKET_SYMBOLS, emailed to
# MARKET_RECIPIENTS. Opt-in, scripted
# (no LLM), email-only -- a sibling of do_seo_tick, not repo-driven.
# Fires on the first weekday tick after midnight (no send-hour gate --
# midnight is the day rollover, matching the rest of the harness), but
# only emails once the latest EOD bar is the session we expect: at the
# boundary marketstack often still has the prior session, and sending
# that would email stale prices. A stale read just holds (no send) and
# re-checks on the next cooldown; a HARD failure (API error / empty read /
# send failure) bumps a small bounded counter so a broken key or outage
# abandons the day instead of burning the metered quota. (Holiday-naive:
# on the trading day after a market holiday the freshness gate never
# matches, so no report goes out that day -- see market_prev_trading_day.)
# Returns 0 if a report was sent (caller exits the tick), 1 if the
# subsystem is unconfigured, it's the weekend, today's already sent, the
# data isn't fresh yet, or the send failed (caller falls through).
do_market_tick() {
  # Opt-in gate: every required credential/config must be present.
  if [ -z "${MARKETSTACK_API_KEY:-}" ] || [ -z "${MARKET_SYMBOLS:-}" ] \
     || [ -z "${MARKET_RECIPIENTS:-}" ] || [ -z "${SMTP2GO_API_KEY:-}" ] \
     || [ -z "${SMTP2GO_SENDER:-}" ]; then
    return 1
  fi

  # Weekday only -- markets are closed Sat/Sun (date +%u: 1=Mon..7=Sun).
  # Every configured-but-not-sending path below logs its status: the
  # journal should say WHY market did nothing this tick, same as
  # maintenance ("no repos eligible") and seo ("all domains analyzed").
  local dow; dow=$(date +%u)
  if [ "$dow" -ge 6 ]; then
    log "market: weekend -- markets closed, no report today"
    return 1
  fi

  # At most once per day (set only on a successful send).
  if market_sent_today; then
    log "market: report already sent today -- continuing"
    return 1
  fi

  # Failure budget: once marketstack/SMTP has hard-failed too many times
  # today, abandon the day rather than keep burning the metered quota
  # (clear the .market object in discretionary-state.json to force a retry).
  # Checked before the cooldown so an abandoned day stops cheaply, and
  # before any API hit so we never re-fetch past the cap. Hardcoded, not an
  # env knob -- keep the .env surface small.
  local max_failures=5 failures
  failures=$(market_failures)
  if [ "$failures" -ge "$max_failures" ]; then
    log "market: abandoned for the day (${failures}/${max_failures} hard failures; clear .market in discretionary-state.json to retry) -- continuing"
    return 1
  fi

  # Cooldown gate: at most one marketstack hit per MARKET_RETRY_COOLDOWN_SECS.
  # The first attempt of the day passes straight through (last_attempt=0);
  # a stale or failed read then waits out the cooldown instead of polling
  # the metered API every minute while EOD data is still being published.
  if ! market_retry_ready; then
    log "market: not sent yet today, waiting out the retry cooldown -- continuing"
    return 1
  fi
  market_mark_attempt  # start the cooldown clock for this hit

  log "market: fetching EOD for ${MARKET_SYMBOLS}"
  local eod report count
  eod=$(marketstack_eod_latest "$MARKET_SYMBOLS") || eod='{"data":[]}'
  report=$(market_build_report "$eod" "$MARKET_SYMBOLS")
  count=$(jq -r '.count // 0' <<<"$report" 2>/dev/null || echo 0)

  if [ "${count:-0}" -eq 0 ]; then
    # No bars at all -- a hard failure (transient API error or a bad key;
    # a valid symbol always has a last EOD bar). Count it toward the cap.
    failures=$(market_failure_inc)
    if [ "$failures" -ge "$max_failures" ]; then
      log "market: ${max_failures} consecutive failures today -- abandoning the report for the day"
    else
      log "market: no EOD rows returned -- not sending (failure ${failures}/${max_failures}, retry after cooldown)"
    fi
    return 1
  fi

  # Got data -- the API works, so clear any prior transient-failure streak.
  market_clear_failures

  # Freshness gate: the latest bar should be the most recent completed
  # session (yesterday, or Friday on a Monday). At the midnight boundary
  # marketstack often still has only the prior session -- hold for fresh
  # data rather than emailing stale prices. This is NOT a failure (the API
  # answered fine), so it doesn't touch the failure budget; the cooldown
  # alone rate-limits the wait.
  local session expected
  session=$(jq -r '.session_date // ""' <<<"$report" 2>/dev/null || echo "")
  expected=$(market_prev_trading_day)
  if [ "$session" != "$expected" ]; then
    log "market: latest bar is ${session:-none}, expected ${expected} -- holding for fresh data (retry after cooldown)"
    return 1
  fi

  local md html subject today formatted_today
  today=$(date +%Y-%m-%d)
  report=$(jq --arg today "$today" '. + {report_date: $today}' <<<"$report")
  md=$(market_render_markdown <<<"$report")
  html=$(market_render_html <<<"$report")
  formatted_today=$(market_format_date "$today")
  subject="[Market] ${formatted_today:-$today}"
  if email_send "$subject" "$html" "$md" "$MARKET_RECIPIENTS"; then
    log "market: emailed report (${session:-latest}, $count symbols) to $MARKET_RECIPIENTS"
    market_mark_sent
    return 0
  fi
  # Send failure -- count it toward the cap so a persistent SMTP outage
  # abandons the day rather than re-fetching marketstack every cooldown.
  failures=$(market_failure_inc)
  if [ "$failures" -ge "$max_failures" ]; then
    log "market: ${max_failures} consecutive failures today -- abandoning the report for the day"
  else
    log "warning: market email failed (failure ${failures}/${max_failures}) -- will retry after cooldown"
  fi
  return 1
}

# -- Sports digest (daily, opt-in) --------------------------------
#
# The ELI5 sports-tutor email: harness-side ESPN fetch (lib/espn.sh),
# ONE claude_call distill on AGENT_MODEL, email via SMTP2GO. Email-only
# and not repo-driven like market/SEO -- but unlike them it USES the
# model, so it lives below the global health gate (a blocked tick
# skips it) and is the reason it can't join their blocked-tick
# carve-out.
#
# Fires on the first tick after 03:00 -- a window-completeness gate
# like logwatch's, not a send-hour: the digest covers YESTERDAY, and
# west-coast NBA/NHL games routinely end past midnight CT. By 03:00
# every previous-day event is final and recapped. Runs 7 days a week.
#
# Retry semantics are market's (.sports = {date, sent, failures,
# last_attempt}): sent flips only on a successful send, attempts are
# spaced by SPORTS_RETRY_COOLDOWN_SECS, and a hardcoded 5-hard-failure
# cap abandons the day. Unlike market there is no clear-on-good-fetch:
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
  if [ -z "${SPORTS_RECIPIENTS:-}" ] || [ -z "${SPORTS_LEAGUES:-}" ] \
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
  local covered prompt directive raw parsed attempt snippet tail_snip
  covered=$(sports_concepts_load)
  prompt=$(sports_build_prompt "$payload" "$covered" "$ydash")
  directive=$(cat "$AGENT_HOME/bin/lib/sports-digest-directive.md")
  parsed=""
  for attempt in 1 2; do
    raw=$(claude_call "$AGENT_MODEL" "sports-digest" 16000 "$directive" "$prompt" 0) || {
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

  # Subject carries TODAY's date, like the market report: it's today's
  # digest of yesterday's action, and the body already frames the
  # content as yesterday's highlights.
  local body concepts html subject today formatted
  body=$(jq -r '.body' <<<"$parsed")
  concepts=$(jq -c '.concepts' <<<"$parsed")
  html=$(sports_render_html <<<"$body")
  today=$(date +%Y-%m-%d)
  formatted=$(market_format_date "$today")
  subject="[Sports] ${formatted:-$today}"
  if email_send "$subject" "$html" "$body" "$SPORTS_RECIPIENTS"; then
    sports_mark_sent
    sports_concepts_append "$concepts" "$(date +%Y-%m-%d)" \
      || log "warning: sports: curriculum ledger update failed (digest sent fine)"
    log "sports: emailed digest for ${ydash} ($(jq 'length' <<<"$concepts") new concepts) to $SPORTS_RECIPIENTS"
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
#      after a day rollover (mirroring the market report's
#      at-most-once-daily send).
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

  if [ -z "$HEALTH_RECIPIENTS" ] || [ -z "$SMTP2GO_API_KEY" ] || [ -z "$SMTP2GO_SENDER" ]; then
    log "health: $kind failure live since $since but alert email not configured (HEALTH_RECIPIENTS + SMTP2GO) -- log-only"
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
  if email_send "$subject" "<pre>${body}</pre>" "$body" "$HEALTH_RECIPIENTS"; then
    tmp=$(mktemp)
    jq --arg d "$today" '.health = ((.health // {}) + {emailed_on: $d})' \
      "$f" > "$tmp" && mv "$tmp" "$f"
    log "health: $kind alert emailed to $HEALTH_RECIPIENTS"
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
# Agent label + unassign; until both happen, claimable discovery
# can't see it. Review time is logged on each filed ticket.
#
# State: one ".logwatch" object {date} in discretionary-state.json.
# Stamped once ATTEMPTED (slot semantics): a wedged pass must not
# retry model calls every tick for the rest of the day. The
# after-01:00 gate is window-completeness (the hour being analyzed
# must have closed), not a send-hour preference -- same flavor as the
# market report's freshness gate.

LOGWATCH_MARKER='<!-- agent:logwatch -->'

logwatch_done_today() {
  local state_file today
  state_file=$(discretionary_state_file)
  [ -f "$state_file" ] || return 1
  today=$(date +%Y-%m-%d)
  [ "$(jq -r '.logwatch.date // ""' "$state_file" 2>/dev/null)" = "$today" ]
}

logwatch_mark_done() {
  local state_file tmp today
  state_file=$(discretionary_state_file)
  today=$(date +%Y-%m-%d)
  [ -f "$state_file" ] || echo '{}' > "$state_file"
  tmp=$(mktemp)
  jq --arg d "$today" '.logwatch = {date: $d}' "$state_file" > "$tmp"
  mv "$tmp" "$state_file"
}

# logwatch_review_unit <repo> <unit>
# Review ONE unit's midnight-hour journal; file tickets on <repo>.
# Returns 0 if a model call ran (the tick did real work), 1 if the
# unit was skipped (empty journal).
logwatch_review_unit() {
  local repo="$1" unit="$2"
  local today start journal
  today=$(date +%F)
  start=$(date +%s)

  journal=$(journalctl --user -u "$unit" \
    --since "$today 00:00:00" --until "$today 01:00:00" \
    --no-pager 2>/dev/null | grep -v '^-- No entries --$' | tail -c 60000)
  if [ -z "$journal" ]; then
    log "logwatch: ${unit}: no entries in the midnight hour -- skipping"
    return 1
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
ticket-worthy: market freshness holds / weekend / already-sent
statuses; validation skips over open onboarding tickets; single
"indeterminate (Forgejo API error)" validation lines; "no claimable
work -- idle" ticks; cooldown waits; "midnight hour still open" /
"already ran today" logwatch statuses. Claude auth/usage-limit
backoffs and health alert emails ARE ticket-worthy.
EOF
)
  fi

  local system user
  system="You are the nightly log reviewer for systemd services owned by an
unattended agent's operator. Each repo that runs as a service
declares its unit files in-repo; you receive ONE service's journal
for last night's batch window (00:00-01:00 local), plus dedup
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
${blurb}

DO file for:
- a run that exhausted its retries or abandoned the night
- an error with no subsequent success in the window
- the unit crashing or exiting nonzero with no benign explanation
- output indicative of a bug: stack traces, unbound variables,
  parse errors, shell warnings

Output STRICT JSON only -- no preamble, no fences:
{\"findings\": [{\"title\": \"...\", \"severity\": \"low|medium|high\", \"body\": \"...\"}]}

- findings: [] when the night was clean. This is the expected common
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

## Journal: ${unit}, ${today} 00:00-01:00

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
    log "logwatch: ${unit}: no parseable review after 2 attempts -- giving up until tomorrow"
    return 0
  fi

  local count
  count=$(jq 'length' <<<"$findings")
  if [ "$count" -eq 0 ]; then
    log "logwatch: ${unit}: clean night -- nothing to file"
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
window: ${today} 00:00-01:00 (filed by the nightly logwatch pass)
${LOGWATCH_MARKER}"
    num=$(forgejo_open_issue "$repo" "$title" "$body") \
      || { log "warning: logwatch ticket open failed on $repo (continuing)"; continue; }
    # Deliberately NO "Agent" label here: the label is the human's
    # triage stamp, not the filing default. The operator greenlights a
    # ticket for Igor by adding the label AND unassigning -- until
    # then it's doubly invisible to claimable discovery (which wants
    # Agent-labeled AND unassigned).
    forgejo_assign "$repo" "$num" "$FORGEJO_REVIEWER" 2>/dev/null \
      || log "warning: could not assign ${repo}#${num} to $FORGEJO_REVIEWER"
    forgejo_log_time "$repo" "$num" "$elapsed" 2>/dev/null \
      || log "warning: could not log time on ${repo}#${num}"
    log "logwatch: filed ticket ${repo}#${num} (${elapsed}s logged): $title"
  done < <(jq -c '.[0:2][]' <<<"$findings")

  return 0
}

do_logwatch_tick() {
  # Window-completeness gate: the midnight hour must have closed.
  # 10#: zero-padded %H must not parse as octal.
  local hour; hour=$((10#$(date +%H)))
  if [ "$hour" -lt 1 ]; then
    log "logwatch: midnight hour still open -- continuing"
    return 1
  fi
  if logwatch_done_today; then
    log "logwatch: today's pass already ran -- continuing"
    return 1
  fi

  if ! command -v journalctl >/dev/null 2>&1; then
    log "logwatch: journalctl not available on this host -- marking done for today"
    logwatch_mark_done
    return 1
  fi

  # Attempted = done for the day, BEFORE any model call (see header).
  logwatch_mark_done

  # Discovery: every bot-accessible repo that declares systemd units.
  # ANALYSIS_REPOS_JSON (not the validated set) -- like maintenance,
  # this pass only reads and files issues, never commits.
  local reviewed=0 repo_line r_name units unit
  while IFS= read -r repo_line; do
    [ -z "$repo_line" ] && continue
    r_name=$(jq -r '.full_name' <<<"$repo_line")
    units=$(forgejo_repo_list_dir "$r_name" "systemd" 2>/dev/null \
      | grep -E '\.service$' || true)
    [ -z "$units" ] && continue
    while IFS= read -r unit; do
      [ -z "$unit" ] && continue
      if logwatch_review_unit "$r_name" "$unit"; then
        reviewed=$((reviewed + 1))
      fi
    done <<<"$units"
  done <<<"$ANALYSIS_REPOS_JSON"

  if [ "$reviewed" -eq 0 ]; then
    log "logwatch: no service journals to review today -- continuing"
    return 1
  fi
  log "logwatch: reviewed $reviewed service journal(s)"
  return 0
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
# scripted, no-LLM subsystems (SEO, market report) so their emails
# aren't held hostage by a usage limit; everything else waits.
# `|| true`: the canary must never kill a tick.

do_health_tick || true

if claude_health_blocked; then
  log "claude health: backoff active (kind=$(claude_health_kind)) -- skipping all model work this tick"
  do_seo_tick || true
  do_market_tick || true
  exit 0
fi

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

# -- Validation sweep ------------------------------------------
#
# Per-tick pre-flight. Every bot-accessible repo runs through
# repo-checks.sh before any downstream step (maintenance, PR
# review, claimable discovery) is allowed to touch it. Repos that
# fail get the onboarding-ticket treatment (idempotent file/reopen
# via handle_onboarding_failure). Local clones are NOT purged on
# failure -- the failure handler is already idempotent, and a
# transient validation hiccup shouldn't cost a re-clone.
#
# Builds VALIDATED_REPOS_JSON: newline-separated JSON lines, one
# per passing repo, same shape that `jq -c '.[]' <<<$(forgejo_list_bot_repos)`
# would produce. Downstream loops iterate this set instead of the
# raw API response.

log "validation sweep ($BOT_USER)"
ALL_REPOS=$(forgejo_list_bot_repos)

# Analysis set: every bot-accessible repo, in the same newline-delimited
# JSON-object shape as VALIDATED_REPOS_JSON. Validation gates WORK
# (issue pickup, PR pushes, site-work); it does NOT gate read-only
# ANALYSIS (the weekly security/dep audit, which only files tickets and
# never commits). do_maintenance_tick loops this set so a repo that
# fails validation -- or has an open onboarding ticket -- still gets its
# dependencies audited; whether a finding becomes a PR (validated) or a
# human triage ticket (not) is decided per-repo in do_maintenance_for_repo.
ANALYSIS_REPOS_JSON=$(jq -c '.[]' <<<"$ALL_REPOS")
VALIDATED_REPOS_JSON=""
VAL_PASS=0
VAL_CACHED=0
VAL_FAIL=0
VAL_SKIPPED=0
VAL_INDET=0
while IFS= read -r repo_line; do
  [ -z "$repo_line" ] && continue
  R_NAME=$(jq -r '.full_name' <<<"$repo_line")

  # Short-circuit: open onboarding ticket means "this repo is
  # known-broken and the user hasn't told us it's fixed." Skip the
  # ~6-call validation pass and treat as failed. Closing the ticket
  # is the user's signal to re-validate.
  EXISTING=$(forgejo_find_marked_issue "$R_NAME" "$BOT_USER" "$ONBOARDING_MARKER" 2>/dev/null)
  if [ -n "$EXISTING" ] && [ "$EXISTING" != "null" ] && [ "$EXISTING" != "empty" ] \
      && [ "$(jq -r '.state' <<<"$EXISTING" 2>/dev/null)" = "open" ]; then
    EXISTING_NUM=$(jq -r '.number' <<<"$EXISTING" 2>/dev/null)
    log "validation: $R_NAME skipped -- open onboarding ticket #${EXISTING_NUM} (close ticket to re-validate)"
    VAL_SKIPPED=$((VAL_SKIPPED + 1))
    continue
  fi

  # Cooldown: reuse a recent PASS instead of re-running the ~6-API-call
  # validation pass every tick. Decouples validation cost from tick
  # frequency (matters at the 1-minute cadence as repos are added).
  # Only PASSes are cached; failures re-check every tick.
  if validation_fresh "$R_NAME"; then
    VALIDATED_REPOS_JSON+="${repo_line}"$'\n'
    VAL_CACHED=$((VAL_CACHED + 1))
    continue
  fi

  set +e
  V_REPORT=$(validate_repo_via_api "$R_NAME")
  V_RC=$?
  set -e
  if [ "$V_RC" -eq 0 ]; then
    VALIDATED_REPOS_JSON+="${repo_line}"$'\n'
    validation_mark_ok "$R_NAME"
    VAL_PASS=$((VAL_PASS + 1))
  elif [ "$V_RC" -eq 2 ]; then
    # Indeterminate: the Forgejo API errored mid-read, so no check
    # actually ran. A hiccup must NOT file an onboarding ticket on a
    # healthy repo (that short-circuits validation until a human
    # closes the ticket) -- skip the repo for work this tick only;
    # nothing is cached, so the next tick re-checks.
    log "validation: $R_NAME indeterminate (Forgejo API error) -- no ticket filed, re-checking next tick"
    VAL_INDET=$((VAL_INDET + 1))
  else
    log "validation: $R_NAME failed -- filing/reopening onboarding ticket"
    handle_onboarding_failure "$R_NAME" "$BOT_USER" "$V_REPORT" \
      || log "warning: onboarding handler failed on $R_NAME (token scope or repo perms); continuing"
    VAL_FAIL=$((VAL_FAIL + 1))
  fi
done < <(jq -c '.[]' <<<"$ALL_REPOS")
log "validation: ${VAL_PASS} pass, ${VAL_CACHED} cached, ${VAL_FAIL} fail, ${VAL_INDET} indeterminate, ${VAL_SKIPPED} skipped (open onboarding ticket)"

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
    latest_review=$(forgejo_pr_non_bot_reviews "$repo_full" "$pr_num" "$BOT_USER" 2>/dev/null \
      | jq -c '.[-1] // empty')
    [ -z "$latest_review" ] && continue
    review_state=$(jq -r '.state // ""' <<<"$latest_review")
    review_stale=$(jq -r '.stale // false' <<<"$latest_review")
    review_dismissed=$(jq -r '.dismissed // false' <<<"$latest_review")
    if [ "$review_state" = "REQUEST_CHANGES" ] \
        && [ "$review_stale" = "false" ] \
        && [ "$review_dismissed" = "false" ]; then
      # Synthesize the PR record into the same shape forgejo_my_assigned_prs
      # returns so the downstream flow can consume it uniformly.
      REVIEW_PR=$(jq -c --arg r "$repo_full" '. + {repository: {full_name: $r}}' <<<"$pr_details_json")
      REVIEW_PR_TRIGGER="REQUEST_CHANGES review (not stale, not dismissed)"
    fi
  done < <(jq -r '.[].number' <<<"$rc_open_prs" 2>/dev/null)
done <<<"$VALIDATED_REPOS_JSON"

# Signal 2: assignment dance (only if no request-changes signal fired)
if [ -z "$REVIEW_PR" ] && [ -n "${FORGEJO_REVIEWER:-}" ]; then
  REVIEW_PRS=$(forgejo_my_assigned_prs 2>/dev/null || echo '[]')
  REVIEW_COUNT=$(jq 'length' <<<"$REVIEW_PRS")
  if [ "$REVIEW_COUNT" -gt 0 ]; then
    REVIEW_PR=$(jq -c '.[0]' <<<"$REVIEW_PRS")
    REVIEW_PR_TRIGGER="reassigned back to bot"
  fi
fi

if [ -n "$REVIEW_PR" ]; then
    PR_NUMBER=$(jq -r .number <<<"$REVIEW_PR")
    PR_REPO=$(jq -r '.repository.full_name' <<<"$REVIEW_PR")
    PR_TITLE=$(jq -r .title <<<"$REVIEW_PR")

    log "PR-review: ${PR_REPO}#${PR_NUMBER} -- reopening (${REVIEW_PR_TRIGGER})"

    PR_DETAILS=$(forgejo_get_pr "$PR_REPO" "$PR_NUMBER" 2>/dev/null || echo '{}')
    PR_HEAD=$(jq -r '.head.ref // ""' <<<"$PR_DETAILS")
    PR_BASE=$(jq -r '.base.ref // ""' <<<"$PR_DETAILS")
    PR_BODY=$(jq -r '.body // ""' <<<"$PR_DETAILS")

    if [ -z "$PR_HEAD" ]; then
      log "PR-review: could not fetch PR details for ${PR_REPO}#${PR_NUMBER} -- skipping"
      exit 0
    fi

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

    PR_USER_MSG=$(cat <<EOF
You opened PR ${PR_REPO}#${PR_NUMBER}: ${PR_TITLE}

The human reviewer assigned the PR back to you for revisions. Read
the comments below, decide what is actionable, address them with new
commits on this branch (${PR_HEAD}), and exit. The harness will push
your commits and request the reviewer's review again (the PR is left
unassigned -- assigned-to-you means it's your turn, unassigned means
it's back in the human's court).
${PR_MERGE_CONFLICT_MSG}

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

    PR_SYSTEM_PROMPT=$(issue_system_prompt)

    cd "$PR_WORKTREE"
    log "invoking claude for PR review (timeout ${TICK_TIMEOUT})"
    PR_LOG="$PR_WORKTREE/.agent/claude-output.log"
    PR_START=$(date +%s)
    set +e
    claude_run_with_cost "pr-review" "$PR_LOG" "$TICK_TIMEOUT" \
      --model "$AGENT_MODEL_REVIEW" \
      --append-system-prompt "$PR_SYSTEM_PROMPT" \
      --settings "$AGENT_HOME/agent-settings.json" \
      --max-turns 50 \
      --print "$PR_USER_MSG"
    PR_EXIT=$?
    set -e
    PR_ELAPSED=$(( $(date +%s) - PR_START ))
    log "claude exited $PR_EXIT after ${PR_ELAPSED}s"

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

$(echo "$PR_OFFLIMITS" | sed 's/^/  - /')

Review requested so a human can review/discard." 2>/dev/null \
          || log "warning: comment failed on ${PR_REPO}#${PR_NUMBER}"
        forgejo_unassign_all "$PR_REPO" "$PR_NUMBER" 2>/dev/null || true
        forgejo_request_review "$PR_REPO" "$PR_NUMBER" "$FORGEJO_REVIEWER" 2>/dev/null || true
        (cd "$PR_REPO_PATH" && git worktree remove --force "$PR_WORKTREE") 2>/dev/null || true
        exit 0
      fi

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

      log "PR-review: pushing $PR_NEW new commits and requesting review from $FORGEJO_REVIEWER"
      git push origin "$PR_HEAD" || log "warning: push failed on $PR_HEAD"
      forgejo_unassign_all "$PR_REPO" "$PR_NUMBER" 2>/dev/null \
        || log "warning: unassign failed on ${PR_REPO}#${PR_NUMBER}"
      forgejo_request_review "$PR_REPO" "$PR_NUMBER" "$FORGEJO_REVIEWER" 2>/dev/null \
        || log "warning: review-request-to-${FORGEJO_REVIEWER} failed on ${PR_REPO}#${PR_NUMBER}"
    else
      log "PR-review: no commits made -- requesting review from $FORGEJO_REVIEWER with a note"
      forgejo_comment "$PR_REPO" "$PR_NUMBER" \
        "The agent reopened this PR after reassignment but didn't make any new commits. Either the feedback was answerable without code changes, or the agent couldn't act on it. Review requested so a human can close the loop." 2>/dev/null \
        || log "warning: comment failed on ${PR_REPO}#${PR_NUMBER}"
      forgejo_unassign_all "$PR_REPO" "$PR_NUMBER" 2>/dev/null \
        || log "warning: unassign failed on ${PR_REPO}#${PR_NUMBER}"
      forgejo_request_review "$PR_REPO" "$PR_NUMBER" "$FORGEJO_REVIEWER" 2>/dev/null \
        || log "warning: review-request-to-${FORGEJO_REVIEWER} failed on ${PR_REPO}#${PR_NUMBER}"
    fi

    forgejo_log_time "$PR_REPO" "$PR_NUMBER" "$PR_ELAPSED" \
      && log "time logged: ${PR_ELAPSED}s on ${PR_REPO}#${PR_NUMBER}" \
      || log "warning: could not log time on ${PR_REPO}#${PR_NUMBER}"

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
# Google Search Console + SMTP2GO + SEO_PRIMARY_EMAIL env; no-ops when
# unconfigured. GSC-driven, not repo-driven: emails the owner a graded
# report per domain, and for agentic sites files a deduped Agent-labeled
# ticket the discovery step below picks up once that repo is validated.
# One domain per tick spreads the GSC/email load across the 1-min beat.
if do_seo_tick; then
  exit 0
fi

# Daily market report (Mon-Fri, one email per weekday, on the first
# tick after midnight). Opt-in via the marketstack + SMTP2GO env;
# no-ops when unconfigured, on weekends, or once today's already sent.
# Scripted, email-only -- a sibling of the SEO pass, not repo-driven.
if do_market_tick; then
  exit 0
fi

# Daily sports digest (7 days a week, first tick after 03:00 -- by
# then even west-coast games are final and recapped). Opt-in via
# SPORTS_RECIPIENTS + SPORTS_LEAGUES + SMTP2GO; no-ops when
# unconfigured or once today's already sent. ESPN fetch is scripted,
# but the distill is a model call -- so unlike SEO/market this pass
# sits below the health gate and goes dark with the rest of the model
# work during a cooldown.
if do_sports_tick; then
  exit 0
fi

# Daily logwatch sweep (first tick after 01:00, once the midnight
# batch hour has closed). Convention-driven, no env knob: every
# bot-accessible repo declaring systemd/*.service gets each unit's
# local midnight-hour journal reviewed (one review-tier call per
# unit with entries; empty journal = runs elsewhere or didn't run =
# skip). Hard-failure tickets land on the owning repo unlabeled and
# assigned to FORGEJO_REVIEWER -- the human triages by adding the
# Agent label and unassigning; until then the issue grind can't see
# them.
if do_logwatch_tick; then
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
  CANDIDATES=$(forgejo_find_claimable "$R_NAME" || echo '[]')
  REPO_CONTENDER=""
  while read -r candidate; do
    [ -z "$candidate" ] && continue
    C_NUM=$(jq -r .number <<<"$candidate")

    C_HISTORY=$(forgejo_bot_prs_for_issue "$R_NAME" "$C_NUM" "$BOT_USER" 2>/dev/null || echo '[]')
    C_OPEN=$(jq '[.[] | select(.state == "open")] | length' <<<"$C_HISTORY")
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

log "claiming ${FORGEJO_REPO}#${ISSUE_NUMBER}: ${ISSUE_TITLE}"
log "branch: ${BRANCH}"

# Export the tier-1 issue context so agent-block.sh / agent-report.sh
# can find the current issue. BOT_USER and FORGEJO_REVIEWER are
# exported earlier (right after bot-identity resolution) so they're
# available to agent-ask.sh from any tick shape (tier-1, tier-3,
# PR-review, maintenance). PATH is set at the top of the script so
# all Claude invocations -- not just tier-1 -- find the harness bin.
export ISSUE_NUMBER ISSUE_TITLE FORGEJO_REPO PR_BASE

# -- Cleanup on exit (set before worktree creation) ------------

WORKTREE=""

cleanup() {
  local rc=$?
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

if [ ! -f "$REPO_PATH/CLAUDE.md" ]; then
  log "preflight: missing CLAUDE.md, blocking"
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
git fetch origin --prune
git worktree add -b "$BRANCH" "$WORKTREE" "origin/${PR_BASE}"
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

log "invoking claude (timeout ${TICK_TIMEOUT})"
CLAUDE_LOG="$WORKTREE/.agent/claude-output.log"
START_TS=$(date +%s)
set +e
claude_run_with_cost "tier-1-issue" "$CLAUDE_LOG" "$TICK_TIMEOUT" \
  --model "$AGENT_MODEL" \
  --append-system-prompt "$SYSTEM_PROMPT" \
  --settings "$AGENT_HOME/agent-settings.json" \
  --max-turns 50 \
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
DIRTY_PATHS=$(git status --porcelain 2>/dev/null \
  | awk '$2 !~ /^\.agent\// { print $2 }')
if [ -n "$DIRTY_PATHS" ]; then
  DIRTY_COUNT=$(echo "$DIRTY_PATHS" | wc -l | tr -d ' ')
  # Stage first so derive_commit_subject can see new files via
  # `git diff --cached`. See tier-3 comment for the failure mode
  # without this.
  git add -A
  COMMIT_SUBJECT=$(derive_commit_subject "$WORKTREE/.agent/PR_BODY.md" "$WORKTREE" "chore: issue #${ISSUE_NUMBER} -- ${ISSUE_TITLE}")
  log "harness-commit: $DIRTY_COUNT file(s), subject: $COMMIT_SUBJECT"
  git commit --quiet -m "$COMMIT_SUBJECT" || log "warning: harness commit failed"
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
  forgejo_log_time "$FORGEJO_REPO" "$ISSUE_NUMBER" "$ELAPSED" \
    && log "time logged: ${ELAPSED}s on ${FORGEJO_REPO}#${ISSUE_NUMBER}" \
    || log "warning: could not log time on ${FORGEJO_REPO}#${ISSUE_NUMBER}"

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
  # shipped; the human splits the work into smaller issues.
  CHANGED=$(git diff --shortstat "origin/${PR_BASE}..HEAD" 2>/dev/null \
    | awk '{ for (i=1;i<=NF;i++) if ($i ~ /insertion|deletion/) s+=$(i-1); print s+0 }')
  CHANGED=${CHANGED:-0}
  if [ "$COMMITS" -gt 10 ] || [ "$CHANGED" -gt 400 ]; then
    # OUTCOME: blocked
    log "outcome: blocked (scope: $COMMITS commits, $CHANGED lines)"
    FILES=$(git diff --name-only "origin/${PR_BASE}..HEAD" | head -30 | sed 's/^/  - /')
    agent-block.sh "Scope exceeded: this branch reached **${COMMITS} commits / ${CHANGED} changed lines**, over the per-issue cap (10 commits / 400 lines).

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

$(echo "$OFFLIMITS" | sed 's/^/  - /')

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
  else
    PR_TITLE=$(git log -1 --pretty=%s)
    if [ -f .agent/PR_BODY.md ]; then
      PR_BODY=$(cat .agent/PR_BODY.md)
    else
      log "WARNING: PR_BODY.md was NOT written by claude this tick. AGENTS.md requires it on every ship; this is not optional. Attempting harness-side fallback via Haiku."
      PR_BODY=$(derive_pr_body "$WORKTREE" "$PR_BASE")
      if [ -n "$PR_BODY" ]; then
        log "harness-side PR body synthesized via Haiku from diff"
      else
        log "WARNING: Haiku fallback also failed; using git-log-derived body. PR description will be thin."
        PR_BODY=$(git log "origin/${PR_BASE}..HEAD" --reverse --format='### %s%n%n%b%n')
      fi
    fi
    PR_BODY+=$(build_deps_section "$PR_BASE")
    PR_BODY+=$'\n\nCloses #'"$ISSUE_NUMBER"

    NEW_PR_NUMBER=$(forgejo_open_pr "$FORGEJO_REPO" "$BRANCH" "$PR_BASE" "$PR_TITLE" "$PR_BODY" "${FORGEJO_REVIEWER:-}")
    log "PR opened${NEW_PR_NUMBER:+ (#$NEW_PR_NUMBER)}"
  fi

  # Record Claude's wall-clock on the ISSUE (Forgejo time tracking).
  # Split rationale: the agent's coding time belongs on the issue (his
  # work); reviewer time belongs on the PR (the human's work during
  # review). PR-review ticks log on the PR. Discretionary ticks (no
  # issue) log on the PR they create. Best-effort; never fail the
  # tick over this.
  forgejo_log_time "$FORGEJO_REPO" "$ISSUE_NUMBER" "$ELAPSED" \
    && log "time logged: ${ELAPSED}s on ${FORGEJO_REPO}#${ISSUE_NUMBER} (issue)" \
    || log "warning: could not log time on ${FORGEJO_REPO}#${ISSUE_NUMBER}"

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
