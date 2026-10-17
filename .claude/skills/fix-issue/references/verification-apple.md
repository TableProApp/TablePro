# Verification on Apple

Read this when a verdict, a test name or a red CI check needs explaining. The commands, the verdict words and the verdict rules are in `AGENTS.md`, Commands; when each step runs is in `references/platform-apple.md`, Verify.

## Usage

- `verify.sh [options] <step> [args]`, plus `verify.sh tail <log> [lines]` and `verify.sh parse <log>`.
- Options go before or after the step: `--platform <name>`, `--root <dir>`, `--run <dir>`, `--no-wait`, `--offline`. An unknown option is a usage error.
- The platform comes from `uname -s`, and Darwin is `apple`. A platform named with `--platform` that has no backend exits 3; a default one with no backend is INCONCLUSIVE.
- The root is the checkout your shell is in when it shares the script's git common directory, else the checkout the script lives in. `--root` overrides both. Check the `root:` line.
- `--offline` adds `-disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile` to `build`, `plugins`, `test` and `uitest`.
- The Apple steps live in `.claude/skills/fix-issue/scripts/lib/platform-apple.sh`, whose header lists each one with its arguments.

## Why the wrapper

- A raw `xcodebuild` failure comes back as a head-and-tail excerpt of about 10,000 characters with no log path, so the one run you need in full is lost.
- Without `DEVELOPER_DIR` the wrapper takes the selected Xcode, then `/Applications/Xcode.app`, then `/Applications/Xcode-beta.app`. A Command Line Tools selection has no `xcodebuild` and no `sourcekitd`.
- It names the project explicitly and waits for a build of the same checkout (Worktrees).

## Naming tests

- A bare `Suite` is a Swift type name: a `struct`, `class`, `enum`, `actor` or `extension` declared in a `.swift` file under any folder whose name ends in `Tests`, tracked or untracked. It is not the file name, the `@Suite` display name or a `@Test` function.
- A nested Swift Testing suite is `<Outer>/<Inner>`.
- A target the Unit or UI plan lists runs through that plan. A package test target no plan lists runs under `swift test` in its package.
- A name no target declares exits 3 before anything builds.
- A name declared in two targets exits 3 and asks for `<target>/<Suite>`.
- A name declared only in a folder no plan or package lists exits 3; for `TableProMobileTests` it names `verify.sh ios`.
- A Unit test passed to `uitest`, or a UI test passed to `test`, exits 3 and names the right step. So does a `swift test` suite passed to `uitest`.
- `test` with no argument runs the Unit plan only, never the TableProCore or TableProOracle test targets; those run with `verify.sh package <Package>`.
- A `swift test` suite runs as `swift test --filter` on `<Target>.<Suite>` in its package. One step can run a plan and several packages, and the worst verdict wins.
- A raw `xcodebuild -only-testing` with a name that is not a type runs 0 cases and still prints `TEST SUCCEEDED`. `verify.sh` and CI fail that run; a raw command does not.
- In zsh an unquoted `$SUITES` holding several names is one argument: write the names out, or use `${=SUITES}`.

## Verdicts

- A test verdict comes from the result bundle or the xunit file, never the console banner.
- The result-bundle rules, first match wins:
  1. nothing executed and the bundle holds build errors: FAIL, "the test build failed";
  2. nothing executed and `xcodebuild` exited nonzero: FAIL;
  3. a failed case: FAIL;
  4. a runner failure outside any test ("System Failures"): FAIL;
  5. a nonzero exit with no failed case: FAIL;
  6. a filter that ran nothing, or nothing executed at all: FAIL;
  7. otherwise PASS.
- The xunit rules: a nonzero exit or a failed case is FAIL, nothing executed is FAIL, else PASS. `<log>.xml` and `<log>-swift-testing.xml` both count.
- Skipped cases do not count as executed. Expected failures are counted apart from failures.
- A case that passed only on the UI plan's retry is listed under "passed only on retry, a flake to fix" and does not fail the step. What to do with it: `.claude/rules/ui-tests.md`, The UI plan.
- The step prints executed, passed, failed and skipped counts and one count per target. Compare executed with what you meant to run.
- A build step whose log lacks `** BUILD SUCCEEDED **` is FAIL, or INCONCLUSIVE when a known environment cause explains it.

