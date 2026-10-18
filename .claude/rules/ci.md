---
paths:
  - ".github/workflows/**/*"
  - ".github/actions/**/*"
  - ".github/actionlint.yaml"
  - ".github/*baseline*"
  - "scripts/ci/**/*"
  - "scripts/release/**/*"
  - ".swiftlint.yml"
  - "**/.swiftlint.yml"
---

# CI

The required check names are in `AGENTS.md` (CI). Reading a red check: `.claude/skills/fix-issue/references/verification-apple.md`, Reading CI. Release tags: `RELEASING.md`.

## Rulesets

| Ruleset | Refs | Rules | Bypass |
|---|---|---|---|
| 25308039 "tags never move" | tags `v*`, `libs-*` | update, deletion | none |
| 23959123 "release tags are created by admins" | tags `v*`, `libs-*`, `plugin-*` | creation | admins |
| 25308049 "release branches are created by admins" | `release/*` | creation | admins |
| 23957966 "main and release branches require green gates" | default branch, `release/*` | the five required checks, `do_not_enforce_on_create` | none |
| 25129799 "branches keep their history" | default branch, `release/*`, `gh-pages` | deletion, non-fast-forward | none |

- `gh-pages` takes no required checks (`RELEASING.md`, Keys and environments).
- There are no gate jobs. A test job runs on `!cancelled() && needs.changes.outputs.run != 'false'`. A job its `if:` skips reports success, and a failed changes job runs the suite rather than skipping it.
- `Changes (macOS)`, `Changes (iOS)` and `Changes (Release)` are not required checks.
- A PR need not be up to date with main to merge (`strict_required_status_checks_policy: false`).
- A required check's name is its job's `name:`. Renaming a job changes the ruleset in the same change, and every open PR then merges main in before its checks report the new name.

## Runners and toolchain

- Every Xcode job in the test and release workflows runs on the `xcode-27` runner label, a GitHub preview image. actionlint learns the label from `.github/actionlint.yaml`. A stable tag builds only on a GA Xcode: `setup-xcode` with `require-release` fails on a beta or Release Candidate.
- The Xcode version is written once, in `.github/actions/setup-xcode/action.yml`, which runs `xcode-select --switch` and prints `xcodebuild -version`. A workflow never selects Xcode another way.
- XcodeGen comes from `.github/actions/setup-xcodegen`, pinned by version and SHA-256.
- `scripts/release/feed.py` runs Sparkle's `generate_appcast` and `sign_update` from `SPARKLE_BIN`, which `.github/actions/setup-sparkle` sets. The action reads the version and revision from the app's `Package.resolved` (`project.yml` pins Sparkle with `exactVersion`) and checks the archive against the checksum in Sparkle's `Package.swift` at that revision.
- The compilation cache is off on CI (`COMPILATION_CACHE_ENABLE_CACHING=NO`); `Configs/Base.xcconfig` turns it on locally.

## macOS Tests (`macos-tests.yml`)

- Triggers: pull request, push to main or `release/**`, dispatch. A PR keeps only its newest run; each pushed commit has its own concurrency group and is never cancelled.
- `Changes (macOS)` outputs `run` (detector `macos`) and `plugins` (detector `plugins`). The test job has a 120-minute limit and sets `NSUnbufferedIO=YES`.
- Setup, in order: checkout, setup-xcode, setup-xcodegen, `scripts/download-libs.sh`, `generate-project.sh macos`, SPM restore, resolve, SPM save.
- One `build-for-testing` with no `-testPlan` builds both plans and writes one `.xctestrun` per plan, with signing, the index store and the compilation cache off.
- `COMPILE_PLUGINS` is true on every push and dispatch, and on a PR when the `plugins` detector is not false. It adds Go, the Dameng and HANA bridge builds, `xcodebuild build -scheme AllPlugins`, then `scripts/ci/verify-plugin-loads.sh`.
- `test-without-building -testPlan Unit`, then `-testPlan UI`. The UI plan runs after a Unit failure too, so one round trip reports both.
- No shards, and no parallel, iteration or retry flags: the plans decide.
- `scripts/ci/summarize-xcresult.sh` always runs. Evidence uploads only on failure (`.claude/skills/fix-issue/references/verification-apple.md`, Reading CI).

