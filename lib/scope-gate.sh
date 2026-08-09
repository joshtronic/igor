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

# scope_gate_sum_numstat -- reads `git diff --numstat` lines on stdin, sums
# added+deleted for every path that is neither a test path nor a generated/
# lockfile path (the pre-existing exclusions the shortstat-based counter
# this replaced already carried). Binary files (numstat prints "-\t-\tpath")
# count as 0, same as before.
scope_gate_sum_numstat() {
  local added deleted path total=0
  while IFS=$'\t' read -r added deleted path; do
    [ -z "$path" ] && continue
    case "$path" in
      package-lock.json|*/package-lock.json) continue ;;
      yarn.lock|*/yarn.lock) continue ;;
      pnpm-lock.yaml|*/pnpm-lock.yaml) continue ;;
      *.lock) continue ;;
      dist/*|*/dist/*) continue ;;
      build/*|*/build/*) continue ;;
    esac
    is_test_path "$path" && continue
    [ "$added" = "-" ] && added=0
    [ "$deleted" = "-" ] && deleted=0
    total=$((total + added + deleted))
  done
  printf '%s\n' "$total"
}
