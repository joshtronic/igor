# Architecture

## How the agent works

A timer fires `bin/tick.sh`. Per tick:

1. **Lock.** Global flock -- only one tick at a time. No two-puppet show.
2. **Identity.** Resolve the bot's Forgejo login from the token via
   `/api/v1/user`. No `BOT_USER` config; the token is the identity.
3. **Recovery sweep.** Any open issue still assigned to the bot from a
   previous interrupted run gets a "previous tick was interrupted --
   re-queueing" comment and is unassigned. Nothing slips through a
   midnight crash.
4. **Validation sweep.** Every bot-accessible repo runs through
   onboarding validation via the Forgejo API. A PASS is cached for
   `VALIDATION_COOLDOWN_SECS` (15 min) so the full ~6-call check
   doesn't re-run every tick at the 1-minute cadence; failures
   re-check every tick. Repos
   that fail get an auto-filed `Status/Need More Info` ticket
   (or a reopen on the existing one) and are excluded from this
   tick's **work** -- no PR review, no issue pickup. Validation
   gates work, not analysis: the read-only weekly security/dep
   audit still runs on a failed repo (it only files an issue, never
   commits). The validated set is what the work steps iterate over.
   Local clones are NOT purged on failure; when the human closes
   the onboarding ticket and validation passes again, the clone is
   still there.
5. **PR-review pickup.** Scan validated repos for open bot PRs
   where the latest non-bot review on the current HEAD is
   `REQUEST_CHANGES`, or for PRs reassigned back to the bot.
   First hit wins; reopen the work. This is responsive to the
   human, so it sits ahead of Igor's own work.
6. **Igor's own work** (opt-in via `WEBSITE_REPO`). One piece per
   tick, fire-one-then-exit, in priority order:
   - **reading** (daily) -- run the reading pipeline: read a
     source, reflect into the brain.
   - **post** (daily) -- run the ideation pipeline and ship the
     day's blog post. The slot stays open and retries every tick
     until a post actually lands that day (capped by
     `POST_MAX_ATTEMPTS`), so the daily post is near-guaranteed.
   - **/now** (weekly) -- refresh the `/now` page from a digest of
     the last week's reading (`site-work-block.sh --directive now`).
   - **site-work** (weekly) -- one pass over the site: bugs, small
     features, a touch of polish, capped at `SITE_WORK_DIFF_CAP`
     changed lines so it can't become a rewrite
     (`site-work-block.sh --directive site-work`).
   Daily slots reset at midnight; weekly slots roll on the ISO week
   (Monday-anchored, self-healing if a Monday tick is missed). State
   lives in `discretionary-state.json`. This is the throttle that
   keeps Igor from opening a stack of discretionary PRs.
7. **Scheduled maintenance / analysis.** Iterate EVERY bot-accessible
   repo -- not just the validated set; analysis is read-only and
   decoupled from the validation gate -- for any not yet audited this
   ISO week (weeks start Monday) and audit each. The
   harness runs the stack-detection audit tools itself (`npm audit`,
   `cargo audit`, `pip-audit`, `govulncheck`, `bundle audit`, plus
   their outdated counterparts) via `lib/maintenance-checks.sh`.
   Clean week -> no issue, no LLM. No recognized stack -> same.
   Findings -> invoke Claude to triage the raw audit output into
   `.agent/AGENT_MAINTENANCE_FINDINGS.md` + severity; harness files
   a `Status/Need More Info` issue with the matching `Priority/*`
   label. Runs after Igor's own work, before the ticket grind.
8. **SEO analysis** (opt-in via Google Search Console + SMTP2GO env;
   no-ops when unconfigured). GSC-driven, not repo-driven: enumerate
   Search Console **domain properties** (`sc-domain:` only) and analyze
   ONE per tick (weekly per domain). The harness scores opportunities
   from the Search Analytics API -- striking-distance queries, low-CTR
   pages, decaying pages -- entirely in shell (`lib/seo-analysis.sh`,
   no LLM), applies an impression floor + top-K cap, grades the batch
   (GOOD/INDIFFERENT by estimated click upside), and emails the owner
   (`SEO_PRIMARY_EMAIL` always, plus selective extras per
   `SEO_EXTRA_RECIPIENTS`) via SMTP2GO. For domains in
   `SEO_AGENTIC_SITES` it also files ONE curated, deduped,
   `Agent`-labeled ticket on the mapped repo -- which Discovery (next)
   picks up once that repo is validated. Surfaced opportunities are
   logged to `seo-opportunities.jsonl` with baselines for future
   outcome grading. Nothing above the floor -> no email, no ticket.
9. **Discovery.** For each validated repo, query for the oldest
   claimable issue (`Agent`-labeled, no assignee, not
   `Status/Blocked`). Skip repos with an open bot-authored PR --
   one PR at a time per repo so the human can review without a
   backlog forming behind them. Pick the globally oldest across
   all eligible repos.
10. **Claim and clone.** Assign the issue to the bot. If the repo
    isn't cloned locally yet, clone it to
    `~/.local/state/agent/repos/<owner>/<repo>/` via SSH.
