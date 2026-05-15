# Tick — Specification

A harness for unattended Claude Code instances that work tickets from
Forgejo and produce PRs. One global worker that rotates through known
projects, one bot identity across all of them (`igor`). Auth via
Claude Max subscription (`CLAUDE_CODE_OAUTH_TOKEN`), not API key
billing.

This document is the authoritative description of how Tick behaves.
The `tick/` repo holds the harness scaffolding; project repos hold
their own context. Nothing in a project repo names "tick" — projects
are unaware of the harness.

---

## Model

A single global consumer. `bin/tick.sh` runs on a timer. Each
invocation:

1. Acquires a global flock — only one tick at a time, across all
   projects.
2. Performs a **recovery sweep** for orphaned `igor` assignments left
   over from an interrupted previous run.
3. Performs **discovery** across every project's Forgejo repo, picks
   the globally oldest claimable `Agent`-labeled issue, and works it
   to completion.

**Every Claude invocation is bound to exactly one issue.** No issue,
no invocation. This is the cost gate and the audit trail.

Filing issues is **out of scope.** Producers (project scripts, hand-
filed issues, external bots) POST to Forgejo with the `Agent` label
by whatever means they like. Tick doesn't wrap or coordinate them —
it just consumes.

If no project has claimable work, the tick does nothing. That is
correct — there is no work.

---

## Labels

Two labels carry the state machine. Forgejo's `Status/Blocked` default
is reused; only `Agent` is custom.

| State | Labels | Assignee | Open? |
|---|---|---|---|
| Filed, not approved | — (or `Kind/*`) | — | open |
| Approved, claimable | `Agent` | — | open |
| In progress | `Agent` | `igor` | open |
| Blocked | `Agent` + `Status/Blocked` | — | open |
| Done | (any) | (any) | closed |

The `Agent` label persists for the issue's entire lifecycle. It is a
**permission flag** ("agent's domain"), not a state. State is carried
by `Status/Blocked`, the assignee, and open/closed.

### Useful queries

- Claimable: `is:open label:Agent no:assignee -label:Status/Blocked`
- In flight: `is:open label:Agent assignee:igor`
- Stuck: `is:open label:Status/Blocked`

### Project-specific labels

Projects may add their own namespaces (e.g., `Persona/Punk` for
scenekids). Tick does not read them. Their semantics live in
whatever filed the issue and in the issue body itself.

---

## Layout

### Tick repo

```
tick/
├── AGENTS.md              # universal unattended rules
├── SPEC.md                # this document
├── README.md
├── bin/
│   ├── tick.sh            # the consumer
│   ├── agent-block.sh     # blocker helper, called by Claude
│   ├── agent-report.sh    # report helper, called by Claude
│   ├── check-sync.sh      # AGENTS.md ↔ tick.sh contract lint
│   ├── validate.sh        # global + every project
│   ├── install.sh
│   └── uninstall.sh
├── lib/
│   └── forgejo.sh         # API helpers
├── projects/
│   └── <name>.conf        # one per project
└── systemd/
    ├── tick.service
    └── tick.timer
```

### Per-project

```
<project>/
├── CLAUDE.md                       # project context, both modes
├── .claude/
│   ├── settings.json               # narrow bot allow-list (committed)
│   └── settings.local.json         # interactive overrides (gitignored)
└── (reference content as needed)   # personas/, templates/, etc.
```

---

## File responsibilities

### `tick/AGENTS.md`

The universal unattended rules. Loaded **only** by `tick.sh` via
`--append-system-prompt`. Interactive Claude never sees it.

Contains:
- The "you are running unattended" preamble.
- Override clause for interactive-only rules in project `CLAUDE.md`
  (e.g., "do not commit unless asked" — overridden for the bot).
- Issue claim protocol.
- Blocker protocol — when and how to call `agent-block.sh`.
- PR conventions — size, `Closes #N`, base from `PR_BASE`.
- The universal "no commits to the base branch without a PR" rule.

### `<project>/CLAUDE.md`

Project context. Auto-loaded by Claude Code in both interactive and
unattended modes (no change from current usage). Architecture,
commands, conventions, interactive rules. Interactive-only rules
remain intact; they are overridden at bot runtime by `tick/AGENTS.md`.

### `tick/agent-settings.json`

