# Setup

## Server prerequisites

Before cloning Igor, make sure the host has:

**Required on PATH:**

- `jq`, `curl`, `git`, `flock`, `timeout` -- core harness deps. On Debian/Ubuntu: `sudo apt-get install -y jq curl git util-linux coreutils` (most are usually already installed; `jq` is the one you'll typically need to add).
- `claude` -- Anthropic's Claude CLI. Install via Anthropic's installer (see [docs.claude.com](https://docs.claude.com)). The harness invokes `claude --print` directly; `ANTHROPIC_API_KEY` from `.env` is what it authenticates with.

`bin/install.sh` and `bin/validate.sh` both pre-flight these and bail loudly if anything's missing.

**Ecosystem toolchains for repos Igor will actually work:**

Tier 2 maintenance auto-detects the stack and runs standard audit tools (`npm audit`, `cargo audit`, `pip-audit`, `govulncheck`, `bundle audit`, etc.). Claude will `cargo install cargo-audit` or `pip install pip-audit` within his session as needed, but the base toolchain must be on the host:

- Node projects (including Igor's own website) → `sudo apt-get install -y nodejs npm`
- Python projects → `sudo apt-get install -y python3 python3-pip python3-venv`
- Go projects → `sudo apt-get install -y golang-go`
- Rust projects → install [rustup](https://rustup.rs) (not in apt)
- Ruby projects → `sudo apt-get install -y ruby ruby-dev`

You only need toolchains for languages Igor will actually touch.

## Auth and secrets

Igor runs against the Anthropic API (not the Max plan). Create a dedicated
API key in the [Anthropic Console](https://console.anthropic.com) and set
a hard spending limit on it -- a pathological tick should not be able to
drain the account. Set the key as `ANTHROPIC_API_KEY` in `.env`.

The Max plan is for interactive Claude Code sessions (you, typing). The
robot is a separate workload with different cost shape -- metered billing
gives real per-task visibility, model selection, and prompt caching you
control.

Pick the model in `IGOR_MODEL` (also in `.env`). Sensible defaults:
`claude-sonnet-4-6` for normal coding work, `claude-opus-4-7` if you find
Igor consistently noops on tickets that need deeper reasoning,
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
- An SSH key for git operations (clone and push). Igor clones via
  `git@<host>:<owner>/<repo>.git`, where `<host>` is derived from
  `FORGEJO_URL` (override with `FORGEJO_SSH_HOST` if SSH is on a different
  endpoint).
- Branch protection bypass on each repo's default branch, so the harness can
  push `agent/N-<slug>` branches and `Closes #N`-linked merges work uniformly.

The server account owns the runtime checkout at `~/.local/share/igor/`, its
state at `~/.local/state/igor/` (which includes the per-repo clones
under `~/.local/state/igor/repos/<owner>/<repo>/`).
Git authorship on all bot commits and PRs attributes to this user.

## Install

Clone the repo, drop the `.env` in place, then run install.sh:

```sh
git clone <forgejo-url>/igor ~/.local/share/igor
cd ~/.local/share/igor
cp .env.example .env && chmod 600 .env
$EDITOR .env                           # fill in tokens
bin/install.sh
```

`install.sh` symlinks the systemd unit files into `~/.config/systemd/user/`
(so future `git pull`s update them with a `daemon-reload`) and enables
`tick.timer`. Verify the setup:

```sh
bin/validate.sh   # checks env, Forgejo reachability, bot identity, accessible repos
```

Re-running `install.sh` is safe. To tear down:

```sh
bin/uninstall.sh   # stops, disables, removes units (leaves config + state)
```

Schedule override goes in a drop-in at
`~/.config/systemd/user/tick.timer.d/override.conf`.

## Local dev / manual runs

`install.sh` is only for the systemd-managed install. To run a tick
manually (against a dev clone or to test changes):

```sh
git clone <forgejo-url>/igor ~/Code/igor
cd ~/Code/igor
cp .env.example .env && chmod 600 .env && $EDITOR .env
bin/tick.sh
```

Same `.env` shape, same scripts. flock prevents collision with any
running systemd-managed tick.

## Operating

- Schedule: `systemctl --user list-timers tick.timer`
- Logs: `journalctl --user -u tick.service -f`
- Force a tick now: `systemctl --user start tick.service`
- Audit a repo's readiness: `bin/validate-repo.sh <owner>/<name>` (or
  `bin/validate-repo.sh --all` to sweep every accessible repo)
