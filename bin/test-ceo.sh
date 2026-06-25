#!/usr/bin/env bash
# test-ceo.sh -- unit tests for the pure functions in lib/ceo.sh.
#
# Covers the directly-testable surface the CEO digest leans on:
#   - ceo_parse_response  (sentinel parsing + blank-collapsing awk)
#   - ceo_render_html     (markdown -> HTML, with escaping)
#   - ceo_week_done / ceo_mark_week_done  (per-repo weekly state round-trip)
#   - ceo_gather_week     (the jq activity filters, with _fj stubbed)
#
# Run standalone (`bin/test-ceo.sh`) or via `make test` -- check-sync.sh
# discovers and runs every bin/test-*.sh. Skip-safe: if a required tool is
# absent it exits 0 with a notice, so a minimal CI image stays green while
# this acts as a real gate wherever the deps exist.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"

for tool in jq awk sed date mktemp; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "test-ceo: $tool not installed -- skipping"; exit 0; }
done

# shellcheck source=lib/ceo.sh
. "$HERE/lib/ceo.sh"

fails=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; fails=$((fails + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi; }
has()    { case "$2" in *"$3"*) ok "$1";; *) bad "$1: missing [$3]";; esac; }
hasnt()  { case "$2" in *"$3"*) bad "$1: unexpected [$3]";; *) ok "$1";; esac; }

# ---- ceo_parse_response -------------------------------------------------
echo "== ceo_parse_response =="
run_parse() {  # <raw> -- sets RC and OUT (RC=1 on parse failure)
  if OUT=$(ceo_parse_response "$1"); then RC=0; else RC=1; fi
}

run_parse "$(printf 'SUBJECT: Week of Jun 18\n===BODY===\nFirst line.\nSecond line.')"
eq "happy: rc 0"     0 "$RC"
eq "happy: subject"  "Week of Jun 18"                   "$(jq -r '.subject' <<<"$OUT")"
eq "happy: body"     "$(printf 'First line.\nSecond line.')" "$(jq -r '.body' <<<"$OUT")"

run_parse "$(printf 'SUBJECT: x\nno sentinel anywhere')"
eq "missing ===BODY===: rc 1" 1 "$RC"

run_parse "$(printf 'SUBJECT: x\n===BODY===\n   \n\t')"
eq "whitespace-only body: rc 1" 1 "$RC"

run_parse "$(printf '===BODY===\nBody with no subject line.')"
eq "no SUBJECT: rc 0"        0 "$RC"
eq "no SUBJECT: empty subj"  "" "$(jq -r '.subject' <<<"$OUT")"
eq "no SUBJECT: body kept"   "Body with no subject line." "$(jq -r '.body' <<<"$OUT")"

run_parse "$(printf 'SUBJECT: t\n===BODY===\n\n\nAlpha.\n\nOmega.\n\n')"
eq "blank-collapse: leading/trailing trimmed, interior kept" \
   "$(printf 'Alpha.\n\nOmega.')" "$(jq -r '.body' <<<"$OUT")"

# ---- ceo_parse_response: proposals (===ISSUE=== blocks) -----------------
echo "== ceo_parse_response proposals =="

run_parse "$(printf 'SUBJECT: s\n===BODY===\nThe digest.')"
eq "no proposals: issues == []" "[]" "$(jq -c '.issues' <<<"$OUT")"

run_parse "$(printf 'SUBJECT: s\n===BODY===\nThe digest.\n===ISSUE===\nTITLE: Internal linking\nAdd related-games links.\nServes priority #1.\n===ISSUE===\nTITLE: Hub copy\nFlesh out category hubs.')"
eq "two proposals: count"         2 "$(jq '.issues | length' <<<"$OUT")"
eq "two proposals: title 1"       "Internal linking" "$(jq -r '.issues[0].title' <<<"$OUT")"
eq "two proposals: body 1"        "$(printf 'Add related-games links.\nServes priority #1.')" "$(jq -r '.issues[0].body' <<<"$OUT")"
eq "two proposals: title 2"       "Hub copy" "$(jq -r '.issues[1].title' <<<"$OUT")"
eq "two proposals: digest body excludes the issues" "The digest." "$(jq -r '.body' <<<"$OUT")"

