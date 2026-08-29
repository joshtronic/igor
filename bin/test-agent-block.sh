#!/usr/bin/env bash
# test-agent-block.sh -- regression guard for igor#434.
#
# The harness posted a block reason (e.g. security-gate findings) ONLY as an
# issue comment, then told the human "remove Status/Blocked to re-queue" --
# but bin/tick.sh builds the next run's prompt from the issue BODY alone,
# never comments. A re-queued ticket got the same body that produced the
# rejected diff, with no trace of why it was blocked, so it just rebuilt the
# same thing and blocked again.
#
# This runs the REAL agent-block.sh as a subprocess (only `curl` is stubbed,
# at the transport layer -- lib/forgejo.sh's own `_fj` is sourced live) and
# proves the round trip end-to-end: the findings PATCHed into the issue body
# survive into the exact prompt shape bin/tick.sh builds for the next tick.
# Skip-safe: needs jq; exits 0 with a notice if absent, like the other
# bin/test-*.sh.
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "test-agent-block: jq absent -- skipping"; exit 0; }

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENT_HOME="$(cd "$HERE/.." && pwd)"
SCRIPT="$HERE/agent-block.sh"
# The consumer half of the probe round trip below (igor#546). Sourced up here,
# before the first subshell, so shellcheck doesn't read $AGENT_HOME as the one
# a subshell re-exported.
# shellcheck source=../lib/blockprobe.sh
. "$AGENT_HOME/lib/blockprobe.sh"

FAIL=0
eq()  { if [ "$2" = "$3" ]; then printf '  + %s\n' "$1"; else printf '  x %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi; }
has() { case "$2" in *"$3"*) printf '  + %s\n' "$1" ;; *) printf '  x %s: [%s] lacks [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)) ;; esac; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# Exported (not just set): agent-block.sh runs as a CHILD bash process below,
# and an exported function carries only its own source text -- variables it
# references are resolved in the callee's environment at call time, not
# lexically bound to this shell. Without exporting these too, curl() below
# would hit "unbound variable" the moment it runs inside that child.
export COMMENT_CAP="$TMP/comment.json"
export BODY_PATCH_CAP="$TMP/body-patch.json"
export ASSIGN_CAP="$TMP/assign.json"
export LABEL_CAP="$TMP/label.json"
export ISSUE_FIXTURE='{"number":42,"body":"Original issue text: do the thing."}'

# Stub curl at the transport layer -- lib/forgejo.sh's `_fj` is real, so this
# exercises the actual request shapes agent-block.sh's calls produce. Args
# arrive as _fj built them: `-X <method> ... [-d <payload>] <url>` (url last).
curl() {
  local args=("$@") n method="GET" data="" url i
  n=${#args[@]}
  url="${args[$((n - 1))]}"
  for ((i = 0; i < n; i++)); do
    [ "${args[$i]}" = "-X" ] && method="${args[$((i + 1))]}"
    [ "${args[$i]}" = "-d" ] && data="${args[$((i + 1))]}"
  done
  case "$url" in
    */issues/42/comments) printf '%s' "$data" >"$COMMENT_CAP"; printf '{}' ;;
    */issues/42/labels)   printf '%s' "$data" >"$LABEL_CAP"; printf '{}' ;;
    */labels)             printf '[{"id":1,"name":"Status/Blocked"}]' ;;
    */issues/42)
      case "$method" in
        GET) [ -n "${ISSUE_GET_FAIL:-}" ] && return 22; printf '%s' "$ISSUE_FIXTURE" ;;
        PATCH)
          case "$data" in
            *'"body"'*)       printf '%s' "$data" >"$BODY_PATCH_CAP" ;;
            *'"assignees"'*)  printf '%s' "$data" >"$ASSIGN_CAP" ;;
          esac
          printf '{}'
          ;;
      esac
      ;;
  esac
}
export -f curl

echo "== agent-block.sh: end-to-end, real script + stubbed transport (igor#434) =="

