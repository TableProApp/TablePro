# Newsletter and X posts

Both are short and both point at the blog post. The blog post is the announcement;
these two are distribution. Write them **from the finished blog post**, not from the
changelog, so the three cannot disagree.

## The newsletter

**150 to 250 words.** One screen on a phone. It says a version exists, names the
headline items one line each, and links the post.

```markdown
**Subject:** TablePro <version>: <two or three plain items>

**Preview text:** <what the subject did not say>

---

# TablePro <version>

<One sentence naming what the release is about, in different words from the subject.>

- **<Feature>**: <one line, what it does for you.>
- **<Feature>**: <one line.>
- **<Feature>**: <one line.>

<One line on the scale of the rest: the fix count, or the one breaking change.>

[Read the full post](<blog post url>)

Update from **TablePro > Check for Updates**, or [download it](https://tablepro.app/download).
```

The bullets are the only body. Three to five of them, matching the blog post's
sections and in the same order. No section headings, no images, no tables. If a
bullet needs a second sentence to make sense, the blog post is where that sentence
goes.

Two things must appear in the mail itself rather than only behind the link, because
the people who do not click are exactly the ones they hurt:

- **A breaking change or a removal.** "MCP remote access is gone" cannot be a
  surprise discovered after upgrading.
- **A one-time reset or migration.** State plainly what is not affected.

**Subject line.** Apple Mail on iPhone shows about 48 characters and Gmail on iOS
about 38, and the sender already says TablePro, so the first item has to complete
inside roughly 40 characters. Two or three items, plain nouns, lowercase after the
colon. Every item named in the subject has to be one of the bullets.

**Preview text.** 40 to 90 characters, adding what the subject left out rather than
restating it. Nothing load-bearing lives only here: on Apple Intelligence devices the
preheader is replaced by a generated summary.

## The X posts

A thread of **four to six posts** plus one standalone. One headline feature per post,
in the blog post's order, and the last post carries the link.

- **280 characters per post**, and a post needing 279 is too dense. Two short
  paragraphs with a blank line between.
- **No markdown.** X renders none of it. Write `Cmd+Shift+O` as Cmd+Shift+O.
- **Links only in the last post.** A link earlier costs reach.
- **One image per post at most**, named in the post header so whoever posts it knows
  what to attach. Only images that exist and are current.
- **The first post has to work alone**, because most people see only that one. Name
  the version and the single biggest change in the first two lines.

```markdown
## 1/5 (attach: <image file, or omit>)

TablePro 0.67 is out.

<The headline change, two sentences.>

## 2/5

<Next feature, compressed.>
```

Close with the round-up and the link:

```
Also in 0.67: <three or four items, comma separated>

Full post: <blog post url>
Download: https://tablepro.app/download
```

The standalone post is version, three or four changes in plain nouns, then the link.
This is the one that gets reposted, so it has to survive with no context around it.

No thread hooks ("a thread 🧵", "here's why this matters"), no engagement bait, no
emoji as decoration, no "and much more". The audience is developers who can tell.

## Voice

Testable against a draft. A "no" is a rewrite, not a note.

**Framing**

1. Subject is `TablePro <version>: ` plus two or three plain items, lowercase after
   the colon, comma separated, no adjectives.
2. Every item named in the subject appears as a bullet. Nothing promised in the
   envelope is missing from the body.
3. The opener is one sentence naming what the release is about, in different words
   from the subject, so the second line adds something.
4. No first person. The subject of a sentence is the product, the feature, or "you".
   Grep for `\bwe\b|\bour\b|\bus\b`.
5. Nothing tells the reader what is worth their time or how they will feel. "Three
   things worth your time" and "fixes you will notice" both fail.

**Sentences**

6. No em dash. Use a comma, a period, a colon, or rewrite.
7. No semicolons, no exclamation marks, no emoji.
8. No filler: seamless, robust, comprehensive, intuitive, effortless, powerful,
   streamlined, leverage, elevate, unlock, unleash, supercharge, delve, utilize,
   facilitate, game-changer.
9. Vague quantifiers get replaced by figures. "More than 130 other fixes", "four of
   the five scopes". Not "many", "several", "significantly", "much faster".
10. No prose sentence over 35 words. An enumeration after a colon may run longer.
11. Name the old behaviour alongside the new one where it fits in one line. Vary the
    form: "instead of", "used to", "no longer". Eight "instead of" clauses in one
    letter is a tic.
12. Second person, present tense, active. No "will now", no "has been improved".
13. No paragraph opens with "It also".

**Typography**

14. Backticks on every shortcut, SQL keyword, type name and literal: `Cmd+F`,
    `EXPLAIN ANALYZE`. Keep it under about eight backticked tokens in a sentence.
15. Bold for menu paths (`**Database > Query Insights**`) and the first mention of a
    new proper noun. Not for run-in paragraph headlines.
16. British spelling in prose (colour, behaviour, honours) but the product's own
    words for product things: the app says "license", so the email says "license".

Run the lint before reading for facts:

```bash
python3 .claude/skills/release/scripts/lint-draft.py <draft.md>
```

It flags em dashes, first person, semicolons, banned filler, vague quantifiers,
overlong sentences, "It also" openers, and subject and preview lengths. Everything it
reports is a real finding. It cannot judge whether a sentence is true; that is
`fact-checks.md`.

## Reference: the shape this replaced

The 0.65 newsletter ran about 1,030 words across eight sections with images and its
own Security list. **That is now the blog post's job.** Do not reach for that shape
here again; a reader who wants it should be one click away, not scrolling it in mail.

The 0.64 letter is closer to the target, and it is worth reading for tone:

```
SUBJECT: TablePro 0.64: one click between every open connection

## TablePro 0.64 is out

Update from **TablePro > Check for Updates**, or download it below.

[Download TablePro 0.64](https://tablepro.app/download)

---

### Every connection you have open, one click away

TablePro 0.64 adds the **workspace rail**: a strip on the leading edge of the window
that lists every connection and database you have open. Switching takes one click,
instead of a trip back through the connection list or the database picker.

Each icon is the database engine's symbol, tinted with the connection's color, so
staging and production are easy to tell apart. The icon changes shape when a session
fails or drops, so a dead connection is visible without hovering.

An entry appears when you open a connection, or when you switch database and leave
work behind in the one you came from. It goes away when its last tab closes. Nothing
is closed for you.

---

### Also in 0.64

- Each connection gets its own window, and a tab stays bound to the database it was
  opened on.
- The menu bar is rebuilt on native macOS menus, with a new Database menu.
- Oracle SYSDBA and SYSOPER logons, and Oracle in TablePro Mobile.
- Sparkle updated to 2.9.5, patching CVE-2026-47121 and CVE-2026-47122.

[Read the full changelog](https://docs.tablepro.app/changelog)
```

Note what it does: flat headings, the old behaviour beside the new one, real numbers,
a short flat closer ("Nothing is closed for you"), and no adjectives selling
anything. Keep all of that. The only change is that the long middle now lives in the
blog post, and the last link points there instead of straight at the changelog.
