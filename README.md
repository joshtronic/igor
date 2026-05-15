# Tick

> "SPOOOON!"

Unattended Claude Code in a big blue moth costume. One global Tick
fires on a timer, sweeps every project's Forgejo issue queue for
`Agent`-labeled work, claims the oldest one, spins up a worktree,
lets Claude do the heroics, and ships a PR. Or posts a report. Or
flags `Status/Blocked` and waits for the city to look at it.

The sidekick is **`igor`** — a separate Forgejo user with its own
SSH key, API token, and server account. Tick gives the orders; igor
swings the spoon.

## How Tick works

A timer fires `bin/tick.sh`. Per tick:

1. **Lock.** Global flock — only one Tick at a time. Justice cannot
   be in two places at once.
2. **Recovery sweep.** Any open issue still assigned to `igor` from a
   previous interrupted run gets a "previous tick was interrupted —
   re-queueing" comment and is unassigned. No villain escapes by
   tripping the harness mid-fight.
3. **Discovery.** Query every configured project's Forgejo repo for
   the oldest claimable issue (`Agent`-labeled, no assignee, not
   `Status/Blocked`). Pick the globally oldest.
4. **Justice.** Assign to `igor`, make a worktree, invoke Claude with
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
with the `Agent` label and Tick picks it up. Tick is a consumer.

For the full contract: [`SPEC.md`](./SPEC.md).

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

## Auth

Claude Max via `CLAUDE_CODE_OAUTH_TOKEN`. No per-call API billing —
that's the whole point. The bot's Forgejo token lives in the same
file. Both at `$TICK_HOME/.env`, chmod 600, gitignored. Not in the
face, not in the repo.

## Install

One time on the host:

```sh
bin/install.sh     # copies units, enables tick.timer
bin/uninstall.sh   # stops, disables, removes
```

Adding a project: drop `projects/<name>.conf`. The next tick will see
it. Removing a project: delete the conf. No systemd reload needed.

Schedule override goes in a drop-in at
`~/.config/systemd/user/tick.timer.d/override.conf`.

cron works fine too if you'd rather skip systemd — see [`SPEC.md`](./SPEC.md).

## Status

Pre-flight. Lint green. No real Tick has swung yet.
