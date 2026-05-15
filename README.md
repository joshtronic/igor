# Tick

> "SPOOOON!"

Unattended Claude Code in a big blue moth costume. One global Tick fires on a
timer, sweeps every project's Forgejo issue queue for `Agent`-labeled work,
claims the oldest one, spins up a worktree, lets Claude do the heroics, and
ships a PR. Or posts a report. Or flags `Status/Blocked` and waits for the city
to look at it.

The work runs under a dedicated Forgejo user (`$BOT_USER`, default `agent`) with
its own SSH key, API token, and server account. Tick fires; the bot does the
swinging.

## How Tick works

A timer fires `bin/tick.sh`. Per tick:

1. **Lock.** Global flock -- only one Tick at a time. Justice cannot be in two
   places at once.
2. **Recovery sweep.** Any open issue still assigned to the bot from a previous
   interrupted run gets a "previous tick was interrupted -- re-queueing" comment
   and is unassigned. No villain escapes by tripping the harness mid-fight.
3. **Discovery.** Query every configured project's Forgejo repo for the oldest
   claimable issue (`Agent`-labeled, no assignee, not `Status/Blocked`). Pick
   the globally oldest.
4. **Justice.** Assign to the bot, make a worktree, invoke Claude with the
   project's `CLAUDE.md` plus the universal `AGENTS.md`, react to whatever
   Claude leaves behind.

| What Claude did                 | What Tick does                                                |
|---------------------------------|---------------------------------------------------------------|
| Made commits                    | Push branch, open PR with `Closes #N`                         |
| Closed the issue with a comment | Treat as a report -- log and clean up                          |
| Applied `Status/Blocked`        | Log, clean up, wait for the human                             |
| Nothing                         | Unassign, leave a "no work" comment with Claude's tail output |

Filing issues is not Tick's job. Project cron jobs, hand-filed issues, external
bots -- all valid producers. They POST to Forgejo with the `Agent` label and Tick
picks it up.

## Labels

Two labels carry the state machine. `Status/Blocked` is Forgejo's default; only
`Agent` is custom.

| State               | Labels                     | Assignee    | Open?  |
|---------------------|----------------------------|-------------|--------|
| Filed, not approved | -- (or `Kind/*`)            | --           | open   |
| Approved, claimable | `Agent`                    | --           | open   |
| In progress         | `Agent`                    | `$BOT_USER` | open   |
| Blocked             | `Agent` + `Status/Blocked` | --           | open   |
| Done                | (any)                      | (any)       | closed |

`Agent` is a **permission flag** ("agent's domain"), not a state. State is
carried by `Status/Blocked`, the assignee, and open/closed.

Useful queries:

- Claimable: `is:open label:Agent no:assignee -label:Status/Blocked`
- In flight: `is:open label:Agent assignee:<bot user>`
- Stuck: `is:open label:Status/Blocked`

## Pieces

In the repo (versioned policy + harness code):

```
bin/
├── tick.sh                  # the worker (one issue per invocation)
├── agent-block.sh           # Claude calls this when stuck
├── agent-report.sh          # Claude calls this for no-diff outcomes
├── check-sync.sh            # CI lint: AGENTS.md <-> tick.sh contract
├── validate.sh              # validate global env + every project
├── install.sh               # one-time: scaffold config, install units
└── uninstall.sh             # stop, disable, remove units

lib/forgejo.sh               # Forgejo API helpers

systemd/                     # user units (no @ instance)
├── tick.service
└── tick.timer

AGENTS.md                    # universal unattended rules -- appended to Claude's system prompt
agent-settings.json          # bot's permission profile -- passed via --settings
```

On the host (deployment-specific, not in the repo):

```
~/.local/share/tick/                 # the runtime git checkout (this repo)
~/.config/tick/.env                  # secrets, chmod 600
~/.config/tick/projects/<name>.conf  # per-project config (paths, base branch)
~/.local/state/tick/                 # worktrees, flock
~/.config/systemd/user/tick.{service,timer}
```

## Setup

### Auth and secrets

Claude Max via `CLAUDE_CODE_OAUTH_TOKEN`. No per-call API billing -- that's the
whole point. The bot's Forgejo token lives in the same file. Both at
`~/.config/tick/.env`, chmod 600 (seeded from `.env.example` by `install.sh`).

### Bot user

A dedicated Forgejo user (`$BOT_USER`) plus a matching server account. The
Forgejo user needs:

- An API token with issue/PR/comment/label/assign permissions on every repo Tick
  will work.
- An SSH key for git operations.
- Branch protection bypass on each repo's base branch (so the harness can push
  `agent/N` branches and `Closes #N`-linked merges work uniformly).

The server account runs the systemd user units and owns the runtime checkout
at `~/.local/share/tick/`, its config at `~/.config/tick/`, and its state at
`~/.local/state/tick/`. Git authorship on all bot commits and PRs attributes
to this user.

### Install

Clone the repo into the runtime location, then run install.sh:

```sh
git clone <forgejo-url>/tick ~/.local/share/tick
~/.local/share/tick/bin/install.sh
```

`install.sh` scaffolds `~/.config/tick/` (seeds `.env` from `.env.example`),
copies the systemd units, and enables `tick.timer`. Edit `~/.config/tick/.env`
with real tokens before the first tick. Re-running is safe.

```sh
bin/uninstall.sh   # stops, disables, removes units (leaves config + state)
```

Schedule override goes in a drop-in at
`~/.config/systemd/user/tick.timer.d/override.conf`.

### Operating

- Schedule: `systemctl --user list-timers tick.timer`
- Logs: `journalctl --user -u tick.service -f`
- Force a tick now: `systemctl --user start tick.service`

### Adding a project

Drop a file at `~/.config/tick/projects/<name>.conf`. The next tick will see
it. Removing a project: delete the conf. No systemd reload needed.

```sh
# Required
REPO_PATH=/home/agent/Code/joshing.you
FORGEJO_REPO=joshtronic/joshing.you

# Optional
PR_BASE=master       # default: master
TICK_TIMEOUT=60m     # default: 60m -- per-project override if needed
BOT_USER=agent       # default: agent
```

## Scope and trade-offs

Tick handles only `Agent`-labeled issue -> outcome work. It does **not** handle:

- **Filing issues.** Producers do that -- cron jobs, external bots, you typing
  at a keyboard. Tick is a consumer.
- **Report-only jobs** (SEO sweeps, weekly summaries) that don't fit issue ->
  PR/report. Run those as plain cron. They may file Tick issues as a side
  effect.
- **Interactive Claude.** Use Claude Code normally in repos; Tick is the
  unattended layer.
- **Pipelines, ETL, long-running daemons.** Not Tick's shape.

Known trade-offs:

- **Cost gating depends on producers being conservative.** Noisy producers file
  spurious issues that Tick will work and burn tokens on. Keep producers tight.
- **Sessions are stateless.** Each tick is a fresh Claude invocation. Durable
  state lives in the repo, the issue, and `state/`.
- **One host per Tick install.** Two hosts watching the same Forgejo will race
  on issue claim.
- **Oldest claimable wins.** No priority labels. Urgency = file the urgent issue
  first.
- **Recovery, not resume.** An interrupted tick re-queues its issue; the next
  tick starts fresh.

## Status

Pre-flight. Lint green. No real Tick has swung yet.
