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
      Usage:*|*"Usage:"*) ok "$base $flag -> usage, exit 0, no environment needed" ;;
      *) bad "$base $flag: exit 0 but printed no usage: ${out:0:60}" ;;
    esac
  done
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
