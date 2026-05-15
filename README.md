# Igor

> "RIDING AROUND TOWN, THEY GON' FEEL THIS ONE"

Unattended Claude Code in a pastel blue suit. One global tick fires on a
timer, Igor sweeps every repo the bot can push to for `Agent`-labeled work,
claims the oldest one, spins up a worktree, lets Claude do the work, and
ships a PR. Or posts a report. Or flags `Status/Blocked` and waits.

The work runs under a dedicated Forgejo user with its own SSH key and API
token. The token *is* the identity -- the bot's username is resolved from
`/api/v1/user` on each tick, so there's nothing to configure or get out of
sync. The tick fires; Igor does the work.

## How Igor works

A timer fires `bin/tick.sh`. Per tick:

1. **Lock.** Global flock -- only one Igor at a time. No two-puppet show.
2. **Identity.** Resolve the bot's Forgejo login from the token via
   `/api/v1/user`. No `BOT_USER` config; the token is the identity.
3. **Recovery sweep.** Any open issue still assigned to the bot from a
   previous interrupted run gets a "previous tick was interrupted --
   re-queueing" comment and is unassigned. Nothing slips through a midnight
   crash.
4. **Discovery.** List every repo the bot has push access to (one API call),
   then query each for the oldest claimable issue (`Agent`-labeled, no
   assignee, not `Status/Blocked`). Pick the globally oldest.
5. **Claim and clone.** Assign the issue to the bot. If the repo isn't cloned
   locally yet, clone it to `~/Code/<repo>` via SSH.
6. **Preflight.** Verify `CLAUDE.md` exists at the repo root. If not, block
   the issue with a clear comment and bail. (Same code path as Claude calling
   `agent-block.sh` from inside the worktree.)
7. **Work.** Make a worktree, invoke Claude with the project's `CLAUDE.md`
   plus the universal `AGENTS.md`, react to whatever Claude leaves behind.

| What Claude did                 | What Igor does                                                |
|---------------------------------|---------------------------------------------------------------|
| Made commits                    | Push branch, open PR with `Closes #N`                         |
| Closed the issue with a comment | Treat as a report -- log and clean up                          |
| Applied `Status/Blocked`        | Log, clean up, wait for the human                             |
| Nothing                         | Unassign, leave a "no work" comment with Claude's tail output |

Filing issues is not Igor's job. Project cron jobs, hand-filed issues,
external bots -- all valid producers. They POST to Forgejo with the `Agent`
label and Igor picks it up.

## Labels

Two labels carry the state machine. `Status/Blocked` is Forgejo's default;
only `Agent` is custom.

| State               | Labels                     | Assignee  | Open?  |
|---------------------|----------------------------|-----------|--------|
| Filed, not approved | -- (or `Kind/*`)            | --         | open   |
| Approved, claimable | `Agent`                    | --         | open   |
| In progress         | `Agent`                    | `<bot>`   | open   |
| Blocked             | `Agent` + `Status/Blocked` | --         | open   |
| Done                | (any)                      | (any)     | closed |

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
├── validate.sh              # validate env + Forgejo connectivity + bot perms
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
~/.local/share/igor/                 # the runtime git checkout (this repo)
~/.config/igor/.env                  # secrets, chmod 600 -- the only config
~/.local/state/igor/                 # worktrees, flock
~/Code/<repo>/                       # per-repo clones (created on demand)
~/.config/systemd/user/tick.{service,timer}
```

## Setup

### Auth and secrets

Claude Max via `CLAUDE_CODE_OAUTH_TOKEN`. No per-call API billing -- that's
the whole point. The bot's Forgejo token lives in the same file. Both at
`~/.config/igor/.env`, chmod 600 (seeded from `.env.example` by `install.sh`).

### Bot user

A dedicated Forgejo user plus a matching server account (one Unix user runs
the systemd units and owns the SSH key). The Forgejo user needs:

- An API token with scopes for `read:user`, `repository` (issue/PR/comment/
  label/assign), and push access on every target repo. The bot's username is
  read from this token via `/api/v1/user`, so there's no separate `BOT_USER`
  setting.
- An SSH key for git operations (clone and push). Igor clones via
  `git@<host>:<owner>/<repo>.git`, where `<host>` is derived from
  `FORGEJO_URL` (override with `FORGEJO_SSH_HOST` if SSH is on a different
  endpoint).
- Branch protection bypass on each repo's default branch, so the harness can
  push `agent/N-<slug>` branches and `Closes #N`-linked merges work uniformly.

The server account owns the runtime checkout at `~/.local/share/igor/`, its
config at `~/.config/igor/`, its state at `~/.local/state/igor/`, and the
per-repo clones at `~/Code/<repo>/`. Git authorship on all bot commits and PRs
attributes to this user.

### Install

Clone the repo into the runtime location, then run install.sh:

```sh
git clone <forgejo-url>/igor ~/.local/share/igor
~/.local/share/igor/bin/install.sh
```

`install.sh` scaffolds `~/.config/igor/` (seeds `.env` from `.env.example`),
copies the systemd units, and enables `tick.timer`. Edit `~/.config/igor/.env`
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

### Granting Igor a repo

There is no per-project config. To put a repo under Igor's care, do three
things in Forgejo (once per repo):

1. Add the bot user as a collaborator with **write** permission.
2. Ensure the `Agent` and `Status/Blocked` labels exist on the repo (Igor
   reads them by name).
3. Put a `CLAUDE.md` at the repo root with project conventions (test
   commands, code style, gotchas, anything Claude needs to be useful here).
   Igor refuses to invoke Claude without one and posts a blocker comment
   explaining why.

That's it. The next tick discovers the repo via the bot's token, clones it
to `~/Code/<repo>` if it's missing locally, and starts working any
`Agent`-labeled issues.

To stop Igor from working a repo: revoke the bot's collaborator role, or stop
applying the `Agent` label. The local clone at `~/Code/<repo>` is yours to
keep or `rm -rf` as you see fit.

## Scope and trade-offs

Igor handles only `Agent`-labeled issue -> outcome work. It does **not**
handle:

- **Filing issues.** Producers do that -- cron jobs, external bots, you
  typing at a keyboard. Igor is a consumer.
- **Report-only jobs** (SEO sweeps, weekly summaries) that don't fit issue
  -> PR/report. Run those as plain cron. They may file Igor issues as a side
  effect.
- **Interactive Claude.** Use Claude Code normally in repos; Igor is the
  unattended layer.
- **Pipelines, ETL, long-running daemons.** Not Igor's shape.

Known trade-offs:

- **Cost gating depends on producers being conservative.** Noisy producers
  file spurious issues that Igor will work and burn tokens on. Keep producers
  tight.
- **Sessions are stateless.** Each tick is a fresh Claude invocation. Durable
  state lives in the repo, the issue, and `state/`.
- **One host per Igor install.** Two hosts watching the same Forgejo will
  race on issue claim.
- **Oldest claimable wins.** No priority labels. Urgency = file the urgent
  issue first.
- **Recovery, not resume.** An interrupted tick re-queues its issue; the next
  tick starts fresh.

## Status

Pre-flight. Lint green. Igor hasn't punched in yet.
