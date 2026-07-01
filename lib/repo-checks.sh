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

# -- Auto-scaffold agent-authorable gaps (igor#304) -------------
#
# When a repo fails onboarding on gaps the AGENT can author -- CLAUDE.md,
# a package.json "test" script, a lint config -- open a scaffold PR
# instead of dumping the whole setup on the human. Additive and fully
# GUARDED: unrecognized stack or any API failure returns empty and
# handle_onboarding_failure falls through to the plain ticket, so worst
# case is exactly the pre-#304 behavior. CI (.forgejo/workflows/) is
# off-limits to the agent and stays a human residual; README + labels
# aren't auto-scaffolded.

SCAFFOLD_BRANCH='agent-scaffold'

# scaffold_parse_gaps <report> -- echo the agent-authorable gaps still OPEN
# in the checklist, one per line, from {claude_md,test,lint}. Reads the
# '- [ ] <name> -- ...' failure lines validate_repo_via_api emits. Pure.
scaffold_parse_gaps() {
  local report="$1"
  grep -q '^- \[ \] CLAUDE\.md present'  <<<"$report" && printf 'claude_md\n'
  grep -q '^- \[ \] Test setup detected' <<<"$report" && printf 'test\n'
  grep -q '^- \[ \] Lint setup detected' <<<"$report" && printf 'lint\n'
  return 0
}

# scaffold_detect_stack <package_json> -- echo the recognized stack or empty.
# v1: 'eleventy' when package.json names eleventy in (dev)dependencies or an
# npm script. Empty -> caller bails to ticket-only. Pure.
scaffold_detect_stack() {
  local pkg="$1"
  [ -n "$pkg" ] || return 0
  if jq -e '((.dependencies // {}) + (.devDependencies // {})) | keys | any(test("eleventy|11ty"))' <<<"$pkg" >/dev/null 2>&1 \
     || jq -e '(.scripts // {}) | to_entries | any(.value | test("eleventy|11ty"))' <<<"$pkg" >/dev/null 2>&1; then
    printf 'eleventy\n'
  fi
  return 0
}

# scaffold_test_script <stack> -- echo the package.json "test" script value.
# 11ty: a clean dry-run build is the gate. Pure.
scaffold_test_script() {
  case "$1" in
    eleventy) printf 'npx @11ty/eleventy --dryrun' ;;
    *) return 0 ;;
  esac
}

# scaffold_markdownlint -- echo a lenient .markdownlint.json. Pure.
scaffold_markdownlint() {
  cat <<'JSON'
{
  "default": true,
  "MD013": false,
  "MD033": false,
  "MD041": false
}
JSON
}

