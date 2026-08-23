# How the TablePro docs are written

The rules a page has to meet. `docs/scripts/check-writing-style.sh` and
`docs/scripts/check-docs-against-source.py` enforce the mechanical half in CI; the rest is here
because no grep can settle it.

Most of this was learned the hard way, from defects that shipped. Where a rule has a scar, the scar
is written down with it. That is deliberate: a rule with a reason survives, and a rule without one
gets argued away.

---

## 1. What the docs are for

A reader arrives with a task and leaves when they can do it. Everything else is cost.

The single most useful test on any sentence: **would the reader do something different if this
sentence were deleted?** If not, delete it.

### The corpus has one origin defect, and it explains most of the rest

These docs grew one feature PR at a time. Each PR appended a paragraph to a page in the same voice
it used for its CHANGELOG entry, and no commit ever rewrote a page whole. `features/tabs.mdx` and
the v0.67.0 release notes still share the same `app.orders` / `staging.orders` sentence.

Release notes answer *what is new*. Docs answer *how do I do this*. They are different genres, and
116 releases regrouped by topic produce exactly the exhaustive, product-centred, focus-free prose
this corpus is being rewritten out of.

**So: when you touch a page, rewrite the section for someone doing a task. Never append a paragraph
describing your change, and never copy a sentence out of the changelog.**

---

## 2. Voice

Write like the developer who built the feature explaining it to the developer about to use it.

- **Second person, imperative.** "Click **Test Connection**." Never "we", never "let's", never
  "users can".
- **Present tense.** "The driver reconnects", not "will reconnect".
- **The product is not the subject.** 409 sentences in this corpus opened `TablePro <verb>`, and 26
  of 33 database pages opened with the same five words. Write from the reader's side, or from the
  thing itself. "Indices are tables, documents are rows" beats "TablePro connects to Elasticsearch".
- **No design rationale.** 464 clauses in this corpus explain *why the app is built this way* to a
  reader who only needs to know what to click.

  > The prefix test: if the clause still reads correctly after you put "we did it this way because"
  > in front of it, cut it.

  ```
  no    With a single tab there is no strip, so a window that behaves the way it
        always did gains no chrome.
  yes   One tab, no strip.
  ```

  Consequence is not rationale. "Value filters run on the rows already loaded, so they cover the
  current page only" is the point of the sentence; keep it.

- **No internals on user-facing pages.** No class names, bundle identifiers, or activity types under
  `features/`, `databases/`, `connections/`, `customization/`. A page once opened with
  `NSUserActivity`. They are fine under `development/` and `external-api/`.
- **Repair a hedge with a measurement.** Not "large results may take some time". Say the number, or
  name the condition.

### Banned

On top of the CLAUDE.md list (seamless, robust, comprehensive, leverage, and the rest):

`simply` · `just` (meaning only) · `easy` · `in order to` · `please note` · `and/or` · `e.g.` ·
`i.e.` · `above` / `below` as document position · `allows you to` · `enables you to` · `lets you` ·
`helps you` · **`you can`**

`you can` is the same sentence with the subject moved. "You can right-click a column header and
choose **Filter with column**" is "Right-click a column header and choose **Filter with column**".

**No em dashes. Anywhere.**

---

## 3. Rhythm, and the trap on the other side of it

Sentence length in this corpus is already healthy: mean 11.8 words, a third under seven. Rhythm is
not the problem and does not need fixing.

**The problem is that every page makes the same move.** That is what "reads like AI" means here, and
it is why the first rewrite pass failed:

> It killed the old formula completely. Zero of 46 pages still opened with the product name. It
> replaced it with a new one: 13 of 46 opened with a numeral, four of those on consecutive database
> pages; six ended on a variant of "there is nothing to install"; three reached for the same
> aphoristic predicate ("is the floor", "is the whole life of the token", "is the way in"); and two
> pages had become the same paragraph with different nouns.

Every one of those collisions was invisible from inside the file being edited and obvious from three
pages away.

> **Check variety across the reading order, not per page.** Before shipping a batch, read its
> openings consecutively, in sidebar order. If two rhyme, rewrite one.

The pass after that one failed the same way in a third costume. Told not to end on "nothing to
install", it moved the negation to the front instead: a third of the batch opened on *no*, *not*,
*never*, *nothing*, or *cannot*. Two adjacent transport pages came out as the same page with
different nouns, down to a byte-identical closing sentence, because two agents wrote them
independently and neither could see the other.

So the rule is not "avoid last time's tic". It is this:

> **If a sibling page already carries the sentence you are about to write, you do not need a
> different wording. You need a snippet.** Rewording a duplicated fact eleven ways is how the corpus
> got eleven templates for "this driver downloads on first use". `docs/snippets/` is where a shared
> fact lives; `registry-plugin.mdx` and `helper-port.mdx` are the two that exist.

