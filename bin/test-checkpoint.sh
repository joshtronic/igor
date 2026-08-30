#!/usr/bin/env bash
# test-checkpoint.sh -- unit tests for lib/checkpoint.sh: the max-turns stream
# detection, the commit/checkpoint/discard disposition (incl. the porksicle#114
# stash guard), the WIP title round-trip, the body checkpoint-counter, the
# resume-budget cap, and the resumed-PR finalize title derivation (igor#572).
# Pure logic -- no network, no git, no state. Skip-safe: needs jq (like the
# other bin/test-*.sh); exits 0 with a notice if absent.
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "test-checkpoint: jq absent -- skipping"; exit 0; }

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/checkpoint.sh
. "$HERE/../lib/checkpoint.sh"
# checkpoint_final_title derives from pr_body_first_item / normalize_subject.
# shellcheck source=../lib/claude.sh
. "$HERE/../lib/claude.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

FAIL=0
ok() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then printf '  + %s\n' "$d"; else printf '  x %s (expected rc0)\n' "$d"; FAIL=$((FAIL + 1)); fi; }
no() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then printf '  x %s (expected rc!=0)\n' "$d"; FAIL=$((FAIL + 1)); else printf '  + %s\n' "$d"; fi; }
eq() { if [ "$2" = "$3" ]; then printf '  + %s\n' "$1"; else printf '  x %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi; }
ne() { if [ "$2" != "$3" ]; then printf '  + %s\n' "$1"; else printf '  x %s: expected anything but [%s]\n' "$1" "$2"; FAIL=$((FAIL + 1)); fi; }
has() { case "$2" in *"$3"*) printf '  + %s\n' "$1" ;; *) printf '  x %s: [%s] lacks [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)) ;; esac; }
lacks() { case "$2" in *"$3"*) printf '  x %s: [%s] still has [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)) ;; *) printf '  + %s\n' "$1" ;; esac; }

# ---- a real max-turns result event (captured from a live crash-log stream) ----
RESULT_MAXTURNS='{"type":"result","subtype":"error_max_turns","is_error":true,"terminal_reason":"max_turns","num_turns":101,"errors":["Reached maximum number of turns (100)"]}'
RESULT_OK='{"type":"result","subtype":"success","is_error":false,"terminal_reason":"end_turn","num_turns":12}'

echo "== terminal-reason / turn-cap detection from the stream =="
STREAM="$TMP/max.jsonl"
{ printf '%s\n' '{"type":"init"}'; printf '%s\n' '{"type":"assistant"}'; printf '%s\n' "$RESULT_MAXTURNS"; } > "$STREAM"
eq   "terminal_reason: reads max_turns"        "max_turns" "$(checkpoint_terminal_reason "$STREAM")"
ok   "hit_turn_cap: true on a max_turns result" checkpoint_hit_turn_cap "$STREAM"

STREAM_OK="$TMP/ok.jsonl"
{ printf '%s\n' '{"type":"init"}'; printf '%s\n' "$RESULT_OK"; } > "$STREAM_OK"
eq   "terminal_reason: reads end_turn"          "end_turn" "$(checkpoint_terminal_reason "$STREAM_OK")"
no   "hit_turn_cap: false on a clean result"    checkpoint_hit_turn_cap "$STREAM_OK"

# a mid-stream crash leaves no result event at all
STREAM_CRASH="$TMP/crash.jsonl"
{ printf '%s\n' '{"type":"init"}'; printf '%s\n' '{"type":"assistant"}'; } > "$STREAM_CRASH"
eq   "terminal_reason: empty when no result event" "" "$(checkpoint_terminal_reason "$STREAM_CRASH")"
no   "hit_turn_cap: false when no result event"    checkpoint_hit_turn_cap "$STREAM_CRASH"
no   "hit_turn_cap: false on a missing stream file" checkpoint_hit_turn_cap "$TMP/nope.jsonl"
# subtype alone (terminal_reason renamed away upstream) still trips the cap
printf '%s\n' '{"type":"result","subtype":"error_max_turns","is_error":true}' > "$TMP/sub.jsonl"
ok   "hit_turn_cap: subtype alone still detected"  checkpoint_hit_turn_cap "$TMP/sub.jsonl"

