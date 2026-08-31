#!/usr/bin/env bash
# test-forgejo-surface.sh -- guards the igor#565 invariant: `_fj`, the
# low-level HTTP helper in lib/forgejo.sh, is PRIVATE to that file. Every
# other caller that wants to talk to the forge goes through a named
# `forgejo_*` operation instead of hand-rolling a path/method/payload
# against `_fj` directly. Before igor#565, `_fj` was called 71 times outside
# the client -- this is what keeps that count at zero going forward.
#
# Exemptions, both narrow and deliberate:
#  - lib/forgejo.sh itself, where `_fj` is defined and legitimately used.
#  - bin/test-forgejo.sh, which exercises the private helper directly, by
#    design (it is the client's own unit test).
#  - this file, whose fixture heredocs and failure messages spell out the
#    very calls it hunts for.
#  - in bin/test-*.sh, only the LINE that redefines `_fj() { ... }` as a
#    stub/mock to intercept calls a sourced `forgejo_*` wrapper makes
#    underneath. A mock never talks to a real forge, so a test double using
#    the name doesn't violate the invariant. A test that hand-rolls a real
#    `_fj GET ...` call is a stray call like any other and is still flagged.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE" || exit 1

FAIL=0
ok()  { printf '  + %s\n' "$1"; }
bad() { printf '  x %s\n' "$1"; FAIL=$((FAIL + 1)); }

# scan_for_stray_fj <root> -- print "<file>:<lineno>:<content>" for every
# line under <root>/bin and <root>/lib (recursively, *.sh only) that invokes
# `_fj` as a bare command, outside the exemptions above. A comment-only line
# (trimmed content starts with '#') is never a call, so it's skipped.
scan_for_stray_fj() {
  local root="$1"
  grep -rnE '(^|[^A-Za-z0-9_])_fj([^A-Za-z0-9_]|$)' --include='*.sh' \
    "$root/bin" "$root/lib" 2>/dev/null \
    | while IFS=: read -r file lineno content; do
        trimmed="${content#"${content%%[![:space:]]*}"}"
        case "$trimmed" in
          '#'*) continue ;;
        esac
        case "$file" in
          */lib/forgejo.sh|*/bin/test-forgejo.sh|*/bin/test-forgejo-surface.sh) continue ;;
          */bin/test-*.sh)
            case "$content" in
              *'_fj()'*|*'_fj ()'*) continue ;;
            esac
            ;;
        esac
        printf '%s:%s:%s\n' "$file" "$lineno" "$content"
      done
}

echo "== no file outside lib/forgejo.sh (and its own test) calls _fj directly =="
REAL_HITS=$(scan_for_stray_fj "$HERE")
if [ -n "$REAL_HITS" ]; then
  while IFS= read -r line; do
    bad "stray _fj call outside the client: $line"
  done <<<"$REAL_HITS"
else
  ok "no stray _fj call sites outside lib/forgejo.sh"
fi

# Negative test (igor#565): prove the scan above actually catches a
# violation instead of being vacuously green -- e.g. from a typo'd glob or an
# exemption pattern that's grown too wide. Without a check like this one
# wired into `make test`, a re-introduced stray `_fj` call would sail
# through unnoticed (the guard "severed"); this fixture is what proves the
# mechanism, once wired in, is what actually catches it.
echo "== negative test: a deliberately reintroduced stray _fj call is caught =="
TMPROOT=$(mktemp -d) || { bad "could not create fixture tmpdir"; TMPROOT=""; }
if [ -n "$TMPROOT" ]; then
  trap 'rm -rf "$TMPROOT"' EXIT
  mkdir -p "$TMPROOT/bin" "$TMPROOT/lib"
  cat > "$TMPROOT/lib/example.sh" <<'EOF'
