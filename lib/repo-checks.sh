#!/usr/bin/env bash
# repo-checks.sh -- repo-readiness checks + onboarding ticket lifecycle.
# Sourced by bin/tick.sh (gates the clone) and bin/validate-repo.sh
# (operator audit tool). All checks run via the Forgejo API; no clone
# is required.
#
# Requires lib/forgejo.sh sourced first.

# Fallback logger so this module is sourceable outside tick.sh. When
# sourced into tick.sh, bash's dynamic function lookup picks up tick's
# richer definition at call time.
if ! declare -F log >/dev/null; then
  log() { printf '[agent] %s\n' "$*"; }
fi

# -- Individual checks ------------------------------------------
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

# Returns 0 if all four labels the agent uses exist on the repo, 1 if any
# are missing. Prints a comma-separated list of missing labels to
# stdout (empty on full pass), so the orchestrator can include the
# specifics in the onboarding ticket.
check_labels() {
  local repo="$1" name missing=""
  for name in "Agent" "Status/Blocked" "Status/Need More Info" "Priority/Critical"; do
    if ! forgejo_repo_has_label "$repo" "$name"; then
      missing="${missing:+$missing, }\`$name\`"
    fi
  done
  printf '%s' "$missing"
  [ -z "$missing" ]
}

# -- Main validator ---------------------------------------------
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

  local labels_missing
  labels_missing=$(check_labels "$repo")
  if [ -z "$labels_missing" ]; then
    _emit 0 "Required labels present (Agent, Status/Blocked, Status/Need More Info, Priority/Critical)" ""
  else
    _emit 1 "Required labels present" \
      "create missing label(s): ${labels_missing} -- the Status/* and Priority/* labels come from Forgejo's Advanced label template (Settings -> Labels -> load template); the \`Agent\` label is custom"
  fi

  [ "$fail" -eq 0 ]
}

# -- Onboarding ticket lifecycle --------------------------------
#
# Filed when a repo fails validation, closed by the human when fixed,
# reopened on re-validation failure. The marker keeps it auto-
# discoverable across ticks without needing a title prefix.

ONBOARDING_MARKER='<!-- agent:onboarding -->'

# handle_onboarding_failure <repo> <bot-user> <markdown-report>
#
# Idempotent: existing open ticket -> silent skip; existing closed
# ticket and still failing -> reopen with updated checklist; nothing
# -> file fresh.
handle_onboarding_failure() {
  local repo="$1" bot="$2" report="$3"

  local body
  body=$(cat <<EOF
${ONBOARDING_MARKER}

The agent refuses to clone this repo until it has the scaffolding to support
unattended work. Required checks:

${report}

Bring the repo to standard, then close this ticket -- the next tick will
re-validate and either proceed or reopen this with what's still missing.

This ticket is auto-managed by the agent. Do not edit the title or remove the
HTML comment marker at the top of the body.
EOF
)

  local existing num state
  existing=$(forgejo_find_marked_issue "$repo" "$bot" "$ONBOARDING_MARKER")

  if [ -z "$existing" ] || [ "$existing" = "null" ] || [ "$existing" = "empty" ]; then
    log "onboarding: filing fresh ticket on $repo"
    num=$(forgejo_open_issue "$repo" "Repo not ready for the agent: missing scaffolding" "$body")
    forgejo_add_label "$repo" "$num" "Status/Need More Info" 2>/dev/null \
      || log "warning: could not apply 'Status/Need More Info' on $repo (label missing?)"
    forgejo_add_label "$repo" "$num" "Priority/Critical" 2>/dev/null \
      || log "warning: could not apply 'Priority/Critical' on $repo (label missing?)"
    return
  fi

  num=$(jq -r '.number' <<<"$existing")
  state=$(jq -r '.state' <<<"$existing")

  if [ "$state" = "open" ]; then
    log "onboarding: existing open ticket #${num} on $repo, skipping silently"
    return
  fi

  log "onboarding: re-validation failed on $repo, reopening #${num}"
  forgejo_comment "$repo" "$num" \
"Re-validation still failing. Updated checklist:

${report}"
  forgejo_reopen_issue "$repo" "$num"
}
