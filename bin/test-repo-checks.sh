#!/usr/bin/env bash
# test-repo-checks.sh -- unit tests for the LOCAL-clone readiness checks
# (lib/repo-checks.sh). Builds throwaway git repos, commits file sets, and
# runs the checks against them -- exercising the real git reads
# (rc_local_init + check_*), no network, no API stubs.
#   check_test_signal  -- rejects the npm default stub, accepts a real test.
#   check_ci_workflow  -- requires a pull_request-triggered build/test/lint
#                         workflow; a deploy-only workflow no longer counts.
#   validate_repo_local -- gates on check_test_signal AND check_ci_workflow (a
#                         real test signal + a real Validate action); the
#                         CLAUDE.md/README/lint signals are advisory and no
#                         longer bench a repo that has real CI.
# Skip-safe: needs git + jq; exits 0 with a notice if either is absent.
set -uo pipefail

command -v jq  >/dev/null 2>&1 || { echo "test-repo-checks: jq absent -- skipping";  exit 0; }
command -v git >/dev/null 2>&1 || { echo "test-repo-checks: git absent -- skipping"; exit 0; }

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/dossier.sh
. "$HERE/../lib/dossier.sh"
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

echo "== check_deploy_smoke_signal: deploy-verifiable static site substitutes for unit tests =="
f="$(new_fixture)"
printf '%s' '{"smoke":{"url":"https://snail.io"}}' >"$f/agent.json"
printf '%s' '<meta name="deploy-sha" content="${sha}">' >"$f/vite.config.ts"
printf '%s' '{"scripts":{"build":"tsc && vite build"}}' >"$f/package.json"
commit_fixture "$f"
ok "smoke.url + deploy-sha marker passes"        check_deploy_smoke_signal
ok "...and satisfies check_test_signal too"      check_test_signal

f="$(new_fixture)"
printf '%s' '{"smoke":{"url":"https://snail.io"}}' >"$f/agent.json"
printf '%s' '{"scripts":{"build":"tsc && vite build"}}' >"$f/package.json"
commit_fixture "$f"
no "smoke.url without a deploy-sha marker fails"  check_deploy_smoke_signal
no "...and check_test_signal still fails too"     check_test_signal

f="$(new_fixture)"
printf '%s' '<meta name="deploy-sha" content="${sha}">' >"$f/vite.config.ts"
printf '%s' '{"scripts":{"build":"tsc && vite build"}}' >"$f/package.json"
commit_fixture "$f"
no "deploy-sha marker without agent.json fails"   check_deploy_smoke_signal

f="$(new_fixture)"
printf '%s' '{"smoke":{}}' >"$f/agent.json"
printf '%s' '<meta name="deploy-sha" content="${sha}">' >"$f/vite.config.ts"
commit_fixture "$f"
no "agent.json without .smoke.url fails"          check_deploy_smoke_signal

# An adopted dossier (root AGENTS.md carrying ## Metadata) is read FIRST, no
# agent.json involved at all -- the migration step this ticket (igor#473) is
# building toward: agent.json can be deleted once every reader takes url from
# the dossier.
DOSSIER=$'# snail.io\n\n## Metadata\n\n```yaml\ntype: game\nurl: https://snail.io\n```\n'
f="$(new_fixture)"
printf '%s' "$DOSSIER" >"$f/AGENTS.md"
printf '%s' '<meta name="deploy-sha" content="${sha}">' >"$f/vite.config.ts"
printf '%s' '{"scripts":{"build":"tsc && vite build"}}' >"$f/package.json"
commit_fixture "$f"
ok "adopted dossier url + deploy-sha marker passes (no agent.json needed)" check_deploy_smoke_signal

# The fleet-wide case TODAY: a PROSE AGENTS.md (the harness writes one into
# every repo) carries no `## Metadata`, so the repo has not adopted the spec
# and the legacy agent.json still answers. This is what keeps igor#473
# behavior-neutral.
f="$(new_fixture)"
printf '%s' $'# snail.io\n\nHouse rules for agents working here. No metadata fence.\n' >"$f/AGENTS.md"
printf '%s' '{"smoke":{"url":"https://snail.io"}}' >"$f/agent.json"
printf '%s' '<meta name="deploy-sha" content="${sha}">' >"$f/vite.config.ts"
printf '%s' '{"scripts":{"build":"tsc && vite build"}}' >"$f/package.json"
commit_fixture "$f"
ok "prose AGENTS.md + agent.json still falls back to .smoke.url" check_deploy_smoke_signal

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
if [ "$V" -eq 1 ]; then printf '  + incomplete repo -> rc 1 (not ready)\n'; else printf '  x incomplete repo should rc 1, got %s\n' "$V"; FAIL=$((FAIL + 1)); fi
V=0; validate_repo_local demo/x "$TMPROOT/does-not-exist" >/dev/null 2>&1 || V=$?
if [ "$V" -eq 2 ]; then printf '  + missing clone -> rc 2 (indeterminate)\n'; else printf '  x missing clone should rc 2, got %s\n' "$V"; FAIL=$((FAIL + 1)); fi

