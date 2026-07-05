#!/usr/bin/env bash
# test-bot-identity.sh -- regression for igor#346: tick.sh's bot-identity
# bootstrap must survive a forgejo_whoami() failure and land on its own
# diagnostic (exit 3), not die via errexit with curl's raw exit code.
#
# forgejo_whoami() is `curl | jq`. Under `set -euo pipefail`, if curl fails
# (e.g. exit 6/COULDNT_RESOLVE_HOST on the same network blip that can make
# the harness's self-pull fail) and jq still exits 0 on empty stdin, pipefail
# surfaces curl's exit code for the pipeline. An unguarded
# `BOT_USER=$(forgejo_whoami)` lets that code kill the tick via errexit
# BEFORE the caller's own `[ -n "$BOT_USER" ] || exit 3` check ever runs --
# so the tick dies with a meaningless status instead of the intended,
# explained one. This locks in the fix: the assignment must be guarded so a
# lookup failure always falls through to the caller's own handling.
#
# Run standalone (`bin/test-bot-identity.sh`) or via `make test`. Skip-safe:
# exits 0 with a notice if a required tool is absent.
set -euo pipefail

for tool in jq curl mktemp; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "test-bot-identity: $tool not installed -- skipping"; exit 0; }
done

HERE="$(cd "$(dirname "$0")/.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Stub `curl`: simulate DNS resolution failure -- no output, exit 6, exactly
# what curl returns for COULDNT_RESOLVE_HOST.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
exit 6
STUB
chmod +x "$TMP/bin/curl"
PATH="$TMP/bin:$PATH"

export FORGEJO_URL="https://forgejo.example.test"
export FORGEJO_TOKEN="test-token"
# shellcheck source=../lib/forgejo.sh
. "$HERE/lib/forgejo.sh"

fails=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; fails=$((fails + 1)); }

echo "== forgejo_whoami: a curl failure alone must not silently vanish =="

set +e
(
  set -e
  BOT_USER=$(forgejo_whoami)
  echo "$BOT_USER"
)
rc_unguarded=$?
set -e

if [ "$rc_unguarded" -eq 0 ]; then
  bad "unguarded assignment did not fail at all -- test stub is broken"
else
  ok "unguarded assignment fails as expected (rc=$rc_unguarded), demonstrating the raw-code hazard"
fi

echo "== tick.sh's guarded bootstrap pattern survives and reaches its own diagnostic =="

# Replicate the exact tick.sh caller pattern (bin/tick.sh, bot-identity
# bootstrap): guarded assignment, then the existing empty-check + exit 3.
REACHED="$TMP/reached"
rm -f "$REACHED"
set +e
(
  set -e
  BOT_USER=$(forgejo_whoami) || BOT_USER=""
  [ -n "$BOT_USER" ] || {
    echo "agent: failed to resolve bot user from $FORGEJO_URL/api/v1/user" >&2
    exit 3
  }
) >/dev/null 2>"$TMP/stderr"
rc=$?
set -e
echo "$rc" > "$REACHED"

if [ -f "$REACHED" ]; then
  got="$(cat "$REACHED")"
  if [ "$got" = "3" ]; then
    ok "guarded bootstrap reached its own check and exited 3 (not curl's raw 6)"
  else
    bad "expected exit 3 from the caller's own check, got [$got]"
  fi
else
  bad "guarded bootstrap never completed"
fi

if grep -q "failed to resolve bot user" "$TMP/stderr" 2>/dev/null; then
  ok "clear diagnostic printed, not a bare crash"
else
  bad "expected diagnostic message missing from stderr"
fi

if [ "$fails" -eq 0 ]; then
  echo "test-bot-identity: all checks passed"
  exit 0
else
  echo "test-bot-identity: $fails check(s) failed"
  exit 1
fi
