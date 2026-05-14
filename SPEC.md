# Igor — Specification

A harness for unattended Claude Code instances that work tickets from
Forgejo and produce PRs. One robot per project, one bot identity
across all projects (`igor`). Auth via Claude Max subscription
(`CLAUDE_CODE_OAUTH_TOKEN`), not API key billing.

This document is the authoritative description of how Igor behaves.
The `igor/` repo holds the harness scaffolding; project repos hold
their own context and (optionally) a producer script. Nothing in a
project repo names "igor" — projects are unaware of the harness.

---

## Model

Producer / consumer, bound by Forgejo issues.

- **Producers** create Forgejo issues carrying the `Agent` label. A
  project's scheduled `enqueue.sh` is one producer; you filing an
  issue is another.
- **Consumer** is the universal `tick.sh`. Each tick claims one
  `Agent`-labeled issue, makes a worktree, invokes Claude, and
  produces an outcome (PR / report / blocked).
- **Every Claude invocation is bound to exactly one issue.** No
  issue, no invocation. This is the cost gate and the audit trail.

If a project has no producer and no human-filed issues, the bot does
nothing. That is correct — there is no work.

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
scenekids). Igor does not read them. Their semantics live in the
project's `enqueue.sh` and in the issue bodies that producer writes.

---

## Layout

### Igor repo

```
igor/
├── AGENTS.md              # universal unattended rules
├── SPEC.md                # this document
├── README.md
├── bin/
│   ├── tick.sh            # the consumer
│   ├── agent-block.sh     # blocker helper, called by Claude
│   └── whats-good.sh      # validation
├── lib/
│   ├── forgejo.sh         # API helpers
│   └── claude.sh          # invocation wrapper
├── projects/
│   └── <name>.conf        # one per project
└── systemd/
    ├── igor-tick@.service
    ├── igor-tick@.timer
    ├── igor-enqueue@.service
    └── igor-enqueue@.timer
```

### Per-project

```
<project>/
├── CLAUDE.md                       # project context, both modes
├── .claude/
│   ├── settings.json               # narrow bot allow-list (committed)
│   └── settings.local.json         # interactive overrides (gitignored)
├── scripts/
│   └── enqueue.sh                  # optional; only for scheduled producers
└── (reference content as needed)   # personas/, templates/, etc.
```

---

## File responsibilities

### `igor/AGENTS.md`

The universal unattended rules. Loaded **only** by `tick.sh` via
`--append-system-prompt`. Interactive Claude never sees it.

Contains:
- The "you are running unattended" preamble.
- Override clause for interactive-only rules in project `CLAUDE.md`
  (e.g., "do not commit unless asked" — overridden for the bot).
- Issue claim protocol.
- Blocker protocol — when and how to call `agent-block.sh`.
- PR conventions — size, `Closes #N`, base from `PR_BASE`.
- The universal "no commits to `main` without a PR" rule.

### `<project>/CLAUDE.md`

Project context. Auto-loaded by Claude Code in both interactive and
unattended modes (no change from current usage). Architecture,
commands, conventions, interactive rules. Interactive-only rules
remain intact; they are overridden at bot runtime by `igor/AGENTS.md`.

### `<project>/.claude/settings.json`

The bot's narrow Claude Code allow-list. Committed. Claude picks it
up from the project checkout automatically — `tick.sh` does not pass
`--settings`.

### `<project>/.claude/settings.local.json`

Interactive overrides. Gitignored. Broadens perms locally so
interactive work isn't constrained by the bot's profile. The server
checkout never has this file, so the bot is unaffected.

### `<project>/scripts/enqueue.sh`

Optional. Project-specific work detector. Plain shell — no LLM. Runs
on the project's schedule, files a Forgejo issue with `Agent` when
work exists, exits clean when there is none. No issue → no Claude
tick → no cost.

### Reference content

Files the bot consults during work, pointed to by the issue body
(e.g., `personas/punk.md`, `templates/post.md`). Plain project
content; not auto-loaded. The bot reads them because the issue body
told it to. Lives wherever it makes sense within the project repo.

---

