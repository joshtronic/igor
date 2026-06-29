# agent -- Igor's harness

The unattended worker. Wakes on a timer (every minute, 24/7),
claims one piece of work, ships it, sleeps. Each tick runs a
strictly ordered cascade: recovery + validation, then PR-review
pickup, then Igor's own work (daily reading + blog post, weekly
/now refresh + site-work pass -- opt-in via `WEBSITE_REPO`), then
the code review, then
scheduled maintenance, then the monthly GSC-driven SEO pass (opt-in),
then the daily sports digest (opt-in), then the weekly CEO board digest
(opt-in), then the daily logwatch self-report
(opt-in), then the claimable-issue grind. Igor's own
work comes first and is throttled (daily/weekly slots), so tickets
soak up whatever time is left and roll over to the next day. The
reading pipeline's durable state lives in
`~/.local/state/agent/brain.sqlite`; the per-day/per-week slot
slate in `~/.local/state/agent/discretionary-state.json`. This
repo is everything that makes the cron beat real.

## What's where

- `bin/tick.sh` -- the single per-tick orchestrator. Read this
  first; everything else hangs off it.
- `bin/reading-pipeline.sh`, `bin/site-work-block.sh` -- the
  website-side ticks (opt-in via `WEBSITE_REPO`).
- `bin/*.sh` -- helpers Claude or the operator can invoke
  (`agent-block.sh`, `agent-ask.sh`, `validate-repo.sh`, etc.).
- `bin/lib/` -- shared voice anchor + task directives loaded into
  Claude's system prompt per surface.
- `lib/*.sh` -- sourced shell libraries (Forgejo API, repo checks,
  maintenance checks, cost tracking; the shared SMTP2GO sender
  `email.sh`; the opt-in SEO pair `gsc.sh` + `seo-analysis.sh`; and
  the opt-in sports-digest pair `espn.sh` + `sports-digest.sh`).
- `AGENTS.md` -- the universal agent rules appended to Claude's
  system prompt for issue work and PR review.
- `agent-settings.json` -- Claude's tool permission profile.
- `systemd/agent.{service,timer}` -- the production deploy units.
- `docs/` -- operator-facing notes (architecture, onboarding,
  setup).

## Test command

```sh
make test
```

Runs `bin/check-sync.sh`, which is what CI runs on every PR. The
sync check enforces the `AGENTS.md` <-> `tick.sh` contract: every
`# OUTCOME: <label>` in tick.sh must have a matching
`<!-- OUTCOME: <label> -->` in AGENTS.md, and every `agent-*.sh`
referenced in AGENTS.md must exist and be executable in `bin/`.
It then runs every `bin/test-*.sh` (shell-function unit tests, e.g.
`bin/test-ceo.sh`); each is skip-safe, exiting 0 with a notice if a
tool like `jq` is absent, so the single CI step covers the contract
plus the units without going red on a minimal image.

For deeper checks, `make lint` runs `shellcheck` on `bin/` + `lib/`
and `markdownlint` on the markdown surface. Both require their
respective tools on the host; install or skip.

## Code style

- Bash, with `set -euo pipefail` at the top of every script.
- 2-space indentation (matches existing files).
- Sourced libraries live in `lib/`; entry points in `bin/`.
- Logging via the `log` function defined in `tick.sh`.
- Idempotent remote steps -- every Forgejo-mutating action
  check-then-acts. Crash-safe retry is the design rule.
- No sudo. The harness runs as a regular Unix user; ops work is
  the operator's, not the agent's.

## Gotchas

- ALL model calls go through the `claude` CLI on the host's Claude
  subscription login (OAuth) -- there is no API key in play. Both
  invocation primitives in `lib/claude.sh` (`claude_run_with_cost`
  agentic, `claude_call` one-shot no-tools) strip `ANTHROPIC_API_KEY`
  from the child env: an inherited key silently flips the CLI to
  pay-as-you-go billing. `anthropic_call` (raw Messages API) is kept
  as the escape hatch and has no live call sites. Three model vars
  are REQUIRED in `.env`, stakes-ordered by surface: `AGENT_MODEL`
  (workhorse: issues, site-work, pipelines, PR text),
  `AGENT_MODEL_REVIEW` (PR-review + maintenance triage),
  `AGENT_MODEL_SECURITY` (security gate). `AGENT_MODEL_THINKING` is
  retired. Adding/renaming model vars is a host-`.env` lockstep
  change -- tick.sh fails fast on a missing one, every minute.
