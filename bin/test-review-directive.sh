#!/usr/bin/env bash
# test-review-directive.sh -- the review directive's machine contract must match
# what review_parse_response actually accepts.
#
# The directive text lives in the Distillery now (igor#486), but only ONE end of
# the handshake moved: review_parse_response is still in bin/tick.sh, and it
# still accepts exactly three tokens above a `===BODY===` sentinel. Edit either
# side without the other and every review becomes "no parseable verdict after 2
# attempts", which retries twice per tick, forever, and looks like a model
# failure rather than a text mismatch.
#
# So the checks split by what they can see. The parser half is in this repo and
# runs everywhere, CI included. The directive half is read through
# context_surface and needs a seeded cache, which only a real host has -- it
# skips cleanly elsewhere, per bin/check-sync.sh's skip-safe convention.
set -uo pipefail

# Skip-safe per bin/check-sync.sh's contract. Not a courtesy skip: the parser
# lifted below ENDS in `jq -n`, so without jq every round-trip fails on the
# missing tool and the suite reports a directive/parser mismatch that isn't
# there. That is exactly the false red this guard exists to prevent.
command -v jq >/dev/null 2>&1 || { echo "test-review-directive: jq absent -- skipping"; exit 0; }

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TICK="$HERE/bin/tick.sh"

FAIL=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi; }

# The tokens the SHIPPING parser accepts. Pinned here so the parser's own
# fail-closed behaviour is covered in CI, where no directive text is reachable.
ACCEPTED=(APPROVE REQUEST_CHANGES COMMENT)

# A verdict "has a rubric entry" means a line bolds the token AND carries more
# than the token itself -- MEANING, not layout. Deliberately blind to bullet
# vs numbered vs any other list style, and to whether the verdict sits at the
# front or the end of the line (distillery#31 moved it to the end). A line
# that is only the bolded token, with no explanation attached, still fails --
# that is a verdict left undocumented in every layout, not a documented one.
rubric_has_entry() {
  local rubric="$1" verdict="$2" line rest found=1
  while IFS= read -r line; do
    case "$line" in *"**${verdict}**"*) ;; *) continue ;; esac
    rest="${line//\*\*${verdict}\*\*/}"
    # Strip a leading list marker (bullet or number) so its digit/dash isn't
    # mistaken for explanatory content -- "1. **COMMENT**" must still fail.
    rest="$(printf '%s' "$rest" | sed -E 's/^[[:space:]]*([-*]|[0-9]+\.)?[[:space:]]*//')"
    if printf '%s' "$rest" | grep -qE '[A-Za-z0-9]'; then
      found=0
      break
    fi
  done <<<"$rubric"
  return "$found"
}

echo "== the rubric-entry check is meaning-based, not layout-based (fixtures) =="
# Regression coverage for the check ITSELF, independent of context_seeded --
# these run everywhere, CI included, so the check's own logic is proven
# without needing a live directive.

FIXTURE_NUMBERED='The verdict follows mechanically from the findings above:

1. Any `blocking` finding -> **REQUEST_CHANGES**.
2. Otherwise, if you could not actually evaluate the change (CI
   pending, ...) -> **COMMENT** (see routing below).
3. Otherwise -> **APPROVE**, with every note carried into the body.'
for v in "${ACCEPTED[@]}"; do
  if rubric_has_entry "$FIXTURE_NUMBERED" "$v"; then ok "  numbered fixture: $v has a rubric entry"
  else bad "  numbered fixture: $v has no rubric entry (distillery#31's format must pass)"; fi
done

FIXTURE_BULLETED='- **APPROVE**: no blocking findings, everything looks fine.
- **REQUEST_CHANGES**: at least one blocking finding.
- **COMMENT**: could not evaluate the change, or non-blocking notes only.'
for v in "${ACCEPTED[@]}"; do
  if rubric_has_entry "$FIXTURE_BULLETED" "$v"; then ok "  bulleted fixture: $v has a rubric entry"
  else bad "  bulleted fixture: $v has no rubric entry (the old format must not newly break)"; fi
done

FIXTURE_MISSING_COMMENT='1. Any blocking finding -> **REQUEST_CHANGES**.
2. Otherwise -> **APPROVE**.'
if rubric_has_entry "$FIXTURE_MISSING_COMMENT" "COMMENT"; then
  bad "  fixture omitting COMMENT was wrongly accepted"
else
  ok "  fixture omitting COMMENT is correctly rejected"
fi

FIXTURE_BARE_TOKENS='1. **APPROVE**
2. **REQUEST_CHANGES**
3. **COMMENT**'
for v in "${ACCEPTED[@]}"; do
  if rubric_has_entry "$FIXTURE_BARE_TOKENS" "$v"; then
    bad "  bare-token fixture: $v was wrongly accepted with no explanation attached"
  else
    ok "  bare-token fixture: $v is correctly rejected"
  fi
done

# Lift the real parser rather than reimplementing it -- a hand-rolled copy would
# happily agree with a directive that the shipping parser rejects.
PARSER_SRC=$(sed -n '/^review_parse_response() {$/,/^}$/p' "$TICK")
if [ -z "$PARSER_SRC" ]; then
  bad "could not extract review_parse_response() from bin/tick.sh"
else
  eval "$PARSER_SRC"
fi

# Lifting one function out of tick.sh assumes it calls no other tick.sh helper.
# If that ever stops being true the parser fails on an undefined command and
# every round-trip below reads as "the directive advertises a verdict the parser
# rejects" -- a true statement about the wrong thing. Name the dependency so the
# failure text points at the lift instead of at the directive.
LIFT_NOTE=""
_tick_fns=$(grep -oE '^[a-z_][a-z0-9_]*\(\) \{' "$TICK" | sed 's/() {$//' | grep -vx 'review_parse_response')
for _fn in $_tick_fns; do
  printf '%s' "$PARSER_SRC" | grep -qE "(^|[^a-z0-9_])${_fn}([^a-z0-9_]|$)" || continue
  declare -F "$_fn" >/dev/null 2>&1 && continue
  LIFT_NOTE="${LIFT_NOTE}${LIFT_NOTE:+, }$_fn"