# NOT env -i: an exported bash function (curl, above) rides in the process
# environment as a `BASH_FUNC_curl%%` entry, and env -i wipes the whole
# environment -- including that -- before the child ever starts.
#
# SC2030/SC2031: the subshell-local exports are the POINT -- each scenario
# below sets up its own child env and must not leak into the next.
# shellcheck disable=SC2030,SC2031
(
  unset FORGEJO_REVIEWER  # keep the run hermetic: no ambient reviewer to notify
  export ISSUE_NUMBER=42 FORGEJO_REPO=acme/x AGENT_HOME="$AGENT_HOME" \
         FORGEJO_URL="https://example.invalid" FORGEJO_TOKEN="test-token"
  bash "$SCRIPT" "SEC-FINDING-XYZ: unauthorized access" >/dev/null 2>&1
)
RC=$?
eq "agent-block.sh exits 0 on a clean run" "0" "$RC"

[ -s "$BODY_PATCH_CAP" ] || { echo "  x no body PATCH captured at all -- aborting remaining checks"; FAIL=$((FAIL + 1)); }

NEW_BODY=$(jq -r '.body // empty' "$BODY_PATCH_CAP" 2>/dev/null)
has "issue body PATCH preserves the original text" "$NEW_BODY" "Original issue text: do the thing."
has "issue body PATCH carries the block findings" "$NEW_BODY" "SEC-FINDING-XYZ: unauthorized access"

COMMENT_BODY=$(jq -r '.body // empty' "$COMMENT_CAP" 2>/dev/null)
has "the comment still carries the findings too" "$COMMENT_BODY" "SEC-FINDING-XYZ: unauthorized access"
has "the comment's instruction matches the real mechanism (body, not a dead-end)" \
  "$COMMENT_BODY" "issue description above"

eq "Status/Blocked label was applied" "1" "$(jq -r '.labels[0]' "$LABEL_CAP" 2>/dev/null)"
eq "the bot was unassigned" "[]" "$(jq -c '.assignees' "$ASSIGN_CAP" 2>/dev/null)"

# The acceptance test that matters: replay bin/tick.sh's own extraction +
# prompt-building shape (ISSUE_BODY=$(jq -r '.body // ""' <<<"$WINNER");
# USER_MSG interpolates it verbatim) using the PATCHed body as what the next
# tick's issue fetch would return, and confirm the findings show up in the
# reconstructed prompt input -- not just "written somewhere" in Forgejo.
echo "== agent-block.sh: the findings reach the rebuilt tick.sh prompt, not just Forgejo (igor#434) =="
WINNER=$(jq -n --arg b "$NEW_BODY" '{number: 42, title: "some issue", body: $b, labels: []}')
ISSUE_BODY=$(jq -r '.body // ""' <<<"$WINNER")
USER_MSG="You are working Forgejo issue #42 in acme/x.

Body:
${ISSUE_BODY}"
has "the rebuilt USER_MSG the next tick would send contains the findings" \
  "$USER_MSG" "SEC-FINDING-XYZ: unauthorized access"

# igor#546: a mechanical probe recorded alongside the reason rides in the
# issue BODY (never just the comment), same rationale as igor#434 above --
# lib/blockprobe.sh's sweep reads only the body.
echo "== agent-block.sh: a mechanical probe is recorded in the issue body (igor#546) =="
export COMMENT_CAP="$TMP/comment-probe.json"
export BODY_PATCH_CAP="$TMP/body-patch-probe.json"
export ASSIGN_CAP="$TMP/assign-probe.json"
export LABEL_CAP="$TMP/label-probe.json"
# shellcheck disable=SC2030,SC2031
(
  unset FORGEJO_REVIEWER
  export ISSUE_NUMBER=42 FORGEJO_REPO=acme/x AGENT_HOME="$AGENT_HOME" \
         FORGEJO_URL="https://example.invalid" FORGEJO_TOKEN="test-token"
  bash "$SCRIPT" "waiting on igor#537 to land" issue-open "joshtronic/igor#537" >/dev/null 2>&1
)
PROBE_BODY=$(jq -r '.body // empty' "$BODY_PATCH_CAP" 2>/dev/null)
has "probe: body carries the probe block"        "$PROBE_BODY" "<!-- probe"
has "probe: body carries the recorded kind"       "$PROBE_BODY" "kind: issue-open"
has "probe: body carries the recorded ref"        "$PROBE_BODY" "ref: joshtronic/igor#537"