echo "== disposition: commit / checkpoint / discard =="
eq "decision: exit 0 -> commit (done)"                       "commit"     "$(checkpoint_decision 0 0 0)"
eq "decision: exit 0 wins even if cap flag set"              "commit"     "$(checkpoint_decision 0 1 0)"
eq "decision: nonzero + turn cap + no stash -> checkpoint"   "checkpoint" "$(checkpoint_decision 1 1 0)"
eq "decision: nonzero, NOT turn cap -> discard (crash)"      "discard"    "$(checkpoint_decision 1 0 0)"
eq "decision: turn cap but unrestored stash -> discard"      "discard"    "$(checkpoint_decision 1 1 1)"
eq "decision: SIGKILL (137) not turn cap -> discard"         "discard"    "$(checkpoint_decision 137 0 0)"
# igor#411: a confirmed turn cap with real dirty work must not be discarded
# just because a stash existed -- only an UNRECONCILED (never-popped or
# conflicted) stash still vetoes the checkpoint.
eq "decision: turn cap + stash reconciled -> checkpoint"     "checkpoint" "$(checkpoint_decision 1 1 1 1)"
eq "decision: turn cap + stash, reconcile failed -> discard" "discard"    "$(checkpoint_decision 1 1 1 0)"
eq "decision: turn cap, no stash, reconciled flag ignored"   "checkpoint" "$(checkpoint_decision 1 1 0 1)"

echo "== WIP title round-trip =="
ok    "is_wip: a WIP title"                       checkpoint_is_wip "WIP: feat: thing"
no    "is_wip: a plain title"                     checkpoint_is_wip "feat: thing"
eq    "wip_title: adds the prefix"                "WIP: feat: thing" "$(checkpoint_wip_title 'feat: thing')"
eq    "wip_title: idempotent (no double prefix)"  "WIP: feat: thing" "$(checkpoint_wip_title 'WIP: feat: thing')"
eq    "strip_wip: removes the prefix"             "feat: thing"      "$(checkpoint_strip_wip 'WIP: feat: thing')"
eq    "strip_wip: no-op on a plain title"         "feat: thing"      "$(checkpoint_strip_wip 'feat: thing')"
# strip then re-add is stable
eq    "wip round-trip is stable" "WIP: feat: x" "$(checkpoint_wip_title "$(checkpoint_strip_wip 'WIP: feat: x')")"

echo "== body checkpoint counter =="
BODY_PLAIN=$'Closes #351\n\nDoes the thing.'
eq    "read_count: absent -> 0"        "0" "$(checkpoint_read_count "$BODY_PLAIN")"
B1="$(checkpoint_set_count "$BODY_PLAIN" 1)"
eq    "read_count: after set 1 -> 1"   "1" "$(checkpoint_read_count "$B1")"
has   "set_count: preserves the body"  "$B1" "Closes #351"
has   "set_count: writes the marker"   "$B1" "<!-- agent-checkpoints=1 -->"
B2="$(checkpoint_set_count "$B1" 2)"
eq    "read_count: after set 2 -> 2"   "2" "$(checkpoint_read_count "$B2")"
# incrementing must not accumulate stale markers
eq    "set_count: replaces, not appends (one marker only)" "1" \
      "$(printf '%s' "$B2" | grep -c 'agent-checkpoints=')"
has   "set_count: keeps body across increments" "$B2" "Closes #351"
# a '|' in the body must not corrupt the line-oriented rewrite
BODY_PIPE=$'a | b & c / d\n<!-- agent-checkpoints=3 -->'
B3="$(checkpoint_set_count "$BODY_PIPE" 4)"
eq    "set_count: metachars in body survive" "4" "$(checkpoint_read_count "$B3")"
has   "set_count: body metachars preserved"  "$B3" "a | b & c / d"

echo "== resume budget cap =="
no    "budget: 0 checkpoints -> not exhausted"          checkpoint_budget_exhausted 0
no    "budget: 7 checkpoints -> not exhausted"          checkpoint_budget_exhausted 7
ok    "budget: 8 checkpoints -> exhausted (escalate)"   checkpoint_budget_exhausted 8
ok    "budget: 20 checkpoints -> exhausted"             checkpoint_budget_exhausted 20
no    "budget: empty arg -> treated as 0"               checkpoint_budget_exhausted ""

echo "== final title derivation on finalize (igor#572) =="
# igor#569: a resumed branch's newest commit was a small cleanup ("docs: note
# the CEO stage removal..."), so titling from `git log --pretty=%s | head -1`
# mistitled a PR that actually retired the whole CEO cascade stage. The fix:
# derive the title from PR_BODY.md's first checklist item instead, falling
# back to the (git-log-derived) commit subject only when the file is absent
# or unparseable -- and the fallback path must be observable (rc!=0) so the
# caller can log it.
BODY_OK="$TMP/pr_body_ok.md"
cat >"$BODY_OK" <<'EOF'
## What this PR does

- [x] chore: retire the CEO cascade stage (phase 1 -- unwire only)
- [x] Unwire the retired stage's gate and its per-tick file-output helper

## Test plan

- [x] make test
EOF
eq "final_title: uses PR_BODY.md's first item, not the last commit" \
   "chore: retire the CEO cascade stage (phase 1 -- unwire only)" \
   "$(checkpoint_final_title "$BODY_OK" 'docs: note the CEO stage removal in CLAUDE.md')"