## iOS and Package Tests (`ios-tests.yml`)

- Triggers and concurrency as macOS Tests. `Changes (iOS)` outputs `run` (detector `ios`) and `oracle` (detector `oracle`).
- 50 minutes on `xcode-27`, simulator `iPhone 18 Pro`. The iOS platform is downloaded only when that simulator is missing.
- `TableProMobileTests` runs with `-parallel-testing-enabled NO`: a second booted simulator killed runs with "(ipc/mig) server died" on the 3-core runner. `TableProMobile/project.yml` says `parallelizable: true`, which every run overrides.
- `swift test --package-path Packages/TableProCore --parallel`, then TableProOracle with `--force-resolved-versions` when its detector is not false. Each step has `if: !cancelled()`, so one red step never hides the next.
- The summary step always runs. Evidence uploads only on failure.

## Release Build (`release-build.yml`)

- Push to main or `release/**`, and dispatch; never a PR. Each commit has its own concurrency group and is never cancelled. Not a required check.
- `Changes (Release)` outputs `run` (detector `release`). `Release Build` runs on `xcode-27` with a 150-minute limit.
- Setup as macOS Tests up to the SPM restore, which it never saves; then Go, `build-dameng.sh both`, `build-hana.sh both` and create-dmg.
- `scripts/release/build.sh app --unsigned` archives the `TablePro` scheme; `build.sh plugins --unsigned` builds `RegistryPlugins` and copies the publish set, the targets `scripts/release/registry.py targets` reads from `.github/plugin-registry.json`, to `build/release/plugins`. Both build universal. They run `lipo -verify_arch` once per arch (arm64, x86_64), since Xcode 27's `lipo` takes one arch per call, then `verify-plugin-loads.sh`.
- `scripts/release/package.sh app 0.0.0-dev --unsigned` writes the release assets: the DMG, the `.tar.xz` (extracted and compared with the app) and the dSYMs zip; `package.sh plugins` writes one zip per plugin and the plugin dSYMs zip.
- The plugins build runs after an app failure too. The xcodebuild logs in `build/release/logs` upload only on failure.

## Release, Withdraw and Pages

- A `v*` tag runs only `release.yml`; its jobs: `RELEASING.md`, What a tag runs. `withdraw.yml` runs only by dispatch, and `pages.yml` runs from both or by dispatch. Their environments allow only `v*` tags, so a dispatch names one with `--ref`.
- Jobs read the tag, version, build and channel only from `verify` outputs passed through `env:`, never through `${{ }}` inside `run:`.
- The default permission is `contents: read`, and each job lists every scope it needs. A job that calls `pages.yml` grants `pages: write` and `id-token: write`, since a called workflow can only lower what it receives.

## Summaries (`scripts/ci/summarize-xcresult.sh`)

- Runs `scripts/lib/xcresult-cases.py summary`. `verify.sh` reads its verdicts through the same parser, and `scripts/lib/test_xcresult_cases.py` tests it in Repo Hygiene.
- Reads `.xcresult` bundles and `swift test` xunit files, and skips a missing input.
- Writes build errors with file and 1-based line, runner failures ("System Failures"), per-bundle counts and minutes, up to 50 failed cases and the 20 slowest to the step summary.
- Exits 1 when a bundle or a `swift test` run executed nothing, because `xcodebuild` and `swift test` both call that success. A runner failure is not an executed test.
- For `X.xml` it also reads `X-swift-testing.xml`.
- It never fails on a failed case; the test step already did.

## SwiftLint (`swiftlint.yml`)

