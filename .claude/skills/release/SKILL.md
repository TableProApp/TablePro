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
6. **Credit every entry to its pull request and its author**, in the form GitHub's
   generated release notes use. Do this before anything rewords an entry: the script
   reads each line's commit with `git blame`, and a line reworded in the working tree
   blames to nothing and is skipped.

   ```bash
   python3 scripts/ci/changelog_credits.py --dry-run | tail -5
   python3 scripts/ci/changelog_credits.py
   ```

   Each entry ends up as `(#2905 by @digows)`, or `(#1748, #2741 by @J2TeamNNL)` when it
   already named an issue. The last lines name every contributor and every entry left
   alone. Read that list: an entry is left bare when its commit has no pull request
   number, which is a direct push. Credit it by hand from `git log` or leave it bare;
   never guess a handle.

   `git blame` credits the last commit to touch a line, so an entry a maintainer reworded
   in a later pull request carries the maintainer's handle. Check the contributor list
   against `gh pr list --state merged --search "merged:>=<last release date>" --json author`
   and put a contributor's handle back on any entry that lost it. The script is
   idempotent, so running it again changes only what is still bare.
7. **Entries are the right shape.** They accumulate one PR at a time and drift long.
   Per `CLAUDE.md` rule 1 and Keep a Changelog 1.1.0, an entry is a fragment naming
   the change, one line, aiming under 120 characters. The credit is not part of the
   fragment, so measure without it:

   ```bash
   awk '/^## \[Unreleased\]/{f=1;next} /^## \[/{f=0} f' CHANGELOG.md \
     | grep '^- ' | sed -E 's/ \(#[0-9, #]+ by @[A-Za-z0-9-]+\)$//' \
     | awk '{ t+=length($0); n++; if (length($0)>120) o++ } \
         END { if (!n) { print "no entries"; exit } \
               print n" entries, avg "int(t/n)" chars, "o+0" over 120" }'
   ```

   Also flag the shapes the style forbids, which are what long entries turn into.
   `now` and `no longer` are the tells for a repair narrative, and `, so` for a
   trailing consequence. Not `instead of` on its own: describing the bug as
   `showing an empty table instead of reporting an error` is exactly right.

   ```bash
   awk '/^## \[Unreleased\]/{f=1;next} /^## \[/{f=0} f' CHANGELOG.md \
     | grep -nE '^- .*( now | no longer |, so )'
   ```

   If entries run over or match, rewrite the whole section before finalizing: cut each
   to the notable difference, turn every `X now does Y instead of Z` into the bug or
   the thing itself, drop trailing `so ...` clauses, merge entries describing one
   change, keep every trailing `(#1234 by @handle)` exactly as it is. Diff the
   reference IDs and handles before and after to prove none were dropped. The
   explanation belongs in the PR body. At 0.67.0 this arrived with 211 entries
   averaging 300 characters, the longest 1,685.
8. **On `main`**: warn, do not block.
9. **SwiftLint is clean**: `swiftlint lint --strict`. Fix what it finds first, in its
   own commit.
10. **Report the last full-suite verdict on `main`**: warn, do not block.

    ```bash
    gh run list --workflow=macos-tests.yml --branch main --limit 1 \
      --json conclusion,headSha,createdAt -q '.[] | "\(.conclusion // "in progress") \(.headSha[0:9]) \(.createdAt)"'
    ```

    Say the verdict and the commit it belongs to, then carry on. This reports rather
    than blocks on purpose: `main` is red or cancelled far more often than green, on
    merge skew rather than on real defects, and a hard gate with no merge queue behind
    it would stop releases instead of improving them. The release tag is currently the
    only unconditional full-suite run, so knowing what the last one said is worth the
    one command. Eight of the last seventeen releases had their tag moved onto extra
    commits before going green.

The release job re-checks what it can once the tag is pushed. It fails if the tag
disagrees with `MARKETING_VERSION`, and it fails if `CURRENT_PROJECT_VERSION` did not
rise above the newest published release's, because that number is what Sparkle
compares and a flat one means no install is ever offered the update.

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

### Write the release highlights

A version section may open with a **lead block**: at most six lines before its first `###`
heading, naming what a reader would notice. That block is what the update window and the
Sparkle feed show. Without one they fall back to the whole section, which for 0.73.0 meant
22,443 bytes and 231 list items inside a dialog.

```
## [0.75.0] - 2026-01-01

Map view for results holding a geometry column.
Row-number gutter held at the left edge when the grid scrolls sideways.

### Added
...
```

Two or three lines is right. Write them from the `### Added` entries a reader would change
their behaviour over, in their words rather than the changelog's. A release of pure fixes can
skip the block and take the fallback.

Then regenerate the in-app notes from that block, so **Help > What's New** and the update
window cannot disagree:

```bash
scripts/generate-whats-new.sh <version>
```

A release with no lead block gets a short pointer to the changelog instead of 270 entries
compiled into the app bundle.

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