## Issue lifecycle

1. **Filed.** A producer creates a Forgejo issue. If the producer is
   `enqueue.sh`, it applies `Agent` immediately. If the producer is
   you, you apply `Agent` when you decide it's bot-ready.
2. **Claimed.** Next `tick.sh` finds the oldest issue matching
   `label:Agent no:assignee -label:Status/Blocked`, assigns it to
   `igor`, and creates a worktree.
3. **Worked.** Claude runs in the worktree. Inputs: project's
   `CLAUDE.md` (auto-loaded), `igor/AGENTS.md` (appended), issue body
   (user message).
4. **Outcome.** One of three:
   - **PR.** Branch pushed, PR opened with `Closes #N`. Issue closes
     when the PR merges.
   - **Report.** For analysis tasks producing no diff. Claude comments
     findings on the issue and closes it.
   - **Blocked.** Claude calls `agent-block.sh`, which posts a comment
     describing what went wrong, applies `Status/Blocked`, and
     unassigns. The issue stays open.
5. **Human resolution (blocked only).** You read the comment, fix
   whatever needs fixing, remove `Status/Blocked`. The bot reclaims
   on the next tick (because `Agent` was never removed).

In all outcomes, the worktree is removed.

---

## `tick.sh` contract

Per invocation, scoped to one project (passed as argument or systemd
instance name):

1. Load `projects/<name>.conf`.
2. Query Forgejo for the oldest claimable issue. If none, exit 0.
3. Assign the issue to `igor` (via Forgejo API).
4. Create a worktree at `<state_dir>/worktrees/<repo>-<issue>`.
5. Invoke Claude with:
   - `cwd` = worktree path
   - `--append-system-prompt "$(cat $IGOR_HOME/AGENTS.md)"`
   - `--print "$ISSUE_BODY"`
   - Settings auto-loaded from `<worktree>/.claude/settings.json`
6. On Claude exit, inspect worktree state:
   - Commits on a branch ahead of `PR_BASE` → push branch, open PR
     with `Closes #<issue>` in description. PR body is taken from
     `.git/PR_BODY.md` if the agent wrote one (preferred for
     multi-commit work); otherwise constructed from `git log`.
   - No commits, blocker was called → cleanup only; the blocker
     helper handled state changes.
   - No commits, no blocker → unassign, post a generic "produced no
     work" comment. Should be rare; investigate.
7. Remove the worktree.
8. Exit 0.

One issue per tick. Concurrency comes from frequency, not parallelism.

---

## `enqueue.sh` contract

Per invocation, scoped to one project:

1. Determine deterministically whether work exists. **No LLM calls.**
2. **Be idempotent.** Before filing, check Forgejo for an open issue
   that already represents this unit of work (filed by a previous
   `enqueue.sh` run). If one exists, do not file a duplicate. This
   matters for projects whose detection logic might match the same
   state across multiple runs (joshing.you's feed-date check is the
   obvious case).
3. If no work: exit 0.
4. If work exists: file one Forgejo issue per discrete unit. Each
   issue must:
   - Carry the `Agent` label.
   - Have a self-sufficient body: what to do, where to look, what
     output is expected, what failure modes are recoverable. The bot
     must be able to act on the issue alone (plus project `CLAUDE.md`
     and any files the body references).
5. Exit 0.

Project-specific knowledge is encapsulated in `enqueue.sh` and the
content of the issue bodies it writes. Igor does not parse project
state.

---

## Bot identity

A single Forgejo + server user named `igor`:

- Forgejo API token and SSH key, with branch protection bypass on
  `main` (necessary for the bot to push branches and have
  `Closes #N`-linked merges work uniformly).
- Server user account, owns `~/.config/igor/`, runs the systemd user
  units.
- Git authorship on all bot commits and PRs.

Logs are uniformly tagged `igor:*` via systemd. One identity for
access control, audit trail, and grep.

---

## Secrets

`$IGOR_HOME/.env` (chmod 600), gitignored. Contains the harness-wide
credentials:

```
CLAUDE_CODE_OAUTH_TOKEN=...
FORGEJO_URL=https://git.sherver.org
FORGEJO_TOKEN=...
```