- Claude auth/usage health: every CLI call records ok/auth/limit
  under `.health` in `discretionary-state.json` (only auth and
  usage-limit failures count -- ordinary nonzero exits stay the
  surface's problem). While a cooldown is live the tick skips ALL
  model work (the scripted SEO emails still run); a daily probe
  covers idle days and a once-daily alert email goes to
  `PRIMARY_RECIPIENTS` (plus any `HEALTH_RECIPIENTS` extras; log-only
  without SMTP2GO). Clear `.health` to reset. Side effect of
  subscription billing: the cost ledger's `usd` is dollars-EQUIVALENT
  consumed (a plan-usage meter), not dollars billed.
- The harness pulls itself at the top of every tick and re-execs
  if HEAD moved. Any change pushed to master takes effect on the
  next systemd timer fire -- and ticks fire every minute, so a bad
  commit is live in ~1 minute whether you wanted it to be or not.
  (Changing the timer interval or any `systemd/` unit needs a
  `systemctl --user daemon-reload` + `restart agent.timer` on the
  host; the self-pull updates the file but does not reload systemd.)
- Validation runs every tick against every bot-accessible repo.
  Repos with an open onboarding ticket short-circuit the full
  check; closing the ticket re-enables it. Validation gates only
  WORK (issue pickup, PR pushes, site-work) -- the read-only weekly
  analysis pass (security/dep audit) runs on every bot-accessible
  repo regardless of validation, since the audit itself only files
  tickets and never commits. `ANALYSIS_REPOS_JSON` is the analysis
  set; `VALIDATED_REPOS_JSON` is the work set. Validation is also what
  proves a repo has tests + CI: `check_test_signal` AND
  `check_ci_workflow` are both REQUIRED to pass, so "validated" is a
  reliable stand-in for "a dependency bump here can be CI-verified" --
  which is exactly the gate the maintenance pass uses to decide
  PR-vs-issue (next bullet).
- The maintenance pass (`do_maintenance_tick` ->
  `do_maintenance_for_repo`, weekly, one ISO-week stamp per repo under
  `.maintenance`) is a two-tier Dependabot. The harness runs the audit
  tools (`lib/maintenance-checks.sh`); a clean repo costs no LLM. On
  findings, ONE `claude_call` on `AGENT_MODEL_REVIEW` CLASSIFIES (never
  fixes) into lanes and the harness files up to four DEDUPED tickets,
  each keyed by an HTML-comment marker (skip-if-open dedup, like the
  SEO/onboarding tickets -- a repo is audited at most once per ISO
  week, so the guard is just last week's ticket still being open):
  `maint-security` + `maint-bumps` are **Agent-labeled, unassigned**
  work tickets that the normal claimable grind turns into a reviewed PR
  -- filed ONLY for validated repos (the validation gate IS the opt-in;
  no separate list), so unverifiable PRs never land; `maint-triage` is
  the human ticket for majors/judgment, or for EVERYTHING when the repo
  isn't validated (audit reach is preserved for every repo, PR-routing
  is not); `maint-tooling` fires when an audit tool can't run --
  uninstallable (`:skipped`) OR crashed mid-scan (`:error`, e.g.
  govulncheck failing to build) -- because a tool that didn't run is a
  blind spot, not a clean bill. Auto-Agent-labeling bump tickets means
  dep PRs open without a per-ticket human greenlight (matching the SEO
  agentic-site precedent); the human gate is the PR review/merge.
  govulncheck is kept but deprioritized (flaky); its `:error` rides the
  deduped `maint-tooling` ticket so it can't spam.
- There is no shift window -- the tick runs 24/7. Midnight is just
  the local-day rollover for the daily slots; the cascade's fixed
  priority order is what shapes what runs, not the clock.
- Igor's own work is slotted, one piece per tick: DAILY reading +
  blog post (reset at midnight) and WEEKLY /now refresh + site-work
  pass (ISO week, Monday-anchored, self-healing). The blog post is
  special -- its slot stays open and retries every tick until a post
  actually ships that day (capped by `POST_MAX_ATTEMPTS`). State
  lives in `discretionary-state.json` (`slots` daily, `weekly`
  weekly). This is a deliberate throttle -- don't add paths that let
  multiple discretionary PRs land in one tick.
- Validation is cached per repo for `VALIDATION_COOLDOWN_SECS`
  (15 min) so the per-tick cost doesn't compound at the 1-minute
  cadence as repos are added. Only PASSes are cached; failures
  re-check every tick.
- `AGENTS.md` is appended to Claude's system prompt for issue
  work and PR review. Other surfaces (maintenance triage, reading
  pipeline, site-work) use task-specific directives from
  `bin/lib/`. Treat changes to any of these the way you would a
  deploy.
- Website work is opt-in via `WEBSITE_REPO`. With it unset the
  daily/weekly Igor slots no-op cleanly; the rest of the tick
  (issues, maintenance, PR review) still runs.
- The SEO pass (`do_seo_tick`) is opt-in via the GSC + SMTP2GO env
  and is GSC-driven, NOT repo-driven -- it enumerates Search Console
  domain properties, not Forgejo repos. Monthly (once per calendar
  month per domain, self-healing -- not a hard day-of-month window),
  one domain per tick, fully scripted (no LLM). The 28-day analysis
  window pairs with the monthly beat so each run gets a fresh,
  near-non-overlapping window and last month's fixes have time to land
  before re-evaluation; `seo_period` in `tick.sh` is the single knob if
  the cadence ever changes. It emails always; for `SEO_AGENTIC_SITES`
  it also files an `Agent`-labeled ticket the normal discovery flow
  works once that repo validates (so SEO *work* still honors the
  validation gate, even though SEO *analysis* doesn't). Set
  `SEO_DEBUG_DOMAIN` to one bare domain to run the pass against just
  that site (otherwise a normal day). State (incl. SEO monthly stamps
  under `.seo`, now `YYYY-MM`) lives in
  `~/.local/state/agent/discretionary-state.json`; clear a domain's
  stamp there to re-run it. The SEO, sports, CEO, and alert emails all
  share `email.sh`, gating on `SMTP2GO_API_KEY` + `SMTP2GO_SENDER`
  (renamed from `SEO_SENDER_EMAIL`); change the code's email vars and the
  host `.env` must change in lockstep or those emails break.
- The sports digest (`do_sports_tick`) is opt-in via `SPORTS_RECIPIENTS`
  + `SPORTS_LEAGUES` + SMTP2GO and is another email sibling -- but the
  FIRST that uses the model (scripted ESPN fetch via `lib/espn.sh`, ONE
  `claude_call` distill on `AGENT_MODEL`), so unlike SEO it sits
  below the health gate and goes dark during a Claude cooldown. Daily,
  7 days a week, first tick after 03:00 (window-completeness like
  logwatch: the digest covers YESTERDAY and west-coast games end past
  midnight CT). `SPORTS_LEAGUES` is one flat CSV of ESPN
  `{sport}/{league}` paths -- no tier var; the directive
  (`bin/lib/sports-digest-directive.md`) curates by significance.
  Day-state is `.sports = {date, sent, failures, last_attempt}`: a
  cooldown via `SPORTS_RETRY_COOLDOWN_SECS`, a hardcoded 5-failure cap,
  and `sent` flips only on a successful send. Deliberately no
  clear-on-good-fetch -- ESPN being up says nothing about the distill,
  and clearing would let a parse-flaky day burn unbounded model calls.
  Clear `.sports` to force a re-send. The model's output is label-line +
  `===BODY===` sentinel, parsed harness-side -- never model-written
  JSON; links must come from the ESPN payload verbatim. The taught-
  concepts curriculum ledger (what makes it a course, not a loop) lives
  in `~/.local/state/agent/sports-curriculum.json` -- a SEPARATE file,
  appended only after a successful send and capped at 300, so clearing
  `.sports` never wipes what the reader has been taught.
- The logwatch pass (`do_logwatch_tick`) is convention-driven, NO env
  knob: a root-level `systemd/` directory in any bot-accessible repo
  declares "I run as a service", and once per clock hour (reviewing the
  hour that JUST CLOSED -- window-completeness, not a send-hour: the
  window read must be complete, which the previous hour always is, so
  there's no midnight gate) each declared unit's LOCAL user journal gets
  one `claude_call` on `AGENT_MODEL_REVIEW` hunting hard failures. The
  daily pass only ever read the 00:00-01:00 window -- 23 hours a day were
  unwatched; hourly closes that blind spot. Dedup (open-issue titles +
  recent commits) keeps a chronic failure to ONE ticket, not one/hour. Empty journal = unit runs elsewhere or didn't run =
  skip; no canary/uptime semantics, no news is good news. The harness
  discovers itself this way (`systemd/agent.service`); only its
  known-benign blurb is special-cased, keyed off the UNIT name. The
  contract is failure-smell, not narration: retries that succeeded,
  expected holds, anything matching an open issue title, and symptoms
  covered by a recent commit (titles + subjects ride along per repo
  as dedup signals) are explicitly not ticket-worthy. At most 2
  tickets per unit per hour, filed on the owning repo UNLABELED and
  ASSIGNED to `FORGEJO_REVIEWER` with review time logged. The `Agent`
  label is the human's triage stamp, never the filing default:
  greenlighting a ticket for Igor = add the label (that's the gate;
  an Agent-labeled ticket still assigned to the reviewer is claimable,
  so unassigning is optional cleanup, not required). Stamped
  attempted under `.logwatch` BEFORE any model call (slot semantics --
  no retry storm); clear `.logwatch` to re-run. When a greenlit ticket
  targets this repo, Igor PRs against its own harness -- safe only
  because a human-reviewed merge gates master (and master self-deploys
  in ~1 minute, so review those PRs accordingly).
- The code review (`do_review_tick`) is convention-driven with NO env
  knob -- like logwatch, its closest sibling, the merge IS the opt-in;
  a misbehaving pass is a one-PR revert like any other harness bug. Bot
  PRs open with no reviewer assigned; `do_review_tick` finds the first
  open bot PR whose head hasn't been reviewed yet. ONE `claude_call` on
  `AGENT_MODEL_REVIEW` (the non-author tier -- the thing under review
  doesn't audit itself, honoring the supply-chain trust boundary)
  produces a verdict (APPROVE/REQUEST_CHANGES/COMMENT). APPROVE or
  COMMENT requests the human reviewer; REQUEST_CHANGES assigns the bot
  and drives Igor's rework loop, capped at 3 rounds then escalates to
  the human. The requested-changes text rides in
  `.review.pending_rc_body`; the PR-pickup filter reads it because
  assignment is the turn marker (issue-type recovery and pull-type
  pickup don't collide). Patch-id dedup: a head that is only a
  base-merge (same net diff) is recorded as seen but NOT re-reviewed.
  Runs on the VALIDATED set: unvalidated repos (including onboarding-
  open repos) are skipped -- a verdict there can never graduate to a
  merge signal, so it's just bot footprint on a not-ready repo.
  Per-SHA dedup under `.review` in `discretionary-state.json`; the
  per-sha comment marker (`<!-- review sha=... -->`) is the crash-safety
  net against a duplicate post on a crash-between-post-and-record. The
  verdict is a `VERDICT:` label-line + `===BODY===` sentinel parsed
  harness-side (`review_parse_response`), never model-written JSON. CI
  status for the head rides into both the prompt and the recorded
  verdict -- and the pass WAITS for CI to settle (success/failure/error)
  before reviewing at all: a pending build can't be assessed, so a
  not-yet-settled head is skipped (re-checked next tick) rather than
  burned on a useless "CI pending, re-run" verdict. NEVER auto-merge this
  harness's own repo -- self-deploy +
  blast radius means it stays a human gate regardless of verdict. Clear
  a PR's `.review` entry to force a re-review.
- The CEO board digest (`do_ceo_tick`) is convention-driven with NO env
  knob -- like logwatch and the review tick, the convention IS the opt-in:
  any analysis-set repo carrying a root `CEO.md` mandate is under
  autonomous CEO management (the mandate's mere presence opts it in, and
  the mandate itself -- mission, ranked priorities, the authority "rope,"
  guardrails -- is the system prompt). WEEKLY, one repo per tick: read the
  mandate + gather that repo's week (PRs merged, issues opened/closed, the
  open `Agent` queue), ONE `claude_call` on `AGENT_MODEL` writes a board
  digest assessing the week against the mandate's priorities, emailed to
  `PRIMARY_RECIPIENTS` (plus any `CEO_RECIPIENTS` extras; needs SMTP2GO). A
  model call, so it sits BELOW the health gate and goes dark in a Claude
  cooldown. Per-repo ISO-week stamp under `.ceo` in
  `discretionary-state.json` (self-healing; one digest per repo per week,
  so several managed repos digest over successive ticks); clear a repo's
  `.ceo` entry to force a re-send. The digest is a `SUBJECT:` label-line +
  `===BODY===` sentinel parsed harness-side (`ceo_parse_response`), never
  model-written JSON. **Phase 2 adds proposing-as-agency:** the same model call
  may append `===ISSUE===` proposal blocks, which the harness files as
  **UNLABELED issues assigned to `FORGEJO_REVIEWER`** (each stamped
  `CEO_PROPOSAL_MARKER`). `_ceo_parse_issues` **caps the count at two
  harness-side** -- the limit is enforced, never left to model restraint. They become real work only when the human greenlights
  them -- add the `Agent` label (unassigning optional) -- so the human merge/label gate is
  intact and a poisoned mandate can at worst mis-propose, never ship code.
  Throttle: a fresh batch is filed only when no proposal is still open
  (`ceo_open_proposals_count` == 0), so they never pile up. **Phase 3 adds
  decision-guidance redlines:** the same call may end with a `===GUIDANCE===`
  line distilled from the board's verdicts on prior proposals (greenlit /
  declined / pending, via `ceo_proposal_outcomes`); the harness **opens a PR**
  appending it to a `## Decision guidance` section in `CEO.md`
  (`ceo_open_guidance_pr` -- contents-API + new_branch, no clone) for the board
  to merge. Append-only (it adds what it learned, never rewrites/erases),
  throttled to one open guidance PR (`ceo_guidance_pr_open`), so `CEO.md` learns
  how Josh decides over time. The CEO still never commits to `master` or merges --
  it drafts (issues + redline PRs), the board ratifies; further agency
  (auto-Agent-label, daily steering) stays a deliberate, human-gated step per
  "start tight, loosen as trust earns it."
- The auto-merge + deploy barrier (`lib/automerge.sh`, Phase 1) is the "after you
  approve, your job ends" step -- convention opt-in like the CEO/logwatch: a repo
  is auto-merge-eligible IFF its root `agent.json` (`AGENT_CONFIG_FILE` -- the
  shared per-repo machine-config dossier, jq-parsed; each feature reads its own
  key) carries a `.smoke.url` declaring its live URL. `do_automerge_tick` merges a
  bot PR only when the human (`FORGEJO_REVIEWER`)
  has an APPROVED review, CI is green on the head, it's cleanly mergeable, AND the
  shadow verdict isn't `REQUEST_CHANGES` (an RC blocks the merge even past a human
  approve); it then stamps a pending deploy under `.deploy`. **Require-up-to-date
  is handled, not fought:** the gate also checks `automerge_behind_count` (the PR
  head vs its base branch) -- the merge API rejects a behind PR, so rather than
  POST a doomed merge (the old "merge API failed" warning), a ready-but-behind PR
  gets its branch UPDATED (`automerge_update_branch`, Forgejo's base-merge) and
  merges a cycle later once CI re-runs green. The human approval survives the
  base-merge (Forgejo doesn't dismiss it) and the shadow review's patch-id dedup
  skips re-reviewing the same net diff. To avoid thrashing a fast-moving master,
  it prefers to merge a CURRENT pr each tick and only updates ONE behind pr when
  none is current -- and the deploy barrier freezes master between deploys, giving
  the update its window. An inconclusive up-to-date check (`-1`) just skips the
  tick rather than guessing. `do_deploy_barrier`
  (run EARLY, above the health gate, as `do_deploy_barrier && exit 0`) watches it:
  it polls CI, and while the deploy is still in flight it ENDS the tick -- the
  1-minute cadence IS the polling loop, so no long work starts mid-deploy (one
  deploy at a time, since the barrier sits above the work, including the
  auto-merge step itself). On CI-green it verifies the deploy actually LANDED, not
  just that the site is up (monit owns up/down): it reads the live page's `<meta
  name="deploy-sha">` and asserts it equals the merged commit -- **PROPAGATION**,
  proving the build that's *serving* is the one we merged -- with a few ticks of
  grace for rsync/propagation lag; a page carrying no marker degrades to a plain
  2xx/3xx liveness curl. Then **sitemap-when-available**: if `<base>/sitemap.xml`
  exists it GETs every `<loc>` and flags any non-2xx (capped at 500, logged if
  exceeded). It clears + posts a **confirm comment on the merged PR** on success,
  or emails `ALERT_RECIPIENTS` (plus a failure comment) on a failed CI, a
  stale/unreachable build, or a broken sitemap page. The *build* emits the meta
  itself (porksicle's `eleventy.config.js` stamps `git rev-parse HEAD`), so no CI
  change is needed; correctness stays in CI (E2E pre-merge), the barrier owns
  propagation, monit owns liveness. The merge itself passes
  `delete_branch_after_merge` (the repo's "delete by default" is only a UI-form
  default; an API merge must opt in explicitly), so the head branch is cleaned
  up. Both are non-model (API + curl), so they run even during a Claude cooldown.
  **Phase 1 is alert-only -- NO auto-revert.** NEVER the harness's own repo: a watcher can't reliably watch
  itself (a broken self-deploy could crash the very tick meant to smoke-test it),
  so igor stays a manual merge -- enforced by `AUTOMERGE_SELF_REPO` AND by having
  no `agent.json` `.smoke.url`. Clear `.deploy` to abandon a stuck deploy.
- The feedback-triage pass (`do_feedback_tick`, `lib/feedback.sh`) is
  convention-driven via `agent.json` `.feedback.csv` -- the published Google-Form
  CSV of player feedback (the second `agent.json` consumer after auto-merge).
  PER-TICK, one row: it takes the OLDEST unprocessed row across the analysis set,
  ONE `claude_call` on `AGENT_MODEL_REVIEW` reads the feedback (clearly fenced as
  UNTRUSTED data, never instructions) plus GENERIC tracker context -- recent
  CLOSED issues, recent commits, and a targeted keyword search of issues/commits
  for the subject the feedback names (`feedback_search_prior`, which reaches older
  fixes the recent-N lists miss). No repo-specific catalog or file layout: the
  harness has none, and the model takes the named subject as-given (an unfamiliar
  name is just a name, never "no such game"). It decides **DROP** (spam / vague /
  already-worked, judged from that context) or **FILE** (real + new), in which
  case the harness opens an UNLABELED issue assigned to `FORGEJO_REVIEWER`, who
  greenlights (adds the `Agent` label; unassigning is optional) or rejects
  (closes). Every row
  is stamped in a local seen-set (`.feedback.seen`, FIFO-capped) so it's triaged
  once; nothing is written back to the sheet (the issue tracker IS the status, so
  no status column). The human label gate bounds prompt-injection -- a poisoned
  row at worst yields a ticket Josh rejects, never code; the model MAY silently
  drop confident spam/dupes (operator's call), so not every row becomes a ticket
  but the seen-set still records it. Model work, so it sits BELOW the Claude
  health gate. The verdict is a `DECISION:` line + `REASON:` (DROP) or
  `TITLE:`/`===BODY===` (FILE), parsed harness-side (`feedback_parse_response`),
  never model-written JSON. Needs `python3` (robust quoted-CSV parsing). On FILE
  the model may also emit an optional `LABELS:` line for **loose classification**,
  chosen ONLY from the repo's OWN existing labels (`feedback_repo_labels` lists
  them in the prompt and `feedback_resolve_labels` maps the picks back to IDs --
  the issue API takes IDs, not names). It is deliberately NOT a 1:1 type→label
  map: the model picks whatever fits, or nothing, and a name it invents simply
  doesn't resolve. `feedback_repo_labels` EXCLUDES the harness's workflow labels
  (`Agent` = the greenlight gate, plus `Status/*` and `onboarding`), so a
  model-applied classification can never bypass the human greenlight. No label is
  created and none is required -- repos without a label set just file unlabeled.
  Clear `.feedback.seen` to re-triage.

## Off-limits

- `agent-settings.json` -- mutating the permission profile changes
  what Claude can do in production. Coordinate with the operator
  before touching.
- `systemd/` units -- production deploy config. Local dev doesn't
  use systemd; changing these means changing the install on the
  host.
- `.forgejo/workflows/` -- CI config managed by the operator.