run_parse "$(printf 'SUBJECT: s\n===BODY===\nD.\n===ISSUE===\nTITLE: Only one\nbody here')"
eq "one proposal: count" 1 "$(jq '.issues | length' <<<"$OUT")"
eq "one proposal: title" "Only one" "$(jq -r '.issues[0].title' <<<"$OUT")"

run_parse "$(printf 'SUBJECT: s\n===BODY===\nD.\n===ISSUE===\nno title line\n===ISSUE===\nTITLE: Valid\nok')"
eq "malformed block (no TITLE:) skipped: count" 1 "$(jq '.issues | length' <<<"$OUT")"
eq "malformed block skipped: keeps the valid one" "Valid" "$(jq -r '.issues[0].title' <<<"$OUT")"

# ---- ceo_render_html ----------------------------------------------------
echo "== ceo_render_html =="
html="$(ceo_render_html <<<"$(printf '## The win\n- ship **verify**\n\nA <tag> & co.')")"
has "render: h3 heading"        "$html" "<h3>The win</h3>"
has "render: list item + bold"  "$html" "<li>ship <strong>verify</strong></li>"
has "render: html-escapes < > &" "$html" "A &lt;tag&gt; &amp; co."

# ---- ceo_week_done / ceo_mark_week_done ---------------------------------
echo "== ceo_week_done / ceo_mark_week_done =="
state_dir="$(mktemp -d)"
trap 'rm -rf "$state_dir"' EXIT
export AGENT_STATE_DIR="$state_dir"
state_file="$state_dir/discretionary-state.json"
repo="acme/widgets"

if ceo_week_done "$repo"; then bad "fresh: not done"; else ok "fresh: not done"; fi
ceo_mark_week_done "$repo"
if ceo_week_done "$repo"; then ok "after mark: done"; else bad "after mark: done"; fi
if ceo_week_done "acme/other"; then bad "other repo: not done"; else ok "other repo: not done"; fi
eq "stamp = this ISO week" "$(date +%G-W%V)" "$(jq -r --arg r "$repo" '.ceo[$r]' "$state_file")"

# A stale stamp (different ISO week) must read as not-done.
tmp="$(mktemp)"
jq --arg r "$repo" '.ceo[$r] = "1999-W01"' "$state_file" > "$tmp" && mv "$tmp" "$state_file"
if ceo_week_done "$repo"; then bad "stale stamp: not done"; else ok "stale stamp: not done"; fi

# Re-marking is idempotent and restores done.
ceo_mark_week_done "$repo"
if ceo_week_done "$repo"; then ok "re-mark: done again"; else bad "re-mark: done again"; fi

# ---- ceo_gather_week (jq filters, with _fj stubbed) ---------------------
echo "== ceo_gather_week =="
_fj() {  # override forgejo.sh's API caller: route canned JSON by URL path
  case "$2" in
    */pulls*)        printf '%s' "$STUB_PULLS" ;;
    *labels=Agent*)  printf '%s' "$STUB_AGENT" ;;
    */issues*)       printf '%s' "$STUB_ISSUES" ;;
    *)               printf '[]' ;;
  esac
}
since="2026-06-18T00:00:00Z"
STUB_PULLS='[{"number":46,"title":"Add verify","merged_at":"2026-06-20T00:00:00Z","user":{"login":"igor"}},
             {"number":40,"title":"Stale","merged_at":"2026-01-01T00:00:00Z","user":{"login":"igor"}}]'
STUB_ISSUES='[{"number":51,"title":"Login bug","state":"open","created_at":"2026-06-19T00:00:00Z","closed_at":null,"pull_request":null},
              {"number":12,"title":"PR in disguise","created_at":"2026-06-19T00:00:00Z","pull_request":{"merged":false}}]'
STUB_AGENT='[{"number":51,"title":"Login bug","pull_request":null}]'

out="$(ceo_gather_week "$repo" "$since")"
has   "gather: merged PR in window"      "$out" "- #46 Add verify (by igor)"
hasnt "gather: pre-window PR excluded"   "$out" "#40"
has   "gather: opened issue rendered"    "$out" "- #51 [open] Login bug (opened)"
hasnt "gather: PR filtered from issues"  "$out" "#12"
has   "gather: open Agent queue"         "$out" "- #51 Login bug"

# ---- summary ------------------------------------------------------------
echo
if [ "$fails" -eq 0 ]; then
  echo "test-ceo: all checks passed"
  exit 0
fi
echo "test-ceo: $fails check(s) FAILED"
exit 1