done
[ -z "$LIFT_NOTE" ] || LIFT_NOTE=" (NOTE: the lifted parser calls undefined tick.sh helper(s): ${LIFT_NOTE} -- fix the lift, not the directive)"

echo "== the parser round-trips each verdict it is supposed to accept =="
for v in "${ACCEPTED[@]}"; do
  if parsed=$(review_parse_response "VERDICT: ${v}
===BODY===
some review prose"); then
    eq "  $v round-trips" "$v" "$(printf '%s' "$parsed" | jq -r '.verdict')"
  else
    bad "  $v round-trips: parser REJECTED it${LIFT_NOTE}"
  fi
done

echo "== and accepts nothing outside that set =="
for v in LGTM APPROVED REJECT BLOCK ""; do
  case " ${ACCEPTED[*]} " in *" $v "*) continue ;; esac
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

# -- the directive half ----------------------------------------------------
#
# Needs the Distillery cache. Unseeded (CI, a fresh clone) -> skip, same
# contract as the jq guard above: absent input is not a failing assertion.

# shellcheck source=../lib/context-source.sh
. "$HERE/lib/context-source.sh"

if ! context_seeded; then
  echo "== directive-side checks skipped: prompt cache unseeded (lib/context-source.sh) =="
  if [ "$FAIL" -eq 0 ]; then
    echo "test-review-directive: parser-side checks passed (directive side skipped)"
    exit 0
  fi
  echo "test-review-directive: $FAIL FAILED"
  exit 1
fi

DIRECTIVE=$(mktemp)
trap 'rm -f "$DIRECTIVE"' EXIT
if ! context_surface review-directive > "$DIRECTIVE" 2>/dev/null || [ ! -s "$DIRECTIVE" ]; then
  bad "the cache is seeded but 'review-directive' could not be served"
  echo "test-review-directive: $FAIL FAILED"
  exit 1
fi

echo "== the directive still specifies the handshake the parser looks for =="
if grep -q '^VERDICT: ' "$DIRECTIVE"; then
  ok "directive shows a VERDICT: line"
else bad "directive shows a VERDICT: line"; fi
if grep -q '^===BODY===$' "$DIRECTIVE"; then
  ok "directive shows the ===BODY=== sentinel"
else bad "directive shows the ===BODY=== sentinel"; fi

echo "== the directive advertises exactly the verdicts the parser accepts =="
# Adding a fourth verdict to the rubric without teaching the parser fails here
# instead of in production.
read -r -a ADVERTISED <<<"$(sed -n 's/^VERDICT: //p' "$DIRECTIVE" | head -1 | tr '|' ' ')"
# An empty array is not a soft failure: the comparison below would compare two
# empty strings and pass vacuously. (It also trips `${ADVERTISED[*]}` under
# `set -u` on bash < 4.4.) Stop here instead.
if [ "${#ADVERTISED[@]}" -eq 0 ]; then
  bad "the directive's VERDICT: format line did not parse -- every check below would pass vacuously"
  echo "test-review-directive: $FAIL FAILED"
  exit 1
fi
eq "advertised token set matches the parser's" "${ACCEPTED[*]}" "${ADVERTISED[*]}"

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
  # rubric_has_entry (defined above, fixture-tested) asserts MEANING -- a
  # bolded token with an explanation attached -- not list layout. Bullets,
  # numbers, verdict-first or verdict-last all pass; a bare bolded token
  # with nothing else on its line does not.
  for v in "${ACCEPTED[@]}"; do
    if rubric_has_entry "$RUBRIC" "$v"; then ok "  $v has a rubric entry"
    else bad "  $v has no rubric entry -- parser accepts a verdict the directive never explains"; fi
  done
fi

echo "== the directive tells the reviewer what a dismissal does (igor#456) =="
# lib/review.sh feeds a "## Findings the author already dismissed" section into
# the user turn. If the directive never mentions it, the block arrives
# unannounced and there is no rule for how it interacts with fail-closed --
# which is how a well-argued dismissal starts converting blocks into approvals.
if grep -q 'Findings the author already dismissed' "$DIRECTIVE"; then
  ok "the input list names the dismissals section"
else bad "the input list names the dismissals section"; fi
if grep -qi 'never, on its own, turns' "$DIRECTIVE"; then
  ok "and states a dismissal alone cannot upgrade a verdict"
else bad "and states a dismissal alone cannot upgrade a verdict"; fi
# The heading the directive advertises must be the one review.sh actually emits.
# Both sides are pinned NON-EMPTY first: comparing two greps that each found
# nothing passes vacuously, which is how this assertion started out useless.
DIR_H=$(grep -o 'Findings the author already dismissed' "$DIRECTIVE" | head -1)
REV_H=$(grep -o 'Findings the author already dismissed' "$HERE/lib/review.sh" | head -1)
if [ -n "$DIR_H" ]; then ok "the directive names the section heading"
else bad "the directive names the section heading"; fi
if [ -n "$REV_H" ]; then ok "lib/review.sh emits that heading"
else bad "lib/review.sh emits that heading"; fi
eq "directive and review.sh agree on the section heading" "$DIR_H" "$REV_H"

if [ "$FAIL" -eq 0 ]; then
  echo "test-review-directive: all checks passed"
else
  echo "test-review-directive: $FAIL FAILED"
  exit 1
fi
