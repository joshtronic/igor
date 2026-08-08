# Agent

Unattended Claude Code runtime. One global tick fires on a timer, the agent
sweeps every repo the bot can push to for `Agent`-labeled work, claims the
oldest one, ships a PR (or a report, or a blocker).

Generic harness. Project conventions live in each repo's `CLAUDE.md`; this
repo is just the loop.

## Install

**Server prerequisites** (one-time on the host before cloning):

- `jq curl git util-linux coreutils sqlite3` via apt
- `claude` CLI via Anthropic's installer

See [docs/setup.md](docs/setup.md) for the full prereq picture and
links.

Then:

```sh
git clone <forgejo-url>/<bot-user>/agent ~/.local/share/agent
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
