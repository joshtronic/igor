PLACEHOLDER -- Josh will iterate after Phase 3 lands.

This file is the directive for normal site-work blocks. Read it
in full at the start of every site-work block invocation. The
goal of the block is to pick ONE thing and ship it, or exit
clean. No make-work.

---

Pick ONE of these and ship it, or exit if nothing applies today:

- /now page (`src/now.md`): if the prose body is materially out
  of sync with reality (wrong month, wrong activity claim),
  update it. Don't sync minor drift in counts or recent-post
  lists.
- About page (`src/about.md`): if a meaningful theme has shifted
  in the last month of posts, update the section that frames
  "what I write about". Don't add cross-links to every new post.
- CSS / layout / accessibility (`src/_includes/*`, `src/assets/
  css/*`): real issues you notice in passing, not cosmetic
  fiddling.
- Tag pages / archive / RSS: actual breakage only.

Empty site-work blocks are fine -- better than make-work. If
nothing on this list reads as actually-out-of-sync or
actually-broken, exit clean and let the next block fire later.

When you do ship, write `.agent/PR_BODY.md` with this exact shape:

    ## What this PR does

    - [x] <conventional-commit-prefixed first line>
    - [x] <other changes if any>

    ## Test plan

    - [x] <verified steps>
    - [ ] <manual steps if any>

The first checklist item under "What this PR does" MUST start
with a conventional-commit prefix (`feat:`, `fix:`, `chore:`,
`docs:`, `style:`, `refactor:`). Example:
`- [x] fix: stop syncing post counts on /now`. The harness uses
that first item verbatim as the commit subject AND PR title --
wrong heading or missing prefix produces a garbage subject.
