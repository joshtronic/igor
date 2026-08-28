#!/usr/bin/env bash
# test-context-source.sh -- unit tests for lib/context-source.sh: igor's
# last-good-cache sourcing of its prompt surfaces from the Distillery
# (DISTILLERY_REPO) at origin/master. No in-repo fallback -- the
# fallback IS the previously cached copy (igor#485).
#   context_skill_body -- reads skills/<skill>/SKILL.md at origin/master via
#                          `git show`, strips YAML frontmatter, echoes the body.
#   context_refresh     -- no-op if origin/master HEAD == cache stamp;
#                          otherwise extracts + validates every consumed
#                          skill and swaps ALL-OR-NOTHING into the cache.
#   context_surface     -- echoes a skill's cached body; nonzero only when
#                          the cache has never been seeded.
#   context_seeded / context_bootstrap_alert -- the bootstrap gate.
# Skip-safe: needs git, jq, sha256sum; exits 0 with a notice if any is absent.
set -uo pipefail

for _tool in git jq sha256sum; do
  command -v "$_tool" >/dev/null 2>&1 || { echo "test-context-source: $_tool absent -- skipping"; exit 0; }
done
unset _tool

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
# real per-tick clone context_refresh reads. write_skill/commit_and_push let
# each test advance origin/master to a fresh HEAD.
DISTILLERY_BARE="$TMPROOT/distillery.git"
git init -q --bare -b master "$DISTILLERY_BARE"
SEED="$TMPROOT/seed"
git init -q -b master "$SEED"
git -C "$SEED" config user.email t@t
git -C "$SEED" config user.name  t
git -C "$SEED" remote add origin "$DISTILLERY_BARE"

# A well-formed body: frontmatter + a 12-line body, one skill per line so
# a test can target a specific skill's fixture content.
write_good_skill() {
  local skill="$1" tag="${2:-$1}"
  mkdir -p "$SEED/skills/$skill"
  {
    printf -- '---\nname: %s\ndescription: fixture\n---\n\n' "$skill"
    for i in $(seq 1 12); do printf 'Line %d of %s.\n' "$i" "$tag"; done
  } > "$SEED/skills/$skill/SKILL.md"
}

write_malformed_skill() {
  local skill="$1"
  mkdir -p "$SEED/skills/$skill"
  printf 'just some prose, no frontmatter fence here\nsecond line\n' \
    > "$SEED/skills/$skill/SKILL.md"
}

write_short_skill() {
  local skill="$1"
  mkdir -p "$SEED/skills/$skill"
  printf -- '---\nname: %s\n---\n\nonly\nthree\nlines\n' "$skill" \
    > "$SEED/skills/$skill/SKILL.md"
}

# All 7 consumed skills well-formed by default -- individual tests
# override one at a time and re-commit to advance HEAD.
seed_all_good() {
  local skill
  for skill in "${CONTEXT_SKILLS[@]}"; do write_good_skill "$skill"; done
}

# write_manifest [exclude-skill] -- (re)generates dist/manifest.json from
# whatever's currently on disk under $SEED/skills, the same way `still
# build` records a sha256 per skill at build time. Pass a skill name to
# simulate that skill never having been built into the manifest at all
# (present on disk, absent from the recorded hashes). A test that wants a
# STALE manifest (mismatched hash) simply mutates a skill's file AFTER
# calling write_manifest, without calling it again.
write_manifest() {
  local exclude="${1:-}"
  mkdir -p "$SEED/dist"
  {
    printf '{\n  "skills": {\n'
    local skill first=1 sha
    for skill in "${CONTEXT_SKILLS[@]}"; do
      [ -n "$exclude" ] && [ "$skill" = "$exclude" ] && continue
      [ -f "$SEED/skills/$skill/SKILL.md" ] || continue
      sha=$(sha256sum "$SEED/skills/$skill/SKILL.md" | cut -d' ' -f1)
      [ "$first" -eq 1 ] || printf ',\n'
      first=0
      printf '    "%s": "%s"' "$skill" "$sha"
    done
    printf '\n  }\n}\n'
  } > "$SEED/dist/manifest.json"
}

