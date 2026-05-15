# Tick

> "SPOOOON!"

Unattended Claude Code in a big blue moth costume. One global Tick
fires on a timer, sweeps every project's Forgejo issue queue for
`Agent`-labeled work, claims the oldest one, spins up a worktree,
lets Claude do the heroics, and ships a PR. Or posts a report. Or
flags `Status/Blocked` and waits for the city to look at it.

The work runs under a dedicated Forgejo user (`$BOT_USER`, default
`agent`) with its own SSH key, API token, and server account. Tick
fires; the bot does the swinging.

## How Tick works

A timer fires `bin/tick.sh`. Per tick:

1. **Lock.** Global flock — only one Tick at a time. Justice cannot
   be in two places at once.
2. **Recovery sweep.** Any open issue still assigned to the bot from
   a previous interrupted run gets a "previous tick was interrupted —
   re-queueing" comment and is unassigned. No villain escapes by
   tripping the harness mid-fight.
3. **Discovery.** Query every configured project's Forgejo repo for
   the oldest claimable issue (`Agent`-labeled, no assignee, not
   `Status/Blocked`). Pick the globally oldest.
4. **Justice.** Assign to the bot, make a worktree, invoke Claude with
   the project's `CLAUDE.md` plus the universal `AGENTS.md`, react to
   whatever Claude leaves behind.

| What Claude did | What Tick does |
|---|---|
| Made commits | Push branch, open PR with `Closes #N` |
| Closed the issue with a comment | Treat as a report — log and clean up |
| Applied `Status/Blocked` | Log, clean up, wait for the human |
| Nothing | Unassign, leave a "no work" comment with Claude's tail output |

Filing issues is not Tick's job. Project cron jobs, hand-filed
issues, external bots — all valid producers. They POST to Forgejo
with the `Agent` label and Tick picks it up.

## Labels

Two labels carry the state machine. `Status/Blocked` is Forgejo's
default; only `Agent` is custom.

| State | Labels | Assignee | Open? |
|---|---|---|---|
| Filed, not approved | — (or `Kind/*`) | — | open |
| Approved, claimable | `Agent` | — | open |
| In progress | `Agent` | `$BOT_USER` | open |
| Blocked | `Agent` + `Status/Blocked` | — | open |
| Done | (any) | (any) | closed |

`Agent` is a **permission flag** ("agent's domain"), not a state.
State is carried by `Status/Blocked`, the assignee, and open/closed.

Useful queries:

- Claimable: `is:open label:Agent no:assignee -label:Status/Blocked`
- In flight: `is:open label:Agent assignee:<bot user>`
- Stuck: `is:open label:Status/Blocked`

## Pieces

```
bin/
├── tick.sh                  # the worker (one issue per invocation)
├── agent-block.sh           # Claude calls this when stuck
├── agent-report.sh          # Claude calls this for no-diff outcomes
├── check-sync.sh            # CI lint: AGENTS.md ↔ tick.sh contract
├── validate.sh              # validate global env + every project
├── install.sh               # one-time: copy units, enable timer
└── uninstall.sh             # stop, disable, remove units

lib/forgejo.sh               # Forgejo API helpers

systemd/                     # global user units (no @ instance)
├── tick.service
└── tick.timer

AGENTS.md                    # universal unattended rules — appended to Claude's system prompt
agent-settings.json          # bot's permission profile — passed via --settings
projects/<name>.conf         # per-project config (paths, base branch)
```

## Setup

### Auth and secrets

Claude Max via `CLAUDE_CODE_OAUTH_TOKEN`. No per-call API billing —
that's the whole point. The bot's Forgejo token lives in the same
file. Both at `$TICK_HOME/.env`, chmod 600, gitignored.

### Bot user

A dedicated Forgejo user (`$BOT_USER`) plus a matching server
account. The Forgejo user needs:

- An API token with issue/PR/comment/label/assign permissions on
  every repo Tick will work.
- An SSH key for git operations.
- Branch protection bypass on each repo's base branch (so the
  harness can push `agent/N` branches and `Closes #N`-linked merges
  work uniformly).

The server account runs the systemd user units and owns
`$TICK_HOME/.env`. Git authorship on all bot commits and PRs
attributes to this user.

### Install

```sh
bin/install.sh     # copies units, enables tick.timer
bin/uninstall.sh   # stops, disables, removes
```

Schedule override goes in a drop-in at
`~/.config/systemd/user/tick.timer.d/override.conf`.

cron works too: `*/10 * * * * $HOME/Code/tick/bin/tick.sh`. The
global flock keeps overlapping runs safe either way.

### Adding a project

Drop a file at `projects/<name>.conf`. The next tick will see it.
Removing a project: delete the conf. No systemd reload needed.

```sh
# Required
REPO_PATH=/home/josh/Code/joshing.you
FORGEJO_REPO=joshtronic/joshing.you

# Optional
PR_BASE=master       # default: master
TICK_TIMEOUT=60m     # default: 60m — per-project override if needed
BOT_USER=agent       # default: agent
```

## Scope and trade-offs

Tick handles only `Agent`-labeled issue → outcome work. It does
**not** handle:

- **Filing issues.** Producers do that — cron jobs, external bots,
  you typing at a keyboard. Tick is a consumer.
- **Report-only jobs** (SEO sweeps, weekly summaries) that don't fit
  issue → PR/report. Run those as plain cron. They may file Tick
  issues as a side effect.
- **Interactive Claude.** Use Claude Code normally in repos; Tick is
  the unattended layer.
- **Pipelines, ETL, long-running daemons.** Not Tick's shape.

Known trade-offs:

- **Cost gating depends on producers being conservative.** Noisy
  producers file spurious issues that Tick will work and burn tokens
  on. Keep producers tight.
- **Sessions are stateless.** Each tick is a fresh Claude invocation.
  Durable state lives in the repo, the issue, and `state/`.
- **One host per Tick install.** Two hosts watching the same Forgejo
  will race on issue claim.
- **Oldest claimable wins.** No priority labels. Urgency = file the
  urgent issue first.
- **Recovery, not resume.** An interrupted tick re-queues its issue;
  the next tick starts fresh.

## Status

Pre-flight. Lint green. No real Tick has swung yet.
