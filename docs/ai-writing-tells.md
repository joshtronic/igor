# AI writing tells

A working catalogue of the patterns that make prose read as
machine-written, compiled from the sources at the bottom. This is the
recall artifact: it can be exhaustive because nothing here is loaded
into a prompt. The curated, prompt-facing subset lives in the `## Bans`
section of the `voice` skill, sourced live from the Distillery
(`joshtronic/distillery`) -- when you change one, glance at the other.

It's a living doc. Add tells as you find them, and add the source. The
era note under Sources matters: the giveaway vocabulary shifts as models
change, so a tell that's loud today goes quiet in a year and a new one
takes its place.

Scope is filtered to first-person notebook and site prose, which is all
Igor writes. The Wikipedia-markup and SEO/crypto buckets are dropped on
purpose; see "Out of scope" near the end.

The one throughline behind nearly all of it, and the rule already in
the `voice` skill: **prefer the specific over the vague. If a sentence
still works after you delete a clause, the clause was filler -- name
the thing, cite the number, or cut it.**

Source tags in parentheses: `smells` = shvbsle.in, `bron` = Bronsdon's
SKILL.md, `wiki` = Wikipedia. Multiple tags mean the sources agree, which
is a decent proxy for how strong a tell is.

## Vocabulary

Words that show up far more in machine text than in anyone's natural
writing. Use the plain word.

Kill on sight (all three sources converge on most of these):

    delve / delve into     -> look at, dig into
    leverage (verb)        -> use
    utilize                -> use
    robust                 -> strong, reliable
    seamless / seamlessly  -> smooth, without friction
    comprehensive          -> thorough, full
    pivotal                -> key, central
    crucial                -> important, necessary
    landscape (metaphor)   -> field, space
    realm                  -> area, field
    tapestry               -> name the actual complexity
    testament to           -> shows, proves
    underscores            -> shows, highlights
    showcasing             -> showing
    game-changer           -> say what specifically changed
    meticulous(ly)         -> careful, precise
    ever-evolving          -> changing (say how)
    deep dive              -> just dive in, or cut

Watch-list -- fine in isolation, a tell when two or more cluster in a
paragraph (bron groups these as tiers; the split is theirs):

    foster, elevate, streamline, navigate, harness, empower, bolster,
    facilitate, catalyze, cultivate, resonate (with), myriad, plethora,
    intricate / intricacies, holistic, actionable, learnings, nuanced,
    ecosystem (metaphor), nestled, vibrant, thriving, burgeoning,
    significant(ly), innovative, compelling, sophisticated

Each has a plain replacement: `foster` -> encourage; `streamline` ->
simplify; `navigate` -> work through; `resonate with` -> connect with;
`myriad`/`plethora` -> many (give the number); `learnings` -> lessons;
`actionable` -> practical; `holistic` -> whole. (bron, wiki)

## Sentence shape

- **Negative parallelism.** "It's not X, it's Y" and "not only X but
  also Y." State the positive directly. Example: "Kusama's self-portrait
  is not a mirror but a portal." (all three)
- **Rule of three.** Three parallel items, three adjectives, three short
  clauses, because the cadence feels finished: "fast, cheap, and
  reliable." Use two, or four, or a sentence. (all three)
- **Copula-dodging.** Reaching for "serves as," "stands as," "features,"
  "boasts," "represents," "offers" where plain "is" or "has" would do.
  Example: "is LAAA's exhibition arm" rewritten as "serves as LAAA's
  exhibition space." Default to is/has unless a stronger verb earns its
  place. (bron, wiki)
- **Hedge stacks.** Two hedges where one would do: "could potentially,"
  "may eventually," "might ultimately transform." Pick one hedge or
  commit to the claim. (smells, bron)
- **Hollow / real intensifiers.** "genuine," "truly," "real," "actual"
  bolted onto an abstract noun with no contrast named: "a genuine
  improvement," "real utility." Drop the intensifier and add a specific
  claim. (smells, bron)

## Significance inflation

The strongest single signal on Wikipedia, and worth its own heading.

- Stock phrases that announce importance the prose hasn't earned:
  "marking a pivotal moment in the evolution of," "stands as a testament
  to," "underscores the importance of," "a key turning point," "setting
  the stage for." State what happened; let the reader judge the weight.
  (wiki, bron)
- **Superficial `-ing` analysis.** A present-participle phrase tacked
  onto a sentence end to simulate insight: "showcasing a new era,"
  "reflecting decades of investment," "highlighting the importance of,"
  "symbolizing the region's commitment." Replace with a fact or cut.
  (all three)
- **Promotional / travel-brochure tone** even when the subject is dry:
  "nestled in the heart of," "a vibrant hub," "a thriving ecosystem."
  Plain description instead: location, number, fact. (wiki, bron)
- **Outline-shaped concessions.** "Despite its many strengths, X faces
  challenges typical of..." Name the actual challenge and the actual
  response, or drop it. (wiki, bron)

## Throat-clearing and framing

Words and moves that tell the reader how to feel instead of giving them
something to feel it about.

- **Confidence-calibration adverbs.** "Notably," "Interestingly,"
  "Importantly," "Surprisingly," "It's worth noting that." More than one
  per few hundred words is the tell. Cut them; let the fact land. (bron)
- **Transition openers.** "Moreover," "Furthermore," "Additionally"
  (especially starting a sentence). Use "and"/"also" or restructure so
  the connection is real. (bron, wiki)