## INCONCLUSIVE

- INCONCLUSIVE always names a cause outside the change. A test run gets it only when nothing executed and a known cause explains it; a run that executed tests is PASS or FAIL.
- The script prints each cause with its remedy. Two need more than it prints.
- "The test runner hung before establishing connection" twice in a row is a wedged `testmanagerd`, and every later test run on the Mac hangs the same way. When `pgrep -f Developer/usr/bin/xcodebuild` prints nothing, run `kill -9 $(pgrep testmanagerd)`. SIGTERM does not stop it; launchd starts a fresh one on the next run.
- "Timed out while enabling automation mode" means Automation Mode is off. Run an untouched suite as a control (`verify.sh uitest <a suite you did not change>`) and grep its log for `automation mode`. If it fails the same way, take a `screencapture -x` to see whether the "Enable UI Automation" prompt is up; scripting cannot see it.
- Only the user turns Automation Mode on: by answering that prompt with an admin password, or by running `sudo automationmodetool enable-automationmode-without-authentication` once, after which XCTest enables it with no prompt. `automationmodetool` prints which of the two this Mac needs. Unit tests, lint and screenshots keep working meanwhile; say in the PR that CI runs the UI flow.

## Logs and files

- Logs go to `<root>/.analysis/<branch with / turned into ->/logs/`, or to `<dir>/logs/` with `--run <dir>`. `.analysis/` is gitignored.
- A log is `<step>[-<detail>]-<HHMMSS>.log` (`build-TablePro-<HHMMSS>.log`, `test-<Suite>-<HHMMSS>.log`), with a numeric suffix when two start in the same second.
- Each run writes `<log>.verdict`, and `verify.sh parse <log>` prints it back.
- A test run also writes `<log>.filters`. A plan run keeps `<log>.xcresult` only when it did not pass, since a failing bundle runs to about 150 MB. A `swift test` run writes `<log>.xml` and `<log>-swift-testing.xml`.

## Build

- `xcodebuild` writes outside the tree, to `~/Library/Developer/Xcode/DerivedData`, which a sandbox has to allow.
- `cannot find 'X' in scope` for code you just wrote means the project was not regenerated: run `generate`.
- MemberImportVisibility errors on a new file that uses `Combine` or `TableProPluginKit` members are real: add the import.
- CI selects its Xcode in `.github/actions/setup-xcode/action.yml`. A compile error only CI reports is real: compare `xcodebuild -version` with that file, then fix the error. Never re-run hoping it passes.
- SourceKit diagnostics in the editor are noise. Only an `xcodebuild` run counts.
- A plugin's scheme is its target name in `project.yml`, not always `<Name>Driver`: `MSSQLDriver`, but `SnowflakeDriverPlugin`. `xcodebuild -list` lists them, and `verify.sh build <Scheme>` builds one.
- After a package's public API or a type's stored layout changes, a target can still compile against the old `Build/Products/Debug/<Module>.swiftmodule` in DerivedData. The link then fails on the old symbol, or the test host crashes in an outlined destroy. Delete that module's `.swiftmodule` and `.o`, or the checkout's DerivedData folder, and rebuild. A clean CI build never sees it.

## Test runs

- Run the suites that own what you changed, plus their neighbors, not a whole plan. CI runs the plans in full (`.claude/rules/ci.md`, What runs where).
- Swift Testing's expectation text is in the result bundle, not the log: `xcrun xcresulttool get test-results tests --path <xcresult>`.
- A test behind `#if canImport(C...)` compiles to nothing where that module is absent, so it looks present and never runs.
- To decide whether a failing suite is yours, grep its file for the symbols you changed.

## Packages and iOS

