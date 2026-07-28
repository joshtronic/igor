#!/usr/bin/env bash
# test-reviewnotify.sh -- unit tests for lib/reviewnotify.sh, the email Igor
# sends when it puts a PR on the operator's desk (igor#439).
#
# Two things have to hold, and they fail in opposite directions:
#
#   1. The mail actually goes out. The operator runs with Forgejo's own
#      notifications OFF, so a notification Igor swallows is a PR that sits
#      there unseen -- the exact failure this feature exists to fix.
#   2. It goes out ONCE per head. forgejo_request_review is idempotent and
#      callers fire it freely, so a naive hook re-mails on every call and
#      rebuilds the flood the operator turned Forgejo off to escape.
#
# The last section drives the REAL forgejo_request_review with only its
# documented HTTP seam stubbed, because "the hook is wired at all" is the one
# thing the pure tests above cannot see.
#
# Skip-safe: needs jq; exits 0 with a notice if absent.
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "test-reviewnotify: jq absent -- skipping"; exit 0; }

HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/reviewnotify.sh
. "$HERE/lib/reviewnotify.sh"

FAIL=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi; }
has() {  # <desc> <haystack> <needle>
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1: [$2] does not contain [$3]" ;; esac
}

echo "== dedup: the key is repo#number + head sha =="
SEEN='{"review_notified":{"joshtronic/igor#42":"abc123"}}'
if reviewnotify_should_send "$SEEN" joshtronic/igor 42 abc123; then
  bad "same PR + same head is suppressed"
else ok "same PR + same head is suppressed"; fi
if reviewnotify_should_send "$SEEN" joshtronic/igor 42 def456; then
  ok "a NEW head on the same PR sends again"
else bad "a NEW head on the same PR sends again"; fi
if reviewnotify_should_send "$SEEN" joshtronic/igor 43 abc123; then
  ok "a different PR sends even at a sha-collision"
else bad "a different PR sends even at a sha-collision"; fi
if reviewnotify_should_send "$SEEN" joshtronic/porksicle.com 42 abc123; then
  ok "the same number in another repo is a different key"
else bad "the same number in another repo is a different key"; fi

echo "== dedup fails OPEN (a missed alert beats a duplicate) =="
for CASE in "empty state:" "empty object:{}" "no map:{\"review\":{}}" \
            "garbage state:not json at all" "truncated json:{\"review_notified\":"; do
  DESC="${CASE%%:*}"; STATE="${CASE#*:}"
  if reviewnotify_should_send "$STATE" joshtronic/igor 42 abc123; then
    ok "$DESC -> send"
  else bad "$DESC -> send"; fi
done
if reviewnotify_should_send "$SEEN" joshtronic/igor 42 ""; then
  ok "an empty head (PR fetch failed) -> send, not swallow"
else bad "an empty head (PR fetch failed) -> send, not swallow"; fi

echo "== the message says which PR and why =="
SUB=$(reviewnotify_subject joshtronic/igor 42 "feat: a thing")
has "subject carries the repo"   "$SUB" "joshtronic/igor"
has "subject carries the number" "$SUB" "#42"
has "subject carries the title"  "$SUB" "feat: a thing"
eq  "a missing title does not produce a bare dangling subject" \
    "[Agent] Needs you: joshtronic/igor#42 -- untitled" "$(reviewnotify_subject joshtronic/igor 42 '')"

B=$(reviewnotify_body joshtronic/igor 42 "feat: a thing" COMMENT "https://git.example/pr/42")
has "body carries the URL"   "$B" "https://git.example/pr/42"
has "body carries the title" "$B" "feat: a thing"
has "COMMENT explains auto-merge will not take it" "$B" "auto-merge will not take"
has "APPROVE explains the repo is human-gated" \
    "$(reviewnotify_body r 1 t APPROVE u)" "pinned to your review"
has "REQUEST_CHANGES explains the escalation" \
    "$(reviewnotify_body r 1 t REQUEST_CHANGES u)" "escalated to you"
has "an unknown/absent verdict still says something true" \
    "$(reviewnotify_body r 1 t '' u)" "handed this one to you"

echo "== review_notify_human: sends once per head, records only on success =="
TMPDIR_T=$(mktemp -d); trap 'rm -rf "$TMPDIR_T"' EXIT
export AGENT_STATE_DIR="$TMPDIR_T"
STATE="$TMPDIR_T/discretionary-state.json"
export SMTP2GO_API_KEY=k SMTP2GO_SENDER=s PRIMARY_RECIPIENTS=op@example.com

