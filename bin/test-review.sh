#!/usr/bin/env bash
# test-review.sh -- unit tests for lib/review.sh: the shadow reviewer's
# extra context-gathering (igor#438) -- the linked issue's body and the
# repo's test-runner facts, both folded into review_build_prompt. Skip-safe:
# needs jq; exits 0 with a notice if absent. forgejo_get_issue and
# forgejo_repo_get_file are stubbed per section -- no real API calls.
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "test-review: jq absent -- skipping"; exit 0; }

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/review.sh
. "$HERE/../lib/review.sh"

FAIL=0
eq()    { if [ "$2" = "$3" ]; then printf '  + %s\n' "$1"; else printf '  x %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi; }
has()   { case "$2" in *"$3"*) printf '  + %s\n' "$1" ;; *) printf '  x %s: [%s] lacks [%s]\n' "$1" "${2:0:200}" "$3"; FAIL=$((FAIL + 1)) ;; esac; }
lacks() { case "$2" in *"$3"*) printf '  x %s: [%s] still has [%s]\n' "$1" "${2:0:200}" "$3"; FAIL=$((FAIL + 1)) ;; *) printf '  + %s\n' "$1" ;; esac; }

echo "== review_closed_issue_number: parsing the closing keyword =="
eq "Closes #433 -> 433"                    "433" "$(review_closed_issue_number 'Closes #433')"
eq "lowercase 'closes' -> 433"             "433" "$(review_closed_issue_number 'this closes #433, see notes')"
eq "Fixes #12 -> 12"                       "12"  "$(review_closed_issue_number 'Fixes #12')"
eq "Resolved #7 -> 7"                      "7"   "$(review_closed_issue_number 'Resolved #7')"
eq "first match wins"                      "433" "$(review_closed_issue_number 'Closes #433 and fixes #12')"
eq "a bare #N with no keyword -> empty"    ""    "$(review_closed_issue_number 'see #433 for context')"
eq "no issue reference at all -> empty"    ""    "$(review_closed_issue_number 'just a description')"

echo "== review_linked_issue_section: fetch + bound, skip gracefully =="
forgejo_get_issue() {
  local number="$2"
  case "$number" in
    433) printf '%s' '{"number":433,"title":"Requirement 6","body":"Requirement 6: do the thing."}' ;;
    *) return 1 ;;
  esac
}
SECTION=$(review_linked_issue_section acme/repo "Closes #433")
has  "linked-issue section carries the heading"    "$SECTION" "## Linked issue #433"
has  "linked-issue section carries the title"      "$SECTION" "Requirement 6"
has  "linked-issue section carries the body"       "$SECTION" "do the thing"
eq   "PR body with no closing keyword -> no section" "" "$(review_linked_issue_section acme/repo 'no issue named here')"
eq   "closing keyword but the fetch fails -> no section (skip gracefully)" "" "$(review_linked_issue_section acme/repo 'Closes #999')"

forgejo_get_issue() { printf '%s' "{\"number\":5,\"title\":\"t\",\"body\":\"$(head -c 5000 < /dev/zero | tr '\0' 'x')\"}"; }
LONG=$(review_linked_issue_section acme/repo "Closes #5")
has "an oversized issue body is truncated"          "$LONG" "TRUNCATED"
has "linked-issue section is fenced as untrusted data" "$LONG" "BEGIN UNTRUSTED ISSUE TEXT"
has "linked-issue section's untrusted fence is closed" "$LONG" "END UNTRUSTED ISSUE TEXT"
# Body is the only source of 'x' chars in this fixture (title is "t"), so a
# raw count is a format-independent way to confirm the truncation length.
eq  "truncated body caps at REVIEW_ISSUE_BODY_MAX"  "$REVIEW_ISSUE_BODY_MAX" \
    "$(printf '%s' "$LONG" | tr -cd 'x' | wc -c | tr -d ' ')"

echo "== review_diff_changed_files / review_diff_test_files =="
DIFF="diff --git a/bin/test-foo.sh b/bin/test-foo.sh
index 000..111 100644
--- a/bin/test-foo.sh
+++ b/bin/test-foo.sh
@@ -0,0 +1 @@
+echo hi
diff --git a/lib/foo.sh b/lib/foo.sh
index 000..111 100644
--- a/lib/foo.sh
+++ b/lib/foo.sh
@@ -0,0 +1 @@
+echo hi"
FILES=$(review_diff_changed_files "$DIFF")
has "changed-files lists the new test file"   "$FILES" "bin/test-foo.sh"
has "changed-files lists the non-test file"   "$FILES" "lib/foo.sh"
TESTFILES=$(review_diff_test_files "$FILES")
eq  "test-file filter keeps only the test-shaped path" "bin/test-foo.sh" "$TESTFILES"

