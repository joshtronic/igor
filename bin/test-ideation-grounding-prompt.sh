#!/usr/bin/env bash
# test-ideation-grounding-prompt.sh -- unit tests for the system prompt
# bin/ideation-pipeline.sh's ground_named_entities() builds (igor#540).
#
# igor#540 moved the operator's identity out of that prompt's literal text
# and into OPERATOR_NAME/OPERATOR_HANDLE. The prompt body stays a QUOTED
# heredoc with placeholders swapped afterwards, so a $, backtick, or
# backslash anywhere in it can never expand into (or eat) an instruction --
# these tests pin both halves: the identity does land, and the body is
# still literal.
#
# The function is lifted out of the script (sed range extraction, same
# technique bin/test-reading-slate.sh uses) rather than sourced, since the
# script has top-level side-effecting code a plain `.` would trip over.
#
# shellcheck disable=SC2034  # MODEL/OPERATOR_* are read by the eval'd function
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/ideation-pipeline.sh"
# shellcheck source=../lib/testlib.sh
. "$HERE/../lib/testlib.sh"

FAIL=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; FAIL=$((FAIL + 1)); }

src=$(sed -n '/^ground_named_entities() {$/,/^}$/p' "$SCRIPT")
[ -z "$src" ] && { bad "could not extract ground_named_entities() from bin/ideation-pipeline.sh"; exit 1; }
eval "$src"

# The stub writes to a file, not a variable: ground_named_entities calls
# claude_call inside a command substitution, so an assignment would die with
# that subshell.
CAPTURE=$(mktemp)
trap 'rm -f "$CAPTURE"' EXIT
claude_call() { printf '%s' "$4" > "$CAPTURE"; printf 'NONE\n'; }
MODEL="stub"
OPERATOR_NAME="Ada"
OPERATOR_HANDLE="alovelace"

echo "== the operator identity lands in the system prompt =="
ground_named_entities "a draft" "some sources" >/dev/null
SYS=$(cat "$CAPTURE")
has "OPERATOR_NAME substituted" "$SYS" "- The author: Ada, alovelace."
eq "no placeholder survives" "0" "$(grep -c '__OPERATOR_' "$CAPTURE")"

echo "== the prompt body stays literal (quoted heredoc) =="
# A hostile identity value proves nothing downstream of the swap re-expands,
# and that the rest of the body was never expansion-eligible to begin with.
OPERATOR_NAME='$HOME'
OPERATOR_HANDLE='`id`'
ground_named_entities "a draft" "some sources" >/dev/null
SYS=$(cat "$CAPTURE")
has "\$-bearing name passed through verbatim" "$SYS" '- The author: $HOME, `id`.'
has "instructions after the identity line survive" "$SYS" "Output ONLY a bare list"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "test-ideation-grounding-prompt: all checks passed"
else
  echo "test-ideation-grounding-prompt: $FAIL check(s) failed"
fi
exit "$FAIL"
