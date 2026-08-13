#!/usr/bin/env bash
# test-ideation-write-post-file.sh -- unit tests for bin/ideation-pipeline.sh's
# write_post_file (igor#509).
#
# Root cause: igor.bot's CI (markdownlint, MD012 default-on) strips YAML
# frontmatter before linting and exempts leading blanks, so a double blank
# line immediately after the closing frontmatter fence passes CI even though
# the same double blank mid-body would fail it. The drafted post body can
# arrive with blank-line runs (double blanks between paragraphs, or a stray
# blank right after the fence) and nothing downstream ever squeezed them.
#
# The fix normalizes the written file in write_post_file: no two consecutive
# blank lines survive anywhere in the output, checked with a real file write
# (not a string comparison) since the function's job is the file on disk.
#
# Function is lifted straight out of bin/ideation-pipeline.sh (sed range
# extraction, same technique bin/test-ideation-shipped-digest.sh uses) rather
# than sourced, since the script has top-level side-effecting code that a
# plain `.` would trip over.
# Skip-safe: needs jq; exits 0 with a notice if absent.
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "test-ideation-write-post-file: jq absent -- skipping"; exit 0; }

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/ideation-pipeline.sh"

FAIL=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; FAIL=$((FAIL + 1)); }
eq()  { local d="$1" want="$2" got="$3"; if [ "$want" = "$got" ]; then ok "$d"; else bad "$d (want $(printf '%q' "$want") got $(printf '%q' "$got"))"; fi; }

lift() {
  local fn="$1" src
  src=$(sed -n "/^${fn}() {\$/,/^}\$/p" "$SCRIPT")
  [ -z "$src" ] && { bad "could not extract ${fn}() from bin/ideation-pipeline.sh"; return 1; }
  eval "$src"
}

lift write_post_file || exit 1

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# shellcheck disable=SC2034  # read by the eval'd write_post_file
WEBSITE_PATH="$TMPROOT/website"
mkdir -p "$WEBSITE_PATH"

echo "== a drafted body with double blanks (incl. right after frontmatter) is squeezed =="
POST_JSON=$(jq -n '{
  title: "A Test Post",
  description: "a test post description",
  tags: ["tech"],
  body: "\n\nFirst paragraph.\n\n\nSecond paragraph after a double blank.\n\n\n\nThird paragraph after a triple blank.\n"
}')
POST_FILE=$(write_post_file "a-test-post" "$POST_JSON" "2026-08-12T00:00:00Z")

eq "write_post_file returns a path that exists" "1" "$([ -f "$POST_FILE" ] && echo 1 || echo 0)"

if grep -qzP '\n[[:space:]]*\n[[:space:]]*\n' "$POST_FILE" 2>/dev/null; then
  bad "no run of 2+ consecutive blank lines survives anywhere in the file"
else
  ok "no run of 2+ consecutive blank lines survives anywhere in the file"
fi

FENCE_LINE=$(grep -n '^---$' "$POST_FILE" | sed -n '2p' | cut -d: -f1)
AFTER_FENCE_1=$(sed -n "$((FENCE_LINE + 1))p" "$POST_FILE")
AFTER_FENCE_2=$(sed -n "$((FENCE_LINE + 2))p" "$POST_FILE")
eq "exactly one blank line right after the frontmatter fence" "" "$AFTER_FENCE_1"
eq "content resumes on the very next line" "First paragraph." "$AFTER_FENCE_2"

BODY_CONTENT=$(cat "$POST_FILE")
case "$BODY_CONTENT" in
  *"First paragraph."*"Second paragraph after a double blank."*"Third paragraph after a triple blank."*)
    ok "all paragraphs survive the squeeze" ;;
  *)
    bad "all paragraphs survive the squeeze" ;;
esac

echo "== a drafted body with no blank runs is left untouched =="
POST_JSON2=$(jq -n '{
  title: "Clean Post",
  description: "already clean",
  tags: [],
  body: "One paragraph.\n\nAnother paragraph.\n"
}')
POST_FILE2=$(write_post_file "clean-post" "$POST_JSON2" "2026-08-12T00:00:00Z")
if grep -qzP '\n[[:space:]]*\n[[:space:]]*\n' "$POST_FILE2" 2>/dev/null; then
  bad "an already-clean post stays free of double blanks"
else
  ok "an already-clean post stays free of double blanks"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "test-ideation-write-post-file: all checks passed"
else
  echo "test-ideation-write-post-file: $FAIL FAILED"
  exit 1
fi
