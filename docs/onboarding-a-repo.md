# Onboarding a repo

There is no per-project config. To put a repo under the agent's care:

1. Add the bot user as a collaborator with **write** permission.
2. Set up the labels the agent reads. Three of them come from Forgejo's
   **Advanced** label template; the fourth is custom:
   - From the Advanced template (repo Settings -> Labels -> load
     template -> Advanced): `Status/Blocked`, `Status/Needs More Info`,
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
5. Optional: add a `## Maintenance` section to the repo's `CLAUDE.md`
   only if you want to override the defaults. Without it, the agent
   auto-detects the stack and runs the standard audit + dep-freshness
   tools for the ecosystem (`npm audit`, `cargo audit`, `pip-audit`,
   `govulncheck`, `bundle audit`, etc.). Use the override when you
   want stricter thresholds, additional checks (link audit, SEO
   scan, performance benchmarks), or a non-standard tool. Example:

   ```markdown
   ## Maintenance

   When asked to do a maintenance pass, run:

   - `npm audit --production --audit-level=moderate` -- file issues
     for unresolved vulnerabilities.
   - `npx lychee --offline 'src/**/*.md'` -- file an issue if any
     links resolve as broken.
   - `npm outdated` -- summarize anything > 6 months behind.

   If everything's clean, exit silently.
   ```

That's it. The next tick validates the repo via the Forgejo API. If any
checks fail, the agent files a `Status/Needs More Info` ticket listing what's
missing and skips the repo. Fix the gaps, close the ticket, and the next
tick re-validates and clones if ready (or reopens the ticket with what's
still wrong).

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
