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
# shellcheck source=lib/maintenance-checks.sh
. "$AGENT_HOME/lib/maintenance-checks.sh"
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
# the "## TS -- <mode-suffix>" header so brain has an existence-
# proof of the tick even when Claude didn't write a reflection.
# Header = existence proof. Body = Claude's reflection, if any.
#
# Args:
#   $1 -- mode-suffix (free-form text after the "-- " in the header).
#         Mode suffixes the refactor recognizes:
#           "discretionary reading"   -> read mode
#           "discretionary on <repo>" -> work mode
#           "<owner>/<repo>#<num>"    -> work mode (tier-1 issue)
#   $2 -- (optional) path to a body source file written by Claude.
#         When present and non-empty and not a byte-identical
#         duplicate of today's existing content, the file contents
#         land under the header.
#   $3 -- (optional) fallback body string. Used when $2 is missing
#         or empty. Lets callers pre-build a fact stub (commit
#         subject, files touched, etc.) so brain always has a
#         meaningful entry, not just a placeholder. When $2 is a
#         duplicate, $3 is also used (the harness stub is preferable
#         to a "no body -- duplicate" placeholder).
#
# Rule: every tick gets a journal entry. If $2 is missing and $3
# is empty, the function logs a loud warning and skips the entry
# rather than writing an orphan header -- but the always-journal
# contract in AGENTS.md is what should keep this from happening.
append_journal_entry() {
  local mode_suffix="$1" body_src="${2:-}" fallback_body="${3:-}"
  local brain="${AGENT_BRAIN_PATH:-${BRAIN_PATH:-$AGENT_REPO_ROOT/${BOT_USER}/brain}}"
  local journal_date journal_file journal_ts body
  journal_date=$(date +%Y-%m-%d)
  journal_file="$brain/journal/${journal_date}.md"
  journal_ts=$(date +%Y-%m-%dT%H:%M:%S%z)
  mkdir -p "$(dirname "$journal_file")"

  body=""
  if [ -n "$body_src" ] && [ -s "$body_src" ]; then
    if journal_is_duplicate "$body_src" "$journal_file"; then
      log "journal: body duplicates an earlier entry today -- using fallback stub"
      body="$fallback_body"
    else
      body=$(cat "$body_src")
    fi
  elif [ -n "$fallback_body" ]; then
    log "journal: no AGENT_JOURNAL.md from ${mode_suffix} -- using harness fact stub"
    body="$fallback_body"
  fi

  if [ -z "$body" ]; then
    log "WARNING: journal: no body and no fallback for ${mode_suffix} -- skipping entry (always-journal contract violated upstream)"
    return 0
  fi

  # Sanitize body before commit so brain's markdownlint doesn't
  # reject it. Claude occasionally ends a line with a stray space
  # (MD009) and brain's CI fails on push. Sed strips trailing
  # whitespace from every line in the body -- both Claude's
  # AGENT_JOURNAL.md content and any harness-built fallback_body
  # land here. Bash command substitution drops the trailing
  # newline, and the printf '%s\n' below adds one back, so MD047
  # (single trailing newline) stays correct.
  body=$(printf '%s' "$body" | sed 's/[[:space:]]*$//')

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


# Eligible if not run this ISO week (weeks start Monday, local time).
# Any tick all week can pick up an eligible repo -- no shift-window
# gate. Resilient to Monday-tick failures and to new repos added
# mid-week.
#
# Skips:
# - Repos with an open onboarding ticket. The validation gate
#   already excludes these from VALIDATED_REPOS_JSON, but this is
#   belt-and-suspenders against any future caller that bypasses
#   the validated set.
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

# Scheduled maintenance pass -- priority 1 in the work cascade.
# Iterates VALIDATED_REPOS_JSON (set by the validation sweep); fires
# on a random repo eligible this ISO week. Exits 0 if maintenance
# fires; returns 1 when no validated repo is eligible this week.
#
# Hybrid execution:
#   - Harness runs the audit tools itself via lib/maintenance-checks.sh
#     (npm audit + outdated, cargo audit + outdated, pip-audit + pip
#     list --outdated, govulncheck + go list -m -u all, bundle-audit
#     + bundle outdated).
#   - Clean week -> templated journal entry, no LLM, no issue.
#   - No recognized stack -> templated "nothing to audit" journal
#     entry, no LLM, no issue.
#   - Findings -> invoke Claude to triage; harness files the
#     Status/Need More Info issue with the triaged report and
#     appends the journal entry.
do_maintenance_tick() {
  # Maintenance is Igor-driven (scheduled chore, not human-triggered),
  # so it only fires inside the shift window.
  in_shift_window || return 1

  local target=""
  local ELIGIBLE=()
  local repo_line r_name
  while IFS= read -r repo_line; do
    [ -z "$repo_line" ] && continue
    r_name=$(jq -r '.full_name' <<<"$repo_line")
    if maintenance_eligible "$r_name"; then
      ELIGIBLE+=("$r_name")
    fi
  done <<<"$VALIDATED_REPOS_JSON"

  if [ "${#ELIGIBLE[@]}" -eq 0 ]; then
    log "maintenance: no validated repos eligible this week -- continuing"
    return 1
  fi

  target="${ELIGIBLE[RANDOM % ${#ELIGIBLE[@]}]}"
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
  (cd "$target_path" && git fetch --prune origin)
  (cd "$target_path" && git worktree add --detach "$m_worktree" "origin/${target_base}")
  init_igor_scratch "$m_worktree"

  # Worktree cleanup at script exit. M_WT_PATH/M_TGT_PATH need
  # global scope so the trap can see them.
  M_WT_PATH="$m_worktree"
  M_TGT_PATH="$target_path"
  trap '[ -d "$M_WT_PATH" ] && (cd "$M_TGT_PATH" && git worktree remove --force "$M_WT_PATH") 2>/dev/null || true; rag_cleanup_marker' EXIT

  cd "$m_worktree"

  local m_brain="$AGENT_REPO_ROOT/${BOT_USER}/brain"
  local audit_dir="$m_worktree/.agent/audit-output"
  mkdir -p "$audit_dir"

  log "maintenance: running audit tools on $target"
  local audit_rc=0
  set +e
  maintenance_audit_repo "$m_worktree" "$audit_dir"
  audit_rc=$?
  set -e

  # rc==2: no recognized stack manifests. Templated "no audit
  # surface" journal entry. Still mark done so we don't try again
  # this week.
  if [ "$audit_rc" -eq 2 ]; then
    log "maintenance: no recognized stack at $target -- nothing to audit"
    local jbody="$m_worktree/.agent/AGENT_JOURNAL.md"
    {
      printf 'Scheduled maintenance pass on %s.\n\n' "$target"
      printf 'No recognized stack manifests (package.json / Cargo.toml / pyproject.toml / requirements.txt / go.mod / Gemfile). Nothing to audit.\n'
    } > "$jbody"
    AGENT_BRAIN_PATH="$m_brain" append_journal_entry "maintenance on $target (no stack)" "$jbody"
    maintenance_mark_done "$target"
    exit 0
  fi

  # rc==0: every audit/outdated check came back clean. Templated
  # journal entry, no LLM, no Forgejo issue. The "X weeks clean"
  # baseline accumulates via these entries.
  if [ "$audit_rc" -eq 0 ]; then
    log "maintenance: all checks clean on $target"
    local jbody="$m_worktree/.agent/AGENT_JOURNAL.md"
    {
      printf 'Scheduled maintenance pass on %s.\n\n' "$target"
      printf 'All checks clean.\n\n'
      printf 'Tools run:\n\n'
      sed 's/^/- /' "$audit_dir/AUDIT_SUMMARY.txt"
    } > "$jbody"
    AGENT_BRAIN_PATH="$m_brain" append_journal_entry "maintenance on $target (clean)" "$jbody"
    maintenance_mark_done "$target"
    exit 0
  fi

  # rc==1: findings present in at least one tool's output. Invoke
  # Claude to triage. The raw output files are in
  # .agent/audit-output/ for him to read.
  log "maintenance: findings detected on $target, invoking claude for triage"

  local m_rag_context
  m_rag_context=$(AGENT_BRAIN_PATH="$m_brain" rag_query "maintenance pass on $target")
  [ -n "$m_rag_context" ] && log "rag: surfaced past context for maintenance"

  local m_user_msg
  m_user_msg=$(cat <<EOF
You are triaging the output of a scheduled maintenance audit on $target.

The harness already ran the audit tools. Their raw output is in
.agent/audit-output/ -- one file per tool, plus AUDIT_SUMMARY.txt
listing clean/findings/skipped per check.

Your job:

  1. Read .agent/audit-output/AUDIT_SUMMARY.txt for the at-a-glance
     status, then read the individual files for any check marked
     "findings". Skip the "clean" and "skipped" entries unless
     context warrants a look.
  2. Apply judgment: which findings actually matter for THIS repo?
     Are CVEs reachable in the code? Are outdated deps blocking
     something or just trivia? Read the source as needed.
  3. Write .agent/AGENT_MAINTENANCE_FINDINGS.md with a triaged
     summary -- lead with what matters, bury what's noise. The
     harness files this as a Forgejo issue for human triage.
  4. Write a single-word severity to
     .agent/AGENT_MAINTENANCE_PRIORITY: critical, high, medium, or
     low. Guidelines:
       - critical: actively-exploited vulns, leaked secrets in deps
       - high:     unfixed CVEs of moderate-or-worse severity
       - medium:   outdated-but-functional, low-severity advisories
       - low:      minor version bumps, nice-to-haves
  5. Write .agent/AGENT_JOURNAL.md with what you observed (severity
     summary, patterns across the audit, whether RAG surfaced
     repeat issues from prior weeks). Brief is fine.

You're triaging, not fixing. Don't commit, don't open PRs. The
harness files the issue + appends the journal.

---

## Past context (RAG)

${m_rag_context:-(no past context retrieved this tick)}
EOF
)

  local m_system_prompt
  m_system_prompt=$(brain_system_prompt "$m_brain")

  log "invoking claude for maintenance triage (timeout ${TICK_TIMEOUT})"
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
    log "maintenance: claude exited without findings file -- nothing to file"
  fi

  # Journal append: prefer Claude's entry, fall back to a stub if
  # he didn't write one.
  local jbody="$m_worktree/.agent/AGENT_JOURNAL.md"
  if [ ! -s "$jbody" ]; then
    {
      printf 'Scheduled maintenance pass on %s.\n\n' "$target"
      printf 'Findings detected (see Forgejo issue if filed).\n\n'
      printf 'Audit summary:\n\n'
      sed 's/^/- /' "$audit_dir/AUDIT_SUMMARY.txt"
    } > "$jbody"
  fi
  AGENT_BRAIN_PATH="$m_brain" append_journal_entry "maintenance on $target (findings)" "$jbody"

  maintenance_mark_done "$target"
  exit 0
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

# -- Shift gate (split: human-driven vs Igor-driven) -----------
#
# The shift used to be a hard tick gate -- outside hours, the whole
# tick exited. That made the agent unresponsive to human signals
# (reviewer requested changes, human filed a new issue) for the
# 16 off-shift hours.
#
# New model: the tick always runs to completion. The shift gates
# only Igor-driven work:
#   - Scheduled maintenance (do_maintenance_tick)
#   - Discretionary website work / reading / reflection
#   - Tier-1 issue work where the issue author IS the bot (issues
#     Igor filed himself via agent-enqueue.sh during site-work)
#
# Human-driven work runs around the clock:
#   - Validation sweep
#   - Recovery sweep
#   - PR-review pickup (REQUEST_CHANGES, reassignment)
#   - Tier-1 issue work where the author is NOT the bot
#
# in_shift_window is consulted per-step below instead of gating
# at the top.

if ! in_shift_window; then
  log "outside shift window (${AGENT_SHIFT_START:-unset}-${AGENT_SHIFT_END:-unset}), current hour $(date +%H) -- human-driven work only this tick"
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
VALIDATED_REPOS_JSON=""
VAL_PASS=0
VAL_FAIL=0
VAL_SKIPPED=0
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

  set +e
  V_REPORT=$(validate_repo_via_api "$R_NAME")
  V_RC=$?
  set -e
  if [ "$V_RC" -eq 0 ]; then
    VALIDATED_REPOS_JSON+="${repo_line}"$'\n'
    VAL_PASS=$((VAL_PASS + 1))
  else
    log "validation: $R_NAME failed -- filing/reopening onboarding ticket"
    handle_onboarding_failure "$R_NAME" "$BOT_USER" "$V_REPORT" \
      || log "warning: onboarding handler failed on $R_NAME (token scope or repo perms); continuing"
    VAL_FAIL=$((VAL_FAIL + 1))
  fi
done < <(jq -c '.[]' <<<"$ALL_REPOS")
log "validation: ${VAL_PASS} pass, ${VAL_FAIL} fail, ${VAL_SKIPPED} skipped (open onboarding ticket)"

if [ -z "$VALIDATED_REPOS_JSON" ]; then
  log "validation: no repos passed -- nothing to do this tick"
  exit 0
fi

# -- Scheduled maintenance (priority 1) ------------------------
#
# Weekly dep-freshness + security audit. Runs at the top of the
# cascade so it always beats PR-review, claimable issues, and
# discretionary website work. One repo per tick, weekly cap per
# repo (ISO week, starts Monday). No shift-window gate -- any tick
# all week can pick up an eligible repo.

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

    # Outside shift, only human-filed tickets are eligible. Tickets
    # the bot filed himself (via agent-enqueue.sh during discretionary
    # site-work) are Igor's own queue and respect the shift gate the
    # same way discretionary work does.
    if ! in_shift_window; then
      C_AUTHOR=$(jq -r '.user.login // ""' <<<"$candidate")
      if [ "$C_AUTHOR" = "$BOT_USER" ]; then
        log "skipping ${R_NAME}#${C_NUM} -- bot-filed and outside shift"
        continue
      fi
    fi

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

# -- Reading pipeline + site-work block (no claimable work) ---
#
# When discovery came up empty, we still run Igor-driven work
# inside the shift window: read a few sources (and maybe ship a
# post if material clusters), then a site-work block. Both
# scripts are self-contained executors; the harness just invokes
# them. Daily-refrain ("post already shipped today -> stop
# reading") is enforced inside reading-pipeline.sh; the 1-in-10
# play-tick dice roll is inside site-work-block.sh.
#
# Phase 4 wire-in for the refactor (~/Notes/igor-refactor-plan.md).
# Phase 4c moves these calls so they fire AFTER the issues loop
# too, not only when discovery comes up empty.

if [ -z "$WINNER" ]; then
  log "no claimable work across any repo"

  if in_shift_window; then
    log "running reading pipeline"
    "$AGENT_HOME/bin/reading-pipeline.sh" --live \
      || log "warning: reading-pipeline exited rc=$?"

    log "running site-work block"
    "$AGENT_HOME/bin/site-work-block.sh" --live \
      || log "warning: site-work-block exited rc=$?"
  else
    log "outside shift window -- skipping reading + site-work"
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

# -- Brain journal: append Claude's reflection (or harness stub) ------
#
# AGENTS.md mandates a journal entry every tick. Claude writes
# .agent/AGENT_JOURNAL.md before exit; if he forgets, the harness
# falls back to a fact stub built from what it knows here. Brain
# always gets an entry. The harness owns the brain commit -- Claude's
# worktree never reaches across to brain. Best-effort: if pull/push
# fails, log it but don't fail the tick over a journal entry.

JOURNAL_SRC="$WORKTREE/.agent/AGENT_JOURNAL.md"
BRAIN_LOCAL="$AGENT_REPO_ROOT/${BOT_USER}/brain"
JOURNAL_FALLBACK=$(cat <<EOF
(no reflection from Claude this tick -- harness recorded the facts below)

- Issue: ${FORGEJO_REPO}#${ISSUE_NUMBER} -- ${ISSUE_TITLE}
- Commit subject: ${COMMIT_SUBJECT:-(no commit this tick)}
- Files changed: ${DIRTY_COUNT:-0}
- Elapsed: ${ELAPSED}s
EOF
)
append_journal_entry "${FORGEJO_REPO}#${ISSUE_NUMBER}" "$JOURNAL_SRC" "$JOURNAL_FALLBACK"
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