Auto-exported by `tick.sh` via `set -a; . .env; set +a`. systemd units
load the same file via `EnvironmentFile=`.

Project-specific secrets (e.g., joshing.you's `ANTHROPIC_API_KEY`,
a future SEO worker's GSC token) stay in the project's own `.env`.
`enqueue.sh` and the worked code source it as needed; igor itself
does not.

`.gitignore` at `$IGOR_HOME` blocks `.env`, `state/`, `*.log`.

---

## Persistence

Two systemd user-unit templates, instanced per project:

- `igor-tick@<project>.timer` — runs the consumer on `TICK_INTERVAL`.
  Enabled for every project.
- `igor-enqueue@<project>.timer` — runs the producer on
  `ENQUEUE_INTERVAL`. Enabled only for projects with `enqueue.sh`.

Observability:
- `systemctl --user list-timers` — schedule.
- `journalctl --user -u 'igor-*'` — all activity.
- Forgejo issue queue — current state of work.

---

## Per-project conf schema

`projects/<name>.conf` is shell-sourced.

```sh
# Required
REPO_PATH=/home/josh/Code/joshing.you
FORGEJO_REPO=joshtronic/joshing.you
TICK_INTERVAL=10min

# Optional — omit if the project has no producer
ENQUEUE_INTERVAL=6h
ENQUEUE_CMD=scripts/enqueue.sh

# Defaults to main
PR_BASE=main

# Optional — where report outcomes deliver. Default: forgejo (comment
# on the issue and close it). Future targets (email, discord) layer
# additional delivery without changing the contract — the issue
# comment is always written so the audit trail is intact.
REPORT_TARGETS=forgejo
```

Adding a new project = drop a conf file + enable one or two systemd
timer instances. No code changes in the igor repo.

---

## Validation: `whats-good.sh`

Run against a project name, or with no argument to check all
projects. Each check exits non-zero on failure so the script is
usable as a deploy gate or pre-tick sanity check.

Checks per project:
- `projects/<name>.conf` parses and has required fields.
- `REPO_PATH` exists, is a git repo, matches `FORGEJO_REPO`.
- Forgejo API reachable with the bot token.
- Required labels (`Agent`, `Status/Blocked`) exist on the repo.
- Bot user can comment, label, assign, push, open PRs.
- `<project>/.claude/settings.json` present.
- `<project>/scripts/enqueue.sh` present and executable (if
  `ENQUEUE_CMD` is set).
- systemd units enabled for the project.
- `CLAUDE_CODE_OAUTH_TOKEN` valid (verified with a no-op
  `claude --print`).
- Worktree state dir writable.

---

## Out of scope

Igor handles only issue → outcome work. It explicitly does **not**
handle:

- **Report-only jobs** (SEO sweeps, weekly summaries, cross-site
  analyses). Run those as plain cron. They may file Forgejo issues
  into igor projects as a side effect, but they themselves are not
  igor projects.
- **Interactive Claude.** You use Claude Code in repos normally;
  igor is the unattended layer.
- **Cross-project coordination.** Each project's issue queue is
  independent. If one process wants to queue work for another
  project's bot, it files the issue in that project's repo directly.
- **Pipelines, ETL, long-running daemons.** Not igor's shape.

---

## Trade-offs accepted

- **Cost gating depends on `enqueue.sh` being conservative.** A
  noisy producer will file spurious issues that the bot will work
  and burn tokens on. Keep producers deterministic and tight.
- **Sessions are stateless.** Each tick is a fresh Claude
  invocation. No in-session memory between ticks. Durable state
  lives in the repo, the issue, and `state/`.
- **One project, one host.** Two hosts running ticks for the same
  project will race on issue claim. Each project's timers are
  enabled on exactly one host.
- **No priority labels.** Oldest claimable wins. Urgency is
  expressed by ordering — file the urgent issue first, or close
  older ones.
- **Single bot identity.** All projects share `igor`. Cleaner logs
  and one secret to manage; less audit granularity than per-project
  bots would give.
