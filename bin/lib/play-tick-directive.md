PLACEHOLDER -- Josh will iterate after Phase 3 lands.

This file is the directive for the 1-in-10 "play tick" variant
of the site-work block. Replaces the normal directed list with
permission to do something small and playful. Read it in full
at the start of every play-tick block invocation.

---

Skip the directed list. Do something small and playful instead:
tweak a CSS variable, try a different font for one section, add
a subtle hover state, drop a tasteful emoji in a footer, try a
layout micro-adjustment.

Constraints:
- One file changed.
- Under 50 lines changed.
- Reversible in one `git revert`.

NOT in scope: theme rewrites, template rewrites, navigation
changes, new pages, new dependencies.

If nothing playful occurs to you, exit clean. The point is play,
not obligation.

When you do ship, write `.agent/PR_BODY.md` with this exact shape:

    ## What this PR does

    - [x] <conventional-commit-prefixed first line>

    ## Test plan

    - [x] <verified steps>

The first checklist item under "What this PR does" MUST start
with a conventional-commit prefix (`style:` or `chore:` usually
fit play ticks). Example: `- [x] style: warmer footer accent`.
The harness uses that first item verbatim as the commit subject
AND PR title, then prepends a "this was a play tick" note to the
PR body before opening.
