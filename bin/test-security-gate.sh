#!/usr/bin/env bash
# test-security-gate.sh -- unit tests for lib/security-gate.sh: the parse/retry
# path (igor#491). Three consecutive no-verdict responses on igor#480's diff
# (a diff whose own prose describes merge-gate security semantics) blocked the
# push with nothing to diagnose -- the reviewer's actual text was never
# captured. This covers: a stub returning non-verdict text twice then a valid
# verdict -> proceeds (and escalates effort + preserves the two undiagnosable
# responses); three non-verdicts -> blocks with all three responses preserved.
# Skip-safe: needs date/mkdir/find; exits 0 with a notice if absent. git and
# claude_call are both stubbed -- no real repo, no model calls.
set -uo pipefail

for t in date mkdir find; do
  command -v "$t" >/dev/null 2>&1 || { echo "test-security-gate: $t unavailable -- skipping"; exit 0; }
done

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/security-gate.sh
. "$HERE/../lib/security-gate.sh"

TMP="$(mktemp -d)" || { echo "test-security-gate: mktemp unavailable -- skipping"; exit 0; }
trap 'rm -rf "$TMP"' EXIT
export AGENT_STATE_DIR="$TMP/state"
mkdir -p "$AGENT_STATE_DIR"
WT="$TMP/worktree"; mkdir -p "$WT"

FAIL=0
eq()   { if [ "$2" = "$3" ]; then printf '  + %s\n' "$1"; else printf '  x %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi; }
has()  { case "$2" in *"$3"*) printf '  + %s\n' "$1" ;; *) printf '  x %s: [%s] lacks [%s]\n' "$1" "${2:0:200}" "$3"; FAIL=$((FAIL + 1)) ;; esac; }
lacks(){ case "$2" in *"$3"*) printf '  x %s: [%s] still has [%s]\n' "$1" "${2:0:200}" "$3"; FAIL=$((FAIL + 1)) ;; *) printf '  + %s\n' "$1" ;; esac; }

LOGGED=""
log() { LOGGED="${LOGGED}$*"$'\n'; }

# A non-empty diff every time -- security_gate only short-circuits on an
# EMPTY diff, and these tests are about the review-call retry path.
git() { printf 'diff --git a/lib/automerge.sh b/lib/automerge.sh\n+# comment\n'; }

logs_dir() { printf '%s/security-gate-logs' "$AGENT_STATE_DIR"; }
log_count() { find "$(logs_dir)" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' '; }

echo "== security_gate_preserve_response =="
security_gate_preserve_response "issue" "1" "" >/dev/null 2>&1
eq "empty response -> no artifact written" "0" "$(log_count)"

LOGGED=""
security_gate_preserve_response "security-gate-issue" "2" "an essay about the diff" >/dev/null 2>&1
eq "non-empty response -> one artifact written" "1" "$(log_count)"
has "and the artifact holds the raw text" \
  "$(cat "$(logs_dir)"/*attempt2.txt 2>/dev/null)" "an essay about the diff"
has "and the log line names the preserved path" "$LOGGED" "response preserved to"

echo "== security_gate_preserve_response is bounded (SECURITY_GATE_LOG_KEEP) =="
rm -rf "$(logs_dir)"
for i in $(seq 1 25); do
  security_gate_preserve_response "bound-test" "$i" "content-$i" >/dev/null 2>&1
done
eq "keeps SECURITY_GATE_LOG_KEEP (20) newest" "20" "$(log_count)"

echo "== security_gate: immediate PASS =="
rm -rf "$(logs_dir)"
N0="$TMP/n0"; : > "$N0"
claude_call() { printf x >> "$N0"; printf 'No material findings.\nSECURITY_VERDICT: PASS\n'; }
OUT=$(security_gate "$WT" "master" "security-gate-issue"); RC=$?
eq "returns 0" "0" "$RC"
eq "nothing on stdout" "" "$OUT"
eq "one call made" "1" "$(wc -c < "$N0" | tr -d ' ')"

