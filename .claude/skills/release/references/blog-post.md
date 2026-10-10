# Blog post

The blog lives in the marketing site repo, `../tablepro-web` by default; confirm the path with the
user. Every command here runs from that repo's root.

A post is one markdown file, `resources/blog/<slug>.md`. Nothing else registers it: `BlogService`
globs the directory and the route takes any `[a-z0-9-]+`, so there is no index or route to edit. For
a release, the post carries the detail, the figures and the limits, and the newsletter and X posts
are written from it.

The three usual mistakes: inventing a layout instead of matching the shipped posts, leaving out
figures, and forgetting `tests/Feature/Landing/BlogTest.php`, which hardcodes the post count.

## 1. Read first

```bash
ls resources/blog/
grep -n "^## \|^<figure>" resources/blog/*.md
```

Read the newest `tablepro-0-*.md` release post and `mcp-database-claude.md` in full: together they
show the house structure and the figure convention. Aim for about 1,000 words of prose
(`lint-draft.py --blog` prints the count without figures). If it runs long, cut sections to bullets,
not adjectives.

## 2. Frontmatter

`app/Services/Blog/Post.php` is the contract. Every field is required; `ogPunchline` is optional in
code but every post sets it, because it is the subtitle on the OG card.

```yaml
---
slug: tablepro-0-77        # equals the filename
title: "TablePro 0.77: Charts for Every Result"   # quote a title with a colon
description: One or two sentences. The meta description and the card blurb.
date: 2026-10-15           # YYYY-MM-DD, newest first
author: TablePro Team
tags: [release, charts]    # lowercase kebab
ogPunchline: Two or three short sentences, under about 90 characters.
---
```

`ogPunchline` is the line someone reads on a shared link, not the description restated.

## 3. Shape

```
intro          two paragraphs, no heading
<figure>       the hero, right after the intro
## section     5 to 8 of these, figures between them
## limits      what this does not do, or where a competitor still wins
## closing     how to do it in TablePro, or how to get it
```

- **A release post opens with the number** and gets out of the way: "TablePro 0.77 is out: 210
  changes, 150 of them fixes." A topical post opens on the reader's problem and reaches TablePro in
  the second paragraph, never with "TablePro 0.77 adds".
- **Headings are plain statements or names**: "Where the 320 MB goes", "When D1 is not the right
  call". No questions, slogans or gerund stacks.
- **The limits section is required.** Name real gaps ("Charts draw the loaded rows, not the whole
  table"), not disguised strengths.
- **The closing is concrete**: numbered steps, a config snippet, or the update path. Never a summary.

## 4. Weight

A post where every section weighs the same reads as machine-written, whatever its sentence length.
Decide per feature before writing:

- **Prose plus a figure** for something a reader will change their behavior over. Four is usually the
  ceiling.
- **One bullet** for everything else, collected in one "Also new" section.
- **A bold one-liner** for a breaking change, wherever it lands, so it cannot be skimmed past.

Aim for at least a 3x spread in words between the biggest and smallest section; under 2x means the
post has not been edited. `lint-draft.py --blog` measures it. Explain rationale once per post, not in
every section: state the behavior and stop.

## 5. Figures

Raw HTML, not markdown image syntax, which gives no caption:

```html
<figure>
  <img src="/images/blog/mcp-settings-panel.png" alt="TablePro Connect a Client sheet with tabs for Claude Code, Claude Desktop, and Cursor, showing the JSON snippet to paste into the chosen client's config" />
  <figcaption>Connect a Client: pick Claude Code, Claude Desktop, or Cursor and TablePro shows the exact config to paste.</figcaption>
</figure>
```

- Files live in `public/images/blog/` (tracked in git) and are referenced as `/images/blog/...`.
- **Alt text describes the picture** in one long, specific sentence: what is on screen, not which
  feature it is.
- **The caption says what the picture proves**, in one sentence that stands on its own.
- One figure per 150 to 350 words. Retina and unpadded, no fixed size; never upscale a small capture.
- A docs screenshot can be reused, renamed to the blog scheme `<area>-<thing>.png`.

**When the screenshot does not exist yet**, ship a rendered placeholder that names what to capture
and the file path to overwrite, and list it as pending in your report. Never point an `<img>` at a
missing file or reuse a shot of a pane that has changed. The real screenshot later replaces the file
at the same path, so the post needs no edit.

```bash
npx puppeteer browsers install chrome-headless-shell
```

```php
Browsershot::html($html)->windowSize(2400, 1500)->setScreenshotType('png')
    ->save(public_path('images/blog/' . $name . '.png'));
```

## 6. Voice

- Second person, present tense. Contractions are fine here.
- Numbers instead of adjectives: "400 MB at idle", "three round trips", never "much faster".
- Backticks on shortcuts, SQL keywords, identifiers, paths and config keys. Bold for menu paths:
  `**Settings > MCP**`.
- Tables only for tabular things, two per post at most.
- State a limit flatly and without apology. Never call a competitor bad; say what it costs.
- No em dashes, no banned words (`scripts/banned-words.txt` in the TablePro repo), US spelling to
  match the docs and the app. The lint checks all three.

Then run `references/fact-checks.md`: tier claims, menu labels, thresholds and plugin availability
all need checking before the post is indexed and quoted.

## 7. Wire it up and verify

1. In `tests/Feature/Landing/BlogTest.php`, add one to the `->has('posts', N)` count and add the slug
   to the `blogSlugs` dataset.
2. Render the OG card, tracked at `public/og/blog/<slug>.png`, and look at it: a long title wraps to
   three lines and can push the punchline off the card.

   ```bash
   php artisan og:generate --type=blog --slug=<slug>
   ```

3. The sitemap needs nothing; it is regenerated on deploy.
4. Lint, test, and confirm the post parsed, because bad frontmatter fails quietly:

   ```bash
   python3 <TablePro repo>/.claude/skills/release/scripts/lint-draft.py --blog resources/blog/<slug>.md
   php artisan test --compact
   vendor/bin/pint --dirty --format agent      # after any PHP edit
   php artisan tinker --execute="
   \$p = app(App\Services\Blog\BlogService::class)->find('<slug>');
   echo \$p->wordCount.' words, '.substr_count(\$p->bodyHtml, '<figure>').\" figures\n\";
   "
   ```

`main` deploys itself on green tests, so pushing publishes the post. Push only when every blocker at
the end of `references/fact-checks.md` that applies to the post holds: a post that says "update now"
before the build exists sends readers to the previous version.
