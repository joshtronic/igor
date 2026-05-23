# Architecture

## How the agent works

A timer fires `bin/tick.sh`. Per tick:

1. **Lock.** Global flock -- only one tick at a time. No two-puppet show.
2. **Identity.** Resolve the bot's Forgejo login from the token via
   `/api/v1/user`. No `BOT_USER` config; the token is the identity.
3. **Recovery sweep.** Any open issue still assigned to the bot from a
   previous interrupted run gets a "previous tick was interrupted --
   re-queueing" comment and is unassigned. Nothing slips through a midnight
   crash.
4. **Discovery.** List every repo the bot has push access to (one API call).
   For each:
   - If we haven't cloned it yet, run onboarding validation via the Forgejo
     API. Repos that fail get an auto-filed `Status/Need More Info` ticket
     listing what's missing (or a reopen on the existing one), and are
     excluded from discovery until the human closes the ticket.
   - If there's an open bot-authored PR, skip -- one PR at a time per repo
     so the human can review without a backlog forming behind them.
   - Otherwise, query for the oldest claimable issue (`Agent`-labeled, no
     assignee, not `Status/Blocked`).

   Pick the globally oldest across all eligible repos.
5. **Claim and clone.** Assign the issue to the bot. If the repo isn't cloned
   locally yet, clone it to `~/.local/state/agent/repos/<owner>/<repo>/` via SSH.
6. **Preflight.** Verify `CLAUDE.md` exists at the repo root. If not, block
   the issue with a clear comment and bail. (Same code path as Claude calling
   `agent-block.sh` from inside the worktree.)
7. **Work.** Make a worktree, invoke Claude with the project's `CLAUDE.md`
   plus the universal `AGENTS.md`, react to whatever Claude leaves behind.
8. **Discretionary maintenance (tier 2).** If steps 4-7 found no
   claimable work, fire one maintenance pass on a random eligible
   repo. Gated by `AGENT_MAX_OPEN_PRS` (default 3) and per-repo
   weekly cadence (one audit per repo per ISO week). Claude reads
   the repo's `CLAUDE.md` Maintenance section, runs the declared
   checks, writes findings to `.git/AGENT_MAINTENANCE_FINDINGS.md`.
   Harness files an Agent-labeled issue with those findings if
   non-empty, then updates the cooldown state at
   `~/.local/state/agent/discretionary-state.json`.
9. **Discretionary self-directed work (tier 3).** If no maintenance
   repos are eligible either, the agent does one freeform pass on his
   own website. Same throttles apply (open-PR cap), plus the
   one-PR-per-repo rule (skip if there's an open bot PR on the
   website). Claude reads the website's `CLAUDE.md`, picks one
   focused improvement (post, design, copy, layout), and opens a
   PR with no `Closes #N` since there's no source issue. Branch
   name pattern: `agent/discretionary-YYYY-MM-DD-HHMMSS`.

| What Claude did                 | What the agent does                                                |
|---------------------------------|---------------------------------------------------------------|
| Made commits                    | Push branch, open PR with `Closes #N` + deps audit            |
| Closed the issue with a comment | Treat as a report -- log and clean up                         |
| Applied `Status/Blocked`        | Log, clean up, wait for the human                             |
| Nothing                         | Unassign, leave a "no work" comment with Claude's tail output |

Filing issues is not the agent's job. Project cron jobs, hand-filed issues,
external bots -- all valid producers. They POST to Forgejo with the `Agent`
label and the agent picks it up.

## Labels

Two labels carry the state machine for agent-work tickets. `Status/Blocked`
comes from Forgejo's Advanced label template; `Agent` is custom (created
per-repo). Onboarding-failure tickets also use `Status/Need More Info` and
`Priority/Critical`, both from the Advanced template. See
[onboarding-a-repo.md](onboarding-a-repo.md) for how to set them up.

| State               | Labels                     | Assignee  | Open?  |
|---------------------|----------------------------|-----------|--------|
| Filed, not approved | -- (or `Kind/*`)           | --        | open   |
| Approved, claimable | `Agent`                    | --        | open   |
| In progress         | `Agent`                    | `<bot>`   | open   |
| Blocked             | `Agent` + `Status/Blocked` | --        | open   |
| Done                | (any)                      | (any)     | closed |

`Agent` is a **permission flag** ("agent's domain"), not a state. State is
carried by `Status/Blocked`, the assignee, and open/closed.

Useful queries:

- Claimable: `is:open label:Agent no:assignee -label:Status/Blocked`
- In flight: `is:open label:Agent assignee:<bot user>`
- Stuck: `is:open label:Status/Blocked`

The agent also files `Status/Need More Info` + `Priority/Critical` tickets for repos
that fail onboarding validation. See [onboarding-a-repo.md](onboarding-a-repo.md).

