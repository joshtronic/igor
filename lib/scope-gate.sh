#!/usr/bin/env bash
# scope-gate.sh -- the finalize-time runaway-diff guard's test-path
# classifier and line-counter (igor#467). Split out of bin/tick.sh so
# bin/test-scope-gate.sh can source and exercise it without running a tick.
#
# The cap moved 400 -> 1000 net lines and now EXCLUDES test files. A worker
# once deleted its own passing tests to duck under the old line count
# (igor#411) and a later PR's only overage was pure failure-mode test
# coverage that the human ended up waiving (igor#465) -- in both cases the
# cap was punishing the wrong thing. Excluding tests makes "delete tests to
# shrink the diff" structurally impossible and stops taxing coverage; sizing
# judgment for everything else (padding, drive-by changes) moves to the
# review (bin/lib/review-directive.md), which can actually read intent.

# shellcheck disable=SC2034  # read only by bin/tick.sh, which sources this
SCOPE_GATE_MAX_LINES=1000

# is_test_path <path> -- true if path is a test file, per a hardcoded
# classifier (deliberately not an env knob -- house style bakes in the
# single-operator fleet's constants rather than dialing them). Matches:
#   (^|/)test[s]?/            a test/ or tests/ directory anywhere in the path
#   (^|/)bin/test-[^/]+$      this repo's own bin/test-*.sh convention
#   \.(test|spec)\.[a-z]+$    foo.test.js / foo.spec.ts style
#   _test\.(go|py|rb|ex|exs)$ foo_test.go / foo_test.py style
#   (^|/)spec/                a spec/ directory (RSpec etc.)
is_test_path() {
  printf '%s' "$1" | grep -qE \
    '(^|/)test[s]?/|(^|/)bin/test-[^/]+$|\.(test|spec)\.[a-z]+$|_test\.(go|py|rb|ex|exs)$|(^|/)spec/'
}

# scope_gate_is_generated_data <path> <globs> -- true if path matches one of
# <globs>, a comma-separated list of shell glob patterns from a repo's
# dossier-declared `generated-data` key (docs/agents-md-spec.md). Empty
# globs never matches -- a repo that declares nothing behaves exactly as
# before (igor#544). Whitespace around each comma-separated entry is
# trimmed, so `a/*.json, b/*.json` reads the same as `a/*.json,b/*.json`.
scope_gate_is_generated_data() {
  local path="$1" globs="$2" glob parts
  [ -n "$globs" ] || return 1
  # `read -ra` splits on IFS WITHOUT pathname expansion. An unquoted `for glob
  # in $globs` would expand each pattern against the CWD first, replacing the
  # declaration with whatever files happen to be on disk -- so a path the
  # branch deleted would stop matching and be counted as branch work.
  IFS=, read -ra parts <<<"$globs" || true
  for glob in "${parts[@]}"; do
    glob="${glob#"${glob%%[![:space:]]*}"}"
    glob="${glob%"${glob##*[![:space:]]}"}"
    [ -n "$glob" ] || continue
    # shellcheck disable=SC2053,SC2254  # intentional glob match, not literal compare
    case "$path" in
      $glob) return 0 ;;
    esac
  done
  return 1
}

# scope_gate_base_generated_globs <base-ref> -- echoes the `generated-data`
# declaration from <base-ref>'s dossier, or empty when the repo declares none.
# Requires lib/dossier.sh sourced (bin/tick.sh sources it first).
#
# The ref is the BASE branch, never the branch under judgment: reading HEAD
# would let a branch add its own exclusion mid-branch and duck this guard,
# the same self-privilege-escalation the automerge maintenance-tier carve-out
# guards against. stderr from the lookup is deliberately NOT suppressed -- an
# absent key is an ordinary rc1, so anything that does print (a missing
# dossier reader, say) is a real fault worth having in the journal rather
# than a silent degrade to the old behavior.
scope_gate_base_generated_globs() {
  local base_ref="$1" agents cfg
  agents=$(git show "${base_ref}:AGENTS.md" 2>/dev/null) || agents=""
  cfg=$(git show "${base_ref}:agent.json" 2>/dev/null) || cfg=""
  dossier_get_content "$agents" "$cfg" generated-data || true
}

# scope_gate_sum_numstat [generated-data-globs] -- reads `git diff --numstat`
# lines on stdin, sums added+deleted for every path that is neither a test
# path, a hardcoded lockfile/dist/build path (the pre-existing exclusions
# the shortstat-based counter this replaced already carried), nor a declared
# generated-data path (igor#544 -- a repo-owned file like a nightly data
# refresh that a stale base can make a live branch look like it rewrote).
# Binary files (numstat prints "-\t-\tpath") count as 0, same as before.
#
# Echoes three tab-separated fields so a caller can report not just the
# count but what was excluded and why (igor#544 deliverable #3):
#   <counted-total>  <generated-data-excluded-lines>  <generated-data-excluded-files>
scope_gate_sum_numstat() {
  local globs="${1:-}" added deleted path total=0 gen_lines=0 gen_files=0
  while IFS=$'\t' read -r added deleted path; do
    [ -z "$path" ] && continue
    [ "$added" = "-" ] && added=0
    [ "$deleted" = "-" ] && deleted=0
    if scope_gate_is_generated_data "$path" "$globs"; then
      gen_lines=$((gen_lines + added + deleted))
      gen_files=$((gen_files + 1))
      continue
    fi
    case "$path" in
      package-lock.json|*/package-lock.json) continue ;;
      yarn.lock|*/yarn.lock) continue ;;
      pnpm-lock.yaml|*/pnpm-lock.yaml) continue ;;
      *.lock) continue ;;
      dist/*|*/dist/*) continue ;;
      build/*|*/build/*) continue ;;
    esac
    is_test_path "$path" && continue
    total=$((total + added + deleted))
  done
  printf '%s\t%s\t%s\n' "$total" "$gen_lines" "$gen_files"
}
