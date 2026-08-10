#!/usr/bin/env bash
# test-retired-directives.sh -- the six per-surface directive copies retired
# in igor#489 must stay gone and must never grow a reader back.
#
# igor#486 moved review-directive, voice, feedback-directive,
# site-work-directive, sports-digest-directive, and now-directive to be
# sourced live from the Distillery cache (lib/context-source.sh); the
# in-repo bin/lib/*.md copies of those six were left behind, unconsumed,
# until igor#489 deleted them. This is the negative-wiring assertion that
# review asked for: nothing should still expect one of those six files to
# exist on disk.
#
# bin/lib/ceo-digest-directive.md is a DIFFERENT, still-live in-repo
# directive -- it was never migrated and is out of scope here -- so a
# literal, unfiltered `grep -rn 'bin/lib/.*\.md' bin/ lib/` would flag its
# real reader (bin/tick.sh) forever, a false red. This test narrows the
# raw grep to what actually matters: a non-comment line naming one of the
# six RETIRED filenames specifically. A comment that merely mentions a
# retired path in prose is harmless -- nothing dereferences a comment.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE" || exit 1

RETIRED=(review-directive voice feedback-directive site-work-directive sports-digest-directive now-directive)

FAIL=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; FAIL=$((FAIL + 1)); }

echo "== the six retired directive copies are actually gone =="
for name in "${RETIRED[@]}"; do
  if [ -f "bin/lib/${name}.md" ]; then
    bad "bin/lib/${name}.md still exists -- retired copy was not deleted"
  else
    ok "bin/lib/${name}.md is gone"
  fi
done

echo "== and nothing outside a comment still reads one of them =="
LIVE_HITS=0
while IFS=: read -r _file _lineno content; do
  [ -n "${content+set}" ] || continue
  trimmed="${content#"${content%%[![:space:]]*}"}"
  case "$trimmed" in
    '#'*) continue ;;   # a stale comment mentioning the old path isn't a reader
  esac
  for name in "${RETIRED[@]}"; do
    case "$content" in
      *"bin/lib/${name}.md"*)
        bad "${_file}:${_lineno} still reads the retired bin/lib/${name}.md: ${content}"
        LIVE_HITS=$((LIVE_HITS + 1))
        ;;
    esac
  done
done < <(grep -rn 'bin/lib/.*\.md' bin/ lib/ 2>/dev/null || true)

[ "$LIVE_HITS" -eq 0 ] && ok "no non-comment reader of a retired bin/lib/*.md directive"

if [ "$FAIL" -eq 0 ]; then
  echo "test-retired-directives: all checks passed"
else
  echo "test-retired-directives: $FAIL FAILED"
  exit 1
fi
