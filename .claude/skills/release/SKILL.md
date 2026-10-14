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

- You never push to this repository's `main`. Every push made with the release key (the release
  commit, a withdrawal) is the user's to run in their own terminal, because that key never enters
  ssh-agent (`RELEASING.md`, Keys and rulesets). Wait for them to confirm it landed.
- Tags are always annotated, `-a -m`: the owner's git has `tag.gpgSign=true`, and a plain
  `git tag <name>` fails with "no tag message?".
- The release commit holds exactly the four files that Commit, tag, push stages.
- Once a release run is past **Publish the release**, only **Re-run failed jobs**
  (`RELEASING.md`, When a release run fails).

Run the stages in order, starting one only when the one before it is real: 1 decide the shape, 2
release (always), 3 plugins (when they changed), 4 to 6 blog post, newsletter and X posts (big
only). A normal release stops after stage 3; the changelog and docs changelog are its announcement.
A big release's newsletter and X posts come from the finished post, so the three cannot disagree.

House rules relied on, not repeated: `.claude/rules/changelog.md`, `.claude/rules/plugin-system.md`,
the commit format in the top comment of `.github/pull_request_template.md`, and `RELEASING.md` for
the pipeline.

## Stage 1: Decide the shape

The release is **big** when `### Added` has something a reader would change their behavior over (a
new pane or mode, a new way to connect, a new database, a rebuilt surface they will not recognize),
when something people rely on was removed or changed under them, or when a long-standing class of
bugs users have asked about is gone. Otherwise it is **normal**: fixes, small changes, plugin work.
The entry count per section is a sanity check, not the rule. Say which shape you picked and why
before any work, and ask when it is borderline: an unwanted newsletter costs an hour, a skipped one
costs a launch.

## Stage 2: Release

### Pre-flight

Check each. If one fails, stop and say what is wrong.

1. The version is semver (`X.Y.Z`; a suffix like `-beta.1` is fine), newer than `MARKETING_VERSION`
   in `Configs/Version.xcconfig`, and its tag is free (`git tag -l "v<version>"`). Ask if missing.
2. The tree is clean (`git status --porcelain`), or the user says the changes belong in the
   release. `[Unreleased]` has entries; if not, say the release has no notes.
3. `swiftlint lint --strict` is clean: the tag's checks do not cover SwiftLint. Fix findings
   through their own pull request.
4. If `Plugins/TableProPluginKit/` changed since the last tag, do Stage 3, PluginKit, now, before
   the tag.
5. `scripts/export-cloudkit-schema.sh --check` passes; it needs the cktool management token on this
   Mac. A field in the snapshot but not in Production makes CloudKit reject every record carrying
   it, so the user deploys it in CloudKit Console before the tag.
6. After `git fetch origin main`, you are on `main` and it equals `origin/main`. Report both suite
   verdicts and stop when either is a failure. What the tag's `Tested on main` job checks on top of
   this: `RELEASING.md`, The release pipeline.

   ```bash
   for pair in 'macos-tests.yml|macOS Tests' 'ios-tests.yml|iOS and Package Tests'; do
     for id in $(gh run list --workflow "${pair%%|*}" --branch main --event push --limit 20 \
         --json databaseId -q '.[].databaseId'); do
       verdict=$(gh run view "$id" --json headSha,jobs \
         -q ".headSha[0:9] + \" \" + ([.jobs[] | select(.name == \"${pair#*|}\") | .conclusion][0] // \"\")")
       case "$verdict" in *' ' | *skipped) continue ;; esac
       echo "${pair#*|}: $verdict (run $id)"
       break
     done
   done
   ```