# Close the producer -> consumer loop on the body the PRODUCER actually
# PATCHes. The substring checks above pass on a body the sweep can't read:
# blockprobe's parsers work from the LAST "## Blocked (" heading onward, so
# they also depend on forgejo_append_issue_body emitting that heading exactly
# -- something no substring assertion here covers. Run the real consumer.
eq "probe round trip: the sweep parses the kind back" "issue-open" \
   "$(blockprobe_parse_kind "$PROBE_BODY")"
eq "probe round trip: the sweep parses the ref back"  "joshtronic/igor#537" \
   "$(blockprobe_parse_ref "$PROBE_BODY")"
eq "probe round trip: the sweep parses the reason back" "waiting on igor#537 to land" \
   "$(blockprobe_last_reason "$PROBE_BODY")"
eq "probe round trip: a fresh probe is not already spent" "" \
   "$(blockprobe_parse_cleared "$PROBE_BODY")"

echo "== agent-block.sh: an operator-kind probe needs no ref (igor#546) =="
export BODY_PATCH_CAP="$TMP/body-patch-operator.json"
# shellcheck disable=SC2030,SC2031
(
  unset FORGEJO_REVIEWER
  export ISSUE_NUMBER=42 FORGEJO_REPO=acme/x AGENT_HOME="$AGENT_HOME" \
         FORGEJO_URL="https://example.invalid" FORGEJO_TOKEN="test-token"
  bash "$SCRIPT" "the operator needs to pick an approach" operator >/dev/null 2>&1
)
OP_BODY=$(jq -r '.body // empty' "$BODY_PATCH_CAP" 2>/dev/null)
has "operator probe: body carries kind: operator" "$OP_BODY" "kind: operator"

# igor#555: the security gate's no-verdict/gate-error path has no external
# condition to check either, so it records a probe the same way operator
# does -- no ref -- but with different (self-clearing) sweep semantics.
echo "== agent-block.sh: a transient-kind probe needs no ref (igor#555) =="
export BODY_PATCH_CAP="$TMP/body-patch-transient.json"
# shellcheck disable=SC2030,SC2031
(
  unset FORGEJO_REVIEWER
  export ISSUE_NUMBER=42 FORGEJO_REPO=acme/x AGENT_HOME="$AGENT_HOME" \
         FORGEJO_URL="https://example.invalid" FORGEJO_TOKEN="test-token"
  bash "$SCRIPT" "the security gate produced no verdict" transient >/dev/null 2>&1
)
TRANSIENT_BODY=$(jq -r '.body // empty' "$BODY_PATCH_CAP" 2>/dev/null)
has "transient probe: body carries kind: transient" "$TRANSIENT_BODY" "kind: transient"
eq "transient probe: parses back as kind transient" "transient" \
   "$(blockprobe_parse_kind "$TRANSIENT_BODY")"

echo "== agent-block.sh: an unrecognized probe kind is dropped, not fatal, still blocks (igor#546) =="
export BODY_PATCH_CAP="$TMP/body-patch-badkind.json"
BADKIND_ERR="$TMP/badkind-stderr.txt"
# shellcheck disable=SC2030,SC2031
(
  unset FORGEJO_REVIEWER
  export ISSUE_NUMBER=42 FORGEJO_REPO=acme/x AGENT_HOME="$AGENT_HOME" \
         FORGEJO_URL="https://example.invalid" FORGEJO_TOKEN="test-token"
  bash "$SCRIPT" "some reason" made-up-kind "joshtronic/igor#537" >/dev/null 2>"$BADKIND_ERR"
)
RC_BADKIND=$?
eq "bad kind: still exits 0 (block still lands)" "0" "$RC_BADKIND"
BADKIND_BODY=$(jq -r '.body // empty' "$BODY_PATCH_CAP" 2>/dev/null)
lacks_probe=$(case "$BADKIND_BODY" in *"<!-- probe"*) echo present ;; *) echo absent ;; esac)
eq "bad kind: no probe block recorded" "absent" "$lacks_probe"
has "bad kind: warns on stderr" "$(cat "$BADKIND_ERR")" "unrecognized probe kind"

