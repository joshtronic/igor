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
# checking a copy the model never reads (igor#487). lib/worker-doc.sh
# owns that choice: the sourced body on a seeded host, the in-repo
# AGENTS.md (announced as a fallback) in a CI container with no cache.
#
# Exits 0 on success, 1 on any mismatch or test failure. Run by
# .forgejo/workflows/lint.yml on every PR and push.
#
# Every check below reports failure inline as its own "x <reason>" line, then
# keeps going -- so a run with dozens of checks after the failing one pushes
# that line out of a truncated tail (a CI-log-tail-fed rework prompt saw
# nothing but a run of passes and the runner's bare exit code, igor#522). Hence
# the summary before the exit code: it lands the reason inside any tail window.

set -euo pipefail

AGENT_HOME="$(cd "$(dirname "$0")/.." && pwd)"
cd "$AGENT_HOME"

# shellcheck source=../lib/suite-guard.sh
. "$AGENT_HOME/lib/suite-guard.sh"
# shellcheck source=../lib/context-source.sh
. "$AGENT_HOME/lib/context-source.sh"
# shellcheck source=../lib/worker-doc.sh
. "$AGENT_HOME/lib/worker-doc.sh"

check_sync() {
  # The caller disables errexit around the pipeline this runs in (see below),
  # and that reaches in here too -- leaving every check to carry on past a
  # command that died mid-way, which is how a broken run reports green. Re-arm
  # it. This executes in the pipeline's subshell, so it cannot leak back out.
  set -e

  local FAIL=0

  # -- Worker-contract document ------------------------------------

  WORKER_DOC_TMP=$(mktemp)
  # Set inside the pipeline's subshell, where bash has reset the inherited EXIT
  # trap -- so this one owns WORKER_DOC_TMP and the caller's still owns LOG_TMP.
  trap 'rm -f "$WORKER_DOC_TMP"' EXIT

  # A seeded cache that can't serve the surface is a broken cache, and
  # there's nothing left to check against -- exit rather than carry on
  # with an empty document, which every check below passes vacuously.
  if ! worker_doc_select "$WORKER_DOC_TMP"; then
    echo "x prompt cache is seeded but 'worker-contract' could not be served"
    echo "    -- refusing to validate sentinels/helpers against an empty document"
    return 1
  fi
  if [ "$WORKER_DOC" = "AGENTS.md" ]; then
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
      echo "  bin/tick.sh: $(echo "$tick_outcomes" | tr '\n' ' ')"
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

  return $FAIL
}

LOG_TMP=$(mktemp)
trap 'rm -f "$LOG_TMP"' EXIT

# `set +e` around the pipeline, not a trailing `|| true`: `set -e` would
# otherwise abort the script the instant the pipeline reports nonzero
# (pipefail), and a trailing `|| true` runs as its own command AFTER the
# pipeline, resetting PIPESTATUS to that command's own (zero) status before
# it can be read.
set +e
check_sync 2>&1 | tee "$LOG_TMP"
FAIL=${PIPESTATUS[0]}
set -e

# A missing-tool skip (suite_run_report's `! <suite> skipped (...)` line, see
# lib/suite-guard.sh) exits 0 and is otherwise indistinguishable in the log
# from an ordinary pass -- which is how a jq-less CI runner let the
# automerge/dossier/forgejo/needsyou suites go unexecuted while this stayed
# green (igor#523). Always print the count, even zero, so its absence is
# itself legible rather than silent.
skipped_count=$(grep -cE '^! .+ skipped \(' "$LOG_TMP" || true)

# Skip-safe is for a laptop/host missing an optional tool; it is NOT meant to
# hide a CI runner whose own install step silently regressed. CHECK_SYNC_STRICT
# is set only in .forgejo/workflows/lint.yml, which installs jq itself -- there,
# a skip means the install step failed, a build break wearing a green badge
# (igor#527). `make test` on a bare host stays green by leaving the var unset.
if [ "$skipped_count" -gt 0 ] && [ "${CHECK_SYNC_STRICT:-0}" = "1" ]; then
  echo "x $skipped_count suite(s) skipped for missing tools under CHECK_SYNC_STRICT" >> "$LOG_TMP"
  FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then
  echo
  echo "== FAILURES =="
  # Guarded: grep exits 1 on no match, which under errexit would kill the
  # script here and rewrite $FAIL to 1 under a heading with nothing beneath it.
  grep '^x ' "$LOG_TMP" || echo "(no 'x' lines -- the run died mid-check; see the full output above)"
fi

echo
echo "$skipped_count suite(s) skipped for missing tools"

exit "$FAIL"
