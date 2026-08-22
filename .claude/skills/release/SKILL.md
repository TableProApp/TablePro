---
name: release
description: >
  Ships a TablePro release end to end: bumps Configs/Version.xcconfig, finalizes
  CHANGELOG.md, commits, tags, pushes, releases plugins, and then, when the release
  is big enough to be worth announcing, writes the blog post, the newsletter and the
  X posts that point at it. Use whenever the user says "release", "bump version",
  "ship version", "tag a release", "cut a release", gives a version number
  ("/release 0.67.0", "/release plugin-oracle 1.0.0"), or asks for the announcement
  that goes with one: "newsletter for 0.67", "blog post for the release",
  "announce 0.67", "write the X thread".
---

# Release

One pipeline, run in order. Each stage has a gate: do not start the next until the
previous one is real.

```
1. Decide the shape    big release, or normal
2. Release             version bump, changelog, tag, push       always
3. Plugins             registry tags, after the app build       when plugins changed
4. Blog post           the announcement itself                  big only
5. Newsletter          short, points at the blog post           big only
6. X posts             short, point at the blog post            big only
```

**A normal release stops after stage 3.** The changelog and the docs changelog are
the announcement. Do not write a newsletter for a release nobody would change their
behaviour over: a mail that says "we fixed some things" costs more attention than it
returns.

**For a big release the blog post is the announcement.** It is the canonical URL and
the only place carrying the full story, the figures and the limits. The newsletter
and the X posts exist to send people to it, not to repeat it. Write both from the
finished blog post, never from the changelog, or you ship three versions of one
release that disagree with each other.

## Stage 1: Decide the shape

A release is **big** when at least one of these is true:

- `### Added` holds a feature a reader would do something differently because of: a
  new pane or mode, a new way to connect, a new database, a rebuilt surface they
  will not recognise.
- Something people rely on was removed or changed underneath them.
- A whole class of long-standing bugs is gone in a way users have been asking about.

It is **normal** when the release is fixes, small changes, and plugin work.

Entry count is a sanity check, not the rule. Recent releases: 0.64 ran 42 entries,
0.66 ran 65, 0.65 ran 158, 0.67 ran 200.

```bash
awk '/^## \[Unreleased\]/{f=1;next} /^## \[/{f=0} f' CHANGELOG.md \
  | awk '/^### /{s=$2} /^- /{c[s]++} END{for (k in c) print k, c[k]}'
```

Say which shape you picked and why before doing any work. When it is genuinely
borderline, ask: an unwanted newsletter wastes an hour, a skipped one wastes a launch.

## Stage 2: Release

### Pre-flight

Verify all of these first. If any fails, stop and say what is wrong.

1. **Version argument exists** and is semver (`X.Y.Z`; pre-release suffixes like
   `-beta.1` are allowed). If missing, ask.
2. **Version is newer** than `MARKETING_VERSION` in `Configs/Version.xcconfig`.
3. **Tag is free**: `git tag -l "v<version>"`.
4. **Working tree is clean**: `git status --porcelain`. If not, warn and ask whether
   to fold those changes into the release.
5. **`[Unreleased]` has content.** If empty, the release has no notes. Say so.
6. **Entries are the right shape.** They accumulate one PR at a time and drift long.
   Per `CLAUDE.md` rule 1 and Keep a Changelog 1.1.0, an entry is one sentence, two
   at the outside, under 200 characters:

   ```bash
   awk '/^## \[Unreleased\]/{f=1;next} /^## \[/{f=0} f' CHANGELOG.md \
     | grep '^- ' | awk '{ t+=length($0); n++; if (length($0)>200) o++ } \
         END { if (!n) { print "no entries"; exit } \
               print n" entries, avg "int(t/n)" chars, "o+0" over 200" }'
   ```

   If entries run over, rewrite the whole section before finalizing: cut each to the
   notable difference, merge entries describing one change, keep every `(#1234)`.
   Diff the reference IDs before and after to prove none were dropped. The
   explanation belongs in the PR body. At 0.67.0 this arrived with 211 entries
   averaging 300 characters, the longest 1,685, and was rewritten to 200 averaging 100.
7. **On `main`**: warn, do not block.
8. **SwiftLint is clean**: `swiftlint lint --strict`. Fix what it finds first, in its
   own commit.

### Bump the version

