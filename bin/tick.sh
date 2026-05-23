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
: "${ANTHROPIC_API_KEY:?must be set in $env_file_hint}"
: "${AGENT_MODEL:?must be set in $env_file_hint}"
: "${AGENT_MODEL_THINKING:?must be set in $env_file_hint}"
: "${FORGEJO_URL:?must be set in $env_file_hint}"
: "${FORGEJO_TOKEN:?must be set in $env_file_hint}"
: "${FORGEJO_HOST:?must be set in $env_file_hint}"
: "${FORGEJO_REVIEWER:?must be set in $env_file_hint}"
: "${REDIS_URL:?must be set in $env_file_hint}"
: "${TICK_TIMEOUT:?must be set in $env_file_hint}"
: "${AGENT_SHIFT_START:?must be set in $env_file_hint}"
: "${AGENT_SHIFT_END:?must be set in $env_file_hint}"
: "${AGENT_RECALL_DAYS:?must be set in $env_file_hint}"
unset env_file_hint

# -- Library ----------------------------------------------------

# shellcheck source=lib/forgejo.sh
. "$AGENT_HOME/lib/forgejo.sh"
# shellcheck source=lib/repo-checks.sh
. "$AGENT_HOME/lib/repo-checks.sh"
# shellcheck source=lib/rag.sh
. "$AGENT_HOME/lib/rag.sh"
# shellcheck source=lib/cost.sh
. "$AGENT_HOME/lib/cost.sh"

# Children (discretionary executors, agent-* scripts) re-source
# lib/rag.sh and share our per-tick build marker via $TICK_PID.
# Without this, each child would think it owns the build and either
# duplicate the ~25s flush+rebuild or fail to find the marker.
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

# Brain + website paths derived from the bot user. Exported so every
# Claude Code invocation (tier-1, PR-review, maintenance, site-work)
# can resolve absolute paths into the bot's own repos -- e.g. writing
# memory files to $AGENT_BRAIN_PATH/memories/projects/X.md from inside
# a worktree that's on a different repo. Without these exported,
# AGENTS.md's instruction to "use $AGENT_BRAIN_PATH" is a dead
# reference.
export AGENT_BRAIN_PATH="$AGENT_REPO_ROOT/${BOT_USER}/brain"
export AGENT_WEBSITE_PATH="$AGENT_REPO_ROOT/${BOT_USER}/website"

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

