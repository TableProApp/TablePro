---
paths:
  - ".github/workflows/**/*"
  - ".github/actions/**/*"
  - ".github/scripts/**/*"
  - ".github/actionlint.yaml"
  - ".github/*baseline*"
  - "scripts/ci/**/*"
  - ".swiftlint.yml"
  - "**/.swiftlint.yml"
---

# CI

The required check names are in `AGENTS.md` (CI). Reading a red check: `.claude/skills/fix-issue/references/verification-apple.md`, Reading CI. The release and plugin builds: `RELEASING.md`.

## Rulesets and required checks

- There are no gate jobs. A test job runs on `!cancelled() && needs.changes.outputs.run != 'false'`. A job its `if:` skips reports success, and a failed changes job runs the suite rather than skipping it.
- `Changes (macOS)` and `Changes (iOS)` are not required checks.
- A PR need not be up to date with main to merge (`strict_required_status_checks_policy: false`).
- A second ruleset blocks force-push and deletion of `main`, with no bypass.
- A required check's name is its job's `name:`. Renaming a job changes the ruleset in the same change, and every open PR then merges main in before its checks report the new name.

## Runners and toolchain

- Every Xcode job in the test and release workflows runs on the `xcode-27` runner label, a GitHub preview image. actionlint learns the label from `.github/actionlint.yaml`. `build-plugin.yml` picks its runner from the ref it builds (`RELEASING.md`).
- The Xcode version is written once, in `.github/actions/setup-xcode/action.yml`, which runs `xcode-select --switch` and prints `xcodebuild -version`. A workflow never selects Xcode another way.
- XcodeGen comes from `.github/actions/setup-xcodegen`, pinned by version and SHA-256.
- The compilation cache is off on CI (`COMPILATION_CACHE_ENABLE_CACHING=NO`); `Configs/Base.xcconfig` turns it on locally.

## macOS Tests (`macos-tests.yml`)

- Triggers: pull request, push to main, dispatch. A PR keeps only its newest run; each main commit has its own concurrency group and is never cancelled.
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

## Summaries (`scripts/ci/summarize-xcresult.sh`)

- Reads `.xcresult` bundles and `swift test` xunit files, and skips a missing input.
- Writes build errors with file and line, per-bundle counts and minutes, up to 50 failed cases and the 20 slowest to the step summary.
- Exits 1 when a bundle or a `swift test` run executed nothing, because `xcodebuild` and `swift test` both call that success.
- For `X.xml` it also reads `X-swift-testing.xml`.
- It never fails on a failed case; the test step already did.

## SwiftLint (`swiftlint.yml`)

- PR, push to main, dispatch; Ubuntu, 10 minutes.
- Runs the digest-pinned `ghcr.io/realm/swiftlint` image over the whole repo with `lint --strict`. The image's entrypoint is `swiftlint`, so the command never repeats it.
- Fails when stderr has `Invalid configuration` or `is not a valid rule identifier`, because SwiftLint drops a custom rule whose regex does not compile and still exits 0.

## PR title (`pr-title.yml`)

- Runs on opened, edited, reopened and synchronize, so every head commit gets the check.
- Runs `scripts/ci/check-pr-title.py`, then `scripts/check-banned-words.sh` on the PR's added lines and on its body. The banned-words step runs both and exits with the worse result.

## Repo Hygiene (`repo-hygiene.yml`)

- PR, push to main, dispatch, no path filter; Ubuntu, 15 minutes.
- Steps, in order:
  - actionlint, which also shellchecks every inline `run:` block;
  - `shellcheck --severity=warning` on every `*.sh` under `scripts` and `.claude/skills`;
  - the tooling tests: `scripts/ci/test_*.py`, `scripts/test_localization.py`, `.github/scripts/test_update_registry.py` and two shell tests;
  - `check-lib-sourcing.py`, `check-plugin-manifest.py`, `check-deployment-target.sh`, `check-ios-shared-isolation.py`;
  - `localization.py plugins` and `plugins --target ios`;
  - `check-string-catalogs.py`, `check-license-inventory.py`, `check-entitlements.py`, `check-test-plans.py`;
  - `check-pluginkit-bump-cadence.py`, `check-sparkle-version.py`;
  - `scripts/audit-refactor-health.sh --check`, `check-hub-ratchet.py`;
  - the Go checks on the HANA helper, when the `hana` detector is true.
