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
  (cd "$repo_path" && npm outdated 2>&1) > "$outdated_file"
  # npm outdated exits non-zero when there ARE outdated packages, 0
  # when clean. Output is empty when clean.

  if [ "$audit_rc" -eq 0 ]; then echo "npm-audit:clean"; else echo "npm-audit:findings"; fi
  if [ ! -s "$outdated_file" ]; then echo "npm-outdated:clean"; else echo "npm-outdated:findings"; fi
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

  if ensure_audit_tool govulncheck "go install golang.org/x/vuln/cmd/govulncheck@latest"; then
    (cd "$repo_path" && govulncheck ./... 2>&1) > "$audit_file"
    if [ $? -eq 0 ]; then echo "govulncheck:clean"; else echo "govulncheck:findings"; fi
  else
    echo "govulncheck unavailable on this host" > "$audit_file"
    echo "govulncheck:skipped"
  fi

  # go list -m -u all marks updatable modules with bracketed
  # versions: "example.com/mod v1.0.0 [v1.2.0]". No brackets -> clean.
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
