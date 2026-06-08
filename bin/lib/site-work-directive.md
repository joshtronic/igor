This is the directive for the WEEKLY site-work pass: one pass per
week across your own site. Not a daily slot, not a rewrite. The
bar is high and most weeks there's little that genuinely needs
doing -- a clean "nothing this week" is a fine outcome. A forced
change is worse than no change.

---

Do a real pass over the site. Fix what's genuinely broken, ship
one or two improvements that actually matter, and add a small
polish if one earns its place. In scope:

- Real bugs: a broken link, layout that breaks in a browser,
  RSS/sitemap that fails validation, a build warning you can trace
  to a root cause.
- A small feature the site genuinely lacks: a missing footer link,
  an absent meta tag, a script hook that makes future work cheaper.
- A content or copy restructure that needs more than a one-line
  fix: splitting a page that's grown unwieldy, consolidating copy
  duplicated across pages (but NOT the locked pages below).
- Visual or interaction polish: a CSS variable, spacing, type, a
  subtle hover/transition, a turn of microcopy with personality.
  At most a small part of the pass -- polish is the garnish, not
  the meal.

Hold the line on scope. This is the rule that keeps the pass from
becoming a weekly pixel-pushing rewrite:

- One or two meaningful changes, not a pile of trivial tweaks.
  Five cosmetic nudges in one PR is the failure mode, not the
  goal. If you can't name why a change matters, don't make it.
- The harness caps the diff size and refuses to ship an oversized
  pass. Stay well under it; a tight, defensible PR beats a sprawl.

Out of scope (leave these alone):

- The locked stable pages: /now, /about, /uses. Hard
  boundary, no exceptions (see CLAUDE.md). /now has its own
  separate weekly pass; the others are the human's to author. If
  one reads stale, that's a ticket for the human to file, not a
  change to make here.
- CI workflow files under .forgejo/ or .github/. Never.
- Anything that needs a new dependency unless it's clearly
  warranted and you note why.

The test for shipping: would a careful maintainer agree this
needed doing this week? If you're reaching, you have your answer
-- exit clean.

When you do ship, write `.agent/PR_BODY.md` with this exact shape:

    ## What this PR does

    - [x] <conventional-commit-prefixed first line>
    - [x] <other changes if any>

    ## Test plan

    - [x] <what you actually ran this pass: tests / lint / build pass>
    - [ ] Manual: <steps needing a human -- anything visual or in a browser>

Only mark `- [x]` what you genuinely ran and confirmed this pass.
Any step that needs a human -- viewing a page, checking light/dark
mode or layout, comparing against an external system -- stays a
`- [ ] Manual:` line, UNCHECKED, because you cannot see rendered
output. A ticked box means "I did this," not "this should be
fine." If nothing needs a human, say so: `- [x] No manual
verification needed; CI is the gate`.

The first checklist item under "What this PR does" MUST start with
a conventional-commit prefix (`feat:`, `fix:`, `chore:`, `docs:`,
`style:`, `refactor:`). Example: `- [x] fix: broken RSS validation
on the feed root`. The harness uses that first item verbatim as
the commit subject AND PR title -- wrong heading or missing prefix
produces a garbage subject.
