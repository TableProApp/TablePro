---
name: newsletter
description: >-
  Writes the TablePro release newsletter and the matching X posts from the CHANGELOG, in the
  voice the last releases actually shipped in. Use whenever the user asks to draft, write, or
  update a newsletter, release email, "what's new" email, release announcement, launch post,
  or an X / Twitter thread for a TablePro version, including bare requests like "newsletter
  v0.67", "announce 0.67", or "email for the release". It reads [Unreleased] and the repo,
  decides what earns a section and what gets cut, writes the markdown, then runs the fact and
  voice checks that catch the mistakes this has shipped before: claiming a fix for a version
  that never had the bug, announcing a plugin whose binary is not published, and embedding a
  placeholder image. Prefer it over writing the email freehand even for a small release,
  because the checks are the point.
---

# Newsletter

Write the release email TablePro's subscribers actually get, and the X posts that go out with
it. The finished artifact is markdown in the scratchpad, plus a short list of things that have
to be true before it can be sent.

The failure mode this skill exists to prevent is not a boring email. It is a confident,
well-written email that is wrong: it credits a fix to a version that never had the bug, it
tells people to install a plugin that was never published, or it embeds a placeholder card
that says "Screenshot pending". Every one of those has happened. The writing is the easy part.

## The shape of the work

Four passes, in order. Do not start writing before pass 2, because what earns a section is an
editorial decision made against the whole release, not one made a paragraph at a time.

1. **Gather** what is actually in the release.
2. **Decide** what earns a section, what earns a bullet, and what gets cut.
3. **Write** it in the house voice.
4. **Check** it, mechanically and factually, and report the pre-send blockers.

## 1. Gather

Read the release before writing about it.

```bash
grep MARKETING_VERSION Configs/Version.xcconfig                # the version being written about
git tag -l "v*" --sort=-v:refname | head -2                    # the last two app releases
git log --oneline v<previous>..HEAD                            # what landed since
```

Use `git tag -l "v*"`, not `git describe --tags`. Plugin tags share the repository and there are
hundreds of them, so `git describe` almost always answers with something like
`plugin-beancount-v1.0.3` rather than the app release you meant.

The changelog section you read depends on whether the release has been cut yet. Before the
release commit the content sits under `[Unreleased]`; after it, `[Unreleased]` is empty and the
content has moved under the version heading. Check which state you are in, because reading the
empty one silently produces a newsletter about nothing:

```bash
sed -n '/## \[Unreleased\]/,/^## \[0/p' CHANGELOG.md           # pre-release
awk '/^## \[0\.66\.0\]/{f=1;next} /^## \[0/{f=0} f' CHANGELOG.md   # post-release
```

Count the bullets per section on whichever one has the content, so the round-up carries a real
number:

```bash
awk '/^## \[0\.66\.0\]/{f=1;next} /^## \[0/{f=0} f' CHANGELOG.md \
  | awk '/^### /{s=$2} /^- /{c[s]++} END{for (k in c) print k, c[k]}'
```

If the release commit has already landed, diff it against the last pre-release commit. The
finalisation pass often adds entries, and they are the ones nobody has read yet:

```bash
git diff <last-pre-release-commit>..HEAD -- CHANGELOG.md | grep '^+-'
```

For every feature you might give a section to, confirm the docs page exists and note its
published URL, because a section without a link is a section the reader cannot follow up on:

```bash
ls docs/features/ docs/databases/
```

`docs/features/x.mdx` publishes at `https://docs.tablepro.app/features/x`. A section heading
inside a page is an anchor, so Entra ID is
`https://docs.tablepro.app/databases/mssql#microsoft-entra-id`, not a page of its own.

## 2. Decide

The changelog is a record. The newsletter is an argument about what matters. They are not the
same document and the newsletter is much shorter, so most entries do not survive.

Sort every entry into one of three piles.

**Gets a section** when a reader would do something differently because of it: a new feature,
a rebuilt feature they will not recognise, a fix to something they use every day, a new way to
connect. Three to five sections is the usual shape. More than six and nothing stands out.

**Gets a bullet** when it is real and visible but nobody changes their day over it: a moved
control, a corrected menu item, a papercut in the grid. Bullets go in the round-up at the end,
one idea each, one line each.

**Gets cut** when the reader gains nothing by reading it. Be willing to cut a lot. The
recurring cases:

