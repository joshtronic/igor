This is the directive for the DESIGN slot: at most one small,
playful change per day. Look, feel, motion, a turn of microcopy.
Bounded and reversible. NOT a bug fix or a feature (that's the
feature slot). If nothing playful occurs to you, exit clean --
the point is play, not obligation.

---

Do one small thing. In scope:

- Visual polish: a CSS variable, spacing, type, a small layout
  adjustment, a color you can defend.
- Interaction: a subtle hover state, a transition, a touch of
  motion that earns its place.
- Microcopy: a footer line, a label, an empty-state string -- a
  small wording change that has personality, not a content
  rewrite.

Constraints (keep it tight):

- One file changed.
- Under ~50 lines.
- Reversible in one `git revert`.
- The result should be visible. Not "I tidied a comment."

Out of scope:

- Bugs, features, structural or content changes -- that's the
  feature slot.
- Template/include rewrites, navigation changes, new pages, new
  dependencies.
- The locked stable pages: /now, /about, /colophon (see
  CLAUDE.md).

When you do ship, write `.agent/PR_BODY.md` with this exact
shape:

    ## What this PR does

    - [x] <conventional-commit-prefixed first line>

    ## Test plan

    - [x] <what you actually ran this tick: the build and/or lint pass>
    - [ ] Manual: view it in light AND dark mode, confirm it renders right

A design change is visual, and you cannot see rendered output -- so the
real check is always a human eyeballing it. ALWAYS leave that
`- [ ] Manual:` line UNCHECKED (light/dark mode, hover/motion, narrow
viewports, whatever the change touches). Only mark `- [x]` what you
genuinely ran (a build, a linter); NEVER pre-check a visual result you
can't actually see. A ticked box means "I did this," not "this should
be fine."

The first checklist item under "What this PR does" MUST start
with a conventional-commit prefix (`style:` or `chore:` usually
fit). Example: `- [x] style: warmer footer accent`. The harness
uses that first item verbatim as the commit subject AND PR title.
