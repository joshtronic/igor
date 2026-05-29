This is the directive for the FEATURE slot: at most one
substantive piece of site work per day. The bar is high. Most
days there's nothing that genuinely needs doing, and that's the
expected outcome -- exit clean. A forced change is worse than no
change.

---

Pick ONE thing only if it's clearly broken or clearly missing.
In scope:

- A real bug: broken link, layout that breaks in a specific
  browser, RSS/sitemap that fails validation, a build warning you
  can trace to a root cause.
- A small feature the site genuinely lacks: a missing footer
  link, a meta tag that's actually absent, a script hook that
  makes future work cheaper.
- A content or copy restructure that needs more than a one-line
  fix: splitting a page that's grown unwieldy, consolidating copy
  that's duplicated across pages (but NOT the locked pages below).

Out of scope (leave these alone):

- Cosmetic polish -- color, spacing, type, hover states. That's
  the design slot.
- The locked stable pages: /now, /about, /colophon. Hard
  boundary, no exceptions (see CLAUDE.md). If one of them reads
  stale, that's a ticket for the human to file, not a change to
  make autonomously.
- CI workflow files under .forgejo/ or .github/. Never.
- Anything that needs a new dependency unless it's clearly
  warranted and you note why.

The test for shipping: would a careful maintainer agree this
needed doing today? If you're reaching, you have your answer --
exit clean and let the design slot fire later.

When you do ship, write `.agent/PR_BODY.md` with this exact
shape:

    ## What this PR does

    - [x] <conventional-commit-prefixed first line>
    - [x] <other changes if any>

    ## Test plan

    - [x] <what you actually ran this tick: tests / lint / build pass>
    - [ ] Manual: <steps needing a human -- anything visual or in a browser>

Only mark `- [x]` what you genuinely ran and confirmed this tick. Any
step that needs a human -- viewing a page, checking light/dark mode or
layout, comparing against an external system -- stays a `- [ ] Manual:`
line, UNCHECKED, because you cannot see rendered output. A ticked box
means "I did this," not "this should be fine." If nothing needs a
human, say so: `- [x] No manual verification needed; CI is the gate`.

The first checklist item under "What this PR does" MUST start
with a conventional-commit prefix (`feat:`, `fix:`, `chore:`,
`docs:`, `refactor:`). Example:
`- [x] fix: broken RSS validation on the feed root`. The harness
uses that first item verbatim as the commit subject AND PR title
-- wrong heading or missing prefix produces a garbage subject.
