# Design: shadow-review auto-merge gate + daily ship-report

**Date:** 2026-07-20
**Status:** approved design, pre-implementation

## Problem

Today every `smoke.url` repo auto-merges only after **Josh** (`FORGEJO_REVIEWER`)
files an APPROVED review. So Josh is the review gate for the entire fleet — the
throughput bottleneck. The shadow reviewer (`do_review_tick`) already runs and
produces a verdict, but that verdict is advisory: it requests the human, it
doesn't gate.

Goal: let the **shadow review's `APPROVE` gate the merge** for the class of
change a diff+CI review can vouch for, so most PRs ship without Josh — while
keeping a **human gate on the repos where the shadow can't judge the real defect
class**, and giving Josh a daily window into what shipped so he stays in control
by exception.

This is two coupled pieces: (1) a **review-gate selector**, and (2) a **daily
ship-report** as the safety valve. Both ship together.

## Part 1 — Review-gate auto-merge

### The reframe
This is not "turn auto-merge on/off." Every `smoke.url` repo already auto-merges;
what varies is **whose review gate-keeps it** — the human or the shadow. The
change flips the default gate from human to shadow, with a per-repo opt-out that
pins a repo back to the human gate.

### The flag
A per-repo `agent.json` key (idiomatic — sits alongside `.smoke`, `.seo`,
`.feedback`):

```json
"automerge": { "require_human": true }
```