SENDS=0; LAST_SUBJECT=""; LAST_HTML=""; LAST_BODY=""; SEND_RC=0
recipients_with_primary() { printf '%s' "${PRIMARY_RECIPIENTS:-}"; }
email_send() {
  SENDS=$((SENDS + 1)); LAST_SUBJECT="$1"; LAST_HTML="$2"; LAST_BODY="$3"; return "$SEND_RC"
}
PR_SHA=aaaa111
forgejo_get_pr() {
  jq -n --arg s "$PR_SHA" \
    '{head:{sha:$s}, title:"feat: a thing", html_url:"https://git.example/pr/42"}'
}
log() { :; }

review_notify_human joshtronic/igor 42
eq "first request emails" "1" "$SENDS"
has "the email names the PR" "$LAST_SUBJECT" "joshtronic/igor#42"
eq "the head is recorded" "$PR_SHA" \
   "$(jq -r '.review_notified["joshtronic/igor#42"] // ""' "$STATE")"

review_notify_human joshtronic/igor 42
eq "a repeat request on the SAME head does not re-email" "1" "$SENDS"
review_notify_human joshtronic/igor 42
eq "and still does not on the third" "1" "$SENDS"

PR_SHA=bbbb222
review_notify_human joshtronic/igor 42
eq "a NEW head emails again" "2" "$SENDS"
eq "and the new head replaces the old" "bbbb222" \
   "$(jq -r '.review_notified["joshtronic/igor#42"] // ""' "$STATE")"

echo "== a failed send is retried, not marked delivered =="
PR_SHA=cccc333; SEND_RC=1
review_notify_human joshtronic/igor 42
eq "the send was attempted" "3" "$SENDS"
eq "a failed send records NOTHING" "bbbb222" \
   "$(jq -r '.review_notified["joshtronic/igor#42"] // ""' "$STATE")"
SEND_RC=0
review_notify_human joshtronic/igor 42
eq "so the next request retries it" "4" "$SENDS"
eq "and now it records" "cccc333" \
   "$(jq -r '.review_notified["joshtronic/igor#42"] // ""' "$STATE")"

echo "== the verdict in review state becomes the reason =="
jq '.review["joshtronic/igor#42"] = {verdict:"COMMENT"}' "$STATE" > "$STATE.t" && mv "$STATE.t" "$STATE"
PR_SHA=dddd444
review_notify_human joshtronic/igor 42
has "COMMENT verdict is explained in the body" "$LAST_BODY" "auto-merge will not take"

echo "== a PR whose fetch fails alerts, but not once per call =="
forgejo_get_pr() { return 1; }
SENDS_BEFORE=$SENDS
review_notify_human joshtronic/igor 99
eq "no PR detail -> still emails (the operator is still blocked)" \
   "$((SENDS_BEFORE + 1))" "$SENDS"
review_notify_human joshtronic/igor 99
review_notify_human joshtronic/igor 99
eq "a stuck fetch is capped, not an email per call site per tick" \
   "$((SENDS_BEFORE + 1))" "$SENDS"
has "and it keys on an hour bucket, not an empty sha" \
    "$(jq -r '.review_notified["joshtronic/igor#99"] // ""' "$STATE")" "nohead-"
forgejo_get_pr() {
  jq -n --arg s "$PR_SHA" \
    '{head:{sha:$s}, title:"feat: a thing", html_url:"https://git.example/pr/42"}'
}
PR_SHA=ffff666
review_notify_human joshtronic/igor 99
eq "a fetch that recovers is a head nobody has seen -> sends" \
   "$((SENDS_BEFORE + 2))" "$SENDS"

echo "== the PR title is not Igor's prose: it cannot inject HTML =="
forgejo_get_pr() {
  jq -n --arg s "$PR_SHA" \
    '{head:{sha:$s}, title:"<script>x</script> & co", html_url:"u"}'
}
PR_SHA=1111aaa
review_notify_human joshtronic/igor 42
has "the HTML part escapes the angle brackets" "$LAST_HTML" "&lt;script&gt;"
case "$LAST_HTML" in
  *"<script>"*) bad "no raw tag survives into the HTML part" ;;
  *)            ok  "no raw tag survives into the HTML part" ;;
esac
has "and the ampersand"                  "$LAST_HTML" "&amp; co"
has "the plain-text part is left alone"  "$LAST_BODY" "<script>x</script>"
forgejo_get_pr() {
  jq -n --arg s "$PR_SHA" \
    '{head:{sha:$s}, title:"feat: a thing", html_url:"https://git.example/pr/42"}'
}