# Build the full system prompt for a Claude invocation. Ordered
# for prompt-cache stability: most-stable first, volatile last so
# changes to a downstream file don't invalidate the upstream
# cached prefix.
#
# Order (and why):
#   AGENTS.md           -- protocol/rules, changes by PR only
#   identity.md         -- who I am, changes by PR only
#   memories/MEMORY.md  -- memory index, edited by Claude OCCASIONALLY
#                          (when he adds a new memory file)
#
# Files Claude edits FREQUENTLY mid-tick (notably blog-ideas.md)
# are intentionally NOT loaded here. Loading them in-prompt
# guarantees cache invalidation every time he writes -- the cost
# of always-loaded blog-ideas exceeds the benefit. AGENTS.md
# documents that Claude reads brain/blog-ideas.md on demand
# (via the Read tool) when shipping/considering a post.
#
# Args:
#   $1 -- path to local brain clone
#
# Each file is optional -- missing files are skipped. Caller
# supplies the per-tick user message separately.
brain_system_prompt() {
  local brain="$1"
  local files=("$AGENT_HOME/AGENTS.md")
  [ -f "$brain/identity.md" ]         && files+=("$brain/identity.md")
  [ -f "$brain/memories/MEMORY.md" ]  && files+=("$brain/memories/MEMORY.md")
  cat "${files[@]}"
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
# Two flavors: pipe form (stdin -> stdout) and in-place file form.
normalize_unicode_dashes() {
  # If args given, treat as input text; otherwise read stdin.
  if [ "$#" -gt 0 ]; then
    printf '%s' "$*" | sed -e 's/–/--/g' -e 's/—/--/g'
  else
    sed -e 's/–/--/g' -e 's/—/--/g'
  fi
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
  for f in PR_BODY.md AGENT_JOURNAL.md AGENT_MAINTENANCE_FINDINGS.md; do
    normalize_unicode_dashes_in_file "$worktree/.agent/$f"
  done
}

# Run `claude --print` with stream-json output so the tick keeps live
# progress in journalctl AND we can extract the precomputed
# total_cost_usd from the final result event for the ledger.
#
# Pipeline shape:
#   claude (stream-json) -> tee raw-stream-log -> jq display-text -> tee display-log
#
# Raw stream log holds every event (one JSON object per line) for
# post-run cost extraction + debugging. Display log + journalctl get
# the same readable text the old plain --print mode produced.
#
# Args: <call_site> <display_log_path> <timeout_spec> <claude_args...>
# Returns: claude's exit code (PIPESTATUS[0] captured into $?)
#
# Sets globals (read by the caller after return):
#   CLAUDE_RUN_STREAM_LOG -- path to the raw stream-json file
claude_run_with_cost() {
  local call_site="$1" display_log="$2" timeout_spec="$3"
  shift 3
  local scratch
  scratch=$(dirname "$display_log")
  local stream_log="$scratch/claude-stream.jsonl"
  CLAUDE_RUN_STREAM_LOG="$stream_log"
  : > "$stream_log"
  : > "$display_log"
  # stderr inline with stdout (old behavior); jq filter drops
  # non-JSON lines so stray stderr doesn't break the pipeline.
  # --verbose is required by Claude Code when using stream-json
  # with --print (it refuses without it).
  set +e
  set -o pipefail
  timeout --kill-after=30s "$timeout_spec" \
    claude --output-format stream-json --verbose --include-partial-messages "$@" 2>&1 \
    | tee "$stream_log" \
    | jq -r --unbuffered '
        if (try .type catch null) == "assistant" then
          (.message.content // [])[]
          | if .type == "text" then .text
            elif .type == "tool_use" then "[tool: \(.name)]"
            else empty
            end
        elif (try .type catch null) == "user" then
          (.message.content // [])[]
          | if .type == "tool_result" then "[tool_result]"
            else empty
            end
        else empty
        end
      ' 2>/dev/null \
    | tee "$display_log"
  local rc=${PIPESTATUS[0]}
  set +o pipefail
  set -e
  cost_record_cli "$call_site" "$stream_log"
  return "$rc"
}

# Model defaults to Haiku (cheap, fast, good enough for short
# completions). Override via AGENT_MODEL_THINKING. Returns the text
# of the response on stdout; empty on failure.
#
# Optional 4th arg: a call-site tag for the cost ledger. If unset,
# the call is logged as "claude-complete" (still tracked, but the
# caller could be more specific -- "commit-subject", "cadence", etc).
claude_complete() {
  local system_prompt="$1" user_msg="$2"
  local model="${AGENT_MODEL_THINKING:-claude-haiku-4-5-20251001}"
  local max_tokens="${3:-256}"
  local call_site="${4:-claude-complete}"
  local response
  response=$(curl -sf -X POST https://api.anthropic.com/v1/messages \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "Content-Type: application/json" \
    --max-time 30 \
    -d "$(jq -n \
      --arg m "$model" \
      --argjson mt "$max_tokens" \
      --arg s "$system_prompt" \
      --arg u "$user_msg" \
      '{model: $m, max_tokens: $mt, system: $s, messages: [{role: "user", content: $u}]}')" \
    2>/dev/null) || return 1
  cost_record_api "$call_site" "$model" "$response"
  jq -r '.content[0].text // ""' <<<"$response" 2>/dev/null
}

# Return 0 if the subject looks like a conventional commit
# ("type: description" with a known type). Used to reject API
# responses that are conversational rather than subject-shaped.
looks_like_conventional_commit() {
  local s="$1"
  [[ "$s" =~ ^(feat|fix|chore|docs|style|refactor|test|perf|build|ci|revert):[[:space:]]+.+ ]]
}

# Ensure a conventional-commit prefix. If the subject already has
# one (feat:/fix:/chore:/etc.), return unchanged. Otherwise prepend
# `chore: ` as a safe default so the PR title isn't bare imperative
# prose like "Update X" with no type marker.
normalize_subject() {
  local s="$1"
  if looks_like_conventional_commit "$s"; then
    printf '%s' "$s"
  else
    printf 'chore: %s' "$s"
  fi
}

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
    subject=$(awk '
      /^## What this PR does/ { in_section = 1; next }
      /^## / && in_section { exit }
      in_section && /^- \[[x ]\] / {
        sub(/^- \[[x ]\] /, "")
        print
        exit
      }
    ' "$pr_body")
    if [ -n "$subject" ]; then
      normalize_subject "$subject"
      return 0
    fi
  fi

  # Tier 2: API-generated from the staged diff
  if [ -n "$worktree" ] && [ -d "$worktree" ]; then
    local diff_summary
    diff_summary=$( (
      cd "$worktree" && {
        git diff --cached --stat 2>/dev/null
        echo "---"
        git diff --cached 2>/dev/null | head -200
      }
    ) 2>/dev/null)
    # Only call the API if we actually have changes to describe.
    # `--stat` is empty when nothing's staged; the divider alone
    # without it isn't worth burning an API call on.
    if printf '%s' "$diff_summary" | grep -q "files\? changed"; then
      local api_subject
      api_subject=$(claude_complete \
        "You generate ONE single-line conventional-commit subject. Output ONLY the subject line -- no quotes, no preamble, no explanation, no questions. Format: 'type: description' where type is one of feat/fix/chore/docs/style/refactor/test. Under 72 chars. Imperative mood ('Add X' not 'Added X'). Be specific about what changed. If the input is empty or you cannot tell what changed, output exactly: chore: tick work" \
        "$diff_summary" \
        80 \
        "commit-subject")
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
# reviewer's time. Better to spend a cent on Haiku to synth a real
# description than ship a one-liner.
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
  body=$(claude_complete \
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
    "$diff_summary" \
    800 \
    "pr-body-fallback")

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

# Returns 0 (is duplicate) if the source journal's entire content
# appears verbatim as a substring of the target journal file. Strict
# match -- only true byte-for-byte copies are skipped. Previous
# implementation used a 200-char prefix probe which false-positived
# on entries that shared an opening structure ("Read X today.
# Took Y..."), eating legitimately new entries. The strict match
# trades some occasional duplicate-let-through for never losing real
# content.
journal_is_duplicate() {
  local source_file="$1" target_file="$2"
  [ -f "$target_file" ] || return 1
  [ -s "$source_file" ] || return 1
  local new_content target_content
  new_content=$(cat "$source_file")
  target_content=$(cat "$target_file")
  [[ "$target_content" == *"$new_content"* ]]
}

# Append a journal entry to today's brain journal. ALWAYS writes
# the "## TS -- <mode-suffix>" header so the recent_modes signal
# in discretionary_assess_cadence reflects every tick that actually
# fired, regardless of whether Claude voluntarily wrote a body.
# Header = existence proof of the tick. Body = Claude's reflection,
# if any.
#
# Args:
#   $1 -- mode-suffix (free-form text after the "-- " in the header).
#         The cadence parser keys off this:
#           "discretionary reading"   -> read mode
#           "discretionary on <repo>" -> work mode
#           "<owner>/<repo>#<num>"    -> work mode (tier-1 issue)
#   $2 -- (optional) path to a body source file. When present and
#         non-empty and not a byte-identical duplicate of today's
#         existing content, the file contents land under the header.
#         Otherwise a short placeholder body lands so the heading
#         isn't orphan.
append_journal_entry() {
  local mode_suffix="$1" body_src="${2:-}"
  local brain="${AGENT_BRAIN_PATH:-${BRAIN_PATH:-$AGENT_REPO_ROOT/${BOT_USER}/brain}}"
  local journal_date journal_file journal_ts body
  journal_date=$(date +%Y-%m-%d)
  journal_file="$brain/journal/${journal_date}.md"
  journal_ts=$(date +%Y-%m-%dT%H:%M:%S%z)
  mkdir -p "$(dirname "$journal_file")"

  body="(no body -- tick completed without a journal entry)"
  if [ -n "$body_src" ] && [ -s "$body_src" ]; then
    if journal_is_duplicate "$body_src" "$journal_file"; then
      log "journal: body duplicates an earlier entry today -- header only"
      body="(no body -- duplicate of an earlier entry today)"
    else
      body=$(cat "$body_src")
    fi
  fi

  {
    printf '\n## %s -- %s\n\n' "$journal_ts" "$mode_suffix"
    printf '%s\n' "$body"
  } >> "$journal_file"
  log "journal: appended (${mode_suffix})"
}

# Idempotent clone-if-missing, pull-if-present. Creates the owner
# subdir as needed. Pulls existing clones so brain identity changes
# and website content updates propagate to the agent on every tick.
#
# Self-healing for dirty trees: a crashed tick (W_LOG-style unbound
# var, OOM, timeout, etc.) can mutate working-tree files but never
# reach the commit step, leaving the repo in a state where every
# subsequent `git pull --rebase` refuses to run. The warning was
# the only signal and the silent rot meant brain stopped getting
# new commits for hours at a time.
#
# Fix: at tick start, if any tracked file is dirty, auto-commit
# the leftover state with a `recovery:` subject and try to push.
# The commit captures whatever the previous tick was writing (likely
# blog-ideas.md edits, journal appends, sources weight adjustments)
# instead of leaving them orphaned in the working tree. Pull then
# succeeds against either the just-pushed origin or a clean local
# tree.
ensure_repo_local() {
  local repo="$1" local_path
  local_path=$(repo_path_for "$repo")
  if [ ! -d "$local_path/.git" ]; then
    log "bootstrap: cloning $repo to $local_path"
    mkdir -p "$(dirname "$local_path")"
    git clone "$(ssh_clone_url "$repo")" "$local_path"
    return
  fi

  # Detect uncommitted changes (staged or unstaged, tracked files
  # only). Untracked files aren't counted -- they don't block
  # git pull --rebase and we don't want to sweep them up blindly.
  if ! (cd "$local_path" \
        && git diff --quiet HEAD 2>/dev/null \
        && git diff --cached --quiet 2>/dev/null); then
    local dirty_summary
    dirty_summary=$(cd "$local_path" && git status --short 2>/dev/null | head -10)
    log "warning: $repo has uncommitted changes from a prior tick:"
    while IFS= read -r line; do
      [ -n "$line" ] && log "  $line"
    done <<<"$dirty_summary"
    (cd "$local_path" && git add -A 2>/dev/null) || true
    # Pre-commit lint gate (no-op for non-brain repos -- see
    # repo_lint_passes). If brain's dirty state itself is what's
    # breaking lint, don't push more broken content. Leave dirty
    # and surface; a future tick or human can untangle.
    if ! repo_lint_passes "$local_path"; then
      log "  warning: $repo lint failed on dirty state; refusing recovery commit. Inspect: (cd $local_path && npm test)"
    elif (cd "$local_path" \
          && git commit --quiet -m "recovery: auto-commit leftover changes from prior tick" 2>/dev/null); then
      log "  recovery commit created in $repo"
      if (cd "$local_path" && git push --quiet origin 2>/dev/null); then
        log "  recovery commit pushed"
      else
        log "  warning: push of recovery commit failed; will retry next tick"
      fi
    else
      log "  warning: recovery commit failed; pull will likely still fail"
    fi
  fi

  (cd "$local_path" && git pull --rebase --quiet origin 2>/dev/null) \
    || log "warning: pull of $repo failed; using stale local copy"
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

# Eligible if not run this local calendar week. Weekly cadence aligns
# with the Monday-morning maintenance shift -- one audit per repo per
# week, biased to Mondays. Same-week re-runs are blocked.
#
# Skips:
# - Repos with an open onboarding ticket. Issue-work refused to clone
#   them for cause; maintenance shouldn't sneak around that gate.
#
# Bot-owned repos (brain, website, the agent itself) are NOT excluded
# -- they have real audit surface (website has npm deps, agent has
# requirements.txt) and security findings matter there too. Repos
# with no detectable stack (brain is just markdown) naturally no-op
# under the auto-detection branch of the maintenance prompt -- one
# wasted Claude call per week per such repo, acceptable cost.
maintenance_eligible() {
  local repo="$1" last last_week this_week existing

  existing=$(forgejo_find_marked_issue "$repo" "$BOT_USER" "$ONBOARDING_MARKER" 2>/dev/null)
  if [ -n "$existing" ] && [ "$existing" != "null" ] && [ "$existing" != "empty" ]; then
    if [ "$(jq -r '.state' <<<"$existing" 2>/dev/null)" = "open" ]; then
      return 1
    fi
  fi

  last=$(maintenance_last_run "$repo")
  [ -z "$last" ] && return 0
  # ISO week (YYYY-Www): local time, same week = blocked
  last_week=$(date -d "$last" +%G-W%V 2>/dev/null \
    || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last" +%G-W%V 2>/dev/null \
    || echo "")
  this_week=$(date +%G-W%V)
  [ "$last_week" != "$this_week" ]
}

# Are we in the configured Monday-morning maintenance window?
# True when: today is Monday AND we're inside the configured shift.
# When shift is unconfigured, this returns false (no scheduled
# maintenance). Maintenance is a scheduled chore that runs once per
# week per repo at the top of priority on Monday morning; the rest
# of the week has no maintenance work.
in_maintenance_window() {
  local dow
  dow=$(date +%u)  # 1=Mon, 7=Sun
  [ "$dow" = "1" ] || return 1
  in_shift_window
}

# Scheduled maintenance pass -- priority 1 in the work cascade.
# Runs during the Monday-morning shift window. One repo per tick,
# weekly cap per repo. Exits 0 if maintenance fires; returns 1
# when not in the window or no repos are eligible this week (so
# the caller falls through to PR review / issues / discretionary).
#
# Findings flow: Claude writes .agent/AGENT_MAINTENANCE_FINDINGS.md,
# harness files a Status/Need More Info issue for human triage.
do_maintenance_tick() {
  in_maintenance_window || return 1

  local repos r_name target target_path target_base
  local ELIGIBLE=()
  repos=$(forgejo_list_bot_repos)
  while read -r repo_line; do
    [ -z "$repo_line" ] && continue
    r_name=$(jq -r '.full_name' <<<"$repo_line")
    if maintenance_eligible "$r_name"; then
      ELIGIBLE+=("$r_name")
    fi
  done < <(jq -c '.[]' <<<"$repos")

  if [ "${#ELIGIBLE[@]}" -eq 0 ]; then
    log "scheduled: no repos eligible for maintenance this week -- continuing"
    return 1
  fi

  target="${ELIGIBLE[RANDOM % ${#ELIGIBLE[@]}]}"
  log "scheduled: maintenance pass on $target"

  ensure_repo_local "$target"
  target_path=$(repo_path_for "$target")

  # Detached-HEAD worktree on the repo's current default branch.
  # No feature branch -- maintenance doesn't commit; it writes
  # findings to a known path that the harness reads after exit.
  target_base=$(cd "$target_path" && git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
  target_base="${target_base:-master}"
  local m_worktree="$AGENT_STATE_DIR/worktrees/maintenance-${target//\//_}-$$"
  mkdir -p "$AGENT_STATE_DIR/worktrees"
  (cd "$target_path" && git fetch --prune origin)
  (cd "$target_path" && git worktree add --detach "$m_worktree" "origin/${target_base}")
  init_igor_scratch "$m_worktree"

  # Worktree cleanup at script exit. Variables M_WT_PATH/M_TGT_PATH
  # need global scope so the trap can see them.
  M_WT_PATH="$m_worktree"
  M_TGT_PATH="$target_path"
  trap '[ -d "$M_WT_PATH" ] && (cd "$M_TGT_PATH" && git worktree remove --force "$M_WT_PATH") 2>/dev/null || true; rag_cleanup_marker' EXIT

  cd "$m_worktree"

  local m_brain="$AGENT_REPO_ROOT/${BOT_USER}/brain"

  # RAG context: prior maintenance findings, related commits, any
  # journal entries about this repo. Helps catch repeat-offender
  # findings vs the first-time surface.
  local m_rag_context
  m_rag_context=$(AGENT_BRAIN_PATH="$m_brain" rag_query "maintenance pass on $target")
  [ -n "$m_rag_context" ] && log "rag: surfaced past context for maintenance"

  local m_user_msg
  m_user_msg=$(cat <<EOF
You are doing a scheduled maintenance pass on $target.

No human is waiting on you. Your job:

  1. Read this repo's CLAUDE.md. If it has a "Maintenance" section,
     follow it -- that's the repo author declaring exactly what
     maintenance means here.
  2. Otherwise, auto-detect the stack and run the standard audit
     plus dep-freshness commands for the ecosystem:
       - package.json     -> npm audit + npm outdated
       - Cargo.toml       -> cargo audit + cargo outdated
       - pyproject.toml/requirements.txt -> pip-audit + pip list --outdated
       - go.mod           -> govulncheck + go list -m -u all
       - Gemfile          -> bundle audit + bundle outdated
     If a tool isn't installed, install it within this session
     (cargo install cargo-audit, etc.). Use judgment for stacks not
     listed above.
  3. If anything notable surfaces -- vulnerabilities, outdated
     deps, broken links, regressions -- write a markdown summary
     to .agent/AGENT_MAINTENANCE_FINDINGS.md. The harness will file
     an issue with that content for human triage.
  4. If nothing notable, skip the findings file and exit cleanly.

Don't commit fixes during a maintenance pass -- file findings and
let normal work flow address them on a future tick. Same content
rules as always: identity guardrails apply.

---

## Past context (RAG)

${m_rag_context:-(no past context retrieved this tick)}
EOF
)

  local m_system_prompt
  m_system_prompt=$(brain_system_prompt "$m_brain")

  log "invoking claude for maintenance (timeout ${TICK_TIMEOUT})"
  local m_log="$m_worktree/.agent/claude-output.log"
  local m_start; m_start=$(date +%s)
  local m_exit
  set +e
  claude_run_with_cost "maintenance" "$m_log" "$TICK_TIMEOUT" \
    --model "$AGENT_MODEL" \
    --append-system-prompt "$m_system_prompt" \
    --settings "$AGENT_HOME/agent-settings.json" \
    --max-turns 50 \
    --print "$m_user_msg"
  m_exit=$?
  set -e
  log "claude exited $m_exit after $(( $(date +%s) - m_start ))s"

  normalize_worktree_dashes "$m_worktree"

  local findings="$m_worktree/.agent/AGENT_MAINTENANCE_FINDINGS.md"
  if [ -s "$findings" ]; then
    local m_title m_body m_num
    m_title="Maintenance pass $(date +%Y-%m-%d): findings"
    m_body=$(cat "$findings")
    m_num=$(forgejo_open_issue "$target" "$m_title" "$m_body")
    forgejo_add_label "$target" "$m_num" "Status/Need More Info" 2>/dev/null \
      || log "warning: could not apply 'Status/Need More Info' on #$m_num ($target)"

    local m_priority_file="$m_worktree/.agent/AGENT_MAINTENANCE_PRIORITY"
    if [ -s "$m_priority_file" ]; then
      local m_priority m_pri_label=""
      m_priority=$(tr -d '[:space:]' < "$m_priority_file" | tr '[:upper:]' '[:lower:]')
      case "$m_priority" in
        critical) m_pri_label="Priority/Critical" ;;
        high)     m_pri_label="Priority/High" ;;
        medium)   m_pri_label="Priority/Medium" ;;
        low)      m_pri_label="Priority/Low" ;;
      esac
      if [ -n "$m_pri_label" ]; then
        forgejo_add_label "$target" "$m_num" "$m_pri_label" 2>/dev/null \
          || log "warning: could not apply '$m_pri_label' on #$m_num ($target)"
      fi
    fi

    log "maintenance: filed #$m_num on $target (awaiting human triage)"
  else
    log "maintenance: no findings on $target"
  fi

  maintenance_mark_done "$target"
  exit 0
}

# Post cooldown. One post per local calendar day on the agent's own blog.
# Calendar-day semantics (not rolling 24h) so "once a day" matches
# what a human means -- the day ticks over at local midnight.
#
# Reads from reality, scoped strictly to TODAY:
#
#   (a) origin/master tree contains a post file whose filename
#       begins with today's date (src/posts/YYYY/YYYY-MM-DD-...)
#       -> already shipped today, cooldown fires.
#   (b) open bot PRs adding a post file whose filename begins
#       with today's date (checked by the caller as
#       W_INFLIGHT_POST, NOT by this function) -> today's slot
#       is in flight, cooldown fires.
#
# An open PR carrying YESTERDAY's post (still awaiting review)
# does NOT block today's posting slot. A closed-without-merge PR
# from any day leaves no trace. Tomorrow's tick is similarly
# scoped to tomorrow's date and unaffected by yesterday's open
# PRs.
#
# State files used to be a third source here, but they drifted
# out of sync with reality when ticks crashed mid-flow. Dropped
# entirely; filename-date in master + open PRs is the only truth.
#
# Only gates posts -- other site work (about page, layout, copy)
# and read+journal ticks are unthrottled.
posts_cooldown_clear() {
  local today website_path
  today=$(date +%Y-%m-%d)

  website_path=$(repo_path_for "${BOT_USER}/website")
  if [ ! -d "$website_path/.git" ]; then
    # Bootstrap case: no clone yet. Default to allowed -- a duplicate
    # post on the very first run is acceptable; refusing to ever
    # post until the clone exists is worse.
    return 0
  fi

  # Fetch origin master so the tree check sees current truth, not
  # a stale local copy. Best-effort -- a transient fetch failure
  # means we look at whatever's already in origin/master, which
  # the top-of-tick ensure_repo_local pulled. Bounded cost.
  (cd "$website_path" && git fetch --quiet origin master 2>/dev/null) || true

  # Check the CURRENT TREE of origin/master for a post file whose
  # filename starts with today's date. The earlier version of this
  # check looked at git log --since/--until (commit date), which
  # confused backdated commits and same-day reverts. The filename
  # date is what matters -- "did the agent publish a post FOR today?"
  # -- and that's recoverable from a tree listing without ambiguity.
  local today_re="^src/posts/[0-9]{4}/${today}-.+\\.md$"
  local today_count
  today_count=$(cd "$website_path" \
    && git ls-tree --name-only -r origin/master 2>/dev/null \
    | grep -cE "$today_re" || true)
  if [ "${today_count:-0}" -gt 0 ]; then
    return 1
  fi

  return 0
}

# Kept as a no-op so any leftover call sites don't error out. Post
# cooldown no longer relies on state -- it reads git log on origin
# master. Remove this function (and any callers) in a follow-up
# cleanup; left in place to keep this PR scoped to the behavior fix.
posts_mark_shipped() {
  return 0
}

# Commit any pending mutations to the brain repo. Stages the three
# harness-writable surfaces (journal/, memories/, blog-ideas.md),
# commits with the given subject if anything is staged, and pushes.
#
# Called unconditionally at end-of-tick. The previous design gated
# the entire commit block on "Claude wrote an AGENT_JOURNAL.md this
# tick" -- which left dedupe edits, reflection swaps, source-weight
# adjustments, and any other harness-side brain mutations orphaned
# in the working tree. The recovery-commit step at next tick start
# eventually picked them up, but that masked the bug: every tick
# was leaving brain dirty and relying on the next tick to clean up.
#
# Now: journal append is one step (still gated on journal source
# existing); commit-brain-changes is a separate step that ALWAYS
# runs and is a no-op when there's truly nothing staged.
commit_brain_changes() {
  local brain="$1" subject="$2"
  [ -d "$brain/.git" ] || return 0

  # No pre-commit pull. The earlier version did `git pull --rebase`
  # here as belt-and-suspenders, but by the time we reach this
  # function the tick has already mutated brain (journal appended,
  # ledgers updated, weights tweaked). The dirty tree blocks the
  # rebase and the warning "brain pull failed before commit" fired
  # on every tick that touched brain -- a confusing false alarm,
  # because the subsequent commit + push almost always succeeded.
  # ensure_repo_local at tick start handles the legitimate sync;
  # if origin moved during our tick, the push below will fail
  # loudly with non-fast-forward and the NEXT tick's ensure_repo_local
  # reconciles.

  # Stage everything the harness writes. -A within each pathspec
  # captures adds / mods / deletes uniformly.
  (cd "$brain" && git add -A journal/ memories/ blog-ideas.md 2>/dev/null) || true

  # No-op if nothing is staged -- the common case for ticks that
  # didn't touch brain at all.
  if (cd "$brain" && git diff --cached --quiet 2>/dev/null); then
    return 0
  fi

  # Pre-commit lint gate. If brain has `npm test` configured and it
  # fails on the staged content, refuse to commit -- pushing broken
  # content would just fail brain's CI on every commit until a human
  # cleans it up. Better to leave brain dirty locally so the
  # divergence is visible and a future tick can fix the lint issue
  # before piling on more.
  if ! repo_lint_passes "$brain"; then
    log "warning: brain lint failed -- refusing to commit. Brain stays dirty locally. Run: (cd $brain && npm test) to see why."
    (cd "$brain" && git reset --quiet HEAD -- journal/ memories/ blog-ideas.md 2>/dev/null) || true
    return 1
  fi

  if (cd "$brain" && git commit --quiet -m "$subject" 2>/dev/null); then
    if ! (cd "$brain" && git push --quiet origin master 2>/dev/null); then
      log "warning: brain push failed for: $subject (commit is local; next tick will reconcile via ensure_repo_local)"
    fi
  else
    log "warning: brain commit failed for: $subject"
  fi
}

# Returns 0 if the repo passes its declared lint, OR if no lint
# is configured. Best-effort: missing toolchain (no package.json,
# no node_modules, no npm) is treated as "no lint" (pass) so
# non-brain repos and unconfigured hosts no-op cleanly. Currently
# scoped to npm-based lint -- extend per stack as other repos
# start needing pre-commit gating.
repo_lint_passes() {
  local repo_path="$1"
  [ -f "$repo_path/package.json" ] || return 0
  [ -d "$repo_path/node_modules" ] || return 0
  command -v npm >/dev/null 2>&1 || return 0
  (cd "$repo_path" && npm test --silent >/dev/null 2>&1)
}

# Cadence assessment. Called on EVERY discretionary tick to decide
# whether to ship more work or take a break to read & reflect. The
# choice gates BOTH post and site-work modes -- a heavy queue can
# overrule even an open posting slot.
#
# Inputs: today's real activity (open PRs, commits across all clones,
# brain journal entries, post landed yes/no) AND whether posting is
# eligible this tick (so Haiku knows "work" means post-something-big
# vs file-an-issue).
#
# Bias is in the prompt, not in code: reading is cheap; lean toward
# it when the day's been substantial; pick work when the queue is
# light or nothing's shipped yet. Failure (API error, parse error)
# defaults to "work" -- shipping is the default mode, reading is
# the opt-in break.
#
# Output: "<choice>|<reason>" on stdout (caller splits on the first
# pipe). No JSON parsing burden for the caller.
discretionary_assess_cadence() {
  local active_prs="$1"
  local posting_allowed="$2"
  local open_prs="${3:-$active_prs}"  # total open count; defaults to active if not passed
  local today work_reflections_today commits_today repo_dir count post_today prs_opened_today recent_modes
  today=$(date +%Y-%m-%d)

  # WORK reflections logged today: count of harness-written tick
  # headers EXCLUDING reading-mode entries. Including reading would
  # be a self-licking ice-cream cone -- each reading tick bumps the
  # count, which the cadence then reads as "active day", which
  # justifies more reading. Only tier-1 / site-work / maintenance /
  # post / PR-review reflections count as "did real work".
  local journal_file="${BRAIN_PATH:-}/journal/${today}.md"
  if [ -n "${BRAIN_PATH:-}" ] && [ -f "$journal_file" ]; then
    work_reflections_today=$(grep -E '^## [0-9]+-[0-9]+-[0-9]+T' "$journal_file" 2>/dev/null \
      | grep -vcE -- '-- discretionary reading$' || echo 0)
  else
    work_reflections_today=0
  fi

  # Recent tick modes (last 5 reflections, newest last). Tells the
  # cadence assessor what the bot was JUST doing -- without this it
  # decides fresh each tick from raw counters and can roll "read"
  # five times in a row without noticing.
  recent_modes=""
  if [ -n "${BRAIN_PATH:-}" ] && [ -f "$journal_file" ]; then
    recent_modes=$(grep -E '^## [0-9]+-[0-9]+-[0-9]+T' "$journal_file" 2>/dev/null \
      | tail -5 \
      | sed -E 's/.*-- discretionary reading$/read/; s/.*-- discretionary on .*/work/; s/.*-- [^ ]+\/[^#]+#.*/work/; s/^## .*/work/' \
      | paste -sd, -)
  fi
  [ -n "$recent_modes" ] || recent_modes="(none yet today)"

  # Today's commits across cloned repos. No author filter: Josh's
  # commits to brain (manual edits) also count as "stuff happened
  # today" from the agent's perspective.
  commits_today=0
  if [ -d "${AGENT_REPO_ROOT:-}/${BOT_USER}" ]; then
    for repo_dir in "$AGENT_REPO_ROOT/${BOT_USER}"/*; do
      [ -d "$repo_dir/.git" ] || continue
      count=$(cd "$repo_dir" \
        && git log --since="$today 00:00:00" --until="$today 23:59:59" \
            --no-merges --oneline 2>/dev/null | wc -l | tr -d ' ')
      commits_today=$((commits_today + ${count:-0}))
    done
  fi

  # PRs the agent authored TODAY across the website repo, regardless of
  # current state. Open + merged + closed-without-merge all count
  # as "The agent shipped work today" -- the cadence is asking whether
  # the day's been productive, not whether the queue is reviewed.
  # state=all + user.login filter + created_at-startswith-today.
  prs_opened_today=0
  if [ -n "${BOT_USER:-}" ]; then
    prs_opened_today=$(_fj GET "/repos/${BOT_USER}/website/pulls?state=all&sort=newest&limit=50" 2>/dev/null \
      | jq --arg u "$BOT_USER" --arg today "$today" \
          '[.[] | select(.user.login == $u) | select(.created_at | startswith($today))] | length' 2>/dev/null \
      || echo 0)
  fi

  # Did a post land on website master today?
  post_today=0
  if [ -d "${AGENT_REPO_ROOT:-}/${BOT_USER}/website/.git" ]; then
    local merged_count
    merged_count=$(cd "$AGENT_REPO_ROOT/${BOT_USER}/website" \
      && git log --since="$today 00:00:00" --until="$today 23:59:59" \
          origin/master --diff-filter=A --name-only --pretty=format: \
          -- 'src/posts/*' 2>/dev/null \
      | grep -cE '^src/posts/.+\.md$' || true)
    [ "${merged_count:-0}" -gt 0 ] && post_today=1
  fi

  local posting_label work_label
  if [ "$posting_allowed" = "1" ]; then
    posting_label="yes (today's post slot is open)"
    work_label="write the day's blog post"
  else
    posting_label="no (already posted today, or a post is in flight)"
    work_label="file a site-work issue for the queue"
  fi

  local activity
  activity=$(cat <<EOF
Today is $today.

Your activity since local midnight:
- TOTAL open bot PRs in the queue: $open_prs
- ACTIVE bot PRs (open AND with activity in last 8h): $active_prs
- bot PRs opened today (any state): $prs_opened_today
- Work reflections logged today (excludes reading ticks): $work_reflections_today
- Commits authored today (all repos): $commits_today
- Post landed today: $([ "$post_today" = "1" ] && echo "yes" || echo "no")
- Posting eligible this tick: $posting_label
- Recent tick modes (oldest -> newest): $recent_modes

Two queue signals matter, and they answer different questions:

"ACTIVE bot PRs" = is the human engaging right now? High = they're processing
the queue, capacity exists. Low = quiet from their side.

"TOTAL open bot PRs" = how deep is the pile they have to come back to? High
total + low active means PRs are stacking up while the human is offline or
busy elsewhere. Piling more on top makes their next review session worse,
even though they're not actively reviewing now.

When TOTAL is high (say >= 4) regardless of ACTIVE, lean read. Don't
out-ship the human's review velocity.

If the decision is "work", the tick will: $work_label.
If the decision is "read", the tick will: read an article + journal-reflect.

Question: should the next discretionary tick be work or a break?
EOF
)

  local response choice reason
  response=$(claude_complete \
    "You are deciding how the agent (an autonomous Claude process) should spend the next discretionary tick.

Default bias is WORK. Reading is the opt-in break, taken when shipping more would be counterproductive.

Choose \"read\" when ANY of these hold:
  - TOTAL open bot PRs is >= 4 (pile is deep -- don't make it worse)
  - Active queue is heavy (open bot PRs with recent reviewer activity)
  - Multiple posts shipped today AND queue is at least somewhat full
  - Recent-modes list shows mostly work (a short break is fine)

Choose \"work\" when ALL of these hold:
  - TOTAL open queue is shallow (under ~4) -- room exists in the pile
  - Active queue is light (no current human pressure)
  - Recent-modes shows mostly read OR no work today yet

Don't congratulate yourself on a productive day if recent ticks have been
reading. Reading ticks are NOT work output -- they're consumption. The
recent-modes list reveals whether shipping happened recently or whether
the bot has been coasting.

CRITICAL: a low \"active\" count does NOT mean low queue pressure when
TOTAL is high. It means the human is offline or busy elsewhere; the
pile is still waiting for them. Don't out-ship review velocity.

Output STRICT JSON. No code fences, no preamble.

Schema:
{
  \"decision\": \"work\" | \"read\",
  \"reason\": \"one short sentence\"
}" \
    "$activity" \
    200 \
    "cadence-assess")

  response=$(printf '%s' "$response" | sed -E '/^```/d')
  choice=$(jq -r '.decision // ""' <<<"$response" 2>/dev/null || echo "")
  reason=$(jq -r '.reason // ""' <<<"$response" 2>/dev/null || echo "")

  case "$choice" in
    work|read) ;;
    *)
      choice="work"
      reason="cadence assessment failed -- defaulting to work"
      ;;
  esac

  # Hard consecutive-read cap, conditional on capacity. The cap is
  # meant to break smoke-break streaks when there's actual room to
  # ship -- NOT to pile on PRs when the human is already swamped.
  # Fires only when the active queue is small (< 2 active PRs). If
  # active_prs is high, the model's "keep reading" judgment stands;
  # the bot keeps reading until the human catches up.
  if [ "$choice" = "read" ] && [ "${active_prs:-0}" -lt 2 ]; then
    local tail3
    tail3=$(printf '%s' "$recent_modes" | tr ',' '\n' | tail -3 | tr '\n' ',')
    if [ "$tail3" = "read,read,read," ]; then
      choice="work"
      reason="consecutive-read cap: last 3 ticks were all reading and queue is light, forcing work"
    fi
  fi

  printf '%s|%s' "$choice" "$reason"
}

# Shift window. Returns 0 if a configured shift is active OR no shift
# is configured (testing / always-on). When AGENT_SHIFT_START + _END
# are both set, only fire ticks during [START, END) local hours.
in_shift_window() {
  local start="${AGENT_SHIFT_START:-}" end="${AGENT_SHIFT_END:-}" hour
  [ -z "$start" ] && return 0
  [ -z "$end" ] && return 0
  hour=$(date +%H)
  hour=$((10#$hour))
  [ "$hour" -ge "$start" ] && [ "$hour" -lt "$end" ]
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

# -- Shift gate ------------------------------------------------
#
# If AGENT_SHIFT_START + _END are configured, exit early when the
# current local hour is outside the shift window. Lets the systemd
# timer fire 24/7 while the agent only "works" his configured shift.
# Default (unconfigured) is always-on.

if ! in_shift_window; then
  log "outside shift window (${AGENT_SHIFT_START:-unset}-${AGENT_SHIFT_END:-unset}), current hour $(date +%H) -- skipping tick"
  exit 0
fi

# -- Bootstrap: ensure the agent's own repos are cloned -------------
#
# Brain is hard-required: identity.md is foundational, every system
# prompt loads it. If the bot doesn't own a brain repo, halt loudly
# rather than running ticks with generic-Claude voice.
#
# Website is soft: warn if absent but proceed -- the agent can still work
# other repos. The website is just one of his target repos, not
# essential infrastructure.

if ! forgejo_repo_exists "${BOT_USER}/brain"; then
  echo "agent: bootstrap failed -- ${BOT_USER}/brain does not exist or bot lacks access" >&2
  echo "  create the repo (see docs/setup.md) and try again." >&2
  exit 4
fi
ensure_repo_local "${BOT_USER}/brain"

if forgejo_repo_exists "${BOT_USER}/website"; then
  ensure_repo_local "${BOT_USER}/website"
else
  log "warning: ${BOT_USER}/website does not exist -- website work disabled"
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

# -- Scheduled maintenance (priority 1) ------------------------
#
# Monday-morning maintenance is a chore, not discretionary work.
# Runs at the top of the cascade so it always beats PR-review,
# claimable issues, and discretionary website work. One repo per
# tick, weekly cap per repo. Off-Monday or outside the shift this
# is a no-op and we proceed.

do_maintenance_tick || true

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

# Signal 1: scan all bot-accessible repos for open bot PRs where
# the latest non-bot review on the CURRENT HEAD is REQUEST_CHANGES.
# The HEAD check is important -- if the agent already pushed follow-up
# commits, the old REQUEST_CHANGES no longer applies and we
# shouldn't re-pickup until the reviewer reviews again.
RC_REPOS=$(forgejo_list_bot_repos 2>/dev/null || echo '[]')
while read -r repo_full; do
  [ -n "$REVIEW_PR" ] && break
  [ -z "$repo_full" ] && continue
  rc_open_prs=$(forgejo_list_open_bot_prs "$repo_full" "$BOT_USER" 2>/dev/null || echo '[]')
  while read -r pr_num; do
    [ -n "$REVIEW_PR" ] && break
    [ -z "$pr_num" ] && continue
    pr_details_json=$(forgejo_get_pr "$repo_full" "$pr_num" 2>/dev/null || echo '{}')
    pr_head_sha=$(jq -r '.head.sha // ""' <<<"$pr_details_json")
    [ -z "$pr_head_sha" ] && continue
    latest_review=$(forgejo_pr_non_bot_reviews "$repo_full" "$pr_num" "$BOT_USER" 2>/dev/null \
      | jq -c '.[-1] // empty')
    [ -z "$latest_review" ] && continue
    review_state=$(jq -r '.state // ""' <<<"$latest_review")
    review_commit=$(jq -r '.commit_id // ""' <<<"$latest_review")
    if [ "$review_state" = "REQUEST_CHANGES" ] && [ "$review_commit" = "$pr_head_sha" ]; then
      # Synthesize the PR record into the same shape forgejo_my_assigned_prs
      # returns so the downstream flow can consume it uniformly.
      REVIEW_PR=$(jq -c --arg r "$repo_full" '. + {repository: {full_name: $r}}' <<<"$pr_details_json")
      REVIEW_PR_TRIGGER="REQUEST_CHANGES review on current HEAD"
    fi
  done < <(jq -r '.[].number' <<<"$rc_open_prs" 2>/dev/null)
done < <(jq -r '.[].full_name' <<<"$RC_REPOS" 2>/dev/null)

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
    (cd "$PR_REPO_PATH" && git worktree add -B "$PR_HEAD" "$PR_WORKTREE" "origin/${PR_HEAD}")
    init_igor_scratch "$PR_WORKTREE"

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

    # RAG context for the review pickup: the PR title + body is the
    # most concrete signal of what this PR's about. Helps surface
    # past discussions of the same code area / topic.
    PR_RAG_CONTEXT=$(rag_query "${PR_TITLE}
${PR_BODY}")
    [ -n "$PR_RAG_CONTEXT" ] && log "rag: surfaced past context for PR review"

    PR_USER_MSG=$(cat <<EOF
You opened PR ${PR_REPO}#${PR_NUMBER}: ${PR_TITLE}

The human reviewer assigned the PR back to you for revisions. Read
the comments below, decide what is actionable, address them with new
commits on this branch (${PR_HEAD}), and exit. The harness will push
your commits and reassign the PR back to the reviewer.

If you genuinely have nothing to change -- for example the comments
were questions you can answer in a reply rather than code, or the
feedback is a "ship it" -- post a comment with your reply using
\`forgejo_comment\` semantics is not available; instead just exit
without commits and the harness will reassign back with a note that
no changes were made. The human will close the loop manually.

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

---

## Past context (RAG)

${PR_RAG_CONTEXT:-(no past context retrieved this tick)}
EOF
)

    PR_BRAIN_PATH="$AGENT_REPO_ROOT/${BOT_USER}/brain"
    PR_SYSTEM_PROMPT=$(brain_system_prompt "$PR_BRAIN_PATH")

    cd "$PR_WORKTREE"
    log "invoking claude for PR review (timeout ${TICK_TIMEOUT})"
    PR_LOG="$PR_WORKTREE/.agent/claude-output.log"
    PR_START=$(date +%s)
    set +e
    claude_run_with_cost "pr-review" "$PR_LOG" "$TICK_TIMEOUT" \
      --model "$AGENT_MODEL" \
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
      # Off-limits guard before push -- CI workflows shouldn't be
      # touched even in a review round-trip.
      PR_OFFLIMITS=$(list_offlimits_violations "$PR_HEAD")
      if [ -n "$PR_OFFLIMITS" ]; then
        log "PR-review: off-limits files modified, refusing push and bouncing back to $FORGEJO_REVIEWER"
        log "off-limits paths touched: $(echo "$PR_OFFLIMITS" | tr '\n' ' ')"
        forgejo_comment "$PR_REPO" "$PR_NUMBER" \
          "The agent refused to push revisions: the new commits modify CI workflow files, which are off-limits. Paths touched:

$(echo "$PR_OFFLIMITS" | sed 's/^/  - /')

Reassigning back so a human can review/discard." 2>/dev/null \
          || log "warning: comment failed on ${PR_REPO}#${PR_NUMBER}"
        forgejo_unassign_all "$PR_REPO" "$PR_NUMBER" 2>/dev/null || true
        forgejo_assign "$PR_REPO" "$PR_NUMBER" "$FORGEJO_REVIEWER" 2>/dev/null || true
        (cd "$PR_REPO_PATH" && git worktree remove --force "$PR_WORKTREE") 2>/dev/null || true
        exit 0
      fi

      log "PR-review: pushing $PR_NEW new commits and reassigning to $FORGEJO_REVIEWER"
      git push origin "$PR_HEAD" || log "warning: push failed on $PR_HEAD"
      forgejo_unassign_all "$PR_REPO" "$PR_NUMBER" 2>/dev/null \
        || log "warning: unassign failed on ${PR_REPO}#${PR_NUMBER}"
      forgejo_assign "$PR_REPO" "$PR_NUMBER" "$FORGEJO_REVIEWER" 2>/dev/null \
        || log "warning: assign-to-${FORGEJO_REVIEWER} failed on ${PR_REPO}#${PR_NUMBER}"
    else
      log "PR-review: no commits made -- reassigning to $FORGEJO_REVIEWER with a note"
      forgejo_comment "$PR_REPO" "$PR_NUMBER" \
        "The agent reopened this PR after reassignment but didn't make any new commits. Either the feedback was answerable without code changes, or the agent couldn't act on it. Reassigning back so a human can close the loop." 2>/dev/null \
        || log "warning: comment failed on ${PR_REPO}#${PR_NUMBER}"
      forgejo_unassign_all "$PR_REPO" "$PR_NUMBER" 2>/dev/null \
        || log "warning: unassign failed on ${PR_REPO}#${PR_NUMBER}"
      forgejo_assign "$PR_REPO" "$PR_NUMBER" "$FORGEJO_REVIEWER" 2>/dev/null \
        || log "warning: assign-to-${FORGEJO_REVIEWER} failed on ${PR_REPO}#${PR_NUMBER}"
    fi

    forgejo_log_time "$PR_REPO" "$PR_NUMBER" "$PR_ELAPSED" \
      && log "time logged: ${PR_ELAPSED}s on ${PR_REPO}#${PR_NUMBER}" \
      || log "warning: could not log time on ${PR_REPO}#${PR_NUMBER}"

    (cd "$PR_REPO_PATH" && git worktree remove --force "$PR_WORKTREE") 2>/dev/null || true

    exit 0
fi

# -- Discovery: find globally oldest claimable -----------------

REPOS=$(forgejo_list_bot_repos)
REPO_COUNT=$(jq 'length' <<<"$REPOS")
log "scanning $REPO_COUNT repo(s) for claimable work"

WINNER=""
WINNER_REPO=""
WINNER_PR_BASE=""
WINNER_CREATED=""

while read -r repo_line; do
  [ -z "$repo_line" ] && continue
  R_NAME=$(jq -r '.full_name' <<<"$repo_line")
  R_BASE=$(jq -r '.default_branch' <<<"$repo_line")
  R_PATH=$(repo_path_for "$R_NAME")

  # Onboarding gate: for repos we haven't cloned yet, validate via API
  # before we look at any issues there. Failing repos get an auto-filed
  # ticket (or a reopen on the existing one) and are excluded from
  # discovery until the human closes the ticket.
  if [ ! -d "$R_PATH/.git" ]; then
    if ! R_REPORT=$(validate_repo_via_api "$R_NAME"); then
      log "onboarding check failed on $R_NAME"
      handle_onboarding_failure "$R_NAME" "$BOT_USER" "$R_REPORT" \
        || log "warning: onboarding handler failed on $R_NAME (likely token scope or repo perms); continuing"
      continue
    fi
    log "onboarding check passed on $R_NAME"
  fi

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
done < <(jq -c '.[]' <<<"$REPOS")

if [ -z "$WINNER" ]; then
  log "no claimable work across any repo"

  # -- Discretionary: self-directed website work --------------
  #
  # Last priority in the cascade. Scheduled maintenance, PR-review
  # pickup, and claimable issues all came up empty. If the bot owns
  # a website, do one freeform pass on the site (or reading, or a
  # post -- the cadence assessor below picks).
  #
  # Always fires on empty ticks. The operator dials back activity
  # by shortening the shift window (AGENT_SHIFT_START/END), not by
  # rate-gating individual ticks. Natural pacing comes from the
  # scope cap (400 lines / 10 commits) and the once-per-local-day
  # post cap; multiple concurrent PRs on the same repo are fine --
  # the human handles merge order in Forgejo like any multi-PR
  # project.

  W_REPO="${BOT_USER}/website"
  W_PATH=$(repo_path_for "$W_REPO")
  BRAIN_PATH="$AGENT_REPO_ROOT/${BOT_USER}/brain"

  # Determine the discretionary mode by deterministic priority, not
  # by dice-roll. Earlier the harness sampled a weighted split from
  # brain/memories/preferences/discretionary-split.md (50/25/25
  # reading/post/site-work) -- which had the failure mode of randomly
  # not-posting for two days in a row, and burning 50% of ticks on
  # reading when there was actual work to ship.
  #
  # New routing:
  #   1. If posting is allowed (no blog today, none in flight) -> post.
  #   2. Else -> site-work (file an issue; no per-PR cap).
  #   3. Reading is the bottom-of-chain fallback in both -- only fires
  #      when the primary mode's executor fails or skips.
  #
  # The dice-roll's blog-ideas.md ordering still matters (the picker
  # takes the top idea); reflection still re-orders the stack after
  # each tick. discretionary-split.md is unused now and can be deleted
  # from brain in a follow-up.

  # Hoisted from the worktree setup block: we need posting-allowed
  # state BEFORE routing, not after.
  W_OPEN_PRS_JSON=$(forgejo_list_open_bot_prs "$W_REPO" "$BOT_USER" 2>/dev/null || echo '[]')
  W_OPEN_PRS_COUNT=$(jq 'length' <<<"$W_OPEN_PRS_JSON")

  # "Active" = opened or had updated activity within last 8 hours.
  # Stale PRs (opened a day ago, no review action since) shouldn't
  # register as queue pressure -- they're abandoned, not active.
  # The cadence assessor uses the ACTIVE count, not the raw open
  # count, to decide whether the queue is "heavy".
  W_ACTIVE_CUTOFF=$(date -u -d "8 hours ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
                    || date -u -v-8H +%Y-%m-%dT%H:%M:%SZ)
  W_ACTIVE_PRS_COUNT=$(jq --arg cutoff "$W_ACTIVE_CUTOFF" \
    '[.[] | select((.updated_at // .created_at // "") >= $cutoff)] | length' \
    <<<"$W_OPEN_PRS_JSON" 2>/dev/null || echo 0)

  # Inflight-post scan is TODAY-SCOPED. The filename format from
  # discretionary-post.sh is src/posts/YYYY/YYYY-MM-DD-slug.md, so
  # we filter the PR's added files to ones whose basename starts
  # with today's date. An open PR carrying a post from yesterday
  # (still awaiting review) does NOT block today's posting slot --
  # tomorrow's tick should not be blocked by yesterday's PR either.
  W_TODAY=$(date +%Y-%m-%d)
  W_TODAY_POST_RE="^src/posts/[0-9]{4}/${W_TODAY}-.+\\.md$"
  W_INFLIGHT_POST=0
  if [ "$W_OPEN_PRS_COUNT" -gt 0 ]; then
    while read -r pr_number; do
      [ -z "$pr_number" ] && continue
      if forgejo_pr_files "$W_REPO" "$pr_number" 2>/dev/null \
          | jq -e --arg re "$W_TODAY_POST_RE" \
              '[.[] | select(.status == "added") | .filename | select(test($re))] | length > 0' \
              >/dev/null 2>&1; then
        W_INFLIGHT_POST=1
        break
      fi
    done < <(jq -r '.[].number' <<<"$W_OPEN_PRS_JSON" 2>/dev/null || echo "")
  fi

  if [ "$W_INFLIGHT_POST" -eq 1 ]; then
    W_POSTING_ALLOWED=0
    W_POST_RULE="An open bot PR on this repo already contains a new post for today (not yet merged). Do NOT publish another post -- one post per day is the rule and today's slot is already taken. Site work, follow-ups, or a read+journal tick are still fair game."
  elif posts_cooldown_clear; then
    W_POSTING_ALLOWED=1
    W_POST_RULE="You MAY publish a new post this tick if that's the right call."
  else
    W_POSTING_ALLOWED=0
    W_POST_RULE="You already shipped a post today (local calendar day). Do NOT publish another post this tick -- max one post per day is a hard rule. Other site work (about page, layout, copy, links, tag pages, CSS) and read+journal ticks are still fair game."
  fi

  # Routing: cadence assessment fires FIRST, on every discretionary
  # tick. It gates both post and site-work -- a heavy queue can
  # overrule an open posting slot just as easily as it can short-
  # circuit yet another site-work issue. Posting eligibility is one
  # of cadence's inputs (so it knows what "work" actually does this
  # tick), not a separate code branch.
  #
  # Earlier versions hard-capped site-work at a fixed PR threshold
  # and exempted post mode entirely. Wrong shape: post is the
  # heaviest PR the agent opens (real content, real review burden),
  # so exempting it from queue pressure made the worst case worse.
  # Now: judgment over thresholds, applied uniformly.
  W_CADENCE=$(discretionary_assess_cadence "$W_ACTIVE_PRS_COUNT" "$W_POSTING_ALLOWED" "$W_OPEN_PRS_COUNT")
  W_CADENCE_CHOICE=${W_CADENCE%%|*}
  W_CADENCE_REASON=${W_CADENCE#*|}
  log "discretionary: cadence -> $W_CADENCE_CHOICE ($W_CADENCE_REASON)"

  # Hard cap on shipping. If the open queue is already deep, no more
  # PRs this tick regardless of what cadence decided -- the bot can
  # rationalize endless work tickets; this is the floor. Reading
  # still runs (it's cheap, and the journal entry shifts the
  # recent_modes signal for the next cadence call).
  W_OPEN_PR_SHIP_CAP=4
  if [ "$W_CADENCE_CHOICE" = "work" ] && [ "${W_OPEN_PRS_COUNT:-0}" -ge "$W_OPEN_PR_SHIP_CAP" ]; then
    log "discretionary: ship-cap hit ($W_OPEN_PRS_COUNT open PRs >= $W_OPEN_PR_SHIP_CAP) -- forcing read"
    W_CADENCE_CHOICE="read"
    W_CADENCE_REASON="ship-cap: $W_OPEN_PRS_COUNT open PRs awaiting review, don't out-ship human review velocity"
  fi

  if [ "$W_CADENCE_CHOICE" = "read" ]; then
    W_PICKED_MODE="reading"
    W_SPLIT_ORDER="reading"
  elif [ "$W_POSTING_ALLOWED" = "1" ]; then
    W_PICKED_MODE="post"
    W_SPLIT_ORDER="post site-work reading"
  else
    W_PICKED_MODE="site-work"
    W_SPLIT_ORDER="site-work reading"
  fi
  log "discretionary: routing (posting_allowed=$W_POSTING_ALLOWED, open_prs=$W_OPEN_PRS_COUNT, active_prs=$W_ACTIVE_PRS_COUNT) -> $W_SPLIT_ORDER"

  # Reading mode short-circuit: it doesn't touch the website. Use a
  # scratch dir for the .agent/AGENT_JOURNAL.md output, run the
  # executor, append the journal to brain, exit. No website worktree
  # is set up; no website context computed.
  if [ "$W_PICKED_MODE" = "reading" ]; then
    W_SCRATCH="$AGENT_STATE_DIR/scratch-reading-$$"
    mkdir -p "$W_SCRATCH/.agent"
    R_CLEANUP() {
      rm -rf "$W_SCRATCH" 2>/dev/null || true
      rag_cleanup_marker
    }
    trap R_CLEANUP EXIT
    W_START=$(date +%s)
    if AGENT_BRAIN_PATH="$BRAIN_PATH" \
       "$AGENT_HOME/bin/discretionary-read.sh" "$W_SCRATCH" 2>&1; then
      W_ELAPSED=$(( $(date +%s) - W_START ))
      log "discretionary: reading mode succeeded in ${W_ELAPSED}s"

      # Always log the tick to brain journal (header guaranteed
      # so recent_modes reflects activity). The reading executor
      # also updates memories/reading/log.md, sources.md weight
      # tweaks, and blog-ideas.md (post-tick ideas reflection) --
      # all of which need to land regardless.
      append_journal_entry "discretionary reading" "$W_SCRATCH/.agent/AGENT_JOURNAL.md"
      commit_brain_changes "$BRAIN_PATH" "journal: discretionary reading on $(date +%Y-%m-%d)"
    else
      log "warning: reading mode failed -- this mode does not fall through to other modes (no website worktree set up)"
    fi
    exit 0
  fi

  if [ ! -d "$W_PATH/.git" ]; then
    log "discretionary: no website cloned -- nothing to do"
    exit 0
  fi

  # W_OPEN_PRS_JSON, W_OPEN_PRS_COUNT, W_INFLIGHT_POST, W_POSTING_ALLOWED,
  # W_POST_RULE were all computed earlier (above the routing decision).
  # No re-fetch -- we reuse what we already have.

  if [ "$W_OPEN_PRS_COUNT" -gt 0 ]; then
    W_OPEN_PRS_LIST=$(jq -r '.[] | "  - #\(.number) (branch `\(.head)`): \(.title)"' <<<"$W_OPEN_PRS_JSON")

    # Aggregate every file touched across all open PRs. Different
    # topics often touch the same infrastructure files (base.njk,
    # style.css). Topic-only briefing wasn't enough -- two PRs about
    # different things both touching the same file still conflict at
    # merge time. Telling Claude the file list directly is much more
    # actionable than the title list alone.
    W_INFLIGHT_FILES=""
    while read -r pr_number; do
      [ -z "$pr_number" ] && continue
      forgejo_pr_files "$W_REPO" "$pr_number" 2>/dev/null \
        | jq -r '.[] | .filename' 2>/dev/null
    done < <(jq -r '.[].number' <<<"$W_OPEN_PRS_JSON" 2>/dev/null) \
      | grep -v '^\.agent/' \
      | sort -u \
      | sed 's/^/  - /' > /tmp/igor_inflight_files.$$
    W_INFLIGHT_FILES=$(cat /tmp/igor_inflight_files.$$)
    rm -f /tmp/igor_inflight_files.$$

    if [ -n "$W_INFLIGHT_FILES" ]; then
      W_FILES_NOTE="

Files currently modified across those open PRs (avoid editing these
unless you're certain your change won't conflict at merge time):

${W_INFLIGHT_FILES}

If your idea would touch any file on that list, pick a different
idea or do a read+journal tick instead."
    else
      W_FILES_NOTE=""
    fi

    W_IN_FLIGHT="There are ${W_OPEN_PRS_COUNT} open bot PR(s) on this repo already, awaiting human review:

${W_OPEN_PRS_LIST}

Do NOT duplicate any of these. Pick something different. If
nothing else is calling you, this is a fine tick to spend reading
(shape c) instead of shipping another overlapping PR.${W_FILES_NOTE}"
  else
    W_IN_FLIGHT="No open bot PRs on this repo right now -- you're working from a clean slate."
  fi

  log "discretionary: self-directed work on $W_REPO (posting=$W_POSTING_ALLOWED, in_flight=$W_OPEN_PRS_COUNT, inflight_post=$W_INFLIGHT_POST)"

  W_BASE=$(cd "$W_PATH" && git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
  W_BASE="${W_BASE:-master}"
  W_TS=$(date +%Y%m%d-%H%M%S)
  W_BRANCH="agent/discretionary-${W_TS}"
  W_WORKTREE="$AGENT_STATE_DIR/worktrees/website-discretionary-${W_TS}"
  mkdir -p "$AGENT_STATE_DIR/worktrees"
  (cd "$W_PATH" && git fetch --prune origin)
  (cd "$W_PATH" && git worktree add -b "$W_BRANCH" "$W_WORKTREE" "origin/${W_BASE}")
  init_igor_scratch "$W_WORKTREE"

  W_CLEANUP() {
    [ -d "$W_WORKTREE" ] && (cd "$W_PATH" && git worktree remove --force "$W_WORKTREE") 2>/dev/null || true
    cleanup_agent_branches "discretionary-${W_TS}" "$W_PATH"
    rag_cleanup_marker
  }
  trap W_CLEANUP EXIT

  cd "$W_WORKTREE"

  # Dispatch by mode. W_PICKED_MODE and W_SPLIT_ORDER were sampled
  # at the top of the discretionary block (before website setup) so
  # reading mode could short-circuit out entirely. At this point
  # W_PICKED_MODE is post or site-work; reading is in W_SPLIT_ORDER
  # only as a fallback if the primary mode fails (it'd run inside
  # the website worktree, which is wasteful but works).
  USED_HARNESS_MODE=""
  for mode in $W_SPLIT_ORDER; do
    [ -n "$USED_HARNESS_MODE" ] && break
    case "$mode" in
      reading)
        W_START=$(date +%s)
        if AGENT_BRAIN_PATH="$BRAIN_PATH" \
           "$AGENT_HOME/bin/discretionary-read.sh" "$W_WORKTREE" 2>&1; then
          USED_HARNESS_MODE="reading"
          W_EXIT=0
          W_ELAPSED=$(( $(date +%s) - W_START ))
          log "discretionary: harness reading executor succeeded in ${W_ELAPSED}s"
        else
          log "discretionary: harness reading executor failed -- trying next mode in order"
        fi
        ;;
      post)
        # Skip post mode if posting is on cooldown; falls through
        # to the next mode in W_SPLIT_ORDER.
        if [ "$W_POSTING_ALLOWED" != "1" ]; then
          log "discretionary: post mode picked but posting is on cooldown -- trying next mode"
          continue
        fi
        W_START=$(date +%s)
        if AGENT_BRAIN_PATH="$BRAIN_PATH" AGENT_WEBSITE_PATH="$W_PATH" \
           "$AGENT_HOME/bin/discretionary-post.sh" "$W_WORKTREE" 2>&1; then
          USED_HARNESS_MODE="post"
          W_EXIT=0
          W_ELAPSED=$(( $(date +%s) - W_START ))
          W_NEW_POST=1  # mark for posts_mark_shipped downstream
          log "discretionary: harness post executor succeeded in ${W_ELAPSED}s"
        else
          log "discretionary: harness post executor failed -- trying next mode in order"
        fi
        ;;
      site-work)
        # No harness executor for site-work; falls through to the
        # Claude Code path below. Set the mode to a synthetic value
        # so we exit the loop and enter the claude block.
        USED_HARNESS_MODE="site-work-claude"
        log "discretionary: dispatching site-work mode to claude code"
        ;;
    esac
  done

if [ "$USED_HARNESS_MODE" = "site-work-claude" ] || [ -z "$USED_HARNESS_MODE" ]; then

  # Force-load the reading log into the user message. Reading ticks
  # historically picked the same blog post 3 nights in a row because
  # Claude didn't remember to check the MEMORY.md hook. This makes the
  # check deterministic -- the log is literally in his prompt, can't
  # be missed. Empty if the file doesn't exist (e.g., before brain
  # memory PR lands).
  W_READING_LOG=""
  W_READING_LOG_FILE="$BRAIN_PATH/memories/reading/log.md"
  if [ -f "$W_READING_LOG_FILE" ]; then
    W_READING_LOG=$(cat "$W_READING_LOG_FILE")
  fi

  # Fetch open issues on the repo so Claude can see what's already
  # queued and avoid filing duplicates. Best-effort; empty on
  # failure (the prompt mentions it but doesn't depend on it).
  W_OPEN_ISSUES_LIST=""
  W_OPEN_ISSUES_JSON=$(forgejo_list_open_issues "$W_REPO" 2>/dev/null || echo '[]')
  W_OPEN_ISSUES_COUNT=$(jq 'length' <<<"$W_OPEN_ISSUES_JSON" 2>/dev/null || echo 0)
  if [ "$W_OPEN_ISSUES_COUNT" -gt 0 ]; then
    W_OPEN_ISSUES_LIST=$(jq -r '
      .[] | "  - #\(.number) [\([.labels[].name] | join(",") | (if . == "" then "no labels" else . end))]: \(.title)"
    ' <<<"$W_OPEN_ISSUES_JSON")
  fi

  # RAG: pull relevant past entries to inject into the user message.
  # Build happens lazily on first rag_query in the tick (other Claude
  # paths share the build via $TICK_PID). Best-effort -- failures
  # log a warning and return empty.
  W_RAG_CONTEXT=$(rag_query "$W_IN_FLIGHT")
  [ -n "$W_RAG_CONTEXT" ] && log "rag: surfaced past context for discretionary tick"

  W_USER_MSG=$(cat <<EOF
MODE: FILE A SITE-WORK ISSUE. The harness sampled site-work from
the discretionary split this tick. Do NOT do site work directly --
your job is to file ONE Agent-labeled issue describing something
worth fixing or improving on the site. A future tick will pick up
the issue via the normal issue-work flow and do the work then.

Why this shape: all coding work goes through the issue queue, so
nothing happens to the site without a spec and a paper trail.
Reading and posting have their own harness-driven paths on other
discretionary ticks -- this tick is for queueing site work.

You are examining $W_REPO. No issue is assigned to you, and you
are NOT being asked to ship code. Your only output this tick is:
ONE filed issue, plus an optional journal entry.

What to do:

1. Read CLAUDE.md (especially "Posts" and "Site shape" sections).
2. Browse src/ to see the current state: src/index.md (homepage),
   src/about.md (about), src/posts.njk, src/_includes/base.njk
   (layout), src/posts/ (existing posts), etc.
3. Identify ONE specific thing worth fixing or improving. Could be:
   layout, CSS, broken links, accessibility gaps, copy edits,
   typos, missing meta tags, RSS issues, a tag page that needs
   work, a new page that would help. Pick something concrete and
   bounded -- one PR's worth of work.
4. File the issue via agent-enqueue.sh. Two forms:

     # Short body, single-line:
     agent-enqueue.sh $W_REPO "title" "body"

     # Multi-line body (RECOMMENDED for real specs):
     #   1. Write the body to a scratch file in .agent/ (gitignored).
     #   2. Pass the file path -- no command substitution needed,
     #      static-analyzable, no permission-hook fights.
     agent-enqueue.sh $W_REPO "title" --body-file .agent/issue-body.md

   - Title: short, imperative, conventional-commit-style
     ("fix: footer links wrap on narrow viewports").
   - Body: enough spec that a future tick can do the work without
     re-discovering the problem. Reference specific files, give
     acceptance criteria. Multi-paragraph spec bodies are normal --
     use --body-file for those.

   IF agent-enqueue.sh FAILS for any reason (permission gate,
   network error, label problem, etc.): do NOT silently exit with
   only a journal entry. Surface the failure as a question issue
   via:

     agent-ask.sh igor/brain "harness gap: <short summary>" "<details>"

   This puts a Status/Need More Info issue on Josh's dashboard so
   the gap is visible without him scrolling journalctl. Journal
   entries are private and easy to miss; issues are not.

5. Exit cleanly. NO commits, NO edits to files in the worktree,
   NO PR. The issue you filed (or the agent-ask question, if
   enqueue failed) is the tick's output.

IN-FLIGHT PRs: $W_IN_FLIGHT

OPEN ISSUES on this repo right now -- DO NOT file a duplicate.
Check the existing queue first; if your idea overlaps an open
issue, either comment on that issue or pick a different thing to
file.

${W_OPEN_ISSUES_LIST:-(no open issues on this repo)}

RELEVANT PAST CONTEXT (top-K journal entries surfaced by similarity
to current state; use as memory hooks, not directives):

${W_RAG_CONTEXT:-(no past context retrieved this tick)}

A journal entry is fine to write if something about the examination
was worth remembering (a pattern you noticed across the site, a
constraint you should keep in mind). Otherwise skip it.
EOF
)

  # BRAIN_PATH is set at the top of the discretionary block now
  # (so the READING_LOG load earlier can use it).
  W_SYSTEM_PROMPT=$(brain_system_prompt "$BRAIN_PATH")

  log "invoking claude for website work (timeout ${TICK_TIMEOUT})"
  W_LOG="$W_WORKTREE/.agent/claude-output.log"
  W_START=$(date +%s)
  set +e
  claude_run_with_cost "site-work" "$W_LOG" "$TICK_TIMEOUT" \
    --model "$AGENT_MODEL" \
    --append-system-prompt "$W_SYSTEM_PROMPT" \
    --settings "$AGENT_HOME/agent-settings.json" \
    --max-turns 50 \
    --print "$W_USER_MSG"
  W_EXIT=$?
  set -e
  W_ELAPSED=$(( $(date +%s) - W_START ))
  log "claude exited $W_EXIT after ${W_ELAPSED}s"

  normalize_worktree_dashes "$W_WORKTREE"

fi  # end if-claude-code-site-work

  # Always log the tick. Header is guaranteed (so recent_modes
  # reflects activity) and Claude's body lands if he wrote one.
  # Brain commit happens after regardless -- the harness-side
  # executors (discretionary-post.sh's dedupe, ideas reflection,
  # source-weight tweaks) also mutate brain.
  W_JOURNAL_SRC="$W_WORKTREE/.agent/AGENT_JOURNAL.md"
  append_journal_entry "discretionary on $W_REPO" "$W_JOURNAL_SRC"
  commit_brain_changes "$BRAIN_PATH" "journal: discretionary on $W_REPO"

  # Harness-owned commits: Claude doesn't run git commit; the harness
  # commits anything dirty (outside .agent/) at end of tick. Subject is
  # derived from .agent/PR_BODY.md's first checklist item; falls back
  # to a generic message. Claude's `git add` and commit instructions
  # were removed from his prompt -- saves tool calls and eliminates
  # the "forgot to commit" failure mode structurally.
  cd "$W_WORKTREE"
  W_DIRTY_PATHS=$(git status --porcelain 2>/dev/null \
    | awk '$2 !~ /^\.agent\// { print $2 }')
  if [ -n "$W_DIRTY_PATHS" ]; then
    W_DIRTY_COUNT=$(echo "$W_DIRTY_PATHS" | wc -l | tr -d ' ')
    # Stage first so derive_commit_subject can use `git diff
    # --cached` and see new (previously-untracked) files. Without
    # this, posts and other added files are invisible to the
    # API-tier diff, and the API responds conversationally to an
    # empty input ("I'm ready to generate...").
    git add -A
    W_SUBJECT=$(derive_commit_subject "$W_WORKTREE/.agent/PR_BODY.md" "$W_WORKTREE" "chore: discretionary website tick")
    log "harness-commit: $W_DIRTY_COUNT file(s), subject: $W_SUBJECT"
    git commit --quiet -m "$W_SUBJECT" || log "warning: harness commit failed"
  fi

  # Outcome classification
  W_COMMITS=$(git rev-list --count "origin/${W_BASE}..HEAD" 2>/dev/null || echo 0)

  if [ "$W_COMMITS" -eq 0 ]; then
    # If site-work mode filed an issue via agent-enqueue.sh, the
    # marker file is in the worktree. Log the agent's examination time
    # on that issue -- his work this tick produced the spec, the
    # time belongs there.
    W_FILED_MARKER="$W_WORKTREE/.agent/AGENT_FILED_ISSUE"
    if [ -f "$W_FILED_MARKER" ]; then
      W_FILED_REF=$(head -1 "$W_FILED_MARKER" | tr -d '[:space:]')
      W_FILED_REPO="${W_FILED_REF%#*}"
      W_FILED_NUM="${W_FILED_REF##*#}"
      if [ -n "$W_FILED_REPO" ] && [ -n "$W_FILED_NUM" ]; then
        forgejo_log_time "$W_FILED_REPO" "$W_FILED_NUM" "$W_ELAPSED" \
          && log "time logged: ${W_ELAPSED}s on ${W_FILED_REPO}#${W_FILED_NUM} (filed issue)" \
          || log "warning: could not log time on ${W_FILED_REPO}#${W_FILED_NUM}"
      fi
      log "discretionary: site-work tick filed ${W_FILED_REF}"
    elif [ -s "$W_JOURNAL_SRC" ]; then
      log "discretionary: reading tick complete on $W_REPO -- journal recorded, no PR"
    else
      log "discretionary: no work produced on $W_REPO"
    fi
    exit 0
  fi

  W_ACTUAL_BRANCH=$(git rev-parse --abbrev-ref HEAD)
  if [ "$W_ACTUAL_BRANCH" != "$W_BRANCH" ]; then
    log "discretionary: HEAD on $W_ACTUAL_BRANCH, expected $W_BRANCH -- abandoning"
    exit 0
  fi

  W_CHANGED=$(git diff --shortstat "origin/${W_BASE}..HEAD" 2>/dev/null \
    | awk '{ for (i=1;i<=NF;i++) if ($i ~ /insertion|deletion/) s+=$(i-1); print s+0 }')
  W_CHANGED=${W_CHANGED:-0}
  if [ "$W_COMMITS" -gt 10 ] || [ "$W_CHANGED" -gt 400 ]; then
    log "discretionary: scope exceeded ($W_COMMITS commits, $W_CHANGED lines) -- abandoning"
    exit 0
  fi

  W_OFFLIMITS=$(list_offlimits_violations "$W_BASE")
  if [ -n "$W_OFFLIMITS" ]; then
    log "discretionary: off-limits files modified -- abandoning. CI workflows are operator-managed."
    log "off-limits paths touched: $(echo "$W_OFFLIMITS" | tr '\n' ' ')"
    exit 0
  fi

  # Vacuous-tests check: only meaningful for the Claude Code path,
  # which actually runs the project's test suite and captures stdout
  # in W_LOG. The harness post executor doesn't run tests -- it just
  # writes a markdown file -- so W_LOG isn't set and the check would
  # die under `set -u` with "unbound variable". Skip when the file
  # isn't there.
  if [ -n "${W_LOG:-}" ] && [ -f "$W_LOG" ] \
     && grep -qiE 'tests:[[:space:]]+0[[:space:]]+(passed|failed|of|total)|no tests (ran|found|collected)|collected 0 items|(^|[^0-9])0 passing([^0-9]|$)|running 0 tests|ran 0 tests' "$W_LOG"; then
    log "discretionary: vacuous tests -- abandoning"
    exit 0
  fi

  # Did this tick ship a new post? Detect via diff: any new file under src/posts/.
  W_NEW_POST=0
  if git diff --name-status --diff-filter=A "origin/${W_BASE}..HEAD" 2>/dev/null \
       | awk '{ print $2 }' | grep -qE '^src/posts/.+\.md$'; then
    W_NEW_POST=1
  fi

  if [ "$W_NEW_POST" -eq 1 ] && [ "$W_POSTING_ALLOWED" -eq 0 ]; then
    log "discretionary: new post detected but posting is on cooldown -- abandoning (1 post/day rule)"
    exit 0
  fi

  # Burn the cooldown BEFORE push -- intent-based, not success-based.
  # If the push or PR-open fails after this, the cooldown still
  # protects against another post-shaped PR tomorrow morning. The
  # commits exist locally and the human can recover; we just need
  # to not let the next tick double up.
  if [ "$W_NEW_POST" -eq 1 ]; then
    posts_mark_shipped
  fi

  log "discretionary: pushing $W_BRANCH and opening PR on $W_REPO (new_post=$W_NEW_POST)"
  git push --force-with-lease -u origin "$W_BRANCH"

  W_EXISTING_PR=$(forgejo_find_pr_by_head "$W_REPO" "$W_BRANCH")
  if [ -n "$W_EXISTING_PR" ]; then
    log "PR #$W_EXISTING_PR already open"
    W_NEW_PR_NUMBER="$W_EXISTING_PR"
  else
    W_PR_TITLE=$(git log -1 --pretty=%s)
    if [ -f .agent/PR_BODY.md ]; then
      W_PR_BODY=$(cat .agent/PR_BODY.md)
    else
      log "WARNING: PR_BODY.md was NOT written by claude this tick. AGENTS.md requires it on every ship; this is not optional. Attempting harness-side fallback via Haiku."
      W_PR_BODY=$(derive_pr_body "$W_WORKTREE" "$W_BASE")
      if [ -n "$W_PR_BODY" ]; then
        log "harness-side PR body synthesized via Haiku from diff"
      else
        log "WARNING: Haiku fallback also failed; using git-log-derived body. PR description will be thin."
        W_PR_BODY=$(git log "origin/${W_BASE}..HEAD" --reverse --format='### %s%n%n%b%n')
      fi
    fi
    W_PR_BODY+=$(build_deps_section "$W_BASE")
    W_NEW_PR_NUMBER=$(forgejo_open_pr "$W_REPO" "$W_BRANCH" "$W_BASE" "$W_PR_TITLE" "$W_PR_BODY" "${FORGEJO_REVIEWER:-}")
    log "discretionary: PR opened on $W_REPO${W_NEW_PR_NUMBER:+ (#$W_NEW_PR_NUMBER)}"
  fi

  if [ -n "${W_NEW_PR_NUMBER:-}" ]; then
    forgejo_log_time "$W_REPO" "$W_NEW_PR_NUMBER" "$W_ELAPSED" \
      && log "time logged: ${W_ELAPSED}s on ${W_REPO}#${W_NEW_PR_NUMBER}" \
      || log "warning: could not log time on ${W_REPO}#${W_NEW_PR_NUMBER}"
  else
    log "warning: no PR number captured, skipping time log"
  fi

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
  rag_cleanup_marker
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

# System prompt: brain_system_prompt assembles AGENTS.md + brain
# files in cache-friendly order. Brain files are bootstrap-required;
# log a warning if identity.md is missing rather than crashing the
# tick (brain_system_prompt handles the missing case by skipping).
BRAIN_PATH="$AGENT_REPO_ROOT/${BOT_USER}/brain"
[ -f "$BRAIN_PATH/identity.md" ] \
  || log "warning: brain identity.md missing at $BRAIN_PATH"
SYSTEM_PROMPT=$(brain_system_prompt "$BRAIN_PATH")

# RAG context: the issue title + body is the most concrete signal of
# what the agent is about to work on. Pulls past journal entries, related
# commits, and prior reviews touching the same area.
TIER1_RAG_CONTEXT=$(AGENT_BRAIN_PATH="$BRAIN_PATH" rag_query "${ISSUE_TITLE}
${ISSUE_BODY}")
[ -n "$TIER1_RAG_CONTEXT" ] && log "rag: surfaced past context for tier-1 issue work"

USER_MSG=$(cat <<EOF
You are working Forgejo issue #${ISSUE_NUMBER} in ${FORGEJO_REPO}.

Title: ${ISSUE_TITLE}
Labels: ${ISSUE_LABELS}

Body:
${ISSUE_BODY}

---

## Past context (RAG)

${TIER1_RAG_CONTEXT:-(no past context retrieved this tick)}
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

# -- Brain journal: append Claude's reflection if present ------
#
# Claude optionally writes .agent/AGENT_JOURNAL.md before exit. The
# harness owns the brain commit -- Claude's worktree never reaches
# across to brain. Best-effort: if pull/push fails, log it but
# don't fail the tick over a journal entry.

JOURNAL_SRC="$WORKTREE/.agent/AGENT_JOURNAL.md"
BRAIN_LOCAL="$AGENT_REPO_ROOT/${BOT_USER}/brain"
append_journal_entry "${FORGEJO_REPO}#${ISSUE_NUMBER}" "$JOURNAL_SRC"
commit_brain_changes "$BRAIN_LOCAL" "journal: ${FORGEJO_REPO}#${ISSUE_NUMBER}"

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
