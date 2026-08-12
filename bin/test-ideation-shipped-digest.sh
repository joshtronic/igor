#!/usr/bin/env bash
# test-ideation-shipped-digest.sh -- unit tests for bin/ideation-pipeline.sh's
# read-the-ref-never-the-checkout fix (igor#507).
#
# Root cause: the ideation pipeline's website clone sits DETACHED at the
# PREVIOUS run's end state (push_and_open_pr's cleanup checkout), so any
# helper that reads posts off the WORKING TREE is always exactly one publish
# behind -- it can never see the post that shipped most recently, which is
# precisely the one most likely to get re-covered (igor#377 duplicated the
# 2026-08-11 post because of this).
#
# The fix moved every website-repo read onto `git ls-tree`/`git show` against
# the fetched origin/master ref (website_post_paths / website_show /
# post_slug_exists), same pattern as lib/context-source.sh and rc_local_init.
# These tests build a real fixture clone whose working tree is deliberately
# checked out one commit BEHIND origin/master (mirroring the bug) and assert
# that shipped_digest, recent_post_territory_tokens, posts_cited_sources,
# broken_internal_links, post_slug_exists, and the today-post guard
# (post_done_today) all still see the newest post.
#
# The conversion swapped `[ -f "$f" ] || continue` guards for command
# substitutions of git, which changes EXIT STATUSES, so the last two blocks
# pin the degradation paths: an absent file and an unresolvable origin/master
# must come back empty with status 0, never abort mid-pipeline. The `set -`
# line below deliberately MATCHES bin/ideation-pipeline.sh's own (`-uo
# pipefail`, no `-e`) so those statuses are exercised under the same options
# the real script runs with.
#
# Functions are lifted straight out of bin/ideation-pipeline.sh (sed range
# extraction, same technique bin/test-cascade.sh uses for cascade_run) rather
# than sourced, since the script has top-level side-effecting code (env
# guards, brain_init, context_seeded) that a plain `.` would trip over.
# Skip-safe: needs git; exits 0 with a notice if absent.
set -uo pipefail

command -v git >/dev/null 2>&1 || { echo "test-ideation-shipped-digest: git absent -- skipping"; exit 0; }

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/ideation-pipeline.sh"

FAIL=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; FAIL=$((FAIL + 1)); }
eq()  { local d="$1" want="$2" got="$3"; if [ "$want" = "$got" ]; then ok "$d"; else bad "$d (want $(printf '%q' "$want") got $(printf '%q' "$got"))"; fi; }
contains() { local d="$1" needle="$2" haystack="$3"; case "$haystack" in *"$needle"*) ok "$d" ;; *) bad "$d (expected to find $(printf '%q' "$needle"))" ;; esac; }
not_contains() { local d="$1" needle="$2" haystack="$3"; case "$haystack" in *"$needle"*) bad "$d (did not expect to find $(printf '%q' "$needle"))" ;; *) ok "$d" ;; esac; }

lift() {
  local fn="$1" src
  src=$(sed -n "/^${fn}() {\$/,/^}\$/p" "$SCRIPT")
  [ -z "$src" ] && { bad "could not extract ${fn}() from bin/ideation-pipeline.sh"; return 1; }
  eval "$src"
}

for fn in website_post_paths website_show post_slug_exists website_ref_ok \
          shipped_digest recent_post_territory_tokens posts_cited_sources \
          recent_post_bodies links_roster broken_internal_links post_done_today; do
  lift "$fn" || exit 1
done

log() { :; }  # the real log() writes to stderr; silence it for the tests

# Constants the eval'd functions read as globals -- shellcheck can't see
# through eval, so these read as unused without the disables.
# shellcheck disable=SC2034
SHIPPED_RECENT=40
# shellcheck disable=SC2034
SHIPPED_SAMPLE=20
# shellcheck disable=SC2034
VOICE_NOTES_RECENT_POSTS=5
# shellcheck disable=SC2034
VOICE_NOTES_MAX_POSTS_BYTES=120000

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# -- fixture website clone -----------------------------------------
#
# A real bare-repo + push + clone, so `git ls-tree`/`git show` against
# origin/master behaves exactly like the real per-tick clone. WEBSITE_PATH
# is the clone the functions under test read; its working tree is left
# checked out one commit BEHIND origin/master, mirroring the bug.

BARE="$TMPROOT/website.git"
git init -q --bare -b master "$BARE"
SEED="$TMPROOT/seed"
git init -q -b master "$SEED"
git -C "$SEED" config user.email t@t
git -C "$SEED" config user.name  t
git -C "$SEED" remote add origin "$BARE"