The bot's dev-centric permission profile, applied to every project
via `--settings`. Broad allow list (common dev tooling) plus a
targeted deny list (`git push`, `sudo`, `rm -rf /`, `curl | bash`,
etc.). The harness owns push and remote ops; the bot does the work.

### `<project>/.claude/settings.json`

Optional. Project-specific tweaks layered on top of
`tick/agent-settings.json` — most projects won't need one. If
present, it adds project-specific allowed/denied tools (e.g. a
project that uses an unusual build tool can allow it here).

### `<project>/.claude/settings.local.json`

Gitignored, interactive use only. Never seen by the bot (the bot's
profile is `tick/agent-settings.json`, not the project's local file).

---

## Issue lifecycle

1. **Filed.** Some producer (a project's cron, a human, an external
   bot) creates a Forgejo issue and applies the `Agent` label when
   it's bot-ready.
2. **Recovery sweep.** Before claiming new work, the tick checks
   every known project for issues already assigned to `igor`. Any it
   finds are orphans from a previous interrupted tick: it posts a
   "previous tick interrupted — re-queueing" comment, unassigns, and
   best-effort cleans up the leftover worktree/branch.
3. **Claimed.** The tick queries every project for the oldest open
   issue matching `label:Agent no:assignee -label:Status/Blocked`,
   picks the globally oldest, assigns it to `igor`, and creates a
   worktree.
4. **Worked.** Claude runs in the worktree. Inputs: project's
   `CLAUDE.md` (auto-loaded), `tick/AGENTS.md` (appended), issue body
   (user message).
5. **Outcome.** One of three:
   - **PR.** Branch pushed, PR opened with `Closes #N`. Issue closes
     when the PR merges.
   - **Report.** For analysis tasks producing no diff. Claude comments
     findings on the issue and closes it.
   - **Blocked.** Claude calls `agent-block.sh`, which posts a comment
     describing what went wrong, applies `Status/Blocked`, and
     unassigns. The issue stays open.
6. **Human resolution (blocked only).** You read the comment, fix
   whatever needs fixing, remove `Status/Blocked`. The next tick
   reclaims (because `Agent` was never removed).

In all outcomes, the worktree is removed.

---

## `tick.sh` contract

Per invocation:

1. Acquire a global flock at `$TICK_STATE_DIR/lock`. If another tick
   holds it, exit 0.
2. Recovery sweep: for each project in `projects/*.conf`, query
   Forgejo for open issues assigned to `$BOT_USER`. For each, comment
   "previous tick interrupted — re-queueing," unassign, and clean up
   the matching worktree/branch if they exist.
3. Discovery: for each project, query for the oldest claimable issue.
   Pick the globally oldest across all projects. If none, exit 0.
4. Assign the issue to `$BOT_USER`.
5. Create a worktree at `$TICK_STATE_DIR/worktrees/<project>-<issue>`,
   branched from `origin/$PR_BASE` as `agent/<issue>`.
6. Invoke Claude with:
   - `cwd` = worktree path
   - `--append-system-prompt "$(cat $TICK_HOME/AGENTS.md)"`
   - `--settings "$TICK_HOME/agent-settings.json"` (bot's dev-centric
     permission profile; project's `.claude/settings.json` layers on
     top automatically)
   - `--max-turns 50` (safety net against runaway tool-use loops; the
     wall-clock `TICK_TIMEOUT` is the coarser backstop)
   - `--print "$ISSUE_BODY"`
7. On Claude exit, inspect worktree state:
   - Commits on a branch ahead of `PR_BASE` → push branch, open PR
     with `Closes #<issue>` in description. PR body is taken from
     `.git/PR_BODY.md` if the agent wrote one (preferred for
     multi-commit work); otherwise constructed from `git log`.
   - Issue closed by the agent → report delivered, no further action.
   - `Status/Blocked` applied by the agent → blocker registered, no
     further action.
   - None of the above → unassign, post a generic "produced no work"
     comment. Should be rare; investigate.
8. Remove the worktree.
9. Exit 0.

One issue per tick. Concurrency comes from frequency, not parallelism.

The CLI accepts an optional project name as a debug-scope arg:

```sh
bin/tick.sh           # scan all projects, pick globally oldest
bin/tick.sh joshing   # scope to one project (manual / debug)
```

---

## Bot identity

A single Forgejo + server user named `igor`:

- Forgejo API token and SSH key, with branch protection bypass on
  the base branch (necessary for the bot to push branches and have
  `Closes #N`-linked merges work uniformly).
- Server user account, runs the systemd user units, owns
  `$TICK_HOME/.env` (chmod 600).
- Git authorship on all bot commits and PRs.

systemd journal is tagged `tick.service`; git and Forgejo audit
trails attribute to `igor`.

---

## Secrets

`$TICK_HOME/.env` (chmod 600), gitignored. Contains the harness-wide
credentials:

```
CLAUDE_CODE_OAUTH_TOKEN=...
FORGEJO_URL=https://git.sherver.org
FORGEJO_TOKEN=...
```

Auto-exported by `tick.sh` via `set -a; . .env; set +a`. The systemd
unit loads the same file via `EnvironmentFile=` if you want it there
too (not required — `tick.sh` sources it itself).

Project-specific secrets stay in the project's own `.env`, sourced by
whatever project script needs them. Tick itself does not.

`.gitignore` at `$TICK_HOME` blocks `.env`, `state/`, `*.log`.

---

## Persistence

One systemd user unit: `tick.timer` fires `tick.service` on a
schedule (10min default). The timer uses `OnUnitInactiveSec` so
ticks measured from previous completion never overlap; the global
flock catches anything the scheduler doesn't.

Observability:
- `systemctl --user list-timers` — schedule.
- `journalctl --user -u tick.service` — all activity.
- Forgejo issue queue — current state of work.

cron alternative: a single line like
`*/10 * * * * $HOME/Code/tick/bin/tick.sh` works the same. The flock
makes overlap safe.

---

## Per-project conf schema

`projects/<name>.conf` is shell-sourced.

```sh
# Required
REPO_PATH=/home/josh/Code/joshing.you
FORGEJO_REPO=joshtronic/joshing.you

# Optional
PR_BASE=master       # default: master
TICK_TIMEOUT=60m     # default: 60m — per-project override if needed
BOT_USER=igor        # default: igor
```

Adding a new project = drop a conf file. No code changes, no systemd
reload.

---

## Validation: `validate.sh`

Validates global env, then every project in `projects/`. Exits
non-zero on any failure so the script is usable as a deploy gate or
pre-tick sanity check.

Global checks:
- `FORGEJO_URL`, `FORGEJO_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN` set.
- `agent-settings.json` present.
- State dir writable.

Per-project checks:
- `projects/<name>.conf` parses and has `REPO_PATH` + `FORGEJO_REPO`.
- `REPO_PATH` is a git repo.
- `<project>/.claude/settings.json` present.
- Forgejo repo reachable with the bot token.
- Required labels (`Agent`, `Status/Blocked`) exist on the repo.
- Bot user exists on Forgejo.

---

## Out of scope

Tick handles only `Agent`-labeled issue → outcome work. It explicitly
does **not** handle:

- **Filing issues.** Producers do that on their own — cron jobs,
  external bots, you typing at a keyboard. Tick is a consumer.
- **Report-only jobs** (SEO sweeps, weekly summaries, cross-site
  analyses) that don't fit the issue → PR/report shape. Run those as
  plain cron. They may file Tick issues as a side effect, but they
  themselves are not Tick projects.
- **Interactive Claude.** You use Claude Code in repos normally;
  Tick is the unattended layer.
- **Cross-project coordination.** Each project's issue queue is
  independent. The tick rotates through them; it does not link them.
- **Pipelines, ETL, long-running daemons.** Not Tick's shape.

---

## Trade-offs accepted

- **Cost gating depends on producers being conservative.** A noisy
  producer will file spurious issues that Tick will work and burn
  tokens on. Producers are the project's responsibility, not Tick's.
- **Sessions are stateless.** Each tick is a fresh Claude
  invocation. No in-session memory between ticks. Durable state
  lives in the repo, the issue, and `state/`.
- **One host per Tick install.** Two hosts running ticks against the
  same Forgejo will race on issue claim. Run Tick on one host.
- **No priority labels.** Globally oldest claimable wins. Urgency is
  expressed by ordering — file the urgent issue first, or close
  older ones.
- **Single bot identity.** All projects share `igor`. Cleaner logs
  and one secret to manage; less audit granularity than per-project
  bots would give.
- **Recovery, not resume.** An interrupted tick re-queues its
  issue, losing the in-flight work. The next tick starts fresh. If
  this becomes painful, resume can be built later.
