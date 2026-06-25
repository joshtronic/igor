#!/usr/bin/env bash
# test-recipients.sh -- unit tests for recipients_with_primary (lib/email.sh):
# PRIMARY_RECIPIENTS is ALWAYS on the To line, and every per-surface list is
# additive + deduped on top of it. Skip-safe: needs awk/paste/tr (coreutils);
# exits 0 with a notice if absent, like the other bin/test-*.sh.
set -uo pipefail

for tool in awk paste tr; do
  command -v "$tool" >/dev/null 2>&1 \
    || { echo "test-recipients: $tool absent -- skipping"; exit 0; }
done

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/email.sh
. "$HERE/../lib/email.sh"

FAIL=0
eq() {  # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then printf '  + %s\n' "$1"
  else printf '  x %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi
}

echo "== recipients_with_primary =="
PRIMARY_RECIPIENTS="josh@x.com"
eq "primary always present, extras added" "josh@x.com,jen@y.com,liz@z.com" "$(recipients_with_primary "jen@y.com,liz@z.com")"
eq "no extras -> primary only"            "josh@x.com" "$(recipients_with_primary "")"
eq "missing arg -> primary only"          "josh@x.com" "$(recipients_with_primary)"
eq "primary first, order preserved"       "josh@x.com,a@x,b@x" "$(recipients_with_primary "a@x,b@x")"
eq "primary repeated in extras -> deduped" "josh@x.com,jen@y.com" "$(recipients_with_primary "josh@x.com,jen@y.com")"
eq "internal dupes in extras -> deduped"  "josh@x.com,jen@y.com" "$(recipients_with_primary "jen@y.com,jen@y.com")"

PRIMARY_RECIPIENTS=""
eq "no primary -> extras only"            "jen@y.com" "$(recipients_with_primary "jen@y.com")"
eq "nothing set -> empty"                 "" "$(recipients_with_primary "")"

if [ "$FAIL" -eq 0 ]; then echo "test-recipients: all checks passed"; exit 0; fi
echo "test-recipients: $FAIL check(s) FAILED"
exit 1
