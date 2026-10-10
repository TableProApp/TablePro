---
name: release
description: >
  Ships a TablePro release end to end: bumps Configs/Version.xcconfig, finalizes CHANGELOG.md,
  commits, tags, pushes, releases plugins, and then, when the release is big enough to be worth
  announcing, writes the blog post, the newsletter and the X posts that point at it. Use whenever the
  user says "release", "bump version", "ship version", "tag a release", "cut a release", gives a
  version number ("/release 0.67.0", "/release plugin-oracle 1.0.0"), or asks for the announcement
  that goes with one: "newsletter for 0.67", "blog post for the release", "announce 0.67", "write the
  X thread".
---

# Release

Run the stages in order, and do not start one until the one before it is real: 1 decide the shape,
2 release (always), 3 plugins (when they changed), 4 to 6 blog post, newsletter and X posts (big
releases only). A normal release stops after stage 3: the changelog and the docs changelog are its
announcement. For a big release the blog post is the announcement, and the newsletter and X posts
are written from the finished post, never from the changelog, so the three cannot disagree.

House rules this skill relies on and does not repeat: `.claude/rules/changelog.md` (entry shape,
sections, credits, lead block), `.claude/rules/plugin-system.md` (PluginKit ABI, plugin tags) and the
commit format in `AGENTS.md` ("Every change", item 7).

## Stage 1: Decide the shape

The release is **big** when at least one of these holds:

- `### Added` has something a reader would change their behavior over: a new pane or mode, a new way
  to connect, a new database, a rebuilt surface they will not recognize.
- Something people rely on was removed or changed under them.
- A long-standing class of bugs users have asked about is gone.

Otherwise it is **normal**: fixes, small changes, plugin work. The entry count per section is a
sanity check, not the rule. Say which shape you picked and why before any work. Ask when it is
borderline: an unwanted newsletter costs an hour, a skipped one costs a launch.

## Stage 2: Release

### Pre-flight

Check each one. If any fails, stop and say what is wrong.

1. The version is semver (`X.Y.Z`, a suffix like `-beta.1` is fine), newer than `MARKETING_VERSION`
   in `Configs/Version.xcconfig`, and its tag is free (`git tag -l "v<version>"`). Ask if it is missing.
2. The tree is clean (`git status --porcelain`), or the user says the changes belong in the release.
   `[Unreleased]` has entries; if not, say the release has no notes.
3. `swiftlint lint --strict` is clean. Fix findings first, in their own commit.
4. If `Plugins/TableProPluginKit/` changed since the last tag, settle the ABI now (stage 3, PluginKit),
   because a breaking bump publishes plugins before the app tag.
5. Warn, without blocking, when you are not on `main`, and report the last finished full-suite
   verdict on `main` with its commit. `main` is often red on merge skew; the tag's own run is the gate.

   ```bash
   gh run list --workflow=macos-tests.yml --branch main --limit 30 --json conclusion,headSha,createdAt \
     -q '[.[] | select(.conclusion == "success" or .conclusion == "failure")][0]
         | "\(.conclusion) \(.headSha[0:9]) \(.createdAt)"'
   ```

### Credit the entries

Do this before rewording anything: the script reads each entry's commit with `git blame`, and a line
edited in the working tree blames to nothing.

```bash
python3 scripts/ci/changelog_credits.py --dry-run | tail -5
python3 scripts/ci/changelog_credits.py
```

An outside contributor's entry ends `(#2905 by @digows)`, a maintainer's ends `(#2905)`. The output
ends with every contributor and every entry left bare. A bare entry came from a direct push: credit it
from `git log` or leave it, and never guess a handle. Blame credits the last commit to touch a line, so
check the contributors against `gh pr list --state merged --search "merged:>=<last release date>"
--json author` and restore any handle a later rewording took. The script is idempotent.

### Tighten the entries

Entries arrive one PR at a time and drift long. Measure them without their credit, then look for the
repair-story tells:

```bash
awk '/^## \[Unreleased\]/{f=1;next} /^## \[/{f=0} f' CHANGELOG.md | grep '^- ' \
  | sed -E 's/ \(#[0-9, #]+( by @[A-Za-z0-9-]+)?\)$//' \
  | awk '{ t+=length; n++; if (length>120) o++ }
         END { if (!n) { print "no entries"; exit } print n" entries, avg "int(t/n)" chars, "o+0" over 120" }'
awk '/^## \[Unreleased\]/{f=1;next} /^## \[/{f=0} f' CHANGELOG.md | grep -nE '^- .*( now | no longer |, so )'
```

Bare `length` is the line's length. Never write a dollar sign followed by a digit in this file:
Claude Code replaces it with a skill argument, so `/release 0.77.0` ran `length(0.77.0)`.

