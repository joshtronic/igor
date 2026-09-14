#!/usr/bin/env bash
# test-split-ticket.sh -- unit tests for lib/split-ticket.sh: the marker
# round-trip, the follow-up issue body, the parent-linking comment, and the
# finalize-body rewrite that neutralizes an auto-close keyword on a split
# PR (igor#608). Pure logic -- no network, no git, no state.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/split-ticket.sh
. "$HERE/../lib/split-ticket.sh"

FAIL=0
eq() { if [ "$2" = "$3" ]; then printf '  + %s\n' "$1"; else printf '  x %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi; }
has() { case "$2" in *"$3"*) printf '  + %s\n' "$1" ;; *) printf '  x %s: [%s] lacks [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)) ;; esac; }
lacks() { case "$2" in *"$3"*) printf '  x %s: [%s] still has [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)) ;; *) printf '  + %s\n' "$1" ;; esac; }

echo "== SPLIT_TICKET_MARKER_FILE: alongside PR_BODY.md's convention =="
eq "marker lives under .agent/" ".agent/SPLIT_TICKET" "$SPLIT_TICKET_MARKER_FILE"

echo "== split_ticket_read_followup: parses the marker file's issue number =="
eq "bare number"              "650" "$(split_ticket_read_followup '650')"
eq "number with trailing newline" "650" "$(split_ticket_read_followup $'650\n')"
eq "unparseable content -> empty" "" "$(split_ticket_read_followup 'nope')"

echo "== split_ticket_followup_body: carries the deferred scope + a back-reference =="
FB=$(split_ticket_followup_body "608" "Do the deferred part.")
has "keeps the agent's deferred-scope text" "$FB" "Do the deferred part."
has "back-references the original issue"   "$FB" "Split from #608"

echo "== split_ticket_parent_comment: links the follow-up, doesn't close anything =="
PC=$(split_ticket_parent_comment "650")
has "references the follow-up issue" "$PC" "#650"
lacks "never writes an auto-close keyword" "$(printf '%s' "$PC" | tr '[:upper:]' '[:lower:]')" "closes #650"

echo "== split_ticket_finalize_body: neutralizes an auto-close keyword for the original issue =="
lacks "strips a bare 'Closes #608'" \
  "$(split_ticket_finalize_body 'Did the thing.

Closes #608' 608 650)" "Closes #608"
eq "'Closes #608' becomes 'Part of #608'" "Did the thing.

Part of #608" \
  "$(split_ticket_finalize_body 'Did the thing.

Closes #608' 608 '')"
has "'Fixes #608 by ...' -> neutralized mid-sentence" \
  "$(split_ticket_finalize_body 'Fixes #608 by adding the guard.' 608 '')" "Part of #608 by adding the guard."
has "'resolved #608' -> neutralized (case-insensitive, past tense)" \
  "$(split_ticket_finalize_body 'resolved #608' 608 '')" "Part of #608"
has "'#6080' -- the unrelated close keyword survives untouched" \
  "$(split_ticket_finalize_body 'Closes #6080' 608 '')" "Closes #6080"
has "'Closes: #608' -- Forgejo honors the colon form, so it must be neutralized too" \
  "$(split_ticket_finalize_body 'Closes: #608' 608 '')" "Part of #608"
lacks "'Closes: #608' leaves no closing keyword behind" \
  "$(split_ticket_finalize_body 'Closes: #608' 608 '')" "Closes:"
has "'fixed:  #608' -- colon plus extra spacing, past tense" \
  "$(split_ticket_finalize_body 'fixed:  #608' 608 '')" "Part of #608"
has "'precloses #608' -- keyword embedded in a word is left alone" \
  "$(split_ticket_finalize_body 'precloses #608' 608 '')" "precloses #608"
lacks "'precloses #608' isn't mangled into 'PrePart of'" \
  "$(split_ticket_finalize_body 'precloses #608' 608 '')" "prePart of"
has "'#6080' doesn't satisfy the #608 'Part of' guarantee -- appended separately" \
  "$(split_ticket_finalize_body 'Closes #6080' 608 '')" "Part of #608"

echo "== split_ticket_finalize_body: guarantees 'Part of #<orig>' is present =="
has "no closing keyword at all -> 'Part of' still appended" \
  "$(split_ticket_finalize_body 'Did the thing.' 608 '')" "Part of #608"
ONCE=$(split_ticket_finalize_body 'Did the thing.' 608 '')
TWICE=$(split_ticket_finalize_body "$ONCE" 608 '')
eq "idempotent: re-running adds nothing further" "$ONCE" "$TWICE"

echo "== split_ticket_finalize_body: guarantees a reference to the follow-up =="
has "follow-up issue referenced when given" \
  "$(split_ticket_finalize_body 'Did the thing.' 608 650)" "#650"
eq "empty follow-up -> no follow-up line added" "Did the thing.

Part of #608" \
  "$(split_ticket_finalize_body 'Did the thing.' 608 '')"
ALREADY=$(split_ticket_finalize_body 'Did the thing.

Part of #608

Remaining scope split to #650.' 608 650)
FIRST_COUNT=$(printf '%s' "$ALREADY" | grep -oE '#650' | wc -l | tr -d ' ')
eq "already-present follow-up reference isn't duplicated" "1" "$FIRST_COUNT"

echo "== split_ticket_body_{set,read}: the split survives a checkpoint -> resume =="
eq "no marker in the body -> empty" "" "$(split_ticket_body_read 'Nothing here.')"
MARKED=$(split_ticket_body_set 'Did part of the thing.' 650)
has "marker stamped into the body" "$MARKED" "<!-- agent-split=650 -->"
has "the body itself is preserved" "$MARKED" "Did part of the thing."
eq "round-trips through split_ticket_body_read" "650" "$(split_ticket_body_read "$MARKED")"
REMARKED=$(split_ticket_body_set "$MARKED" 651)
eq "re-stamping replaces rather than appends" "651" "$(split_ticket_body_read "$REMARKED")"
lacks "the superseded marker is gone" "$REMARKED" "agent-split=650"
eq "empty follow-up -> body unchanged" "Did part of the thing." \
  "$(split_ticket_body_set 'Did part of the thing.' '')"

if [ "$FAIL" -gt 0 ]; then
  printf '\n%d assertion(s) failed\n' "$FAIL"
  exit 1
fi
printf '\nall assertions passed\n'