11. **Preflight.** Verify `CLAUDE.md` exists at the repo root. If
    not, block the issue with a clear comment and bail. (Same code
    path as Claude calling `agent-block.sh` from inside the
    worktree.)
12. **Work.** Make a worktree, invoke Claude with `bin/lib/voice.md`
    plus `AGENTS.md` (the project's `CLAUDE.md` is auto-loaded by
    Claude Code), react to whatever Claude leaves behind. If
    discovery turned up nothing, the tick is idle and exits.

There is no shift window -- every tick runs the full cascade, 24/7.
Midnight is just the local-day rollover for the daily slots
(reading, post); the weekly slots (/now, site-work), maintenance, and
the per-domain SEO pass roll on the ISO week (Monday-anchored). What runs on a given tick is
decided by the cascade's fixed priority order, not the clock:
PR-review and the ticket grind respond whenever there's a signal,
while Igor's own daily/weekly work is throttled by its slots.

| What Claude did                 | What the agent does                                           |
|---------------------------------|---------------------------------------------------------------|
| Made commits                    | Push branch, open PR with `Closes #N` + deps audit            |
| Closed the issue with a comment | Treat as a report -- log and clean up                         |
| Applied `Status/Blocked`        | Log, clean up, wait for the human                             |
| Nothing                         | Unassign, leave a "no work" comment with Claude's tail output |

Filing issues is not the agent's job. Project cron jobs, hand-filed
issues, external bots -- all valid producers. They POST to Forgejo
with the `Agent` label and the agent picks it up.

## System prompts

Different surfaces inside a single tick get different system
prompts -- not one kitchen-sink prompt for everything. The split:

