#!/usr/bin/env bash
# test-mr-target-guard.sh -- static guard against the issues-vs-merge-requests
# class of bug, which bit three times before this existed.
#
# On Forgejo a pull request IS an issue: one number space, one endpoint, so
# forgejo_comment/_assign/_unassign_all/_log_time served either. On GitLab they
# are separate resources with SEPARATE iid spaces, so an issue-targeted call
# given a PR number either:
#
#   - 404s, and the action is silently lost. The review verdict for
#     igor.bot!4 had nowhere to go, so the reviewer dropped it and retried
#     forever.
#   - or lands on the WRONG OBJECT. review_route_into_rework assigned the bot
#     to ISSUE #6 instead of MR !6; the recovery sweep then declared that issue
#     orphaned and commented on it once per rework round.
#
# Neither raises anything a human notices, so a static check is the only thing
# that catches it before it ships.
#
# The check is FUNCTION-SCOPED, not name-based on the variable. The first
# version of this guard matched only $pr/$PR_NUMBER/$pr_num/$target_num and
# therefore missed the call that caused the actual damage, which was spelled
# `forgejo_assign "$repo" "$number"` -- $number is an ISSUE number in half the
# codebase and an MR iid in the review path. The only reliable signal is which
# FUNCTION the call sits in.
#
# Fixing a hit means switching to the forgejo_pr_* variant, never suppressing.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE" || exit 1
FAIL=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; FAIL=$((FAIL + 1)); }

# Issue-targeted adapter functions that have a forgejo_pr_* counterpart.
ISSUE_FNS='forgejo_comment|forgejo_assign|forgejo_unassign_all'

echo "== PR-scoped functions never call an issue-targeted adapter fn =="
# A shell function is treated as PR-scoped when its name says so. These are
# the families whose second positional is a PR/MR number throughout.
PR_SCOPED_RE='^(review_|do_review|automerge_|pr_)'
HITS=$(python3 - "$ISSUE_FNS" "$PR_SCOPED_RE" <<'PY'
import re,sys,glob
issue_fns, scoped_re = sys.argv[1], sys.argv[2]
out=[]
for path in sorted(glob.glob('bin/*.sh')+glob.glob('lib/*.sh')):
    if re.match(r'^(lib/(forgejo|gitlab)\.sh|bin/test-)', path): continue
    src=open(path).read().split('\n')
    bounds=[]
    for i,l in enumerate(src):
        m=re.match(r'^([a-z_][a-z0-9_]*)\(\)\s*\{', l)
        if m: bounds.append((i,m.group(1)))
    bounds.append((len(src),'<eof>'))
    for (s,name),(e,_) in zip(bounds,bounds[1:]):
        if not re.match(scoped_re,name): continue
        for n in range(s,e):
            line=src[n]
            if line.lstrip().startswith('#'): continue
            m=re.search(r'\b('+issue_fns+r')\s', line)
            if m: out.append(f"{path}:{n+1} in {name}(): {m.group(1)}")
print('\n'.join(out))
PY
)
if [ -z "$HITS" ]; then
  ok "no PR-scoped function calls an issue-targeted adapter fn"
else
  while IFS= read -r h; do [ -n "$h" ] && bad "$h"; done <<<"$HITS"
  printf '    -- use the forgejo_pr_* variant; see lib/gitlab.sh\n'
fi

echo "== explicit PR-named variables are never passed to an issue-targeted fn =="
# Belt to the function-scope brace: catches a PR number handed to an
# issue-targeted fn from a non-PR-scoped function (e.g. the tick body).
PR_VARS='\$pr\b|\$\{pr\}|\$PR_NUMBER\b|\$pr_num\b|\$target_num\b'
V=$(grep -rnE "\b(${ISSUE_FNS})[[:space:]]+\"[^\"]*\"[[:space:]]+\"(${PR_VARS})\"" \
      bin/*.sh lib/*.sh 2>/dev/null | grep -vE '^(lib/(forgejo|gitlab)\.sh|bin/test-)' || true)
if [ -z "$V" ]; then ok "no issue-targeted call site passes a PR-named variable"
else while IFS= read -r h; do [ -n "$h" ] && bad "PR-named variable to an issue fn: $h"; done <<<"$V"; fi

echo "== forgejo_log_time on a PR names the merge_requests kind =="
LT=$(grep -rnE "forgejo_log_time[[:space:]]+\"[^\"]*\"[[:space:]]+\"(${PR_VARS})\"" \
       bin/*.sh lib/*.sh 2>/dev/null | grep -vE '^(lib/(forgejo|gitlab)\.sh|bin/test-)' || true)
if [ -z "$LT" ]; then ok "no bare log_time call site with a PR-named variable"
else
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    case "$h" in *merge_requests*) ok "log_time names merge_requests: ${h%%:*}" ;;
      *) bad "forgejo_log_time on a PR without merge_requests: $h" ;; esac
  done <<<"$LT"
fi

echo "== every forgejo_pr_* helper exists in BOTH adapters =="
while IFS= read -r fn; do
  g=$(grep -c "^${fn}()" lib/gitlab.sh); f=$(grep -c "^${fn}()" lib/forgejo.sh)
  if [ "$g" -ge 1 ] && [ "$f" -ge 1 ]; then ok "$fn in both adapters"
  else bad "$fn missing from an adapter (gitlab=$g forgejo=$f)"; fi
done < <(grep -ohE '^forgejo_pr_[a-z_]+' lib/gitlab.sh | sort -u)

if [ "$FAIL" -eq 0 ]; then echo "test-mr-target-guard: all checks passed"; exit 0
else echo "test-mr-target-guard: $FAIL check(s) failed"; exit 1; fi