commit_and_push() {
  git -C "$SEED" add -A
  git -C "$SEED" commit -q -m "fixture $(git -C "$SEED" rev-list --count HEAD 2>/dev/null || echo 0)"
  git -C "$SEED" push -q origin master
}

DISTILLERY_CLONE="$TMPROOT/distillery-clone"
seed_all_good
write_manifest
commit_and_push
git clone -q "$DISTILLERY_BARE" "$DISTILLERY_CLONE"

CACHE="$TMPROOT/cache"
export CONTEXT_DISTILLERY_PATH="$DISTILLERY_CLONE"
export CONTEXT_CACHE_DIR="$CACHE"

fetch_clone() { git -C "$DISTILLERY_CLONE" fetch -q origin master; }

echo "== context_skill_body: a well-formed skill extracts cleanly, frontmatter stripped exactly =="
BODY=$(context_skill_body worker-contract)
WANT=$'Line 1 of worker-contract.\nLine 2 of worker-contract.\nLine 3 of worker-contract.\nLine 4 of worker-contract.\nLine 5 of worker-contract.\nLine 6 of worker-contract.\nLine 7 of worker-contract.\nLine 8 of worker-contract.\nLine 9 of worker-contract.\nLine 10 of worker-contract.\nLine 11 of worker-contract.\nLine 12 of worker-contract.'
eq "frontmatter stripped exactly, body matches" "$WANT" "$BODY"
no "extracted body does not contain a frontmatter fence" bash -c "printf '%s' \"\$1\" | grep -qx -- '---'" _ "$BODY"

echo "== context_skill_body: missing skill fails =="
no "a skill with no SKILL.md on origin/master fails" context_skill_body does-not-exist

echo "== context_refresh: seeds the cache from a clean HEAD, all 7 skills present =="
ok "first refresh succeeds" context_refresh
FIRST_HEAD=$(git -C "$DISTILLERY_CLONE" rev-parse origin/master)
eq "cache stamp matches distillery HEAD" "$FIRST_HEAD" "$(cat "$CACHE/current/HEAD")"
MISSING=0
for skill in "${CONTEXT_SKILLS[@]}"; do
  [ -f "$CACHE/current/${skill}.md" ] || MISSING=$((MISSING + 1))
done
eq "every consumed skill cached" "0" "$MISSING"
eq "context_surface serves the cached (frontmatter-stripped) body" "$WANT" "$(context_surface worker-contract)"

echo "== context_refresh: HEAD unchanged -> no-op, no re-extract =="
GEN_BEFORE=$(readlink "$CACHE/current")
# If context_refresh re-extracted despite an unchanged HEAD, it would call
# context_skill_body again -- override it to fail loudly so a bug here
# shows up as a broken cache, not a silent pass.
context_skill_body() { echo "TEST BUG: re-extracted on an unchanged HEAD" >&2; return 1; }
ok "second refresh (same HEAD) still returns success" context_refresh
unset -f context_skill_body
. "$HERE/../lib/context-source.sh"   # restore the real context_skill_body
eq "current still points at the same generation (no swap happened)" "$GEN_BEFORE" "$(readlink "$CACHE/current")"

echo "== context_refresh: one malformed skill in a new HEAD -> ENTIRE swap refused, old cache intact =="
write_malformed_skill feedback-directive
commit_and_push
fetch_clone
OLD_WORKER_CONTRACT=$(cat "$CACHE/current/worker-contract.md")
WARN=$(context_refresh 2>&1 1>/dev/null); RC=$?
if [ "$RC" -ne 0 ]; then
  printf '  + %s\n' "refresh returns nonzero on a malformed skill"
