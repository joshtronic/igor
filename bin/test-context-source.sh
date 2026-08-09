#!/usr/bin/env bash
# test-context-source.sh -- unit tests for lib/context-source.sh: sourcing
# igor's prompt surfaces from the Distillery (joshtronic/distillery) at
# origin/master, fail-open to the in-repo fallback copy on any problem.
#   context_skill_body -- reads skills/<skill>/SKILL.md at origin/master via
#                          `git show`, strips YAML frontmatter, echoes the body.
#   context_surface    -- context_skill_body when it succeeds AND is >= 10
#                          lines; otherwise the fallback file + one warn line.
# Skip-safe: needs git; exits 0 with a notice if absent.
set -uo pipefail

command -v git >/dev/null 2>&1 || { echo "test-context-source: git absent -- skipping"; exit 0; }

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/context-source.sh
. "$HERE/../lib/context-source.sh"

FAIL=0
ok() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then printf '  + %s\n' "$d"; else printf '  x %s (rc0 expected)\n' "$d"; FAIL=$((FAIL + 1)); fi; }
no() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then printf '  x %s (rc!=0 expected)\n' "$d"; FAIL=$((FAIL + 1)); else printf '  + %s\n' "$d"; fi; }
eq() { local d="$1" want="$2" got="$3"; if [ "$want" = "$got" ]; then printf '  + %s\n' "$d"; else printf '  x %s (want %q got %q)\n' "$d" "$want" "$got"; FAIL=$((FAIL + 1)); fi; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# -- fixture distillery clone ------------------------------------
#
# A real fetched clone at origin/master, built the same way
# bin/test-repo-checks.sh builds fixture clones for rc_local_init: bare repo
# + push + clone, so `git show origin/master:...` behaves exactly like the
# real per-tick validation sweep's clone.
DISTILLERY_BARE="$TMPROOT/distillery.git"
git init -q --bare -b master "$DISTILLERY_BARE"
SEED="$TMPROOT/seed"
mkdir -p "$SEED/skills/worker-contract" "$SEED/skills/malformed-skill" "$SEED/skills/short-skill"
git init -q -b master "$SEED"
git -C "$SEED" config user.email t@t
git -C "$SEED" config user.name  t

# A well-formed skill: frontmatter + a 12-line body.
GOOD_BODY=$'Line 1 of the worker contract.\nLine 2.\nLine 3.\nLine 4.\nLine 5.\nLine 6.\nLine 7.\nLine 8.\nLine 9.\nLine 10.\nLine 11.\nLine 12.'
printf -- '---\nname: worker-contract\ndescription: how the worker behaves\n---\n\n%s\n' "$GOOD_BODY" \
  >"$SEED/skills/worker-contract/SKILL.md"

# A malformed skill: no frontmatter at all.
printf 'just some prose, no frontmatter fence here\nsecond line\n' \
  >"$SEED/skills/malformed-skill/SKILL.md"

# A well-formed but too-short skill: frontmatter + a 3-line body (< 10).
printf -- '---\nname: short-skill\n---\n\nonly\nthree\nlines\n' \
  >"$SEED/skills/short-skill/SKILL.md"

git -C "$SEED" add -A
git -C "$SEED" commit -q -m fixture
git -C "$SEED" remote add origin "$DISTILLERY_BARE"
git -C "$SEED" push -q origin master
DISTILLERY_CLONE="$TMPROOT/distillery-clone"
git clone -q "$DISTILLERY_BARE" "$DISTILLERY_CLONE"

export CONTEXT_DISTILLERY_PATH="$DISTILLERY_CLONE"

# -- fallback file -------------------------------------------------
FALLBACK="$TMPROOT/fallback.md"
printf 'this is the in-repo fallback copy\nit has its own content\n' >"$FALLBACK"

echo "== context_skill_body: a well-formed skill extracts cleanly =="
BODY=$(context_skill_body worker-contract)
eq "frontmatter stripped exactly, body matches" "$GOOD_BODY" "$BODY"
FIRST_LINE=$(printf '%s\n' "$BODY" | head -n1)
eq "no leading blank line" "Line 1 of the worker contract." "$FIRST_LINE"
no "extracted body does not contain a frontmatter fence" bash -c "printf '%s' \"\$1\" | grep -qx -- '---'" _ "$BODY"

echo "== context_skill_body: missing skill fails =="
no "a skill with no SKILL.md on origin/master fails" context_skill_body does-not-exist

echo "== context_skill_body: no frontmatter fails =="
no "a SKILL.md with no frontmatter fence fails" context_skill_body malformed-skill

echo "== context_skill_body: missing clone fails =="
CONTEXT_DISTILLERY_PATH="$TMPROOT/no-such-clone" \
  no "no readable clone at all fails" context_skill_body worker-contract

echo "== context_surface: well-formed + long-enough skill wins over fallback =="
OUT=$(context_surface worker-contract "$FALLBACK" 2>/dev/null)
eq "surface returns the distillery body, not the fallback" "$GOOD_BODY" "$OUT"

echo "== context_surface: missing skill falls back + warns =="
WARN=$(context_surface does-not-exist "$FALLBACK" 2>&1 1>/dev/null)
OUT=$(context_surface does-not-exist "$FALLBACK" 2>/dev/null)
eq "falls back to the fallback file's content" "$(cat "$FALLBACK")" "$OUT"
if printf '%s' "$WARN" | grep -q 'context-source: does-not-exist fell back --'; then
  ok "  warns naming the skill and a reason" true
else
  ok "  warns naming the skill and a reason" false
fi
WARN_LINES=$(printf '%s\n' "$WARN" | grep -c 'context-source: does-not-exist fell back --')
eq "exactly one warn line" "1" "$WARN_LINES"

echo "== context_surface: malformed skill (no frontmatter) falls back + warns =="
OUT=$(context_surface malformed-skill "$FALLBACK" 2>/dev/null)
eq "falls back to the fallback file's content" "$(cat "$FALLBACK")" "$OUT"
WARN=$(context_surface malformed-skill "$FALLBACK" 2>&1 1>/dev/null)
if printf '%s' "$WARN" | grep -q 'context-source: malformed-skill fell back --'; then
  ok "  warns naming the skill and a reason" true
else
  ok "  warns naming the skill and a reason" false
fi

echo "== context_surface: body-too-short (< 10 lines) falls back + warns =="
OUT=$(context_surface short-skill "$FALLBACK" 2>/dev/null)
eq "falls back to the fallback file's content" "$(cat "$FALLBACK")" "$OUT"
WARN=$(context_surface short-skill "$FALLBACK" 2>&1 1>/dev/null)
if printf '%s' "$WARN" | grep -q 'context-source: short-skill fell back --'; then
  ok "  warns naming the skill and a reason" true
else
  ok "  warns naming the skill and a reason" false
fi

echo "== context_surface: distillery outage (clone renamed away) falls back cleanly for every surface =="
CONTEXT_DISTILLERY_PATH="$TMPROOT/renamed-away"
OUT=$(CONTEXT_DISTILLERY_PATH="$TMPROOT/renamed-away" context_surface worker-contract "$FALLBACK" 2>/dev/null)
eq "falls back to the fallback file's content" "$(cat "$FALLBACK")" "$OUT"

unset CONTEXT_DISTILLERY_PATH

echo "== context_surface: a fallback does not abort a caller running under 'set -e' =="
# bin/tick.sh runs under `set -euo pipefail`. context_skill_body's ordinary
# failure (skill absent, no frontmatter, etc.) happens via a bare
# `var=$(...)` assignment inside context_surface -- unguarded, that trips
# errexit and kills the WHOLE tick the first time a skill lookup misses,
# which is the opposite of fail-open. Run the fallback path in a fresh
# `set -e` subshell and confirm it completes instead of aborting silently.
SETE_OUT=$(
  set -e
  . "$HERE/../lib/context-source.sh"
  CONTEXT_DISTILLERY_PATH="$TMPROOT/no-such-clone"
  context_surface does-not-exist "$FALLBACK" 2>/dev/null
  echo "REACHED_AFTER_FALLBACK"
)
if printf '%s' "$SETE_OUT" | grep -q 'REACHED_AFTER_FALLBACK'; then
  ok "caller reaches the line after context_surface under set -e" true
else
  ok "caller reaches the line after context_surface under set -e" false
fi

# -- wiring: at least one real consuming call site routes through
#    context_surface (identified by its skill-name content marker, not a
#    line number, so an unrelated reflow of the surrounding code can't
#    silently break this).
echo "== wiring: bin/tick.sh's issue_system_prompt routes through context_surface =="
TICK="$HERE/tick.sh"
FN_SRC=$(sed -n '/^issue_system_prompt() {$/,/^}$/p' "$TICK")
if [ -z "$FN_SRC" ]; then
  ok "could not extract issue_system_prompt() from bin/tick.sh" false
else
  if printf '%s' "$FN_SRC" | grep -q 'context_surface[[:space:]]\+voice\b'; then
    ok "issue_system_prompt sources the voice anchor via context_surface" true
  else
    ok "issue_system_prompt sources the voice anchor via context_surface" false
  fi
  if printf '%s' "$FN_SRC" | grep -q 'context_surface[[:space:]]\+worker-contract\b'; then
    ok "issue_system_prompt sources the worker contract via context_surface" true
  else
    ok "issue_system_prompt sources the worker contract via context_surface" false
  fi
fi

if [ "$FAIL" -eq 0 ]; then
  echo "test-context-source: all passed"
else
  echo "test-context-source: $FAIL failure(s)"
fi
exit "$FAIL"