`Configs/Version.xcconfig` holds exactly two lines and they belong to the macOS app
alone. Set `MARKETING_VERSION` to the new version, increment `CURRENT_PROJECT_VERSION`
by 1.

No other file carries an app version. Plugin bundles, test bundles and
TableProPluginKit pin `MARKETING_VERSION = 1.0` in `project.yml`; the iOS app reads
`Configs/Version-iOS.xcconfig`. Leave those alone.

### Finalize CHANGELOG.md

1. **Version the heading.** Replace `## [Unreleased]` with:

   ```
   ## [Unreleased]

   ## [<version>] - <YYYY-MM-DD>
   ```

2. **Update the footer links.**

   ```
   [Unreleased]: https://github.com/TableProApp/TablePro/compare/v<version>...HEAD
   [<version>]: https://github.com/TableProApp/TablePro/compare/v<old>...v<version>
   ```

3. **Check the sections.** Entries land one PR at a time, each appending its own
   heading, so a version can end up with a type listed twice or out of order. Keep a
   Changelog allows each type once per version, in the order `Added`, `Changed`,
   `Deprecated`, `Removed`, `Fixed`, `Security`:

   ```bash
   awk '/^## \[<version>\]/{f=1;next} /^## \[/{f=0} f' CHANGELOG.md | grep '^### '
   ```

   A repeated heading means merging the two bodies into the first. An out-of-order
   one means moving the whole block. 0.67.0 arrived with two `### Security` sections,
   one of them before `### Fixed`.

4. **Confirm nothing was lost** after any restructuring:

   ```bash
   grep -n '^## \[' CHANGELOG.md | head -5
   awk '/^## \[<version>\]/{f=1;next} /^## \[/{f=0} f' CHANGELOG.md | grep -c '^- '
   ```

### Update the docs changelog

`docs/changelog.mdx` needs a new `<Update>` block at the top, right after the
frontmatter. The docs site is English only: `docs/docs.json` declares no locales and
`docs/vi/` was deleted on 2026-03-22 in `5837cb597`. Do not recreate it.

```mdx
<Update label="<Month Day, Year>" description="v<version>">
  ### New Features

  - **Feature Name**: Description

  ### Improvements

  - Description

  ### Bug Fixes

  - Description
</Update>
```

Group by audience, not by the Keep a Changelog types. This is the one place the
wording may grow past the `CHANGELOG.md` entry it came from: the changelog states
the change, the docs entry can name the feature and say what the reader does with it.

### Commit, tag, push

```bash
git add Configs/Version.xcconfig CHANGELOG.md docs/changelog.mdx
git commit -m "release: v<version>"
git tag v<version>
git push origin main && git push origin v<version>
```

Push the commit and the tag separately: `--follow-tags` only pushes annotated tags
and `git tag` creates lightweight ones. Keep unrelated work out of the release
commit; a lint fix made along the way gets its own conventional commit first.

This triggers `.github/workflows/build.yml`: arm64 and x86_64 builds, DMG and ZIP,
Sparkle signatures, `appcast.xml`, and the GitHub Release with notes from
`CHANGELOG.md`.

## Stage 3: Plugins

After the app tag is pushed, check which separate plugin bundles changed. Changes in
`Plugins/TableProPluginKit/` affect every plugin.

Do not hardcode the plugin list. Scan `Plugins/`, skip the bundled ones and
PluginKit, and derive each tag name to match the `case "$PLUGIN_NAME"` mapping in
`.github/workflows/build-plugin.yml`. Non-obvious mappings: `CloudflareD1DriverPlugin`
→ `cloudflare-d1`, `EtcdDriverPlugin` → `etcd`.

```bash
LAST=$(git tag -l "plugin-<name>-v*" --sort=-version:refname | head -1)
git log --oneline "${LAST}..HEAD" -- "Plugins/<Dir>/" "Plugins/TableProPluginKit/"
```

Separate the plugin's own commits from PluginKit-only ones. A plugin with no commits
of its own can still need a release when PluginKit moved, or when something like
notarization forces republishing everything.

Show the user what changed and ask before tagging. Suggest a patch bump from the last
tag. For a bulk re-release, `scripts/release-all-plugins.sh <pluginKitVersion>` fires
one matrix run over all registry-only plugins.

```bash
git tag plugin-<name>-v<version>
git push origin plugin-<name>-v<version>
```