Vary the shape deliberately: an imperative, a plain declarative, a constraint, a number, a full
complex sentence. **At most one page in five may open on a sentence fragment.**

---

## 4. Opening a page

Mintlify prints the frontmatter `description` directly under the H1, so the first body sentence must
not restate it. The description is read by someone deciding whether to open the page. The first
sentence is read by someone who already did. **They carry different facts.**

Lead with the entry point, the constraint, or the fact that changes a decision.

```
no    Browse and edit columns, indexes, foreign keys, triggers, and DDL for any table.
      (the description, minus four words)
yes   This is a DDL editor with a grid in front of it. Rename a column, add an index,
      change a key, and what you get is a pending ALTER TABLE you can read before it runs.
```

The model in this corpus is `switching.mdx`: *"Most of a migration is one dialog."* Six words, does
not restate the title, has a point of view.

---

## 5. Structure

| Content | Use |
|---|---|
| Two or more actions in sequence | `<Steps>`. Never a bare numbered list, never numbered headings |
| Parallel items, no order | Bullets, 40 words maximum each |
| Items with three or more properties | A table |
| One item with properties | A sentence |
| A chain of reasoning | Prose. Bulleting an argument hides the causal link |
| Six or more failure modes | H3 per error string |
| Same content, different variant | `<CodeGroup>` or `<Tabs>` |

**A `**Label**:` paragraph is never structure.** 454 lines in this corpus open that way. A label plus
a body is an H3, a table row, or a `<ParamField>`. `databases/postgresql.mdx` had a `## Features`
section built from eight of them, one 620 characters long, and none appeared in the table of
contents, so a reader could not find array editing from the sidebar.

**Never restate a table in prose.** After a table, write only what the table cannot carry.
`features/safe-mode.mdx` had a six-row table followed by six subsections saying "Same as X, but Y".

**Name the default.** Whenever a page enumerates three or more options, one sentence says which one a
normal reader should pick and who should pick differently. Exhaustiveness is not neutrality.

### Headings

Sentence case. Capitals only for acronyms, names with an interior capital (`MySQL`, `PGlite`), and
headings that are literally a control or menu item in the app. `docs/scripts/proper-nouns.txt` holds
the product names whose second word is an ordinary English word: Google **Cloud** SQL, DynamoDB
**Local**.

Stop at H3; Mintlify's table of contents ignores H4. Never write an H1, the frontmatter `title` is
the H1. Never `## Features`: it fitted 17 pages, so it is not a heading.

---

## 6. Page shapes

### A database page

Fixed order for the sections that exist. **Engine-specific H2s are allowed** between
`## Connection URL` and `## Limitations`, and this matters: an earlier draft of this guide froze the
section list, which would have destroyed `beancount.mdx` (Source locations, Includes, BQL) and
`etcd.mdx`, the two best pages in that directory.

```
Quick setup · Connection settings · Connection URL · Authentication · <engine sections> ·
SSL/TLS · Limitations · Troubleshooting · Related
```

Every database page answers all of these, even when the answer is "none". A page missing one fails
review however well it reads.

1. Minimum server version, or "any"
2. Where the driver comes from: bundled, or the registry, with the plugin's exact name
3. Default port, or "no port" and what replaces it
4. Whether the Database field is required to connect
5. Default SSL mode and what it falls back to
6. What a tab bound to a second database does
7. At least one limitation. If an engine genuinely has none, say "No driver-side limits" in one
   line. Never omit the heading

### A limitation

Three slots, fixed order: **what you cannot do, what happens instead, what to do about it.** Never
why.

```
no   Arrays of jsonb, bytea, or composite types keep the plain text editor, since
     their quoting cannot round-trip through a per-element list.
yes  The list editor covers arrays of simple types. jsonb[], bytea[], composite and
     multi-dimensional arrays open the text editor instead: edit the {…} literal directly.
```

### An error entry

The heading is the verbatim string the server or the app produced, casing and punctuation preserved,
variable parts collapsed to `…` inside the original quoting. The body is three lines, in order: what
it means, what to check with the file or setting named, what to change.

Never open with "This error occurs when". The heading is the name.

`**Auth failed**` is not searchable, because PostgreSQL has never emitted that string.
`FATAL: password authentication failed for user "…"` is what the reader has in their clipboard.

### A capability that varies by engine

Asserted in exactly one place: the feature page, as a table, one row per engine, no prose gloss. A
database page states what the capability does on **that** engine and links. It never lists which
other engines have it, because nobody will remember to edit it when the 27th engine gains the
feature.

---

## 7. Naming what is on screen

The shipped `String(localized:)` is the name. One term per element.