NO_TEST_DIFF="diff --git a/lib/foo.sh b/lib/foo.sh
index 000..111 100644
--- a/lib/foo.sh
+++ b/lib/foo.sh
@@ -0,0 +1 @@
+echo hi"
eq "no test-shaped files touched -> empty" "" "$(review_diff_test_files "$(review_diff_changed_files "$NO_TEST_DIFF")")"

echo "== review_makefile_target_recipe: chases a one-hop delegation =="
MAKEFILE='test: check-sync

check-sync:
	bin/check-sync.sh
'
RECIPE=$(review_makefile_target_recipe "$MAKEFILE" test)
has "delegated 'test: check-sync' resolves to check-sync's own recipe" "$RECIPE" "bin/check-sync.sh"

DIRECT_MAKEFILE='test:
	pytest -q
'
eq "a target with its own recipe needs no delegation hop" "	pytest -q" \
   "$(review_makefile_target_recipe "$DIRECT_MAKEFILE" test)"

eq "no matching target -> empty" "" "$(review_makefile_target_recipe "$MAKEFILE" lint)"

echo "== review_test_runner_facts: the assembled section =="
forgejo_repo_get_file() {
  local path="$2"
  case "$path" in
    Makefile) printf '%s' "$MAKEFILE" ;;
    bin/check-sync.sh) printf 'globs bin/test-*.sh and runs each one\n' ;;
    *) return 1 ;;
  esac
}
FACTS=$(review_test_runner_facts acme/repo "$DIFF")
has "facts name the changed test file"           "$FACTS" "bin/test-foo.sh"
has "facts show the Makefile's test target"      "$FACTS" "bin/check-sync.sh"
has "facts include the referenced script's content (answers 'is it run')" "$FACTS" "globs bin/test-*.sh"
eq  "diff with no test-shaped files -> no section" "" "$(review_test_runner_facts acme/repo "$NO_TEST_DIFF")"

forgejo_repo_get_file() { return 1; }   # no Makefile, no package.json, nothing readable
BARE=$(review_test_runner_facts acme/repo "$DIFF")
has "still names the changed test file with zero repo signal" "$BARE" "bin/test-foo.sh"
lacks "no Makefile section fabricated when none exists"        "$BARE" "Makefile"

echo "== review_build_prompt: acceptance test -- both facts land in the built prompt =="
forgejo_get_issue() { printf '%s' '{"number":433,"title":"Requirement 6","body":"Requirement 6: do the thing."}'; }
forgejo_repo_get_file() {
  case "$2" in
    Makefile) printf '%s' "$MAKEFILE" ;;
    bin/check-sync.sh) printf 'globs bin/test-*.sh and runs each one\n' ;;
    *) return 1 ;;
  esac
}
PROMPT=$(review_build_prompt joshtronic/igor 9 deadbeef success "Add a test" "Closes #433" "$DIFF" "")
has "built prompt carries the linked issue's body"           "$PROMPT" "Requirement 6: do the thing"
has "built prompt states the test-runner facts"              "$PROMPT" "bin/check-sync.sh"
has "built prompt still carries the unified diff"            "$PROMPT" "diff --git a/bin/test-foo.sh"

# No linked issue, no test file touched -> must reproduce the pre-438 shape exactly.
PLAIN=$(review_build_prompt acme/repo 1 cafe0000 success "Fix a bug" "just a fix, no issue" "$NO_TEST_DIFF" "")
lacks "no linked-issue heading when the PR closes nothing" "$PLAIN" "## Linked issue"
lacks "no test-runner-facts heading when no test file changed" "$PLAIN" "## Test-runner facts"
EXPECTED_PLAIN="PR under review: acme/repo#1
Head commit: cafe0000
CI status for head: success

## PR title

Fix a bug

## PR description

just a fix, no issue

## Unified diff

\`\`\`diff
${NO_TEST_DIFF}
\`\`\`"
eq "plain PR (no issue, no test files) prompt is byte-identical to the pre-438 shape" "$EXPECTED_PLAIN" "$PLAIN"

if [ "$FAIL" -eq 0 ]; then
  echo "test-review: all checks passed"
else
  echo "test-review: $FAIL check(s) failed"
fi
exit "$FAIL"