| Surface                         | System prompt                                                              |
|---------------------------------|----------------------------------------------------------------------------|
| Issue work, PR review           | `bin/lib/voice.md` + `AGENTS.md` (repo's `CLAUDE.md` is auto-loaded)       |
| Maintenance triage              | (none -- the user message is self-contained classification)                |
| Reading pipeline (reflect, post drafting, post-shape decision) | `bin/lib/voice.md` + a task-specific directive      |
| Site-work + /now pass           | `bin/lib/voice.md` + `bin/lib/{site-work,now}-directive.md` |

`voice.md` is the shared voice anchor; the task directives carry
surface-specific framing. The slim `AGENTS.md` is only what
unattended issue/PR work actually needs.

## Labels

Two labels carry the state machine for agent-work tickets.
`Status/Blocked` comes from Forgejo's Advanced label template;
`Agent` is custom (created per-repo). Onboarding-failure tickets
also use `Status/Need More Info` and `Priority/Critical`, both from
the Advanced template. See
[onboarding-a-repo.md](onboarding-a-repo.md) for how to set them up.

| State               | Labels                     | Assignee  | Open?  |
|---------------------|----------------------------|-----------|--------|
| Filed, not approved | -- (or `Kind/*`)           | --        | open   |
| Approved, claimable | `Agent`                    | --        | open   |
| In progress         | `Agent`                    | `<bot>`   | open   |
| Blocked             | `Agent` + `Status/Blocked` | --        | open   |
| Done                | (any)                      | (any)     | closed |

`Agent` is a **permission flag** ("agent's domain"), not a state.
State is carried by `Status/Blocked`, the assignee, and open/closed.

Useful queries:

- Claimable: `is:open label:Agent no:assignee -label:Status/Blocked`
- In flight: `is:open label:Agent assignee:<bot user>`
- Stuck: `is:open label:Status/Blocked`

The agent also files `Status/Need More Info` + `Priority/Critical`
tickets for repos that fail onboarding validation. See
[onboarding-a-repo.md](onboarding-a-repo.md).

## Pieces

In the repo (versioned policy + harness code):

```
bin/
|-- tick.sh                  # the worker (one issue per invocation)
|-- reading-pipeline.sh      # read one source, reflect, draft post (opt-in)
|-- site-work-block.sh       # fresh Claude pass against the website (opt-in)
|-- agent-ask.sh             # Claude calls to file an async question issue
|-- agent-block.sh           # Claude calls when stuck
|-- agent-report.sh          # Claude calls for no-diff outcomes
|-- check-sync.sh            # CI lint: AGENTS.md <-> tick.sh contract
|-- validate.sh              # validate env + Forgejo connectivity + bot perms
|-- validate-repo.sh         # audit a single repo (or --all) for readiness
|-- gsc-auth.sh              # one-time: mint a GSC OAuth refresh token (SEO)
|-- install.sh               # one-time: install systemd units + enable timer
|-- uninstall.sh             # stop, disable, remove units
`-- lib/
    |-- voice.md             # shared voice anchor for every Claude invocation
    |-- site-work-directive.md # weekly site-work pass directive
    `-- now-directive.md     # weekly /now refresh directive

lib/
|-- forgejo.sh               # Forgejo API helpers
|-- cost.sh                  # Anthropic cost ledger (CLI + raw API)
|-- repo-checks.sh           # repo-readiness checks + onboarding ticket lifecycle
|-- maintenance-checks.sh    # stack detection + audit tool dispatch
|-- gsc.sh                   # Google Search Console API client (SEO, opt-in)
|-- email.sh                 # SMTP2GO HTTP API sender (SEO, opt-in)
`-- seo-analysis.sh          # scripted SEO analysis: score, grade, render (no LLM)

systemd/                     # user units (no @ instance)
|-- agent.service
`-- agent.timer

AGENTS.md                    # universal unattended rules -- appended to Claude's system prompt for issue/PR work
agent-settings.json          # bot's permission profile -- passed via --settings
```

On the host (deployment-specific, not in the repo):

```
~/.local/share/agent/                          # the harness install (systemd-managed)
~/.local/share/agent/.env                      # secrets, chmod 600 -- the only config
~/.local/state/agent/lock                      # global flock
~/.local/state/agent/brain.sqlite              # seen URLs, sources, reflections
~/.local/state/agent/discretionary-state.json  # daily/weekly slots + per-repo maintenance + per-domain SEO stamps
~/.local/state/agent/seo-opportunities.jsonl   # surfaced SEO opportunities + baselines (for outcome grading)
~/.local/state/agent/worktrees/<key>/          # per-tick worktrees
~/.local/state/agent/repos/<owner>/<repo>/     # harness's per-repo clones
~/.local/state/agent/repos/<WEBSITE_REPO>/     # the bot's website -- bootstrap-soft, opt-in
~/.config/systemd/user/agent.{service,timer}   # symlinks into the harness install
```

Harness state lives entirely under `~/.local/state/agent/`,
isolated from `~/Code/` (your interactive workspace) and from
`~/.local/share/agent/` (the install itself). Per-repo clones nest
by owner to mirror Forgejo's URL structure and prevent same-name
collisions across different owners.

The sqlite store (`brain.sqlite`) is the durable state behind the
reading pipeline -- seen URLs (so we don't re-read the same article
across ticks) and reflections from prior reads. The harness is
pure bash + standard CLI tools; no Python, no Redis, no vector
index. Tables: `seen_urls`, `reflections`. Schema is lazy-created
by `reading-pipeline.sh` on first run.

## Scope and trade-offs

The agent handles only `Agent`-labeled issue -> outcome work, plus
optional website work (reading + posts + freeform site passes) when
`WEBSITE_REPO` is set. It does **not** handle:

- **Filing issues.** Producers do that -- cron jobs, external bots,
  you typing at a keyboard. The agent is a consumer.
- **Report-only jobs** (SEO sweeps, weekly summaries) that don't fit
  issue -> PR/report. Run those as plain cron. They may file agent
  issues as a side effect.
- **Interactive Claude.** Use Claude Code normally in repos; the
  agent is the unattended layer.
- **Pipelines, ETL, long-running daemons.** Not the agent's shape.

Known trade-offs:

- **Cost gating depends on producers being conservative.** Noisy
  producers file spurious issues that the agent will work and burn
  tokens on. Keep producers tight.
- **Sessions are stateless.** Each tick is a fresh Claude
  invocation. Durable state lives in the repo, the issue, and
  `brain.sqlite`.
- **One host per agent install.** Two hosts watching the same
  Forgejo will race on issue claim.
- **Oldest claimable wins.** No priority labels. Urgency = file the
  urgent issue first.
- **Recovery, not resume.** An interrupted tick re-queues its
  issue; the next tick starts fresh.
- **Scope cap.** A branch over ~400 changed lines gets blocked
  instead of shipped, with a comment listing the touched files.
  Split the ticket and re-queue.
- **One PR per repo.** While a bot PR is open in a repo, the rest
  of that repo's claimable issues wait. Intentional throttle; merge
  or close to resume.
- **Metered cost per tick.** The agent runs against the Anthropic
  API (not the Max plan -- that's for interactive Claude Code), so
  every tick costs money in proportion to context size and tool
  use. Wall-clock and turn caps bound the worst case, but watch the
  Console for the first week to calibrate. Prompt caching on the
  stable `AGENTS.md` + per-repo `CLAUDE.md` portion drops repeat
  input cost ~90%.
- **Tests-vacuous-true.** Definition of done is "tests pass." A
  test command that exits 0 with zero tests run (e.g.
  `jest --passWithNoTests`) is a vacuous pass. The harness greps
  Claude's output for obvious zero-test patterns and blocks, but
  the real defense is a meaningful test command in `CLAUDE.md`.
  Repos with weak test discipline get a weaker bar.
- **Supply-chain alerting, not prevention.** Every PR the agent
  opens gets a harness-generated `## Dependencies changed` section
  listing manifest / lockfile diffs with line counts -- so a
  `npm install evil-package` is impossible to miss in review. The
  harness writes that section, not Claude, so the thing under
  review can't omit it. The agent does **not** sandbox installs or
  scan package contents -- a malicious package could still run
  install scripts during the work. The defense is human PR review
  armed with the audit.
