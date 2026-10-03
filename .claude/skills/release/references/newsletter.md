# Newsletter and X posts

Both are short and both point at the blog post, which is the announcement. Write them from the
finished post, not from the changelog, so the three cannot disagree.

## The newsletter

**150 to 250 words**, one phone screen. It says a version exists, names the headline items one line
each, and links the post.

```markdown
**Subject:** TablePro <version>: <two or three plain items>

**Preview text:** <what the subject did not say>

---

# TablePro <version>

<One sentence naming what the release is about, in different words from the subject.>

- **<Feature>**: <one line, what it does for you.>
- **<Feature>**: <one line.>
- **<Feature>**: <one line.>

<One line on the rest: the fix count, or the one breaking change.>

[Read the full post](<blog post url>)

Update from **TablePro > Check for Updates**, or [download it](https://tablepro.app/download).
```

- **The bullets are the whole body**: three to five, matching the post's sections in the same order.
  No headings, images or tables. A bullet that needs a second sentence belongs in the post.
- **Put these in the mail itself**, because the readers who do not click are the ones they hurt: a
  breaking change or removal, and a one-time reset or migration with what it does not affect.
- **Subject**: `TablePro <version>: ` plus two or three plain items, lowercase after the colon, comma
  separated, no adjectives. The sender already says TablePro and Gmail on iOS cuts near 40
  characters, so the first item has to finish inside that. Every item in the subject is a bullet.
- **Preview text**: 40 to 90 characters that add what the subject left out. Nothing load-bearing
  lives only here, because Apple Intelligence can replace it with a generated summary.

## The X posts

A thread of **four to six posts** plus one standalone, one headline feature per post in the blog
post's order.

- **280 characters at most**, and a post needing 279 is too dense. Two short paragraphs.
- **No markdown**: X renders none of it.
- **Links only in the last post**, which carries the round-up and the link. An earlier link costs
  reach.
- **One image per post at most**, named in the post header so whoever posts it knows what to
  attach, and only images that exist and are current.
- **The first post works alone**: the version and the biggest change in its first two lines.
- **The standalone post** is the version, three or four changes in plain nouns, then the link. It is
  the one that gets reposted, so it needs no context.
- No thread hooks ("a thread", "here's why this matters"), no engagement bait, no emoji, no "and
  much more".

```markdown
## 1/5 (attach: <image file, or omit>)

TablePro 0.77 is out.

<The headline change, two sentences.>

## 5/5

Also in 0.77: <three or four items, comma separated>

Full post: <blog post url>
Download: https://tablepro.app/download
```

## Voice

Each rule is a yes or no against the draft, and a no is a rewrite.

1. The opener names what the release is about in different words from the subject.
2. No first person: the subject of a sentence is the product, the feature, or "you".
3. Nothing tells the reader what is worth their time or how they will feel ("fixes you will
   notice").
4. No em dashes, semicolons, exclamation marks or emoji, and no banned words
   (`scripts/banned-words.txt`).
5. Figures instead of vague quantifiers: "more than 130 other fixes", not "many" or "significantly".
6. No prose sentence over 35 words. An enumeration after a colon may run longer.
7. Name the old behavior beside the new one where it fits in one line, and vary the form ("instead
   of", "used to", "no longer").
8. Second person, present tense, active voice. No "will now", no "has been improved", no paragraph
   opening with "It also".
9. Backticks on every shortcut, SQL keyword, type name and literal (`Cmd+F`, `EXPLAIN ANALYZE`), at
   most about eight in a sentence. Bold for menu paths and the first mention of a new proper noun,
   not for run-in headlines.
10. US spelling (color, behavior), the same as the docs, whose `docs/scripts/check-writing-style.sh`
    rejects British spelling, and as the app's own strings.

Run the lint before reading for facts:

```bash
python3 .claude/skills/release/scripts/lint-draft.py <draft.md>
```

It checks rules 2, 4, 5, 6 and 10, the common phrases behind rule 3, the "It also" opener, and the
subject and preview budgets, and it resolves every docs link and image. Whether a sentence is true is
`fact-checks.md`.
