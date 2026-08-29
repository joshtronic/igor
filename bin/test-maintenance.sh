#!/usr/bin/env bash
# test-maintenance.sh -- unit tests for igor#553: an errored maintenance pass
# never stamped its completion, so a persistently-broken repo (the trigger:
# an upstream default-branch rename leaving `origin/HEAD` dangling at the
# deleted branch) re-ran and re-errored on EVERY tick forever, and
# do_maintenance_tick returned success regardless -- handing the whole
# cascade to that one broken repo and starving sports/feedback/logwatch/the
# claimable grind below it.
#
# do_maintenance_tick / do_maintenance_for_repo / maintenance_resolve_base
# live inline in bin/tick.sh (which has top-level side-effecting code, so it
# can't be sourced directly). Following test-cascade.sh's precedent, each
# function under test is lifted out with `sed -n '/^fn() {$/,/^}$/p'` and
# eval'd here, with the handful of dependencies it touches (ensure_repo_local,
# repo_path_for, log, ANALYSIS_REPOS_JSON, ...) stubbed or hand-set. Only
# maintenance_audit_repo/detect_stacks come from a real source (lib/
# maintenance-checks.sh) -- the "no recognized stack" success path exercises
# them for real against an empty git repo.
#
# Skip-safe: needs jq + git; exits 0 with a notice if either is absent.
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "test-maintenance: jq absent -- skipping"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "test-maintenance: git absent -- skipping"; exit 0; }

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TICK="$HERE/bin/tick.sh"

# shellcheck source=../lib/maintenance-checks.sh
. "$HERE/lib/maintenance-checks.sh"

extract_fn() { sed -n "/^$1() {\$/,/^}\$/p" "$TICK"; }

for fn in maintenance_last_run maintenance_mark_done maintenance_mark_attempted \
          maintenance_eligible maintenance_resolve_base do_maintenance_for_repo \
          do_maintenance_tick init_igor_scratch; do
  SRC="$(extract_fn "$fn")"
  if [ -z "$SRC" ]; then
    echo "test-maintenance: could not extract $fn() from bin/tick.sh -- skipping"
    exit 0
  fi
  eval "$SRC"
done

log() { printf '[agent] %s\n' "$*" >&2; }
repo_path_for() { echo "$AGENT_REPO_ROOT/$1"; }
discretionary_state_file() { echo "$AGENT_STATE_DIR/discretionary-state.json"; }

FAIL=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1: [$2] lacks [$3]" ;; esac; }

TMP="$(mktemp -d)" || { echo "test-maintenance: mktemp unavailable -- skipping"; exit 0; }
trap 'rm -rf "$TMP"' EXIT

# Only read by the eval'd do_maintenance_for_repo's RETURN trap -- static
# analysis can't see through the eval.
# shellcheck disable=SC2034
AGENT_HOME="$TMP"
AGENT_STATE_DIR="$TMP/state"
AGENT_REPO_ROOT="$AGENT_STATE_DIR/repos"
mkdir -p "$AGENT_STATE_DIR/worktrees" "$AGENT_REPO_ROOT"

git_commit() { git -C "$1" -c user.email=t@example.com -c user.name=test commit --quiet "${@:2}"; }

# origin_and_clone <name> <default-branch> -- a bare "origin" plus a local
# clone at repo_path_for, seeded with one empty commit. Mirrors a real
# ensure_repo_local checkout closely enough for do_maintenance_for_repo's
# git plumbing (fetch/resolve/worktree add) to run unmodified.
origin_and_clone() {
  local name="$1" branch="$2"
  local origin="$TMP/remotes/$name.git" seed="$TMP/seed-$name"
  local clone; clone="$(repo_path_for "$name")"
  mkdir -p "$(dirname "$origin")"
  git init --quiet --bare -b "$branch" "$origin"
  git init --quiet -b "$branch" "$seed"
  git_commit "$seed" --allow-empty -m init
  git -C "$seed" remote add origin "$origin"
  git -C "$seed" push --quiet origin "$branch"
  mkdir -p "$(dirname "$clone")"
  git clone --quiet "$origin" "$clone"
}

