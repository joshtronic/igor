#!/usr/bin/env bash
# test-dossier.sh -- unit tests for lib/dossier.sh (docs/agents-md-spec.md):
# dossier_get/dossier_keys (the runtime reader + agent.json fallback) and
# dossier_validate (the structural spec gate), plus its wiring into
# lib/repo-checks.sh's check_dossier / validate_repo_local.
# Skip-safe: needs git + jq; exits 0 with a notice if either is absent.
set -uo pipefail

command -v jq  >/dev/null 2>&1 || { echo "test-dossier: jq absent -- skipping";  exit 0; }
command -v git >/dev/null 2>&1 || { echo "test-dossier: git absent -- skipping"; exit 0; }

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/dossier.sh
. "$HERE/../lib/dossier.sh"
# shellcheck source=../lib/repo-checks.sh
. "$HERE/../lib/repo-checks.sh"

FAIL=0
ok()   { local d="$1"; shift; if "$@" >/dev/null 2>&1; then printf '  + %s\n' "$d"; else printf '  x %s (rc0 expected)\n' "$d"; FAIL=$((FAIL + 1)); fi; }
no()   { local d="$1"; shift; if "$@" >/dev/null 2>&1; then printf '  x %s (rc!=0 expected)\n' "$d"; FAIL=$((FAIL + 1)); else printf '  + %s\n' "$d"; fi; }
eq()   { local d="$1" want="$2" got="$3"; if [ "$want" = "$got" ]; then printf '  + %s\n' "$d"; else printf '  x %s (want %q got %q)\n' "$d" "$want" "$got"; FAIL=$((FAIL + 1)); fi; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

GOOD=$'# porksicle.com\n\nPenny arcade, played casually.\n\n## KPIs\n\n1. Games played per week -- GA4 game_start\n\n## DOs and DON\'Ts\n\n- DO keep it faithful.\n\n## Caveats\n\n- Edit the generator, never the build.\n\n## Metadata\n\n```yaml\ntype: arcade\nurl: https://www.porksicle.com\ntest: npm test\nfeedback-csv: https://example.com/feedback.csv\n```\n'

echo "== dossier_get / dossier_keys: root AGENTS.md, fallback, absent =="
D1="$TMPROOT/d1"; mkdir -p "$D1"; printf '%s' "$GOOD" >"$D1/AGENTS.md"
eq "type" "arcade" "$(dossier_get "$D1" type)"
eq "url" "https://www.porksicle.com" "$(dossier_get "$D1" url)"
eq "test" "npm test" "$(dossier_get "$D1" test)"
eq "feedback-csv" "https://example.com/feedback.csv" "$(dossier_get "$D1" feedback-csv)"
no "absent key (lint) -> rc1" dossier_get "$D1" lint
eq "dossier_keys lists all 4" "$(printf 'type\nurl\ntest\nfeedback-csv')" "$(dossier_keys "$D1")"

D2="$TMPROOT/d2"; mkdir -p "$D2"
printf '%s' '{"smoke":{"url":"https://snail.io"},"feedback":{"csv":"https://example.com/f.csv"}}' >"$D2/agent.json"
eq "url via legacy .smoke.url" "https://snail.io" "$(dossier_get "$D2" url)"
eq "feedback-csv via legacy .feedback.csv" "https://example.com/f.csv" "$(dossier_get "$D2" feedback-csv)"
no "unmapped key (type) not supported by fallback" dossier_get "$D2" type
eq "dossier_keys via fallback" "$(printf 'url\nfeedback-csv')" "$(dossier_keys "$D2")"

D3="$TMPROOT/d3"; mkdir -p "$D3"
no "neither AGENTS.md nor agent.json -> rc1" dossier_get "$D3" type
no "dossier_keys with nothing present -> rc1" dossier_keys "$D3"

# A prose AGENTS.md (no ## Metadata) is NOT an adopted dossier: the reader
# must still take the agent.json fallback, or a repo that adds an ordinary
# AGENTS.md silently loses its smoke url.
PROSE=$'# Unattended Mode\n\nHow this repo works for agents.\n\n## Override notice\n\nRules for unattended runs.\n\n## Universal rules\n\n- one issue, one outcome\n'
D4="$TMPROOT/d4"; mkdir -p "$D4"; printf '%s' "$PROSE" >"$D4/AGENTS.md"
printf '%s' '{"smoke":{"url":"https://snail.io"}}' >"$D4/agent.json"
eq "prose AGENTS.md + agent.json -> still reads .smoke.url" "https://snail.io" "$(dossier_get "$D4" url)"
eq "dossier_keys likewise falls back" "url" "$(dossier_keys "$D4")"

# Unvalidated read path: a junk block must not emit junk "keys".
D5="$TMPROOT/d5"; mkdir -p "$D5"
printf '%s' $'# x\n\n## Metadata\n\n```yaml\nnot a key line at all\n```\n' >"$D5/AGENTS.md"
no "malformed Metadata block -> dossier_keys rc1, no junk keys" dossier_keys "$D5"

echo "== dossier_validate: happy path + (none yet) KPIs =="
ok "conforming dossier validates" dossier_validate "$GOOD"
NONE_KPI=${GOOD/1. Games played per week -- GA4 game_start/(none yet)}
ok "(none yet) KPIs passes" dossier_validate "$NONE_KPI"

echo "== dossier_validate: failure modes =="
# reason_has <desc> <content> <substring> -- fails, then asserts the printed
# reason line mentions <substring> (greppability check per the ticket).
reason_has() {
  local d="$1" content="$2" substr="$3" v
  if v=$(dossier_validate "$content"); then
    printf '  x %s (expected rc1, got rc0)\n' "$d"; FAIL=$((FAIL + 1)); return
  fi
  if [[ "$v" == *"$substr"* ]]; then printf '  + %s\n' "$d"; else printf '  x %s (reason: %s)\n' "$d" "$v"; FAIL=$((FAIL + 1)); fi
}

BAD=${GOOD/\# porksicle.com/porksicle.com}
reason_has "missing H1 fails" "$BAD" "H1"
NOORDER=${GOOD/'## KPIs'/'## Caveats'}
no "KPIs section renamed/out of order fails" dossier_validate "$NOORDER"
NOKPISRC=${GOOD/1. Games played per week -- GA4 game_start/1. Games played per week}
reason_has "KPI entry missing measurement source fails" "$NOKPISRC" "measurement source"
EMPTYKPI=${GOOD/1. Games played per week -- GA4 game_start/}
no "empty KPIs section fails" dossier_validate "$EMPTYKPI"
BADKEY=$'# porksicle.com\n\nx\n\n## KPIs\n\n(none yet)\n\n## Metadata\n\n```yaml\ntype: arcade\nurl: https://porksicle.com\nbogus: nope\n```\n'
reason_has "unknown Metadata key fails" "$BADKEY" "unknown Metadata key"
NOTYPE=${GOOD/type: arcade/}
reason_has "missing type fails" "$NOTYPE" "missing required key: type"
BADTYPE=${GOOD/type: arcade/type: spaceship}
reason_has "type outside closed list fails" "$BADTYPE" "closed list"
NOURL=${GOOD/url: https:\/\/www.porksicle.com/}
reason_has "site type without url fails" "$NOURL" "requires url"
MISMATCH=${GOOD/url: https:\/\/www.porksicle.com/url: https:\/\/other.example.com}
reason_has "H1/url host mismatch fails" "$MISMATCH" "does not match"
TRAILING=$'# porksicle.com\n\nx\n\n## KPIs\n\n(none yet)\n\n## Metadata\n\n```yaml\ntype: tool\n```\n\ntrailing prose\n'
no "content after the Metadata fenced block fails" dossier_validate "$TRAILING"
NOFENCE=$'# porksicle.com\n\nx\n\n## KPIs\n\n(none yet)\n\n## Metadata\n\ntype: tool\n'
no "Metadata section with no fenced block fails" dossier_validate "$NOFENCE"

echo "== dossier_check_no_nested_metadata =="
ok "prose-only nested AGENTS.md passes"  dossier_check_no_nested_metadata $'# lore\n\njust prose, no metadata\n'
no  "nested AGENTS.md with ## Metadata fails" dossier_check_no_nested_metadata $'# lore\n\n## Metadata\n\n```yaml\ntype: tool\n```\n'

echo "== check_dossier: un-adopted-vs-nonconforming migration gate, nested exemption =="
new_fixture() { local p; p=$(mktemp -d "$TMPROOT/fix.XXXXXX"); git init -q -b master "$p"; git -C "$p" config user.email t@t; git -C "$p" config user.name t; printf '%s' "$p"; }
commit_fixture() { local p="$1"; git -C "$p" add -A; git -C "$p" commit -q -m fixture; _RC_REPO_PATH="$p"; _RC_REF="master"; }

f="$(new_fixture)"; : >"$f/README.md"; commit_fixture "$f"
V=0; check_dossier || V=$?
eq "no root AGENTS.md -> rc2 (legacy, not a failure)" 2 "$V"

# The case the whole fleet is actually in today (this repo included): a root
# AGENTS.md that is ordinary prose. It predates the spec, so it's un-adopted
# -> rc2, NOT a nonconforming dossier.
f="$(new_fixture)"; printf '%s' "$PROSE" >"$f/AGENTS.md"; commit_fixture "$f"
V=0; check_dossier || V=$?
eq "prose root AGENTS.md (no ## Metadata) -> rc2 (un-adopted)" 2 "$V"

f="$(new_fixture)"; : >"$f/AGENTS.md"; : >"$f/README.md"; commit_fixture "$f"
V=0; check_dossier || V=$?
eq "empty root AGENTS.md -> rc2 (un-adopted)" 2 "$V"

f="$(new_fixture)"; printf '%s' "$BADTYPE" >"$f/AGENTS.md"; commit_fixture "$f"
V=0; check_dossier || V=$?
eq "present + nonconforming -> rc1 (hard fail)" 1 "$V"
if [[ "$DOSSIER_REASON" == *"closed list"* ]]; then
  printf '  + DOSSIER_REASON set\n'
else
  printf '  x DOSSIER_REASON: %s\n' "$DOSSIER_REASON"; FAIL=$((FAIL + 1))
fi

f="$(new_fixture)"; printf '%s' "$GOOD" >"$f/AGENTS.md"; mkdir -p "$f/games/snail"
printf '%s' $'# Snail lore\n\njust prose about this one game, no metadata block.\n' >"$f/games/snail/AGENTS.md"
commit_fixture "$f"
V=0; check_dossier || V=$?
eq "root conforms + nested prose-only -> rc0" 0 "$V"

f="$(new_fixture)"; printf '%s' "$GOOD" >"$f/AGENTS.md"; mkdir -p "$f/games/snail"
printf '%s' $'# Snail lore\n\n## Metadata\n\n```yaml\ntype: tool\n```\n' >"$f/games/snail/AGENTS.md"
commit_fixture "$f"
V=0; check_dossier || V=$?
eq "nested AGENTS.md with ## Metadata -> rc1" 1 "$V"

echo "== validate_repo_local: absent AGENTS.md unchanged; broken one hard-fails =="
GBARE="$TMPROOT/good.git"; git init -q --bare -b master "$GBARE"
PR_CI=$'name: ci\non:\n  pull_request:\njobs:\n  test:\n    steps:\n      - run: npm test'
GWORK="$(new_fixture)"
printf '%s' '{"scripts":{"test":"jest"}}' >"$GWORK/package.json"
mkdir -p "$GWORK/.forgejo/workflows"; printf '%s' "$PR_CI" >"$GWORK/.forgejo/workflows/ci.yml"
git -C "$GWORK" add -A; git -C "$GWORK" commit -q -m good
git -C "$GWORK" remote add origin "$GBARE"; git -C "$GWORK" push -q origin master
GCLONE="$TMPROOT/good-clone"; git clone -q "$GBARE" "$GCLONE"
ok "no AGENTS.md at all -> validate_repo_local still passes (rc0)" validate_repo_local demo/good "$GCLONE"

# The regression this gate must not cause: a repo whose root AGENTS.md is
# prose (the pre-spec convention, e.g. this harness's own) validated before
# the dossier check existed and must keep validating after it.
printf '%s' "$PROSE" >"$GWORK/AGENTS.md"
git -C "$GWORK" add -A; git -C "$GWORK" commit -q -m "add prose AGENTS.md"
git -C "$GWORK" push -q origin master; git -C "$GCLONE" pull -q
ok "prose root AGENTS.md -> validate_repo_local still passes (rc0)" validate_repo_local demo/good "$GCLONE"

printf '%s' "$BADTYPE" >"$GWORK/AGENTS.md"
git -C "$GWORK" add -A; git -C "$GWORK" commit -q -m "add broken dossier"
git -C "$GWORK" push -q origin master; git -C "$GCLONE" pull -q
V=0; validate_repo_local demo/good "$GCLONE" >/dev/null 2>&1 || V=$?
eq "otherwise-complete repo with a broken dossier -> rc1" 1 "$V"

if [ "$FAIL" -eq 0 ]; then
  echo "test-dossier: all passed"
else
  echo "test-dossier: $FAIL failure(s)"
fi
exit "$FAIL"
