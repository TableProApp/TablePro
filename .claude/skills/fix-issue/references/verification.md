# Verification traps

Read this when a `verify.sh` verdict needs interpreting, or before writing a UI test. The usage line is `verify.sh [--root <tree>] [--run <dir>] [--no-wait] [--offline] <step> [args]`. `--run <dir>` puts logs in `<dir>/logs`. Without `--root`, the root is the checkout the current directory is in, falling back to the one the script lives in. `verify.sh tail <log> [n]` re-reads a stored log, and `verify.sh parse <log>` prints the verdict the live run wrote to `<log>.verdict`, re-deriving it from the log only when no receipt exists.

## Why the wrapper, always

A raw `xcodebuild` failure comes back as a head-and-tail excerpt of about 10,000 characters with no log path, so the one run you need in full is the one you cannot get back. The wrapper also exports `DEVELOPER_DIR` (a Command Line Tools `xcode-select` has no `xcodebuild` and no `sourcekitd`), names the project explicitly, waits for another `xcodebuild` in the same checkout, and checks failing cases against both quarantine files and the known environment failures before it calls a run red.

## Build

- **The `TablePro` scheme builds only the bundled plugins.** A compile error in a registry-only plugin still ends `BUILD SUCCEEDED`, so run `verify.sh plugins` whenever `Plugins/` changed.
- **`Could not resolve package dependencies`** means SwiftPM tried the network: re-run with `--offline`.
- **`Unable to open base configuration reference file`** means `Configs/Secrets.xcconfig` is missing, which is normal in a worktree that `worktree.sh` did not create.
- **`cannot find 'X' in scope` for code you just wrote** means the project was not regenerated.
- **MemberImportVisibility errors** on a new file that uses `Combine` or `TableProPluginKit` members are real: add the `import`.
- **CI's Swift compiler is older than this machine's.** A compile error that only CI reports is real (a shadowed `let x = x` inside a closure that initializes `x` has been one): fix it, never re-run hoping it passes.
- **SourceKit diagnostics in the editor are noise here** (`No such module 'TablePro'` and the like). Only an `xcodebuild` run counts.
- **One plugin's scheme is its target name in `project.yml`**, which is not always `<Name>Driver`: `MSSQLDriver`, but `SnowflakeDriverPlugin` and `TrinoDriverPlugin`. `xcodebuild -list -project <tree>/TablePro.xcodeproj` lists them; `verify.sh build <Scheme>` builds one.
- **`verify.sh plugins` builds the HANA helper first** when the tree has none and Go is installed, since `AllPlugins` otherwise fails on `tablepro-hana-helper has no arm64 slice`.
- **`scripts/check-pluginkit-abi.sh` has no CI wiring.** For any PluginKit change, `verify.sh abi <merge-base>` is the only check that runs.

## Unit tests

- **Run the suites that own the types you changed, plus their neighbors**, not the whole target, which takes far longer and tells you little more. The wrapper mutes cases listed in the quarantine files. A suite that fails only on one machine is a test bug: fix it with a pinned locale, a private pasteboard, a stubbed network or an injected clock.
- **Filter by Swift type name.** `-only-testing` matches the type, not the file name, not the `@Suite` display name and not a `@Test` function, and a filter that matches nothing still prints `TEST SUCCEEDED`. Resolve each name with `grep -rn "struct <Suite>\|class <Suite>" TableProTests` and compare the executed count with the number of tests those suites hold.
- **`The test runner hung before establishing connection`**, twice in a row, is a wedged `testmanagerd`, and every later run on the machine hangs the same way for about 14 minutes each. When no `xcodebuild` is running (`pgrep -f Developer/usr/bin/xcodebuild` prints nothing), `kill -9 $(pgrep testmanagerd)` (SIGTERM does not stop it); launchd starts a fresh one on the next run.
- **Zero cases executed** is a wedged host, an empty filter, or a test target that did not compile. The live run tells the last apart and reports it as `FAIL` with the compile errors; the other two are `INCONCLUSIVE`.
- **To run one test case**, which the wrapper cannot do because it takes suites, call `xcodebuild ... "-only-testing:TableProTests/<Suite>/<test>()"` yourself with `DEVELOPER_DIR` set and the output redirected to a scratch log. Swift Testing's expectation text is in the result bundle (`xcrun xcresulttool get test-results tests --path <xcresult>`), not in the log.
- **To decide whether a failing suite is yours**, grep its file for the symbols you changed. Zero references plus a known environment cause is a faster answer than a baseline build.