write_post() {
  local ymd="$1" slug="$2" title="$3" tags="$4" url="${5:-}"
  local year="${ymd%%-*}" dir file
  dir="$SEED/src/posts/$year"
  mkdir -p "$dir"
  file="$dir/${ymd}-${slug}.md"
  {
    printf -- '---\n'
    printf 'title: "%s"\n' "$title"
    printf 'description: "desc for %s"\n' "$slug"
    printf 'tags: %s\n' "$tags"
    printf -- '---\n\n'
    printf 'Body of %s.\n' "$slug"
    [ -n "$url" ] && printf '\nSee [a source](%s).\n' "$url"
  } > "$file"
}

mkdir -p "$SEED/src"
printf '# Links\n\n[Example](https://example.com/about)\n' > "$SEED/src/links.md"
write_post "2026-08-10" "an-older-post" "An Older Post" '["tech"]'
git -C "$SEED" add -A
git -C "$SEED" commit -q -m "seed"
git -C "$SEED" push -q origin master

CLONE="$TMPROOT/clone"
git clone -q "$BARE" "$CLONE"
# shellcheck disable=SC2034  # read by the eval'd functions above
WEBSITE_PATH="$CLONE"

# Detach the clone at the pre-newest-post commit -- exactly what
# push_and_open_pr's cleanup checkout leaves behind at the end of a run.
git -C "$CLONE" checkout -q --detach origin/master

# Now advance origin/master past the clone's checkout: a second post ships
# (from the SEED side, standing in for another process/run), simulating
# "last night's" merge that the stale clone never saw.
write_post "2026-08-11" "the-interview-doesnt-end" "The Interview Doesn't End" \
  '["ai", "identity"]' "https://example.com/interview"
git -C "$SEED" add -A
git -C "$SEED" commit -q -m "ship newest post"
git -C "$SEED" push -q origin master

# Mirror main's up-front fetch (the fix): the clone's origin/master ref is
# now current, but its WORKING TREE is still detached at the older commit.
git -C "$CLONE" fetch -q origin master

