# Igor

Igor is an unattended Claude Code harness: a systemd timer fires a tick
every minute, the tick claims one `Agent`-labeled issue from the git
forge across every repo the bot can push to, and ships a PR. Every bot
PR gets a shadow code review before a human ever sees it, and a fleet
of other scheduled passes (maintenance audits, deploy verification,
reporting) run alongside the issue grind. This repo is the harness
itself -- the loop, not any one project it works on.

Generic harness. Project conventions live in each repo's `AGENTS.md`
dossier (see [docs/agents-md-spec.md](docs/agents-md-spec.md) for the
required shape); `CLAUDE.md` is legacy and only present in repos still
mid-migration.

## Mirrors

**Canonical repo:** <https://git.sherver.org/joshtronic/igor>

Mirrored for _your_ convenience:

- <https://github.com/joshtronic/igor>

_I don't monitor these services or accept pull/merge requests on them._

## What it does

- **Issue grind** -- claims the oldest `Agent`-labeled issue across
  every accessible repo, does the work, opens a PR (or files a report,
  or blocks with a comment if it can't proceed).
- **PR shadow review + rework/adjudication** -- an independent model
  reviews every bot PR (APPROVE/REQUEST_CHANGES/COMMENT); a
  REQUEST_CHANGES drives an automatic rework loop, capped at 3 rounds,
  where the agent may fix the finding or dismiss it with recorded
  reasoning before escalating to the human.
- **Checkpoint-and-resume** -- a large issue that hits the per-tick
  turn cap snapshots its progress as a draft PR and picks back up next
  tick instead of losing the work, up to a bounded number of resumes.
- **Maintenance audits** -- a weekly, per-repo dependency/security
  sweep (`npm audit`, `cargo audit`, `pip-audit`, `govulncheck`,
  `bundle audit`, ...) that files deduped tickets for bumps, security
  findings, and anything needing human judgment.
- **Auto-merge + deploy barrier** -- for opted-in repos, merges an
  approved, green, up-to-date bot PR and then verifies the deploy
  actually landed (build SHA + sitemap check) before letting the next
  tick's work start.
- **SEO/GA reporting** -- a monthly, Search-Console-driven pass that
  scores click-upside opportunities per domain (plus GA4 on-site
  numbers where available) and emails a report, filing a ticket for
  opted-in sites.
- **Logwatch** -- a daily sweep of the local systemd journal for any
  repo that declares itself a service, filing a ticket on genuinely
  recurring failures (not one-off blips).
- **Feedback triage** -- reads player/user feedback rows from an
  opted-in repo's published form CSV and files a ticket for anything
  real and new, dropping spam and dupes.

## Requirements

**Stack** -- the real answer lives in `bin/install.sh` and
`bin/doctor.sh`; this is a summary, not a second copy:

- **Commands on `PATH`:** `jq`, `curl`, `git`, `flock` (`util-linux`),
  `timeout` (`coreutils`), `sqlite3`, `openssl`, and the `claude` CLI.
  `install.sh` checks for all of these and refuses to proceed if any
  are missing. Among the apt-installable ones, the Debian package name
  matches the command name except for the two noted above; `claude`
  has no apt package at all and comes from Anthropic's own installer.
  `doctor.sh` additionally uses `fuser` and `journalctl` for
  diagnostics -- useful, not required; it degrades gracefully without
  them.
- **Init system:** systemd **user** units, with lingering enabled so
  the timer survives logout (see [Operator setup](#operator-setup)).
- **The `claude` CLI**, authenticated with a Claude subscription login
  (OAuth) -- not an API key. Every model call goes through it, and the
  harness strips `ANTHROPIC_API_KEY` from every child process on
  purpose: an inherited key would silently flip billing to
  pay-as-you-go.
- **Config:** `.env.example` lists 26 variables, no defaults. The core
  ones (Forgejo connection, model routing, timeouts) make every tick
  fail fast if unset; the rest gate opt-in subsystems (website work,
  SEO reporting, healthcheck pings) that simply no-op without theirs.

We run Debian, so that's what we recommend. Any Linux with systemd and
the commands above should work -- nothing here is Debian-specific
except the `apt` package names baked into `install.sh`. We haven't
tested elsewhere.

### Why systemd

The dependency on systemd is deliberate, not incidental.

The tick cadence itself is a systemd concept. `agent.timer` sets
`OnUnitInactiveSec=15s` -- 15 seconds after the *previous tick
finished*, not a wall-clock schedule -- because ticks here run
anywhere from seconds to many minutes; a fixed cron interval either
piles up during long ticks or idles after short ones, and cron can't
express "N seconds after last completion" at all. `AccuracySec=1s`
skips cron-style batching of wakeups, and `Persistent=true` catches
up a missed run after downtime, where cron just misses it.
`agent.service` adds `After=network-online.target` to order the first
tick on network readiness, which cron has no concept of -- a boot-time
cron job can fire before the network is up.

Overrun protection is `Type=oneshot` plus systemd's own refusal to
double-start an active unit, alongside the global `flock` the tick
takes on its own state dir -- belt-and-braces, not the only
defence. journald gives per-unit, time-filterable logs, which the
logwatch pass reads directly.

Nothing stops you from porting this to another init -- just know
that's a different scheduling model, not a config flag.

## Forge support

| Forge | Status | Notes |
| --- | --- | --- |
| **Forgejo** | Supported | The full unattended loop -- the harness reviews its own PRs and auto-merges where a repo opts in. |
| **Codeberg** | Not supported (policy) | **Do not point this at Codeberg.** Codeberg runs Forgejo, so this would work there with zero code changes -- which is exactly the problem. Codeberg's [Terms of Use](https://codeberg.org/Codeberg/org/src/branch/main/TermsOfUse.md) prohibit sharing projects that mostly consist of code written by generative-AI tools, so pointing an unattended AI agent at it is a policy violation, not a technical limitation. |
| **GitLab** | Coming soon | Not implemented yet. GitLab only lets a merge request be approved by its own author when a project enables `merge_requests_author_approval` -- without that, the unattended loop can't close on its own. |
| **GitHub** | Coming soon | Not implemented yet. GitHub blocks `APPROVE` and `REQUEST_CHANGES` on your own pull request; the harness could still post its independent review as a `COMMENT`, but every merge would need a human click. Review works, unattended merge doesn't -- self-host Forgejo for the full loop. |

Only GitLab and GitHub are planned; neither works today.

## Operator setup

Getting a working install means setting up a bot account and its
credentials on the forge first -- currently manual, one-time work.

- **A dedicated bot account**, separate from the human reviewer. The
  harness assigns terminal review verdicts (approve, request changes)
  to `FORGEJO_REVIEWER` -- a bot reviewing its own PRs defeats the
  point, so the two must be different Forgejo users.
- **An API token** for the bot with three scopes: `read:user` (resolve
  the bot's own identity -- there's no separate `BOT_USER` config
  variable, it's derived from this token at runtime), `write:repository`
  (repo reads, PR listing/creation), and `write:issue`
  (issue create/comment/label/assign/close). Forgejo splits repository
  and issue scopes, so both write scopes are required. Push access for
  git is via an SSH key, separate from the API token.
- **`FORGEJO_REVIEWER`**, set in `.env` -- the human Forgejo username
  every bot PR gets assigned to for review.
- **Lingering enabled** for the Unix user running the timer
  (`sudo loginctl enable-linger <user>`), so its systemd user instance
  keeps running after logout. `install.sh` checks for this and prints
  the exact command if it's missing.
- **Where things live:** the runtime checkout is `AGENT_HOME` --
  wherever you clone the repo (`~/.local/share/agent` below); state
  (per-repo clones, worktrees, the reading-pipeline database) lives at
  `~/.local/state/agent` (`AGENT_STATE_DIR`). Neither is a `.env`
  variable -- `tick.sh` derives them from its own location and `$HOME`
  on every run; `doctor.sh` alone accepts an override, for convenience.

See [docs/setup.md](docs/setup.md) for the full walkthrough and
`.env.example` for the complete variable list -- documented there
rather than duplicated here so the two can't drift.

## Install

**Server prerequisites** (one-time on the host before cloning):

- `jq curl git flock timeout sqlite3` -- `sudo apt-get install -y jq
  curl git util-linux coreutils sqlite3`
- `claude` CLI via Anthropic's installer, authenticated with the
  host's Claude subscription login

See [docs/setup.md](docs/setup.md) for the full prereq picture
(ecosystem toolchains, bot user setup, auth) and links.

Then:

```sh
git clone <git-repo-url> ~/.local/share/agent
cd ~/.local/share/agent
cp .env.example .env && chmod 600 .env
$EDITOR .env                   # fill in every var -- no defaults
bin/install.sh                 # pre-flights deps, wires systemd
bin/validate.sh                # confirm setup
```

`install.sh` is the "clone and go" entry point. It pre-flights all
prereqs and wires up the systemd timer. Idempotent; re-run after
`git pull` to pick up unit file changes.

## Updating

```sh
cd ~/.local/share/agent
git pull
bin/install.sh                 # re-reads units, daemon-reloads
```

`install.sh` is idempotent. `.env` changes need no reload -- each tick
re-sources it.

For each repo the agent should work: add the bot user as a collaborator,
set up labels (the forge's label set -- on Forgejo, the Advanced
template -- plus a custom `Agent` label),
and confirm via `bin/validate-repo.sh <owner>/<name>`. See
[docs/onboarding-a-repo.md](docs/onboarding-a-repo.md) for the full
readiness bar.

## Docs

- [Architecture](docs/architecture.md) -- how the runtime works, labels, layout, trade-offs
- [Setup](docs/setup.md) -- auth, bot user, install, local dev, operating
- [Onboarding a repo](docs/onboarding-a-repo.md) -- readiness bar, labels, validation
- [AGENTS.md dossier spec](docs/agents-md-spec.md) -- the per-repo context file's required shape

## License

This project is licensed under the GNU General Public License v3.0 --
see [LICENSE](LICENSE) for the full text.
