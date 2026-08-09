#!/usr/bin/env bash
# test-scope-gate.sh -- unit tests for lib/scope-gate.sh: the finalize-time
# runaway-diff guard's test-path classifier (is_test_path) and its numstat
# line-summer (igor#467). Pure logic -- no network, no git, no state.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/scope-gate.sh
. "$HERE/../lib/scope-gate.sh"

FAIL=0
ok() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then printf '  + %s\n' "$d"; else printf '  x %s (expected rc0)\n' "$d"; FAIL=$((FAIL + 1)); fi; }
no() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then printf '  x %s (expected rc!=0)\n' "$d"; FAIL=$((FAIL + 1)); else printf '  + %s\n' "$d"; fi; }
eq() { if [ "$2" = "$3" ]; then printf '  + %s\n' "$1"; else printf '  x %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi; }

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
  "$(printf '%s\n' "$NUMSTAT" | scope_gate_sum_numstat)"

echo "== scope_gate_sum_numstat: binary files count as 0 =="
BIN_NUMSTAT=$(printf '%s\t%s\t%s\n' '-' '-' 'assets/logo.png')
eq "binary numstat line ('-\t-\tpath') contributes 0" "0" \
  "$(printf '%s\n' "$BIN_NUMSTAT" | scope_gate_sum_numstat)"

echo "== scope_gate_sum_numstat: empty input sums to 0 =="
eq "no lines -> 0" "0" "$(printf '' | scope_gate_sum_numstat)"

if [ "$FAIL" -gt 0 ]; then
  printf '\n%d assertion(s) failed\n' "$FAIL"
  exit 1
fi
printf '\nall assertions passed\n'
