---
name: release
description: Ships a TablePro release. Bumps Configs/Version.xcconfig, finalizes CHANGELOG.md and the docs changelog, commits, tags, and pushes, then handles registry-only plugin bundle releases. Invoke only when the user explicitly asks for a release.
disable-model-invocation: true
---

# Release

Every step here is public and most of it cannot be undone. A pushed tag triggers a build, a
GitHub Release, an appcast commit on `main`, and for plugins a registry push that clients read.

## Gate

Run this only on an explicit release request from the user, naming the version. "Release" appearing
in conversation is not a request. If you arrived here without one, stop and ask.

```
/release <version>                 # app, for example /release 0.5.0
/release plugin-<name> <version>   # one registry plugin, for example /release plugin-oracle 1.0.1
```

## Pre-flight, all blocking

Nothing below this section is reversible, so every check runs first and a failure stops the
release. Do not "note it and continue".

1. **Version shape.** `X.Y.Z`, optionally with `-beta.N` or `-rc.N`.
2. **Version is newer** than `MARKETING_VERSION` in `Configs/Version.xcconfig`.
3. **Tag is free on the remote**, not just locally. A local check passes for a tag that already
   exists on origin and then the push fails mid-release:
   ```bash
   git ls-remote --tags --refs origin "refs/tags/v<version>"
   ```
4. **Branch and tree.** `git branch --show-current` is `main`, and `git status --porcelain` is
   understood. Other sessions work in this checkout, so anything dirty that you did not put there
   is theirs: never sweep it into a release commit. Stage explicit paths only.
5. **`## [Unreleased]` has entries.** An empty section ships a release whose notes are the CI
   fallback line.
6. **Lint and tests pass**, unscoped, because the release job depends on both:
   ```bash
   .claude/skills/fix-issue/scripts/verify.sh lint TablePro
   .claude/skills/fix-issue/scripts/verify.sh test <affected suites>
   ```
7. **Registry readiness.** The `v*` tag is gated on it in CI, so check it before tagging rather
   than discovering it after:
   ```bash
   MANAGER=TablePro/Core/Plugins/PluginManager.swift
   CURRENT=$(grep -E 'static let currentPluginKitVersion = ' "$MANAGER" | grep -oE '[0-9]+' | head -1)
   FLOOR=$(grep -E 'static let minimumCompatiblePluginKitVersion = ' "$MANAGER" | grep -oE '[0-9]+' | head -1)
   python3 scripts/check-registry-readiness.py --floor "$FLOOR" --current "$CURRENT"
   ```
8. **PluginKit floor decision.** If `minimumCompatiblePluginKitVersion` rose since the last
   release, every registry plugin needs re-publishing with `scripts/release-all-plugins.sh`
   **before or with** this app release, never after. Shipping an app ahead of its plugin binaries
   is what caused two registry-wide outages.

## App release

### 1. Version

`Configs/Version.xcconfig` holds the only app version, and only for the macOS app: set
`MARKETING_VERSION`, and increment `CURRENT_PROJECT_VERSION` by one. Leave everything else alone.
Plugin bundles, test bundles, and `TableProPluginKit` pin `1.0` / `1` in `project.yml`, and the iOS
app reads `Configs/Version-iOS.xcconfig`.

### 2. CHANGELOG.md

Insert a new heading under the kept `## [Unreleased]`:

```
## [<version>] - <YYYY-MM-DD>
```

The shape is load-bearing. `scripts/ci/extract-release-notes.sh` awk-matches `## [X.Y.Z]`, and any
other shape silently yields the fallback release note. Then update the footer links: point
`[Unreleased]` at `v<version>...HEAD` and add `[<version>]: …/compare/v<old>...v<version>`.

Confirm the released headings survived the edit, because dropping one folds a whole past release
into `[Unreleased]` and the next release re-ships it:

```bash
grep -n '^## \[' CHANGELOG.md
```

### 3. docs/changelog.mdx

Add one `<Update label="<Month Day, Year>" description="v<version>">` block at the top, directly
after the frontmatter. Match the shape of the block already there. Rewrite the changelog entries as
user-facing prose grouped by what a user would look for, not by Keep a Changelog categories, and
drop internal refactors with no visible effect. There is no other locale: `docs/vi/` was deleted.

This has to be written now, before the commit, because it ships in the same commit.

### 4. Commit, tag, push, in that order and separately

```bash
git add Configs/Version.xcconfig CHANGELOG.md docs/changelog.mdx
git status --short
git branch --show-current
git commit -m "release: v<version>"
```

Read that `git status --short` before committing and unstage anything that is not one of those
three paths.

```bash
git push origin main
git tag v<version>
git push origin v<version>
```

Push the branch and the tag as separate commands. `git tag` creates a lightweight tag and
`--follow-tags` pushes only annotated ones, so a combined push silently ships no tag.

CI then builds both architectures, signs with Sparkle EdDSA, commits `appcast.xml` to `main`, and
creates the GitHub Release. Pull `main` afterwards, since CI has committed to it.

## Recovery

A failed release leaves a public tag. Delete it on both sides before retrying, and never force
push a branch:

```bash
git push origin :refs/tags/v<version>
git tag -d v<version>
```

If the appcast commit already landed, the release is out. Ship a follow-up version rather than
rewriting history.

## Plugin releases

Only registry-only plugins are released this way. **Never publish a bundled plugin to the
registry.** Do not maintain a list here: `scripts/release-all-plugins.sh` holds the authoritative
`PLUGINS` and `BUNDLED_PLUGINS` arrays and hard-fails on a bundled name.

The `<name>` in a tag must match a case in `.github/workflows/build-plugin.yml`. Read that case
block for the valid names; do not derive a name by transforming a directory name. A wrong name
still creates a permanent public tag and then fails CI with `Unknown plugin name`.

One plugin:

```bash
git ls-remote --tags --refs origin "refs/tags/plugin-<name>-v<version>"
git tag plugin-<name>-v<version>
git push origin plugin-<name>-v<version>
```

Every registry plugin, which is what a PluginKit floor bump requires:

```bash
scripts/release-all-plugins.sh
```

No version bump or changelog edit: a plugin's version is the tag.

### Which plugins have changes

To find candidates, compare each registry plugin's directory and `Plugins/TableProPluginKit/`
against its last remote tag. Take the plugin names from the `PLUGINS` array in
`scripts/release-all-plugins.sh` and map each to its directory, rather than scanning `Plugins/`
and filtering, which is how bundled plugins get offered by mistake.

Do not release a plugin with no changes since its last tag. Report the candidates and their
commits to the user and let them choose.

## Report

State the version and build number, the tag, the CI run URL, the release URL, and any plugin tags
pushed. Say explicitly if a check was skipped and why.