7. The release key exists: `test -f ~/.ssh/tablepro_release`. If not, stop and give the user both
   commands to run, the first with a passphrase:

   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/tablepro_release -C "release commit push"
   gh repo deploy-key add ~/.ssh/tablepro_release.pub --allow-write --title "Release commit push" -R TableProApp/TablePro
   ```

### Credit the entries

Do this before rewording anything: the script reads each entry's commit with `git blame`, and a line
edited in the working tree blames to nothing.

```bash
python3 scripts/ci/changelog_credits.py --dry-run | tail -5
python3 scripts/ci/changelog_credits.py
```

An outside contributor's entry ends `(#2905 by @digows)`, a maintainer's ends `(#2905)`. The output
ends with every contributor and every entry left bare. A bare entry came from a direct push: credit
it from `git log` or leave it, and never guess a handle. Blame credits the last commit to touch a
line, so check the contributors against `gh pr list --state merged --search "merged:>=<last release date>" --json author`
and restore any handle a later rewording took. The script is idempotent.

### Tighten the entries

Entries arrive one PR at a time and drift long. Measure them without their credit, then look for
the repair-story tells:

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
`CURRENT_PROJECT_VERSION`. Touch no other version: plugin and PluginKit versions live in `project.yml`,
and the iOS app's in `Configs/Version-iOS.xcconfig`. The release job checks both values
(`RELEASING.md`, The release pipeline).

### Finalize CHANGELOG.md

1. Add `## [<version>] - <YYYY-MM-DD>` below `## [Unreleased]`, leaving Unreleased empty. In the
   footer, point `[Unreleased]` at `v<version>...HEAD` and add
   `[<version>]: https://github.com/TableProApp/TablePro/compare/v<old>...v<version>`.
2. Each `###` heading appears once, in the order Added, Changed, Deprecated, Removed, Fixed,
   Security. Merge a repeated heading into the first and move an out-of-order block, then check
   nothing was lost:

   ```bash
   awk '/^## \[<version>\]/{f=1;next} /^## \[/{f=0} f' CHANGELOG.md | grep '^### '
   awk '/^## \[<version>\]/{f=1;next} /^## \[/{f=0} f' CHANGELOG.md | grep -c '^- '
   grep -n '^## \[' CHANGELOG.md | head -5
   ```

3. Write the lead block: two or three lines under the version heading, before the first `###`,
   naming the `### Added` items a reader would change their behavior over, in the reader's words.
   The update window and the Sparkle feed show only this block. A release of pure fixes can skip it.
4. Regenerate the in-app notes so **Help > What's New** matches the feed:
   `scripts/generate-whats-new.sh <version>`.

### Docs changelog

Add an `<Update>` block at the top of `changelog.mdx` in the docs repository (`../tablepro-docs`,
TableProApp/docs; confirm the path and `git pull --ff-only` first), right after the frontmatter. The
docs are English only, so there is no translated copy.

```mdx
<Update label="v<version>" description="<Month Day, Year>">
  ### New Features

  - **Feature Name**: what it does for the reader
</Update>
```

The headings are New Features, Improvements, Removed, Security and Bug Fixes, in that order, each
only when the version has one. Each line is one CHANGELOG entry written for a reader; a New Features
line may add one sentence on what the reader does with it. An outside contributor's line ends
`, by [@user](https://github.com/user)`; a maintainer's carries no credit.

### Critical update flag

`.github/release-flags.json` holds `criticalUpdate`. Leave it `false`: updates install in the
background and apply on quit, and the flag is what lets Sparkle interrupt the user. Set it `true`
only when the release fixes one of these, and say which:

- Data loss or corruption of a database, saved connections or persisted tabs.
- A security issue with a `### Security` entry that users of the old build are exposed to.
- A crash or hang on a common path, or a failure to launch, connect or update.
- A regression from the previous release with no workaround.

Nothing else; a handful a year at most. Set it in the release commit and back to `false` in the
next. A retag of the same release never gets it. A bad build is withdrawn (Withdraw a release) and
superseded by a corrective release with the flag. What the flag makes Sparkle do, and the release
job's check for a leftover flag: `RELEASING.md`, Staged rollout and critical updates.

### Commit, tag, push

The release key skips every check, so before the user pushes with it, prove the push carries the
release commit and nothing else; stop if the check prints nothing. Push the docs changelog in the
same sitting: the docs CI fails while the app's `CHANGELOG.md` carries a version the page does not.
It goes straight to the docs `main` under the admin bypass, and Mintlify deploys it.

```bash
git add Configs/Version.xcconfig CHANGELOG.md .github/release-flags.json TablePro/Resources/WhatsNew.md
scripts/check-banned-words.sh --staged
git commit -m "release: v<version>"
git fetch origin main
[ "$(git branch --show-current)" = main ] \
  && [ "$(git rev-parse HEAD^)" = "$(git rev-parse origin/main)" ] \
  && [ -z "$(git diff --name-only HEAD^ HEAD | grep -vxE 'CHANGELOG\.md|Configs/Version\.xcconfig|TablePro/Resources/WhatsNew\.md|\.github/release-flags\.json')" ] \
  && echo "only the release commit"
git tag -a v<version> -m "v<version>"
# The user runs this one:
GIT_SSH_COMMAND='ssh -i ~/.ssh/tablepro_release -o IdentitiesOnly=yes' git push origin main
git push origin v<version>
# Then the docs changelog:
git -C ../tablepro-docs add changelog.mdx
git -C ../tablepro-docs commit -m "docs(changelog): v<version>"
git -C ../tablepro-docs push origin main
```

- Keep the subject exactly `release: v<version>`.
- Keep the release commit to the four files above. All four are on the change detector's
  release-only list (`.claude/rules/ci.md`, Change detector), so the push skips both suites and the
  tag takes the verdict of the code it ships. Any other file runs the suites on that push, and the tag waits for
  them. A lint fix made on the way lands first, through its own PR.

### Confirm it shipped

A pushed tag is not a build: the workflow publishes from its last job. Check the run, the release
assets and the feed:

```bash
gh run list --workflow build.yml --limit 1
gh release view v<version> --json tagName,assets -q '"\(.tagName) assets=\(.assets|length)"'
curl -s https://raw.githubusercontent.com/TableProApp/TablePro/main/appcast.xml | grep -o '<sparkle:shortVersionString>[^<]*' | head -2
```

That raw URL is the app's `SUFeedURL`; `tablepro.app/appcast.xml` does not exist. `shortVersionString`
is an element, not an attribute. A failed run: `RELEASING.md`, When a release run fails.

### Withdraw a release

Only when a build loses data, fails to launch or breaks connecting, and the fix is more than a few
minutes away. Commands and effects: `RELEASING.md`, Withdrawing a release; the user runs its push.
Users already on the build are reached by the corrective release with `criticalUpdate` set.

## Stage 3: Plugins

After the app tag is pushed, list the registry plugins with commits since their last tag:

```bash
python3 .claude/skills/release/scripts/changed-plugins.py
```

Slugs, tag names and targets come from `.github/plugin-registry.json`, so nothing is mapped by hand.
`own` counts commits in the plugin's source paths (its folder, plus a package or `Native/` bridge it
builds from), `kit` counts PluginKit commits. Skip `bundled` rows: their changes ship inside the
app, which never applies a registry update to a bundled plugin. A row with only `kit` commits needs
a release only after a breaking bump, through `release-all-plugins.sh`.

