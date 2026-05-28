# Setup

## Server prerequisites

Before cloning the agent, make sure the host has the following installed.
`bin/install.sh` pre-flights everything and bails loudly if anything's
missing.

**Required on PATH:**

- `jq`, `curl`, `git`, `flock`, `timeout`, `sqlite3` -- core harness deps.
  `sudo apt-get install -y jq curl git util-linux coreutils sqlite3`
  (most are usually already installed; `jq` and `sqlite3` are typically
  the ones to add).
- `claude` -- Anthropic's Claude CLI. Install via Anthropic's installer
  (see [docs.claude.com](https://docs.claude.com)). `ANTHROPIC_API_KEY`
  from `.env` is what it authenticates with.

**Ecosystem toolchains for repos the agent will actually work:**

The weekly maintenance pass auto-detects the stack and runs standard audit tools (`npm audit`, `cargo audit`, `pip-audit`, `govulncheck`, `bundle audit`, etc.) from the harness directly. Missing audit binaries (`cargo-audit`, `pip-audit`, `govulncheck`, `bundler-audit`) are installed on demand into user-writable paths -- no sudo. But the base language toolchain must already be on the host:

- Node projects (including the agent's own website) → `sudo apt-get install -y nodejs npm`
- Python projects → `sudo apt-get install -y python3 python3-pip python3-venv`
- Go projects → `sudo apt-get install -y golang-go`
- Rust projects → install [rustup](https://rustup.rs) (not in apt)
- Ruby projects → `sudo apt-get install -y ruby ruby-dev`

You only need toolchains for languages the agent will actually touch.

## Auth and secrets

The agent runs against the Anthropic API (not the Max plan). Create a dedicated
API key in the [Anthropic Console](https://console.anthropic.com) and set
a hard spending limit on it -- a pathological tick should not be able to
drain the account. Set the key as `ANTHROPIC_API_KEY` in `.env`.

The Max plan is for interactive Claude Code sessions (you, typing). The
robot is a separate workload with different cost shape -- metered billing
gives real per-task visibility, model selection, and prompt caching you
control.

Pick the model in `AGENT_MODEL` (also in `.env`). Sensible defaults:
`claude-sonnet-4-6` for normal coding work, `claude-opus-4-7` if you find
The agent consistently noops on tickets that need deeper reasoning,
`claude-haiku-4-5-20251001` only for cheap/light tasks.

The bot's Forgejo token (`FORGEJO_TOKEN`) lives in the same `.env`, chmod
600. See `.env.example` for the full template.

## Bot user

A dedicated Forgejo user plus a matching server account (one Unix user runs
the systemd units and owns the SSH key). The Forgejo user needs:

- An API token with these three scopes:
  - `read:user` -- so the harness can resolve the bot's identity via
    `/api/v1/user` (no separate `BOT_USER` config needed)
  - `write:repository` -- reading repo contents, listing PRs, opening PRs
  - `write:issue` -- creating/commenting/labeling/assigning/closing issues

  Forgejo's scope model is fine-grained: `write:repository` does NOT
  include issue ops, hence the separate `write:issue`. All three are
  required; missing any will cause specific harness operations to fail
  later with a `403 token does not have at least one of required scope(s)`
  message. Push access for git (clone/push) is via the SSH key, separate
  from API scopes.
- An SSH key for git operations (clone and push). The agent clones via
  `git@<host>:<owner>/<repo>.git`, where `<host>` is derived from
  `FORGEJO_URL` (override with `FORGEJO_HOST` if SSH is on a different
  endpoint).
- Branch protection bypass on each repo's default branch, so the harness can
  push `agent/N-<slug>` branches and `Closes #N`-linked merges work uniformly.

The server account owns the runtime checkout at `~/.local/share/agent/`, its
state at `~/.local/state/agent/` (which includes the per-repo clones
under `~/.local/state/agent/repos/<owner>/<repo>/`).
Git authorship on all bot commits and PRs attributes to this user.

## Install

Clone the repo, drop the `.env` in place, then run install.sh:

```sh
git clone <forgejo-url>/<bot-user>/agent ~/.local/share/agent
cd ~/.local/share/agent
cp .env.example .env && chmod 600 .env
$EDITOR .env                           # fill in every var -- no defaults
bin/install.sh
```

`install.sh` symlinks the systemd unit files into `~/.config/systemd/user/`
(so future `git pull`s update them with a `daemon-reload`) and enables
`agent.timer`. Verify the setup:

```sh
bin/validate.sh   # checks env, Forgejo reachability, bot identity, accessible repos
```

Re-running `install.sh` is safe. To tear down:

```sh
bin/uninstall.sh   # stops, disables, removes units (leaves config + state)
```

Schedule override goes in a drop-in at
`~/.config/systemd/user/agent.timer.d/override.conf`.

## Local dev / manual runs

`install.sh` is only for the systemd-managed install. To run a tick
manually (against a dev clone or to test changes):

```sh
git clone <forgejo-url>/<bot-user>/agent ~/Code/agent
cd ~/Code/agent
cp .env.example .env && chmod 600 .env && $EDITOR .env
bin/tick.sh
```

Same `.env` shape, same scripts. flock prevents collision with any
running systemd-managed tick.

## Operating

- Schedule: `systemctl --user list-timers agent.timer`
- Logs: `journalctl --user -u agent.service -f`
- Force a tick now: `systemctl --user start agent.service`
- Audit a repo's readiness: `bin/validate-repo.sh <owner>/<name>` (or
  `bin/validate-repo.sh --all` to sweep every accessible repo)
