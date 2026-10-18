# Releasing

This runbook covers the macOS app, its registry plugins and the static libraries; the iOS app ships by hand, and the Linux app's runbook is `linux/docs/releasing.md`. The `release` skill (`.claude/skills/release/SKILL.md`) decides what ships and points at the sections here. Every command below is the maintainer's to run.

## Channels

- Stable and beta share one appcast, `https://updates.tablepro.app/appcast.xml`. A beta item carries `<sparkle:channel>beta</sparkle:channel>`.
- The app takes betas only while Settings > General > Get beta updates is on (`allowedChannels(for:)`). The key, `com.TablePro.updates.receivesBetaUpdates`, can be pinned by a configuration profile ([Managed updates](https://docs.tablepro.app/security/managed-updates)).
- Sparkle never downgrades: with the toggle off, a beta install keeps its beta until a stable passes it. So a beta never writes storage the previous stable cannot read (`.claude/rules/data-sync-storage.md`).
- A stable rolls out in phases of 21600 s. A beta is not phased, and on GitHub it is a prerelease. Latest goes only to the highest stable, so a patch on an older line publishes with `--latest=false`.
- Critical means a security fix or data loss, nothing else. It is ` [CRITICAL]` on the version's `CHANGELOG.md` heading, never on a beta. Every later stable item carries the highest critical build forward (`sparkle:criticalUpdate sparkle:version`).
- CI writes the orphan `gh-pages` branch, which holds `appcast.xml` and the v3 plugin manifest (`https://updates.tablepro.app/plugins/v3.json`), and `pages.yml` deploys it to `updates.tablepro.app`. The appcast is EdDSA-signed, and the app requires that (`SURequireSignedFeed`, `SUVerifyUpdateBeforeExtraction`).
- The legacy `appcast.xml` on `main` is the `SUFeedURL` of apps up to 0.81 (`https://raw.githubusercontent.com/TableProApp/TablePro/main/appcast.xml`), and `plugins.json` in TableProApp/plugins is their registry. No tag writes either. The tablepro.app download button and the Homebrew cask `tablepro` read the same appcast. v0.82.0 is the one bridge. Once it publishes, TableProApp/web moves to the new feed. Then a PR copies the v0.82.0 feed item verbatim into the legacy `appcast.xml`, a PR in TableProApp/plugins points `plugins.json` at its plugin zips, and a Homebrew/homebrew-cask PR moves `tablepro` to `TablePro-#{version}.dmg`, with livecheck on the new feed's items that have no channel. Both files then freeze.

## Versions

- A tag is `vX.Y.Z` or `vX.Y.0-beta.N`, N from 1 to 98. There is no `-rc`.
- `MARKETING_VERSION` is the tag without the `v`. The build, `CURRENT_PROJECT_VERSION`, is `((MAJOR*1000+MINOR)*100+PATCH)*100+R`, where R is N for a beta and 99 for a stable: `v0.82.0-beta.1` is 820001, `v0.82.0` is 820099, `v0.82.1` is 820199. MINOR stays at most 999 and PATCH at most 99.
- A local build is `0.0.0-dev`, build 1 (`project.yml`, `settings.base`). `scripts/release/version.py parse <tag>` prints a tag's version, build, channel and line. Every "is newer" check, in the app and in the plugin manifest, compares the build (`CFBundleVersion`).
- Every X.Y.0 ships at least one published `vX.Y.0-beta.N` first; patches go straight to stable. When each ships: Schedule.
- One universal build, arm64 and x86_64. It becomes arm64-only once the deployment target reaches macOS 27.

## Branches

- An admin cuts `release/<X.Y>` from a green `main` commit at beta.1. Only admins create `release/*` branches.
- Every fix lands on `main` first, then reaches the line through a cherry-pick PR from `backport/<PR>-<X.Y>`: one fix per PR, titled with the original subject and its ` (#N)`, which is the provenance. A release PR comes from `prep/v<X.Y.Z>`. No PR head branch lives under `release/*`.
- A line closes when `X.(Y+1).0` ships. A later security or data-loss fix for its users ships as a critical patch on the current stable line. At most two lines are live.
- After a stable or patch publishes, a PR with the same title cherry-picks its release commit to `main`, and to a newer open line when one exists. The next tag refuses to build until it has.

## Schedule

Tags go out between 13:00 and 15:00 ICT (UTC+7).

- Monday, the train: promote the open line's newest beta to `vX.Y.0` when the gate passes, forward-port it, then cut `release/X.(Y+1)` from the newest green `main` commit and tag its beta.1. The forward-port merges first: `version.py` refuses beta.1 of X.(Y+1) until `main` has `## [X.Y.0]`.
- The gate: the line is 7 days old; its newest beta is at least 72 h old and nothing outside `CHANGELOG.md` and `changelog.d/` landed on the line after it; no open issue is labeled `regression`; the storage check passes (`.claude/skills/release/SKILL.md`, section 4).
- When the gate fails, nothing is promoted or cut. Fix on `main`, pick it, and ship beta.N+1. Promote it on the first Tuesday to Thursday when it is 48 h old with no open `regression` issue, and cut the next beta.1 the same day. That line's train is the first Monday it is 7 days old.
- Tuesday to Thursday: a beta.N when the line has picks, at most one a day. A patch `X.Y.Z` goes straight to stable, only for a regression from the previous stable, a crash, a plugin that fails to load, a security fix or data loss.
- Friday to Sunday: no tags, except a critical release or the fix for a build that fails to launch, update or connect.
- No train on 2026-12-21, 2026-12-28 or in the Tet week (2027-02-08). Betas and patches still ship on their days.
- An issue against a `-beta.N` build is triaged within one working day and labeled `regression` when it worked in the previous stable.

## Notes

- Fragments in `changelog.d/` (`.claude/rules/changelog.md`) become a `CHANGELOG.md` section. The tooling needs towncrier: `python3 -m venv .venv && .venv/bin/pip install --require-hashes -r scripts/release/requirements.txt`.
- `.venv/bin/python scripts/release/notes.py assemble X.Y.Z [--date YYYY-MM-DD]` runs on `prep/v<X.Y.Z>`. It refuses a beta, an empty `changelog.d/`, and a version `CHANGELOG.md` already has. It credits each fragment ` by @login` when its PR's author is not an OWNER or MEMBER (read with `gh`), then runs `towncrier build`, which deletes the fragments and stages `CHANGELOG.md`.
- The lead: X.Y.0 only, at most 6 plain lines, typed under the heading in the release PR, naming what a reader would change their behavior over. With a lead, What's New, the Sparkle notes and the Telegram post show only the lead. Without one, the Sparkle notes carry the whole section and What's New points at the changelog.
- A beta gets no section. Its GitHub release body and feed notes are a towncrier draft of the fragments at the tag.

## Cutting a beta

beta.1 cuts the line at the newest `main` commit whose push runs are all green; beta.N tags the line's head once the picks are on it.

```bash
git fetch origin
git push origin <sha>:refs/heads/release/X.Y  # beta.1 only
gh label create "backport release/X.Y"  # beta.1 only
git tag -s vX.Y.0-beta.N -m vX.Y.0-beta.N origin/release/X.Y
git push origin vX.Y.0-beta.N
```

## Cutting a stable or patch

```bash
git fetch origin
git switch -c prep/vX.Y.Z origin/release/X.Y
.venv/bin/python scripts/release/notes.py assemble X.Y.Z
# X.Y.0: type the lead under the heading; critical: append ' [CRITICAL]' to it
git add CHANGELOG.md
git commit -m "chore(release): vX.Y.Z"
git push -u origin prep/vX.Y.Z
gh pr create --base release/X.Y --title "chore(release): vX.Y.Z" --body "Release notes for vX.Y.Z."
```

The PR changes only `CHANGELOG.md` and `changelog.d/`; PR title refuses anything else. Squash-merge it, then tag its merge commit:

```bash
git fetch origin
git tag -s vX.Y.Z -m vX.Y.Z "$(gh pr view <PR> --json mergeCommit -q .mergeCommit.oid)"
git push origin vX.Y.Z
```

After the run publishes, forward-port the release commit, then write the docs changelog:

```bash
git fetch origin
git switch -c forward/vX.Y.Z origin/main
git cherry-pick <release commit>
git push -u origin forward/vX.Y.Z
gh pr create --base main --title "chore(release): vX.Y.Z" --body "Forward-port of #<PR>."
python3 scripts/release/notes.py docs X.Y.Z --ref vX.Y.Z --mdx ../tablepro-docs/changelog.mdx
```

- A cherry-pick conflict on a fragment reworded on `main`: delete the fragment; on `CHANGELOG.md`: keep both sections, in version order. The docs PR is `docs(changelog): vX.Y.Z` in TableProApp/docs, opened with the maintainer's own `gh` (a PR opened with `GITHUB_TOKEN` starts no workflows) and merged once the release is published.

## What a tag runs

A `v*` tag runs `release.yml` and nothing else. A run is never cancelled, and every job reads the version, build and channel from `verify`.

- `verify`: `version.py check` refuses a tag that breaks the grammar or the bounds; that `origin/release/<X.Y>` does not contain; whose previous tag on the line is not its ancestor; a stable X.Y.0 with no published beta, or a beta after its X.Y.0; a stable whose tree differs from its line's newest published beta outside `CHANGELOG.md` and `changelog.d/`, until a stable tag on the line has matched that beta; a `CHANGELOG.md` missing the stable's heading, or a published stable of this or the previous line below it; a stable whose tag still holds fragments in `changelog.d/`. Then it needs macOS Tests, iOS and Package Tests and Release Build green on the tag commit or the nearest first-parent commit that ran them, with no change to the files they read after it, waiting on a pending run. Last, it writes the notes.
- `app` (`signing`): a GA Xcode for a stable (`setup-xcode` `require-release`), the CloudKit Production schema check, `build.sh app` (archive, export with `scripts/release/ExportOptions.plist`, universal and plugin load checks), `notarize.sh` on the app, `package.sh app`, `notarize.sh` on the DMG.
- `plugins` (`signing`): the Dameng and HANA bridges, `build.sh plugins` (each target `registry.py targets` prints, universal, signed with Developer ID, the hardened runtime and a timestamp), one notary submission for all, `package.sh plugins` (the zips, described as the manifest will read them).
- `github-release`: `actions/attest` attests `dist/*`; `gh release create` drafts, uploads and publishes; `gh release verify` and `verify-asset` check the published release.
- `feed` (`release`): `feed.py add` checks the published appcast's signature, downloads the archive and the zips from the release, checks each with `gh release verify-asset`, runs `generate_appcast` and `registry.add`, checks the new item, and the job pushes `gh-pages`. The feed and withdraw jobs share the concurrency group `gh-pages` with `queue: max`.
- `pages` deploys `gh-pages`. `notify`, stable only and allowed to fail, posts the lead to Telegram.
- Assets: `TablePro-<v>.dmg`, `TablePro-<v>.tar.xz` (the Sparkle archive), `TablePro-<v>-dSYMs.zip`, `TablePro-<v>-Plugins-dSYMs.zip` and one `<Target>-<v>.zip` per registry plugin.

## When a run fails

- Tags never move. Before `github-release` publishes, an infrastructure failure is a re-run of the failed jobs; a code failure is fixed on `main`, picked to the line, and ships as the next number.
- After it publishes: **Re-run failed jobs**. Every later step skips what is done: a published release, a feed item with the same version and build, or a manifest release with the same build and sha256.
- A stable that never published: the next release PR runs `git revert <its release commit>` before `notes.py assemble`, and the leftover draft goes (`gh release delete vX.Y.Z`).
- No GA Xcode on the runner image fails a stable in `app`. The fix is a PR pointing `.github/actions/setup-xcode` at a GA Xcode on an image that has one. Betas still ship.

## Withdrawing a release

```bash
gh workflow run withdraw.yml --ref v<newest tag> -f version=X.Y.Z
```

- It removes the version's feed items and plugin releases, re-signs the feed, marks the highest stable left as Latest, and redeploys. It refuses to leave the feed with no stable item. The `--ref` is a tag because the `release` environment allows only `v*` tags.
- The GitHub release stays. The fix ships as the next number, critical when the bad build loses data.

## Keys and environments

| Environment | Refs | Secrets |
|---|---|---|
| `signing` | tags `v*` | `CERTIFICATES_P12`, `CERTIFICATES_PASSWORD`, `PROVISIONING_PROFILE`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `ANALYTICS_HMAC_SECRET`, `CLOUDKIT_MANAGEMENT_TOKEN` |
| `release` | tags `v*` | `SPARKLE_PRIVATE_KEY`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` |
| `github-pages` | tags `v*` | none |

- No repo-level secret or deploy key is left, and no environment above has required reviewers: admin-only, immutable tags are the gate. `linux-release` also deploys from `main`, so it takes a reviewer (`linux/docs/releasing.md`). Rulesets: `.claude/rules/ci.md`, Rulesets.
- Notarization uses the App Store Connect API key, which `.github/actions/apple-signing` stores as the `TablePro` notarytool profile. The action warns when the certificate expires within 60 days.
- An offline backup of the Sparkle EdDSA key exists and the maintainer holds it. The key never rotates without a signed transition, since every app from 0.82 verifies the feed with it.
- `gh-pages` takes pushes from `github-actions[bot]` with `GITHUB_TOKEN` and has no required checks. `feed.py add` and `withdraw` refuse an `appcast.xml` whose signature does not verify, so a hand edit is re-signed with `sign_update` before it is pushed.
- `updates.tablepro.app` enforces HTTPS (Settings > Pages).

## Plugins

- One tag builds the app and every registry plugin, and the plugin zips are assets of the app's release. Each plugin's version and build are the app's. There are no plugin tags.
- `.github/plugin-registry.json` holds `retainFromPluginKit` and the publish set, keyed by target, with each plugin's `name`. Bundled plugins are not in it.
- The v3 manifest lists each plugin's releases: version, build, channel, PluginKit version, `minimumSystemVersion`, URL and sha256. The bundle id, `databaseTypeIds` and `exportFormatIds` come from the built bundle.
- Selection: a release in the running build's channel (a `-beta.N` or local build takes beta and stable, any other stable only), with its PluginKit version in the app's range and its `minimumSystemVersion` at or below the running macOS. The highest build wins. Installed registry plugins update after the app does.
- Retention per channel, kit and `minimumSystemVersion`: the two highest builds stay; a beta goes once a stable with the same key has a higher build; a kit below `retainFromPluginKit` goes. A release pruned on arrival is a logged no-op.
- `retainFromPluginKit` is the kit of the oldest app version still on at least 1% of the machines seen in the last 30 days (license dashboard, App Versions). Check it before each stable and raise it with a normal PR. The manifest keeps the higher of its own value and the tag's, so an older line never lowers it.
- Accepted risks: the manifest is trusted through HTTPS, the plugin's Team ID check and the sha256, so a rollback or freeze of the manifest goes undetected.
- PluginKit ABI rules and when the kit version moves: `.claude/rules/plugin-system.md`, ABI.

## Static libraries

The `.a` files under `Libs/` and the xcframeworks under `Libs/ios/` live on the immutable `libs-<n>` GitHub release that `Libs/release` names, not in git; `scripts/download-libs.sh` fetches it and verifies every file against the checksums at `HEAD`. `scripts/publish-libs.sh` takes every library you rebuilt, added or removed, verifies the others against `HEAD`, creates the next `libs-<n>` and rewrites `Libs/release` and both checksum files (`--dry-run` only prints). A published `libs-<n>` never changes: a fix is the next `<n>`. Each library is built by a `build-*.sh` in `scripts/` or `scripts/ios/`.

```bash
scripts/publish-libs.sh libmongoc_arm64.a libmongoc_x86_64.a libmongoc_universal.a libmongoc.a
git add Libs/release Libs/checksums.sha256 Libs/ios/checksums.sha256 && git commit -m "build(libs): publish libs-<n>"
```

## Reproducing a Release build

```bash
export VERSION=0.0.0-dev BUILD=9999999
scripts/download-libs.sh && scripts/generate-project.sh macos
scripts/release/build.sh app --unsigned && scripts/release/package.sh app --unsigned
scripts/build-dameng.sh both && scripts/build-hana.sh both
scripts/release/build.sh plugins --unsigned && scripts/release/package.sh plugins --unsigned
```

- `build.sh` writes `build/release/` (xcodebuild logs in `build/release/logs/`), `package.sh` writes `dist/`. CI builds the same in Release Build (`.claude/rules/ci.md`, Release Build). Signed: drop `--unsigned`, export the tag's `VERSION` and `BUILD`, and have the Developer ID identity and the provisioning profile `ExportOptions.plist` names. `notarize.sh <path>...` needs the profile `xcrun notarytool store-credentials TablePro --key <p8> --key-id <id> --issuer <issuer>` creates.