- **Rhetorical-question section openers.** "But what does this mean?",
  "So why should you care?", "What's next?" used as transitions. Just
  state the answer. (bron)
- **Engagement-hook fragments.** "The catch?", "Here's the thing.",
  "Plot twist:", "But here's the kicker:". They delay the point to
  manufacture suspense. Delete the hook, keep the point. (bron)
- **Filler openers and closers.** "Let's dive in," "Here's what's
  interesting," "In conclusion," "The future looks bright," "Only time
  will tell," "At the end of the day." Open on the point; stop when
  done. (all three)

## Rhythm and density

The structural tells. Harder to catch by word-search, easier to feel.

- **Length uniformity.** Every sentence 15-25 words, every paragraph
  3-5 sentences of similar size. Real writing varies: short fragments
  next to long flowing ones. (bron, smells)
- **Consecutive short declaratives for effect.** "Yet the tilt is not an
  accident. It is the shape of the optimum." A little goes a long way;
  in bulk it reads as a machine reaching for gravitas. (smells)
- **Too many punchlines.** A quotable, symmetrical one-liner closing
  every paragraph: "Symmetry becomes a trap." One earned line is fine;
  one per paragraph is a pattern. (smells)
- **The treadmill (low information density).** Each paragraph restates
  the premise in fresh words instead of advancing. Test: could you cut
  40-60% with no loss? Then it's throat-clearing. Name the one new fact
  per paragraph and lead with it. (bron)
- **Reshuffle immunity.** If paragraphs can swap order without breaking
  the piece, there's no through-line. Each should build on the last.
  (bron)
- **Synonym cycling / elegant variation.** The same thing renamed to
  avoid repetition: "developers... engineers... practitioners...
  builders" in one paragraph. Repeat the clearest word. (bron, wiki)

## Mechanical

The deterministic stuff -- a search-and-replace could catch most of it.

- **Em-dashes.** Both the unicode em-dash and the `--` double-hyphen,
  used to glue clauses. Use a comma, a period, or two sentences. (all
  three)
- **Emoji** anywhere, and especially in headings. (bron, wiki)
- **Curly quotes and smart apostrophes.** The unicode left/right quotes
  and apostrophe in plain-text or markdown contexts. Straight quotes
  only. (bron, wiki)
- **Vague attributions.** "Experts say," "studies show," "research
  suggests," "observers note" with no source named. Cite the specific
  source or drop the claim. (bron, wiki)
- **Title Case In Headings.** Sentence case instead. (bron, wiki)

Credibility-killers -- rare in Igor's output but fatal if they leak, so
they're worth knowing:

- **Citation-markup leaks** from chatbot exports: `oai_citation`,
  `contentReference`, `citeturn0search0`, `grok_card`. Strip every
  token. (bron, wiki)
- **AI-tool URL parameters** on cited links: `utm_source=chatgpt.com`,
  `utm_source=claude.ai`, `utm_source=copilot.com`. Strip the
  parameter, keep the URL. (bron, wiki)
- **Unfilled placeholders:** `[Your Name]`, `[INSERT SOURCE]`,
  `2025-XX-XX`, leftover "TODO" comments. Fill or delete. (bron, wiki)

## Out of scope

Two buckets from the sources are deliberately left out, because Igor
writes a personal notebook and a small static site, not encyclopedia
articles or marketing copy. They're noted here so they're recallable,
not detailed:

- **Wikipedia-specific:** wikitext-vs-markdown markup errors, malformed
  DOIs/ISBNs, non-existent categories and templates, AfC submission
  statements, talk-page good-faith boilerplate. (wiki)
- **SEO / crypto / social:** hashtag stuffing, notability name-dropping
  ("featured in NYT, BBC, Wired"), investor-post tropes, bullet lists of
  bare adjective-noun feature claims. (bron)

If Igor's surfaces ever grow toward either, pull the relevant tells back
in.

## Sources

Three sources, three angles. Accessed 2026-05-28.

**Various LLM smells** -- <https://shvbsle.in/various-llm-smells/>
(`smells`). A writer's-eye field guide, strongest on rhythm and the
"feel" tells that resist word-search: punchline stacking, consecutive
short declaratives, the "X is the Y of Z" construction. Thin on a
vocabulary list; rich on cadence. Also covers AI-generated *website*
tells (JetBrains Mono, card layouts, blinking-dot badges) -- not folded
in here but a fun read if the site ever feels generic.

**Avoid AI writing (Bronsdon)** --
<https://github.com/conorbronsdon/avoid-ai-writing/blob/main/SKILL.md>
(`bron`). The most operational of the three: a tiered word/phrase ban
list (Tier 1 always-replace, Tier 2 flag-in-clusters, Tier 3
flag-at-density) with plain-word replacements and before/after fixes,
plus P0/P1/P2 priority buckets. This is the one to mine when you want a
concrete replacement for a word. Built as a Claude skill, so its framing
maps cleanly onto our use.

**Wikipedia: Signs of AI writing** --
<https://en.wikipedia.org/wiki/Wikipedia:Signs_of_AI_writing> (`wiki`).
The most exhaustive and the most carefully sourced, since it's a
maintained community page. Strongest on significance inflation,
promotional tone, and vague attribution. Crucially, it tracks how the
giveaway vocabulary **shifts by model era** (a 2023 list, a mid-2024
list, a mid-2025 list) -- the reminder that this whole catalogue has a
shelf life and needs revisiting.
