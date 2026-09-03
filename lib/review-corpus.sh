#!/usr/bin/env bash
# review-corpus.sh -- parse a PR's comment thread into a review-loop
# trajectory. No network calls, no model calls: pure functions over the
# comment JSON the review loop already produces (igor#582).
#
# The bot can't self-review (Forgejo 422s a review on your own PR), so every
# review/rework/dismissal event lands as a plain issue comment with a
# structured header (do_review_tick / bin/tick.sh's rework flow /
# lib/adjudication.sh). This file recognizes exactly those three headers and
# turns the ordered comment list into one record per PR:
#
#   ### 🤖 Review — `VERDICT` _(automated)_
#   ### 🔧 Rework — round N _(automated)_
#   ### 🧑‍⚖️ Rework — findings dismissed _(automated)_
#
# Header matching is ANCHORED to the start of the (whitespace-trimmed)
# comment body. A comment that merely quotes one of these headers inside a
# fenced code block -- to explain the convention, say -- has other text
# before the header, so the anchor excludes it. Matching on "contains"
# instead would count every such quote as a real artifact and silently
# inflate every figure downstream.

# The jq program backing review_corpus_trajectory. Kept as one constant so
# the shell wrapper stays a thin plumbing layer -- everything provable is in
# here, over JSON text, so a bug in it fails a test rather than a production
# comment post.
#
# Design notes on the two judgement calls that AREN'T just "count the
# headers":
#
#   - A dismissal's "round" is however many review artifacts preceded it
#     -- i.e. which review cycle it's answering -- rather than the round
#     number in a same-round "Rework -- round N" comment, because a
#     dismiss-only round (no commits) never gets one of those at all
#     (bin/tick.sh's converged branch posts only the dismissal comment).
#
#   - "the same finding was raised again" is decided by literal line overlap
#     between the dismissal's own text and a LATER review's text, after
#     stripping the fixed template scaffolding (headers, the CI line, the
#     "---" separator, the <sub>/<!-- --> footer, the two fixed adjudication
#     tail sentences) from both. That scaffolding is identical across every
#     artifact of a given kind, so leaving it in would make two unrelated
#     REQUEST_CHANGES reviews "overlap" on the header line alone. What's left
#     after stripping is the model's own freeform prose -- the actual finding
#     text -- so a literal repeat of a line in it is a real signal, not
#     resemblance by boilerplate.
#
#     Measured 2026-09-02 across the last 25 merged PRs of igor, joshing.you,
#     sharktankdb.com and snail.io: 48 dismissals, 46 with a later review, and
#     ZERO sharing a literal content line. Neither side quotes the other -- the
#     dismissal argues in its own words and the next review restates the point
#     in its own. So `finding_reraised` is a LOWER BOUND, not a measured rate:
#     read a 0 as "no verbatim repeat found", never as "the reviewer accepted
#     every dismissal". Catching the real thing needs a semantic comparison,
#     which means a model call -- explicitly the follow-on ticket's job, not
#     this one's (igor#582 is deliberately model-free). Loosening this to fuzzy
#     matching instead would manufacture false positives in exactly the figures
#     the scorecard exists to keep honest.
#
# `|| true` because `read -d ''` returns nonzero when it reaches EOF without
# finding a NUL -- which a heredoc never contains. The variable is still set;
# without it, sourcing this file from a script under `set -e` would exit the
# shell right here.
read -r -d '' REVIEW_CORPUS_JQ <<'JQ_EOF' || true
def strip_lead: sub("^\\s+"; "");