ok "final_title: rc0 when derived from the body" \
   checkpoint_final_title "$BODY_OK" 'docs: note the CEO stage removal in CLAUDE.md'

NO_BODY="$TMP/pr_body_missing.md"
rm -f "$NO_BODY"
eq "final_title: no PR_BODY.md -> falls back to the commit subject" \
   "fix: the actual thing" \
   "$(checkpoint_final_title "$NO_BODY" 'fix: the actual thing')"
no "final_title: rc!=0 (fallback) when PR_BODY.md is absent -- caller must log" \
   checkpoint_final_title "$NO_BODY" 'fix: the actual thing'

BODY_UNPARSEABLE="$TMP/pr_body_unparseable.md"
cat >"$BODY_UNPARSEABLE" <<'EOF'
Just some prose with no "What this PR does" checklist at all.
EOF
eq "final_title: unparseable first item -> falls back to the commit subject" \
   "fix: the actual thing" \
   "$(checkpoint_final_title "$BODY_UNPARSEABLE" 'fix: the actual thing')"
no "final_title: rc!=0 (fallback) on an unparseable body -- caller must log" \
   checkpoint_final_title "$BODY_UNPARSEABLE" 'fix: the actual thing'

# a first item that is plain prose (no conventional-commit prefix) is the
# common non-conventional case: it must be normalized, not rejected.
BODY_PROSE="$TMP/pr_body_prose.md"
printf '## What this PR does\n\n- [x] Add the thing\n' >"$BODY_PROSE"
eq "final_title: plain-prose first item gets a conventional prefix" \
   "chore: Add the thing" "$(checkpoint_final_title "$BODY_PROSE" 'fix: fallback')"
ok "final_title: rc0 on a plain-prose first item" \
   checkpoint_final_title "$BODY_PROSE" 'fix: fallback'

# a whitespace-only first item passes a raw [ -n ] test but normalizes to a
# bare "chore: " -- a junk title that would silently replace the WIP one and
# leave nobody a write path to fix it. Must land on the logged fallback.
BODY_BLANK_ITEM="$TMP/pr_body_blank_item.md"
printf '## What this PR does\n\n- [x]    \n' >"$BODY_BLANK_ITEM"
eq "final_title: whitespace-only first item -> falls back, not 'chore: '" \
   "fix: the actual thing" "$(checkpoint_final_title "$BODY_BLANK_ITEM" 'fix: the actual thing')"
no "final_title: rc!=0 (fallback) on a whitespace-only first item" \
   checkpoint_final_title "$BODY_BLANK_ITEM" 'fix: the actual thing'

# the lib/claude.sh dependency is not sourced by lib/checkpoint.sh itself. A
# caller that sources checkpoint.sh alone must land on the fallback tier (which
# the caller logs), not abort the finalize path with `command not found`.
eq "final_title: missing pr_body_first_item -> fallback, not a hard error" \
   "fix: the actual thing" \
   "$(unset -f pr_body_first_item; checkpoint_final_title "$BODY_OK" 'fix: the actual thing')"
eq "final_title: missing normalize_subject -> fallback, not a hard error" \
   "fix: the actual thing" \
   "$(unset -f normalize_subject; checkpoint_final_title "$BODY_OK" 'fix: the actual thing')"

# negative test: prove the OLD derivation (newest non-WIP commit subject) is
# what mistitled igor#569 -- i.e. that the fix above is actually load-bearing.
ne "final_title: body-derived title differs from (and fixes) the commit-subject title" \
   "docs: note the CEO stage removal in CLAUDE.md" \
   "$(checkpoint_final_title "$BODY_OK" 'docs: note the CEO stage removal in CLAUDE.md')"

# checkpoint_final_title must stay the SAME derivation bin/tick.sh's
# derive_commit_subject (tier 1) uses for a single-run PR's title, not a
# divergent one -- a guard against the two drifting apart, since a non-resumed
# PR never calls checkpoint_final_title and so can't catch that here:
eq "final_title: same body derivation derive_commit_subject's tier 1 uses" \
   "$(normalize_subject "$(pr_body_first_item "$BODY_OK")")" \
   "$(checkpoint_final_title "$BODY_OK" 'chore: fallback')"

# ---- the forgejo.sh helpers the checkpoint flow depends on ----------------
# The discovery gate + resume detector key off forgejo_bot_prs_for_issue's title
# field; the counter-bump + WIP-drop go through forgejo_edit_pr. Stub _fj -- no
# network. (forgejo.sh is just function defs; safe to source.)
# shellcheck source=../lib/forgejo.sh
. "$HERE/../lib/forgejo.sh"

