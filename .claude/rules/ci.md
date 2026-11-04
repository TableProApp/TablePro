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
- `release/0.82` and `release/0.83` were cut before `ci.yml`: they keep their own workflow files and the old per-workflow checks (ruleset 23957966).
- Tags never move (ruleset 25308039, no bypass). Only admins create `release/*` and the `v*`, `ios-v*`, `linux-v*`, `libs-*` and `plugin-*` tags. `windows-v*` joins both once the maintainer adds it (`windows/RELEASING.md`, Setup).

## Reading a red check

- Open the CI run and read the red job under it. `CI` only lists the results.
- PR CI tests the merge with main as of the trigger. After main is fixed, merge main in instead of re-running.
- Artifacts, annotations and summaries: `.claude/skills/fix-issue/references/verification-apple.md`, Reading CI.

## What runs where

- `ci.yml` runs on every PR, on pushes to main and `release/**`, and by dispatch. `Plan` runs the detector per suite, then calls each workflow when its suite is true: `macos-tests.yml` (`macos`), `ios-tests.yml` (`ios`), `swiftlint.yml` (`swiftlint`), `build-linux.yml` (`linux-docs`, docs job only unless `linux`; never on `release/**`, since Linux ships from main or `linux-X.Y`), `core.yml` (`linux`, the shared Rust core on Windows and macOS; never on `release/**`), `windows.yml` (`windows`, the Windows app, its UI tests and the .NET libraries over the core's FFI crate; never on `release/**`) and `repo-hygiene.yml` (always). `plugins`, `oracle` and `hana` go in as inputs.
- The base is a PR's base SHA, or on a main push the head SHA of the last green CI push run on main. No such run, or a dispatch, runs everything. A dispatch never counts as main's last green run or for a tag.
- Concurrency in `ci.yml`: a PR keeps its newest run, main pushes run one at a time and a newer pending run replaces the older, and each `release/**` commit and each dispatch has its own group. `linux-packages.yml` keeps a PR's newest run too; its other runs, a release's call included, each have their own group.
- macOS Tests runs the Unit and UI plans in full, with no shard, parallel, iteration or retry flag.
- A `v*` tag runs only `release.yml`, a `linux-v*` tag only `release-linux.yml`, a `windows-v*` tag only `release-windows.yml`, which also runs by dispatch and publishes nothing then (`windows/RELEASING.md`).
- `windows-grid-gate.yml` runs only by dispatch: the Windows data grid's timing and behavior gate on `windows-2025` and `windows-11-arm`, whose numbers vary too much between hosted runners to gate a merge (`windows/docs/decisions/0003-data-grid-control.md`, Gate). `windows.yml` runs the grid's tests on every change.

## Change detector

- `scripts/ci/detect-changed-paths.sh [--base <sha>] [--head <rev>] [--ref <ref>] <suite>` prints `true` or `false`. No base prints true; an all-zero base diffs from the merge base with `origin/main`; `--ref refs/heads/release/*` prints true.
- Suites: `macos`, `plugins`, `ios`, `oracle`, `hana`, `swiftlint`, `linux` (`linux/`, `core/` and the Cargo workspace files at the top; no Markdown but `linux/CHANGELOG.md`, `linux/docs/regression-tests.md` and `linux/data/`), `linux-docs`, `windows` (`windows/`, `core/`, `Cargo.toml`, `Cargo.lock` and `rust-toolchain.toml` at the top, and the Windows workflows `windows.yml` lints; no Markdown), `release` (what Release Build reads) and `shipped` (`release` without `.github/`; `version.py check` reads it).
- Every suite but `shipped` watches `ci.yml` and its own workflow. A path a suite newly reads joins its pattern in the same change.

## Runners

- Xcode jobs run on `xcode-27`, a GitHub preview image. `setup-xcode` pins the Xcode build.
- Every job runs on a GitHub-hosted runner. There is no self-hosted runner. `core.yml` and `windows.yml` use `windows-2025`, `windows-11-arm` and `macos-15`. `release-windows.yml` also installs on `windows-2022`, the oldest Windows a hosted runner has.
- At most 5 hosted macOS jobs and 20 jobs in all run at once.

## Release Build

- `release-build.yml` builds and packages the app and every registry plugin as a tag does, unsigned, on `xcode-27`: nightly at 19:00 UTC and by dispatch. No tag waits for it.

## Summaries

- `apple/scripts/ci/summarize-xcresult.sh` writes the step summary and fails a bundle or `swift test` run that executed no test.

## Caches

- `~/.spm-cache`, keyed on the app's `Package.resolved`. macOS Tests saves it on a push miss; Release and Release Build only restore it.
- Linux, `core.yml` and `windows.yml` cache Cargo through `Swatinem/rust-cache`. `windows.yml` also caches the pinned uniffi-bindgen-cs. `release-windows.yml` restores no cache. No libs or DerivedData cache.

## Writing workflow and lint code

- Pin every action by commit SHA. Repo Hygiene runs actionlint and `shellcheck --severity=warning`; Supply chain runs zizmor on `ci.yml`, `core.yml` and the Linux workflows, and `windows.yml`'s macOS job on `windows.yml`, `release-windows.yml` and `windows-grid-gate.yml`.
- Nested `.swiftlint.yml` files under `apple/TableProTests`, `apple/Plugins` (not `TableProPluginKit`), `apple/TableProMobile` and `apple/TableProUITests` use `only_rules`, so a new rule applies there only once listed.
