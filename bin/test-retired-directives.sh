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
# igor#556 retired the CEO surface (bin/lib/ceo-digest-directive.md, plus
# lib/ceo.sh and its cascade stage) as a deliberate removal, not a dead-code
# cleanup -- do_ceo_tick was live and reachable, it just had zero opted-in
# repos. ceo-digest-directive.md joins the RETIRED list below rather than
# getting its own section, since the mechanism -- grep for a non-comment
# reference to the filename -- is identical.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE" || exit 1

RETIRED=(review-directive voice feedback-directive site-work-directive sports-digest-directive now-directive ceo-digest-directive)

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

echo "== igor#556: the rest of the CEO surface is gone =="
for f in lib/ceo.sh bin/test-ceo.sh; do
  if [ -f "$f" ]; then
    bad "$f still exists -- CEO surface was not fully removed"
  else
    ok "$f is gone"
  fi
done

echo "== and nothing outside a comment still references a retired CEO symbol =="
CEO_SYMBOL_HITS=0
while IFS=: read -r _file _lineno content; do
  [ -n "${content+set}" ] || continue
  trimmed="${content#"${content%%[![:space:]]*}"}"
  case "$trimmed" in
    '#'*) continue ;;   # a stale comment mentioning the retired surface isn't a reader
  esac
  bad "${_file}:${_lineno} still references a retired CEO symbol: ${content}"
  CEO_SYMBOL_HITS=$((CEO_SYMBOL_HITS + 1))
done < <(grep -rnE 'do_ceo_tick|_ceo_file_outputs|cascade_run ceo|CASCADE_STAGES=.*[^_]ceo |CEO_MANDATE_PATH|\bceo_[a-z_]+\(' bin/ lib/ \
  --include='*.sh' --exclude='test-retired-directives.sh' 2>/dev/null || true)

[ "$CEO_SYMBOL_HITS" -eq 0 ] && ok "no non-comment reference to a retired CEO symbol"

if [ "$FAIL" -eq 0 ]; then
  echo "test-retired-directives: all checks passed"
else
  echo "test-retired-directives: $FAIL FAILED"
  exit 1
fi