# scaffold_claude_md <repo> <package_json> -- echo a templated CLAUDE.md from
# package.json (name/description). Deterministic v1. Pure. (Backtick-bearing
# body is a quoted heredoc; the dynamic header is printf'd so no command
# substitution fires.)
scaffold_claude_md() {
  local repo="$1" pkg="$2" name desc
  name=$(jq -r '.name // empty' <<<"$pkg" 2>/dev/null); [ -n "$name" ] || name="${repo##*/}"
  desc=$(jq -r '.description // empty' <<<"$pkg" 2>/dev/null); [ -n "$desc" ] || desc="Static site built with Eleventy."
  printf '# %s\n\n%s\n\n' "$name" "$desc"
  cat <<'EOF'
## Build & test

```sh
npm ci
npm run build   # if defined
npm test        # a clean Eleventy dry-run build is the gate
```

## Conventions

- Eleventy input lives under `src/`; the build writes `_site/` (generated -- don't edit by hand).
- Keep changes small and scoped; everything ships via a reviewed PR to the default branch.
- Markdown is linted (`.markdownlint.json`); long prose lines are fine (MD013 off).

## Off-limits

- `.forgejo/workflows/` -- CI is operator-managed.
- Secrets, `.env`, and the live deploy host.

_Scaffolded by the agent (igor#304); refine as the project grows._
EOF
}

# scaffold_pr_body <newline-separated-gaps> -- echo the scaffold PR body. Pure.
scaffold_pr_body() {
  local gaps="$1"
  printf '## What this PR does\n\n'
  printf -- '- [x] chore: scaffold agent-authorable repo setup so the repo can validate\n\n'
  printf 'The onboarding checks flagged scaffolding the **agent** can author. Added:\n\n'
  grep -qx claude_md <<<"$gaps" && printf -- '- `CLAUDE.md` -- project orientation for the agent\n'
  grep -qx lint      <<<"$gaps" && printf -- '- `.markdownlint.json` -- lenient markdown lint config\n'
  grep -qx test      <<<"$gaps" && printf -- '- `package.json` `test` script -- a clean Eleventy dry-run build\n'
  printf '\nStill on the human: CI (`.forgejo/workflows/`) is off-limits to the agent -- add it (and merge this) to finish onboarding.\n\n'
  printf '## Test plan\n\n'
  printf -- '- [x] `npm test` is a clean Eleventy dry-run build (the validation gate)\n'
  printf -- '- [ ] Reviewer: merge, then confirm the repo validates (or add the CI workflow if none exists)\n'
}

# _scaffold_put <repo> <path> <content> <sha> -- PUT a file onto the scaffold
# branch (create when sha empty, update when set). Impure.
_scaffold_put() {
  local repo="$1" path="$2" content="$3" sha="$4" b64 body
  b64=$(printf '%s' "$content" | base64 -w0) || return 1
  if [ -n "$sha" ]; then
    body=$(jq -n --arg m "chore: scaffold ${path} (igor#304)" --arg c "$b64" --arg s "$sha" --arg br "$SCAFFOLD_BRANCH" \
      '{message:$m, content:$c, sha:$s, branch:$br}')
  else
    body=$(jq -n --arg m "chore: scaffold ${path} (igor#304)" --arg c "$b64" --arg br "$SCAFFOLD_BRANCH" \
      '{message:$m, content:$c, branch:$br}')
  fi
  _fj PUT "/repos/${repo}/contents/${path}" "$body" >/dev/null
}

# scaffold_try_open_pr <repo> <report> -- open (or reuse) the scaffold PR for
# the agent-authorable gaps. Echoes the PR number on success, empty on any
# reason to fall through (no agent-doable gaps, unrecognized stack, a
# mid-scaffold branch already present, or any API failure). Impure + guarded;
# idempotent (an already-open scaffold PR is reused, never duplicated).
scaffold_try_open_pr() {
  local repo="$1" report="$2"
  local gaps stack pkg base existing wrote=0

  gaps=$(scaffold_parse_gaps "$report")
  [ -n "$gaps" ] || return 0

  pkg=$(forgejo_repo_get_file "$repo" package.json 2>/dev/null) || pkg=""
  stack=$(scaffold_detect_stack "$pkg")
  [ -n "$stack" ] || return 0

  # Idempotency: reuse an already-open scaffold PR.
  existing=$(forgejo_find_pr_by_head "$repo" "$SCAFFOLD_BRANCH" 2>/dev/null || true)
  if [ -n "$existing" ]; then printf '%s' "$existing"; return 0; fi
  # A leftover scaffold branch with no open PR (crash mid-scaffold) -- don't
  # recreate it; skip to ticket-only this tick.
  if _fj GET "/repos/${repo}/branches/${SCAFFOLD_BRANCH}" >/dev/null 2>&1; then
    return 0
  fi

  base=$(_fj GET "/repos/${repo}" 2>/dev/null | jq -r '.default_branch // "master"') || base="master"
  [ -n "$base" ] || base="master"

  # Create the scaffold branch off the default branch, then PUT each file
  # onto it (uniform branch target -- no first-PUT special-casing).
  _fj POST "/repos/${repo}/branches" \
    "$(jq -n --arg n "$SCAFFOLD_BRANCH" --arg o "$base" '{new_branch_name:$n, old_ref_name:$o}')" >/dev/null 2>&1 || return 0

  if grep -qx claude_md <<<"$gaps"; then
    _scaffold_put "$repo" "CLAUDE.md" "$(scaffold_claude_md "$repo" "$pkg")" "" && wrote=1
  fi
  if grep -qx lint <<<"$gaps"; then
    _scaffold_put "$repo" ".markdownlint.json" "$(scaffold_markdownlint)" "" && wrote=1
  fi
  if grep -qx test <<<"$gaps"; then
    local ts newpkg pkgsha
    ts=$(scaffold_test_script "$stack")
    newpkg=$(jq --arg t "$ts" '.scripts = ((.scripts // {}) + {test: $t})' <<<"$pkg" 2>/dev/null) || newpkg=""
    pkgsha=$(_fj GET "/repos/${repo}/contents/package.json?ref=${SCAFFOLD_BRANCH}" 2>/dev/null | jq -r '.sha // empty')
    if [ -n "$ts" ] && [ -n "$newpkg" ] && [ -n "$pkgsha" ]; then
      _scaffold_put "$repo" "package.json" "$newpkg" "$pkgsha" && wrote=1
    fi
  fi

  [ "$wrote" -eq 1 ] || return 0

  # Open UNASSIGNED: the repo is unvalidated, so the shadow-review tick
  # skips it -- surfacing rides on the onboarding ticket (assigned to the
  # reviewer) which links this PR, rather than a review request here.
  local prnum
  prnum=$(forgejo_open_pr "$repo" "$SCAFFOLD_BRANCH" "$base" \
    "chore: scaffold agent-authorable repo setup (igor#304)" \
    "$(scaffold_pr_body "$gaps")" 2>/dev/null) || return 0
  printf '%s' "$prnum"
}

# handle_onboarding_failure <repo> <bot-user> <markdown-report>
#
# Idempotent: existing open ticket -> silent skip; existing closed
# ticket and still failing -> reopen with updated checklist; nothing
# -> file fresh.
handle_onboarding_failure() {
  local repo="$1" bot="$2" report="$3"

  # igor#304: try to auto-scaffold the agent-authorable gaps first. On
  # success the ticket is narrowed to the human residual (CI); on any
  # failure scaffold_pr is empty and we file the full ticket as before.
  local scaffold_pr=""
  scaffold_pr=$(scaffold_try_open_pr "$repo" "$report" 2>/dev/null) || scaffold_pr=""
  [ -n "$scaffold_pr" ] && log "onboarding: scaffold PR #${scaffold_pr} open on $repo (agent-authorable gaps)"

  local body
  if [ -n "$scaffold_pr" ]; then
    body=$(cat <<EOF
${ONBOARDING_MARKER}

The agent scaffolded the setup it can author in **PR #${scaffold_pr}** (CLAUDE.md /
test / lint, as applicable). Review and merge it, then add anything only you can --
notably the CI workflow (\`.forgejo/workflows/\`), which is off-limits to the agent.
Current checklist:

${report}

Once the rest is in, close this ticket -- the next tick re-validates and either
proceeds or reopens with what's still missing.

This ticket is auto-managed by the agent. Do not edit the title or remove the
HTML comment marker at the top of the body.
EOF
)
  else
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
  fi

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
