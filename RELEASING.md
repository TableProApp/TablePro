# Releasing

`scripts/build-release.sh` is the whole release build: it signs every nested binary (plugins,
helpers, frameworks) and the app bundle last, so signing again by hand undoes its work.

Everything here needs the maintainer's credentials; a contributor wants `CONTRIBUTING.md`, Building.
The `release` skill in `.claude/skills/release` runs a release on top of this file and owns the
procedure and its decisions.

## Release builds

```bash
scripts/build-release.sh arm64     # or x86_64, or both (the default with no argument)
```

Output lands in `build/Release/TablePro-arm64.app` and `build/Release/TablePro-x86_64.app`.

The script extracts the matching slice from the universal static libraries, copies every non-system
dynamic library the binaries reference into `Contents/Frameworks` and rewrites their install names,
strips the binaries, then signs with hardened runtime and `TablePro/TablePro.entitlements`.

| Variable | Default | Purpose |
|---|---|---|
| `SIGN_IDENTITY` | the maintainer's Developer ID Application | codesign identity for every binary |
| `NOTARIZE` | `false` | `true` notarizes and staples after the build |
| `NOTARY_PROFILE` | `TablePro` | `notarytool` keychain profile holding the credentials |

Create the notary profile once with `xcrun notarytool store-credentials "TablePro"` plus
`--apple-id`, `--team-id` and `--password`. `scripts/lib/notarize.sh` zips, submits, waits and
staples. It reads both the exit status and the reported status, because `notarytool` has exited 0
on a rejected submission.

## Packaging a DMG

`scripts/create-dmg.sh <version> <arm64|x86_64> [source app]` packages one architecture. The source
app defaults to the one `build-release.sh` wrote for that architecture. An empty version reads
`MARKETING_VERSION` from `Configs/Version.xcconfig`, the only place the app version is declared.

```bash
scripts/create-dmg.sh 0.80.0 arm64    # writes build/Release/TablePro-0.80.0-arm64.dmg
```

It prefers `create-dmg` (`brew install create-dmg`) and falls back to `hdiutil`. `NOTARIZE=true`
notarizes the DMG too.

## Static libraries

The `.a` files under `Libs/` and the xcframeworks under `Libs/ios/` live on the `libs-v1` GitHub
release, not in git. Each set has a checksum baseline committed beside it, and
`scripts/download-libs.sh` verifies the working copy against the baseline at `HEAD` on every run,
including runs that download nothing. An archive and its baseline move together, so publish through
the scripts, which do both:

```bash
scripts/publish-libs.sh libmongoc_arm64.a libmongoc_x86_64.a libmongoc_universal.a libmongoc.a
git add Libs/checksums.sha256 && git commit -m "build: update static library checksums"
```

- Name every library you rebuilt. `publish-libs.sh` verifies each one you did not name against the
  checksums at `HEAD`, regenerates `Libs/checksums.sha256` and uploads the archive with `--clobber`.
- The iOS xcframeworks go through `scripts/publish-ios-libs.sh`, then a commit of
  `Libs/ios/checksums.sha256`. It takes `--dry-run` and refuses a publish that changes nothing.
- `libs-v1` predates release immutability, so GitHub keeps it mutable. Both scripts stop before
  touching a checksum file if it ever reports immutable.
- Never write a checksum file by hand. Regenerating one from a stale `Libs/` reverts every library
  you did not rebuild: that shipped a broken libmongoc and rolled DuckDB back a version.
- Never upload with a bare `tar` and `gh release upload`. That put 299 MB on the release with no
  baseline behind it, and the next `download-libs.sh` run stopped on every machine and CI job.

## The release pipeline

`.github/workflows/build.yml` runs on a `v*` tag push or a manual dispatch, and a run is never
cancelled (concurrency group `build-tablepro-<ref>`). Every job except the two builds needs a `v*`
ref, so a dispatch from a branch only builds. The tag runs no test suite.

- `Tested on main` (Ubuntu) fails when the tagged commit is not an ancestor of `origin/main`.
- For `macOS Tests` and `iOS and Package Tests` separately, it walks up to 50 first-parent commits
  back from the tag. On each it takes the newest push run of that workflow and waits for it if it is
  still going. A commit with no run, or whose job was skipped, is passed over; any conclusion other
  than success fails the release.
- A passing run counts only when `scripts/ci/detect-changed-paths.sh --base <that commit> <suite>`
  prints `false`, so nothing the suite reads changed between that commit and the tag. The step
  summary names the covering run for each suite.
- The two suites may be covered by different commits. Requiring one commit for both would fail
  whenever only one suite ran later.
- `Build arm64` and `Build x86_64` run on `xcode-27` with no fail-fast; x86_64 cross-compiles on an
  arm64 runner. Each runs `scripts/build-release.sh` with notarization, then makes the DMG and the
  tar.xz update archive.
- `Registry Readiness` (Ubuntu) runs `scripts/check-registry-readiness.py` with `--floor` and
  `--current` set to the two kit versions in `TablePro/Core/Plugins/PluginManager.swift`. It fails
  when a registry driver has no binary in that range, so the app never ships ahead of its plugins.
- `Create GitHub Release` needs all three and runs under the `release` environment. It fails when
  the tag disagrees with `MARKETING_VERSION` (`tag v... does not match MARKETING_VERSION ...`).
- It also fails when `CURRENT_PROJECT_VERSION` is not above the newest published release's. Sparkle
  compares that number as `<sparkle:version>`, so a flat one ships a release no install is offered.
