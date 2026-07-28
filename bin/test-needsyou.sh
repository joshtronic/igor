#!/usr/bin/env bash
# Unit tests for lib/needsyou.sh -- the "what is waiting on the operator" set
# and its event semantics (igor#439, detection half).
#
# The property that matters: only ADDITIONS are announceable. An unchanged set
# must produce nothing, or the notification becomes a periodic digest that says
# "nothing needs you" and trains the reader to ignore it.
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "test-needsyou: jq absent -- skipping"; exit 0; }
HERE=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/needsyou.sh
. "$HERE/lib/needsyou.sh"

FAIL=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi; }
has() { case "$2" in *"$3"*) ok "$1";; *) bad "$1: [$2] lacks [$3]";; esac; }

K1=$(needsyou_key acme/site pr 12)
K2=$(needsyou_key acme/site issue 12)
echo "== keys =="
eq "key shape" "acme/site/pr/12" "$K1"
if [ "$K1" != "$K2" ]; then ok "a PR and an issue with the SAME number are distinct keys"
else bad "pr and issue #12 collided -- Forgejo shares the number space"; fi

set_of() { # set_of <key> <json-item> [<key> <json-item> ...]
  local out='{}' k v
  while [ $# -gt 0 ]; do
    k="$1"; v="$2"; shift 2
    out=$(jq -c --arg k "$k" --argjson v "$v" '. + {($k): $v}' <<<"$out")
  done
  printf '%s' "$out"
}

NOW=1000000
I1=$(needsyou_item acme/site pr 12 "shadow verdict COMMENT -- needs your call" "$NOW")
I2=$(needsyou_item acme/site issue 5 "Status/Blocked" "$NOW")
PREV=$(set_of "$K1" "$I1")
CUR=$(set_of "$K1" "$I1" "acme/site/issue/5" "$I2")

echo "== additions are the only announceable event =="
eq "a new item is an addition" "acme/site/issue/5" "$(needsyou_added "$PREV" "$CUR")"
eq "an UNCHANGED set announces nothing" "" "$(needsyou_added "$CUR" "$CUR")"
eq "an item leaving is NOT an addition" "" "$(needsyou_added "$CUR" "$PREV")"
eq "and leaving is reported as a removal" "acme/site/issue/5" "$(needsyou_removed "$CUR" "$PREV")"
eq "empty -> empty announces nothing" "" "$(needsyou_added '{}' '{}')"
eq "first ever scan announces everything in it" "acme/site/pr/12" "$(needsyou_added '{}' "$PREV")"

echo "== merge preserves 'since' so wait time is real =="
# The item was first seen at NOW; a later scan must NOT reset its clock, or
# nothing can ever be reported as having waited days.
LATER=$((NOW + 86400))
MERGED=$(needsyou_merge "$PREV" "$CUR" "$LATER")
eq "an existing item keeps its original since" "$NOW" "$(jq -r '."acme/site/pr/12".since' <<<"$MERGED")"
eq "a newly seen item takes the current time" "$LATER" "$(jq -r '."acme/site/issue/5".since' <<<"$MERGED")"
eq "merge keeps exactly the CURRENT keys" "acme/site/issue/5 acme/site/pr/12" \
  "$(jq -r 'keys | join(" ")' <<<"$MERGED")"
# An item that left and came back is genuinely new again.
BACK=$(needsyou_merge '{}' "$PREV" "$LATER")
eq "an item that left and returned resets its clock" "$LATER" "$(jq -r '."acme/site/pr/12".since' <<<"$BACK")"

echo "== describe: what the operator actually reads =="
D=$(needsyou_describe "$MERGED" "acme/site/pr/12" "$LATER")
has "names the repo and number" "$D" "acme/site#12"
has "says why it is waiting" "$D" "shadow verdict COMMENT"
has "reports the wait in days once it is old" "$D" "waiting 1d"
D2=$(needsyou_describe "$MERGED" "acme/site/issue/5" "$((LATER + 1800))")
has "a fresh item reports minutes" "$D2" "waiting 30m"
eq "an unknown key describes to nothing" "" "$(needsyou_describe "$MERGED" "nope/x/1" "$LATER")"

echo "== malformed input degrades to empty, never crashes =="
eq "garbage previous -> everything reads as new" "acme/site/pr/12" "$(needsyou_added 'not json' "$PREV")"
eq "garbage current -> nothing announced" "" "$(needsyou_added "$PREV" 'not json')"
eq "garbage both -> nothing" "" "$(needsyou_added 'not json' 'also not json')"
eq "merge over garbage does not explode" "{}" "$(needsyou_merge 'not json' 'not json' "$NOW")"

if [ "$FAIL" -eq 0 ]; then
  echo "test-needsyou: all checks passed"
else
  echo "test-needsyou: $FAIL FAILED"
  exit 1
fi
