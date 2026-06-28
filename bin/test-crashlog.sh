#!/usr/bin/env bash
# Unit tests for lib/crashlog.sh -- post-mortem capture of in-flight model calls.
# Skip-safe: exits 0 with a notice if a required tool is missing.
set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/crashlog.sh
. "$HERE/lib/crashlog.sh"

for t in date mkdir cp ls basename rm; do
  command -v "$t" >/dev/null 2>&1 || { echo "test-crashlog: $t unavailable -- skipping"; exit 0; }
done

FAIL=0
eq() { if [ "$2" = "$3" ]; then printf '  + %s\n' "$1"; else printf '  x %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi; }

TMP=$(mktemp -d) || { echo "test-crashlog: mktemp unavailable -- skipping"; exit 0; }
trap 'rm -rf "$TMP"' EXIT

echo "== crashlog_preserve =="
# A worktree still carrying an in-flight marker -> its stream is preserved.
STATE="$TMP/s1"; WT="$TMP/wt-pr42"
mkdir -p "$WT/.agent"
printf 'pr-review\t1700000000\n' > "$WT/.agent/claude-in-flight"
printf '{"type":"result"}\n'     > "$WT/.agent/claude-stream.jsonl"
printf '[tool: Skill]\n'         > "$WT/.agent/claude-output.log"
crashlog_preserve 1 "$STATE" "$WT" >/dev/null 2>&1
d=$(ls -d "$STATE/crash-logs"/*/ 2>/dev/null | head -1)
eq "preserves the raw stream"  "1" "$([ -f "${d}claude-stream.jsonl" ] && echo 1 || echo 0)"
eq "preserves the call-site"   "1" "$([ -f "${d}call-site" ] && echo 1 || echo 0)"
eq "preserves the display log" "1" "$([ -f "${d}claude-output.log" ] && echo 1 || echo 0)"
eq "dir name carries the rc"   "1" "$(printf '%s' "$d" | grep -c 'rc1')"

# A worktree with no marker (clean return) -> skipped entirely.
STATE2="$TMP/s2"; WT2="$TMP/wt-clean"
mkdir -p "$WT2/.agent"; printf 'x' > "$WT2/.agent/claude-stream.jsonl"
crashlog_preserve 1 "$STATE2" "$WT2" >/dev/null 2>&1
eq "no marker -> nothing preserved" "0" "$(ls -d "$STATE2/crash-logs"/*/ 2>/dev/null | wc -l | tr -d ' ')"

# An empty worktree argument (unset PR_WORKTREE) -> safe no-op.
crashlog_preserve 1 "$TMP/s3" "" >/dev/null 2>&1
eq "empty worktree arg is a no-op" "0" "$(ls -d "$TMP/s3/crash-logs"/*/ 2>/dev/null | wc -l | tr -d ' ')"

echo "== crashlog_prune =="
PSTATE="$TMP/p"; mkdir -p "$PSTATE/crash-logs"
for i in $(seq 1 25); do mkdir -p "$PSTATE/crash-logs/d$i"; done
crashlog_prune "$PSTATE" >/dev/null 2>&1
eq "keeps CRASHLOG_KEEP (20) newest" "20" "$(ls -d "$PSTATE/crash-logs"/*/ 2>/dev/null | wc -l | tr -d ' ')"

crashlog_prune "$TMP/nonexistent" >/dev/null 2>&1
eq "prune of a missing dir is safe (rc0)" "0" "$?"

if [ "$FAIL" -eq 0 ]; then
  echo "test-crashlog: all checks passed"
else
  echo "test-crashlog: $FAIL FAILED"
  exit 1
fi
