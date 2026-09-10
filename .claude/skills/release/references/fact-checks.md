# Fact checks

The mechanical lint catches how a sentence reads. This catches whether it is true. Work it top
to bottom against every published artifact: the blog post first, because it is the announcement
and the other two are written from it, then the newsletter and the X posts. Each item below has
already been shipped wrong at least once.

## 1. A fix does not get credited to a version until git agrees

The changelog says "editable again" and the newsletter turns that into "0.65 broke this". Check
before writing the version number:

```bash
git log --oneline -S "<the symbol the fix touched>" -- <path>
git show <last-tag>:<path> | grep -n "<the old code>"
```

If the broken code is present at the previous tag and the tag before that, it was never a
regression, and naming a version makes a false claim about a build people are running. Say
what was wrong without a version instead.

The 0.66 draft said an aliased `SELECT` "gave a read-only grid in 0.65". The same table-name
regex was in v0.64.0 and dated to February.

## 2. A claimed behaviour change has to match what the old code did

The changelog scopes carefully and a summary can collapse the scope away. "Joins, unions,
subqueries and CTEs are read-only now, where TablePro used to write your edit into one of the
tables" attributes data corruption to three shapes that were already read-only; only the set
operators ever resolved to a branch table. Read the diff, or simulate the old predicate, before
grouping several things under one verb.

## 3. A plugin feature needs a published binary

Registry plugins ship on their own tags. A feature merged into `main` is not installable until
that tag exists and the registry carries it. Check both:

```bash
git tag -l "plugin-<name>-*" | tail -3
git merge-base --is-ancestor <feature-commit> plugin-<name>-v<latest> && echo included || echo NOT included
```

Also confirm the plugin is in the live registry `plugins.json` at
`https://github.com/TableProApp/plugins`. If either check fails, the section is a pre-send
blocker: either the tag ships with the release or the section comes out.

At 0.66 this caught three sections at once. Dameng had never been tagged, the published MSSQL
plugin predated Entra ID, and the published DuckDB plugin predated both DuckDB fixes.

## 4. Most images in docs are placeholders

Any `docs/images/*.png` at exactly **1560x960** is a generated card reading "Screenshot coming
soon" or "Screenshot pending", not a screenshot. At 0.66 that was 126 of 186 files.

```bash
sips -g pixelWidth -g pixelHeight docs/images/<file>.png
git log -1 --format='%ad %s' --date=short -- docs/images/<file>.png
```

Real screenshots are 1200x800, 1400x900, 1824x1248, 2400x1600 or 3024x1722. A real file can
still be unusable: check its date against the commits that changed the UI it shows. The one
real Open Quickly screenshot predated the rename, the redesign and the new material, so it
showed the retired name.

Never embed a placeholder or a stale shot. Leave a marked placeholder line in the draft and
report it as a pre-send blocker.

## 5. Menu labels come from the app, not from the docs

The docs paraphrase. The email names things the reader has to find on screen, so take the
string from the builder:

```bash
grep -rn "String(localized:" TablePro/Core/Menu/ | grep -i "<the item>"
```

Watch for items that change name by engine. At 0.66 the menu reads "Close Tabs for Other
Databases" normally and "Close Tabs for Other Schemas" on Oracle, Dameng and BigQuery, and the
draft named the wrong one for the engines it was talking about. The docs also say "Flat layout"
and "Tree layout" where the app says "Sidebar as List" and "Sidebar as Tree".

## 6. Tier and gating claims

Check the tier constant rather than the docs table, and check what the gate actually does:

```bash
grep -n -A3 "case <feature>" TablePro/Models/Settings/ProFeature.swift
```

There are two tiers, Starter and Team, and Team includes everything in Starter, so "needs a
license, and both tiers include it" answers the reader's real question better than naming one
tier. Do not say a menu item is disabled when the item stays enabled and the tab shows a locked
overlay.

## 7. Defaults and thresholds

If you quote a number, quote the one that decides the behaviour, or quote none. The 0.66 draft
gave the Got Slower sample floor and the millisecond floor and left out the ratio, which is the
threshold that actually separates a regression from noise, so the sentence read as a complete
test and was not one. Either check every constant in the model file or describe the behaviour
without numbers and let the docs page carry them.

Same for defaults: "got slower than last week" was wrong because the default range is four
weeks.

## 8. Every URL resolves

```bash
ls docs/features/<page>.mdx docs/databases/<page>.mdx
grep -n "^## " docs/databases/<page>.mdx        # anchors for section links
```

`docs/changelog.mdx` lags the release: it will not carry the new version until the release-day
docs deploy, so the changelog link is a pre-send blocker rather than a broken link.

## 9. The app release has to exist

Every call to action, Check for Updates and Download, points at a build. A pushed tag is not a
build: the workflow takes about 45 minutes, and the GitHub Release and the appcast entry only
appear when its final job succeeds.

```bash
gh release view v<version> --json tagName,assets -q '"\(.tagName) assets=\(.assets|length)"'
gh run list --limit 5 --json workflowName,headBranch,status,conclusion \
  -q '.[] | "\(.headBranch) \(.workflowName) \(.status)/\(.conclusion // "-")"'
curl -s https://raw.githubusercontent.com/TableProApp/TablePro/main/appcast.xml \
  | grep -o '<sparkle:shortVersionString>[^<]*' | head -2
```

"release not found" with the tag pushed means the build is still running or it failed. Sending
then puts people on a Download button that hands them the previous version, and Check for
Updates tells them they are up to date. Wait for the release object and the appcast entry.

The feed is the `SUFeedURL` in `TablePro/Info.plist`, which is the raw GitHub URL above.
`https://tablepro.app/appcast.xml` is a 404 and always has been, and
`shortVersionString` is an XML element, not an attribute, so a grep written for
`sparkle:shortVersionString="..."` silently matches nothing and reads as "not
published yet".

At 0.66 the tag was pushed, all seven plugin builds had finished, and Build TablePro was still
in progress, which is exactly the window in which the email looks ready and is not.

## 10. The fix count

Count the bullets, and say so honestly. Several bullets bundle more than one issue, so the
bullet count is a floor, not a total. "48 fixes" is defensible when 48 bullets sit under
`### Fixed`; "48 bugs fixed" is not. The count also drifts while `[Unreleased]` is open, so
recount just before sending.

The floor is lower than it looks, because the release pass merges entries that describe one
change. At 0.67.0 that took 211 entries to 200, and one merged bullet covers six separate fixes
to the JSON and PHP tree filter. Never recover a bigger number by counting issue references or
commits instead; count the bullets under `### Fixed` in the shipped file, and let the number be
whatever it is.

## 11. Reference IDs

Changelog entries carry issue numbers that sometimes point at the wrong thing: at 0.66, Query
Insights cited #2107 but was built as #2180, and the tree folders cited #1590 but were built as
#2151. Neither shipped newsletter prints an issue number. Keep it that way rather than
propagating a wrong one.

## Pre-send blockers to report

Separate from the draft, list what has to be true before it can go out:

- The GitHub Release exists with its assets, and the appcast carries the new version.
- Plugin tags built, published, and in the registry, for every plugin an artifact names.
- Screenshots captured against a build that contains the change, light and dark.
- `docs/changelog.mdx` deployed with the new version.
- The fix count recounted after `[Unreleased]` closes.
- **The blog post is live**, because the newsletter and the X posts link to it. Send either one
  before the post deploys and every reader lands on a 404. This is the only blocker whose fix is
  in a different repository, so check it by fetching the URL rather than by remembering that the
  file was written.
