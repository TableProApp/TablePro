# Releasing

The macOS app, its registry plugins, the static libraries and the manual iOS flow. Linux: `linux/docs/releasing.md`. Commands run from the repository root; a path in prose is relative to `apple/`. An agent runs them when the maintainer says to release. The maintainer decides what ships and whether it is critical.

## Channels

- One EdDSA-signed appcast, `https://updates.tablepro.app/appcast.xml`, carries stable and beta items. The app takes betas only while Settings > General > Get beta updates is on.
- A stable rolls out in phases of 21600 s. A beta is not phased and is a GitHub prerelease.
- Critical means a security fix or data loss, nothing else: ` [CRITICAL]` on the version's `CHANGELOG.md` heading, never on a beta. Later stables carry it forward.
- The legacy `appcast.xml` on `main`, the feed of apps up to 0.81, ends at 0.82.0. No release writes it.

## Storage check

Sparkle never downgrades, so a release never writes storage the previous stable cannot read. Before beta.1, before every stable, and on a pick that touches the `.claude/rules/data-sync-storage.md` paths, list the commits on those paths and read each for a changed storage or sync format:

```bash
awk -F'"' '/^  - "/ {print ":(glob)" $2}' .claude/rules/data-sync-storage.md \
  | xargs git log --oneline --no-merges v<previous stable>..<commit> --
```

Such a change stops the release until a fix lands on `main`.

## Versions

- A tag is `vX.Y.Z` or `vX.Y.0-beta.N`, N from 1 to 98, MINOR at most 999, PATCH at most 99. There is no `-rc`.
- The build is `((MAJOR*1000+MINOR)*100+PATCH)*100+R`, R being N for a beta and 99 for a stable: `v0.83.0-beta.1` is 830001. A local build is `0.0.0-dev`, build 1.
- `python3 apple/scripts/release/version.py parse <tag>` prints the version, build, channel and line. `version.py check <tag>` is the gate `verify` runs; read it for the rules.

## Branches

- `release/X.Y` is cut from `main` at beta.1 and closes when X.(Y+1).0 ships. A later security or data-loss fix for its users ships as a critical patch on the current line.
- Every fix lands on `main` first. A pick is one fix per PR, never a `feat` or a PluginKit bump. A patch takes only a regression from the previous stable, a crash, a plugin that fails to load, a security fix or data loss.
- `release/0.82` predates the move into `apple/` and follows the `RELEASING.md` on that branch: paths at the root, no `ci.yml`, and a `verify` that waits up to 240 min for green macOS Tests, iOS and Package Tests and Release Build push runs covering the tag. A pick from `main` relies on rename detection.

```bash
git fetch origin && git switch -c backport/<PR>-X.Y origin/release/X.Y
git cherry-pick -x <merge commit> && git push -u origin HEAD
gh pr create --base release/X.Y --title "$(git log -1 --format=%s <merge commit>)" --body "Pick of #<PR>."
gh pr merge --auto --squash
```

## Train

- Monday: promote the newest beta if it is at least 72 h old with no open regression issue, then cut the next beta.1.
- Patches Tuesday to Thursday.
- Friday to Sunday: critical fixes only.
- Triage a regression within one working day.

## Tagging

A tag goes on a line commit once that commit's CI push run is green. Tags never move, so check the tag before it leaves the machine: `version.py check` runs the same gate as `verify`.

```bash
git fetch origin --tags
gh run list --workflow ci.yml --branch release/X.Y --event push --commit <commit>
gh run watch <run id> --exit-status
git tag -s <tag> -m <tag> <commit>
python3 apple/scripts/release/version.py check <tag> && git push origin <tag>
```

On an error, `git tag -d <tag>`, fix the cause and tag again.

## Cutting a beta

1. beta.1 only: `main` has the last stable's forward-port. Cut the line at the newest `main` commit with a green CI push run, after the storage check up to it:

   ```bash
   git fetch origin
   sha="$(gh run list --workflow ci.yml --branch main --event push --status success --limit 1 --json headSha -q '.[0].headSha')"
   # Storage check: v<previous stable>..$sha
   git push origin "$sha:refs/heads/release/X.Y"
   ```

2. Tag `origin/release/X.Y` as `vX.Y.0-beta.N` (Tagging).

A beta gets no `CHANGELOG.md` section: its notes are a towncrier draft of the fragments at the tag.

## Cutting a stable or patch

1. Run the storage check from the previous stable to `origin/release/X.Y`.
2. X.Y.0 only: no shipped source landed on the line after the newest beta, so this prints `false`. On `true`, tag beta.N+1 first.

   ```bash
   scripts/ci/detect-changed-paths.sh --base vX.Y.0-beta.N --head origin/release/X.Y shipped
   ```

3. Ask the maintainer whether it is critical.
4. Open the release PR. Curate on its branch: add a missing fragment, reword one that says more than its PR did (`.claude/rules/changelog.md`).

   ```bash
   git fetch origin && git switch -c prep/vX.Y.Z origin/release/X.Y
   # Curate apple/changelog.d/ here.
   .venv/bin/python apple/scripts/release/notes.py assemble X.Y.Z
   # X.Y.0: type the lead under the heading. Critical: append ' [CRITICAL]' to the heading.
   git add apple/CHANGELOG.md && git commit -m "chore(release): vX.Y.Z" && git push -u origin HEAD
   gh pr create --base release/X.Y --title "chore(release): vX.Y.Z" --body "Release notes for vX.Y.Z."
   gh pr merge --auto --squash
   ```

