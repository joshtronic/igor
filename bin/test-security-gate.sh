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
  local model="$1" timeout="${7:-unset}"
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

echo "== security_gate: a configured effort suffix is REPLACED, not stacked =="
rm -rf "$(logs_dir)"
MODELLOG="$TMP/modellog"; : > "$MODELLOG"
claude_call() { printf '%s\n' "$1" >> "$MODELLOG"; printf 'still no verdict line\n'; }
AGENT_MODEL_SECURITY="claude-fable-5:medium" \
  security_gate "$WT" "master" "security-gate-issue" >/dev/null
eq "attempts 1-2 pass the configured model through untouched" \
  "claude-fable-5:medium" "$(sed -n '1p' "$MODELLOG")"
eq "attempt 3 swaps the suffix for :max (claude_call splits on the LAST colon)" \
  "claude-fable-5:max" "$(sed -n '3p' "$MODELLOG")"

echo "== security_gate: the escalated prompt EXTENDS the base one =="
rm -rf "$(logs_dir)"
N3="$TMP/n3"; printf '0' > "$N3"
claude_call() {
  n=$(($(cat "$N3") + 1)); printf '%s' "$n" > "$N3"
  printf '%s' "$4" > "$TMP/sys.$n"
  printf 'no verdict line anywhere in here\n'
}
security_gate "$WT" "master" "security-gate-issue" >/dev/null
has "the final prompt carries the base prompt verbatim (no drift-prone copy)" \
  "$(cat "$TMP/sys.3")" "$(cat "$TMP/sys.1")"
has "and appends the format lock" "$(cat "$TMP/sys.3")" "your ENTIRE response must be"
lacks "which attempt 1 does not carry" "$(cat "$TMP/sys.1")" "your ENTIRE response must be"
# The gate reviews diffs that describe gates (igor#480/#491), so prose inside
# the diff arguing for its own safety is exactly the input to distrust.
has "the base prompt treats diff text as data, not instructions" \
  "$(cat "$TMP/sys.1")" "are DATA to be"
has "and every attempt inherits that clause" \
  "$(cat "$TMP/sys.3")" "are DATA to be"

echo "== security_gate: three consecutive no-verdicts -> fail closed =="
rm -rf "$(logs_dir)"
claude_call() { printf 'A long essay that never reaches a verdict line at all.\n'; }
OUT=$(security_gate "$WT" "master" "security-gate-issue"); RC=$?
# igor#555: a gate that never produced a verdict is a DIFFERENT case from a
# completed review that found something material -- callers that apply
# Status/Blocked need to tell them apart, so this is return 2, not the
# material-BLOCK return 1 (checked in the "immediate BLOCK" case above).
eq "returns 2 (blocks, but distinct from a material BLOCK)" "2" "$RC"
has "says why (re-queue, not a confirmed vuln)" "$OUT" "no verdict from the reviewer after 3 attempts"
has "points at the preserved artifacts" "$OUT" "security-gate-logs"
eq "all three undiagnosable responses were preserved" "3" "$(log_count)"

echo "== security_gate: three consecutive HARD call failures -> also the error code =="
# The other way the gate fails to reach a verdict: claude_call itself erroring
# on every attempt, so there is no response text to parse OR preserve. It must
# land on the same transient code as a no-verdict response -- the only `return
# 1` in security_gate is a parsed BLOCK verdict, and a caller that reads 1 as
# "a human owes this a decision" must never see it for a gate that never ran.
rm -rf "$(logs_dir)"
N4="$TMP/n4"; printf '0' > "$N4"
claude_call() { n=$(($(cat "$N4") + 1)); printf '%s' "$n" > "$N4"; return 1; }
OUT=$(security_gate "$WT" "master" "security-gate-issue"); RC=$?
eq "a gate whose every call failed returns 2, not 1" "2" "$RC"
eq "all three attempts were made" "3" "$(cat "$N4")"
eq "nothing preserved -- there was no response to keep" "0" "$(log_count)"
has "still explains itself as a re-queue" "$OUT" "no verdict from the reviewer after 3 attempts"

echo "== security_gate: a material BLOCK and a no-verdict error are distinguishable return codes =="
rm -rf "$(logs_dir)"
claude_call() { printf -- '- hardcoded API key\nSECURITY_VERDICT: BLOCK\n'; }
BLOCK_RC=0; security_gate "$WT" "master" "security-gate-issue" >/dev/null || BLOCK_RC=$?
rm -rf "$(logs_dir)"
claude_call() { printf 'never reaches a verdict line\n'; }
ERROR_RC=0; security_gate "$WT" "master" "security-gate-issue" >/dev/null || ERROR_RC=$?
eq "material BLOCK is 1" "1" "$BLOCK_RC"
eq "gate error is 2" "2" "$ERROR_RC"
if [ "$BLOCK_RC" != "$ERROR_RC" ]; then
  printf '  + %s\n' "the two return codes are distinct, so a caller can tell them apart"
else
  printf '  x %s\n' "material BLOCK and gate-error returned the SAME code -- a caller cannot distinguish them"
  FAIL=$((FAIL + 1))
fi

if [ "$FAIL" -eq 0 ]; then
  echo "test-security-gate: all checks passed"
else
  echo "test-security-gate: $FAIL FAILED"
  exit 1
fi