## Package and iOS tests

- `verify.sh package <Package> [filter]` runs `swift test` in `Packages/<Package>` with the pinned versions. Package test targets such as `TableProMSSQLCoreTests` live inside `Packages/TableProCore`; pass the test type as the filter.
- `verify.sh ios <Suite>` runs the iOS unit tests on the first available iPhone simulator, generating the iOS project if the tree has none. It needs `TableProMobile/Secrets.xcconfig`, which `worktree.sh` links. Run it when `TableProMobile/` changed, or a file it compiles from `Plugins/` or `Packages/`.

## UI tests

- **Launch only through `UITestCase`.** A bare `XCUIApplication()` or `: XCTestCase` under `TableProUITests/` fails a source-scanning guard, because storage isolation depends on the launch path. The app cannot detect XCUITest by itself, so it relies on the variables `UITestCase` sets.
- **The accessibility tree differs between this machine and the CI runner.** A contextual `NSMenu` has its identifier locally and not on CI, so reach it with `app.windows.firstMatch.menus.firstMatch`. The data grid is identifier `data-grid`, since the window holds several tables. Click the grid at an offset from `data-grid`, never on a row or cell element, which XCUITest reads as obscured.
- **`.accessibilityIdentifier` on a SwiftUI container replaces the identifier of every child** in that hosting tree. When the container needs one, put `.accessibilityElement(children: .contain)` before it.
- **Diagnose by dumping the tree** (`print(app.windows.firstMatch.debugDescription)` inside a `UITestCase`), not by guessing.
- **When UI tests cannot start on this machine** (`Timed out while enabling automation mode`, zero cases), reproduce it on an untouched suite, then say in the PR that CI runs the suite. When a test fails only on the runner for a reason you cannot establish, quarantine it in `.github/macos-ui-test-quarantine.txt` with the reason instead of guessing at a fix.

## Lint

- **`lint` is SwiftLint only.** The check of `CLAUDE.md` and `.claude/` against the tree is its own step, `agent-docs`, because a stale reference already on `main` made every code lint red.
- **Pass file paths, not directories.** `.swiftlint.yml` limits `included:` to `TablePro` and `Packages`, and a directory argument outside it lints nothing while reporting zero violations. The wrapper names any directory it dropped.
- **Never remove a `swiftlint:disable force_unwrapping`** to satisfy a local run. The CI toolchain differs, and those disables are needed there.

## Worktrees

- `worktree.sh <branch> [base]` creates `.claude/worktrees/<branch>` from `origin/main` by default and links `Configs/Secrets.xcconfig`, `Libs/*.a`, `Libs/dylibs`, `Libs/ios/*.xcframework` and the native bridge outputs. Run `verify.sh --root <dir> generate` before its first build.
- `worktree.sh --prune-merged [--dry-run]` removes each tree whose pull requests are all merged or closed, together with its DerivedData folder (about 7 GB each), but only when `git status` is clean and no process has its working directory inside it. A tree it keeps says why. Long-lived Codex broker processes started in a tree are the usual reason one is kept.
- A worktree builds into its own DerivedData, and `verify.sh` only waits for builds of the same tree, so `--no-wait` is safe there.
- The shell's working directory can drift between calls, so every `git` call for a worktree carries its own `cd <dir> &&` or `git -C <dir>`.
- `worktree.sh --remove <branch>` refuses to remove a tree with uncommitted changes. Commit, or leave it.
