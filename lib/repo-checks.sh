#!/usr/bin/env bash
# repo-checks.sh -- repo-readiness checks. Sourced by bin/tick.sh (which
# decides which repos get agentic WORK) and bin/validate-repo.sh (the
# operator audit tool).
#
# All checks read a LOCAL fetched clone at origin/<default-branch> -- never
# the working tree, never the Forgejo API. The tick clones every accessible
# repo up front (ensure_repo_local) and validates that clone. Reading a git
# clone is all-or-nothing, so one file's read can't blip and look "absent" --
# the old per-file API failure mode that filed bogus "not ready" tickets on
# healthy repos. If no clone can be read at all (a fetch failed before any
# clone landed), rc_local_init returns indeterminate and the repo is skipped +
# retried; an existing clone whose refresh-fetch failed validates its
# last-fetched state (stale-but-valid on purpose -- readiness barely changes
# tick-to-tick, and the WORK step re-fetches before acting). Onboarding is now
# a manual, ~1-minute operator step; a repo that isn't ready is simply skipped
# for work, silently -- run `bin/validate-repo.sh <repo>` to see what's missing.
#
# Requires lib/forgejo.sh sourced first (for repo enumeration in the --all
# path of validate-repo.sh; the checks themselves are pure git reads).

# Fallback logger so this module is sourceable outside tick.sh. When sourced
# into tick.sh, bash's dynamic function lookup picks up tick's richer
# definition at call time.
if ! declare -F log >/dev/null; then
  log() { printf '[agent] %s\n' "$*"; }
fi

# -- Local clone reader -----------------------------------------
#
# rc_local_init <clone-path> resolves the default-branch ref ONCE; the
# check_* helpers below read files/dirs from it. Returns non-zero when the
# clone is missing or its refs are unreadable (the fetch likely failed) --
# the caller MUST treat that as INDETERMINATE and skip the repo for this tick,
# never as a check failure.

_RC_REPO_PATH=""   # the initialised clone
_RC_REF=""         # origin/<default-branch>, e.g. origin/master

