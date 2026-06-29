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

# -- Per-repo fetch cache ---------------------------------------
#
# The checks below would otherwise hit the Forgejo API once per
# candidate file (~25 GETs) and once per required label (4 GETs) per
# repo per tick. Instead rc_cache_init does ONE root-contents listing
# and ONE labels listing up front, and the checks consult those in
# memory. The few files whose CONTENT (not just existence) is inspected
# are fetched once each, only when present at the root.
#
# rc_cache_init <repo> MUST run before any check_* -- it does, at the
# top of validate_repo_via_api, which is the only entry point.

_RC_ROOT_NAMES=""    # newline-separated names of root entries (files + dirs)
_RC_LABELS=""        # newline-separated label names
_RC_PACKAGE_JSON=""  # root files whose content we inspect; fetched once if present
_RC_PYPROJECT=""
_RC_MAKEFILE=""
_RC_CARGO=""

# Whole-line fixed-string membership tests against the cached listings.
rc_root_has()  { grep -qxF "$1" <<<"$_RC_ROOT_NAMES"; }
rc_has_label() { grep -qxF "$1" <<<"$_RC_LABELS"; }

# Returns non-zero when any underlying API call fails -- the caller
# must treat that as INDETERMINATE (can't read the repo right now),
# never as a check failure. Before this distinction existed, one
# Forgejo hiccup emptied the cache, failed every check at once, and
# filed a bogus onboarding ticket on a healthy repo -- which then
# short-circuited validation until a human closed it.
rc_cache_init() {
  local repo="$1" root_json labels_json
  root_json=$(forgejo_repo_list_root "$repo") || return 1
  labels_json=$(forgejo_list_labels "$repo") || return 1
  _RC_ROOT_NAMES=$(jq -r '.[]' <<<"$root_json" 2>/dev/null)
  _RC_LABELS=$(jq -r '.[]' <<<"$labels_json" 2>/dev/null)
  _RC_PACKAGE_JSON=""; _RC_PYPROJECT=""; _RC_MAKEFILE=""; _RC_CARGO=""
  if rc_root_has package.json;   then _RC_PACKAGE_JSON=$(forgejo_repo_get_file "$repo" package.json)   || return 1; fi
  if rc_root_has pyproject.toml; then _RC_PYPROJECT=$(forgejo_repo_get_file "$repo" pyproject.toml)    || return 1; fi
  if rc_root_has Makefile;       then _RC_MAKEFILE=$(forgejo_repo_get_file "$repo" Makefile)           || return 1; fi
  if rc_root_has Cargo.toml;     then _RC_CARGO=$(forgejo_repo_get_file "$repo" Cargo.toml)            || return 1; fi
}

# -- Individual checks ------------------------------------------
#
# Each returns 0 on pass, non-zero on fail. Pure reads of the per-repo
# cache (rc_cache_init) -- no logging, no API calls. check_ci_workflow
# is the one exception: workflow dirs aren't at the root, so it still
# does a (guarded) directory listing.

check_claude_md() { rc_root_has CLAUDE.md; }

check_readme() {
  local f
  for f in README.md README.rst README.txt README readme.md; do
    rc_root_has "$f" && return 0
  done
  return 1
}

check_test_signal() {
  # package.json with a "test" script
  [ -n "$_RC_PACKAGE_JSON" ] && jq -e '.scripts.test // empty' <<<"$_RC_PACKAGE_JSON" >/dev/null 2>&1 && return 0
  # pytest config (own file or pyproject section)
  rc_root_has pytest.ini && return 0
  [ -n "$_RC_PYPROJECT" ] && grep -qE '^\[tool\.pytest' <<<"$_RC_PYPROJECT" && return 0
  # Makefile with a test target
  [ -n "$_RC_MAKEFILE" ] && grep -qE '^test[[:space:]]*:' <<<"$_RC_MAKEFILE" && return 0
  # Cargo / Go projects -- test runners are implicit
  rc_root_has Cargo.toml && return 0
  rc_root_has go.mod && return 0
  return 1
}

