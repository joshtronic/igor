# Tick

> SPOOOON!

A harness for unattended Claude Code work. One global tick fires on a
timer, scans every known project's Forgejo issue queue for `Agent`-
labeled work, claims the oldest one, spins up a worktree, lets Claude
grind on it, and ships a PR. Or posts a report. Or flags
`Status/Blocked` and waits for you to look at it.

The bot that does the actual labor is **`igor`** — a separate Forgejo
user with its own SSH key, API token, and server account. Tick fires;
igor pulls the lever.

## How it works

A timer fires `bin/tick.sh`. Per tick:

1. Acquire a global flock — only one tick at a time, period.
2. **Recovery sweep** — any open issue assigned to `igor` from a
   previous interrupted run gets a "previous tick was interrupted —
   re-queueing" comment and is unassigned.
3. **Discovery** — query every configured project's Forgejo repo for
   the oldest claimable issue (`Agent`-labeled, no assignee, not
   `Status/Blocked`). Pick the globally oldest across all projects.
4. **Work it** — assign to `igor`, make a worktree, invoke Claude
   with the project's `CLAUDE.md` plus the universal `AGENTS.md`,
   react to whatever Claude leaves behind.

| What Claude did | What Tick does |
|---|---|
| Made commits | Push branch, open PR with `Closes #N` |
| Closed the issue with a comment | Treat as a report — log and clean up |
| Applied `Status/Blocked` | Log, clean up, wait for the human |
| Nothing | Unassign, leave a "no work" comment |

Filing issues is not Tick's job. A project's own cron jobs, hand-filed
issues, or external bots are all valid producers — they POST to
Forgejo with the `Agent` label and Tick picks it up.

For the full contract: [`SPEC.md`](./SPEC.md).

## Pieces

```
bin/
├── tick.sh                  # the consumer (one issue per invocation)
├── agent-block.sh           # Claude calls this when stuck
├── agent-report.sh          # Claude calls this for no-diff outcomes
├── check-sync.sh            # CI lint: AGENTS.md ↔ tick.sh contract
├── validate-project.sh      # check a project's setup
└── install.sh               # one-time: copy units, enable timer

lib/forgejo.sh               # Forgejo API helpers

systemd/                     # global user units (no @ instance)
├── tick.service
└── tick.timer

AGENTS.md                    # universal unattended rules — appended to Claude's system prompt
projects/<name>.conf         # per-project config (paths, base branch)
```

## Auth

Claude Max via `CLAUDE_CODE_OAUTH_TOKEN`. No per-call API billing —
that's the whole point. The bot's Forgejo token in the same file.
Both live at `$TICK_HOME/.env`, chmod 600, gitignored.

## Install

One time on the host:

```sh
bin/install.sh    # copies units, enables tick.timer
```

Adding a project: drop `projects/<name>.conf`. The next tick will see
it. Removing a project: delete the conf. No systemd reload needed.

Schedule override goes in a drop-in at
`~/.config/systemd/user/tick.timer.d/override.conf`.

cron works fine too if you'd rather skip systemd — see [`SPEC.md`](./SPEC.md).

## Status

Pre-flight. Lint green; no real tick has flown yet.
