#!/usr/bin/env bash
# maintenance-checks.sh -- harness-side stack detection + audit tool
# dispatch for the weekly maintenance pass. Runs the mechanical part
# (npm audit, cargo audit, pip-audit, etc.) so Claude is only invoked
# when there's something to interpret.
#
# Requires bash; sourced by bin/tick.sh.

# Fallback logger so this module is sourceable outside tick.sh.
if ! declare -F log >/dev/null; then
  log() { printf '[agent] %s\n' "$*"; }
fi

# -- Stack detection --------------------------------------------
#
# Echoes one stack name per line for every manifest detected at
# repo_path's root. Stacks: npm, cargo, pip, go, bundle.

detect_stacks() {
  local repo_path="$1"
  [ -f "$repo_path/package.json" ] && echo npm
  [ -f "$repo_path/Cargo.toml" ] && echo cargo
  { [ -f "$repo_path/pyproject.toml" ] || [ -f "$repo_path/requirements.txt" ]; } && echo pip
  [ -f "$repo_path/go.mod" ] && echo go
  [ -f "$repo_path/Gemfile" ] && echo bundle
  return 0
}

# -- Tool availability ------------------------------------------
#
# ensure_audit_tool <tool> <install-cmd>
#
# Returns 0 if the tool is available (already on PATH or successfully
# installed). Returns 1 if missing AND install failed (e.g. base
# toolchain absent). Installs go to user-writable paths per the
# language's default -- no sudo.

ensure_audit_tool() {
  local tool="$1" install_cmd="$2"
  command -v "$tool" >/dev/null 2>&1 && return 0
  log "maintenance: $tool missing, installing via: $install_cmd"
  if ! eval "$install_cmd" >/dev/null 2>&1; then
    log "maintenance: install of $tool failed (toolchain missing?), skipping"
    return 1
  fi
  command -v "$tool" >/dev/null 2>&1
}

# -- Per-stack runners ------------------------------------------
#
# Each runner:
#   - takes <repo_path> <out_dir>
#   - writes the tool's raw output to <out_dir>/<stack>-<tool>.txt
#   - prints "clean" or "findings" on stdout for each tool checked
#
# "Clean" detection per tool is conservative: any ambiguity -> findings,
# so Claude gets to look at it. Better to spend a few cents on a
# false-positive interpretation than to miss a real vulnerability.

_run_npm() {
  local repo_path="$1" out_dir="$2"
  local audit_file="$out_dir/npm-audit.txt"
  local outdated_file="$out_dir/npm-outdated.txt"

  (cd "$repo_path" && npm audit 2>&1) > "$audit_file"
  local audit_rc=$?
  if [ "$audit_rc" -eq 0 ]; then echo "npm-audit:clean"; else echo "npm-audit:findings"; fi

  # npm outdated. We deliberately do NOT run `npm ci` -- the audit
  # runs in a throwaway worktree and installing deps is out of
  # scope. The catch: with no node_modules, `Current` is MISSING for
  # every package, so the plain-text output is non-empty even when
  # nothing is actually out of date -- which used to flag EVERY npm
  # repo as "findings" and burn an LLM triage pass to conclude
  # there's nothing to do.
  #
  # The real, codebase-actionable drift signal is Wanted != Latest:
  # the package.json range can't reach the latest release, so a
  # manifest bump is needed. Wanted == Latest means `npm ci` would
  # install the newest version as-is -- nothing to do, MISSING
  # current notwithstanding. So the verdict comes from the JSON
  # (Wanted vs Latest); the MISSING-current artifact never counts.
  local outdated_json
  outdated_json=$(cd "$repo_path" && npm outdated --json 2>/dev/null)
  [ -z "$outdated_json" ] && outdated_json='{}'

  # Human-readable table for the triage LLM/operator IF this ends up
  # a real finding, prefaced so neither re-derives the MISSING note.
  {
    echo "NOTE: this audit does not run 'npm ci', so node_modules is"
    echo "absent and the Current column reads MISSING for every"
    echo "package. That is a harness artifact, not a finding. Only"
    echo "rows where Wanted != Latest are real version drift (the"
    echo "package.json range cannot reach the latest release)."
    echo
    (cd "$repo_path" && npm outdated 2>&1) || true
  } > "$outdated_file"

  # Findings only if some package has Wanted != Latest. Empty / `{}`
  # JSON -> clean. Unparseable JSON -> findings (let the LLM look;
  # conservative, matching this module's any-ambiguity-is-findings
  # bias).
  local drift
  drift=$(printf '%s' "$outdated_json" | jq -r \
    '[to_entries[] | select(.value.wanted != .value.latest)] | length' 2>/dev/null)
  if [ -z "$drift" ]; then
    echo "npm-outdated:findings"
  elif [ "$drift" -eq 0 ]; then
    echo "npm-outdated:clean"
  else
    echo "npm-outdated:findings"
  fi
}

