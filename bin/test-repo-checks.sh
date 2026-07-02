#!/usr/bin/env bash
# test-repo-checks.sh -- unit tests for the two readiness checks tightened in
# the "validated means real CI + real test" fix (lib/repo-checks.sh):
#   check_test_signal   -- rejects the npm default stub, accepts a real test.
#   check_ci_workflow    -- requires a pull_request-triggered build/test/lint
#                           workflow; a deploy-only workflow no longer counts.
# Skip-safe: needs jq; exits 0 with a notice if absent. All boundaries stubbed
# (the per-repo cache globals + the two forgejo helpers) -- no network.
#
# The forgejo_repo_* overrides below are invoked indirectly (check_ci_workflow
# calls them), which shellcheck can't trace statically -- hence SC2329.
# shellcheck disable=SC2329
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "test-repo-checks: jq absent -- skipping"; exit 0; }

HERE="$(cd "$(dirname "$0")" && pwd)"
# check_ci_workflow calls forgejo_repo_list_dir / forgejo_repo_get_file; source
# forgejo.sh so the real signatures exist, then override them per-case below.
# shellcheck source=../lib/forgejo.sh
. "$HERE/../lib/forgejo.sh"
# shellcheck source=../lib/repo-checks.sh
. "$HERE/../lib/repo-checks.sh"

FAIL=0
ok() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then printf '  + %s\n' "$d"; else printf '  x %s (rc0 expected)\n' "$d"; FAIL=$((FAIL + 1)); fi; }
no() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then printf '  x %s (rc!=0 expected)\n' "$d"; FAIL=$((FAIL + 1)); else printf '  + %s\n' "$d"; fi; }

# Reset the per-repo cache globals check_test_signal reads. Each case sets only
# what it needs; rc_root_has consults _RC_ROOT_NAMES.
reset_cache() {
  _RC_ROOT_NAMES=""; _RC_LABELS=""
  _RC_PACKAGE_JSON=""; _RC_PYPROJECT=""; _RC_MAKEFILE=""; _RC_CARGO=""
}

echo "== check_test_signal: package.json test script =="
reset_cache
_RC_ROOT_NAMES=$'package.json'
_RC_PACKAGE_JSON='{"scripts":{"test":"echo \"Error: no test specified\" && exit 1"}}'
no "npm default stub is rejected"        check_test_signal
reset_cache
_RC_ROOT_NAMES=$'package.json'
_RC_PACKAGE_JSON='{"scripts":{"test":"jest"}}'
ok "a real test script passes"           check_test_signal
reset_cache
_RC_ROOT_NAMES=$'package.json'
_RC_PACKAGE_JSON='{"scripts":{"build":"eleventy"}}'
no "no test script at all is rejected"   check_test_signal

echo "== check_test_signal: other stacks still pass =="
reset_cache; _RC_ROOT_NAMES=$'pytest.ini'
ok "pytest.ini passes"                   check_test_signal
reset_cache; _RC_PYPROJECT=$'[tool.pytest.ini_options]\naddopts = "-q"'
ok "[tool.pytest] in pyproject passes"   check_test_signal
reset_cache; _RC_MAKEFILE=$'test:\n\tgo test ./...'
ok "Makefile test: target passes"        check_test_signal
reset_cache; _RC_ROOT_NAMES=$'go.mod'
ok "go.mod (implicit go test) passes"    check_test_signal
reset_cache; _RC_ROOT_NAMES=$'Cargo.toml'
ok "Cargo.toml (implicit cargo test)"    check_test_signal

echo "== check_ci_workflow: pull_request + verify step required =="
# Stub the directory listing (one workflow file) and file fetch (its content).
# rc_root_has must see the dotdir at the root for the check to look at all.
DEPLOY_ONLY=$'name: deploy\non:\n  push:\n    branches: [master]\njobs:\n  deploy:\n    steps:\n      - run: rsync -a _site/ host:/var/www'
PR_CI=$'name: ci\non:\n  pull_request:\njobs:\n  test:\n    steps:\n      - run: npm ci\n      - run: npm test'

forgejo_repo_list_dir() { printf 'ci.yml\n'; }

reset_cache; _RC_ROOT_NAMES=$'.forgejo'
forgejo_repo_get_file() { printf '%s' "$DEPLOY_ONLY"; }
no "deploy-only workflow (push:master + rsync) fails" check_ci_workflow acme/x

reset_cache; _RC_ROOT_NAMES=$'.forgejo'
forgejo_repo_get_file() { printf '%s' "$PR_CI"; }
ok "pull_request + test/lint workflow passes"         check_ci_workflow acme/x

reset_cache; _RC_ROOT_NAMES=$'src'   # no .forgejo/.gitea at the root
forgejo_repo_get_file() { printf '%s' "$PR_CI"; }
no "no workflow dir at root -> fails"                 check_ci_workflow acme/x

# A pull_request trigger with NO verify step (e.g. a label-sync bot) shouldn't
# count as CI either -- both signals are required.
NO_VERIFY=$'name: label\non:\n  pull_request:\njobs:\n  label:\n    steps:\n      - uses: actions/labeler@v5'
reset_cache; _RC_ROOT_NAMES=$'.forgejo'
forgejo_repo_get_file() { printf '%s' "$NO_VERIFY"; }
no "pull_request but no verify step -> fails"         check_ci_workflow acme/x

if [ "$FAIL" -eq 0 ]; then
  echo "test-repo-checks: all passed"
else
  echo "test-repo-checks: $FAIL failure(s)"
fi
exit "$FAIL"
