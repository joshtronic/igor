# agent -- Igor's harness

The unattended worker. Wakes on a timer (every minute, 24/7),
claims one piece of work, ships it, sleeps. Each tick runs a
strictly ordered cascade: recovery + validation, then PR-review
pickup, then Igor's own work (daily reading + blog post, weekly
/now refresh + site-work pass -- opt-in via `WEBSITE_REPO`), then
scheduled maintenance, then the weekly GSC-driven SEO pass (opt-in),
then the daily weekday market report (opt-in), then the daily
logwatch self-report (opt-in), then the
claimable-issue grind. Igor's own
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
  the opt-in market-report pair `marketstack.sh` + `market-report.sh`).
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
  model work (scripted SEO/market emails still run); a daily probe
  covers idle days and a once-daily alert email goes to
  `HEALTH_RECIPIENTS` (falls back to `SEO_PRIMARY_EMAIL`; log-only
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
  repo regardless of validation, since it only files an issue and
  never commits. `ANALYSIS_REPOS_JSON` is the analysis set;
  `VALIDATED_REPOS_JSON` is the work set.
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
  domain properties, not Forgejo repos. Weekly, one domain per tick,
  fully scripted (no LLM). It emails always; for `SEO_AGENTIC_SITES`
  it also files an `Agent`-labeled ticket the normal discovery flow
  works once that repo validates (so SEO *work* still honors the
  validation gate, even though SEO *analysis* doesn't). Set
  `SEO_DEBUG_DOMAIN` to one bare domain to run the pass against just
  that site (otherwise a normal day). State (incl. SEO weekly stamps
  under `.seo`) lives in `~/.local/state/agent/discretionary-state.json`;
  clear a domain's stamp there to re-run it.
- The market report (`do_market_tick`) is opt-in via the marketstack
  (v2 EOD API) + SMTP2GO env and is a sibling of the SEO pass: scripted
  (no LLM), email-only, NOT repo-driven. It's the only DAILY-but-weekday-
  gated schedule (`date +%u` <= 5), and unlike the slots it's independent
  of `WEBSITE_REPO`. Sends one email per weekday on the first tick after
  the midnight rollover -- no send-hour knob, matching the harness's
  no-clock-gating design. It shares `email.sh` with SEO -- both now gate
  on `SMTP2GO_API_KEY` + `SMTP2GO_SENDER` (renamed from
  `SEO_SENDER_EMAIL`; if you change the code's email vars, the host
  `.env` must change in lockstep or BOTH reports break). Because the
  midnight tick can beat marketstack's EOD publish for the just-closed
  session, the send is gated on a freshness check: it only emails once the
  latest bar's date equals the expected previous trading day (yesterday,
  or Friday on a Monday). Two concerns are decoupled in the `.market`
  state object `{date, sent, failures, last_attempt}` (same
  one-key-per-subsystem shape as `.slots`/`.seo`): `last_attempt` (epoch
  secs) spaces EVERY marketstack hit by `MARKET_RETRY_COOLDOWN_SECS`
  (default 15 min) so a stale/empty read doesn't poll the metered API every
  minute; `failures` counts only HARD failures (API error, empty read, or
  send failure) and is capped at a hardcoded 5/day so a bad key or outage
  abandons the day instead of burning quota -- a successful fetch clears
  it, and a stale-but-valid read ("not published yet") is NOT a failure, it
  just holds and re-checks on the next cooldown. `sent` flips true only on
  a successful send. The freshness gate is holiday-naive: on the trading
  day *after* a market holiday the latest bar predates the expected
  previous weekday, so the gate never matches and no report goes out that
  day (logged each cooldown, not silent). Clear `.market` to force a
  re-send. Keep it a single report until there's a real reason to split it.
- The logwatch pass (`do_logwatch_tick`) is convention-driven, NO env
  knob: a root-level `systemd/` directory in any bot-accessible repo
  declares "I run as a service", and once a day (first tick after
  01:00 -- window-completeness, not a send-hour: the 00:00-01:00
  journal being read must have closed) each declared unit's LOCAL
  user journal gets one `claude_call` on `AGENT_MODEL_REVIEW` hunting
  hard failures. Empty journal = unit runs elsewhere or didn't run =
  skip; no canary/uptime semantics, no news is good news. The harness
  discovers itself this way (`systemd/agent.service`); only its
  known-benign blurb is special-cased, keyed off the UNIT name. The
  contract is failure-smell, not narration: retries that succeeded,
  expected holds, anything matching an open issue title, and symptoms
  covered by a recent commit (titles + subjects ride along per repo
  as dedup signals) are explicitly not ticket-worthy. At most 2
  tickets per unit per day, filed on the owning repo UNLABELED and
  ASSIGNED to `FORGEJO_REVIEWER` with review time logged. The `Agent`
  label is the human's triage stamp, never the filing default:
  greenlighting a ticket for Igor = add the label + unassign, and
  until both happen claimable discovery can't see it. Stamped
  attempted under `.logwatch` BEFORE any model call (slot semantics --
  no retry storm); clear `.logwatch` to re-run. When a greenlit ticket
  targets this repo, Igor PRs against its own harness -- safe only
  because a human-reviewed merge gates master (and master self-deploys
  in ~1 minute, so review those PRs accordingly).

## Off-limits

- `agent-settings.json` -- mutating the permission profile changes
  what Claude can do in production. Coordinate with the operator
  before touching.
- `systemd/` units -- production deploy config. Local dev doesn't
  use systemd; changing these means changing the install on the
  host.
- `.forgejo/workflows/` -- CI config managed by the operator.