_run_cargo() {
  local repo_path="$1" out_dir="$2"
  local audit_file="$out_dir/cargo-audit.txt"
  local outdated_file="$out_dir/cargo-outdated.txt"

  if ensure_audit_tool cargo-audit "cargo install --quiet cargo-audit"; then
    (cd "$repo_path" && cargo audit 2>&1) > "$audit_file"
    if [ $? -eq 0 ]; then echo "cargo-audit:clean"; else echo "cargo-audit:findings"; fi
  else
    echo "cargo audit unavailable on this host" > "$audit_file"
    echo "cargo-audit:skipped"
  fi

  if ensure_audit_tool cargo-outdated "cargo install --quiet cargo-outdated"; then
    (cd "$repo_path" && cargo outdated 2>&1) > "$outdated_file"
    # cargo-outdated table rows look like "crate_name 1.0.0 ...".
    # No such rows -> clean (handles both "All dependencies are up to
    # date" and any future phrasing changes).
    if ! grep -qE "^[a-zA-Z0-9_-]+[[:space:]]+[0-9]" "$outdated_file"; then
      echo "cargo-outdated:clean"
    else
      echo "cargo-outdated:findings"
    fi
  else
    echo "cargo outdated unavailable on this host" > "$outdated_file"
    echo "cargo-outdated:skipped"
  fi
}

_run_pip() {
  local repo_path="$1" out_dir="$2"
  local audit_file="$out_dir/pip-audit.txt"
  local outdated_file="$out_dir/pip-outdated.txt"

  if ensure_audit_tool pip-audit "pip install --user --quiet pip-audit"; then
    (cd "$repo_path" && pip-audit 2>&1) > "$audit_file"
    if [ $? -eq 0 ]; then echo "pip-audit:clean"; else echo "pip-audit:findings"; fi
  else
    echo "pip-audit unavailable on this host" > "$audit_file"
    echo "pip-audit:skipped"
  fi

  (cd "$repo_path" && pip list --outdated 2>&1) > "$outdated_file"
  # pip list --outdated prints a header even when empty; "clean" means
  # only the header lines, no package rows. Header is two lines ending
  # with "----".
  if ! grep -qE "^[A-Za-z0-9_.-]+\s+[0-9]" "$outdated_file"; then
    echo "pip-outdated:clean"
  else
    echo "pip-outdated:findings"
  fi
}

_run_go() {
  local repo_path="$1" out_dir="$2"
  local audit_file="$out_dir/govulncheck.txt"
  local outdated_file="$out_dir/go-outdated.txt"

  # Pick how to invoke govulncheck. PREFER the repo's own pinned tool
  # (go.mod `tool` directive, Go 1.24+): `go tool` compiles the scanner
  # with the repo's selected toolchain, so it ALWAYS matches the repo's
  # Go version -- no host-level version juggling, no cross-repo drift
  # (a scanner built against an older stdlib can't parse newer source).
  #
  # Repos that haven't adopted the directive fall back to a global
  # install built with the toolchain the repo's own go.mod selects
  # (GOTOOLCHAIN=go1.X.Y, derived below) and invoked by absolute path,
  # so a stale distro binary on PATH (e.g. apt's, frozen at the distro
  # Go) can't shadow it. Last-ditch: a plain install with the default
  # toolchain.
  local -a gv=()
  local modjson
  modjson=$(cd "$repo_path" && go mod edit -json 2>/dev/null)
  if printf '%s' "$modjson" | jq -e '.Tool[]?.Path | select(endswith("/govulncheck"))' >/dev/null 2>&1; then
    gv=(go tool govulncheck)
  else
    # Normalize the repo's Go version to a full toolchain name. GOTOOLCHAIN
    # requires the patch (go1.26.2); a language version (go1.26) is rejected.
    local repo_go tc=""
    repo_go=$(printf '%s' "$modjson" | jq -r '.Toolchain // .Go // empty' 2>/dev/null)
    case "$repo_go" in
      go*)    tc="$repo_go" ;;        # already a toolchain name
      *.*.*)  tc="go$repo_go" ;;      # has patch    -> go1.26.2
      *.*)    tc="go${repo_go}.0" ;;  # language ver -> go1.26.0
    esac
    if [ -n "$tc" ] && GOTOOLCHAIN="$tc" go install golang.org/x/vuln/cmd/govulncheck@latest >/dev/null 2>&1; then
      gv=("$(go env GOPATH)/bin/govulncheck")
    elif go install golang.org/x/vuln/cmd/govulncheck@latest >/dev/null 2>&1; then
      gv=("$(go env GOPATH)/bin/govulncheck")
    fi
  fi

  if [ "${#gv[@]}" -eq 0 ]; then
    echo "govulncheck unavailable: no repo tool directive and global install failed" > "$audit_file"
    echo "govulncheck:skipped"
  else
    # Text-mode exit codes are unambiguous AND reachability-aware:
    #   0     = clean (uncalled stdlib advisories are NOT flagged)
    #   3     = reachable/called vulnerabilities -> real findings
    #   other = build/load/tool error -> NOT a vuln (a crash must not
    #           masquerade as a finding and burn a triage run)
    local rc
    (cd "$repo_path" && "${gv[@]}" ./...) > "$audit_file" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then
      # Native build failed (e.g. a headless host can't compile a
      # desktop GUI backend's X11/cgo deps). Retry the wasm target the
      # web clients actually ship as -- that backend needs no C headers.
      { echo; echo "--- native build failed (exit $rc); retried GOOS=js GOARCH=wasm ---"; echo; } >> "$audit_file"
      (cd "$repo_path" && GOOS=js GOARCH=wasm "${gv[@]}" ./...) >> "$audit_file" 2>&1
      rc=$?
    fi
    case "$rc" in
      0) echo "govulncheck:clean" ;;
      3) echo "govulncheck:findings" ;;
      *) echo "govulncheck:error" ;;
    esac
  fi

  # go list -m -u all marks updatable modules with bracketed
  # versions: "example.com/mod v1.0.0 [v1.2.0]". No brackets -> clean.
  # (Now also surfaces a stale pinned govulncheck, turning toolchain
  # drift into a visible outdated finding instead of silent rot.)
  (cd "$repo_path" && go list -m -u all 2>&1) > "$outdated_file"
  if ! grep -qE "\[v[0-9]" "$outdated_file"; then
    echo "go-outdated:clean"
  else
    echo "go-outdated:findings"
  fi
}