# repos_json <name>... -- newline-delimited compact JSON, one {full_name}
# object per line -- the exact shape ANALYSIS_REPOS_JSON has in production
# (bin/tick.sh: `jq -c '.[]' <<<"$ALL_REPOS"`).
repos_json() {
  local arr="[]" n
  for n in "$@"; do arr=$(jq -c --arg n "$n" '. + [{full_name: $n}]' <<<"$arr"); done
  jq -c '.[]' <<<"$arr"
}

echo "== maintenance_resolve_base: a renamed default branch repairs itself =="
# The igor#553 trigger: origin's default branch moved main -> master after
# the clone existed. origin/HEAD in the clone stays pointed at the deleted
# "main" (fetch --prune removes the now-gone origin/main tracking ref but
# never touches the origin/HEAD symref itself) until something re-resolves
# it against the remote.
origin_and_clone renamerepo main
RENAME_ORIGIN="$TMP/remotes/renamerepo.git"
RENAME_PATH="$(repo_path_for renamerepo)"
git -C "$RENAME_ORIGIN" branch -m main master
git -C "$RENAME_ORIGIN" symbolic-ref HEAD refs/heads/master
git -C "$RENAME_PATH" fetch --prune origin >/dev/null 2>&1
eq "sanity: origin/main is now unresolvable in the clone" "1" \
  "$(git -C "$RENAME_PATH" rev-parse --verify --quiet refs/remotes/origin/main >/dev/null 2>&1; echo $?)"
RESOLVED=$(maintenance_resolve_base "$RENAME_PATH" renamerepo 2>"$TMP/resolve.err")
RESOLVE_RC=$?
eq "resolves to the real (renamed) default branch" "master" "$RESOLVED"
eq "resolve_base returns success" "0" "$RESOLVE_RC"
eq "repairs the local origin/HEAD symref for next time" "origin/master" \
  "$(git -C "$RENAME_PATH" symbolic-ref --short refs/remotes/origin/HEAD)"

echo "== maintenance_resolve_base: genuinely unresolvable fails loudly, names the repo =="
origin_and_clone deadrepo master
DEAD_PATH="$(repo_path_for deadrepo)"
# Corrupt the symref to point somewhere that never existed, then cut off the
# remote so the repair query can't succeed either.
git -C "$DEAD_PATH" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/nonexistent-branch
git -C "$DEAD_PATH" remote set-url origin "$TMP/does-not-exist.git"
DEAD_RESOLVED=$(maintenance_resolve_base "$DEAD_PATH" deadrepo 2>"$TMP/dead.err")
DEAD_RC=$?
eq "unresolvable base -> empty output" "" "$DEAD_RESOLVED"
eq "unresolvable base -> non-zero return" "1" "$DEAD_RC"
has "error log names the repo" "$(cat "$TMP/dead.err")" "deadrepo"
has "error log is greppable as an errored maintenance pass" "$(cat "$TMP/dead.err")" "maintenance: ERRORED"

echo "== do_maintenance_for_repo: an errored pass stamps -- not immediately re-eligible =="
origin_and_clone errrepo master
ERR_PATH="$(repo_path_for errrepo)"
git -C "$ERR_PATH" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/nonexistent-branch
git -C "$ERR_PATH" remote set-url origin "$TMP/does-not-exist.git"
ensure_repo_local() { return 0; }  # already checked out above
eq "errrepo starts eligible (never audited)" "0" "$(maintenance_eligible errrepo; echo $?)"
do_maintenance_for_repo errrepo >/dev/null 2>"$TMP/err1.log"
eq "an errored pass returns non-zero" "1" "$?"
eq "an errored pass does NOT leave the repo immediately re-eligible" "1" \
  "$(maintenance_eligible errrepo; echo $?)"
has "errored-pass log line is distinctly greppable" "$(cat "$TMP/err1.log")" "maintenance: ERRORED"

