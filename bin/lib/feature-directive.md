PLACEHOLDER -- Josh will iterate on this directive over time.

This file is the directive for the FEATURE slot: one piece of
non-trivial site work per day. Bug fix, new feature, content
restructure, accessibility fix, real breakage. NOT design
polish (that's the design slot).

The goal of the block is to pick ONE substantive thing and ship
it, or exit clean. No make-work.

---

Pick ONE of these and ship it, or exit if nothing fits today:

- A real bug somewhere on the site (broken link, broken layout
  in a specific browser, RSS validation failure, build warning
  you can trace to a root cause).
- A new small feature (a footer link the site should have, a
  data attribute that improves something downstream, a script
  hook that makes future ticks cheaper).
- A content restructure that needs more than a paragraph
  rewrite -- e.g. splitting a sprawling page, consolidating
  duplicated copy across pages.
- A meaningful theme drift in /about: if a section that frames
  "what I write about" is genuinely out of date with the last
  month of posts, reshape it. (Don't enumerate posts.)

NOT in scope here (those are the design slot or a separate
ticket entirely):

- Cosmetic CSS tweaks, color swaps, font experiments
- Hover states, micro-animations, layout polish
- The /now or /colophon pages -- those are locked stable pages
  (see CLAUDE.md)

If nothing on this list reads as a genuinely needed change,
exit clean. The design slot still fires later today.

When you do ship, write `.agent/PR_BODY.md` with this exact
shape:

    ## What this PR does

    - [x] <conventional-commit-prefixed first line>
    - [x] <other changes if any>

    ## Test plan

    - [x] <verified steps>
    - [ ] <manual steps if any>

The first checklist item under "What this PR does" MUST start
with a conventional-commit prefix (`feat:`, `fix:`, `chore:`,
`docs:`, `style:`, `refactor:`). Example:
`- [x] fix: broken RSS validation on the feed root`. The
harness uses that first item verbatim as the commit subject AND
PR title -- wrong heading or missing prefix produces a garbage
subject.
