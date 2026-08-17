#!/usr/bin/env bash
# test-check-sync.sh -- the failure summary bin/check-sync.sh reprints before
# its exit code (igor#522).
#
# Drives the REAL script inside a synthetic AGENT_HOME: a fixture suite can
# then fail, and check-sync can exit nonzero, without any of that escaping
# into the run of check-sync that is executing this file.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

FAIL=0
eq() { local d="$1" want="$2" got="$3"; if [ "$want" = "$got" ]; then printf '  + %s\n' "$d"; else printf '  x %s (want %q got %q)\n' "$d" "$want" "$got"; FAIL=$((FAIL + 1)); fi; }
has() { local d="$1" needle="$2" hay="$3"; case "$hay" in *"$needle"*) printf '  + %s\n' "$d" ;; *) printf '  x %s (%q not found in output)\n' "$d" "$needle"; FAIL=$((FAIL + 1)) ;; esac; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# A synthetic AGENT_HOME whose every check passes: real check-sync.sh (via a
# symlink, so `dirname $0` roots it here), real libs, and the minimum tick.sh
# + worker document the sentinel/cascade checks need.
make_home() {
  local home="$TMPROOT/$1" lib
  mkdir -p "$home/bin" "$home/lib"
  ln -s "$REPO/bin/check-sync.sh" "$home/bin/check-sync.sh"
  for lib in suite-guard context-source worker-doc; do
    ln -s "$REPO/lib/$lib.sh" "$home/lib/$lib.sh"
  done
  printf '%s\n' '<!-- OUTCOME: pr -->' > "$home/AGENTS.md"
  cat > "$home/bin/tick.sh" <<'TICK'
#!/usr/bin/env bash
CASCADE_STAGES="demo"
do_demo_tick() { :; }   # OUTCOME: pr
if cascade_run demo; then :; fi
TICK
  printf '%s' "$home"
}

# Unseeded prompt cache -> the fallback AGENTS.md branch, so the run does not
# depend on whether this host happens to be seeded.
export CONTEXT_CACHE_DIR="$TMPROOT/no-cache"

echo "== a failing suite names itself in the summary, inside a truncated tail =="
HOME_A="$(make_home fail-suite)"
cat > "$HOME_A/bin/test-aaa-boom.sh" <<'SUITE'
echo "  x something the reviewer needs to read"
exit 1
SUITE
cat > "$HOME_A/bin/test-zzz-noise.sh" <<'SUITE'
for i in $(seq 1 150); do echo "  + noise $i"; done
SUITE

out=$(bash "$HOME_A/bin/check-sync.sh" 2>&1); rc=$?
eq "exits 1" "1" "$rc"
has "prints the summary heading" "== FAILURES ==" "$out"
has "a failing suite emits an 'x' line at all" "x bin/test-aaa-boom.sh failed" "$out"
has "later suites still run -- a failure is not fail-fast" "+ bin/test-zzz-noise.sh passed" "$out"
has "and the reason survives a 20-line tail" "x bin/test-aaa-boom.sh failed" "$(tail -n 20 <<<"$out")"
has "no suites skipped here -- the summary says so" "0 suite(s) skipped for missing tools" "$out"

echo "== a missing-tool skip is counted in the summary, not read as a pass (igor#523) =="
HOME_C="$(make_home skip-suite)"
cat > "$HOME_C/bin/test-aaa-needs-jq.sh" <<'SUITE'
#!/usr/bin/env bash
echo "test-aaa-needs-jq: jq absent -- skipping"
exit 0
SUITE
cat > "$HOME_C/bin/test-zzz-passes.sh" <<'SUITE'
#!/usr/bin/env bash
echo "  + one real assertion"
SUITE

out=$(bash "$HOME_C/bin/check-sync.sh" 2>&1); rc=$?
eq "a skip alone does not fail the run" "0" "$rc"
has "the skip is reported distinctly, not folded into an ordinary pass" \
  "! bin/test-aaa-needs-jq.sh skipped (test-aaa-needs-jq: jq absent -- skipping)" "$out"
has "the summary counts it" "1 suite(s) skipped for missing tools" "$out"

echo "== a nonzero exit with no 'x' lines keeps its status and says so =="
# Abort check_sync before any check can print: mktemp succeeds once (the
# runner's own log file) and then fails, which is an errexit abort out of the
# function with a status that is neither 0 nor 1.
HOME_B="$(make_home no-x-lines)"
mkdir -p "$TMPROOT/fakebin"
{ printf '#!/usr/bin/env bash\n'
  printf 'if [ -e "$FAKE_MKTEMP_STATE" ]; then exit 3; fi\n'
  printf ': > "$FAKE_MKTEMP_STATE"\n'
  printf 'exec %q "$@"\n' "$(command -v mktemp)"
} > "$TMPROOT/fakebin/mktemp"
chmod +x "$TMPROOT/fakebin/mktemp"

out=$(FAKE_MKTEMP_STATE="$TMPROOT/mktemp-called" \
      PATH="$TMPROOT/fakebin:$PATH" \
      bash "$HOME_B/bin/check-sync.sh" 2>&1); rc=$?
eq "the real failure status survives, not rewritten to 1" "3" "$rc"
has "still prints the summary heading" "== FAILURES ==" "$out"
has "and explains the empty summary" "no 'x' lines" "$out"

if [ "$FAIL" -eq 0 ]; then
  echo "test-check-sync: all passed"
else
  echo "test-check-sync: $FAIL failure(s)"
fi
exit "$FAIL"