else
  printf '  x %s\n' "refresh returns nonzero on a malformed skill"; FAIL=$((FAIL + 1))
fi
eq "cache stamp still the OLD (good) HEAD" "$FIRST_HEAD" "$(cat "$CACHE/current/HEAD")"
eq "an unrelated already-cached skill is untouched" "$OLD_WORKER_CONTRACT" "$(cat "$CACHE/current/worker-contract.md")"
if [ -f "$CACHE/current/feedback-directive.md" ]; then
  BAD_CONTENT=$(cat "$CACHE/current/feedback-directive.md")
  case "$BAD_CONTENT" in
    *"no frontmatter"*|*"just some prose"*)
      printf '  x %s\n' "feedback-directive cache poisoned by the refused swap" ; FAIL=$((FAIL + 1)) ;;
  esac
fi
if printf '%s' "$WARN" | grep -q 'context-source:.*refused'; then
  ok "  warns once, naming the refusal" true
else
  ok "  warns once, naming the refusal" false
fi
WARN2=$(context_refresh 2>&1 1>/dev/null)
eq "same bad HEAD again -> no repeat warn (deduped)" "" "$WARN2"

echo "== context_refresh: a too-short body (< 10 lines) in a new HEAD also refuses the whole swap =="
write_good_skill feedback-directive   # un-break the previous test's skill
write_short_skill now-directive
commit_and_push
fetch_clone
SHORT_WARN=$(context_refresh 2>&1 1>/dev/null)
eq "cache stamp still the OLD (good) HEAD" "$FIRST_HEAD" "$(cat "$CACHE/current/HEAD")"
if printf '%s' "$SHORT_WARN" | grep -q 'too short'; then
  ok "  warns naming the too-short skill" true
else
  ok "  warns naming the too-short skill" false
fi

echo "== context_refresh: a skill body mutated after 'still build' (manifest now stale) -> pour fails, current stays put =="
write_good_skill now-directive        # restore from the too-short test above
write_good_skill worker-contract "worker-contract-mutated"   # content changes; dist/manifest.json is NOT regenerated
commit_and_push
fetch_clone
MUT_WARN=$(context_refresh 2>&1 1>/dev/null); MUT_RC=$?
if [ "$MUT_RC" -ne 0 ]; then
  printf '  + %s\n' "refresh returns nonzero when a skill's sha256 no longer matches the manifest"
else
  printf '  x %s\n' "refresh returns nonzero when a skill's sha256 no longer matches the manifest"; FAIL=$((FAIL + 1))
fi
eq "cache stamp still the OLD (good) HEAD after a sha256 mismatch" "$FIRST_HEAD" "$(cat "$CACHE/current/HEAD")"
eq "current still serves the OLD worker-contract body, not the mutated one" "$WANT" "$(context_surface worker-contract)"
if printf '%s' "$MUT_WARN" | grep -q 'context-source:.*sha256'; then
  ok "  warns naming the sha256 mismatch" true
else
  ok "  warns naming the sha256 mismatch" false
fi

echo "== context_refresh: NEGATIVE -- with sha256 verification severed, the SAME mutated-body commit now PASSES (proves the gate causes the rejection above) =="
_context_verify_skill_sha256() { return 0; }
NEG_CACHE="$TMPROOT/neg-cache"
export CONTEXT_CACHE_DIR="$NEG_CACHE"
ok "with the gate stubbed out, the mutated commit swaps in cleanly" context_refresh
MUT_HEAD=$(git -C "$DISTILLERY_CLONE" rev-parse origin/master)
eq "the severed-gate cache advances to the mutated HEAD" "$MUT_HEAD" "$(cat "$NEG_CACHE/current/HEAD" 2>/dev/null)"
unset -f _context_verify_skill_sha256
. "$HERE/../lib/context-source.sh"   # restore the real sha256 gate
export CONTEXT_CACHE_DIR="$CACHE"