5. Tag its merge commit, `gh pr view <PR> --json mergeCommit -q .mergeCommit.oid`, as `vX.Y.Z` (Tagging).

### Notes

- `assemble` builds the section from `changelog.d/`, credits outside authors and deletes the fragments. It needs the towncrier venv (root `RELEASING.md`, Notes).
- The lead, X.Y.0 only, is at most 6 plain lines, none starting with `#` or `- `, naming what a reader would change their behavior over. What's New, the Sparkle notes and the Telegram post then show only the lead.

## Forward-port

Once a stable or patch publishes, cherry-pick its release commit to `main`, and to a newer open line when one exists. The next tag refuses to build without its heading.

```bash
git fetch origin && git switch -c forward/vX.Y.Z origin/main
git cherry-pick -x <release commit> && git push -u origin HEAD
gh pr create --base main --title "chore(release): vX.Y.Z" --body "Forward-port of #<PR>."
gh pr merge --auto --squash
```

- A newer open line gets the same PR from `origin/release/<line>`, with `--base release/<line>`.
- A conflict on a fragment: `git rm` it. On `CHANGELOG.md`: keep both sections, in version order.
- Then `python3 apple/scripts/release/notes.py docs X.Y.Z --ref vX.Y.Z --mdx ../tablepro-docs/changelog.mdx` goes into a `docs(changelog): vX.Y.Z` PR in TableProApp/docs, merged by hand once green.

## When a run fails

Nothing reaches users before the `github-release` job of `release.yml`.

- Tags never move, with no bypass. A burned number stays burned; the fix ships as the next number.
- `verify` names the broken rule, or the CI run that is still going, red or missing. Once that run is green: `gh run rerun <release run> --failed`.
- An infrastructure failure (runner, network, notary service) is the same re-run, before or after publishing: each step skips what is done. A code failure is fixed on `main`, picked, and ships as the next number.
- A stable that never published: the next release PR runs `git revert <its release commit>` before `assemble`, and `gh release delete vX.Y.Z --yes` removes a leftover draft.
- A stable builds only on a GA Xcode (`setup-xcode` `require-release`). With none on the runner image, `app` and `plugins` fail, and a PR points `.github/actions/setup-xcode` at an image that has one. Betas still ship.

## Withdrawing a release

```bash
gh workflow run withdraw.yml --ref v<newest tag> -f version=X.Y.Z
```

- Only when a build loses data, fails to launch or breaks connecting, and the fix is more than minutes away.
- It removes the version's feed items and plugin releases, re-signs the feed, marks the highest stable left as Latest and redeploys. It refuses to leave the feed with no stable item. The `--ref` is a tag: the `release` environment allows only `v*`. The GitHub release stays. The fix ships as the next number, critical when data was lost.

## Keys

- The `signing` and `release` environments hold the secrets `release.yml` names. They and `github-pages` allow only `v*` tags and have no reviewer: only admins create those tags.
- `.github/actions/apple-signing` stores the App Store Connect key as the `TablePro` notarytool profile, and warns when the Developer ID certificate expires within 60 days.
- The maintainer holds an offline backup of the Sparkle EdDSA key. It never rotates without a signed transition, since every app from 0.82 verifies the feed with it.
- `feed.py` refuses an `appcast.xml` whose signature does not verify, so a hand edit to `gh-pages` is re-signed with `sign_update`.

## Plugins

- One tag builds every registry plugin in `.github/plugin-registry.json`. The zips are assets of the app's release, at its version and build. There are no plugin tags.
- Retention per channel, kit and `minimumSystemVersion`: the two highest builds stay, a beta goes once a stable with the same key has a higher build, and a kit below `retainFromPluginKit` goes.
- Check `retainFromPluginKit` only when `TABLEPRO_PLUGINKIT_VERSION` changes. It is the kit of the oldest app version still on at least 1% of the machines seen in the last 30 days (license dashboard, App Versions), raised with a normal PR. The manifest keeps the higher of its own value and the tag's, so an older line never lowers it. ABI: `.claude/rules/plugin-system.md`.

## Static libraries

`Libs/` comes from the `libs-<n>` release that `Libs/release` names. A rebuilt, added or removed library ships as the next `<n>`: `apple/scripts/publish-libs.sh <lib.a | Name.xcframework>...` names each one, checks the rest against `HEAD`, publishes, and rewrites `Libs/release` and both checksum files, which a `build(libs): publish libs-<n>` PR commits. `--dry-run` only prints. From `libs-2` on, each is an immutable release; `libs-v1` is not, and stays for older commits.

## iOS

By hand, on a Mac with the team's signing identity.

1. A PR raises `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `Configs/Version-iOS.xcconfig`. The build goes up on every upload.
2. `apple/scripts/download-libs.sh && apple/scripts/generate-project.sh ios`, then archive the `TableProMobile` scheme for Any iOS Device in Xcode.
3. Organizer: Distribute App to App Store Connect.
4. TestFlight: test with internal testers.
5. Submit for App Store review, and release once approved.
6. `git tag -s ios-vX.Y.Z -m ios-vX.Y.Z <bump commit> && git push origin ios-vX.Y.Z`. Never a `v*` tag: that starts `release.yml` and moves the PluginKit ABI baseline.
