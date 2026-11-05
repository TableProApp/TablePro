---
paths:
  - ".github/workflows/**/*"
  - ".github/actions/**/*"
  - ".github/actionlint.yaml"
  - ".github/dependabot.yml"
  - "scripts/ci/**/*"
  - "apple/scripts/ci/**/*"
  - "scripts/release/**/*"
  - "apple/scripts/release/**/*"
  - "apple/.swiftlint.yml"
  - "**/.swiftlint.yml"
---

# CI

## Required checks

- main requires `CI`, the last job of `ci.yml`, and merges through GitHub's merge queue, one pull request at a time, squashed. Strict is off. Admins can bypass in pull_request mode.
- `release/*` requires `CI` and `PR title` (ruleset 25435242). `release/0.82` was cut before `ci.yml`: it keeps its own workflow files and the old per-workflow checks (ruleset 23957966).
- `PR title` (`pr-title.yml`) is advisory on main: the reviewer reads the squash subject. It also runs the changelog check, since a title edit starts no CI run; on main the merge group's Lint job runs it again with the current title.
- `CI` fails when a job it needs failed or was cancelled, or when the plan selected a job that did not succeed. A job the plan left out is skipped, which passes.
- Tags never move (ruleset 25308039, no bypass). Only admins create `release/*` and the `v*`, `ios-v*`, `linux-v*`, `windows-v*`, `libs-*` and `plugin-*` tags.

## Reading a red check

- Open the CI run and read the red job under it. `CI` only lists the results.
- PR CI tests the merge with main as of the trigger. After main is fixed, merge main in instead of re-running.
- A merge group runs `CI` again on the squash of the pull request onto main; a red one drops the pull request from the queue.
- Artifacts, annotations and summaries: `.claude/skills/fix-issue/references/verification-apple.md`, Reading CI.

## What runs where

- `ci.yml` runs on every PR, every merge group, pushes to main and `release/**`, and by dispatch. `Plan` runs the detector per suite, then calls each workflow when its suite is true: `ci-lint.yml` (always; SwiftLint with `swiftlint`, the HANA helper with `hana`), `macos-tests.yml` (`macos`, plugins with `plugins`), `ios-tests.yml` (`ios`, TableProOracle with `oracle`), `build-linux.yml` (`linux-docs`, docs job only unless `linux`), `core.yml` (`core`) and `windows.yml` (`windows`).
- A `release/**` push, or a PR into one, runs no Linux, core or Windows job: Linux ships from main or `linux-X.Y`, and the core and the Windows app have no release line.
- The base is a PR's base SHA, a merge group's base SHA, or on a main push the head SHA of the last green CI push run on main. No such run, or a dispatch, runs everything. A main push runs no suite when its parent is that last green commit and the commit itself already passed `CI` in a merge group. A dispatch never counts as main's last green run or for a tag.
- Concurrency in `ci.yml`: a PR keeps its newest run, main pushes run one at a time and a newer pending run replaces the older, and each merge group, `release/**` commit and dispatch has its own group. `linux-packages.yml` keeps a PR's newest run too; its other runs, a release's call included, each have their own group.
- `nightly.yml` is the one schedule, at 19:17 UTC: every suite in full on main, with core's Arm64 SSH tunnel tests, and the Release Build job, which builds and packages the app and every registry plugin as a tag does, unsigned, on `xcode-27`. No tag waits for it. GitHub mails a red run to whoever last edited the schedule.
- macOS Tests runs the Unit and UI plans in full, with no shard, parallel, iteration or retry flag.
- `core.yml` runs the core on Windows x64 and Arm64 and on macOS, where the same job builds and tests the Swift bindings, and SQL Server's integrated login on Windows x64. The SSH tunnel tests through Windows' OpenSSH Server run on x64; Arm64, whose image installs the server in about 20 minutes, runs them nightly.
- A `v*` tag runs only `release.yml`, a `linux-v*` tag only `release-linux.yml`, a `windows-v*` tag only `release-windows.yml`, which also runs by dispatch and publishes nothing then (`windows/RELEASING.md`).
- `windows-grid-gate.yml` runs only by dispatch: the Windows data grid's timing and behavior gate on `windows-2025` and `windows-11-arm`, whose numbers vary too much between hosted runners to gate a merge (`windows/docs/decisions/0003-data-grid-control.md`, Gate). `windows.yml` runs the grid's tests on every change.

## Change detector

- `scripts/ci/detect-changed-paths.sh [--base <sha>] [--head <rev>] [--ref <ref>] <suite>` prints `true` or `false`. No base prints true; an all-zero base diffs from the merge base with `origin/main`; `--ref refs/heads/release/*` prints true.
- Suites: `macos`, `plugins`, `ios`, `oracle`, `hana`, `swiftlint`, `linux` (`linux/`, `core/` and the Cargo workspace files at the top; no Markdown but `linux/CHANGELOG.md`, `linux/docs/regression-tests.md` and `linux/data/`), `linux-docs`, `core` (`core/`, `Cargo.toml`, `Cargo.lock`, `rust-toolchain.toml`, the FFI Swift package and what builds it; no Markdown), `windows` (`windows/`, `core/`, `Cargo.toml`, `Cargo.lock` and `rust-toolchain.toml` at the top; no Markdown), `release` (what the Release Build job reads) and `shipped` (`release` without `.github/`; `version.py check` reads it).
- Every suite but `shipped` watches `ci.yml` and its own workflow. A path a suite newly reads joins its pattern in the same change.

## Runners

- Xcode jobs run on `xcode-27`, a GitHub preview image. `setup-xcode` pins the Xcode build.
- Every job runs on a GitHub-hosted runner of the Free plan. There is no self-hosted or larger runner. `core.yml` and `windows.yml` use `windows-2025`, `windows-11-arm` and `macos-15`. `release-windows.yml` also installs on `windows-2022`, the oldest Windows a hosted runner has.
- At most 5 hosted macOS jobs and 20 jobs in all run at once.

## Summaries

- `apple/scripts/ci/summarize-xcresult.sh` writes the step summary and fails a bundle or `swift test` run that executed no test.

## Caches

- `~/.spm-cache`, keyed on the app's `Package.resolved`. macOS Tests saves it on a push or nightly miss; Release and the Release Build job only restore it.
- Linux, `core.yml` and `windows.yml` cache Cargo through `Swatinem/rust-cache`; `core.yml` and `windows.yml` save it from main only, since a pull request's cache serves that pull request alone and evicts main's. `windows.yml` also caches the pinned uniffi-bindgen-cs. `release-windows.yml` restores no cache. No libs or DerivedData cache.

## Writing workflow and lint code

- Pin every action by commit SHA. Check out with `persist-credentials: false` unless the job pushes with git; a gh-pages writer says so with `# zizmor: ignore[artipacked]`.
- The Lint job (`ci-lint.yml`) runs actionlint, pinned by checksum, `shellcheck --severity=warning` over every tracked `*.sh`, and zizmor offline at medium over all of `.github`, then the release tooling's tests and the repo invariants.
- Blocking: compiler, test, format, license, correctness and changelog checks. Advisory: the PR title and prose style.
- Nested `.swiftlint.yml` files under `apple/TableProTests`, `apple/Plugins` (not `TableProPluginKit`), `apple/TableProMobile` and `apple/TableProUITests` use `only_rules`, so a new rule applies there only once listed.
