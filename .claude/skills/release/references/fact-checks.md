# Fact checks

`lint-draft.py` checks how a sentence reads. This checks whether it is true. Work it top to
bottom on the blog post first, then on the newsletter and the X posts written from it.

## 1. A fix is tied to a version only when git agrees

```bash
git log --oneline -S "<symbol the fix touched>" -- <path>
git show <previous-tag>:<path> | grep -n "<the old code>"
```

If the broken code is also at the tag before that, it was never a regression. Say what was
wrong without naming a version.

## 2. A behavior change matches what the old code did

Before grouping several things under one verb ("joins, unions and CTEs are read-only now"),
read the diff and confirm each one changed. A summary easily drops the changelog's scope.

## 3. A plugin feature needs a published binary

Not installable until its tag exists, contains the commit, and the registry lists it:

```bash
git tag -l "plugin-<slug>-*" | tail -3
git merge-base --is-ancestor <feature-commit> plugin-<slug>-v<latest> && echo included || echo NOT included
curl -s https://raw.githubusercontent.com/TableProApp/plugins/main/plugins.json | python3 -c \
  'import json,sys; [print(p["id"], p["version"]) for p in json.load(sys.stdin)["plugins"] if "<Name>" in p["id"]]'
```

The registry `id` is the `bundleId` in `.github/plugin-registry.json`. If a check fails, tag
the plugin with the release or cut the section.

## 4. Images are real and current

A `docs/images/*.png` at exactly 1560x960 is a "Screenshot coming soon" card. A real file can
still be stale, so compare its date with the commits that changed the UI it shows:

```bash
sips -g pixelWidth -g pixelHeight docs/images/<file>.png
git log -1 --format='%ad %s' --date=short -- docs/images/<file>.png
```

Never embed a placeholder or a stale shot. Mark the gap in the draft and list it as a blocker.

## 5. Menu labels come from the app

The docs paraphrase. Take the string from the menu builder, and watch for labels that change by
engine: "Close Tabs for Other Databases" reads "Other Schemas" on Oracle, Dameng and BigQuery.

```bash
grep -rn "String(localized:" TablePro/Core/Menu/ | grep -i "<the item>"
```

## 6. Tiers, defaults and thresholds

```bash
grep -n -A3 "case <feature>" TablePro/Models/Settings/ProFeature.swift
```

`requiredTier` is the lowest tier that includes a feature, and Team includes Starter, so write
"needs a license, and both tiers include it". Describe a gate as it behaves: a locked overlay
is not a disabled menu item. Quote the number that decides a behavior, or none, after reading
every constant in the model file, including the default range a comparison runs over.

## 7. Every URL resolves

```bash
ls docs/features/<page>.mdx docs/databases/<page>.mdx
grep -n "^## " docs/databases/<page>.mdx
```

`docs/changelog.mdx` carries the version only after the release-day docs deploy, so that link
is a blocker until then, not a broken link.

## 8. Counts and references

Count the bullets under `### Fixed` in the shipped section and write "N fixes", never "N bugs
fixed": one bullet can cover several issues. Never inflate it with issue or commit counts.
Leave issue numbers out of every announcement; changelog references are sometimes wrong.

## Blockers

Report these apart from any draft. Nothing goes out until every one holds.

- The GitHub Release has its assets and the appcast carries the version. A pushed tag is not a
  build: the workflow takes about 45 minutes and publishes from its last job.

  ```bash
  gh run list --workflow build.yml --limit 1
  gh release view v<version> --json tagName,assets -q '"\(.tagName) assets=\(.assets|length)"'
  curl -s https://raw.githubusercontent.com/TableProApp/TablePro/main/appcast.xml \
    | grep -o '<sparkle:shortVersionString>[^<]*' | head -2
  ```

  That raw URL is the `SUFeedURL`. `tablepro.app/appcast.xml` does not exist, and
  `shortVersionString` is an element, not an attribute.
- Every plugin an announcement names is tagged, built and in the registry (check 3).
- Screenshots are captured, light and dark, on a build that contains the change.
- `docs/changelog.mdx` is deployed with the version.
- The fix count is recounted after `[Unreleased]` closed.
- The blog post is live. Fetch the URL rather than trusting that the file was written.
