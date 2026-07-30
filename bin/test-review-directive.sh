#!/usr/bin/env bash
# test-review-directive.sh -- the review directive's machine contract must match
# what review_parse_response actually accepts.
#
# bin/lib/review-directive.md is prose, and prose is not unit-testable: no
# assertion here can tell you whether the rubric produces good verdicts. What IS
# testable is the handshake, and it is load-bearing -- the directive tells the
# model to emit `VERDICT: <token>` above a `===BODY===` sentinel, and
# review_parse_response in bin/tick.sh accepts exactly three tokens and that one
# sentinel. Edit the directive's output-format block without touching the
# parser and every review becomes "no parseable verdict after 2 attempts",
# which retries twice per tick, forever, and looks like a model failure rather
# than a text mismatch.
#
# Nothing covered this file before. Scope is deliberately the contract only.
set -uo pipefail

# Skip-safe per bin/check-sync.sh's contract. Not a courtesy skip: the parser
# lifted below ENDS in `jq -n`, so without jq every round-trip fails on the
# missing tool and the suite reports a directive/parser mismatch that isn't
# there. That is exactly the false red this guard exists to prevent.
command -v jq >/dev/null 2>&1 || { echo "test-review-directive: jq absent -- skipping"; exit 0; }

HERE="$(cd "$(dirname "$0")/.." && pwd)"
DIRECTIVE="$HERE/bin/lib/review-directive.md"
TICK="$HERE/bin/tick.sh"

FAIL=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi; }

[ -f "$DIRECTIVE" ] || { echo "test-review-directive: $DIRECTIVE missing"; exit 1; }

# Lift the real parser rather than reimplementing it -- a hand-rolled copy would
# happily agree with a directive that the shipping parser rejects.
PARSER_SRC=$(sed -n '/^review_parse_response() {$/,/^}$/p' "$TICK")
if [ -z "$PARSER_SRC" ]; then
  bad "could not extract review_parse_response() from bin/tick.sh"
else
  eval "$PARSER_SRC"
fi

echo "== the directive still specifies the handshake the parser looks for =="
if grep -q '^VERDICT: ' "$DIRECTIVE"; then
  ok "directive shows a VERDICT: line"
else bad "directive shows a VERDICT: line"; fi
if grep -q '^===BODY===$' "$DIRECTIVE"; then
  ok "directive shows the ===BODY=== sentinel"
else bad "directive shows the ===BODY=== sentinel"; fi

echo "== every verdict the directive advertises actually parses =="
# The tokens come out of the directive itself, so adding a fourth verdict to the
# rubric without teaching the parser fails here instead of in production.
read -r -a ADVERTISED <<<"$(sed -n 's/^VERDICT: //p' "$DIRECTIVE" | head -1 | tr '|' ' ')"
eq "the format line lists three tokens" "3" "${#ADVERTISED[@]}"
for v in "${ADVERTISED[@]}"; do
  if parsed=$(review_parse_response "VERDICT: ${v}
===BODY===
some review prose"); then
    eq "  $v round-trips" "$v" "$(printf '%s' "$parsed" | jq -r '.verdict')"
  else
    bad "  $v round-trips: parser REJECTED a verdict the directive advertises"
  fi
done

echo "== and the parser accepts nothing the directive doesn't advertise =="
for v in LGTM APPROVED REJECT BLOCK ""; do
  case " ${ADVERTISED[*]} " in *" $v "*) continue ;; esac
  if review_parse_response "VERDICT: ${v}
===BODY===
prose" >/dev/null 2>&1; then
    bad "  undocumented verdict '$v' was accepted"
  else
    ok "  undocumented verdict '${v:-<empty>}' is rejected"
  fi
done

echo "== a missing sentinel or empty body is rejected, not silently accepted =="
if review_parse_response "VERDICT: APPROVE
no sentinel here" >/dev/null 2>&1; then
  bad "missing ===BODY=== is rejected"
else ok "missing ===BODY=== is rejected"; fi
if review_parse_response "VERDICT: APPROVE
===BODY===
   " >/dev/null 2>&1; then
  bad "empty body is rejected"
else ok "empty body is rejected"; fi

echo "== the three verdicts are each documented in the rubric =="
# Guards the inverse of the round-trip: a token the parser accepts but the
# directive stopped explaining is a verdict the model will never deliberately pick.
#
# Scoped to the "## Verdict rubric" SECTION, not the whole file. Grepping the
# whole file passes on a rubric with the entry deleted, because the verdict
# names also appear in the header that explains what each one does -- verified
# by mutation, which is how this started out broken.
RUBRIC=$(awk '/^## Verdict rubric$/{f=1;next} /^## /{f=0} f' "$DIRECTIVE")
if [ -z "$RUBRIC" ]; then
  bad "could not locate the '## Verdict rubric' section"
else
  for v in APPROVE REQUEST_CHANGES COMMENT; do
    if printf '%s' "$RUBRIC" | grep -q -- "- \*\*${v}\*\* --"; then ok "  $v has a rubric entry"
    else bad "  $v has no rubric entry -- parser accepts a verdict the directive never explains"; fi
  done
fi

if [ "$FAIL" -eq 0 ]; then
  echo "test-review-directive: all checks passed"
else
  echo "test-review-directive: $FAIL FAILED"
  exit 1
fi
