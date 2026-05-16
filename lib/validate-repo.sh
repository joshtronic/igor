#!/usr/bin/env bash
# validate-repo.sh -- onboarding health checks for a Forgejo repo.
# Sourced by bin/tick.sh (gates the clone) and bin/validate-repo.sh
# (operator audit tool). All checks run via the Forgejo API; no clone
# is required.
#
# Requires lib/forgejo.sh sourced first.

# ── Individual checks ──────────────────────────────────────────
#
# Each returns 0 on pass, non-zero on fail. Pure -- no logging, no
# side effects beyond the API GET they perform.

check_claude_md() {
  forgejo_repo_file_exists "$1" "CLAUDE.md"
}

check_readme() {
  local repo="$1" f
  for f in README.md README.rst README.txt README readme.md; do
    forgejo_repo_file_exists "$repo" "$f" && return 0
  done
  return 1
}

check_test_signal() {
  local repo="$1" content

  # package.json with a "test" script
  content=$(forgejo_repo_get_file "$repo" "package.json")
  [ -n "$content" ] && jq -e '.scripts.test // empty' <<<"$content" >/dev/null 2>&1 && return 0

  # pytest config (own file or pyproject section)
  forgejo_repo_file_exists "$repo" "pytest.ini" && return 0
  content=$(forgejo_repo_get_file "$repo" "pyproject.toml")
  [ -n "$content" ] && echo "$content" | grep -qE '^\[tool\.pytest' && return 0

  # Makefile with a test target
  content=$(forgejo_repo_get_file "$repo" "Makefile")
  [ -n "$content" ] && echo "$content" | grep -qE '^test[[:space:]]*:' && return 0

  # Cargo / Go projects -- test runners are implicit
  forgejo_repo_file_exists "$repo" "Cargo.toml" && return 0
  forgejo_repo_file_exists "$repo" "go.mod" && return 0

  return 1
}

check_lint_signal() {
  local repo="$1" content f

  # ESLint variants
  for f in .eslintrc.json .eslintrc.js .eslintrc.cjs .eslintrc.yml \
           .eslintrc.yaml .eslintrc eslint.config.js eslint.config.mjs \
           eslint.config.cjs; do
    forgejo_repo_file_exists "$repo" "$f" && return 0
  done
  content=$(forgejo_repo_get_file "$repo" "package.json")
  [ -n "$content" ] && jq -e '.eslintConfig // empty' <<<"$content" >/dev/null 2>&1 && return 0

  # Markdownlint
  for f in .markdownlint.json .markdownlint.yaml .markdownlint.yml \
           .markdownlint-cli2.jsonc; do
    forgejo_repo_file_exists "$repo" "$f" && return 0
  done

  # Stylelint
  for f in .stylelintrc .stylelintrc.json .stylelintrc.js stylelint.config.js; do
    forgejo_repo_file_exists "$repo" "$f" && return 0
  done

  # Python linters (own file or pyproject section)
  for f in .flake8 .pylintrc; do
    forgejo_repo_file_exists "$repo" "$f" && return 0
  done
  content=$(forgejo_repo_get_file "$repo" "pyproject.toml")
  [ -n "$content" ] && echo "$content" | grep -qE '^\[tool\.(ruff|black|flake8|pylint|mypy)' && return 0

  # Go
  for f in .golangci.yml .golangci.yaml; do
    forgejo_repo_file_exists "$repo" "$f" && return 0
  done

  # Rust clippy (own file or Cargo.toml lints section)
  forgejo_repo_file_exists "$repo" "clippy.toml" && return 0
  content=$(forgejo_repo_get_file "$repo" "Cargo.toml")
  [ -n "$content" ] && echo "$content" | grep -qE '^\[lints' && return 0

  # Shell
  forgejo_repo_file_exists "$repo" ".shellcheckrc" && return 0

  return 1
}

check_ci_workflow() {
  local repo="$1" dir
  for dir in .forgejo/workflows .gitea/workflows; do
    forgejo_repo_dir_has_match "$repo" "$dir" '\.ya?ml$' && return 0
  done
  return 1
}

# ── Main validator ─────────────────────────────────────────────
#
# Runs all checks, prints a markdown checklist to stdout, returns 0
# if every required check passed, 1 if any failed. The checklist is
# safe to drop straight into an issue body.

validate_repo_via_api() {
  local repo="$1"
  local fail=0

  _emit() {
    # _emit <status> <name> <hint>
    if [ "$1" -eq 0 ]; then
      printf -- '- [x] %s\n' "$2"
    else
      printf -- '- [ ] %s -- %s\n' "$2" "$3"
      fail=$((fail + 1))
    fi
  }

  check_claude_md "$repo"
  _emit $? "CLAUDE.md present at repo root" \
    "add \`CLAUDE.md\` with project conventions (test commands, code style, gotchas)"

  check_readme "$repo"
  _emit $? "README present at repo root" \
    "add a README (\`README.md\` / \`.rst\` / \`.txt\` / no-ext all accepted)"

  check_test_signal "$repo"
  _emit $? "Test setup detected" \
    "add a way to run tests: \`\"test\"\` script in package.json, \`pytest.ini\`, \`[tool.pytest]\` in pyproject.toml, \`test:\` target in Makefile, or use a Cargo/Go project (implicit)"

  check_lint_signal "$repo"
  _emit $? "Lint setup detected" \
    "add a linter config: \`.eslintrc*\`, \`.markdownlint*\`, \`.stylelintrc*\`, \`.flake8\`, \`[tool.ruff]\` in pyproject.toml, \`.golangci.yml\`, Cargo \`[lints]\`, \`.shellcheckrc\`"

  check_ci_workflow "$repo"
  _emit $? "CI workflow present" \
    "add a Forgejo Actions workflow at \`.forgejo/workflows/<name>.yml\` that runs lint + tests"

  [ "$fail" -eq 0 ]
}