WORKING_TREE_FILES=$(find "$CLONE/src/posts" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')

echo "== sanity: the working tree really is stale (the bug's precondition) =="
eq "working tree sees only the seed post" "1" "$WORKING_TREE_FILES"

echo "== website_post_paths reads the ref, not the stale checkout =="
PATHS=$(website_post_paths)
contains   "includes the newest post (ref)" "the-interview-doesnt-end.md" "$PATHS"
contains   "includes the older post too"    "an-older-post.md" "$PATHS"
eq "exactly 2 posts on the ref" "2" "$(printf '%s\n' "$PATHS" | grep -c .)"

echo "== website_show reads file content at the ref =="
CONTENT=$(website_show "src/posts/2026/2026-08-11-the-interview-doesnt-end.md")
contains "shows the newest post's title" "The Interview Doesn't End" "$CONTENT"

echo "== post_slug_exists sees the newest post despite the stale checkout =="
if post_slug_exists "the-interview-doesnt-end"; then ok "newest slug found"; else bad "newest slug found"; fi
if post_slug_exists "an-older-post"; then ok "older slug found"; else bad "older slug found"; fi
if post_slug_exists "no-such-post"; then bad "nonexistent slug not found"; else ok "nonexistent slug not found"; fi

echo "== shipped_digest (the dedup signal itself) includes the newest post =="
DIGEST=$(shipped_digest)
contains "digest mentions the newest post's title" "The Interview Doesn't End" "$DIGEST"
contains "digest mentions the older post's title"  "An Older Post" "$DIGEST"

echo "== recent_post_territory_tokens picks up the newest post's tags =="
TOKENS=$(recent_post_territory_tokens)
contains "tokens include the newest post's tag" "identity" "$TOKENS"

echo "== posts_cited_sources includes the newest post's link =="
SOURCES=$(posts_cited_sources)
contains "cited sources include the newest post's URL" "https://example.com/interview" "$SOURCES"

echo "== broken_internal_links resolves a link to the newest post =="
BAD=$(broken_internal_links 'See [it](/posts/the-interview-doesnt-end) for more.')
eq "no false positive on the newest post's slug" "" "$BAD"
BAD2=$(broken_internal_links 'See [it](/posts/totally-made-up-slug) for more.')
contains "a genuinely fabricated slug is still caught" "totally-made-up-slug" "$BAD2"

echo "== recent_post_bodies includes the newest post's body =="
BODIES=$(recent_post_bodies)
contains "recent bodies include the newest post" "Body of the-interview-doesnt-end" "$BODIES"

echo "== links_roster reads src/links.md off the ref =="
printf '# Links\n\n[Fresh Source](https://example.com/fresh)\n' > "$SEED/src/links.md"
git -C "$SEED" add -A
git -C "$SEED" commit -q -m "update links roster"
git -C "$SEED" push -q origin master
git -C "$CLONE" fetch -q origin master
ROSTER=$(links_roster)
contains "roster reflects the ref, not the stale checkout" "Fresh Source" "$ROSTER"

# -- the today-post guard ------------------------------------------
#
# post_done_today is the daily refrain: miss the post that shipped today and
# the pass drafts a second one. It already read origin/master before this
# fix, but it is the guard whose failure double-posts, so pin it against the
# same stale-tree fixture (igor#507's Tests section asks for exactly this).
# The fixture's newest post is dated 2026-08-11, so that is "today" here.

echo "== the today-post guard sees today's post through the stale checkout =="
# shellcheck disable=SC2034  # read by the eval'd post_done_today
WEBSITE_REPO="fixture/website"
# shellcheck disable=SC2034
BOT_USER="igor"
forgejo_list_open_bot_prs() { printf '[]\n'; }
forgejo_pr_files() { printf '[]\n'; }

TODAY_POST_RE='^src/posts/[0-9]{4}/2026-08-11-.+\.md$'
if post_done_today; then ok "guard sees the post that shipped on the ref"; else bad "guard sees the post that shipped on the ref"; fi

# shellcheck disable=SC2034  # read by the eval'd post_done_today
TODAY_POST_RE='^src/posts/[0-9]{4}/2026-08-12-.+\.md$'
if command -v jq >/dev/null 2>&1; then
  if post_done_today; then bad "guard reports no post on a day with none"; else ok "guard reports no post on a day with none"; fi
else
  echo "  . jq absent -- skipping the no-post-today case (its fallback path needs jq)"
fi

# -- degradation paths ---------------------------------------------
#
# Absent inputs must degrade to empty, not abort. `git show` exits 128 on a
# path that is not in the ref and `website_post_paths`' grep exits 1 on an
# empty post set, so these pin that the callers still hand back empty with
# status 0 (the behavior the old `[ -f ... ] || return 0` guards gave).

echo "== an absent file degrades to empty, status 0 =="
git -C "$SEED" rm -q src/links.md
git -C "$SEED" commit -q -m "drop the links roster"
git -C "$SEED" push -q origin master
git -C "$CLONE" fetch -q origin master
ROSTER_GONE=$(links_roster); RC=$?
eq "links_roster is empty when src/links.md is not in the ref" "" "$ROSTER_GONE"
eq "links_roster still exits 0" "0" "$RC"

echo "== an unresolvable origin/master degrades to empty, and website_ref_ok catches it =="
if website_ref_ok; then ok "website_ref_ok accepts the fetched clone"; else bad "website_ref_ok accepts the fetched clone"; fi

NOREF="$TMPROOT/noref"
git init -q "$NOREF"
WEBSITE_PATH="$NOREF"
eq "website_post_paths is empty with no origin/master" "" "$(website_post_paths)"
DIGEST_NOREF=$(shipped_digest); RC=$?
eq "shipped_digest is empty with no origin/master" "" "$DIGEST_NOREF"
eq "shipped_digest still exits 0" "0" "$RC"
# The reason main hard-checks the ref: with nothing to compare against, every
# slug reads as un-shipped and the collision gate waves anything through --
# igor#507's duplicate-post failure by another route, and silent without the
# check, since each helper swallows git's stderr.
if post_slug_exists "an-older-post"; then bad "post_slug_exists is fail-open with no ref"; else ok "post_slug_exists is fail-open with no ref (why website_ref_ok gates main)"; fi
if website_ref_ok; then bad "website_ref_ok rejects a repo with no origin/master"; else ok "website_ref_ok rejects a repo with no origin/master"; fi
# shellcheck disable=SC2034  # restores the good fixture for any block added below
WEBSITE_PATH="$CLONE"

if [ "$FAIL" -eq 0 ]; then
  echo "test-ideation-shipped-digest: all checks passed"
else
  echo "test-ideation-shipped-digest: $FAIL FAILED"
  exit 1
fi
