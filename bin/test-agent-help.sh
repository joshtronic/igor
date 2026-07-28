#!/usr/bin/env bash
# Every bin/agent-*.sh helper must treat --help/-h as a request for usage, NOT as
# its first positional argument.
#
# The failure this guards is not theoretical. agent-report.sh had it (igor#398):
# `--help` was taken as the report BODY and posted as a live comment on a real
# issue. The fix was applied there and nowhere else, so agent-block.sh kept it --
# `agent-block.sh --help` blocked the ticket with reason "--help", which is how
# knowthetable.com#42 ended up Status/Blocked for no reason at all.
#
# This asserts the property for EVERY agent-*.sh, so the next one added inherits
# the guard instead of rediscovering the bug.
#
# Deliberately run with NO tick environment: a helper that short-circuits before
# touching Forgejo cannot need ISSUE_NUMBER/FORGEJO_*/AGENT_HOME. If one of these
# starts failing because a var is missing, that IS the bug -- it means the script
# got far enough to try to act.
#
# The second block asserts the mirror property: with NO arguments a helper must
# REFUSE (non-zero) at the argument check and stop there. Same class of bug from
# the other side -- a helper that prints usage and then keeps going acts on empty
# arguments. (A shadowed `usage()` that lost its `exit 1` did exactly this.)
#
# Scope note: the --help guard inspects "$1" only, so `agent-ask.sh some/repo
# --help` still reads --help as the title. That is the reported failure mode and
# all these helpers need; none of them do real flag parsing.
set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
FAIL=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; FAIL=$((FAIL + 1)); }

echo "== every agent-*.sh short-circuits on --help/-h (igor#398 generalised) =="
COUNT=0
for f in "$HERE"/bin/agent-*.sh; do
  [ -f "$f" ] || continue
  COUNT=$((COUNT + 1))
  base=$(basename "$f")
  for flag in --help -h; do
    # env -i: not one tick variable is set. Reaching Forgejo is impossible without them.
    out=$(env -i PATH="$PATH" bash "$f" "$flag" 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then
      bad "$base $flag: exited $rc (expected 0 -- it got past the guard)"
      continue
    fi
    case "$out" in
      *"Usage:"*|*"usage:"*) ok "$base $flag -> usage, exit 0, no environment needed" ;;
      *) bad "$base $flag: exit 0 but printed no usage: ${out:0:60}" ;;
    esac
  done
done

echo "== every agent-*.sh refuses zero arguments instead of falling through =="
for f in "$HERE"/bin/agent-*.sh; do
  [ -f "$f" ] || continue
  base=$(basename "$f")
  out=$(env -i PATH="$PATH" bash "$f" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then
    bad "$base (no args): exited 0 -- it did not refuse"
    continue
  fi
  # Every helper checks its arguments before it checks its environment, so
  # reaching an env check proves the argument check let it through.
  case "$out" in
    *"are you being run from a tick"*)
      bad "$base (no args): fell past the argument check into the env checks" ;;
    *"Usage:"*|*"usage:"*) ok "$base (no args) -> usage, non-zero exit, stopped at the argument check" ;;
    *) bad "$base (no args): exited $rc but printed no usage: ${out:0:60}" ;;
  esac
done

if [ "$COUNT" -eq 0 ]; then
  bad "no bin/agent-*.sh found -- this suite would pass vacuously"
else
  ok "checked $COUNT helper script(s)"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "test-agent-help: all checks passed"
else
  echo "test-agent-help: $FAIL FAILED"
  exit 1
fi
