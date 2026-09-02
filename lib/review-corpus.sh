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

if ! declare -F log >/dev/null; then
  log() { printf '[agent] %s\n' "$*" >&2; }
fi

# The jq program backing review_corpus_trajectory. Kept as one constant so
# the shell wrapper stays a thin plumbing layer -- everything provable is in
# here, over JSON text, so a bug in it fails a test rather than a production
# comment post.
#
# Design notes on the two judgement calls that AREN'T just "count the
# headers":
#
#   - A dismissal's "round" is 1 + however many review artifacts preceded it
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
read -r -d '' REVIEW_CORPUS_JQ <<'JQ_EOF'
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

# Lines of a comment body that carry actual content -- not the fixed
# template scaffolding shared by every artifact of a kind. Short lines
# (< 8 chars trimmed) are dropped too: too easy to "overlap" by accident
# ("ok.", "done").
def is_boilerplate:
  test("^### ")
  or test("^CI for `")
  or test("^---$")
  or test("^<!--")
  or test("^<sub>")
  or test("No code changes: the agent judged every point raised")
  or test("The rest of the findings were addressed in the commits");

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