echo "== context_refresh: a skill present on disk but ABSENT from the manifest -> pour fails, not a pass =="
write_good_skill worker-contract      # restore worker-contract's original good content
write_manifest site-work-directive    # regenerate the manifest, omitting site-work-directive's entry
commit_and_push
fetch_clone
ABSENT_WARN=$(context_refresh 2>&1 1>/dev/null); ABSENT_RC=$?
if [ "$ABSENT_RC" -ne 0 ]; then
  printf '  + %s\n' "refresh returns nonzero when a skill on disk has no manifest entry"
else
  printf '  x %s\n' "refresh returns nonzero when a skill on disk has no manifest entry"; FAIL=$((FAIL + 1))
fi
eq "cache stamp still the OLD (good) HEAD" "$FIRST_HEAD" "$(cat "$CACHE/current/HEAD")"
if printf '%s' "$ABSENT_WARN" | grep -q 'missing from manifest'; then
  ok "  warns naming the manifest-absent skill" true
else
  ok "  warns naming the manifest-absent skill" false
fi

echo "== context_refresh: manifest missing entirely -> fails loudly, distinct log line =="
rm -f "$SEED/dist/manifest.json"
commit_and_push
fetch_clone
NOMANIFEST_WARN=$(context_refresh 2>&1 1>/dev/null); NOMANIFEST_RC=$?
if [ "$NOMANIFEST_RC" -ne 0 ]; then
  printf '  + %s\n' "refresh returns nonzero when dist/manifest.json is absent"
else
  printf '  x %s\n' "refresh returns nonzero when dist/manifest.json is absent"; FAIL=$((FAIL + 1))
fi
eq "cache stamp still the OLD (good) HEAD" "$FIRST_HEAD" "$(cat "$CACHE/current/HEAD")"
if printf '%s' "$NOMANIFEST_WARN" | grep -q 'context-source:.*manifest'; then
  ok "  warns loudly naming the missing manifest" true
else
  ok "  warns loudly naming the missing manifest" false
fi

echo "== context_refresh: manifest present but not valid JSON -> fails loudly =="
mkdir -p "$SEED/dist"
printf 'not { valid json at all\n' > "$SEED/dist/manifest.json"
commit_and_push
fetch_clone
BADJSON_WARN=$(context_refresh 2>&1 1>/dev/null); BADJSON_RC=$?
if [ "$BADJSON_RC" -ne 0 ]; then
  printf '  + %s\n' "refresh returns nonzero when dist/manifest.json is not valid JSON"
else
  printf '  x %s\n' "refresh returns nonzero when dist/manifest.json is not valid JSON"; FAIL=$((FAIL + 1))
fi
eq "cache stamp still the OLD (good) HEAD" "$FIRST_HEAD" "$(cat "$CACHE/current/HEAD")"
if printf '%s' "$BADJSON_WARN" | grep -q 'context-source:.*manifest'; then
  ok "  warns loudly naming the unparseable manifest" true
else
  ok "  warns loudly naming the unparseable manifest" false
fi
write_manifest   # restore a full, valid manifest for the tests below

echo "== context_refresh: clone missing -> fails open, last-good cache still serves =="
export CONTEXT_DISTILLERY_PATH="$TMPROOT/no-such-clone"
no "refresh fails when the clone is gone" context_refresh
export CONTEXT_DISTILLERY_PATH="$DISTILLERY_CLONE"
eq "context_surface still serves the last-good cached body" "$WANT" "$(context_surface worker-contract)"
ok "context_seeded is still true (a prior good cache exists)" context_seeded

echo "== atomicity: current is a symlink into a single, complete generation =="
if [ -L "$CACHE/current" ]; then
  printf '  + %s\n' "current is a symlink (atomic-rename target)"
else
  printf '  x %s\n' "current is a symlink (atomic-rename target)"; FAIL=$((FAIL + 1))