check_lint_signal() {
  local f
  # ESLint variants
  for f in .eslintrc.json .eslintrc.js .eslintrc.cjs .eslintrc.yml \
           .eslintrc.yaml .eslintrc eslint.config.js eslint.config.mjs \
           eslint.config.cjs; do
    rc_root_has "$f" && return 0
  done
  [ -n "$_RC_PACKAGE_JSON" ] && jq -e '.eslintConfig // empty' <<<"$_RC_PACKAGE_JSON" >/dev/null 2>&1 && return 0

  # Markdownlint
  for f in .markdownlint.json .markdownlint.yaml .markdownlint.yml \
           .markdownlint-cli2.jsonc; do
    rc_root_has "$f" && return 0
  done

  # Stylelint
  for f in .stylelintrc .stylelintrc.json .stylelintrc.js stylelint.config.js; do
    rc_root_has "$f" && return 0
  done

  # Python linters (own file or pyproject section)
  for f in .flake8 .pylintrc; do
    rc_root_has "$f" && return 0
  done
  [ -n "$_RC_PYPROJECT" ] && grep -qE '^\[tool\.(ruff|black|flake8|pylint|mypy)' <<<"$_RC_PYPROJECT" && return 0

  # Go
  for f in .golangci.yml .golangci.yaml; do
    rc_root_has "$f" && return 0
  done

  # Rust clippy (own file or Cargo.toml lints section)
  rc_root_has clippy.toml && return 0
  [ -n "$_RC_CARGO" ] && grep -qE '^\[lints' <<<"$_RC_CARGO" && return 0

  # Shell
  rc_root_has .shellcheckrc && return 0

  return 1
}

check_ci_workflow() {
  local repo="$1" dir
  for dir in .forgejo/workflows .gitea/workflows; do
    # workflow dirs live under a dotdir; skip the listing when that
    # parent isn't even present at the root.
    rc_root_has "${dir%%/*}" || continue
    forgejo_repo_dir_has_match "$repo" "$dir" '\.ya?ml$' && return 0
  done
  return 1
}

# Returns 0 if all four labels the agent uses exist on the repo, 1 if any
# are missing. Prints a comma-separated list of missing labels to
# stdout (empty on full pass), so the orchestrator can include the
# specifics in the onboarding ticket.
check_labels() {
  local name missing=""
  for name in "Agent" "Status/Blocked" "Status/Need More Info" "Priority/Critical"; do
    if ! rc_has_label "$name"; then
      missing="${missing:+$missing, }\`$name\`"
    fi
  done
  printf '%s' "$missing"
  [ -z "$missing" ]
}

# -- Main validator ---------------------------------------------
#
# Runs all checks, prints a markdown checklist to stdout. Returns:
#   0 -- every required check passed
#   1 -- one or more checks definitively FAILED (file/reopen the
#        onboarding ticket; the repo really is missing scaffolding)
#   2 -- INDETERMINATE: the Forgejo API errored while reading the
#        repo, so no check result is trustworthy. Do NOT file a
#        ticket; skip the repo for work this tick and re-check next
#        tick (failures are never cached).
# The checklist is safe to drop straight into an issue body.

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

  if ! rc_cache_init "$repo"; then
    printf 'validation indeterminate: the Forgejo API errored while reading the repo -- no check was actually evaluated\n'
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

  check_ci_workflow "$repo"
  _emit $? "CI workflow present" \
    "add a Forgejo Actions workflow at \`.forgejo/workflows/<name>.yml\` that runs lint + tests"

  local labels_missing
  labels_missing=$(check_labels)
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
    # Onboarding is a human ticket -- the repo needs scaffolding only the operator
    # can add -- so assign the reviewer to surface it in their queue.
    forgejo_assign "$repo" "$num" "$FORGEJO_REVIEWER" 2>/dev/null \
      || log "warning: could not assign onboarding ticket on $repo to $FORGEJO_REVIEWER"
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
