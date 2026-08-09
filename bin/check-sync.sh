#!/usr/bin/env bash
# check-sync.sh -- Verify the worker-contract <-> tick.sh contract is in
# sync, then run the repo's shell-function unit tests.
#
# Catches:
#  1. Outcome sets diverge -- a branch in tick.sh marked with
#     `# OUTCOME: <label>` must have a matching `<!-- OUTCOME: <label> -->`
#     in the worker-contract document, and vice versa.
#  2. Helper scripts referenced in that document (anything matching
#     `agent-*.sh`) must exist and be executable in `bin/`.
#  3. Any bin/test-*.sh unit tests fail (each is self-contained and
#     skip-safe -- a missing tool exits 0 -- so this stays the single CI gate).
#
# Since igor#485/#486 the actual issue-work system prompt is built from
# `context_surface worker-contract` (lib/context-source.sh's last-good
# Distillery cache), not this repo's AGENTS.md -- so (1) and (2) must
# validate whichever document the worker actually receives, or they'd be
# checking a copy the model never reads (igor#487). When a cache is
# already seeded (every production host, mid-tick), that's the sourced
# worker-contract body. A CI container has no cache and typically no
# Distillery SSH access either -- see worker_contract_doc() below for the
# best-effort seed attempt and the AGENTS.md fallback.
#
# Exits 0 on success, 1 on any mismatch or test failure. Run by
# .forgejo/workflows/lint.yml on every PR and push.

set -euo pipefail

AGENT_HOME="$(cd "$(dirname "$0")/.." && pwd)"
cd "$AGENT_HOME"

# shellcheck source=../lib/suite-guard.sh
. "$AGENT_HOME/lib/suite-guard.sh"
# shellcheck source=../lib/context-source.sh
. "$AGENT_HOME/lib/context-source.sh"

FAIL=0

# -- Worker-contract document ------------------------------------
#
# Prefer the sourced worker-contract (what the worker actually reads).
# If the cache isn't seeded yet, make one best-effort attempt to seed it
# (mirrors bin/tick.sh's own clone/fetch + context_refresh, using
# FORGEJO_HOST from .env if present) -- this lets a fresh host's first
# `make test` validate the real document instead of the fallback. If
# that doesn't produce a seeded cache (no .env, no network, no
# Distillery access -- the normal CI case), fall back to validating the
# in-repo AGENTS.md stub and say so loudly: it only carries the OUTCOME
# sentinels, not the helper references, so the helper check below is
# vacuous in that mode.
WORKER_DOC_TMP=""
cleanup_worker_doc() { if [ -n "$WORKER_DOC_TMP" ]; then rm -f "$WORKER_DOC_TMP"; fi; }
trap cleanup_worker_doc EXIT

