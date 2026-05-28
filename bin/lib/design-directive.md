PLACEHOLDER -- Josh will iterate on this directive over time.

This file is the directive for the DESIGN slot: one piece of
small, playful site work per day. CSS polish, layout
micro-adjustments, a tasteful detail. Bounded and reversible.
NOT a bug fix or new feature (that's the feature slot).

---

Do something small and playful: tweak a CSS variable, try a
different font for one section, add a subtle hover state, drop
a tasteful emoji in a footer, try a layout micro-adjustment.

Constraints:

- One file changed.
- Under 50 lines changed.
- Reversible in one `git revert`.
- The result should be visible -- not "I cleaned up a comment".

NOT in scope:

- Bug fixes, new features, structural changes (that's the
  feature slot).
- Theme rewrites, template rewrites, navigation changes, new
  pages, new dependencies.
- Touching /now, /about, or /colophon (locked stable pages --
  see CLAUDE.md).

If nothing playful occurs to you, exit clean. The point is
play, not obligation.

When you do ship, write `.agent/PR_BODY.md` with this exact
shape:

    ## What this PR does

    - [x] <conventional-commit-prefixed first line>

    ## Test plan

    - [x] <verified steps>

The first checklist item under "What this PR does" MUST start
with a conventional-commit prefix (`style:` or `chore:` usually
fit). Example: `- [x] style: warmer footer accent`. The harness
uses that first item verbatim as the commit subject AND PR
title.