fi
ok "no leftover current.tmp after a swap" bash -c '[ ! -e "$1" ]' _ "$CACHE/current.tmp"
STRAY=$(find "$CACHE" -maxdepth 1 -type d -name '.gen-*' ! -name "$(basename "$(readlink "$CACHE/current")")" | wc -l)
eq "no orphaned generation directories left behind" "0" "$STRAY"

echo "== unseeded cache + failed refresh -> surfaces refuse, loudly =="
export CONTEXT_CACHE_DIR="$TMPROOT/fresh-cache"
export CONTEXT_DISTILLERY_PATH="$TMPROOT/also-no-such-clone"
no "refresh fails against an unreachable clone" context_refresh
no "context_seeded is false -- never seeded" context_seeded
no "context_surface refuses to serve any skill" context_surface worker-contract
# Explicitly unconfigured, regardless of the ambient environment (a real
# host has real SMTP2GO/recipient env vars) -- the alert must degrade to
# a log line, never crash, and never actually attempt a send in a test.
ALERT_OUT=$(unset SMTP2GO_API_KEY SMTP2GO_SENDER PRIMARY_RECIPIENTS ALERT_RECIPIENTS; context_bootstrap_alert 2>&1)
if printf '%s' "$ALERT_OUT" | grep -q 'never seeded'; then
  printf '  + %s\n' "context_bootstrap_alert logs the loud path when email is unconfigured"
else
  printf '  x %s\n' "context_bootstrap_alert logs the loud path when email is unconfigured"; FAIL=$((FAIL + 1))
fi
export CONTEXT_CACHE_DIR="$CACHE"
export CONTEXT_DISTILLERY_PATH="$DISTILLERY_CLONE"

unset CONTEXT_DISTILLERY_PATH CONTEXT_CACHE_DIR

# -- wiring: at least one real consuming call site per surface routes
#    through context_surface (identified by its skill-name content marker,
#    not a line number, so an unrelated reflow can't silently break this).
fn_src() { sed -n "/^$1() {\$/,/^}\$/p" "$2"; }

echo "== wiring: bin/tick.sh's issue_system_prompt routes through context_surface =="
TICK="$HERE/tick.sh"
FN_SRC=$(fn_src issue_system_prompt "$TICK")
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

echo "== wiring: bin/tick.sh's do_review_tick and do_sports_tick route through context_surface =="
if grep -q 'context_surface review-directive' "$TICK"; then
  ok "do_review_tick sources review-directive via context_surface" true
else
  ok "do_review_tick sources review-directive via context_surface" false
fi
if grep -q 'context_surface sports-digest-directive' "$TICK"; then
  ok "do_sports_tick sources sports-digest-directive via context_surface" true
else
  ok "do_sports_tick sources sports-digest-directive via context_surface" false
fi

echo "== wiring: bin/site-work-block.sh routes voice + directive through context_surface =="
SWB="$HERE/site-work-block.sh"
if grep -q 'VOICE_BODY=\$(context_surface voice)' "$SWB"; then
  ok "site-work-block sources the voice anchor via context_surface" true
else
  ok "site-work-block sources the voice anchor via context_surface" false
fi
if grep -q 'DIRECTIVE_BODY=\$(context_surface "\${DIRECTIVE}-directive")' "$SWB"; then
  ok "site-work-block sources its directive via context_surface" true
else
  ok "site-work-block sources its directive via context_surface" false
fi

echo "== wiring: lib/feedback.sh's do_feedback_tick routes through context_surface =="
if grep -q 'context_surface feedback-directive' "$HERE/../lib/feedback.sh"; then
  ok "do_feedback_tick sources feedback-directive via context_surface" true
else
  ok "do_feedback_tick sources feedback-directive via context_surface" false
fi

if [ "$FAIL" -eq 0 ]; then
  echo "test-context-source: all passed"
else
  echo "test-context-source: $FAIL failure(s)"
fi
exit "$FAIL"