_run_bundle() {
  local repo_path="$1" out_dir="$2"
  local audit_file="$out_dir/bundle-audit.txt"
  local outdated_file="$out_dir/bundle-outdated.txt"

  if ensure_audit_tool bundle-audit "gem install --user-install --silent bundler-audit"; then
    (cd "$repo_path" && bundle-audit check --update 2>&1) > "$audit_file"
    if [ $? -eq 0 ]; then echo "bundle-audit:clean"; else echo "bundle-audit:findings"; fi
  else
    echo "bundle-audit unavailable on this host" > "$audit_file"
    echo "bundle-audit:skipped"
  fi

  (cd "$repo_path" && bundle outdated 2>&1) > "$outdated_file"
  # bundle outdated prints "Bundle up to date!" when clean.
  if grep -qiE "up to date" "$outdated_file"; then
    echo "bundle-outdated:clean"
  else
    echo "bundle-outdated:findings"
  fi
}

# -- Top-level audit ---------------------------------------------
#
# maintenance_audit_repo <repo_path> <out_dir>
#
# Detects stacks, runs each stack's audit + outdated tools, writes
# raw output files into <out_dir>, and writes a summary file to
# <out_dir>/AUDIT_SUMMARY.txt that lists each tool and its
# clean/findings/skipped status.
#
# Returns:
#   0 if all detected tools are clean (or skipped because the tool
#     wasn't installable -- a skip is NOT a finding; it's reported in
#     the summary so the human can fix the host)
#   1 if any tool reported findings
#   2 if no stacks were detected (caller can decide what to do)

maintenance_audit_repo() {
  local repo_path="$1" out_dir="$2"
  mkdir -p "$out_dir"

  local stacks
  stacks=$(detect_stacks "$repo_path")
  if [ -z "$stacks" ]; then
    echo "no recognized stack manifests at $repo_path" > "$out_dir/AUDIT_SUMMARY.txt"
    return 2
  fi

  local summary_file="$out_dir/AUDIT_SUMMARY.txt"
  : > "$summary_file"
  local any_findings=0

  while read -r stack; do
    [ -z "$stack" ] && continue
    local results
    case "$stack" in
      npm)    results=$(_run_npm    "$repo_path" "$out_dir") ;;
      cargo)  results=$(_run_cargo  "$repo_path" "$out_dir") ;;
      pip)    results=$(_run_pip    "$repo_path" "$out_dir") ;;
      go)     results=$(_run_go     "$repo_path" "$out_dir") ;;
      bundle) results=$(_run_bundle "$repo_path" "$out_dir") ;;
      *)      continue ;;
    esac
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      printf '%s\n' "$line" >> "$summary_file"
      case "$line" in
        *:findings) any_findings=1 ;;
      esac
    done <<<"$results"
  done <<<"$stacks"

  return "$any_findings"
}