- `package <Package> [regex]` runs `swift test --parallel` with an xunit file. SwiftPM writes the XCTest xunit file only for a parallel run. A package with a `Package.resolved` also gets `--force-resolved-versions`.
- A `Package.resolved` written by one toolchain can fail `--force-resolved-versions` on another when a transitive dependency was renamed. Re-pinning only moves the failure; drop the dependency or remove the rename from the graph.
- `ios <Suite>...` runs `TableProMobileTests` on the first available iPhone simulator with `-parallel-testing-enabled NO -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO ARCHS=arm64`. `ARCHS=arm64` is there because the prebuilt iOS libraries have arm64 simulator slices only.
- `ios` generates the iOS project when the tree has none.

## Lint

- `lint` is SwiftLint only. `agent-docs` is its own step, so a stale doc reference never turns a code lint red; `AGENTS.md`, Writing style and docs, says what it checks.
- `.swiftlint.yml` `included:` holds six roots: `TablePro`, `Packages`, `Plugins`, `TableProMobile`, `TableProTests`, `TableProUITests`.
- Some folders lint with fewer rules through a nested `only_rules` config: `.claude/rules/ci.md`, Writing workflow and lint code.
- A directory outside `included:` lints nothing and reports 0 violations; the step names it under "NOT LINTED". Pass files.
- Paths go to SwiftLint as given, resolved against the shell's current directory, not `--root`. Pass absolute paths when the shell is elsewhere.
- `force_cast` and `force_unwrapping` are warnings, so only `--strict` fails them. A plain `swiftlint lint` passes code CI rejects.

## Reading CI

- Artifacts exist only for a failed job and are kept 7 days. `macos-tests-<attempt>` holds every `.xcresult` plus `app-diagnostics` (TablePro crash reports and 2 hours of its unified log); `ios-tests-<attempt>` holds `iOS.xcresult`.
- The step summary lists build errors, failed cases and the slowest cases (`.claude/rules/ci.md`, Summaries). A case that passed only on the UI plan's retry shows as a `Passed only on retry` warning annotation while the job stays green.
- `xcbeautify` can hide a compiler error behind "exit code 65". Read the check-run annotations, which also work while the run is going: `gh api repos/TableProApp/TablePro/check-runs/<job-id>/annotations`. Or open `Build.xcresult` from the artifact.
- UI evidence: `gh run download <run-id> -n macos-tests-<attempt>`, then `xcrun xcresulttool get test-results activities --test-id <id> --path UI.xcresult` and `xcrun xcresulttool export attachments --path UI.xcresult --output-path <dir>`. The `element-tree-<n>` attachment shows which window held focus; the recording and the Synthesized Event plists show where each event landed.
- A long silent stretch in the build log is a target's emit-module job, not a stall.
- PR CI tests the PR merged into main as of the trigger, and a re-run reuses that merge. After main is fixed, or a required check is renamed, merge main into the PR instead of re-running.

## Worktrees

- `.claude/skills/fix-issue/scripts/worktree.sh <branch> [base]` creates `.claude/worktrees/<branch with / turned into ->` from a fresh fetch of the base, `origin/main` by default. It links `Configs/Secrets.xcconfig`, `Libs/*.a`, `Libs/dylibs`, `Libs/ios/*.xcframework` and the native bridge outputs from the main checkout, and prints the path to pass as `--root`. Run `generate` before its first build.
- `worktree.sh --prune-merged [--dry-run]` removes each tree whose pull requests are all merged or closed, with its DerivedData folder. It removes one only when `git status` is clean and no process has its working directory inside; a kept tree says why. A Codex broker started in a tree is the usual process that keeps it.
- `worktree.sh --remove <branch>` keeps the branch and refuses a tree with uncommitted or untracked changes.
- Each tree builds into its own DerivedData. `build`, `plugins`, `test`, `uitest` and `ios` wait only for an `xcodebuild` of the same checkout, found by its project path or working directory, so `--no-wait` is safe in your own tree.