echo "== agent-block.sh: a mechanical kind missing its ref is dropped, not fatal (igor#546) =="
export BODY_PATCH_CAP="$TMP/body-patch-noref.json"
NOREF_ERR="$TMP/noref-stderr.txt"
# shellcheck disable=SC2030,SC2031
(
  unset FORGEJO_REVIEWER
  export ISSUE_NUMBER=42 FORGEJO_REPO=acme/x AGENT_HOME="$AGENT_HOME" \
         FORGEJO_URL="https://example.invalid" FORGEJO_TOKEN="test-token"
  bash "$SCRIPT" "some reason" issue-open >/dev/null 2>"$NOREF_ERR"
)
NOREF_BODY=$(jq -r '.body // empty' "$BODY_PATCH_CAP" 2>/dev/null)
lacks_probe2=$(case "$NOREF_BODY" in *"<!-- probe"*) echo present ;; *) echo absent ;; esac)
eq "no ref: no probe block recorded" "absent" "$lacks_probe2"
has "no ref: warns on stderr" "$(cat "$NOREF_ERR")" "needs a ref"

# The other branch, end-to-end: the body append fails (a token blip, a
# renumbered issue) and the block itself must still land. The append is
# best-effort precisely because the comment + label + unassign are what
# actually mark the issue blocked -- and the comment must NOT then claim a
# mechanism that didn't happen, which is the bug igor#434 fixed in the first
# place, just in a different guise.
echo "== agent-block.sh: a failed body append still blocks the issue, and says so honestly (igor#434) =="
export COMMENT_CAP="$TMP/comment2.json"
export BODY_PATCH_CAP="$TMP/body-patch2.json"
export ASSIGN_CAP="$TMP/assign2.json"
export LABEL_CAP="$TMP/label2.json"
export ISSUE_GET_FAIL=1
FAIL_ERR="$TMP/stderr2.txt"
# shellcheck disable=SC2030,SC2031
(
  unset FORGEJO_REVIEWER
  export ISSUE_NUMBER=42 FORGEJO_REPO=acme/x AGENT_HOME="$AGENT_HOME" \
         FORGEJO_URL="https://example.invalid" FORGEJO_TOKEN="test-token"
  bash "$SCRIPT" "SEC-FINDING-XYZ: unauthorized access" >/dev/null 2>"$FAIL_ERR"
)
RC2=$?
unset ISSUE_GET_FAIL
eq "append failure is non-fatal -- agent-block.sh still exits 0" "0" "$RC2"
eq "append failure -> the issue body is never PATCHed" "false" \
  "$([ -s "$BODY_PATCH_CAP" ] && echo true || echo false)"
has "append failure is reported on stderr" "$(cat "$FAIL_ERR")" \
  "could not append findings to the issue body"

COMMENT2=$(jq -r '.body // empty' "$COMMENT_CAP" 2>/dev/null)
has "append failure -> the comment still carries the findings" \
  "$COMMENT2" "SEC-FINDING-XYZ: unauthorized access"
eq "append failure -> the comment does not claim the body was updated" "false" \
  "$(grep -q 'issue description above' <<<"$COMMENT2" && echo true || echo false)"

eq "append failure -> Status/Blocked is still applied" "1" \
  "$(jq -r '.labels[0]' "$LABEL_CAP" 2>/dev/null)"
eq "append failure -> the bot is still unassigned" "[]" \
  "$(jq -c '.assignees' "$ASSIGN_CAP" 2>/dev/null)"

if [ "$FAIL" -eq 0 ]; then echo "test-agent-block: all checks passed"; exit 0; fi
echo "test-agent-block: $FAIL check(s) FAILED"
exit 1
