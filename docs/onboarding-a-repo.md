# Onboarding a repo

There is no per-project config. To put a repo under the agent's care:

1. Add the bot user as a collaborator with **write** permission.
2. Set up the labels the agent reads. Three of them come from Forgejo's
   **Advanced** label template; the fourth is custom:
   - From the Advanced template (repo Settings -> Labels -> load
     template -> Advanced): `Status/Blocked`, `Status/Need More Info`,
     `Priority/Critical`. (The Advanced template also brings `Kind/*` and
     other useful families; harmless to keep them.)
   - Create manually as a new label: `Agent`.
3. Bring the repo to the agent's readiness bar:
   - `CLAUDE.md` at root with project conventions (test commands, code
     style, gotchas, anything Claude needs to be useful here)
   - A README at root (`README.md`/`.rst`/`.txt`/no-ext all accepted)
   - **Tests**: a discoverable way to run them -- `"test"` script in
     `package.json`, `pytest.ini` / `[tool.pytest]` in `pyproject.toml`,
     `test:` target in a `Makefile`, or a Cargo/Go project (implicit)
   - **Lint**: a config -- `.eslintrc*`, `.markdownlint*`, `.stylelintrc*`,
     `.flake8` / `[tool.ruff]`/`[tool.black]` in `pyproject.toml`,
     `.golangci.yml`, Cargo `[lints]`, `.shellcheckrc`
   - **CI**: a workflow file at `.forgejo/workflows/<name>.yml` (or under
     `.gitea/workflows/`) that runs the lint + test commands
4. Optionally, run `bin/validate-repo.sh <owner>/<name>` from your agent
   install to confirm the readiness bar before the first tick.

That's it. Every tick clones (or fetches) every bot-accessible repo and
re-validates it against that local clone -- zero per-file API calls. If
any check fails, the agent skips the repo for this tick's WORK (no PR
review, no issue pickup, no dependency-bump PRs) -- SILENTLY; it does
not file a ticket. The read-only weekly audit still runs. Fix the gaps
and the next tick re-validates and resumes automatically. Run
`bin/validate-repo.sh <owner>/<name>` any time to see what's missing.

The weekly maintenance pass (dep freshness + security audit) is
generic and runs automatically -- the harness detects the stack
from manifests (`package.json`, `Cargo.toml`, `pyproject.toml` /
`requirements.txt`, `go.mod`, `Gemfile`) and runs the standard
audit tools. No per-repo configuration. If you need project-specific
scheduled work (link audits, SEO sweeps, deployment checks), wire
that as a Forgejo workflow in the repo itself; the agent's weekly
pass is intentionally narrow.

The readiness bar is the same for every repo -- a one-page blog and a
production service both need lint + tests + CI. Static sites can satisfy
"tests" with `eleventy --dryrun` plus markdownlint or htmltest; the bar
isn't language-specific, it's about having *some* automation that catches
regressions.

To stop the agent from working a repo: revoke the bot's collaborator role, or
stop applying the `Agent` label. The harness clone under
`~/.local/state/agent/repos/<owner>/<repo>/` is harness-internal -- you
don't need to touch it; `rm -rf`ing the state dir at any time is
safe, the next tick re-clones what it needs.