`instead of` alone is fine when it describes the bug. Rewrite what runs long or matches to
`.claude/rules/changelog.md`, merging entries for one change and keeping every credit as it is. Diff
the `#` references and handles before and after to prove none were dropped.

### Bump the version

In `Configs/Version.xcconfig`, set `MARKETING_VERSION` to the new version and add 1 to
`CURRENT_PROJECT_VERSION`: Sparkle compares the build number, and the release job fails if it did not
rise. Touch no other version: plugins and PluginKit pin `1.0` in `project.yml`, and the iOS app has
`Configs/Version-iOS.xcconfig`.

### Finalize CHANGELOG.md

1. Add `## [<version>] - <YYYY-MM-DD>` below `## [Unreleased]`, leaving Unreleased empty. In the
   footer, point `[Unreleased]` at `v<version>...HEAD` and add
   `[<version>]: https://github.com/TableProApp/TablePro/compare/v<old>...v<version>`.
2. Each `###` heading appears once, in the order Added, Changed, Deprecated, Removed, Fixed, Security.
   Merge a repeated heading into the first and move an out-of-order block, then check nothing was lost:

   ```bash
   awk '/^## \[<version>\]/{f=1;next} /^## \[/{f=0} f' CHANGELOG.md | grep '^### '
   awk '/^## \[<version>\]/{f=1;next} /^## \[/{f=0} f' CHANGELOG.md | grep -c '^- '
   grep -n '^## \[' CHANGELOG.md | head -5
   ```

3. Write the lead block: two or three lines under the version heading, before the first `###`, naming
   the `### Added` items a reader would change their behavior over, in the reader's words. The update
   window and the Sparkle feed show only this block. A release of pure fixes can skip it.
4. Regenerate the in-app notes so **Help > What's New** matches the feed:
   `scripts/generate-whats-new.sh <version>`.

### Docs changelog

Add an `<Update>` block at the top of `docs/changelog.mdx`, right after the frontmatter. The docs are
English only, so there is no translated copy.

```mdx
<Update label="v<version>" description="<Month Day, Year>">
  ### New Features

  - **Feature Name**: what it does for the reader

  ### Bug Fixes

  - Description
</Update>
```

The headings are New Features, Improvements, Removed, Security and Bug Fixes, in that order, each only
when the version has one. Each line is one CHANGELOG entry written for a reader, and a New Features
line may add one sentence on what the reader does with it. An outside contributor's line ends
`, by [@user](https://github.com/user)`; a maintainer's carries no credit.

### Critical update flag

`.github/release-flags.json` holds `criticalUpdate`. Leave it `false`: updates install in the
background and apply on quit, and the flag is what lets Sparkle interrupt the user. Set it `true` only
when the release fixes one of these, and say which:

- Data loss or corruption of a database, saved connections or persisted tabs.
- A security issue with a `### Security` entry that users of the old build are exposed to.
- A crash or hang on a common path, or a failure to launch, connect or update.
- A regression from the previous release with no workaround.

Nothing else, a handful a year at most. Set it in the release commit and back to `false` in the next
one: the release job fails when it is `true` and the file is unchanged since the previous tag. A retag
of the same release never gets it. A bad build is withdrawn (below) and superseded by a corrective
release with the flag.

### Commit, tag, push

```bash
git add Configs/Version.xcconfig CHANGELOG.md docs/changelog.mdx .github/release-flags.json \
    TablePro/Resources/WhatsNew.md
scripts/check-banned-words.sh --staged
git commit -m "release: v<version>"
git tag -a v<version> -m "v<version>"
git push origin main
git push origin v<version>
```

- Keep the subject exactly `release: v<version>`: `scripts/ci/detect-changed-paths.sh` matches it to
  skip the duplicate test run on `main`, since the tag's run is the one that gates.
- Always `-a -m`: the owner's git has `tag.gpgSign=true`, and a plain `git tag <name>` fails with
  "no tag message?".
- Keep unrelated work out of the release commit. A lint fix made on the way goes first, as its own
  Conventional Commit of at most 72 characters.

The tag runs `.github/workflows/build.yml`: arm64 and x86_64 builds, DMG and ZIP, Sparkle signatures,
the GitHub Release with notes from `CHANGELOG.md`, then `appcast.xml`. The release is created as a
draft holding every asset and published in one step, only when `lint`, `test`, `build` and
`registry-readiness` pass. The job fails when the tag disagrees with `MARKETING_VERSION`.

A published release is immutable: its assets and its tag are locked. When a run fails:

