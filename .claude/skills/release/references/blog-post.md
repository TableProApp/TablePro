# Blog post

The blog lives in the **marketing site repo**, not this one: `../tablepro-web` by
default, but confirm the path with the user rather than assuming. Every command in
this file runs from that repo's root.

A post is one markdown file in `resources/blog/`. The filename is the slug. Nothing
else registers it: `BlogService::all()` globs the directory and the route constraint
is a generic `[a-z0-9-]+`, so there is no index to edit and no route to add.

For a release post, this is the announcement: the newsletter and the X posts are
written from it afterwards and link to it. It carries the detail, the figures and
the limits, so nothing downstream has to.

Three things are easy to get wrong and all three have been shipped wrong:

1. **Inventing a layout.** The four shipped posts share a shape. Match it.
2. **Leaving the post imageless.** Prose alone does not show a pane. Every post that
   describes UI carries figures, and a missing screenshot is a placeholder to
   replace, never a reason to ship without one.
3. **Forgetting `BlogTest.php`.** It hardcodes the post count and a slug dataset.
   Adding a file turns the suite red.

## 1. Read before writing

```bash
ls resources/blog/
wc -w resources/blog/*.md
grep -n "^## \|^<figure>" resources/blog/*.md
```

Read `mcp-database-claude.md` in full. It is the reference post: it is the only one
with figures, so it is the one that shows the image convention, and its structure is
the house structure.

Shipped posts run **885 to 1,332 words**. A release round-up with six figures can run
longer, to about 1,900. Length follows the content, but a 2,500-word post means you
kept material that belongs in the changelog.

## 2. Frontmatter

Every field below is required except `ogPunchline`, which every shipped post sets
anyway because it is the subtitle on the OG card. `Post.php` is the contract.

```yaml
---
slug: my-post              # must equal the filename
title: A Native Cloudflare D1 Client for Mac
description: One or two sentences. This is the meta description and the card blurb.
date: 2026-05-15           # YYYY-MM-DD, drives ordering, newest first
author: TablePro Team
tags: [cloudflare-d1, sqlite, edge]   # lowercase kebab
ogPunchline: D1 without wrangler. Real GUI on the Mac.
---
```

A `title` containing a colon must be quoted, or YAML reads it as a mapping.

`ogPunchline` is two or three short sentences, no more than about 90 characters, and
it is not the description restated. It is the line someone reads on a shared link.

## 3. The shape

```
intro          two paragraphs, no heading
<figure>       the hero, right after the intro
## section     5 to 8 of these, figures interspersed
## limits      what this does not do, or where the competitor still wins
## closing     how to actually do it in TablePro, or how to get it
```

**The intro carries the problem, not the product.** Every shipped post opens on
something true about the reader's situation and reaches TablePro in the second
paragraph. `mongodb-native-vs-compass` opens on Compass being Electron.
`mcp-database-claude` opens on the protocol existing. Do not open with "TablePro
0.67 adds".

**Headings are plain statements or plain names.** "The Electron tax", "Where the
320 MB goes", "What the AI gets", "When D1 is not the right call". No questions, no
slogans, no gerund-stacked feature names.

**The limits section is not optional.** Every shipped post has one:

| Post | Its honest section |
|---|---|
| `mongodb-native-vs-compass` | Where Compass still wins |
| `cloudflare-d1-mac` | When D1 is not the right call |
| `mcp-database-claude` | When MCP is not the right tool |
| `open-source-db-clients-2026` | What's missing in the space |

It is the section that makes the rest credible. Name real gaps, not disguised
strengths. "Charts draw the loaded rows, not the whole table" is a limit. "Our only
weakness is being too fast" is not.

**The closing section is concrete.** Numbered setup steps, a config snippet, or the
update path. Never a summary of what the reader just read.

## 4. Figures

Raw HTML, not markdown image syntax. The markdown pipeline allows HTML and
`![](...)` gives you no caption.

```html
<figure>
  <img src="/images/blog/mcp-settings-panel.png" alt="TablePro Connect a Client sheet with tabs for Claude Code, Claude Desktop, and Cursor, showing the JSON snippet to paste into the chosen client's config" />
  <figcaption>Connect a Client: pick Claude Code, Claude Desktop, or Cursor and TablePro shows the exact config to paste.</figcaption>
</figure>
```

- Files live in `public/images/blog/`, referenced from `/images/blog/`. They are
  tracked in git.
- **Alt text describes the picture**, in one long specific sentence. Someone who
  cannot see it should know what is on screen, not just which feature it is.
- **Figcaption says what the picture proves.** One sentence, and it may repeat a
  fact from the prose. It is read on its own.
- Roughly one figure per 250 to 350 words. The reference post has 4 in 1,330 words.
- Screenshots are Retina and unpadded: shipped ones are 1440x1176, 1920x1200,
  3024x1722, 3024x1788. There is no fixed size. Do not upscale a small capture.