- **Present + true** → this repo's auto-merge requires a **human `FORGEJO_REVIEWER`
  APPROVED** review (today's behavior). The shadow review still runs, but stays
  advisory.
- **Absent / false** → auto-merge fires on the **shadow review verdict ==
  `APPROVE`** (the new default).

### The gate change in `do_automerge_tick`
For each eligible PR (repo has `smoke.url`), all existing gates are unchanged —
**CI green, cleanly mergeable, not-behind, and never on a `REQUEST_CHANGES`**.
Only the *approval* signal changes:

| Repo state | Approval that unlocks the merge |
|---|---|
| `require_human: true` (or igor, below) | human `FORGEJO_REVIEWER` APPROVED review |
| default (no flag) | shadow verdict **== `APPROVE`** |

- **`APPROVE` only, never `COMMENT`.** A shadow `COMMENT` (non-blocking remarks,
  no affirmative sign-off) does **not** auto-merge — it still routes to the human,
  as it does today.
- The shadow verdict is **already read** by `do_automerge_tick` (it checks the
  verdict isn't `REQUEST_CHANGES`), so making an affirmative `APPROVE` the gate is
  a small change — the data is already in `discretionary-state.json` under
  `.review[repo#pr].verdict`.
- On a default (shadow-gated) auto-merge, **stop requesting the human reviewer** —
  awareness comes from the deploy-barrier confirm comment plus the daily
  ship-report. A human can still always approve/merge or `REQUEST_CHANGES` on any
  repo, anytime.

### Carve-outs
Repos whose real defect class a diff-reviewer can't judge stay human-gated:

- **joshing.you** — identity/visual ("is this actually a Josh? is the screenshot
  right?"). Flag `require_human: true`.
- **igor.bot** — the blog; freshness/quality/duplication (the 2026-07-20 duplicate
  post is the worked example — the shadow called it "otherwise mergeable"). Flag
  `require_human: true`.
- **porksicle.com** — the games platform. A game change has to be **play-tested**
  to know it actually works, which a diff review can't do — and porksicle gets
  active autonomous work, so the exposure is real. Flag `require_human: true`.
  (The thin standalone games — snail.io, etc. — stay shadow-gated: rarely changed,
  low exposure. Revisit if one starts getting steady work.)
- **igor** — the harness itself. Has **no `agent.json`/`smoke.url`** → never
  auto-merge-eligible, AND is hard-excluded by `AUTOMERGE_SELF_REPO`. Its blast
  radius (a broken self-deploy crashes the tick meant to smoke-test it) is
  catastrophic and unrecoverable, and `agent.json` is a bot-editable file, so the
  **structural code guard is kept as belt-and-suspenders** even though the flag
  would also exclude it. Unify the *general* mechanism on the flag; keep the hard
  guard on the one repo where a mistake is fatal.
- **joshtronic.com** — not onboarded (no `smoke.url`); safe by omission.

The flag is a blocklist in effect: default = shadow-gated, opt-out per repo. Its
fail-closed property is provided by the pre-existing `smoke.url` eligibility gate
(a new/unknown repo can't auto-merge at all until deliberately onboarded).

### Rollout order (matters)
1. **Flags first.** PR the `automerge.require_human` flag into joshing.you and
   igor.bot `agent.json` (and, for uniformity/visibility, create a minimal
   `agent.json` carrying the flag for igor). These are **inert** until the harness
   reads the key.
2. **Then the gate logic** in `do_automerge_tick`. The moment it goes live, the
   carve-outs are already flagged — no window where a carve-out is unflagged but
   the new logic is active.

## Part 2 — Daily ship-report

The counterweight to removing Josh from the per-PR gate.

### Contents (three sections, priority order)
1. **Needs you** — carve-out PRs (joshing.you, igor.bot) awaiting Josh's review;
   `REQUEST_CHANGES` escalations; deploy-barrier failures (stale build, broken
   sitemap, failed CI on an auto-merge). The don't-let-it-languish list.
2. **Shipped** — every PR that auto-merged + deployed in the trailing 24h, per
   repo, each tagged by **how it was gated**: shadow-`APPROVE` vs human-approved.
   The tag is the point — it shows exactly what the shadow let through unattended.
3. **In-flight** — open bot PRs and claimed tickets still cooking, so nothing is a
   surprise later. (Included deliberately: better to over-surface and trim than
   miss something.)

### Mechanics
- **Fully scripted, no model call.** The report is pure fact (which PRs merged,
  deploy status, what's pending), assembled from the Forgejo API + the `.deploy`
  state — like the SEO and deploy-barrier emails. It therefore sits **above the
  Claude health gate** and still sends during a model cooldown (exactly when
  knowing what shipped matters most).
- **Cadence:** daily, first tick after ~07:00 local, covering the trailing 24h.
  One daily stamp under `.shipreport` in `discretionary-state.json` (self-healing,
  like `.sports`/`.ceo`); clear to force a resend. Dial to twice-daily/weekly
  later.
- **Delivery:** a new `do_shipreport_tick`, sibling to the CEO/sports/logwatch
  digests, gated on `PRIMARY_RECIPIENTS` + SMTP2GO, reusing `email.sh`.

## Testing
- `bin/test-automerge*.sh`: extend for the new gate — a `require_human` repo needs
  a human APPROVED (shadow `APPROVE` alone does NOT merge it); a default repo
  merges on shadow `APPROVE`; a shadow `COMMENT` does NOT merge either; existing
  CI/mergeable/behind/RC gates still hold; igor never merges (both flag and
  structural guard).
- `bin/test-shipreport.sh`: report assembly from fixture data — correct
  section bucketing, the shadow-vs-human gate tag, empty-window degrades cleanly,
  and it makes no model call.

## Non-goals (this phase)
- **No auto-revert.** Phase-1 stays alert-only: the ship-report + deploy-barrier
  alerts are the control surface; a bad auto-merge is reverted by hand.
- **No per-PR-class gating within a repo** (e.g. auto-merging igor.bot's `/now`
  refresh while gating its blog posts). Coarser per-repo carve-out for v1; a later
  refinement.
- **No priority-aware / concurrency changes** to the work loop — out of scope.

## Rollout sequence
1. Spec (this doc).
2. PR: carve-out `agent.json` flags (flags-first).
3. PR: `do_automerge_tick` gate change + tests.
4. PR: `do_shipreport_tick` + tests.
