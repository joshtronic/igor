#!/usr/bin/env bash
# test-scope-gate.sh -- unit tests for lib/scope-gate.sh: the finalize-time
# runaway-diff guard's test-path classifier (is_test_path), its declared
# generated-data glob matcher (scope_gate_is_generated_data, igor#544), and
# its numstat line-summer (igor#467). Pure logic -- no network, no git, no
# state.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/scope-gate.sh
. "$HERE/../lib/scope-gate.sh"

FAIL=0
ok() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then printf '  + %s\n' "$d"; else printf '  x %s (expected rc0)\n' "$d"; FAIL=$((FAIL + 1)); fi; }
no() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then printf '  x %s (expected rc!=0)\n' "$d"; FAIL=$((FAIL + 1)); else printf '  + %s\n' "$d"; fi; }
eq() { if [ "$2" = "$3" ]; then printf '  + %s\n' "$1"; else printf '  x %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi; }
# total_of/gen_lines_of/gen_files_of -- pull one field out of
# scope_gate_sum_numstat's "<total>\t<gen-lines>\t<gen-files>" output.
total_of() { cut -f1; }
gen_lines_of() { cut -f2; }
gen_files_of() { cut -f3; }

echo "== SCOPE_GATE_MAX_LINES: the runaway threshold =="
eq "threshold is 1000, not the old 400" "1000" "$SCOPE_GATE_MAX_LINES"

echo "== is_test_path: positive matches =="
ok "tests/ directory"                 is_test_path "tests/foo.sh"
ok "test/ directory, nested"          is_test_path "src/pkg/test/foo.go"
ok "bin/test-*.sh convention"         is_test_path "bin/test-scope-gate.sh"
ok "foo.test.js style"                is_test_path "src/foo.test.js"
ok "foo.spec.ts style"                is_test_path "src/components/foo.spec.ts"
ok "foo_test.go style"                is_test_path "pkg/foo_test.go"
ok "foo_test.py style"                is_test_path "app/foo_test.py"
ok "foo_test.rb style"                is_test_path "app/foo_test.rb"
ok "foo_test.ex style"                is_test_path "lib/foo_test.ex"
ok "foo_test.exs style"               is_test_path "lib/foo_test.exs"
ok "spec/ directory"                  is_test_path "spec/models/foo_spec.rb"
ok "top-level test/ directory"        is_test_path "test/unit/foo.c"

echo "== is_test_path: negative matches (real source) =="
no "plain lib source"                 is_test_path "lib/scope-gate.sh"
no "bin entry point (not test-*)"     is_test_path "bin/tick.sh"
no "a word containing 'test' inline"  is_test_path "lib/latest-version.sh"
no "a word containing 'spec' inline"  is_test_path "lib/inspector.sh"
no "contest.js is not a test file"    is_test_path "src/contest.js"
no "protest_test misspelled ext"      is_test_path "src/foo_test.txt"
no "docs markdown"                    is_test_path "docs/architecture.md"

echo "== scope_gate_sum_numstat: filters tests and lockfiles, sums the rest =="
NUMSTAT=$(cat <<'EOF'
10	5	bin/tick.sh
20	0	bin/test-scope-gate.sh
3	1	lib/scope-gate.sh
100	100	package-lock.json
7	2	dist/bundle.js
1	1	src/foo.test.js
EOF
)
eq "sums only non-test, non-lockfile, non-dist lines (10+5 + 3+1 = 19)" "19" \
  "$(printf '%s\n' "$NUMSTAT" | scope_gate_sum_numstat | total_of)"
eq "no generated-data globs declared -> 0 excluded lines" "0" \
  "$(printf '%s\n' "$NUMSTAT" | scope_gate_sum_numstat | gen_lines_of)"
eq "no generated-data globs declared -> 0 excluded files" "0" \
  "$(printf '%s\n' "$NUMSTAT" | scope_gate_sum_numstat | gen_files_of)"

echo "== scope_gate_sum_numstat: binary files count as 0 =="
BIN_NUMSTAT=$(printf '%s\t%s\t%s\n' '-' '-' 'assets/logo.png')
eq "binary numstat line ('-\t-\tpath') contributes 0" "0" \
  "$(printf '%s\n' "$BIN_NUMSTAT" | scope_gate_sum_numstat | total_of)"

echo "== scope_gate_sum_numstat: empty input sums to 0 =="
eq "no lines -> 0" "0" "$(printf '' | scope_gate_sum_numstat | total_of)"

echo "== scope_gate_is_generated_data: glob matching =="
ok "matches a single declared glob"        scope_gate_is_generated_data "src/_data/jobs.json" "src/_data/*.json"
ok "matches one of several comma-separated globs" \
  scope_gate_is_generated_data "atsjobs.json" "src/_data/*.json, atsjobs.json"
no "declaring nothing never matches"       scope_gate_is_generated_data "src/_data/jobs.json" ""
no "a path outside the declared glob"      scope_gate_is_generated_data "src/app.js" "src/_data/*.json"
no "prefix collision without a glob"       scope_gate_is_generated_data "src/_data/jobs.json.bak" "src/_data/*.json"

echo "== scope_gate_is_generated_data: declarations are patterns, never a listing of the CWD =="
# Splitting the comma-separated declaration must not pathname-expand it. If it
# did, a pattern like `*.json` would be replaced by whatever files happen to
# sit in the process's CWD before it is ever used as a match pattern -- so a
# path the branch DELETED (and which therefore isn't on disk) would stop
# matching and get counted as branch work, the exact false block this exists
# to prevent. Run from a directory where the pattern DOES expand, against a
# path that isn't there.
GEN_CWD_TMP=$(mktemp -d)
trap 'rm -rf "$GEN_CWD_TMP"' EXIT
touch "$GEN_CWD_TMP/present.json"
in_cwd() { local d="$1"; shift; (cd "$d" && "$@"); }

ok "a path absent from the CWD still matches its glob" \
  in_cwd "$GEN_CWD_TMP" scope_gate_is_generated_data "deleted.json" "*.json"
eq "a deleted generated-data file is still excluded from the count" "0" \
  "$(printf '9\t9\tdeleted.json\n' | in_cwd "$GEN_CWD_TMP" scope_gate_sum_numstat "*.json" | total_of)"
no "expansion can't smuggle in a non-matching path either" \
  in_cwd "$GEN_CWD_TMP" scope_gate_is_generated_data "present.json" "*.yaml"

echo "== scope_gate_sum_numstat: declared generated-data is excluded, and the exclusion is reported (igor#544) =="
# ctj#127-shaped scenario: real branch work is small (662 lines across 15
# files in the real incident); a nightly refresh rewrote a multi-MB data
# file underneath the branch, which a stale-base diff attributes to the
# branch. Modeled here at a scale that would trip the 1000-line cap on its
# own if miscounted as branch work.
GEN_NUMSTAT=$(cat <<'EOF'
200	100	src/pages/jobs.astro
150	50	src/lib/search.js
50000	50000	src/_data/jobs.json
20000	20000	atsjobs.json
EOF
)
GLOBS="src/_data/*.json,atsjobs.json"

eq "declared globs present: real branch work only (200+100+150+50=500)" "500" \
  "$(printf '%s\n' "$GEN_NUMSTAT" | scope_gate_sum_numstat "$GLOBS" | total_of)"
eq "declared globs present: passes the gate (500 <= 1000)" "true" \
  "$([ "$(printf '%s\n' "$GEN_NUMSTAT" | scope_gate_sum_numstat "$GLOBS" | total_of)" -le "$SCOPE_GATE_MAX_LINES" ] && echo true || echo false)"
eq "declared globs present: reports 140000 excluded generated-data lines" "140000" \
  "$(printf '%s\n' "$GEN_NUMSTAT" | scope_gate_sum_numstat "$GLOBS" | gen_lines_of)"
eq "declared globs present: reports 2 excluded generated-data files" "2" \
  "$(printf '%s\n' "$GEN_NUMSTAT" | scope_gate_sum_numstat "$GLOBS" | gen_files_of)"

eq "declaration ABSENT: the same branch still blocks (500+140000 > 1000) -- proves the exclusion, not coincidence, does the work" "true" \
  "$([ "$(printf '%s\n' "$GEN_NUMSTAT" | scope_gate_sum_numstat "" | total_of)" -gt "$SCOPE_GATE_MAX_LINES" ] && echo true || echo false)"

echo "== scope_gate_sum_numstat: the exclusion never becomes a bypass for real oversized work (igor#544) =="
OVERSIZED_NUMSTAT=$(cat <<'EOF'
2000	0	src/lib/big-refactor.js
50000	50000	src/_data/jobs.json
EOF
)
eq "a genuinely oversized branch still blocks even with the declaration present (2000 > 1000)" "true" \
  "$([ "$(printf '%s\n' "$OVERSIZED_NUMSTAT" | scope_gate_sum_numstat "$GLOBS" | total_of)" -gt "$SCOPE_GATE_MAX_LINES" ] && echo true || echo false)"
eq "oversized case still narrows correctly: counted total is just the real work (2000)" "2000" \
  "$(printf '%s\n' "$OVERSIZED_NUMSTAT" | scope_gate_sum_numstat "$GLOBS" | total_of)"

echo "== scope_gate_sum_numstat: a binary generated-data file reports as a file, 0 lines =="
BIN_GEN=$(printf '%s\t%s\t%s\n' '-' '-' 'src/_data/cache.bin')
eq "binary generated-data contributes 0 excluded lines" "0" \
  "$(printf '%s\n' "$BIN_GEN" | scope_gate_sum_numstat "src/_data/*" | gen_lines_of)"
eq "binary generated-data still counts as 1 excluded file" "1" \
  "$(printf '%s\n' "$BIN_GEN" | scope_gate_sum_numstat "src/_data/*" | gen_files_of)"

echo "== scope_gate_base_generated_globs: reads the BASE branch, never the branch's own HEAD =="
# The anti-self-escalation property: a branch must not be able to grant
# itself a new exclusion mid-branch to duck the guard. Exercised against a
# real throwaway repo, since it is a git-ref read, not string logic.
if ! command -v git >/dev/null 2>&1 || ! . "$HERE/../lib/dossier.sh" 2>/dev/null; then
  echo "  ~ skipped (git or lib/dossier.sh unavailable)"
else
  BASE_TMP=$(mktemp -d)
  trap 'rm -rf "$GEN_CWD_TMP" "$BASE_TMP"' EXIT
  (
    cd "$BASE_TMP" || exit 1
    git init -q -b main . && git config user.email t@t && git config user.name t
    printf '## Metadata\n\n```\ntype: tool\ngenerated-data: base/*.json\n```\n' > AGENTS.md
    git add -A && git commit -qm base
    git checkout -qb branch
    printf '## Metadata\n\n```\ntype: tool\ngenerated-data: base/*.json,sneaky/*\n```\n' > AGENTS.md
    git add -A && git commit -qm escalate
  ) >/dev/null 2>&1

  eq "the base ref's declaration wins over the branch's own edit" "base/*.json" \
    "$(in_cwd "$BASE_TMP" scope_gate_base_generated_globs main)"
  no "the branch's self-granted glob does not match when read from base" \
    scope_gate_is_generated_data "sneaky/huge.json" "$(in_cwd "$BASE_TMP" scope_gate_base_generated_globs main)"
  eq "a ref with no dossier declares nothing" "" \
    "$(in_cwd "$BASE_TMP" scope_gate_base_generated_globs main:nope 2>/dev/null)"
fi

if [ "$FAIL" -gt 0 ]; then
  printf '\n%d assertion(s) failed\n' "$FAIL"
  exit 1
fi
printf '\nall assertions passed\n'