- PR, push to main or `release/**`, dispatch; Ubuntu, 10 minutes.
- Runs the digest-pinned `ghcr.io/realm/swiftlint` image over the whole repo with `lint --strict`. The image's entrypoint is `swiftlint`, so the command never repeats it.
- Fails when stderr has `Invalid configuration` or `is not a valid rule identifier`, because SwiftLint drops a custom rule whose regex does not compile and still exits 0.

## PR title (`pr-title.yml`)

- Runs on opened, edited, reopened and synchronize, so every head commit gets the check.
- Runs `scripts/ci/check-pr-title.py`, then `scripts/ci/check-changelog.py --pr` with `GH_TOKEN` (`pull-requests: read`), then `scripts/check-banned-words.sh` on the PR's added lines and on its body. The banned-words step runs both and exits with the worse result.

## Repo Hygiene (`repo-hygiene.yml`)

- PR, push to main or `release/**`, dispatch, no path filter; Ubuntu, 15 minutes.
- Steps, in order:
  - actionlint, which also shellchecks every inline `run:` block;
  - `shellcheck --severity=warning` on every `*.sh` under `scripts` and `.claude/skills`;
  - the tooling tests: `scripts/ci/test_*.py`, `scripts/lib/test_*.py`, `scripts/test_localization.py` and `scripts/ci/test_libs_release.sh`;
  - `scripts/release/test_*.py` on Python 3.9 from `actions/setup-python`, in a venv that installs `scripts/release/requirements.txt` with `pip --require-hashes`;
  - in the same venv, `check-changelog.py` and `towncrier build --draft --version 0.0.0`, which fails on a fragment name it cannot parse;
  - `check-lib-sourcing.py`, `check-plugin-manifest.py`, `check-plugin-provides.py`, `check-deployment-target.sh`, `check-ios-shared-isolation.py`;
  - `localization.py plugins` and `plugins --target ios`;
  - `check-string-catalogs.py`, `check-license-inventory.py`, `check-entitlements.py`, `check-test-plans.py`;
  - `check-pluginkit-bump-cadence.py`;
  - `scripts/audit-refactor-health.sh --check`, `check-hub-ratchet.py`;
  - the Go checks on the HANA helper, `govulncheck` among them, when the `hana` detector is true. New advisories between changes arrive as Dependabot alerts.
- `audit-refactor-health.sh --check` fails a file defining a production `DatabaseType` outside `Packages/TableProCore/Sources/TableProCoreTypes/DatabaseType.swift`, unless `.github/duplicate-contract-baseline.txt` lists its path. Moving a listed file moves its baseline path in the same commit. Never add an entry to let a new copy pass.
- `check-hub-ratchet.py` fails when an app hub grows past `.github/hub-ratchet-baseline.json`. `--update` only lowers a value, so growing one is a hand edit a reviewer sees.

## Change detector (`scripts/ci/detect-changed-paths.sh`)

- `detect-changed-paths.sh [--base <sha>] macos|plugins|ios|oracle|hana|release` prints `true` or `false`. An unknown suite or flag exits 2.
- A PR passes its base SHA, a push `github.event.before`. No base prints true. The all-zero SHA of a new ref diffs against `git merge-base HEAD origin/main`, so a branch cut from main skips what main already ran; with no merge base it prints true.
- `macos` watches the app, test, plugin, package, native, config and libs folders, `TestPlans/`, `project.yml`, the app's `Package.resolved`, the build scripts and CI scripts it runs, both setup actions and its workflow. `Packages/` covers TableProMacCore.
- `plugins` watches `Plugins/`, `Packages/TableProCore/`, `Packages/TableProOracle/`, `Native/`, `Libs/`, `Configs/`, `project.yml`, the bridge scripts and `verify-plugin-loads.sh`.
- `ios` watches `TableProMobile/`, `Libs/`, `Plugins/TableProPluginKit/` (the package target is a symlink to it), and every `../` path it reads out of `TableProMobile/project.yml`.
- `oracle` watches `Packages/TableProOracle/`; `hana` watches `Native/HanaBridge/`. Each suite also watches its own workflow.
- `release` watches what the Release build reads: the app, plugin, package, native, config and libs folders, `project.yml`, the app's `Package.resolved`, `.github/plugin-registry.json`, `scripts/release/`, the build and CI scripts it runs and both setup actions. It skips `Plugins/*Tests/` and `Packages/*/Tests/`.
- A path a suite newly reads joins that suite's pattern in the same change, or the suite skips on it.
- `CHANGELOG.md` and `changelog.d/` are on no suite's pattern: the What's New phase writes nothing at `0.0.0-dev`, and Repo Hygiene renders every fragment and section instead.