- `audit-refactor-health.sh --check` fails a file defining a production `DatabaseType` outside `Packages/TableProCore/Sources/TableProCoreTypes/DatabaseType.swift`, unless `.github/duplicate-contract-baseline.txt` lists its path. Moving a listed file moves its baseline path in the same commit. Never add an entry to let a new copy pass.
- `check-hub-ratchet.py` fails when an app hub grows past `.github/hub-ratchet-baseline.json`. `--update` only lowers a value, so growing one is a hand edit a reviewer sees.

## Change detector (`scripts/ci/detect-changed-paths.sh`)

- `detect-changed-paths.sh [--base <sha>] macos|plugins|ios|oracle|hana` prints `true` or `false`. An unknown suite or flag exits 2.
- A PR passes its base SHA, a push `github.event.before`. No base, or the all-zero SHA of a new ref, prints true.
- `macos` watches the app, test, plugin, package, native, config and libs folders, `TestPlans/`, `project.yml`, the app's `Package.resolved`, the build scripts and CI scripts it runs, both setup actions and its workflow. `Packages/` covers TableProMacCore.
- `plugins` watches `Plugins/`, `Packages/TableProCore/`, `Packages/TableProOracle/`, `Native/`, `Libs/`, `Configs/`, `project.yml`, the bridge scripts and `verify-plugin-loads.sh`.
- `ios` watches `TableProMobile/`, `Libs/`, `Plugins/TableProPluginKit/` (the package target is a symlink to it), and every `../` path it reads out of `TableProMobile/project.yml`.
- `oracle` watches `Packages/TableProOracle/`; `hana` watches `Native/HanaBridge/`. Each suite also watches its own workflow.
- A path a suite newly reads joins that suite's pattern in the same change, or the suite skips on it.
- Release-only files never trigger a suite: `CHANGELOG.md`, `appcast.xml`, `TablePro/Resources/WhatsNew.md`, `.github/release-flags.json`, and `Configs/Version.xcconfig` while its diff touches only the two version keys.
- Every file the release commit stages (`.claude/skills/release/SKILL.md`, Commit, tag, push) is on that list; `appcast.xml` is `build.yml`'s own push.
- A release push that touches anything else runs the suites, and the tag waits for them.

## What runs where

- A pull request: both changes jobs; macOS Tests and iOS and Package Tests unless their detector says false (Oracle only when its detector is not false); SwiftLint; Repo Hygiene; PR title. `AllPlugins` only when the `plugins` detector is not false.
- A push to main: the same minus PR title, never cancelled, `AllPlugins` always, the SPM cache saved on a miss. Every code push runs both plans in full; a docs-only or release-only push skips the suites through the detector.
- A `v*` tag runs only `build.yml`; a `plugin-*-v*` tag runs only `build-plugin.yml` (`RELEASING.md`). The test workflows never run on a tag.
- `workflow_dispatch` exists on every workflow except `pr-title.yml`.
- `build-linux.yml` is on `main` only for its Monday schedule, which GitHub runs from the default branch. Until the Linux app's directory lands on `main`, every build job skips and `weekly-dispatch` starts the workflow on the branch the `LINUX_BRANCH` variable names (the linux branch when unset), whose testing guide describes the jobs.

## Caches and runner budget

- Swift package checkouts live in `~/.spm-cache`, keyed `spm-<os>-<hash of the app's Package.resolved>` with prefix restore. The cache is saved only on a push to main and only on a miss: a cache saved on a PR ref is visible to that PR alone.
- `build.yml` restores that cache and never saves it, since a save in tag scope is unreadable from other tags.
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