echo "== only a request FOR the operator is worth mailing him =="
export FORGEJO_REVIEWER=josh
SENDS_BEFORE=$SENDS; PR_SHA=2222bbb
review_notify_human joshtronic/igor 42 someone-else
eq "a request for somebody else does not email the operator" "$SENDS_BEFORE" "$SENDS"
review_notify_human joshtronic/igor 42 josh
eq "his own request does" "$((SENDS_BEFORE + 1))" "$SENDS"
PR_SHA=3333ccc
review_notify_human joshtronic/igor 42
eq "an unnamed reviewer fails open, like the rest of this module" \
   "$((SENDS_BEFORE + 2))" "$SENDS"

echo "== a state dir that does not exist yet is created, not lost =="
SAVED_DIR="$AGENT_STATE_DIR"
export AGENT_STATE_DIR="$TMPDIR_T/never/made/before"
PR_SHA=4444ddd
review_notify_human joshtronic/igor 7
eq "dedup records in a freshly created state dir" "4444ddd" \
   "$(jq -r '.review_notified["joshtronic/igor#7"] // ""' \
      "$AGENT_STATE_DIR/discretionary-state.json" 2>/dev/null)"
export AGENT_STATE_DIR="$SAVED_DIR"

echo "== email off / no recipients: quiet, not crashing =="
# Deliberately NOT `( unset ...; review_notify_human ... )`: a subshell throws
# away the SENDS increment, so the assertion would pass whether the guard works
# or not. Save and restore in THIS shell instead.
SENDS_BEFORE=$SENDS
SAVED_KEY="$SMTP2GO_API_KEY"; unset SMTP2GO_API_KEY
review_notify_human joshtronic/igor 42
eq "no SMTP key -> no send" "$SENDS_BEFORE" "$SENDS"
export SMTP2GO_API_KEY="$SAVED_KEY"

SAVED_RCPT="$PRIMARY_RECIPIENTS"; PRIMARY_RECIPIENTS=""
review_notify_human joshtronic/igor 42
eq "no recipients -> no send" "$SENDS_BEFORE" "$SENDS"
PRIMARY_RECIPIENTS="$SAVED_RCPT"

# Guard the guard: with everything restored a send must happen again, or the
# two assertions above would pass on a permanently-wedged notifier.
PR_SHA=eeee555
review_notify_human joshtronic/igor 42
eq "restoring the config re-enables sending" "$((SENDS_BEFORE + 1))" "$SENDS"

echo "== the hook is actually wired into forgejo_request_review =="
# The point of this block: every test above would pass just as happily if
# lib/forgejo.sh never called the notifier at all. So drive the REAL function
# with only _forgejo_post_reviewers -- its documented test seam -- stubbed.
export FORGEJO_URL="https://example.invalid" FORGEJO_TOKEN="test-token"
# shellcheck source=../lib/forgejo.sh
. "$HERE/lib/forgejo.sh"

HOOKED=""
# ${3:-} deliberately: a hook called with the reviewer dropped must produce a
# readable assertion failure, not an unbound-variable abort that takes the
# whole suite down before it can report which check broke.
review_notify_human() { HOOKED="$1#$2 -> ${3:-}"; }

_forgejo_post_reviewers() { printf '\n201'; }
forgejo_request_review joshtronic/igor 42 josh
eq "a request that LANDS fires the notifier, reviewer and all" \
   "joshtronic/igor#42 -> josh" "$HOOKED"

HOOKED=""
_forgejo_post_reviewers() { printf 'nope\n422'; }
forgejo_request_review joshtronic/igor 42 josh 2>/dev/null
eq "a REJECTED request does not email" "" "$HOOKED"

HOOKED=""
_forgejo_post_reviewers() { printf '\n000'; }
forgejo_request_review joshtronic/igor 42 josh 2>/dev/null
eq "an unreachable instance does not email" "" "$HOOKED"

# A notifier that blows up must not turn a landed request into a failed one --
# the request already succeeded server-side.
review_notify_human() { return 3; }
_forgejo_post_reviewers() { printf '\n201'; }
forgejo_request_review joshtronic/igor 42 josh
eq "a failing notifier does not fail the request" "0" "$?"

# And the hook is optional: bin/agent-*.sh source forgejo.sh without it.
unset -f review_notify_human
forgejo_request_review joshtronic/igor 42 josh
eq "with no notifier defined at all, the request still succeeds" "0" "$?"

if [ "$FAIL" -eq 0 ]; then
  echo "test-reviewnotify: all checks passed"
else
  echo "test-reviewnotify: $FAIL FAILED"
  exit 1
fi