echo "== validate_repo_local: gate = test signal + Validate action; lint/docs advisory =="
# A repo with a real test signal + a pull_request Validate action but NO lint
# config, NO CLAUDE.md and NO README -- previously benched on the existence-only
# lint/doc checks -- now validates. This is the snail.io / knowthetable case
# (real tsc/vitest CI, no lint dotfile) the change unblocks.
MBARE="$TMPROOT/minimal.git"; git init -q --bare -b master "$MBARE"
MWORK="$(new_fixture)"
printf '%s' '{"scripts":{"test":"vitest run"}}' >"$MWORK/package.json"
mkdir -p "$MWORK/.forgejo/workflows"; printf '%s' "$PR_CI" >"$MWORK/.forgejo/workflows/validate.yml"
git -C "$MWORK" add -A; git -C "$MWORK" commit -q -m minimal
git -C "$MWORK" remote add origin "$MBARE"; git -C "$MWORK" push -q origin master
MCLONE="$TMPROOT/minimal-clone"; git clone -q "$MBARE" "$MCLONE"
ok "test signal + Validate action, no lint/doc -> validates (rc 0)" validate_repo_local demo/minimal "$MCLONE"

# No Validate action -> not ready, even with every advisory dotfile + a test.
NBARE="$TMPROOT/noci.git"; git init -q --bare -b master "$NBARE"
NWORK="$(new_fixture)"
: >"$NWORK/CLAUDE.md"; : >"$NWORK/README.md"; : >"$NWORK/.markdownlint.json"
printf '%s' '{"scripts":{"test":"jest"}}' >"$NWORK/package.json"
git -C "$NWORK" add -A; git -C "$NWORK" commit -q -m noci
git -C "$NWORK" remote add origin "$NBARE"; git -C "$NWORK" push -q origin master
NCLONE="$TMPROOT/noci-clone"; git clone -q "$NBARE" "$NCLONE"
V=0; validate_repo_local demo/noci "$NCLONE" >/dev/null 2>&1 || V=$?
if [ "$V" -eq 1 ]; then printf '  + all dotfiles + test but no Validate action -> rc 1 (not ready)\n'; else printf '  x expected rc 1, got %s\n' "$V"; FAIL=$((FAIL + 1)); fi

# No test signal -> not ready, even WITH a Validate action. check_test_signal
# stays a hard gate so "validated" keeps meaning "a change here can be
# CI-verified" (the invariant the maintenance pass relies on).
TBARE="$TMPROOT/notest.git"; git init -q --bare -b master "$TBARE"
TWORK="$(new_fixture)"
: >"$TWORK/CLAUDE.md"; : >"$TWORK/README.md"
printf '%s' '{"scripts":{"build":"vite build"}}' >"$TWORK/package.json"   # build only, no test
mkdir -p "$TWORK/.forgejo/workflows"; printf '%s' "$PR_CI" >"$TWORK/.forgejo/workflows/validate.yml"
git -C "$TWORK" add -A; git -C "$TWORK" commit -q -m notest
git -C "$TWORK" remote add origin "$TBARE"; git -C "$TWORK" push -q origin master
TCLONE="$TMPROOT/notest-clone"; git clone -q "$TBARE" "$TCLONE"
V=0; validate_repo_local demo/notest "$TCLONE" >/dev/null 2>&1 || V=$?
if [ "$V" -eq 1 ]; then printf '  + Validate action but no test signal -> rc 1 (not ready)\n'; else printf '  x expected rc 1, got %s\n' "$V"; FAIL=$((FAIL + 1)); fi

echo "== rc_context_file_exists_at: AGENTS.md/CLAUDE.md either/or (igor#493) =="
# tick.sh's pre-claim preflight -- a dossier-era repo (docs/agents-md-spec.md)
# has no obligation to also carry the legacy CLAUDE.md compatibility symlink,
# so either filename must satisfy the check.
f="$(new_fixture)"; printf '# demo\n' >"$f/AGENTS.md"; commit_fixture "$f"
ok "AGENTS.md only -> present"          rc_context_file_exists_at "$f" master
f="$(new_fixture)"; printf 'demo\n' >"$f/CLAUDE.md"; commit_fixture "$f"
ok "CLAUDE.md only -> present"          rc_context_file_exists_at "$f" master
f="$(new_fixture)"; printf '# demo\n' >"$f/AGENTS.md"; printf 'demo\n' >"$f/CLAUDE.md"; commit_fixture "$f"
ok "both present -> present"            rc_context_file_exists_at "$f" master
f="$(new_fixture)"; : >"$f/README.md"; commit_fixture "$f"
no "neither -> absent (blocked)"        rc_context_file_exists_at "$f" master

echo "== tick.sh preflight block message prefers AGENTS.md wording (igor#493) =="
ok "block message names AGENTS.md first, CLAUDE.md as legacy fallback" \
  grep -qF '\`AGENTS.md\` (or legacy \`CLAUDE.md\`) is missing at the repo root' "$HERE/tick.sh"

if [ "$FAIL" -eq 0 ]; then
  echo "test-repo-checks: all passed"
else
  echo "test-repo-checks: $FAIL failure(s)"
fi
exit "$FAIL"
