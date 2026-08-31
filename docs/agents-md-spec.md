# AGENTS.md dossier spec

Every fleet repo carries exactly one context file: `AGENTS.md`, at the
repo root. It is the project's dossier -- what the project is, what
winning looks like, and the decided policy around it -- plus a small
machine-readable block the harness parses. It replaces `CLAUDE.md` and
`CEO.md`; converted repos delete both. `agent.json` is different: it
stays permanently as the home for machine config too structured for the
dossier's flat Metadata block -- see "agent.json: the permanent
structured-config file" below.

The format follows the [AGENTS.md standard](https://agents.md/): plain
markdown, prose for agents to read. This spec constrains it further so
the file is also parseable, checkable, and uniform across the fleet.
Validation enforces this spec; a repo whose dossier doesn't conform
fails validation and drops out of the work pool, loudly.

## Design principles

- **Thin by intent.** The dossier holds only what is true about THIS
  project. Generic craft (how to be a good unattended worker, PR
  discipline, TDD) lives in the harness's `AGENTS.md` system-prompt
  contract, not per repo. Coding standards are the linters' job
  (`lint:` in Metadata), and idiom is the codebase's job -- agents
  match surrounding code. Per-repo prose earns its place only when it
  is about this repo.
- **Durable truth only.** No status, no roadmap, no "current
  priorities." That is what the issue tracker is for. A dossier that
  narrates state starts rotting the day it merges, and rot in a
  context file is worse than absence because agents trust it.
- **Written for amnesia.** The reader is an agent with no memory of
  any prior conversation. Every fact it needs to avoid a category
  error ("this is not a content site") must be in the file.

## Required structure

Sections appear in exactly this order. Headings are exact strings;
validation matches them literally.

1. **H1 + description** (required). The H1 is the project's canonical
   name: the `url` host for sites (`# porksicle.com`), the repo name
   otherwise (`# igor`). A site served from a subdomain uses that
   subdomain; the validation rule below is the definition. The
   paragraph(s) under it must answer two questions: what this project
   is, and who it is for.
2. **`## KPIs`** (required). Either an ordered list -- priority
   order, top entry matters most -- or the literal `(none yet)` as
   the section's entire content, which is honest and valid. An empty
   section is not. Each list entry names its measurement source (a
   GA4 event, a GSC metric, a spreadsheet) after a separator: `--`,
   an em/en dash, or a comma. A KPI with no measurement source is a
   vibe and does not go in the list.
3. **`## DOs and DON'Ts`** (optional). Decided policy, both
   directions, as two bulleted groups or one mixed list. Entries are
   rulings, ideally with a one-clause why: "DON'T build a real-money
   gambling funnel -- ruled out for AdSense/legal/audience." This is
   where a retired `CEO.md` mandate's guardrails and decision
   guidance land. Its value is preventing an amnesiac agent from
   re-litigating what was already decided.
4. **`## Caveats`** (optional). Landmines and gotchas: "the site is
   generated -- edit the generator, never run the build locally."
   Caveats are warnings; policy belongs in DOs and DON'Ts.
5. **`## Metadata`** (required, always LAST). Exactly one fenced code
   block containing flat YAML. Nothing may follow this section.

## The Metadata block

Validation enforces exactly one fenced code block in this section, so
the harness can simply take the first one after the literal heading
`## Metadata` and never encounter a second. Rules:

- Flat `key: value` scalars only. No nesting, no lists, no multiline
  values. The parser is grep/awk, not a YAML library; flatness is
  what keeps it that way. (The block is still valid YAML, so real
  tooling can consume it later without migration.)
- Keys come from the closed vocabulary below. Unknown keys fail
  validation -- extending the vocabulary is a PR to this spec.

| Key | Required | Meaning |
| --- | --- | --- |
| `type` | yes | One of the closed type list below |
| `url` | sites | Canonical live URL; enables auto-merge + deploy barrier (was `agent.json` `.smoke.url`); host must match the H1 |
| `test` | see note | Command that runs the test suite |
| `lint` | no | Command that runs the linter(s) |
| `verify` | no | Command for end-to-end/visual verification (e.g. a Playwright script) |
| `feedback-csv` | no | Published CSV of user feedback for the triage pass (was `agent.json` `.feedback.csv`) |
| `landed-kind` | no | Host-state landed-verification kind for a url-less auto-merge (`lib/landed.sh`); one of `self-pull` or `context-cache` (was `agent.json` `.landed.kind`) |
| `generated-data` | no | Comma-separated glob(s) of generated data files excluded from the finalize-time scope-gate line count (`lib/scope-gate.sh`) |

Note on `test`: validation's existing test-signal rules apply
unchanged -- a repo needs a test signal (a `test:` command or a live
`url` acting as a smoke check) to validate for work.

Note on `landed-kind`: undeclared means no landed-verification watch
at all (the common case -- most url-less repos have nothing for
`lib/landed.sh` to check). A declared value outside the closed list
is a hard fail-fast: `lib/landed.sh` logs it loudly and still records
no watch, rather than guessing.

Note on `generated-data`: globs are matched against paths relative to
the repo root (shell glob syntax, e.g. `src/_data/*.json`), comma
separated for more than one. Undeclared means no exclusion beyond the
gate's existing test/lockfile/`dist/`/`build/` carve-outs -- a repo
that names nothing behaves exactly as before. This exists so a
repo-owned generated file (a nightly data refresh, a build cache
committed to the branch) doesn't get counted as branch work by the
scope gate when a stale base makes the diff look like the branch
rewrote it.

`type` closed list: `arcade`, `game`, `content`, `tool`, `api`,
`personal`, `infra`. Of these, the **site types** -- the ones that
serve a live domain and therefore require `url` -- are `arcade`,
`game`, `content`, `api`, and `personal`; `tool` and `infra` are not
site types and take no `url`. The type drives harness behavior
(which digest treatment a site gets, what a measurement-gap check
expects), so a new value is a harness change, shipped together with
it.

## Validation contract

`validate-repo` asserts, loudly and fail-fast, against the ROOT
dossier only (nested dossiers are exempt from structural checks --
see below):

- Required sections present, in spec order, exact heading strings.
- `## Metadata` is the last section and contains exactly one fenced
  block; the block parses as flat `key: value` lines.
- All keys are in the vocabulary; required keys present (`type`
  always; `url` for site types).
- For site types, the H1 equals the `url` host, with a leading
  `www.` stripped from the host before comparison.
- Each `## KPIs` entry carries a measurement source, or the section
  is exactly `(none yet)`.
- Nested `AGENTS.md` files contain no `## Metadata` section (the
  root dossier is the only machine-readable one).

**Un-adopted vs nonconforming -- the migration gate:** a repo that
has not adopted this spec validates under the legacy rules
(`CLAUDE.md` + `agent.json`) for the duration of the migration
window -- non-adoption is not failure while the fleet converts. The
gate keys on the `## Metadata` heading, not on the file existing: a
root `AGENTS.md` is the near-universal prose convention and predates
this spec, so a root file carrying no `## Metadata` is an ordinary
prose AGENTS.md and takes the legacy path, exactly as an absent one
does. A file that DECLARES itself a dossier by carrying `##
Metadata` is validated in full, and nonconformance is a hard
validation failure immediately: a broken dossier is worse than none,
because agents trust it. Once the fleet is converted the legacy path
is removed and non-adoption itself becomes the failure.

**When "once the fleet is converted" is true:** when no repo in
`VALIDATED_REPOS_JSON` still takes the legacy path -- every validated
repo has a root `AGENTS.md` carrying a `## Metadata` block. That is
mechanically checkable, so it does not depend on anyone remembering.
The PR that converts the LAST repo is the one that deletes the
fallback and flips non-adoption to a failure; a fallback still
standing after that PR is live debt and gets a ticket, not another
migration window.

## agent.json: the permanent structured-config file

Dossier conversion does not delete `agent.json`. The Metadata block above
is deliberately flat -- `key: value` scalars, no nesting, no lists -- so a
grep/awk parser can read it without a YAML library. Some machine config is
inherently structured (a nested object, a list of allowlist entries) and
doesn't fit that shape. `agent.json` is where that config lives, for every
repo, permanently, regardless of dossier adoption.

The split:

| Config | Lives in |
| --- | --- |
| Flat scalars: `type`, `url`, `test`, `lint`, `verify`, `feedback-csv`, `landed-kind`, `generated-data` | Dossier `## Metadata` (or `agent.json` as the legacy fallback for a repo that hasn't adopted the dossier yet) |
| `automerge.require_human` (boolean) | `agent.json` only -- never migrates to the dossier |
| `automerge.maintenance` (object: `branch`, `allowlist`, `data_file`, `rejected_category`) | `agent.json` only -- never migrates to the dossier |

`lib/automerge.sh`'s `automerge_require_human` and
`automerge_maintenance_declaration` read `agent.json` directly and
unconditionally -- not through the dossier fallback chain
(`dossier_get_repo_status`) that the flat scalar keys above use, and not
affected by whether the repo has otherwise adopted the dossier.

**A url-bearing repo must keep an `agent.json` even if it declares
neither key.** `automerge_require_human` fails closed on a state it could
not read, and a missing file is one of those states: no `agent.json` reads
as UNKNOWN and pins every merge to the human gate, forever. So a
url-bearing repo that wants the shadow-gated auto-merge path keeps a
minimal `agent.json` -- `{"automerge": {"require_human": false}}` says it
outright, though any readable JSON object works, since an absent key is an
expressed "not opted in" rather than an unknown. A url-LESS repo is
implicitly human-gated anyway (igor#520; `do_automerge_tick` never reaches
`automerge_require_human` for one), so there the file is genuinely
optional.

## Nested dossiers

Per the AGENTS.md standard, nested files are allowed and the nearest
file wins. A monorepo-ish site (porksicle's per-game directories) may
give each subproject its own small `AGENTS.md` (lore, mechanics, that
game's verify script) under the root dossier's general one. Only the
ROOT dossier carries `## Metadata`; nested files are prose only.

## Authoring and migration

Dossiers are authored by the onboarding wizard (`bin/onboard.sh`,
planned): it scans the repo for what is inferable (stack, test
command, CI, live domain), interviews the operator for what is not
(type, KPIs, rulings), and emits a conforming file. Hand-authoring is
fine too; validation is the gate either way.

Migration order per repo: wizard emits `AGENTS.md`; content worth
keeping from `CLAUDE.md` moves into Caveats/Metadata; a retired
`CEO.md`'s guardrails move into DOs and DON'Ts ("fire the CEO, keep
his notes"); `CLAUDE.md` and `CEO.md` are deleted in the same PR.
`agent.json` is NOT deleted -- see "agent.json: the permanent
structured-config file" above -- unless the repo is url-LESS and declares
neither `automerge.require_human` nor `automerge.maintenance`, in which
case there is nothing left in it to keep. On a url-bearing repo, deleting
it silently converts every future merge into a human-gated one. During the
migration window the harness helpers fall back to `agent.json` for the flat
scalar keys of any repo that has not adopted the spec (see the
un-adopted-vs-nonconforming rule above); that fallback is removed on the
condition stated there --
with the last repo's conversion PR. `agent.json`'s role as the
structured-config home is independent of that fallback and is never
removed.

Acceptance test for a conversion: the amnesia test. A cold agent with
only the thin dossier takes a trivial ticket end-to-end. If it
fumbles, the dossier is missing something load-bearing -- find out
which section was too thin before converting the next repo.

## Example

````markdown
# porksicle.com

Penny arcade -- a collection of small browser games, played casually
in short sessions. For players; not a content site, and success is
people playing, not people reading.

## KPIs

1. Games played per week -- GA4 game_start (custom events, once wired)
2. Return visitors -- GA4 returning-user share

## DOs and DON'Ts

- DO keep ported games faithful to their originals -- parity over
  improvement.
- DON'T add content/SEO surfaces -- this is an arcade, ruled out
  2026-08.

## Caveats

- Each game directory carries its own AGENTS.md with lore and
  mechanics; read it before touching that game.

## Metadata

```yaml
type: arcade
url: https://porksicle.com
test: npm test
feedback-csv: https://docs.google.com/spreadsheets/d/e/.../pub?output=csv
```
````
