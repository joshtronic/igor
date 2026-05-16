# Architecture

## How Igor works

A timer fires `bin/tick.sh`. Per tick:

1. **Lock.** Global flock -- only one Igor at a time. No two-puppet show.
2. **Identity.** Resolve the bot's Forgejo login from the token via
   `/api/v1/user`. No `BOT_USER` config; the token is the identity.
3. **Recovery sweep.** Any open issue still assigned to the bot from a
   previous interrupted run gets a "previous tick was interrupted --
   re-queueing" comment and is unassigned. Nothing slips through a midnight
   crash.
4. **Discovery.** List every repo the bot has push access to (one API call).
   For each:
   - If we haven't cloned it yet, run onboarding validation via the Forgejo
     API. Repos that fail get an auto-filed `Status/Needs More Info` ticket
     listing what's missing (or a reopen on the existing one), and are
     excluded from discovery until the human closes the ticket.
   - If there's an open Igor-authored PR, skip -- one PR at a time per repo
     so the human can review without a backlog forming behind them.
   - Otherwise, query for the oldest claimable issue (`Agent`-labeled, no
     assignee, not `Status/Blocked`).

   Pick the globally oldest across all eligible repos.
5. **Claim and clone.** Assign the issue to the bot. If the repo isn't cloned
   locally yet, clone it to `~/Code/<repo>` via SSH.
6. **Preflight.** Verify `CLAUDE.md` exists at the repo root. If not, block
   the issue with a clear comment and bail. (Same code path as Claude calling
   `agent-block.sh` from inside the worktree.)
7. **Work.** Make a worktree, invoke Claude with the project's `CLAUDE.md`
   plus the universal `AGENTS.md`, react to whatever Claude leaves behind.

| What Claude did                 | What Igor does                                                |
|---------------------------------|---------------------------------------------------------------|
| Made commits                    | Push branch, open PR with `Closes #N` + deps audit            |
| Closed the issue with a comment | Treat as a report -- log and clean up                         |
| Applied `Status/Blocked`        | Log, clean up, wait for the human                             |
| Nothing                         | Unassign, leave a "no work" comment with Claude's tail output |

Filing issues is not Igor's job. Project cron jobs, hand-filed issues,
external bots -- all valid producers. They POST to Forgejo with the `Agent`
label and Igor picks it up.

## Labels

Two labels carry the state machine for agent-work tickets. `Status/Blocked`
comes from Forgejo's Advanced label template; `Agent` is custom (created
per-repo). Onboarding-failure tickets also use `Status/Needs More Info` and
`Priority/High`, both from the Advanced template. See
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

Igor also files `Status/Needs More Info` + `Priority/High` tickets for repos
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
|-- tick.service
`-- tick.timer

AGENTS.md                    # universal unattended rules -- appended to Claude's system prompt
agent-settings.json          # bot's permission profile -- passed via --settings
```

On the host (deployment-specific, not in the repo):

```
~/.local/share/igor/                 # the runtime git checkout (this repo)
~/.local/share/igor/.env             # secrets, chmod 600 -- the only config
~/.local/state/igor/                 # worktrees, flock
~/Code/<owner>/<repo>/               # per-repo clones, nested by owner
~/Code/<bot>/brain/                  # Igor's brain -- always present, bootstrap-required
~/Code/<bot>/website/                # Igor's website -- present if exists
~/.config/systemd/user/tick.{service,timer}   # symlinks into the clone
```

`<owner>/<repo>` nesting mirrors Forgejo's URL structure and isolates
the harness's per-repo clones from any interactive clones you keep at
`~/Code/<repo>/`.

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
- **Scope cap.** A branch over 10 commits or 400 changed lines gets blocked
  instead of shipped, with a comment listing the touched files. Split the
  ticket and re-queue.
- **One PR per repo.** While an Igor PR is open in a repo, the rest of that
  repo's claimable issues wait. Intentional throttle; merge or close to
  resume.
- **Metered cost per tick.** Igor runs against the Anthropic API (not the
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
- **Supply-chain alerting, not prevention.** Every PR Igor opens gets a
  harness-generated `## Dependencies changed` section listing manifest /
  lockfile diffs with line counts -- so a `npm install evil-package` is
  impossible to miss in review. The harness writes that section, not
  Claude, so the thing under review can't omit it. Igor does **not**
  sandbox installs or scan package contents -- a malicious package could
  still run install scripts during the work. The defense is human PR
  review armed with the audit.