echo "== forgejo_bot_prs_for_issue: title field + the gate/resume filters =="
_fj() { cat <<'JSON'
[
 {"number":10,"state":"open","title":"WIP: fix the thing","user":{"login":"igor"},"body":"wip\n\nCloses #351"},
 {"number":11,"state":"open","title":"feat: other","user":{"login":"igor"},"body":"Closes #351"},
 {"number":12,"state":"closed","title":"old","user":{"login":"igor"},"merged":false,"body":"Closes #351"},
 {"number":13,"state":"open","title":"not the bot","user":{"login":"human"},"body":"Closes #351"}
]
JSON
}
HIST=$(forgejo_bot_prs_for_issue acme/x 351 igor)
eq  "bot_prs: only the bot's PRs referencing #351 (3 of 4)" "3" "$(jq 'length' <<<"$HIST")"
has "bot_prs: entries carry the title field"                "$(jq -r '.[0].title' <<<"$HIST")" "WIP: fix the thing"
# discovery gate's EXACT filter (tick.sh): open AND not-WIP -> in flight -> skip
GATE=$(jq --arg wip "$CHECKPOINT_WIP_PREFIX" '[.[]|select(.state=="open" and ((.title//"")|startswith($wip)|not))]|length' <<<"$HIST")
eq  "gate: only the real open PR (#11) blocks the claim, not the WIP" "1" "$GATE"
# resume detector's EXACT filter (tick.sh): open AND WIP -> resume this PR
RESUME=$(jq -r --arg wip "$CHECKPOINT_WIP_PREFIX" '[.[]|select(.state=="open" and ((.title//"")|startswith($wip)))]|first|.number//empty' <<<"$HIST")
eq  "resume: locates the open WIP checkpoint PR (#10)" "10" "$RESUME"

echo "== forgejo_edit_pr: PATCH payload (counter bump / WIP drop) =="
_fj() { printf '%s' "$1" >"$TMP/m"; printf '%s' "$2" >"$TMP/p"; printf '%s' "$3" >"$TMP/b"; }
forgejo_edit_pr acme/x 10 --title "ready: x" --body "done"
eq  "edit_pr: method is PATCH"                 "PATCH"                    "$(cat "$TMP/m")"
eq  "edit_pr: hits the issues endpoint"        "/repos/acme/x/issues/10"  "$(cat "$TMP/p")"
eq  "edit_pr: title lands in the payload"      "ready: x"                 "$(jq -r '.title' "$TMP/b")"
eq  "edit_pr: body lands in the payload"       "done"                     "$(jq -r '.body' "$TMP/b")"
forgejo_edit_pr acme/x 10 --body "$(checkpoint_set_count 'orig body' 3)"
eq  "edit_pr: body-only omits the title key"   "null"                     "$(jq -r '.title // "null"' "$TMP/b")"
eq  "edit_pr: counter round-trips through edit" "3" "$(checkpoint_read_count "$(jq -r '.body' "$TMP/b")")"

echo "== pr_body_ensure_closes: guarantee an auto-close keyword (#372) =="
eq  "empty issue -> body unchanged"        "keep me" "$(pr_body_ensure_closes 'keep me' '')"
has "no keyword -> appends Closes #369"    "$(pr_body_ensure_closes 'did the work' '369')" "Closes #369"
has "append preserves the original body"   "$(pr_body_ensure_closes 'did the work' '369')" "did the work"
eq  "already 'Closes #369' -> unchanged"   "fix\n\nCloses #369" "$(pr_body_ensure_closes 'fix\n\nCloses #369' '369')"
eq  "already 'Fixes #369' -> unchanged"    "Fixes #369" "$(pr_body_ensure_closes 'Fixes #369' '369')"
eq  "already 'resolved #369' -> unchanged" "resolved #369" "$(pr_body_ensure_closes 'resolved #369' '369')"
lacks "case-insensitive match doesn't double" "$(pr_body_ensure_closes 'CLOSES #369' '369')" "Closes #369"
has "'#3690' does NOT satisfy #369 -> appends" "$(pr_body_ensure_closes 'see #3690' '369')" "Closes #369"
has "keyword for a DIFFERENT issue -> still appends" "$(pr_body_ensure_closes 'Closes #12' '369')" "Closes #369"
# idempotent: a second pass over an appended body must not add a second keyword
ONCE=$(pr_body_ensure_closes 'work' '369'); TWICE=$(pr_body_ensure_closes "$ONCE" '369')
eq  "idempotent -> second pass is a no-op" "$ONCE" "$TWICE"

if [ "$FAIL" -eq 0 ]; then echo "test-checkpoint: ALL PASS"; else echo "test-checkpoint: $FAIL FAILED"; exit 1; fi
