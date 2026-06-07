# agent -- Igor's harness

The unattended worker. Wakes on a timer (every minute, 24/7),
claims one piece of work, ships it, sleeps. Each tick runs a
strictly ordered cascade: recovery + validation, then PR-review
pickup, then Igor's own work (daily reading + blog post, weekly
/now refresh + site-work pass -- opt-in via `WEBSITE_REPO`), then
scheduled maintenance, then the claimable-issue grind. Igor's own
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
  maintenance checks, cost tracking).
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

## Off-limits

- `agent-settings.json` -- mutating the permission profile changes
  what Claude can do in production. Coordinate with the operator
  before touching.
- `systemd/` units -- production deploy config. Local dev doesn't
  use systemd; changing these means changing the install on the
  host.
- `.forgejo/workflows/` -- CI config managed by the operator.