Plugin bundles need no version bump or changelog edit; the version rides on the tag.

**Wait for the app build to finish before pushing plugin tags.** The account runs
five macOS jobs at a time and every plugin build takes one. On v0.66.0, seven plugin
tags pushed two minutes after the app tag left the release's own test suite queued
for nine minutes. Check with `gh run list --workflow build.yml --limit 1`.

### PluginKit ABI

If the release touched `Plugins/TableProPluginKit/`, settle additive vs breaking
before republishing anything:

```bash
scripts/check-pluginkit-abi.sh v<previous-version>
```

It reports a diff and leaves the call to you. Additive needs no bump. Breaking means
bumping `currentPluginKitVersion` plus every plugin `Info.plist`, then
`release-all-plugins.sh` before or with the app release. The trap is a *removed or
renamed* symbol: a shipped plugin hard-references the default implementation it
relied on, and losing that symbol makes it fail to load. Adding a parameter to an
existing public init is the same hazard unless the old signature stays as an
`@_disfavoredOverload`.

## Stage 4: Blog post (big releases only)

**This is the announcement.** Read `references/blog-post.md` before writing. The
marketing site has a house layout and it is easy to invent a different one.

The post is one markdown file in `resources/blog/` in the marketing site repo
(`../tablepro-web`, or wherever the user points), filename equal to the slug.

What that reference covers: two intro paragraphs with no heading that open on the
reader's problem rather than the product, a hero `<figure>`, five to eight
flat-statement `##` sections with figures interspersed, a section naming what the
release does **not** do, and a closing section with the concrete update path. Figures
are raw `<figure>` HTML with descriptive `alt` and a `<figcaption>`; when a screenshot
does not exist yet, ship a rendered placeholder naming what to capture rather than
omitting the image. Adding the file also means updating
`tests/Feature/Landing/BlogTest.php`, which hardcodes the post count and a slug
dataset, and rendering the OG card.

**Gate:** the blog post has to be live before the newsletter and the X posts go out,
because both link to it.

## Stage 5: Newsletter (big releases only)

Short. It says a version exists, names the headline items one line each, and sends
the reader to the blog post. Target **150 to 250 words**. The detail, the figures and
the caveats live in the post. Repeating them here creates a second version of the
release that will drift from the first.

Shape, voice and the shipped references are in `references/newsletter.md`. Run the
mechanical lint before the factual pass:

```bash
python3 .claude/skills/release/scripts/lint-draft.py <draft.md>
```

Then work `references/fact-checks.md` top to bottom. That is where the expensive
mistakes get caught: a fix credited to a version that never had the bug, a plugin
told to install that was never published, a link to a page that does not cover the
feature.

## Stage 6: X posts (big releases only)

Also short, also pointed at the blog post. Four to six posts, one headline feature
each, the last carrying the link, plus one standalone post for people who do not read
threads. Written from the finished blog post and newsletter, not from the changelog.
Rules in `references/newsletter.md`.

## Ordering and blockers

Everything downstream depends on the build existing. A pushed tag is not a build: the
workflow takes about 45 minutes and the GitHub Release and appcast entry appear only
when its final job succeeds.

```bash
gh run list --workflow build.yml --limit 1
gh release view v<version> --json tagName,assets -q '"\(.tagName) assets=\(.assets|length)"'
curl -s https://raw.githubusercontent.com/TableProApp/TablePro/main/appcast.xml \
  | grep -o '<sparkle:shortVersionString>[^<]*' | head -2
```

Report blockers separately from any draft, as a list of things that must be true
before it can go out:

- The GitHub Release exists with its assets, and the appcast carries the version.
- Every plugin an announcement tells people to install is tagged, built and in the
  registry.
- The docs changelog is deployed.
- Screenshots are captured against a build that contains the change.
- The blog post is live, because the newsletter and the X posts link to it.

## Sending

Out of scope on purpose. If the user asks to send the newsletter, tell them the
audience trap first: in the license backend `all` means verified subscribers only,
roughly 58 people, and `everyone` is the real list of roughly 571. The 0.65
newsletter went to 58 people because of it.

## Where drafts go

The session scratchpad, not the repository. Name by version so several can sit side
by side: `newsletter-v0.67.0.md`, `x-posts-v0.67.0.md`. The blog post is the
exception: it is a tracked file in the marketing site repo.