| Element | Term | Source |
|---|---|---|
| Filter row area above the grid | filter bar | `ViewMenuBuilder.swift` "Show Filter Bar" |
| Narrow strip on the leading edge | connections strip | `ViewMenuBuilder.swift` "Show Connections" |
| Object list on the left | sidebar | |
| Right pane | inspector | |
| Launch window | welcome window | never "welcome screen" |
| Disabled control | dimmed | never "greyed out" |
| Pointer | pointer | "cursor" is the text insertion point only |

Apple's nouns, not Microsoft's: **pane**, **dialog**, **sidebar**, **inspector**, **menu bar**,
**System Settings**.

Verbs: **click** a button, **choose** a menu item, **select** a row or a checkbox, **press** a key,
**deselect** a checkbox. Never "click on", never "uncheck".

**Menu paths** are one bold run with ` > `: `**File > Import from Other App…**`, never
`**File** > **X**`. Verify the leaf against `TablePro/Core/Menu/*MenuBuilder.swift` every time. Eight
paths were wrong at once because the Database menu shipped and nobody re-checked.

**Shortcuts** in backticks, modifiers spelled out, joined with `+`: `` `Cmd+Option+F` ``. Never bold,
never a glyph. Apple's `Command-K` is deliberately rejected: the app's own menus render `Cmd`.

**Labels** are bold and never in backticks. Drop a trailing ellipsis when instructing
(`Choose **Save as**`), keep it when the label alone is ambiguous (`**Create Connection…**`).

---

## 8. Callouts

By consequence, never by tone. A reader who learns the yellow box and the blue box mean the same
thing stops reading both.

| | Means |
|---|---|
| `<Danger>` | Irreversible. Data loss, dropped objects, corrupted files |
| `<Warning>` | This will fail, cost money, or silently produce wrong output |
| `<Info>` | A support fact: which engines, which versions, which tier |
| `<Note>` | An aside the reader can skip without breaking anything |
| `<Tip>` | An optional shortcut that makes the task faster |
| `<Check>` | What success looks like at the end of a step |

**A callout is never load-bearing.** If deleting it leaves the page wrong, it is not a callout.

Before the reclassification, a `<Note>` carried silent MongoDB round-trip corruption while a
`<Warning>` carried which builds accepted a URL format in 0.38.

---

## 9. Numbers, and the rule that keeps them true

**A number that exists in the source code is owned by exactly one page. Every other page links to
it.** If linking reads badly, the sentence is wrong, not the rule.

Every count contradiction this corpus has shipped came from one fact typed on two pages: the driver
count, the database count, the AI provider count, the Settings tab count, the PluginKit ABI version.

Three claims rot faster than anything else and are checked in CI against the source that defines
them: menu paths, keyboard shortcuts, and the PluginKit ABI. All three were wrong at once in
August 2026.

**Verify before you write, and verify again before you commit.** A rewrite pass that trades a prose
problem for an accuracy problem is strictly worse than doing nothing.

The second half of that rule is about *ordering*, and it is the half that gets skipped. A page
written early in a task states what the code did that morning. A review later in the same branch
changes the code. Nobody re-reads the page, and the branch ships a table that was true when it was
typed. That is how a capability table claimed Redshift, CockroachDB and PGlite had stored
procedures: they are separate driver subclasses, a later commit removed their capability flags, and
the page still carried the row. **Write the page last, or re-check every claim against the source
immediately before you commit.** Capability tables, supported-engine lists and default values rot
fastest. One turned "A filled yellow star marks a favorite" into "Starred
tables turn yellow"; the star turns yellow, not the table. Another asserted the MCP server grants
anonymous read access on stock defaults, which is the exact opposite of what
`MCPCompositeAuthenticator.swift` does, on the page whose entire job is to be trusted.

---

## 10. Images

Alt describes the picture. The caption adds what the prose does not carry. **They may never be
equal**; 21 pairs once were. If you cannot write an alt that differs from the caption, delete the
caption.

Every `<Frame>` holds either zero images or a light and dark pair at identical dimensions:

```mdx
<Frame caption="Sentence case, no trailing period">
  <img className="block dark:hidden" src="/images/name.png" alt="What is actually visible" />
  <img className="hidden dark:block" src="/images/name-dark.png" alt="What is actually visible" />
</Frame>
```

---

## 11. Before you open the pull request

```bash
cd docs
bash scripts/check-writing-style.sh
python3 scripts/check-docs-against-source.py
mint validate
mint broken-links --check-anchors --check-redirects
mint a11y
```

Then the two things no script can do:

1. **Read your batch's openings consecutively.** If two rhyme, rewrite one.
2. **Check every fact you wrote against the source**, not against the page you were editing. The
   page you were editing is where the error came from.

And when you add a check to CI, **test it by reintroducing the bug it exists to catch.** The first
version of the shortcut check joined table rows by title, and the docs word one row differently from
the action name, so it passed green on a live bug. Two of the first three checks were silent.