Show the user what changed and ask before tagging, suggesting a patch bump from the last tag. Tag
each approved plugin annotated (top of this file). The tag is the version, so a plugin needs no
version bump or changelog edit.

```bash
git tag -a plugin-<slug>-v<version> -m "plugin-<slug>-v<version>"
git push origin plugin-<slug>-v<version>
```

- One tag per push: GitHub sends no push event for a push carrying more than three tags, so no
  build starts. If several went at once, run `gh workflow run build-plugin.yml -f tags="<tag>,<tag>"`.
- Wait for the app build first (`gh run list --workflow build.yml --limit 1`): plugin builds compete
  with its `Build` jobs and `Create GitHub Release` for the same macOS runner slots
  (`.claude/rules/ci.md`, Caches and runner budget). Then confirm a run started for each tag with
  `gh run list --workflow build-plugin.yml --limit 10`.
- A published plugin release cannot take a rebuilt binary, and a rebuild never matches the
  published bytes. A plugin run that fails after its release is published ships as the next patch.

### PluginKit

If the release touched `Plugins/TableProPluginKit/`, run `scripts/check-pluginkit-abi.sh v<previous-version>`
before publishing anything, and act on the diff as `.claude/rules/plugin-system.md` (ABI) says.
`scripts/release-all-plugins.sh` runs for a breaking bump only: each run uses a registry retention
slot for every plugin. One driver fix reaches users who have not updated through
`scripts/release-plugin-for-shipped-app.sh plugin-<slug>-v<version> v<appVersion>`.

## Stages 4 to 6: Announce (big only)

1. **Blog post**, by `references/blog-post.md`: one file in `resources/blog/` of the marketing site
   repo (`../tablepro-web` by default; confirm the path). It goes live first, because the
   newsletter and the X posts link to it. Once live, link it from the version's `<Update>` block in
   the docs `changelog.mdx` with `[Read the announcement](https://tablepro.app/blog/<slug>)` on its
   own line before the first `###`, pushed as `docs(changelog): link the <version> announcement`.
2. **Newsletter**, by `references/newsletter.md`: 150 to 250 words that name the headline items and
   link the post.
3. **X posts**, by `references/newsletter.md`: four to six posts plus one standalone, written from
   the finished post and newsletter.

Lint each draft, then work `references/fact-checks.md` top to bottom. Its closing blocker list
gates all three; report blockers apart from the drafts.

```bash
python3 .claude/skills/release/scripts/lint-draft.py --blog <web repo>/resources/blog/<slug>.md
python3 .claude/skills/release/scripts/lint-draft.py <newsletter-or-x-draft.md>
```

Newsletter and X drafts go in the session scratchpad, named by version (`newsletter-v0.77.0.md`,
`x-posts-v0.77.0.md`). Sending is out of scope. If the user asks to send the newsletter, warn them
first: in the license backend `all` means verified subscribers only, a small fraction of the list,
and `everyone` is the real list.
