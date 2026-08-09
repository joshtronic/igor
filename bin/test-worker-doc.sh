#!/usr/bin/env bash
# test-worker-doc.sh -- unit tests for lib/worker-doc.sh: which document
# bin/check-sync.sh validates its OUTCOME sentinels and helper references
# against (igor#487).
#   seeded prompt cache      -> the sourced worker-contract body
#   unseeded cache           -> the in-repo AGENTS.md, labelled a fallback
#   seeded but unservable    -> nonzero, and never an empty document
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/context-source.sh
. "$HERE/../lib/context-source.sh"
# shellcheck source=../lib/worker-doc.sh
. "$HERE/../lib/worker-doc.sh"

FAIL=0
ok() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then printf '  + %s\n' "$d"; else printf '  x %s (rc0 expected)\n' "$d"; FAIL=$((FAIL + 1)); fi; }
no() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then printf '  x %s (rc!=0 expected)\n' "$d"; FAIL=$((FAIL + 1)); else printf '  + %s\n' "$d"; fi; }
eq() { local d="$1" want="$2" got="$3"; if [ "$want" = "$got" ]; then printf '  + %s\n' "$d"; else printf '  x %s (want %q got %q)\n' "$d" "$want" "$got"; FAIL=$((FAIL + 1)); fi; }
has() { local d="$1" needle="$2" hay="$3"; case "$hay" in *"$needle"*) printf '  + %s\n' "$d" ;; *) printf '  x %s (%q not in %q)\n' "$d" "$needle" "$hay"; FAIL=$((FAIL + 1)) ;; esac; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
export CONTEXT_CACHE_DIR="$TMPROOT/cache"
DEST="$TMPROOT/worker-doc"

echo "== unseeded cache -> the in-repo AGENTS.md, named as a fallback =="
ok "selection succeeds" worker_doc_select "$DEST"
eq "document is the in-repo AGENTS.md" "AGENTS.md" "$WORKER_DOC"
has "label says it is the fallback" "fallback" "$WORKER_DOC_LABEL"
ok "nothing written to the destination" [ ! -s "$DEST" ]

echo "== seeded cache -> the sourced worker-contract body =="
GEN="$CONTEXT_CACHE_DIR/current"
mkdir -p "$GEN"
printf '%s\n' "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" > "$GEN/HEAD"
WANT=$'Do the work.\n\n<!-- OUTCOME: pr -->\n\nCall `agent-block.sh` when stuck.'
printf '%s\n' "$WANT" > "$GEN/worker-contract.md"
ok "selection succeeds" worker_doc_select "$DEST"
eq "document is the destination file, not AGENTS.md" "$DEST" "$WORKER_DOC"
eq "destination holds the sourced body verbatim" "$WANT" "$(cat "$DEST")"
has "label names the sourced document" "sourced worker-contract" "$WORKER_DOC_LABEL"

echo "== seeded cache but worker-contract unservable -> explicit failure, no empty document =="
rm -f "$GEN/worker-contract.md"
no "selection fails rather than falling back" worker_doc_select "$DEST"
eq "WORKER_DOC is left empty so no caller validates an empty file" "" "$WORKER_DOC"

if [ "$FAIL" -eq 0 ]; then
  echo "test-worker-doc: all passed"
else
  echo "test-worker-doc: $FAIL failure(s)"
fi
exit "$FAIL"
