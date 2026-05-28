# agent -- Igor's harness

The unattended worker. Wakes on a timer, claims one piece of work,
ships it, sleeps. When no claimable issue is found, the tick fires
ONE discretionary slot (opt-in via `WEBSITE_REPO`): reading,
feature, or design -- one per tick, each once per local day. The
reading pipeline's durable state lives in
`~/.local/state/agent/brain.sqlite`; the per-day slot slate in
`~/.local/state/agent/discretionary-state.json`. This repo is
everything that makes the cron beat real.

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
  next systemd timer fire -- which means a bad commit is live
  in ~10 minutes whether you wanted it to be or not.
- Validation runs every tick against every bot-accessible repo.
  Repos with an open onboarding ticket short-circuit the full
  check; closing the ticket re-enables it.
- The shift window (`AGENT_SHIFT_START`/`_END`) gates Igor-driven
  work only -- scheduled maintenance, the discretionary slots
  (reading/feature/design), and bot-filed tier-1 tickets.
  Human-driven work (validation, recovery, PR-review pickup,
  human-filed tier-1) runs around the clock.
- Discretionary work is slotted: one slot per tick, each slot once
  per local calendar day, priority reading -> feature -> design.
  The per-day slate lives in `discretionary-state.json` and rolls
  over at midnight. This is a deliberate throttle -- don't add
  paths that let multiple discretionary PRs land in one tick.
- `AGENTS.md` is appended to Claude's system prompt for issue
  work and PR review. Other surfaces (maintenance triage, reading
  pipeline, site-work) use task-specific directives from
  `bin/lib/`. Treat changes to any of these the way you would a
  deploy.
- Website work is opt-in via `WEBSITE_REPO`. With it unset the
  discretionary slots no-op cleanly; the rest of the tick (issues,
  maintenance, PR review) still runs.

## Off-limits

- `agent-settings.json` -- mutating the permission profile changes
  what Claude can do in production. Coordinate with the operator
  before touching.
- `systemd/` units -- production deploy config. Local dev doesn't
  use systemd; changing these means changing the install on the
  host.
- `.forgejo/workflows/` -- CI config managed by the operator.
