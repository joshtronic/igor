# Igor

Igor is an unattended Claude Code harness: a systemd timer fires a tick
every minute, the tick claims one `Agent`-labeled Forgejo issue across
every repo the bot can push to, and ships a PR. Every bot PR gets a
shadow code review before a human ever sees it, and a fleet of other
scheduled passes (maintenance audits, deploy verification, reporting)
run alongside the issue grind. This repo is the harness itself -- the
loop, not any one project it works on.

Generic harness. Project conventions live in each repo's `AGENTS.md`
dossier (see [docs/agents-md-spec.md](docs/agents-md-spec.md) for the
required shape); `CLAUDE.md` is legacy and only present in repos still
mid-migration.

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
git clone <forgejo-url>/<bot-user>/igor ~/.local/share/agent
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
set up labels (Forgejo's Advanced label template + a custom `Agent` label),
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