### When the screenshot does not exist yet

Ship a placeholder that renders and says what to capture, and list the pending files
in your report. Never point an `<img>` at a missing file, and never reuse a stale
shot of a pane that has since changed.

Chromium has to be present for any rendering:

```bash
npx puppeteer browsers install chrome-headless-shell
```

Render placeholders at 2400x1500 with Browsershot. Put the file path on the card so
whoever captures the real shot knows what to overwrite:

```php
Browsershot::html($html)->windowSize(2400, 1500)->setScreenshotType('png')
    ->save(public_path('images/blog/' . $name . '.png'));
```

The real screenshot replaces the file at the same path, so the post needs no edit.

A screenshot that already exists in the docs repo can be copied rather than
re-captured, but rename it to the blog's own scheme (`<area>-<thing>.png`, as in
`sql-editor-code-folding.png`) instead of carrying the docs name over.

## 5. Voice

Derived from the shipped posts, not invented.

- Second person, present tense. Contractions are fine here, unlike the app's
  changelog.
- **No em dashes.** Three of four shipped posts have zero.
- No filler: seamless, robust, comprehensive, intuitive, effortless, streamlined,
  leverage, elevate, unlock, supercharge, delve, utilize, game-changer.
- Numbers instead of adjectives. "400 MB at idle", "2,000 points", "three round
  trips". Never "much faster".
- Backticks on shortcuts, SQL keywords, identifiers, paths and config keys.
- Bold for menu paths: `**Settings > Integrations**`.
- Tables for genuinely tabular things (shortcut lists, per-client paths, a cost
  breakdown). Two per post is plenty; three means one of them is prose.
- Say the limit flatly and without apology. "The file on disk is left exactly as it
  was." "It never silently truncates."
- Never claim a competitor is bad. Say what it costs and let the reader decide.

Check yourself:

```bash
grep -nE '—|seamless|robust|comprehensive|intuitive|effortless|streamlined|leverage|elevate|delve|utilize|game-changer' resources/blog/<slug>.md
```

## 6. Facts

The blog is indexed and quoted, so a wrong number outlives the release.

- **Tier claims** come from `TablePro/Models/Settings/ProFeature.swift` in the app
  repo, not from a docs table. `requiredTier` returns the *lowest* tier that unlocks
  a feature and Team includes Starter, so write "needs a license, and both tiers
  include it" rather than naming one tier.
- **Menu labels** come from the app's menu builders, not from the docs, which
  paraphrase.
- **Thresholds and defaults**: quote the number that decides the behaviour or quote
  none.
- **A feature that lives in a registry plugin** is not usable until that plugin's
  tag is published and the registry carries it. Check before you write the sentence:

  ```bash
  curl -s https://raw.githubusercontent.com/TableProApp/plugins/main/plugins.json
  ```

## 7. Wire it up

Adding the file is not enough. Three things follow.

**Update the test.** `tests/Feature/Landing/BlogTest.php` hardcodes the count and the
slug dataset:

```php
->has('posts', 5),          // bump this
dataset('blogSlugs', [
    'my-new-slug',          // add this
    ...
```

**Render the OG card.** It is tracked in git alongside the four existing ones.

```bash
php artisan og:generate --type=blog --slug=<slug>
```

Open the result and look at it. A too-long title wraps to three lines and can push
the punchline off the card.

**Sitemap needs nothing.** `public/sitemap.xml` is gitignored and regenerated on
deploy. Run `php artisan sitemap:generate` only to verify the URL appears.

## 8. Verify

```bash
php artisan test --compact                  # whole suite, not just BlogTest
vendor/bin/pint --dirty --format agent      # after any PHP edit
```

Then confirm the post actually parsed, because bad frontmatter fails quietly:

```bash
php artisan tinker --execute="
\$p = app(App\Services\Blog\BlogService::class)->find('<slug>');
echo \$p->wordCount.' words, '.\$p->readingMinutes.\" min\n\";
echo substr_count(\$p->bodyHtml, '<figure>').\" figures\n\";
"
```

And confirm every referenced image is on disk:

```bash
grep -o 'src="/images/blog/[^"]*"' resources/blog/<slug>.md \
  | sed 's|src="/||;s|"||' \
  | while read -r f; do [ -f "public/$f" ] && echo "OK $f" || echo "MISSING $f"; done
```

## 9. Before it goes live

`main` self-deploys on green tests. Pushing publishes the post.

For a release post that says "download it" or "check for updates", the build has to
exist first. A pushed tag is not a build:

```bash
gh release view v<version> --json tagName,assets -q '"\(.tagName) assets=\(.assets|length)"'
```

If the post tells readers to update a registry plugin, that plugin has to be
published too. Report both as blockers rather than pushing and hoping the release
lands first.
