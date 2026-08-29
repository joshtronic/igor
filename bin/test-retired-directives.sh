#!/usr/bin/env bash
# test-retired-directives.sh -- the per-surface directive copies retired in
# igor#489 and igor#556 must stay gone and must never grow a reader back.
#
# igor#486 moved review-directive, voice, feedback-directive,
# site-work-directive, sports-digest-directive, and now-directive to be
# sourced live from the Distillery cache (lib/context-source.sh); the
# in-repo bin/lib/*.md copies of those six were left behind, unconsumed,
# until igor#489 deleted them. This is the negative-wiring assertion that
# review asked for: nothing should still expect one of those six files to
# exist on disk.
#
# igor#556 (phase 1) retired the CEO cascade stage as a deliberate removal,
# not a dead-code cleanup -- do_ceo_tick was live and reachable, it just had
# zero opted-in repos (no repo carries a CEO.md mandate). Unlike the six
# directives above, lib/ceo.sh and bin/lib/ceo-digest-directive.md are NOT
# deleted here -- lib/ceo.sh alone is over the per-issue runaway guard, so
# deleting it is a separate, operator-gated phase 2. Phase 1 only unwires the
# stage (CASCADE_STAGES, the cascade_run gate, do_ceo_tick, the lib/ceo.sh
# source line); both files stay on disk, orphaned. The assertion below checks
# the wiring is gone, not that the files are.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE" || exit 1

RETIRED=(review-directive voice feedback-directive site-work-directive sports-digest-directive now-directive)

FAIL=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; FAIL=$((FAIL + 1)); }

echo "== the retired directive copies are actually gone =="
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

echo "== igor#556 phase 1: bin/test-ceo.sh is gone (test-excluded, safe to delete outright) =="
if [ -f bin/test-ceo.sh ]; then
  bad "bin/test-ceo.sh still exists -- should have been removed with the cascade stage"
else
  ok "bin/test-ceo.sh is gone"
fi

echo "== igor#556 phase 1: lib/ceo.sh and its directive are orphaned, not sourced/called =="
if [ -f lib/ceo.sh ] && [ -f bin/lib/ceo-digest-directive.md ]; then
  ok "lib/ceo.sh and bin/lib/ceo-digest-directive.md are still present (phase 2 is a separate, larger removal)"
else
  bad "lib/ceo.sh or bin/lib/ceo-digest-directive.md is missing -- phase 1 leaves both on disk, orphaned"
fi

stages_line=$(grep '^CASCADE_STAGES=' bin/tick.sh | head -1)
case " ${stages_line} " in
  *' ceo '*) bad "ceo is still listed in CASCADE_STAGES: ${stages_line}" ;;
  *) ok "ceo is gone from CASCADE_STAGES" ;;
esac

echo "== and nothing outside a comment in tick.sh still wires the CEO stage back in =="
CEO_SYMBOL_HITS=0
while IFS=: read -r _file _lineno content; do
  [ -n "${content+set}" ] || continue
  trimmed="${content#"${content%%[![:space:]]*}"}"
  case "$trimmed" in
    '#'*) continue ;;   # a stale comment mentioning the retired wiring isn't a reader
  esac
  bad "${_file}:${_lineno} still references retired CEO wiring: ${content}"
  CEO_SYMBOL_HITS=$((CEO_SYMBOL_HITS + 1))
done < <(grep -nE 'do_ceo_tick|_ceo_file_outputs|cascade_run ceo|lib/ceo\.sh|ceo-digest-directive' bin/tick.sh 2>/dev/null || true)

[ "$CEO_SYMBOL_HITS" -eq 0 ] && ok "bin/tick.sh has no reference to the retired CEO wiring"

if [ "$FAIL" -eq 0 ]; then
  echo "test-retired-directives: all checks passed"
else
  echo "test-retired-directives: $FAIL FAILED"
  exit 1
fi