## What runs where

- A pull request: both changes jobs; macOS Tests and iOS and Package Tests unless their detector says false (Oracle only when its detector is not false); SwiftLint; Repo Hygiene; PR title. `AllPlugins` only when the `plugins` detector is not false.
- A push to main or `release/**`: the same minus PR title, plus Release Build; never cancelled, `AllPlugins` always, the SPM cache saved on a miss. Every code push runs both plans in full; a docs-only or changelog-only push skips the suites through the detector.
- A `v*` tag runs only `release.yml`. The test workflows never run on a tag.
- `workflow_dispatch` exists on every workflow except `pr-title.yml` and `release.yml`.
- `build-linux.yml` is on `main` only for its Monday schedule, which GitHub runs from the default branch. Until the Linux app's directory lands on `main`, every build job skips and `weekly-dispatch` starts the workflow on the branch the `LINUX_BRANCH` variable names (the linux branch when unset), whose testing guide describes the jobs.

## Caches and runner budget

- Swift package checkouts live in `~/.spm-cache`, keyed `spm-<os>-<hash of the app's Package.resolved>` with prefix restore. macOS Tests saves it only on a push and only on a miss: a cache saved on a PR ref is visible to that PR alone.
- `release.yml` restores that cache and never saves it, since a save in tag scope is unreadable from other refs.
- `release-build.yml` restores it and leaves the save to macOS Tests.
- There is no other cache: no libs or DerivedData cache, and none in the iOS, plugin or Ubuntu workflows.
- CI fits the GitHub Free and Pro plans: no paid larger runner, no self-hosted Mac. At most 5 macOS jobs run at once, and main runs queue behind PR runs for those slots.

## Writing workflow and lint code

- A SwiftLint custom rule is severity `error`, has a `message` that says what to do and why, and names its files with `included:` or `excluded:`.
- A `scripts/ci/check-*.py` gets a `test_*.py` beside it and a step in Repo Hygiene.
- Prove a new SwiftLint rule fires: plant a violation, run `swiftlint lint --strict --no-cache <file>`, remove it.
- Nested `.swiftlint.yml` files narrow the rules with `only_rules` under `TableProTests`, `Plugins` (except `Plugins/TableProPluginKit`, linted in full), `TableProMobile` and `TableProUITests`. A new rule applies there only once it joins that file's list.
- A local `swiftlint` run only prints the invalid-rule warning that fails CI (SwiftLint above), so read stderr after editing a rule.
- Run `actionlint` and `shellcheck --severity=warning` on what you changed before pushing; Repo Hygiene runs both.
- Write macOS `run:` blocks for bash 3.2, the `/bin/bash` the runner has used. `done < <(script)` throws away the script's exit status, so write the output to a file and read that.
- Reading a producer's output one argument per line turns a single blank line into one empty argument.
- Under `set -u`, bash 3.2 fails on `"${ARR[@]}"` for an empty array; write `${ARR[@]+"${ARR[@]}"}`.
- `git diff --name-only` quotes non-ASCII paths. Use `git -c core.quotePath=false diff --no-renames --name-only -z` into a file and match with `LC_ALL=C grep -z`.