- Anti-piracy and licence enforcement. "Paid features are read from the signed license" tells
  a paying customer you were worried about them, and "a suspended licence now pauses features
  sooner" announces that you cut people off faster. Both stay in the changelog the email links
  to, which is what makes leaving them out editing rather than hiding. Keep the halves that
  help the customer: an activation bug fixed, a status message that now says what went wrong.
- Internal writing cleanup, string changes, translation plumbing.
- Chrome nobody was looking at: a rule removed from under a toolbar, an empty state
  re-centred.
- Fixes so narrow that naming them costs more attention than they return.

Two things that look cuttable and are not. A **rename or a moved menu item** has to be in the
email, or the people who do not read it file "you removed X". A **one-time reset or data
migration** has to be in the email, near the top of its section, with a plain statement of
what is not affected. Burying either one produces support tickets.

## 3. Write

Read `references/voice.md` before writing the first line. It carries the last two shipped
newsletters verbatim plus the checklist derived from them. Match that voice rather than
inventing one: the value of a house voice is that the reader recognises it.

The skeleton, which both shipped newsletters follow:

```markdown
**Subject:** TablePro <version>: <two or three plain items>

**Preview text:** <what the subject did not say>

---

# TablePro <version>

<One sentence naming what the release is about, in different words from the subject.>

Update from **TablePro > Check for Updates**, or [download it here](https://tablepro.app/download).

---

## <Plain statement or plain name>

<Prose. Second person, present tense. Name the old behaviour alongside the new one.>

[<Descriptive phrase> documentation](<verified url>)

---

## Also in <version>

- <One idea, one line, full stop.>

<The count, once.>

[Read the full changelog](https://docs.tablepro.app/changelog)

[Download TablePro](https://tablepro.app/download)
```

**Subject line.** Apple Mail on iPhone shows about 48 characters and Gmail on iOS about 38,
and the sender field already says TablePro, so the first item has to complete inside roughly
40 characters. Two or three items, plain nouns, lowercase after the colon. Every item named in
the subject needs its own section in the body; promising something in the envelope and
delivering it as a bullet is the most common structural failure in drafts of this email.

**Preview text.** 40 to 90 characters, and it should add what the subject left out rather than
restate it. Nothing load-bearing can live only here: on Apple Intelligence devices the
preheader is replaced by a generated summary of the body.

**Sections.** Lead with the new state, then name what it used to do. "Query results are
editable again" before the three sentences of what was broken. State a limit flatly and
without apology when there is one, the way the shipped letters do ("Nothing leaves the Mac",
"Dameng TLS is not supported yet"). Numbers instead of adjectives: "200 rows of history",
"four of the five scopes", not "much faster".

**Images.** One per feature, directly under the heading, before the prose, with alt text that
describes the picture and not the feature. Never illustrate a fix. If no current screenshot
exists, leave a marked placeholder line and say so in the report rather than reaching for a
stale or placeholder file. See the assets check in `references/checks.md` for how to tell.

## 4. Check

Run the mechanical lint first, because it is free:

```bash
python3 .claude/skills/newsletter/scripts/lint-draft.py <draft.md>
```

It flags em dashes, first person, semicolons, banned filler, vague quantifiers, overlong
sentences, "It also" paragraph openers, and subject and preview lengths. Everything it reports
is a real finding in this house style, but it cannot judge whether a sentence is true.

Then work `references/checks.md` top to bottom. It is the factual pass, and it is where the
expensive mistakes get caught: claims that the code does not support, plugin binaries that
were never published, images that are placeholder cards, menu labels the app does not use.

Finish by reporting to the user, separately from the draft:

- **Pre-send blockers**, the things that must be true before this can go out. Plugin tags
  published, screenshots captured, the docs changelog deployed.
- **What you cut and why**, in a sentence each. The user may disagree, and they should be able
  to see the decision rather than notice the absence.
- **Any changelog wording you corrected**, with the evidence. If the changelog says a fix
  restored something and git says it never worked, the changelog is what is wrong.

## X posts

When the user wants the social copy too, read `references/social.md`. Same facts, same voice,
different length rules, and it is written from the finished newsletter rather than from the
changelog so the two cannot disagree.

## Where the files go

Write to the session scratchpad, not the repository. The newsletter is not a tracked artifact:
it goes into the license backend by hand. Name the files by version so several drafts can sit
side by side, for example `newsletter-v0.66.0.md` and `x-posts-v0.66.0.md`.

## Sending

Out of scope here on purpose. If the user asks to send it, tell them the audience trap first:
in the license backend `all` means verified subscribers only, roughly 58 people, and `everyone`
is the real list of roughly 571. The 0.65 newsletter went out to 58 people because of it.
