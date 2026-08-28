#!/usr/bin/env bash
# test-reading-slate.sh -- unit tests for bin/reading-pipeline.sh's
# parse_reading_slate (igor#540).
#
# igor#540 moved the reading pipeline's source slate out of a hardcoded
# array and into the required READING_SLATE env var ("url|picker;..."),
# with the picker name validated against a closed set
# (READING_SLATE_PICKERS) -- same posture as lib/landed.sh's LANDED_KINDS:
# an unrecognized picker fails loudly (exit 2) rather than being silently
# skipped.
#
# Function + closed-set var are lifted straight out of
# bin/reading-pipeline.sh (sed range extraction, same technique
# bin/test-ideation-write-post-file.sh uses) rather than sourced, since the
# script has top-level side-effecting code (env guards, brain_init,
# context_seeded) that a plain `.` would trip over.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/reading-pipeline.sh"

FAIL=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; FAIL=$((FAIL + 1)); }
eq()  { local d="$1" want="$2" got="$3"; if [ "$want" = "$got" ]; then ok "$d"; else bad "$d (want $(printf '%q' "$want") got $(printf '%q' "$got"))"; fi; }

lift() {
  local fn="$1" src
  src=$(sed -n "/^${fn}() {\$/,/^}\$/p" "$SCRIPT")
  [ -z "$src" ] && { bad "could not extract ${fn}() from bin/reading-pipeline.sh"; return 1; }
  eval "$src"
}

READING_SLATE_PICKERS=$(sed -n 's/^READING_SLATE_PICKERS="\(.*\)"$/\1/p' "$SCRIPT" | head -1)
[ -z "$READING_SLATE_PICKERS" ] && { bad "could not extract READING_SLATE_PICKERS from bin/reading-pipeline.sh"; exit 1; }

lift parse_reading_slate || exit 1

log() { :; }  # silence -- parse_reading_slate logs on the failure path

echo "== a well-formed multi-entry slate parses into SLATE_URLS, in order =="
declare -a SLATE_URLS=()
parse_reading_slate "https://joshtronic.com|personal_newest;https://news.ycombinator.com|hn_top;https://en.wikipedia.org/wiki/Special:Random|wiki_random"
eq "3 entries parsed" "3" "${#SLATE_URLS[@]}"
eq "entry 0 preserved verbatim" "https://joshtronic.com|personal_newest" "${SLATE_URLS[0]:-}"
eq "entry 1 preserved verbatim" "https://news.ycombinator.com|hn_top" "${SLATE_URLS[1]:-}"
eq "entry 2 preserved verbatim" "https://en.wikipedia.org/wiki/Special:Random|wiki_random" "${SLATE_URLS[2]:-}"

echo "== the current operator slate (issue-specified value) parses to 5 entries =="
declare -a SLATE_URLS=()
parse_reading_slate "https://joshtronic.com|personal_newest;https://thatgirljen.com|personal_newest;https://news.ycombinator.com|hn_top;https://kagi.com/smallweb|kagi_redirect;https://en.wikipedia.org/wiki/Special:Random|wiki_random"
eq "5 entries parsed" "5" "${#SLATE_URLS[@]}"

echo "== a picker outside the closed set fails loudly (exit 2), not a silent skip =="
declare -a SLATE_URLS=()
( parse_reading_slate "https://example.com|not_a_real_picker" ) >/dev/null 2>&1
eq "exit status 2 on unrecognized picker" "2" "$?"

echo "== all four documented pickers are individually recognized =="
for picker in personal_newest hn_top kagi_redirect wiki_random; do
  declare -a SLATE_URLS=()
  parse_reading_slate "https://example.com|${picker}"
  eq "picker '$picker' accepted" "1" "${#SLATE_URLS[@]}"
done

echo
if [ "$FAIL" -eq 0 ]; then
  echo "test-reading-slate: all checks passed"
else
  echo "test-reading-slate: $FAIL check(s) failed"
fi
exit "$FAIL"