### Decide whether this release may interrupt anyone

`.github/release-flags.json` holds `criticalUpdate`. Leave it `false`. Updates
install in the background and apply on quit, so an ordinary release costs a user
nothing, and the flag is the only way one is allowed to cost them attention.

Set it `true` only when the release fixes one of these, and say which:

- **Data loss or corruption** of a database, saved connections, or persisted tabs.
- **A security issue** that earns a `### Security` entry and to which a user on the
  old build is actively exposed.
- **A crash or hang on a common path**, or a failure to launch, connect, or update.
- **A regression from the previous release** with no workaround.

Nothing else. Not "a user asked for it today", not "it is a one-line fix". Budget it
at a handful a year: 0.74.0 alone carries five `### Security` entries and most would
not qualify. Marking loosely puts back the interruptions this exists to remove.

What Sparkle does differently for a critical item, none of it cosmetic: it bypasses
phased rollout, hides Skip and Remind Me Later, retitles the alert, reschedules an
already-downloaded update at `MIN(regular, impatient)` instead of `MAX`, and shows it
even under automatic downloads.

Set it in the release commit and set it back in the next one. The release job fails
if it is `true` while the file has not changed since the previous tag, which is what
a flag left over from last time looks like.

Three rules around it. A release-pipeline retag is never a hotfix and never gets the
flag. A release that raises `minimumCompatiblePluginKitVersion` is not tagged until
`release-all-plugins.sh` has published, because a silent install removes the user's
chance to notice their drivers stopped loading. And a build that has to be withdrawn
is pulled with `scripts/ci/pull-release.py` and superseded by a corrective release
carrying the flag; that is the only rollback path there is.

### Commit, tag, push

```bash
git add Configs/Version.xcconfig CHANGELOG.md docs/changelog.mdx .github/release-flags.json \
    TablePro/Resources/WhatsNew.md
git commit -m "release: v<version>"
git tag -a v<version> -m "v<version>"
git push origin main && git push origin v<version>
```

Always `-a`. The history mixes both kinds (`v0.72.0` is lightweight, `v0.73.0` and
`v0.74.0` are annotated), and a lightweight tag answers `git tag -l --format='%(contents)'`
with the commit message, so anything read back off a tag is silently wrong depending
on which kind it happens to be. Push the commit and the tag separately anyway; keep
unrelated work out of the release commit, and give a lint fix made along the way its
own conventional commit first.

This triggers `.github/workflows/build.yml`: arm64 and x86_64 builds, DMG and ZIP,
Sparkle signatures, `appcast.xml`, and the GitHub Release with notes from
`CHANGELOG.md`.

### Withdrawing a release

Removing the items from `appcast.xml` is the only way to un-ship a Sparkle release.
Do this when a build turns out to lose data, fail to launch, or break connecting, and
the corrective release is more than a few minutes away.

```bash
python3 scripts/ci/pull-release.py <version> --dry-run   # says what it would remove
python3 scripts/ci/pull-release.py <version>             # edits, commits, pushes
```

Leave the GitHub Release in place. People who downloaded the DMG directly still need
their link to resolve, and it is the corrective release that supersedes the build, not
the deletion of the old one. Anyone who already installed the bad version is reached
by shipping the fix with the critical flag set, not by the withdrawal.

Nothing else needs unwinding. The rewind guard in `build.yml` compares the generated
feed against `origin/main`, so once `main` no longer advertises the withdrawn version
the next release's feed does not either and the guard passes on its own.

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

It reports a diff and leaves the call to you. Any diff at all, additive included,
bumps `currentPluginKitVersion` plus every plugin `Info.plist`; see the PluginKit ABI
section of `CLAUDE.md` for why an additive change still needs it. Breaking adds
raising `minimumCompatiblePluginKitVersion` and running `release-all-plugins.sh`
before or with the app release. The trap is a *removed or renamed* symbol: a shipped
plugin hard-references the default implementation it relied on, and losing that
symbol makes it fail to load. Adding a parameter to an existing public init is the
same hazard unless the old signature stays as an `@_disfavoredOverload`.

**Bump the number at most once per release cycle.** The first ABI change after a
release takes the next number and every later change in the same cycle reuses it,
because only the value at release time ever reaches a user. Between 2026-09-02 and
2026-09-12 the kit went from 20 to 30, five of those bumps on one day, which is what
closed the registry's retention window: by 2026-09-13 the oldest binary published
anywhere was kit 21, and every user on v0.65.0 to v0.71.0 could install none of the
23 registry plugins.

**Run `release-all-plugins.sh` only for a breaking bump.** An additive bump does not
invalidate a published binary, `check-registry-readiness.py` says so in its own
docstring, and a bulk re-release burns a retention slot for every plugin. To get one
driver fix to users who have not updated, build it against their release instead:

```bash
scripts/release-plugin-for-shipped-app.sh plugin-<name>-v<version> v<appVersion>
```

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
