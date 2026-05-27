# agent -- Igor's harness

The unattended worker. Wakes on a timer, claims one piece of work,
ships it, sleeps. The brain is at `igor/brain`; the website at
`igor/website`; this repo is everything that makes the cron beat
real.

## What's where

- `bin/tick.sh` -- the single per-tick orchestrator. Read this
  first; everything else hangs off it.
- `bin/*.sh` -- helpers Claude or the operator can invoke
  (`agent-block.sh`, `agent-enqueue.sh`, `validate-repo.sh`, etc.).
- `lib/*.sh` -- sourced libraries (Forgejo API, repo checks,
  maintenance checks, RAG, cost tracking).
- `AGENTS.md` -- the universal agent rules appended to every
  Claude system prompt. The harness reads this every tick.
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
  work only -- scheduled maintenance, discretionary website work,
  and bot-filed tier-1 tickets. Human-driven work (validation,
  recovery, PR-review pickup, human-filed tier-1) runs around the
  clock.
- AGENTS.md is appended to Claude's system prompt every tick.
  Treat changes to it the way you would a deploy.
- Brain-side lint failures (markdownlint on journal entries Igor
  writes) cascade into recovery loops. When changing the format
  of any harness-templated brain content, lint the templated
  output against `brain/.markdownlint.json` before pushing.

## Off-limits

- `agent-settings.json` -- mutating the permission profile changes
  what Claude can do in production. Coordinate with the operator
  before touching.
- `systemd/` units -- production deploy config. Local dev doesn't
  use systemd; changing these means changing the install on the
  host.
- `.forgejo/workflows/` -- CI config managed by the operator.