- It signs both update archives with the Sparkle key and takes the notes from `CHANGELOG.md`.
- It checks that the appcast deploy key works before publishing anything. Then it puts both DMGs
  and both update archives on a draft release, publishes the draft in one step, and only then
  commits `appcast.xml`, whose download URLs 404 until the release is public.
- The appcast is merged with the tag's own copy of `scripts/ci/merge-appcast.py` and pushed with
  `APPCAST_DEPLOY_KEY`, up to 3 attempts, each re-merging onto the current `origin/main`.
- `generate_appcast` sees only the new release. The merge script splices its items in and moves
  published items byte for byte, because Sparkle rewrites an existing item's download URL and drops
  its notes when a staged archive matches it.
- A tag containing `-alpha`, `-beta` or `-rc` publishes as a prerelease.

## Keys and rulesets

- `main` takes no direct push. Its ruleset requires the checks `AGENTS.md` lists under CI, and
  deploy keys bypass it, so the appcast push and the release commit push need no check run.
- The appcast push uses `APPCAST_DEPLOY_KEY`, a write deploy key held by the `release` environment,
  which only `v*` tags can use.
- The release commit and a withdrawal push with the release key, `~/.ssh/tablepro_release`, a second
  write deploy key. The release skill's pre-flight step 7 creates it the first time a release needs
  it.
- The release key has a passphrase and is never added to ssh-agent: agents run on the maintainer's
  Mac and the key skips every check, so only the maintainer runs a push with it.
- The push command is in `.claude/skills/release/SKILL.md`, Commit, tag, push.
- The `v*` tag ruleset lets only admins create, move or delete a release tag.

## When a release run fails

- A published release is immutable: GitHub refuses to add, replace or delete an asset, or to move
  the tag.
- Before **Publish the release**, only a draft exists. Fix forward on `main` through a pull request,
  then move the tag to the commit it lands as. The next run reuses the draft.

  ```bash
  git fetch origin main
  git tag -f -a v<version> -m "v<version>" origin/main
  git push origin v<version> --force
  ```

- After it (a failed `appcast.xml` push, say), use **Re-run failed jobs**: the release job finds the
  same files already published and carries on. **Re-run all jobs** rebuilds, and the release job
  refuses the new files.
- A published build that is wrong ships as a new version.

## Staged rollout and critical updates

- An ordinary release carries
  `<sparkle:phasedRolloutInterval>21600</sparkle:phasedRolloutInterval>`. Sparkle splits installs
  into seven cohorts by a per-install random id, so the last cohort is offered the build 36 hours
  after the first. **Check for Updates…** is never phased.
- `"criticalUpdate": true` in `.github/release-flags.json` passes `--critical-update-version ""` to
  `generate_appcast` instead. That writes `<sparkle:criticalUpdate/>` with no version, critical for
  every host: Sparkle skips phasing, hides Skip and Remind Me Later, retitles the alert, and shows
  it even under automatic downloads.
- The release job fails when the flag is `true` and the file has not changed since the previous
  tag, which is what a leftover flag looks like.
- When to set it: `.claude/skills/release/SKILL.md`, Critical update flag.

## Withdrawing a release

Removing the version's items from `appcast.xml` is the only way to un-ship a Sparkle release.

```bash
python3 scripts/ci/pull-release.py <version> --dry-run     # reports what it would remove
GIT_SSH_COMMAND='ssh -i ~/.ssh/tablepro_release -o IdentitiesOnly=yes' \
    python3 scripts/ci/pull-release.py <version>           # edits, commits and pushes to main
```

- The second command pushes with the release key, so the maintainer runs it (Keys and rulesets).
- It refuses to push from any branch but `main`, or when local `main` is not `origin/main`, since
  the key would carry any other commit past every check. It also refuses to empty the feed.
- The GitHub release stays up, so a direct download link still resolves. Users already on the bad
  build are reached by shipping the fix.

## Plugins

- `.github/workflows/build-plugin.yml` runs on a `plugin-*-v*` tag, or on a dispatch with `tags`
  (`tag[:pluginKitVersion],...`) and an optional `baseRef`. Runs are grouped per ref and per matrix
  tag and never cancelled.
- `Resolve Plugin Tags` (Ubuntu) picks the runner: `macos-26` when the ref being built pins Xcode 26
  in its own `.github/actions/setup-xcode`, else `xcode-27`.
- It runs `.github/scripts/test_update_registry.py` and `scripts/ci/check-plugin-manifest.py`, and
  validates each tag against `^plugin-[a-z0-9-]+-v[0-9]+\.[0-9]+\.[0-9]+$` and each kit version as
  an integer. A tag given without a kit version takes `currentPluginKitVersion`.
- The build job checks out `baseRef` when one is given. It builds the Dameng bridge for
  `plugin-dameng-*`, a universal HANA helper plus `govulncheck` for `plugin-hana-*`, then runs
  `scripts/build-plugin.sh "$TARGET" both "$VERSION"` with notarization.
- Before publishing: `scripts/ci/verify-plugin-loads.sh` dlopens the arm64 bundle beside its
  PluginKit framework; both zips must be stapled and accepted by Gatekeeper; the built
  `TableProPluginKitVersion` must equal the release label.
- It publishes the release from a draft, then records the binary in the TableProApp/plugins registry
  with `.github/scripts/update-registry.py`. The registry decides which binary a user gets:
  [Plugin Registry](https://docs.tablepro.app/development/plugin-registry) covers the manifest, the
  tag names and the bulk re-release after a PluginKit ABI change.