## Pieces

In the repo (versioned policy + harness code):

```
bin/
|-- tick.sh                  # the worker (one issue per invocation)
|-- agent-block.sh           # Claude calls this when stuck
|-- agent-report.sh          # Claude calls this for no-diff outcomes
|-- check-sync.sh            # CI lint: AGENTS.md <-> tick.sh contract
|-- validate.sh              # validate env + Forgejo connectivity + bot perms
|-- validate-repo.sh         # audit a single repo (or --all) for readiness
|-- install.sh               # one-time: install systemd units + enable timer
`-- uninstall.sh             # stop, disable, remove units

lib/
|-- forgejo.sh               # Forgejo API helpers
`-- repo-checks.sh           # repo-readiness checks + onboarding ticket lifecycle

systemd/                     # user units (no @ instance)
|-- agent.service
`-- agent.timer

AGENTS.md                    # universal unattended rules -- appended to Claude's system prompt
agent-settings.json          # bot's permission profile -- passed via --settings
```

On the host (deployment-specific, not in the repo):

```
~/.local/share/agent/                          # the harness install (systemd-managed)
~/.local/share/agent/.env                      # secrets, chmod 600 -- the only config
~/.local/state/agent/lock                      # global flock
~/.local/state/agent/worktrees/<key>/          # per-tick worktrees
~/.local/state/agent/repos/<owner>/<repo>/     # harness's per-repo clones
~/.local/state/agent/repos/<bot>/brain/        # the agent's brain -- bootstrap-required
~/.local/state/agent/repos/<bot>/website/      # the agent's website -- bootstrap-soft
~/.config/systemd/user/agent.{service,timer}  # symlinks into the harness install
```

Harness state lives entirely under `~/.local/state/agent/`, isolated
from `~/Code/` (your interactive workspace) and from `~/.local/share/agent/`
(the install itself). Per-repo clones nest by owner to mirror
Forgejo's URL structure and prevent same-name collisions across
different owners.

## Scope and trade-offs

The agent handles only `Agent`-labeled issue -> outcome work. It does **not**
handle:

- **Filing issues.** Producers do that -- cron jobs, external bots, you
  typing at a keyboard. The agent is a consumer.
- **Report-only jobs** (SEO sweeps, weekly summaries) that don't fit issue
  -> PR/report. Run those as plain cron. They may file agent issues as a side
  effect.
- **Interactive Claude.** Use Claude Code normally in repos; the agent is the
  unattended layer.
- **Pipelines, ETL, long-running daemons.** Not the agent's shape.

Known trade-offs:

- **Cost gating depends on producers being conservative.** Noisy producers
  file spurious issues that the agent will work and burn tokens on. Keep producers
  tight.
- **Sessions are stateless.** Each tick is a fresh Claude invocation. Durable
  state lives in the repo, the issue, and `state/`.
- **One host per the agent install.** Two hosts watching the same Forgejo will
  race on issue claim.
- **Oldest claimable wins.** No priority labels. Urgency = file the urgent
  issue first.
- **Recovery, not resume.** An interrupted tick re-queues its issue; the next
  tick starts fresh.
- **Scope cap.** A branch over 10 commits or 400 changed lines gets blocked
  instead of shipped, with a comment listing the touched files. Split the
  ticket and re-queue.
- **One PR per repo.** While a bot PR is open in a repo, the rest of that
  repo's claimable issues wait. Intentional throttle; merge or close to
  resume.
- **Metered cost per tick.** The agent runs against the Anthropic API (not the
  Max plan -- that's for interactive Claude Code), so every tick costs
  money in proportion to context size and tool use. Wall-clock and turn
  caps bound the worst case, but watch the Console for the first week to
  calibrate. Prompt caching on the stable `AGENTS.md` + per-repo
  `CLAUDE.md` portion drops repeat input cost ~90%.
- **Tests-vacuous-true.** Definition of done is "tests pass." A test command
  that exits 0 with zero tests run (e.g. `jest --passWithNoTests`) is a
  vacuous pass. The harness greps Claude's output for obvious zero-test
  patterns and blocks, but the real defense is a meaningful test command
  in `CLAUDE.md`. Repos with weak test discipline get a weaker bar.
- **Supply-chain alerting, not prevention.** Every PR the agent opens gets a
  harness-generated `## Dependencies changed` section listing manifest /
  lockfile diffs with line counts -- so a `npm install evil-package` is
  impossible to miss in review. The harness writes that section, not
  Claude, so the thing under review can't omit it. The agent does **not**
  sandbox installs or scan package contents -- a malicious package could
  still run install scripts during the work. The defense is human PR
  review armed with the audit.
