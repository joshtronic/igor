#!/usr/bin/env bash
# test-context-skills-completeness.sh -- guards CONTEXT_SKILLS (and its
# documented complement, CONTEXT_SKILLS_UNSOURCED) against drifting from
# the Distillery's actual skills/ tree.
#
# Before igor#616, 8 of the Distillery's 15 skills were read by nothing
# and nobody had recorded that on purpose. This is the mechanism that
# makes a NEW skill landing on distillery master impossible to silently
# leave unconsumed: it must be added to CONTEXT_SKILLS (a real consumer
# wired it in) or CONTEXT_SKILLS_UNSOURCED (a documented, deliberate
# decline), or this test fails.
#
# Needs a real, reachable local clone of DISTILLERY_REPO at the
# conventional path (the same one lib/context-source.sh reads in
# production, _context_distillery_path with no override) -- a fresh
# checkout or CI container doesn't have one, so this is skip-safe, same
# as every other tool-gated test-*.sh in this suite.
set -uo pipefail

command -v git >/dev/null 2>&1 || { echo "test-context-skills-completeness: git absent -- skipping"; exit 0; }

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/context-source.sh
. "$HERE/../lib/context-source.sh"

DISTILLERY_PATH="$(_context_distillery_path)"
if [ ! -d "$DISTILLERY_PATH/.git" ]; then
  echo "test-context-skills-completeness: no readable distillery clone at $DISTILLERY_PATH -- skipping"
  exit 0
fi

REAL_SKILLS=$(git -C "$DISTILLERY_PATH" ls-tree -r --name-only origin/master -- skills 2>/dev/null \
  | grep -E '/SKILL\.md$' \
  | sed -E 's#^skills/([^/]+)/SKILL\.md$#\1#' \
  | sort -u)

if [ -z "$REAL_SKILLS" ]; then
  echo "test-context-skills-completeness: could not list skills/ on origin/master at $DISTILLERY_PATH -- skipping"
  exit 0
fi

FAIL=0

echo "== every skill on distillery origin/master is either consumed (CONTEXT_SKILLS) or explicitly declined (CONTEXT_SKILLS_UNSOURCED) =="
while IFS= read -r skill; do
  [ -z "$skill" ] && continue
  found=0
  for s in "${CONTEXT_SKILLS[@]}"; do [ "$s" = "$skill" ] && found=1 && break; done
  if [ "$found" -eq 0 ]; then
    for s in "${CONTEXT_SKILLS_UNSOURCED[@]}"; do [ "$s" = "$skill" ] && found=1 && break; done
  fi
  if [ "$found" -eq 1 ]; then
    printf '  + %s accounted for\n' "$skill"
  else
    printf '  x %s is on distillery master but neither consumed nor declined -- add it to CONTEXT_SKILLS or CONTEXT_SKILLS_UNSOURCED (lib/context-source.sh)\n' "$skill"
    FAIL=$((FAIL + 1))
  fi
done <<<"$REAL_SKILLS"

echo "== every name in CONTEXT_SKILLS resolves against distillery origin/master =="
for skill in "${CONTEXT_SKILLS[@]}"; do
  if printf '%s\n' "$REAL_SKILLS" | grep -qx -- "$skill"; then
    printf '  + %s\n' "$skill"
  else
    printf '  x %s is listed in CONTEXT_SKILLS but has no skills/%s/SKILL.md on distillery origin/master\n' "$skill" "$skill"
    FAIL=$((FAIL + 1))
  fi
done

echo "== every name in CONTEXT_SKILLS_UNSOURCED also resolves (a declined skill must still be a real one) =="
for skill in "${CONTEXT_SKILLS_UNSOURCED[@]}"; do
  if printf '%s\n' "$REAL_SKILLS" | grep -qx -- "$skill"; then
    printf '  + %s\n' "$skill"
  else
    printf '  x %s is listed in CONTEXT_SKILLS_UNSOURCED but has no skills/%s/SKILL.md on distillery origin/master\n' "$skill" "$skill"
    FAIL=$((FAIL + 1))
  fi
done

echo "== CONTEXT_SKILLS and CONTEXT_SKILLS_UNSOURCED don't overlap =="
for skill in "${CONTEXT_SKILLS[@]}"; do
  for u in "${CONTEXT_SKILLS_UNSOURCED[@]}"; do
    if [ "$skill" = "$u" ]; then
      printf '  x %s is in BOTH CONTEXT_SKILLS and CONTEXT_SKILLS_UNSOURCED\n' "$skill"
      FAIL=$((FAIL + 1))
    fi
  done
done

if [ "$FAIL" -eq 0 ]; then
  echo "test-context-skills-completeness: all passed"
else
  echo "test-context-skills-completeness: $FAIL failure(s)"
fi
exit "$FAIL"
