#!/usr/bin/env bash
# test-repo-checks.sh -- unit tests for the LOCAL-clone readiness checks
# (lib/repo-checks.sh). Builds throwaway git repos, commits file sets, and
# runs the checks against them -- exercising the real git reads
# (rc_local_init + check_*), no network, no API stubs.
#   check_test_signal  -- rejects the npm default stub, accepts a real test.
#   check_ci_workflow  -- requires a pull_request-triggered build/test/lint
#                         workflow; a deploy-only workflow no longer counts.
# Skip-safe: needs git + jq; exits 0 with a notice if either is absent.
set -uo pipefail

command -v jq  >/dev/null 2>&1 || { echo "test-repo-checks: jq absent -- skipping";  exit 0; }
command -v git >/dev/null 2>&1 || { echo "test-repo-checks: git absent -- skipping"; exit 0; }

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/repo-checks.sh
. "$HERE/../lib/repo-checks.sh"

FAIL=0
ok() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then printf '  + %s\n' "$d"; else printf '  x %s (rc0 expected)\n' "$d"; FAIL=$((FAIL + 1)); fi; }
no() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then printf '  x %s (rc!=0 expected)\n' "$d"; FAIL=$((FAIL + 1)); else printf '  + %s\n' "$d"; fi; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# new_fixture -- init a repo on branch master under a unique dir, echo its
# path. Caller writes files into it, then commit_fixture points the check
# globals at it (ref = the local master branch; the checks read <ref>:<path>,
# which a local branch satisfies just like origin/<ref> on a real clone).
new_fixture() {
  local p; p=$(mktemp -d "$TMPROOT/fix.XXXXXX")
  git init -q -b master "$p"
  git -C "$p" config user.email t@t
  git -C "$p" config user.name  t
  printf '%s' "$p"
}
commit_fixture() {
  local p="$1"
  git -C "$p" add -A
  git -C "$p" commit -q -m fixture
  _RC_REPO_PATH="$p"; _RC_REF="master"
}

echo "== rc_local_init: real clone resolves origin/<default> =="
BARE="$TMPROOT/bare.git"; git init -q --bare -b master "$BARE"
SEED="$(new_fixture)"; : >"$SEED/README.md"; echo '{}' >"$SEED/package.json"
git -C "$SEED" add -A; git -C "$SEED" commit -q -m seed
git -C "$SEED" remote add origin "$BARE"; git -C "$SEED" push -q origin master
CLONE="$TMPROOT/clone"; git clone -q "$BARE" "$CLONE"
ok "rc_local_init on a fresh clone succeeds" rc_local_init "$CLONE"
no "rc_local_init on a non-repo dir fails"   rc_local_init "$TMPROOT/does-not-exist"

echo "== check_test_signal: package.json test script =="
f="$(new_fixture)"; printf '%s' '{"scripts":{"test":"echo \"Error: no test specified\" && exit 1"}}' >"$f/package.json"; commit_fixture "$f"
no "npm default stub is rejected"        check_test_signal
f="$(new_fixture)"; printf '%s' '{"scripts":{"test":"jest"}}' >"$f/package.json"; commit_fixture "$f"
ok "a real test script passes"           check_test_signal
f="$(new_fixture)"; printf '%s' '{"scripts":{"build":"eleventy"}}' >"$f/package.json"; commit_fixture "$f"
no "no test script at all is rejected"   check_test_signal

echo "== check_test_signal: other stacks still pass =="
f="$(new_fixture)"; : >"$f/pytest.ini"; commit_fixture "$f"
ok "pytest.ini passes"                   check_test_signal
f="$(new_fixture)"; printf '[tool.pytest.ini_options]\naddopts = "-q"\n' >"$f/pyproject.toml"; commit_fixture "$f"
ok "[tool.pytest] in pyproject passes"   check_test_signal
f="$(new_fixture)"; printf 'test:\n\tgo test ./...\n' >"$f/Makefile"; commit_fixture "$f"
ok "Makefile test: target passes"        check_test_signal
f="$(new_fixture)"; : >"$f/go.mod"; commit_fixture "$f"
ok "go.mod (implicit go test) passes"    check_test_signal
f="$(new_fixture)"; : >"$f/Cargo.toml"; commit_fixture "$f"
ok "Cargo.toml (implicit cargo test)"    check_test_signal