- Before **Publish the release**, only a draft exists. Fix forward on `main` and move the tag:
  `git tag -f -a v<version> -m "v<version>"`, then `git push origin v<version> --force`. The next run
  reuses the draft.
- After it, at the `appcast.xml` push for instance, use **Re-run failed jobs**. The release job finds
  the same files already published and carries on. **Re-run all jobs** rebuilds, and the release job
  refuses the new files.
- A published build that is wrong ships as a new version.

### Withdraw a release

Only when a build loses data, fails to launch or breaks connecting, and the fix is more than a few
minutes away. Removing the version from `appcast.xml` is the only way to un-ship a Sparkle release:

```bash
python3 scripts/ci/pull-release.py <version> --dry-run
python3 scripts/ci/pull-release.py <version>
```

It commits and pushes to `main`. Leave the GitHub Release so direct DMG links resolve. Users who
already installed the build are reached by the corrective release with `criticalUpdate` set.

## Stage 3: Plugins

After the app tag is pushed, list the registry plugins with commits since their last tag:

```bash
python3 .claude/skills/release/scripts/changed-plugins.py
```

Slugs, tag names and targets come from `.github/plugin-registry.json`, so nothing is mapped by hand.
`own` counts commits in the plugin's source paths (its folder, plus a package or `Native/` bridge it
builds from), `kit` counts PluginKit commits. Skip `bundled` rows: their changes ship inside the app
(to reach users on an older app, use the shipped-app command below). A row with only `kit` commits
needs a release only after a breaking bump, through `release-all-plugins.sh`.

Show the user what changed and ask before tagging, suggesting a patch bump from the last tag. Tag
each approved plugin annotated, for the same signing reason as the app. The tag is the version, so a
plugin needs no version bump or changelog edit.

```bash
git tag -a plugin-<slug>-v<version> -m "plugin-<slug>-v<version>"
git push origin plugin-<slug>-v<version>
```

- One tag per push: GitHub sends no push event when one push carries more than three tags, so no build
  starts. If several went at once, run `gh workflow run build-plugin.yml -f tags="<tag>,<tag>"`.
- Wait for the app build first (`gh run list --workflow build.yml --limit 1`). Five macOS jobs run at
  a time, and plugin builds would queue the release's own tests.
- Confirm a run started for each tag: `gh run list --workflow build-plugin.yml --limit 10`.
- A published plugin release cannot take a rebuilt binary, and a rebuild never matches the published
  bytes. A plugin run that fails after its release is published ships as the next patch version.

### PluginKit

If the release touched `Plugins/TableProPluginKit/`, run `scripts/check-pluginkit-abi.sh
v<previous-version>` before publishing anything, and act on the diff as
`.claude/rules/plugin-system.md` says. Any diff bumps `currentPluginKitVersion`, once per release
cycle. A breaking one also raises `minimumCompatiblePluginKitVersion`, and
`scripts/release-all-plugins.sh <kitVersion>` must publish before the app tag: `registry-readiness`
blocks the release otherwise, and a silent install would hide drivers that stopped loading. Run the
bulk release for a breaking bump only: an additive bump leaves published binaries valid, and each
bulk run uses up a registry retention slot for every plugin.

To get one driver fix to users who have not updated, build it against their release:
`scripts/release-plugin-for-shipped-app.sh plugin-<slug>-v<version> v<appVersion>`.

## Stages 4 to 6: Announce (big only)

1. **Blog post**, by `references/blog-post.md`: one file in `resources/blog/` of the marketing site
   repo (`../tablepro-web` by default; confirm the path). It goes live first, because the newsletter
   and the X posts link to it. Once it is live, link it from the version's `<Update>` block in
   `docs/changelog.mdx`, on its own line before the first `###`:
   `[Read the announcement](https://tablepro.app/blog/<slug>)`.
2. **Newsletter**, by `references/newsletter.md`: 150 to 250 words that name the headline items and
   link the post.
3. **X posts**, by `references/newsletter.md`: four to six posts plus one standalone, written from the
   finished post and newsletter.

Lint each draft, then work `references/fact-checks.md` top to bottom. Its closing blocker list gates
all three; report blockers separately from the drafts.

```bash
python3 .claude/skills/release/scripts/lint-draft.py --blog <web repo>/resources/blog/<slug>.md
python3 .claude/skills/release/scripts/lint-draft.py <newsletter-or-x-draft.md>
```

Newsletter and X drafts go in the session scratchpad, named by version (`newsletter-v0.77.0.md`,
`x-posts-v0.77.0.md`). Sending is out of scope. If the user asks to send the newsletter, warn them
first: in the license backend `all` means verified subscribers only, a small fraction of the list, and
`everyone` is the real list.
