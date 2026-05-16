# Setup

## Auth and secrets

Claude Max via `CLAUDE_CODE_OAUTH_TOKEN`. No per-call API billing -- that's
the whole point. The bot's Forgejo token lives in the same file. Both at
`.env` in the Igor clone (next to `.env.example`), chmod 600.

## Bot user

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
state at `~/.local/state/igor/`, and the per-repo clones at `~/Code/<repo>/`.
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
