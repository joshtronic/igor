# AGENTS.md dossier spec

Every fleet repo carries exactly one context file: `AGENTS.md`, at the
repo root. It is the project's dossier -- what the project is, what
winning looks like, and the decided policy around it -- plus a small
machine-readable block the harness parses. It replaces `CLAUDE.md`,
`agent.json`, and `CEO.md`; converted repos delete all three.

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

Note on `test`: validation's existing test-signal rules apply
unchanged -- a repo needs a test signal (a `test:` command or a live
`url` acting as a smoke check) to validate for work.

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
his notes"); `CLAUDE.md`, `agent.json`, and `CEO.md` are deleted in
the same PR. During the migration window the harness helpers fall
back to `agent.json` for any repo that has not adopted the spec (see
the un-adopted-vs-nonconforming rule above); the fallback is removed on
the condition stated there -- with the last repo's conversion PR.

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
