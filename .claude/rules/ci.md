---
paths:
  - ".github/workflows/**/*"
  - ".github/actions/**/*"
  - ".github/actionlint.yaml"
  - "scripts/ci/**/*"
  - "apple/scripts/ci/**/*"
  - "scripts/release/**/*"
  - "apple/scripts/release/**/*"
  - "apple/.swiftlint.yml"
  - "**/.swiftlint.yml"
---

# CI

## Required checks

- main and `release/*` require `CI`, the last job of `ci.yml`, and `PR title` (`pr-title.yml`). Strict is off. Admins can bypass in pull_request mode.
- `CI` fails when a job it needs failed or was cancelled. A skipped job passes.
- `release/0.82` keeps its own workflow files and the old per-workflow checks.
- Tags never move (ruleset 25308039, no bypass). Only admins create `release/*` and the `v*`, `linux-v*`, `libs-*` and `plugin-*` tags.

## Reading a red check

- Open the CI run and read the red job under it. `CI` only lists the results.
- PR CI tests the merge with main as of the trigger. After main is fixed, merge main in instead of re-running.
- Artifacts, annotations and summaries: `.claude/skills/fix-issue/references/verification-apple.md`, Reading CI.

## What runs where

- `ci.yml` runs on every PR and on pushes to main and `release/**`. `Plan` runs the detector per suite, then calls each workflow when its suite is true: `macos-tests.yml` (`macos`), `ios-tests.yml` (`ios`), `swiftlint.yml` (`swiftlint`), `build-linux.yml` (`linux-docs`, docs job only unless `linux`) and `repo-hygiene.yml` (always). `plugins`, `oracle` and `hana` go in as inputs.
- The base is a PR's base SHA, or on main the head SHA of the last green CI push run on main. No such run runs everything.
- Concurrency is only in `ci.yml`: a PR keeps its newest run, main runs one at a time and a newer pending run replaces the older, and each `release/**` commit has its own group.
- macOS Tests runs the Unit and UI plans in full, with no shard, parallel, iteration or retry flag.
- A `v*` tag runs only `release.yml`, a `linux-v*` tag only `release-linux.yml`.

## Change detector

- `scripts/ci/detect-changed-paths.sh [--base <sha>] [--head <rev>] [--ref <ref>] <suite>` prints `true` or `false`. No base prints true; an all-zero base diffs from the merge base with `origin/main`; `--ref refs/heads/release/*` prints true.
- Suites: `macos`, `plugins`, `ios`, `oracle`, `hana`, `swiftlint`, `linux` (no Markdown but `linux/CHANGELOG.md`, `linux/docs/regression-tests.md` and `linux/data/`), `linux-docs`, `release` (what Release Build reads) and `shipped` (`release` without `.github/`; `version.py check` reads it).
- Every suite but `shipped` watches `ci.yml` and its own workflow. A path a suite newly reads joins its pattern in the same change.

## Runners

- Xcode jobs run on `xcode-27`, a GitHub preview image. `setup-xcode` pins the Xcode build.
- Release Build runs on `mac-mini-m4pro` (`self-hosted`, `macOS`, `ARM64`, `tablepro-release`), the maintainer's Mac, as the maintainer's user. `MAC_RUNNER=github` moves it to `xcode-27`.
- Signing, notarization and the feed stay on hosted runners.
- Any workflow on a pushed ref can target that label: never approve a fork PR run that changes `.github/` unread.
- At most 5 hosted macOS jobs and 20 jobs in all run at once.

## Release Build

- `release-build.yml` builds and packages the app and every registry plugin as a tag does, unsigned: nightly at 19:00 UTC, Sundays at 07:00 UTC on `xcode-27`, and by dispatch. No tag waits for it.

## Summaries

- `apple/scripts/ci/summarize-xcresult.sh` writes the step summary and fails a bundle or `swift test` run that executed no test.

## Caches

- `~/.spm-cache`, keyed on the app's `Package.resolved`. macOS Tests saves it on a push miss; Release and Release Build only restore it.
- Linux caches Cargo through `Swatinem/rust-cache`. No libs or DerivedData cache.

## Writing workflow and lint code

- Pin every action by commit SHA. Repo Hygiene runs actionlint and `shellcheck --severity=warning`; Supply chain runs zizmor on `ci.yml` and the Linux workflows.
- Nested `.swiftlint.yml` files under `apple/TableProTests`, `apple/Plugins` (not `TableProPluginKit`), `apple/TableProMobile` and `apple/TableProUITests` use `only_rules`, so a new rule applies there only once listed.
