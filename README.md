# Igor

> "RIDING AROUND TOWN, THEY GON' FEEL THIS ONE"

Unattended Claude Code in a pastel blue suit. One global tick fires on a
timer, Igor sweeps every repo the bot can push to for `Agent`-labeled work,
claims the oldest one, ships a PR (or a report, or a blocker).

## Install

```sh
git clone <forgejo-url>/igor ~/.local/share/igor
cd ~/.local/share/igor
cp .env.example .env && chmod 600 .env
$EDITOR .env                   # fill in tokens
bin/install.sh                 # systemd setup
bin/validate.sh                # confirm setup
```

## Updating

```sh
cd ~/.local/share/igor
git pull
bin/install.sh                 # re-reads units, daemon-reloads
```

`install.sh` is idempotent. `.env` changes need no reload -- each tick
re-sources it.

For each repo Igor should work: add the bot user as a collaborator, set
up labels (Forgejo's Advanced label template + a custom `Agent` label),
and confirm via `bin/validate-repo.sh <owner>/<name>`. See
[docs/onboarding-a-repo.md](docs/onboarding-a-repo.md) for the full
readiness bar.

## Docs

- [Architecture](docs/architecture.md) -- how Igor works, labels, layout, trade-offs
- [Setup](docs/setup.md) -- auth, bot user, install, local dev, operating
- [Onboarding a repo](docs/onboarding-a-repo.md) -- readiness bar, labels, validation

## Status

Pre-flight. Lint green. Igor hasn't punched in yet.
