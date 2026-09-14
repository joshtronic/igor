#!/usr/bin/env bash
# test-skill-accounting.sh -- CI TEST, not a runtime gate (igor#621): every
# skill on the distillery's skills/ tree must be either consumed
# (CONTEXT_SKILLS) or deliberately declined (CONTEXT_SKILLS_UNSOURCED),
# both declared in lib/context-source.sh. A skill that lands on distillery
# master and reaches neither list is drift nobody has looked at -- that's
# how six (going on seven) accumulated unnoticed.
#
# Explicitly NOT wired into bin/tick.sh: drift is a thing for a human to
# see, not a correctness condition worth halting the harness over. This
# suite is the whole mechanism -- context_unaccounted_skills is pure and
# read-only, with no runtime call site.
#
#   1. context_unaccounted_skills against a synthetic fixture tree --
#      proves listing, excluding, and neither behave as documented.
#   2. context_unaccounted_skills against the REAL distillery clone, if
#      one is reachable on disk -- the actual drift check. Skip-safe: no
#      local clone must never turn into a red build.
set -uo pipefail

for _tool in git sed sort; do
  command -v "$_tool" >/dev/null 2>&1 || { echo "test-skill-accounting: $_tool absent -- skipping"; exit 0; }
done
unset _tool

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/context-source.sh
. "$HERE/../lib/context-source.sh"

FAIL=0
eq() { local d="$1" want="$2" got="$3"; if [ "$want" = "$got" ]; then printf '  + %s\n' "$d"; else printf '  x %s (want %q got %q)\n' "$d" "$want" "$got"; FAIL=$((FAIL + 1)); fi; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

echo "== context_unaccounted_skills: fixture distillery tree =="

# A real fetched clone at origin/master, same shape context_unaccounted_skills
# reads in production (bin/test-context-source.sh builds its fixtures the
# same way): bare repo + push, so `git ls-tree origin/master` behaves
# exactly like the per-tick clone this reads.
DISTILLERY_BARE="$TMPROOT/distillery.git"
git init -q --bare -b master "$DISTILLERY_BARE"
SEED="$TMPROOT/seed"
git init -q -b master "$SEED"
git -C "$SEED" config user.email t@t
git -C "$SEED" config user.name  t
git -C "$SEED" remote add origin "$DISTILLERY_BARE"

write_skill_stub() {
  mkdir -p "$SEED/skills/$1"
  printf -- '---\nname: %s\n---\n\nstub\n' "$1" > "$SEED/skills/$1/SKILL.md"
}

write_skill_stub listed-skill
write_skill_stub excluded-skill
write_skill_stub unaccounted-skill
git -C "$SEED" add -A
git -C "$SEED" commit -q -m fixture
git -C "$SEED" push -q origin master

FIXTURE_CLONE="$TMPROOT/distillery-clone"
git clone -q "$DISTILLERY_BARE" "$FIXTURE_CLONE"

export CONTEXT_DISTILLERY_PATH="$FIXTURE_CLONE"

# shellcheck disable=SC2034  # read by context_unaccounted_skills (sourced lib)
CONTEXT_SKILLS=(listed-skill)
# shellcheck disable=SC2034  # read by context_unaccounted_skills (sourced lib)
CONTEXT_SKILLS_UNSOURCED=(excluded-skill)   # stands in for a deliberate-omission comment
eq "an unlisted, unexcluded skill is reported as drift" "unaccounted-skill" "$(context_unaccounted_skills)"

# shellcheck disable=SC2034  # read by context_unaccounted_skills (sourced lib)
CONTEXT_SKILLS=(listed-skill unaccounted-skill)
eq "listing it clears the drift" "" "$(context_unaccounted_skills)"

# shellcheck disable=SC2034  # read by context_unaccounted_skills (sourced lib)
CONTEXT_SKILLS=(listed-skill)
# shellcheck disable=SC2034  # read by context_unaccounted_skills (sourced lib)
CONTEXT_SKILLS_UNSOURCED=(excluded-skill unaccounted-skill)
eq "excluding it (with a comment) also clears the drift" "" "$(context_unaccounted_skills)"

echo "== context_unaccounted_skills: no distillery clone reachable -> fails open, reports nothing =="
export CONTEXT_DISTILLERY_PATH="$TMPROOT/no-such-clone"
eq "no clone -> nothing reported" "" "$(context_unaccounted_skills)"

unset CONTEXT_DISTILLERY_PATH

# Restore the real declarations for the check below -- the fixture
# assertions above reassigned CONTEXT_SKILLS / CONTEXT_SKILLS_UNSOURCED as
# plain bash globals.
. "$HERE/../lib/context-source.sh"

echo "== context_unaccounted_skills: the REAL distillery clone, if one is reachable =="
REAL_PATH="$(_context_distillery_path)"
# The ref, not just the .git dir: context_unaccounted_skills fails OPEN, so a
# clone that exists but can't answer `ls-tree origin/master` (never fetched,
# corrupt objects) would otherwise report no drift and print a pass it never
# actually earned. Unreadable ref -> the skip message owns it.
if git -C "$REAL_PATH" rev-parse --verify -q origin/master >/dev/null 2>&1; then
  REAL_DRIFT=$(context_unaccounted_skills)
  if [ -z "$REAL_DRIFT" ]; then
    printf '  + %s\n' "every skill on distillery master is consumed or declined"
  else
    printf '  x %s\n' "unaccounted distillery skill(s): $(printf '%s' "$REAL_DRIFT" | tr '\n' ' ')"
    printf '      -- add to CONTEXT_SKILLS (wire it in) or CONTEXT_SKILLS_UNSOURCED (lib/context-source.sh) with a reason\n'
    FAIL=$((FAIL + 1))
  fi
else
  echo "  (no readable distillery clone at $REAL_PATH -- skipping the real check)"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "test-skill-accounting: all passed"
else
  echo "test-skill-accounting: $FAIL failure(s)"
fi
exit "$FAIL"
