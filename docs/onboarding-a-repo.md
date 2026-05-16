# Onboarding a repo

There is no per-project config. To put a repo under Igor's care:

1. Add the bot user as a collaborator with **write** permission.
2. Ensure the labels Igor reads exist on the repo: `Agent`, `Status/Blocked`,
   `Status/Needs More Info`, `Priority/High`.
3. Bring the repo to Igor's readiness bar:
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
4. Optionally, run `bin/validate-repo.sh <owner>/<name>` from your Igor
   install to confirm the readiness bar before the first tick.

That's it. The next tick validates the repo via the Forgejo API. If any
checks fail, Igor files a `Status/Needs More Info` ticket listing what's
missing and skips the repo. Fix the gaps, close the ticket, and the next
tick re-validates and clones if ready (or reopens the ticket with what's
still wrong).

The readiness bar is the same for every repo -- a one-page blog and a
production service both need lint + tests + CI. Static sites can satisfy
"tests" with `eleventy --dryrun` plus markdownlint or htmltest; the bar
isn't language-specific, it's about having *some* automation that catches
regressions.

To stop Igor from working a repo: revoke the bot's collaborator role, or
stop applying the `Agent` label. The local clone at `~/Code/<repo>` is
yours to keep or `rm -rf` as you see fit.