#!/usr/bin/env bash
# a hand-rolled call that should have gone through a named forgejo_* op
example_reads_a_pr() {
  _fj GET "/repos/${1}/pulls/${2}"
}
EOF
  FIXTURE_HITS=$(scan_for_stray_fj "$TMPROOT")
  if [ -n "$FIXTURE_HITS" ]; then
    ok "the guard flags a stray _fj call reintroduced in a fixture file"
  else
    bad "the guard let a reintroduced stray _fj call pass silently -- it isn't checking anything"
  fi

  echo "== sanity: the exemptions don't swallow real violations too =="
  cat > "$TMPROOT/bin/not-a-test-helper.sh" <<'EOF'
#!/usr/bin/env bash
_fj POST "/repos/${1}/issues/${2}/comments" "$3" >/dev/null
EOF
  BIN_HITS=$(scan_for_stray_fj "$TMPROOT")
  if printf '%s' "$BIN_HITS" | grep -q 'not-a-test-helper.sh'; then
    ok "a stray call in bin/ (not a test-*.sh file) is still flagged"
  else
    bad "a stray call in a non-test bin/ file was NOT flagged"
  fi

  echo "== sanity: a test double stubbing _fj() is not mistaken for a caller =="
  cat > "$TMPROOT/bin/test-example.sh" <<'EOF'
#!/usr/bin/env bash
_fj() { printf '%s' '{}'; }
EOF
  MOCK_HITS=$(scan_for_stray_fj "$TMPROOT")
  if printf '%s' "$MOCK_HITS" | grep -q 'test-example.sh'; then
    bad "a bin/test-*.sh mock definition of _fj() was wrongly flagged"
  else
    ok "a bin/test-*.sh mock definition of _fj() is correctly exempt"
  fi

  echo "== sanity: the test-file exemption covers mocks only, not real calls =="
  cat > "$TMPROOT/bin/test-realcall.sh" <<'EOF'
#!/usr/bin/env bash
setup_fixture() {
  _fj GET "/repos/${1}/pulls/${2}"
}
EOF
  REALCALL_HITS=$(scan_for_stray_fj "$TMPROOT")
  if printf '%s' "$REALCALL_HITS" | grep -q 'test-realcall.sh'; then
    ok "a bin/test-*.sh file hand-rolling a real _fj call is still flagged"
  else
    bad "a bin/test-*.sh file hand-rolling a real _fj call slipped through the mock exemption"
  fi

  rm -rf "$TMPROOT"
  trap - EXIT
fi

# docs/forgejo-api-surface.md is the human-readable half of the same
# invariant: if the surface is only explicit in a doc nobody checks, it
# drifts the first time an operation is added. Both directions are checked --
# an undocumented operation and a documented ghost are equally wrong.
echo "== every named forgejo_* operation appears in docs/forgejo-api-surface.md =="
DOC="$HERE/docs/forgejo-api-surface.md"
CLIENT="$HERE/lib/forgejo.sh"

UNDOCUMENTED=$(grep -oE '^forgejo_[a-z0-9_]+\(\)' "$CLIENT" | sed 's/()$//' | sort -u \
  | while IFS= read -r fn; do
      grep -qF "| \`${fn}\` |" "$DOC" || printf '%s\n' "$fn"
    done)
if [ -n "$UNDOCUMENTED" ]; then
  while IFS= read -r fn; do
    bad "operation not documented in docs/forgejo-api-surface.md: $fn"
  done <<<"$UNDOCUMENTED"
else
  ok "every operation defined in lib/forgejo.sh has a documented row"
fi

GHOSTS=$(grep -oE '^\| `forgejo_[a-z0-9_]+`' "$DOC" | grep -oE 'forgejo_[a-z0-9_]+' | sort -u \
  | while IFS= read -r fn; do
      grep -qE "^${fn}\(\)" "$CLIENT" || printf '%s\n' "$fn"
    done)
if [ -n "$GHOSTS" ]; then
  while IFS= read -r fn; do
    bad "documented operation no longer exists in lib/forgejo.sh: $fn"
  done <<<"$GHOSTS"
else
  ok "every documented row names an operation that still exists"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "test-forgejo-surface: all checks passed"
else
  echo "test-forgejo-surface: $FAIL FAILED"
  exit 1
fi
