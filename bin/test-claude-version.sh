#!/usr/bin/env bash
# test-claude-version.sh -- unit tests for lib/claude-version.sh (igor#612
# section 4): installed-vs-latest via stubbed `claude` and `npm` on PATH, so
# no real network/CLI call happens. Skip-safe: needs jq; exits 0 with a
# notice if absent, like the other bin/test-*.sh.
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "test-claude-version: jq absent -- skipping"; exit 0; }

HERE="$(cd "$(dirname "$0")/.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log() { :; }

# shellcheck source=lib/claude-version.sh
. "$HERE/lib/claude-version.sh"

FAIL=0
eq() { if [ "$2" = "$3" ]; then printf '  + %s\n' "$1"; else printf '  x %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi; }

stub_bin() {
  mkdir -p "$TMP/bin"
  rm -f "$TMP/bin/claude" "$TMP/bin/npm"
}

echo "== claude_version_check: installed matches latest -> not behind =="
stub_bin
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
echo "2.1.229 (Claude Code)"
STUB
chmod +x "$TMP/bin/claude"
cat > "$TMP/bin/npm" <<'STUB'
#!/usr/bin/env bash
echo "2.1.229"
STUB
chmod +x "$TMP/bin/npm"
R1=$(PATH="$TMP/bin:$PATH" claude_version_check)
eq "installed parsed"      "2.1.229" "$(jq -r '.installed' <<<"$R1")"
eq "latest parsed"         "2.1.229" "$(jq -r '.latest' <<<"$R1")"
eq "checked_ok"            "true"    "$(jq -r '.checked_ok' <<<"$R1")"
eq "not behind"            "false"   "$(jq -r '.behind' <<<"$R1")"

echo "== claude_version_check: installed behind latest =="
stub_bin
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
echo "2.1.229"
STUB
chmod +x "$TMP/bin/claude"
cat > "$TMP/bin/npm" <<'STUB'
#!/usr/bin/env bash
echo "2.1.269"
STUB
chmod +x "$TMP/bin/npm"
R2=$(PATH="$TMP/bin:$PATH" claude_version_check)
eq "behind: true"          "true"    "$(jq -r '.behind' <<<"$R2")"
eq "behind: checked_ok"    "true"    "$(jq -r '.checked_ok' <<<"$R2")"
eq "behind: latest parsed" "2.1.269" "$(jq -r '.latest' <<<"$R2")"

echo "== claude_version_check: registry lookup fails -> could-not-check, not silence =="
stub_bin
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
echo "2.1.229"
STUB
chmod +x "$TMP/bin/claude"
cat > "$TMP/bin/npm" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$TMP/bin/npm"
R3=$(PATH="$TMP/bin:$PATH" claude_version_check)
eq "checked_ok false on lookup failure" "false" "$(jq -r '.checked_ok' <<<"$R3")"
eq "latest is null"                     "null"  "$(jq -r '.latest' <<<"$R3")"
eq "not spuriously behind"              "false" "$(jq -r '.behind' <<<"$R3")"

echo "== claude_version_check: since_days reflects the binary's mtime =="
stub_bin
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
echo "2.1.229"
STUB
chmod +x "$TMP/bin/claude"
cat > "$TMP/bin/npm" <<'STUB'
#!/usr/bin/env bash
echo "2.1.229"
STUB
chmod +x "$TMP/bin/npm"
touch -d "10 days ago" "$TMP/bin/claude" 2>/dev/null || touch -t "$(date -v-10d +%Y%m%d%H%M 2>/dev/null)" "$TMP/bin/claude" 2>/dev/null || true
R5=$(PATH="$TMP/bin:$PATH" claude_version_check)
SD=$(jq -r '.since_days' <<<"$R5")
if [ "$SD" -ge 9 ] && [ "$SD" -le 11 ]; then
  printf '  + %s\n' "since_days is ~10 (got $SD)"
else
  printf '  x since_days: expected ~10, got [%s]\n' "$SD"; FAIL=$((FAIL + 1))
fi

[ "$FAIL" -eq 0 ] && { echo "test-claude-version: all checks passed"; exit 0; }
echo "test-claude-version: $FAIL check(s) FAILED"
exit 1