rc_local_init() {
  local path="$1" head
  [ -n "$path" ] && [ -d "$path/.git" ] || return 1
  _RC_REPO_PATH="$path"
  # Default branch via origin/HEAD; fall back to master/main if it isn't set
  # (a fetch-only clone may not carry the symbolic ref).
  head=$(git -C "$path" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || head=""
  if [ -z "$head" ]; then
    if   git -C "$path" rev-parse --verify -q refs/remotes/origin/master >/dev/null 2>&1; then head="origin/master"
    elif git -C "$path" rev-parse --verify -q refs/remotes/origin/main   >/dev/null 2>&1; then head="origin/main"
    else return 1; fi
  fi
  _RC_REF="$head"
  git -C "$path" rev-parse --verify -q "$_RC_REF" >/dev/null 2>&1 || return 1
}

# Read helpers, all scoped to _RC_REF on the initialised clone.
# rc_file_read / rc_dir_list print empty (never fail) on absence so callers
# gate on content; rc_file_exists is the boolean existence test.
rc_file_exists() { git -C "$_RC_REPO_PATH" cat-file -e "${_RC_REF}:$1" 2>/dev/null; }
rc_file_read()   { git -C "$_RC_REPO_PATH" show     "${_RC_REF}:$1" 2>/dev/null || true; }
rc_dir_list()    { git -C "$_RC_REPO_PATH" ls-tree --name-only "${_RC_REF}:$1" 2>/dev/null || true; }

# -- Individual checks ------------------------------------------
#
# Each returns 0 on pass, non-zero on fail. Pure reads of the initialised
# clone -- no logging, no API calls.

check_claude_md() { rc_file_exists CLAUDE.md; }

check_readme() {
  local f
  for f in README.md README.rst README.txt README readme.md; do
    rc_file_exists "$f" && return 0
  done
  return 1
}

check_test_signal() {
  # package.json with a REAL "test" script -- reject the failing npm default
  # stub (`echo "Error: no test specified" && exit 1`), which is a test setup
  # in name only.
  local pkg t pyproject makefile
  pkg=$(rc_file_read package.json)
  if [ -n "$pkg" ]; then
    t=$(jq -r '.scripts.test // empty' <<<"$pkg" 2>/dev/null)
    [ -n "$t" ] && ! grep -qiF 'no test specified' <<<"$t" && return 0
  fi
  # pytest config (own file or pyproject section)
  rc_file_exists pytest.ini && return 0
  pyproject=$(rc_file_read pyproject.toml)
  [ -n "$pyproject" ] && grep -qE '^\[tool\.pytest' <<<"$pyproject" && return 0
  # Makefile with a test target
  makefile=$(rc_file_read Makefile)
  [ -n "$makefile" ] && grep -qE '^test[[:space:]]*:' <<<"$makefile" && return 0
  # Cargo / Go projects -- test runners are implicit
  rc_file_exists Cargo.toml && return 0
  rc_file_exists go.mod && return 0
  return 1
}

check_lint_signal() {
  local f pkg pyproject cargo
  # ESLint variants
  for f in .eslintrc.json .eslintrc.js .eslintrc.cjs .eslintrc.yml \
           .eslintrc.yaml .eslintrc eslint.config.js eslint.config.mjs \
           eslint.config.cjs; do
    rc_file_exists "$f" && return 0
  done
  pkg=$(rc_file_read package.json)
  [ -n "$pkg" ] && jq -e '.eslintConfig // empty' <<<"$pkg" >/dev/null 2>&1 && return 0

  # Markdownlint
  for f in .markdownlint.json .markdownlint.yaml .markdownlint.yml \
           .markdownlint-cli2.jsonc; do
    rc_file_exists "$f" && return 0
  done

  # Stylelint
  for f in .stylelintrc .stylelintrc.json .stylelintrc.js stylelint.config.js; do
    rc_file_exists "$f" && return 0
  done

  # Python linters (own file or pyproject section)
  for f in .flake8 .pylintrc; do
    rc_file_exists "$f" && return 0
  done
  pyproject=$(rc_file_read pyproject.toml)
  [ -n "$pyproject" ] && grep -qE '^\[tool\.(ruff|black|flake8|pylint|mypy)' <<<"$pyproject" && return 0

  # Go
  for f in .golangci.yml .golangci.yaml; do
    rc_file_exists "$f" && return 0
  done

  # Rust clippy (own file or Cargo.toml lints section)
  rc_file_exists clippy.toml && return 0
  cargo=$(rc_file_read Cargo.toml)
  [ -n "$cargo" ] && grep -qE '^\[lints' <<<"$cargo" && return 0

  # Shell
  rc_file_exists .shellcheckrc && return 0

  return 1
}

check_ci_workflow() {
  # A REAL CI workflow must run ON pull_request AND actually verify the change
  # (a build/test/lint step) -- a deploy-only workflow (push:master + rsync)
  # doesn't. Read each workflow file and require BOTH signals.
  local dir f content listing
  for dir in .forgejo/workflows .gitea/workflows; do
    listing=$(rc_dir_list "$dir")
    [ -n "$listing" ] || continue
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      [[ "$f" =~ \.ya?ml$ ]] || continue
      content=$(rc_file_read "${dir}/${f}")
      [ -n "$content" ] || continue
      grep -q 'pull_request' <<<"$content" || continue
      grep -qiE 'test|lint|build|dry-?run|eleventy|pytest|cargo|go test|npm (ci|run|test)|markdownlint|shellcheck' \
        <<<"$content" && return 0
    done <<<"$listing"
  done
  return 1
}

# -- Main validator ---------------------------------------------
#
# validate_repo_local <repo-label> <clone-path>
#
# Runs all checks against the fetched clone and prints a markdown checklist
# (safe to drop into an issue body or print for the operator). Returns:
#   0 -- every required check passed; the repo is ready for agentic WORK
#   1 -- one or more checks FAILED; the repo genuinely lacks scaffolding and
#        is skipped for work this tick, SILENTLY (no ticket is filed --
#        onboarding is a manual operator step)
#   2 -- INDETERMINATE: the clone is missing or its refs are unreadable (the
#        fetch likely failed), so no check actually ran -- skip and retry.
#
# <repo-label> keeps the call signature self-documenting -- callers already
# print it in their own header (bin/validate-repo.sh, tick.sh) and the
# checklist body never needs it.
validate_repo_local() {
  # shellcheck disable=SC2034  # repo is signature-only, see above.
  local repo="$1" path="$2" fail=0

  _emit() {
    # _emit <status> <name> <hint>
    if [ "$1" -eq 0 ]; then
      printf -- '- [x] %s\n' "$2"
    else
      printf -- '- [ ] %s -- %s\n' "$2" "$3"
      fail=$((fail + 1))
    fi
  }

  if ! rc_local_init "$path"; then
    printf 'validation indeterminate: no readable clone at %s -- the fetch may have failed; skipping this tick\n' "$path"
    return 2
  fi

  check_claude_md
  _emit $? "CLAUDE.md present at repo root" \
    "add \`CLAUDE.md\` with project conventions (test commands, code style, gotchas)"

  check_readme
  _emit $? "README present at repo root" \
    "add a README (\`README.md\` / \`.rst\` / \`.txt\` / no-ext all accepted)"

  check_test_signal
  _emit $? "Test setup detected" \
    "add a way to run tests: \`\"test\"\` script in package.json, \`pytest.ini\`, \`[tool.pytest]\` in pyproject.toml, \`test:\` target in Makefile, or use a Cargo/Go project (implicit)"

  check_lint_signal
  _emit $? "Lint setup detected" \
    "add a linter config: \`.eslintrc*\`, \`.markdownlint*\`, \`.stylelintrc*\`, \`.flake8\`, \`[tool.ruff]\` in pyproject.toml, \`.golangci.yml\`, Cargo \`[lints]\`, \`.shellcheckrc\`"

  check_ci_workflow
  _emit $? "CI workflow present" \
    "add a Forgejo Actions workflow at \`.forgejo/workflows/<name>.yml\` that runs on \`pull_request\` and executes lint + tests"

  [ "$fail" -eq 0 ]
}
