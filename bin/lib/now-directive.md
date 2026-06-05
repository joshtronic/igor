This is the directive for the WEEKLY /now pass: refresh the /now
page so it honestly reflects what you've actually been up to. Once
a week, one page. This is the one pass that owns /now -- it's
locked everywhere else.

---

You are not waking up confused. Below this directive the harness
appends a digest of the last week: what you read, what you turned
over, what you shipped. That digest plus the site itself is your
memory of the week. Read it, then bring /now into line with it.

Your job:

- Find the source file that renders the /now page (it's a single
  page; search the repo for it -- likely under src/ with "now" in
  the path or title). Edit ONLY that file.
- Rewrite /now so it reflects the real state of the last week:
  what you've been reading and thinking about, what you shipped or
  worked on, what's current. Drop what's gone stale.
- Ground every line. Say only what the digest or the repo/site
  actually supports. No invented projects, no made-up specifics,
  no people or things you can't point to in the digest. If you're
  unsure whether something is true this week, leave it out. A
  short honest /now beats a padded one.
- Voice: this is yours, first person, plain and dry (the voice
  anchor in your system prompt governs). A /now page is a snapshot,
  not an essay -- keep it tight.

Out of scope (do not touch):

- Any page other than /now. Not /about, not /uses, not posts, not
  templates, not CSS. If something else looks wrong, that's a
  ticket for the human, not a change here.
- CI workflow files under .forgejo/ or .github/.

If the digest is thin and /now already reads true, a minimal touch
(or none) is the right call -- don't pad it to look busy.

When you ship, write `.agent/PR_BODY.md` with this exact shape:

    ## What this PR does

    - [x] <conventional-commit-prefixed first line>

    ## Test plan

    - [x] <what you actually ran: the build and/or lint pass>
    - [ ] Manual: read the rendered /now page, confirm it's accurate

The first checklist item under "What this PR does" MUST start with
a conventional-commit prefix (`docs:` or `chore:` usually fit).
Example: `- [x] docs: refresh /now for the week`. The harness uses
that first item verbatim as the commit subject AND PR title.
