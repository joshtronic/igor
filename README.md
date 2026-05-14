# The Fuckin' Foreman

Bossing bitches around to get that shit done.

The Foreman is a coordinator for unattended Claude Code work. You
(or a scheduled script) file a Forgejo issue tagged `Agent`. The
Foreman claims it, spins up a worktree, lets Claude grind on it,
and ships a PR. Or posts a report. Or flags `Status/Blocked` and
waits for you to look at it.

The bot that does the actual labor is **`igor`** — separate Forgejo
user, separate SSH key, separate everything. The Foreman gives the
orders; igor pulls the lever. Hence the name.

## How it works

A producer files an issue. A consumer (`bin/tick.sh`) claims one
issue per tick, makes a worktree, invokes Claude with the project's
context plus the universal unattended rules, and reacts to whatever
Claude leaves behind:

| What Claude did | What the Foreman does |
|---|---|
| Made commits | Push branch, open PR with `Closes #N` |
| Closed the issue with a comment | Treat as a report — log and clean up |
| Applied `Status/Blocked` | Log, clean up, wait for the human |
| Nothing | Unassign, leave a "no work" comment |

`bin/tick.sh` is invoked by a systemd timer per project. An optional
`scripts/enqueue.sh` in each project repo generates issues on its
own schedule — that's the part that knows what work exists. The
Foreman itself is project-agnostic.

For the full contract: [`SPEC.md`](./SPEC.md).

## Pieces

```
bin/
├── tick.sh                  # the consumer (one issue per invocation)
├── enqueue.sh               # wrapper that runs a project's enqueue script
├── agent-block.sh           # Claude calls this when stuck
├── agent-report.sh          # Claude calls this for no-diff outcomes
├── check-sync.sh            # CI lint: AGENTS.md ↔ tick.sh contract
└── validate-project.sh      # check a project's setup

lib/forgejo.sh               # Forgejo API helpers

systemd/                     # user-unit templates (instance = project name)
├── foreman-tick@.{service,timer}
└── foreman-enqueue@.{service,timer}

AGENTS.md                    # universal unattended rules — appended to Claude's system prompt
projects/<name>.conf         # per-project config (paths, intervals, base branch)
```

## Auth

Claude Max via `CLAUDE_CODE_OAUTH_TOKEN`. No per-call API billing —
that's the whole point. The bot's Forgejo token in the same file.
Both live at `$FOREMAN_HOME/.env`, chmod 600, gitignored.

## Install

User systemd units, one host per project:

```sh
cp systemd/*.service systemd/*.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now foreman-tick@<project>.timer
systemctl --user enable --now foreman-enqueue@<project>.timer   # if the project has a producer
```

Per-project schedule overrides go in drop-ins at
`~/.config/systemd/user/foreman-tick@<project>.timer.d/override.conf`.

## Status

Pre-flight. Lint green; no real tick has flown yet.