if ! context_seeded; then
  if [ -f "$AGENT_HOME/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$AGENT_HOME/.env"
    set +a
  fi
  if [ -n "${FORGEJO_HOST:-}" ] && command -v git >/dev/null 2>&1; then
    AGENT_STATE_DIR="${AGENT_STATE_DIR:-$HOME/.local/state/agent}"
    AGENT_REPO_ROOT="${AGENT_REPO_ROOT:-$AGENT_STATE_DIR/repos}"
    DISTILLERY_PATH="$AGENT_REPO_ROOT/distillery"
    ssh_clone_url() {
      if [[ "$FORGEJO_HOST" == *:* ]]; then
        echo "ssh://git@${FORGEJO_HOST}/${1}.git"
      else
        echo "git@${FORGEJO_HOST}:${1}.git"
      fi
    }
    if [ ! -d "$DISTILLERY_PATH/.git" ]; then
      mkdir -p "$AGENT_REPO_ROOT"
      git clone --quiet "$(ssh_clone_url joshtronic/distillery)" "$DISTILLERY_PATH" 2>/dev/null || true
    else
      (cd "$DISTILLERY_PATH" && git fetch --prune --quiet origin 2>/dev/null) || true
    fi
    context_refresh || true
  fi
fi

if context_seeded; then
  WORKER_DOC_TMP=$(mktemp)
  context_surface worker-contract > "$WORKER_DOC_TMP"
  WORKER_DOC="$WORKER_DOC_TMP"
  WORKER_DOC_LABEL="the sourced worker-contract (Distillery cache)"
else
  WORKER_DOC="AGENTS.md"
  WORKER_DOC_LABEL="AGENTS.md (fallback -- prompt cache unseeded; helper check will be vacuous)"
  echo "! prompt cache unseeded and no Distillery access -- validating $WORKER_DOC_LABEL instead"
fi
echo "+ validating sentinels/helpers against: $WORKER_DOC_LABEL"

# -- Outcome sentinels ------------------------------------------

tick_outcomes=$(grep -oE '# OUTCOME: [a-z-]+'   bin/tick.sh 2>/dev/null \
                | awk '{print $3}' | sort -u)
agents_outcomes=$(grep -oE 'OUTCOME: [a-z-]+ ' "$WORKER_DOC" 2>/dev/null \
                | awk '{print $2}' | sort -u)

if [ -z "$tick_outcomes" ]; then
  echo "x no OUTCOME sentinels found in bin/tick.sh"
  FAIL=1
fi
if [ -z "$agents_outcomes" ]; then
  echo "x no OUTCOME sentinels found in $WORKER_DOC_LABEL"
  FAIL=1
fi

if [ -n "$tick_outcomes" ] && [ -n "$agents_outcomes" ]; then
  if [ "$tick_outcomes" != "$agents_outcomes" ]; then
    echo "x outcome sets diverge"
    echo "  bin/tick.sh:      $(echo "$tick_outcomes" | tr '\n' ' ')"
    echo "  $WORKER_DOC_LABEL: $(echo "$agents_outcomes" | tr '\n' ' ')"
    diff <(echo "$tick_outcomes") <(echo "$agents_outcomes") | sed 's/^/    /'
    FAIL=1
  else
    echo "+ outcomes match: $(echo "$tick_outcomes" | tr '\n' ' ')"
  fi
fi

# -- Referenced helpers -----------------------------------------

helpers=$(grep -oE 'agent-[a-z-]+\.sh' "$WORKER_DOC" 2>/dev/null | sort -u || true)
for h in $helpers; do
  if [ ! -f "bin/$h" ]; then
    echo "x $WORKER_DOC_LABEL references bin/$h but it does not exist"
    FAIL=1
  elif [ ! -x "bin/$h" ]; then
    echo "x bin/$h exists but is not executable"
    FAIL=1
  else
    echo "+ bin/$h exists and is executable"
  fi
done

# -- Cascade stages ---------------------------------------------
#
# cascade_run dispatches each name in CASCADE_STAGES as `do_<stage>_tick`. A
# typo exits 127, which the gate reads as "this stage did no work" -- so the
# stage is silently never run AND, because cascade_run stamped it as reached,
# silently never starved either. Two things can drift: a name with no matching
# function, and the literal `cascade_run <stage>` gates falling out of step
# with the list they are supposed to enumerate.

cascade_stages=$(sed -n 's/^CASCADE_STAGES="\([^"]*\)".*/\1/p' bin/tick.sh | head -1)
if [ -z "$cascade_stages" ]; then
  echo "x CASCADE_STAGES not found in bin/tick.sh"
  FAIL=1
else
  for stage in $cascade_stages; do
    if grep -qE "^do_${stage}_tick\(\)" bin/tick.sh lib/*.sh; then
      echo "+ cascade stage '$stage' -> do_${stage}_tick"
    else
      echo "x cascade stage '$stage' has no do_${stage}_tick function"
      FAIL=1
    fi
  done

  cascade_calls=$(grep -oE '^if cascade_run [a-z]+' bin/tick.sh | awk '{print $3}' | sort -u)
  if [ "$cascade_calls" != "$(echo "$cascade_stages" | tr ' ' '\n' | sort -u)" ]; then
    echo "x CASCADE_STAGES and the cascade_run gates diverge"
    diff <(echo "$cascade_stages" | tr ' ' '\n' | sort -u) <(echo "$cascade_calls") | sed 's/^/    /'
    FAIL=1
  fi
fi

# -- Review-notification wiring ---------------------------------
#
# The "a PR needs you" email (igor#439) hangs off forgejo_request_review, which
# fires review_notify_human only if something DEFINED it -- lib/forgejo.sh stays
# a pure API wrapper and bin/agent-*.sh keep working without the notifier. That
# makes the hook a per-PROCESS property: an entry point that reaches a review
# request without sourcing lib/reviewnotify.sh requests it and tells the
# operator nothing, which is the "forgot to hook the caller" failure the design
# set out to avoid, just moved to a process boundary. So assert it.

# Every lib/*.sh an entry point sources, transitively (libs don't source libs
# today, but a one-level check would quietly stop being true if one started).
sourced_libs() {
  local pending="$1" seen="" f next
  while [ -n "$pending" ]; do
    f="${pending%%$'\n'*}"
    pending="${pending#"$f"}"; pending="${pending#$'\n'}"
    case $'\n'"$seen"$'\n' in *$'\n'"$f"$'\n'*) continue ;; esac
    seen="${seen}${seen:+$'\n'}$f"
    [ -f "$f" ] || continue
    next=$(grep -oE '^[[:space:]]*(\.|source)[[:space:]]+"?\$AGENT_HOME/lib/[a-z-]+\.sh' "$f" 2>/dev/null \
           | grep -oE 'lib/[a-z-]+\.sh' | sort -u)
    # `if`, not `[ -n "$next" ] && ...`: the && form returns 1 as the loop
    # body's last status whenever a file sources nothing, which is the common
    # case here and exactly the shape errexit trips on.
    if [ -n "$next" ]; then
      pending="${pending}${pending:+$'\n'}$next"
    fi
  done
  printf '%s\n' "$seen"
}

for entry in bin/*.sh; do
  case "$entry" in bin/test-*.sh | bin/check-sync.sh) continue ;; esac
  reach=$(sourced_libs "$entry")
  # lib/forgejo.sh is excluded from the CALLER scan on purpose: it holds the
  # definitions, and its one internal call is inside forgejo_open_pr -- which is
  # exactly what we're tracking. Counting it would drag in every read-only
  # helper that merely talks to Forgejo.
  callers=$(printf '%s\n' "$reach" | grep -v '^lib/forgejo\.sh$' | tr '\n' ' ')
  [ -n "${callers// /}" ] || continue
  # shellcheck disable=SC2086  # deliberate word-split: $callers is a file list
  if ! grep -hE '(forgejo_request_review|forgejo_open_pr)' $callers 2>/dev/null \
       | grep -qvE '^[[:space:]]*#'; then
    continue
  fi
  if printf '%s\n' "$reach" | grep -q '^lib/reviewnotify\.sh$'; then
    echo "+ $entry can request a review and sources lib/reviewnotify.sh"
  else
    echo "x $entry reaches forgejo_request_review but never sources lib/reviewnotify.sh"
    echo "    -- the review request lands and the operator is never emailed (igor#439)"
    FAIL=1
  fi
done

# -- Unit tests -------------------------------------------------

for t in bin/test-*.sh; do
  [ -f "$t" ] || continue   # no matches -> the literal glob; skip it
  # Runs the suite, echoes its output verbatim, and applies the skipped-
  # assertion guard. Must stay in a condition context -- under `set -e` a bare
  # call would abort the loop on the first failing suite.
  suite_run_report "$t" || FAIL=1
done

exit $FAIL