echo "== do_maintenance_for_repo: a clean pass (no recognized stack) still stamps + succeeds =="
origin_and_clone okrepo master
ensure_repo_local() { return 0; }
eq "okrepo starts eligible" "0" "$(maintenance_eligible okrepo; echo $?)"
do_maintenance_for_repo okrepo >"$TMP/ok1.log" 2>&1
DMFR_OK_RC=$?
# do_maintenance_for_repo's real body toggles the (process-wide, not
# function-scoped) errexit option around the audit call and leaves it ON
# when it reaches that point -- fine under tick.sh's own permanent `set -e`,
# but this test script deliberately runs without it. Restore our own
# baseline so a later unguarded non-zero return (e.g. the negative test
# below) doesn't abort the whole suite instead of just failing its check.
set +e
eq "a successful (no-stack) pass returns success" "0" "$DMFR_OK_RC"
eq "a successful pass stamps -- not immediately re-eligible" "1" \
  "$(maintenance_eligible okrepo; echo $?)"

echo "== negative test: sever the stamp-on-attempt call -- the errored repo IS re-picked immediately =="
# The pre-fix shape of do_maintenance_for_repo's error path: identical git
# plumbing, but no maintenance_mark_attempted call when it fails. This is
# exactly the bug igor#553 reports -- prove the stamp call is what breaks the
# starve loop by removing only it and re-running the same broken-base repo.
do_maintenance_for_repo_unpatched() {
  local target="$1" target_path target_base
  target_path=$(repo_path_for "$target")
  target_base=$(cd "$target_path" && git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
  target_base="${target_base:-master}"
  local m_worktree="$AGENT_STATE_DIR/worktrees/maintenance-unpatched-${target}-$$"
  mkdir -p "$AGENT_STATE_DIR/worktrees"
  (cd "$target_path" && git fetch --prune origin) || return 1
  (cd "$target_path" && git worktree add --detach "$m_worktree" "origin/${target_base}") || return 1
  return 0
}
origin_and_clone severedrepo master
SEV_PATH="$(repo_path_for severedrepo)"
git -C "$SEV_PATH" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/nonexistent-branch
git -C "$SEV_PATH" remote set-url origin "$TMP/does-not-exist.git"
eq "severedrepo starts eligible" "0" "$(maintenance_eligible severedrepo; echo $?)"
do_maintenance_for_repo_unpatched severedrepo >/dev/null 2>&1
eq "unpatched errored pass still returns non-zero" "1" "$?"
eq "BUG (reproduced): without the stamp call, the repo is still eligible right after erroring" "0" \
  "$(maintenance_eligible severedrepo; echo $?)"
do_maintenance_for_repo_unpatched severedrepo >/dev/null 2>&1
eq "BUG (reproduced): a second immediate attempt errors the exact same way" "1" "$?"

echo "== do_maintenance_tick: an errored repo alone must not return success (cascade falls through) =="
browser_reap_sweep() { :; }
STUB_DMFR_RESULTS=(); STUB_DMFR_CALLS=0
do_maintenance_for_repo() {
  local rc="${STUB_DMFR_RESULTS[$STUB_DMFR_CALLS]}"
  STUB_DMFR_CALLS=$((STUB_DMFR_CALLS + 1))
  return "$rc"
}
STUB_DMFR_RESULTS=(1)
# Read only by the eval'd do_maintenance_tick, which shellcheck can't see
# through.
# shellcheck disable=SC2034
ANALYSIS_REPOS_JSON="$(repos_json tickrepo-err)"
do_maintenance_tick >/dev/null 2>&1
eq "all-errored tick returns non-zero (cascade continues past maintenance)" "1" "$?"

echo "== do_maintenance_tick: a successful pass still ends the tick as before =="
STUB_DMFR_RESULTS=(0); STUB_DMFR_CALLS=0
ANALYSIS_REPOS_JSON="$(repos_json tickrepo-ok)"
do_maintenance_tick >/dev/null 2>&1
eq "an all-successful tick still returns success" "0" "$?"

echo "== do_maintenance_tick: one success among several errors is still enough =="
STUB_DMFR_RESULTS=(1 0 1); STUB_DMFR_CALLS=0
ANALYSIS_REPOS_JSON="$(repos_json tickrepo-mix-a tickrepo-mix-b tickrepo-mix-c)"
do_maintenance_tick >/dev/null 2>&1
eq "a mixed tick with at least one success returns success" "0" "$?"

if [ "$FAIL" -eq 0 ]; then
  echo "test-maintenance: all checks passed"
else
  echo "test-maintenance: $FAIL FAILED"
  exit 1
fi