echo "== security_gate: immediate BLOCK =="
rm -rf "$(logs_dir)"
claude_call() { printf -- '- hardcoded API key on line 12\nSECURITY_VERDICT: BLOCK\n'; }
OUT=$(security_gate "$WT" "master" "security-gate-issue"); RC=$?
eq "returns 1" "1" "$RC"
has "findings reach stdout" "$OUT" "hardcoded API key"
lacks "the verdict line itself is stripped from findings" "$OUT" "SECURITY_VERDICT"

echo "== security_gate: transient call failure then PASS (pre-existing retry) =="
rm -rf "$(logs_dir)"
N="$TMP/n1"; : > "$N"
claude_call() {
  n=$(($(cat "$N") + 1)); printf '%s' "$n" > "$N"
  if [ "$n" -eq 1 ]; then return 1; fi
  printf 'No material findings.\nSECURITY_VERDICT: PASS\n'
}
OUT=$(security_gate "$WT" "master" "security-gate-issue"); RC=$?
eq "a failed call followed by a clean PASS still returns 0" "0" "$RC"
eq "two calls made" "2" "$(cat "$N")"

echo "== security_gate: no-verdict twice, then a valid verdict on the escalated 3rd =="
rm -rf "$(logs_dir)"
N2="$TMP/n2"; : > "$N2"
CALLLOG="$TMP/calllog"; : > "$CALLLOG"
claude_call() {
  local model="$1" call_site="$2" max_tokens="$3" system="$4" user="$5" strip="$6" timeout="${7:-unset}"
  n=$(($(cat "$N2") + 1)); printf '%s' "$n" > "$N2"
  printf '%s\t%s\n' "$model" "$timeout" >> "$CALLLOG"
  case "$n" in
    1) printf 'This diff rewrites a header comment describing the merge gate; here is a long discussion of what that gate does and why it matters for the deploy barrier...\n' ;;
    2) printf 'Another rambling response about the security semantics of the gate, still no final line.\n' ;;
    3) printf 'No material findings.\nSECURITY_VERDICT: PASS\n' ;;
  esac
}
OUT=$(security_gate "$WT" "master" "security-gate-issue"); RC=$?
eq "eventually returns 0 (PASS)" "0" "$RC"
eq "three calls made" "3" "$(cat "$N2")"
eq "two undiagnosable responses were preserved" "2" "$(log_count)"
has "attempt 1's essay is on disk" "$(cat "$(logs_dir)"/*attempt1.txt 2>/dev/null)" "header comment describing the merge gate"
has "attempt 2's ramble is on disk" "$(cat "$(logs_dir)"/*attempt2.txt 2>/dev/null)" "rambling response"
THIRD_LINE=$(sed -n '3p' "$CALLLOG")
has "the 3rd (escalated) attempt bumps effort to max" "$THIRD_LINE" ":max"
has "the 3rd attempt gets the longer (600s) budget" "$THIRD_LINE" "600"
FIRST_LINE=$(sed -n '1p' "$CALLLOG")
lacks "attempts 1-2 do NOT carry the escalated effort suffix" "$FIRST_LINE" ":max"

echo "== security_gate: three consecutive no-verdicts -> fail closed =="
rm -rf "$(logs_dir)"
claude_call() { printf 'A long essay that never reaches a verdict line at all.\n'; }
OUT=$(security_gate "$WT" "master" "security-gate-issue"); RC=$?
eq "returns 1 (blocks)" "1" "$RC"
has "says why (re-queue, not a confirmed vuln)" "$OUT" "no verdict from the reviewer after 3 attempts"
has "points at the preserved artifacts" "$OUT" "security-gate-logs"
eq "all three undiagnosable responses were preserved" "3" "$(log_count)"

if [ "$FAIL" -eq 0 ]; then
  echo "test-security-gate: all checks passed"
else
  echo "test-security-gate: $FAIL FAILED"
  exit 1
fi
