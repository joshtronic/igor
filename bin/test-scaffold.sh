#!/usr/bin/env bash
# Unit tests for the auto-scaffold PURE functions (lib/repo-checks.sh,
# igor#304): gap parsing, stack detection, and generated scaffold content.
# The impure orchestrator (scaffold_try_open_pr) hits the Forgejo API and is
# guarded/integration -- not exercised here.
# Skip-safe: exits 0 with a notice if a required tool is missing.
set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/repo-checks.sh
. "$HERE/lib/repo-checks.sh"

for t in jq base64 grep printf; do
  command -v "$t" >/dev/null 2>&1 || { echo "test-scaffold: $t unavailable -- skipping"; exit 0; }
done

FAIL=0
eq()  { if [ "$2" = "$3" ]; then printf '  + %s\n' "$1"; else printf '  x %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi; }
has() { if grep -q "$2" <<<"$3"; then printf '  + %s\n' "$1"; else printf '  x %s: missing pattern [%s]\n' "$1" "$2"; FAIL=$((FAIL+1)); fi; }
no()  { if grep -q "$2" <<<"$3"; then printf '  x %s: unexpected [%s]\n' "$1" "$2"; FAIL=$((FAIL+1)); else printf '  + %s\n' "$1"; fi; }

echo "== scaffold_parse_gaps: reads the '- [ ]' failure lines =="
REPORT='- [x] README present at repo root
- [ ] CLAUDE.md present at repo root -- add CLAUDE.md with project conventions
- [ ] Test setup detected -- add a way to run tests
- [ ] Lint setup detected -- add a linter config
- [ ] CI workflow present -- add a Forgejo Actions workflow'
GAPS=$(scaffold_parse_gaps "$REPORT")
has "flags claude_md" "^claude_md$" "$GAPS"
has "flags test"      "^test$"      "$GAPS"
has "flags lint"      "^lint$"      "$GAPS"
has "flags ci"        "^ci$"        "$GAPS"

echo "== scaffold_parse_gaps: a PASSING CI check is not a gap =="
no "no false ci on [x]" "^ci$" "$(scaffold_parse_gaps '- [x] CI workflow present')"

echo "== scaffold_parse_gaps: all-pass report -> no gaps =="
ALLPASS='- [x] CLAUDE.md present at repo root
- [x] Test setup detected
- [x] Lint setup detected'
eq "empty gaps" "" "$(scaffold_parse_gaps "$ALLPASS")"

echo "== scaffold_parse_gaps: a PASSING check is not a gap =="
no "no false claude_md on [x]" "claude_md" "$(scaffold_parse_gaps '- [x] CLAUDE.md present at repo root')"

echo "== scaffold_detect_stack =="
eq "eleventy via devDependencies" "eleventy" "$(scaffold_detect_stack '{"devDependencies":{"@11ty/eleventy":"^3"}}')"
eq "eleventy via script"          "eleventy" "$(scaffold_detect_stack '{"scripts":{"build":"eleventy"}}')"
eq "non-eleventy node -> empty"   ""         "$(scaffold_detect_stack '{"dependencies":{"react":"^18"}}')"
eq "empty package.json -> empty"  ""         "$(scaffold_detect_stack '')"

echo "== scaffold_test_script =="
eq "eleventy test script"   "npx @11ty/eleventy --dryrun" "$(scaffold_test_script eleventy)"
eq "unknown stack -> empty" ""                            "$(scaffold_test_script python)"

echo "== scaffold_validate_yml: satisfies the hardened CI check =="
YML=$(scaffold_validate_yml eleventy master 'npm ci')
has "triggers on pull_request" "pull_request:"                  "$YML"
has "runs npm test"            "run: npm test"                  "$YML"
has "installs via the arg"     "run: npm ci"                    "$YML"
has "pushes to default branch" "^      - master$"               "$YML"
eq  "unknown stack -> empty"   ""                               "$(scaffold_validate_yml python master 'npm ci')"
# The generator's output must pass the same regexes check_ci_workflow enforces:
# a pull_request trigger plus a build/test/lint verb.
has "check_ci pull_request gate" "pull_request"                                                  "$YML"
has "check_ci verb gate"         "test\|lint\|build\|dry-\?run\|eleventy\|npm (ci\|run\|test)"    "$YML"

echo "== scaffold_markdownlint: valid JSON =="
eq "markdownlint parses as JSON" "1" "$(scaffold_markdownlint | jq -e . >/dev/null 2>&1 && echo 1 || echo 0)"

echo "== scaffold_claude_md: package name, repo fallback, off-limits note =="
has "uses package name"        "# my-site"        "$(scaffold_claude_md joshtronic/x '{"name":"my-site"}')"
has "falls back to repo name"  "# x"              "$(scaffold_claude_md joshtronic/x '{}')"
has "off-limits guards gates"  "review/merge gates" "$(scaffold_claude_md joshtronic/x '{}')"
no  "no stale CI off-limits"   ".forgejo/workflows/" "$(scaffold_claude_md joshtronic/x '{}')"

echo "== scaffold_pr_body: lists only the gaps present =="
BODY=$(scaffold_pr_body "$(printf 'claude_md\ntest\n')")
has "body mentions CLAUDE.md"                  "CLAUDE.md"    "$BODY"
no  "body omits markdownlint when not a gap"   "markdownlint" "$BODY"
no  "body omits validate.yml when no ci gap"   "validate.yml" "$BODY"
CIBODY=$(scaffold_pr_body "$(printf 'claude_md\ntest\nci\n')")
has "body lists validate.yml when ci gap"      "validate.yml" "$CIBODY"

if [ "$FAIL" -eq 0 ]; then echo "test-scaffold: all checks passed"; exit 0; else echo "test-scaffold: $FAIL check(s) failed"; exit 1; fi
