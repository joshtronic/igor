#!/usr/bin/env bash
# test-bot-identity.sh -- regressions for tick.sh's bot-identity bootstrap.
#
# igor#346: the bootstrap must survive a forgejo_whoami() failure and land on
# its own diagnostic (exit 3), not die via errexit with curl's raw exit code.
# forgejo_whoami() is `curl | jq`; under `set -euo pipefail`, if curl fails
# (e.g. exit 6/COULDNT_RESOLVE_HOST) an unguarded `BOT_USER=$(forgejo_whoami)`
# lets that code kill the tick BEFORE the caller's own `[ -n "$BOT_USER" ] ||
# exit 3` check runs -- so it dies with a meaningless status. The guard fixes
# that.
#
# igor#383: bot-identity resolution gates the ENTIRE tick, so a SINGLE
# transient /api/v1/user hiccup used to hard-abort the systemd unit (exit 3 ->
# `Failed with result 'exit-code'`) with no retry. forgejo_resolve_bot_user()
# now retries with backoff: a one-off blip rides through on a later attempt (no
# exit 3), and only a PERSISTENT failure still exits 3 (a sustained outage or a
# revoked token SHOULD surface as a failed unit).
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

# Stateful `curl` stub: fail (exit 6, no output -- exactly curl's
# COULDNT_RESOLVE_HOST) for the first $CURL_STUB_FAIL_TIMES calls, then succeed
# with a valid /user body. Lets one test drive both a persistent outage and a
# transient-then-recovered blip by resetting the counter + fail budget.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
n=$(( $(cat "$CURL_STUB_COUNT" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$n" > "$CURL_STUB_COUNT"
if [ "$n" -le "${CURL_STUB_FAIL_TIMES:-0}" ]; then
  exit 6
fi
printf '%s' '{"login":"igorbot"}'
STUB
chmod +x "$TMP/bin/curl"
PATH="$TMP/bin:$PATH"

export FORGEJO_URL="https://forgejo.example.test"
export FORGEJO_TOKEN="test-token"
export CURL_STUB_COUNT="$TMP/curl-count"
# shellcheck source=../lib/forgejo.sh
. "$HERE/lib/forgejo.sh"

fails=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; fails=$((fails + 1)); }
reset_stub() { : > "$CURL_STUB_COUNT"; export CURL_STUB_FAIL_TIMES="$1"; }

echo "== forgejo_whoami: a curl failure alone must not silently vanish =="

reset_stub 99
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

echo "== forgejo_resolve_bot_user: a PERSISTENT failure exhausts retries and the caller still exits 3 =="

# Replicate the exact tick.sh caller pattern (bin/tick.sh, bot-identity
# bootstrap): guarded resolve, then the existing empty-check + exit 3.
reset_stub 99
set +e
(
  set -e
  BOT_USER=$(forgejo_resolve_bot_user) || BOT_USER=""
  [ -n "$BOT_USER" ] || {
    echo "agent: failed to resolve bot user from $FORGEJO_URL/api/v1/user" >&2
    exit 3
  }
) >/dev/null 2>"$TMP/stderr"
rc=$?
set -e

if [ "$rc" = "3" ]; then
  ok "persistent failure reached the caller's own check and exited 3 (not curl's raw 6)"
else
  bad "expected exit 3 from the caller's own check, got [$rc]"
fi

if grep -q "failed to resolve bot user" "$TMP/stderr" 2>/dev/null; then
  ok "clear diagnostic printed, not a bare crash"
else
  bad "expected diagnostic message missing from stderr"
fi

# It must actually have RETRIED, not given up on the first blip.
tries="$(cat "$CURL_STUB_COUNT" 2>/dev/null || echo 0)"
if [ "$tries" -ge 2 ]; then
  ok "resolution retried on failure (curl called ${tries}x, > 1)"
else
  bad "expected >1 curl attempt (retry), got ${tries}"
fi

echo "== forgejo_resolve_bot_user: a one-off blip rides through -- resolves, no exit 3 =="

# Fail exactly once, then succeed: the #383 scenario. The gate must recover
# WITHIN the tick and never reach the exit-3 path.
reset_stub 1
set +e
(
  set -e
  BOT_USER=$(forgejo_resolve_bot_user) || BOT_USER=""
  [ -n "$BOT_USER" ] || {
    echo "agent: failed to resolve bot user" >&2
    exit 3
  }
  [ "$BOT_USER" = "igorbot" ] || { echo "wrong login: $BOT_USER" >&2; exit 4; }
) >/dev/null 2>"$TMP/stderr2"
rc_transient=$?
set -e

if [ "$rc_transient" = "0" ]; then
  ok "transient blip absorbed by retry -- resolved the bot user, no unit failure"
else
  bad "expected clean resolve (0) after a one-off blip, got [$rc_transient]: $(cat "$TMP/stderr2")"
fi

if [ "$fails" -eq 0 ]; then
  echo "test-bot-identity: all checks passed"
  exit 0
else
  echo "test-bot-identity: $fails check(s) failed"
  exit 1
fi