def classify:
  (.body // "") as $raw
  | ($raw | strip_lead) as $b
  | if ($b | test("^### 🤖 Review — `(APPROVE|REQUEST_CHANGES|COMMENT)` _\\(automated\\)_")) then
      { kind: "review",
        verdict: ($b | capture("^### 🤖 Review — `(?<v>APPROVE|REQUEST_CHANGES|COMMENT)` _\\(automated\\)_").v) }
    elif ($b | test("^### 🔧 Rework — round [0-9]+ _\\(automated\\)_")) then
      { kind: "rework" }
    elif ($b | test("^### 🧑‍⚖️ Rework — findings dismissed _\\(automated\\)_")) then
      { kind: "dismissal" }
    else
      { kind: "other" }
    end;

# One line of the fixed template scaffolding shared by every artifact of a
# kind, as opposed to a line carrying the model's own prose.
def is_boilerplate:
  test("^### ")
  or test("^CI for `")
  or test("^---$")
  or test("^<!--")
  or test("^<sub>")
  or test("No code changes: the agent judged every point raised")
  or test("The rest of the findings were addressed in the commits");

# The lines of a comment body that carry actual content: scaffolding dropped,
# and short lines (< 8 chars trimmed) with it -- those are too easy to
# "overlap" by accident ("ok.", "done").
def content_fingerprint($body):
  ($body // "" | split("\n"))
  | map(gsub("^\\s+|\\s+$"; ""))
  | map(select(length >= 8))
  | map(select(is_boilerplate | not))
  | map(ascii_downcase)
  | unique;

def intersects($a; $b): (($a - ($a - $b)) | length) > 0;

( [ .[] | {body: (.body // ""), created_at: (.created_at // "")} ] | sort_by(.created_at) ) as $sorted
| ($sorted | map(. + classify)) as $tagged
| ($tagged | map(select(.kind != "other"))) as $artifacts
| if ($artifacts | length) == 0 then
    {}
  else
    ($artifacts | map(select(.kind == "review"))) as $reviews
    | ($artifacts | map(select(.kind == "rework"))) as $reworks
    | ($artifacts | to_entries | map(select(.value.kind == "dismissal"))) as $dismissal_entries
    | ( $dismissal_entries | map(
          .key as $idx
          | .value as $d
          | ($artifacts[0:$idx] | map(select(.kind == "review")) | length) as $round
          | ($artifacts[($idx + 1):] | map(select(.kind == "review"))) as $later_reviews
          | ( ($later_reviews | length) > 0 and ($later_reviews[0].verdict == "APPROVE") ) as $followed_by_approve
          | content_fingerprint($d.body) as $dfp
          | ( $later_reviews | any(content_fingerprint(.body) as $rfp | intersects($dfp; $rfp)) ) as $reraised
          | { round: $round, followed_by_approve: $followed_by_approve, reraised: $reraised }
        )
      ) as $dismissals
    | {
        verdicts: ($reviews | map(.verdict)),
        review_rounds: ($reviews | length),
        rework_rounds: ($reworks | length),
        dismissals: $dismissals,
        dismissal_count: ($dismissals | length),
        dismissed_then_approved: ($dismissals | any(.followed_by_approve)),
        finding_reraised: ($dismissals | any(.reraised)),
        terminal_verdict: ($reviews | if length > 0 then last.verdict else null end),
        merged: (if $merged == "true" then true elif $merged == "false" then false else null end)
      }
  end
JQ_EOF

# review_corpus_trajectory [<comments_json>] [<merged: true|false>]
# Parse one PR's comment list (Forgejo's GET .../issues/{n}/comments shape:
# an array of {user, body, created_at, ...}) into a trajectory record.
#
# <comments_json> may be omitted (or empty) to read from stdin instead, so
# this composes with `forgejo_pr_comments repo n | review_corpus_trajectory`.
# <merged> is not derivable from the comments themselves -- Forgejo's merge
# event isn't one of them -- so the caller (which already has the PR object)
# passes it in; omitted it reads as unknown (null), not false.
#
# A PR with zero recognized artifacts (human-only thread) returns `{}`
# rather than a record of zeroed-out fields -- that keeps "nothing automated
# happened here" distinguishable from "one review happened and everything
# is legitimately 0/false".
review_corpus_trajectory() {
  local comments="${1:-}" merged="${2:-unknown}"
  [ -n "$comments" ] || comments=$(cat)
  case "$merged" in
    true | false) ;;
    *) merged="unknown" ;;
  esac
  jq -c --arg merged "$merged" "$REVIEW_CORPUS_JQ" <<<"$comments"
}

# The aggregation behind bin/review-scorecard.sh. It lives here, beside the
# parser, for the same reason the parser's own logic does: every figure the
# operator reads comes out of this program, so it has to be assertable over
# synthetic records with no network in the loop. Inline in the script it was
# reachable only by running the whole thing against a live forge.
read -r -d '' REVIEW_SCORECARD_JQ <<'JQ_EOF' || true
def pct($n; $d): if $d == 0 then 0 else (($n * 1000 / $d) | round) / 10 end;

. as $records
| ($records | length) as $scored
| ($records | map(.verdicts[]) ) as $verdicts
| ($verdicts | length) as $vcount
| (["APPROVE","REQUEST_CHANGES","COMMENT"] | map(. as $v | {verdict: $v, n: ($verdicts | map(select(. == $v)) | length)})) as $mix
| ($records | map(.review_rounds) | sort) as $rounds
| ($rounds | length) as $rn
| ( if $rn == 0 then 0
    elif ($rn % 2) == 1 then $rounds[($rn - 1) / 2]
    else (($rounds[($rn / 2) - 1] + $rounds[$rn / 2]) / 2)
    end ) as $median_rounds
| ((($rounds | add // 0) * 10 / (if $rn == 0 then 1 else $rn end) | round) / 10) as $mean_rounds
| ($records | map(.rework_rounds) | add // 0) as $total_rework_rounds
| ($records | map(.dismissal_count) | add // 0) as $total_dismissals
| ($records | map(select(.dismissal_count > 0)) | length) as $prs_with_dismissal
| ($records | map(select(.dismissed_then_approved)) | length) as $dismissed_then_approved
| ($records | map(select(.finding_reraised)) | length) as $finding_reraised
| (
    "== review scorecard =="
    , "PRs scored (had automated review artifacts): \($scored) of \($total_merged) merged"
    , (if $unfetched > 0 then
         "\($unfetched) merged PR(s) excluded: their comments could not be fetched"
       else empty end)
    , ""
    , "Review-verdict artifacts: \($vcount)"
    , ($mix[] | "  \(.verdict): \(.n) (\(pct(.n; $vcount))%)")
    , ""
    , "Review rounds to merge: mean \($mean_rounds), median \($median_rounds)"
    , "Rework rounds (commits pushed after a review): \($total_rework_rounds)"
    , ""
    , "Dismissal comments: \($total_dismissals)"
    , "PRs with at least one dismissal: \($prs_with_dismissal) of \($scored) (\(pct($prs_with_dismissal; $scored))%)"
    , "Dismissed-then-approved PRs: \($dismissed_then_approved)"
    , "PRs where a dismissed finding reappeared verbatim in a later review: \($finding_reraised)"
    , "  (a lower bound: only a literal shared line counts, so a finding restated"
    , "   in different words is invisible here; see lib/review-corpus.sh)"
  )
JQ_EOF

# review_corpus_scorecard <records_file> <total_merged> [<unfetched>]
# Render the aggregate report over a file of trajectory records, one compact
# JSON object per line (the shape review_corpus_trajectory emits).
# <total_merged> is the denominator for "scored N of M merged" -- a PR with no
# automated artifacts produces no record, so it can't be counted from these.
# <unfetched> is how many merged PRs the caller couldn't read the comments of.
# Those are indistinguishable from human-only PRs once they reach here (both
# are simply absent), and every one of them deflates the scored count and the
# denominator of every percentage -- so the count is printed with the figures
# it qualifies, not just warned about on stderr.
review_corpus_scorecard() {
  local records="$1" total_merged="${2:-0}" unfetched="${3:-0}"
  jq -s -r --argjson total_merged "$total_merged" --argjson unfetched "$unfetched" \
    "$REVIEW_SCORECARD_JQ" "$records"
}