echo "== check_ci_workflow: pull_request + verify step required =="
DEPLOY_ONLY=$'name: deploy\non:\n  push:\n    branches: [master]\njobs:\n  deploy:\n    steps:\n      - run: rsync -a _site/ host:/var/www'
PR_CI=$'name: ci\non:\n  pull_request:\njobs:\n  test:\n    steps:\n      - run: npm ci\n      - run: npm test'
NO_VERIFY=$'name: label\non:\n  pull_request:\njobs:\n  label:\n    steps:\n      - uses: actions/labeler@v5'

f="$(new_fixture)"; mkdir -p "$f/.forgejo/workflows"; printf '%s' "$DEPLOY_ONLY" >"$f/.forgejo/workflows/deploy.yml"; commit_fixture "$f"
no "deploy-only workflow (push:master + rsync) fails" check_ci_workflow
f="$(new_fixture)"; mkdir -p "$f/.forgejo/workflows"; printf '%s' "$PR_CI" >"$f/.forgejo/workflows/ci.yml"; commit_fixture "$f"
ok "pull_request + test/lint workflow passes"         check_ci_workflow
f="$(new_fixture)"; mkdir -p "$f/src"; : >"$f/src/index.js"; commit_fixture "$f"
no "no workflow dir -> fails"                          check_ci_workflow
f="$(new_fixture)"; mkdir -p "$f/.forgejo/workflows"; printf '%s' "$NO_VERIFY" >"$f/.forgejo/workflows/label.yml"; commit_fixture "$f"
no "pull_request but no verify step -> fails"         check_ci_workflow

echo "== check_claude_md / check_readme =="
f="$(new_fixture)"; : >"$f/CLAUDE.md"; : >"$f/README.md"; commit_fixture "$f"
ok "CLAUDE.md present"      check_claude_md
ok "README.md present"      check_readme
f="$(new_fixture)"; : >"$f/x"; commit_fixture "$f"
no "no CLAUDE.md -> fails"  check_claude_md
no "no README -> fails"     check_readme

echo "== validate_repo_local: full pass / not-ready / indeterminate =="
# validate_repo_local calls rc_local_init, which resolves origin/<default> --
# so the full-pass case needs a real clone (bare + push + clone), not a bare
# local fixture. Build a COMPLETE repo and clone it.
GBARE="$TMPROOT/good.git"; git init -q --bare -b master "$GBARE"
GWORK="$(new_fixture)"
: >"$GWORK/CLAUDE.md"; : >"$GWORK/README.md"; : >"$GWORK/.markdownlint.json"
printf '%s' '{"scripts":{"test":"jest"}}' >"$GWORK/package.json"
mkdir -p "$GWORK/.forgejo/workflows"; printf '%s' "$PR_CI" >"$GWORK/.forgejo/workflows/ci.yml"
git -C "$GWORK" add -A; git -C "$GWORK" commit -q -m good
git -C "$GWORK" remote add origin "$GBARE"; git -C "$GWORK" push -q origin master
GCLONE="$TMPROOT/good-clone"; git clone -q "$GBARE" "$GCLONE"
ok "a complete repo validates (rc 0)" validate_repo_local demo/good "$GCLONE"
# $CLONE (from the rc_local_init block) has only README + empty package.json
# -> genuinely not ready.
V=0; validate_repo_local demo/x "$CLONE" >/dev/null 2>&1 || V=$?
[ "$V" -eq 1 ] && printf '  + incomplete repo -> rc 1 (not ready)\n' || { printf '  x incomplete repo should rc 1, got %s\n' "$V"; FAIL=$((FAIL + 1)); }
V=0; validate_repo_local demo/x "$TMPROOT/does-not-exist" >/dev/null 2>&1 || V=$?
[ "$V" -eq 2 ] && printf '  + missing clone -> rc 2 (indeterminate)\n' || { printf '  x missing clone should rc 2, got %s\n' "$V"; FAIL=$((FAIL + 1)); }

if [ "$FAIL" -eq 0 ]; then
  echo "test-repo-checks: all passed"
else
  echo "test-repo-checks: $FAIL failure(s)"
fi
exit "$FAIL"
