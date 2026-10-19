---
paths:
  - "apple/TableProTests/**/*"
  - "apple/TableProUITests/**/*"
  - "apple/Plugins/*Tests/**/*"
  - "apple/Packages/*/Tests/**/*"
  - "apple/TableProMobile/TableProMobileTests/**/*"
  - "apple/TestPlans/**/*"
  - "apple/scripts/ci/check-test-plans.py"
  - "apple/scripts/clean-test-residue.sh"
---

# Tests

UI flows: `.claude/rules/ui-tests.md`. Running tests and reading verdicts: `.claude/skills/fix-issue/references/verification-apple.md`.

## Where a test goes

| Code under test | Target | Runs in |
| --- | --- | --- |
| A TableProCore module or a PluginKit API | `<Module>Tests`, `TableProPluginKitTests` | `swift test` |
| Logic a plugin and the iOS app share without PluginKit | its TableProCore product's target (`TableProMySQLCoreTests`) | `swift test` |
| Oracle wire logic | `TableProOracleCoreTests` (TableProOracle) | `swift test` |
| A TableProMacCore module, the editor, the grammars | the package's `<Module>Tests` | Unit plan |
| A bundled driver, a bundled format plugin | `<Engine>DriverTests`, `FormatPluginTests` (one bundle for all formats) | Unit plan |
| App code that needs the app host: AppKit windows, `DatabaseManager.shared`, a coordinator | `TableProTests` | Unit plan |
| The iOS app | `TableProMobileTests` | iOS and Package Tests, `verify.sh ios` |
| A new end-to-end user flow | `TableProUITests` | UI plan |

- Take the first row that can hold the test. A hostless target beats `TableProTests`.
- A registry-only driver gets no test target; `AllPlugins` only compiles it. An app-side gate around a registry engine (Safe Mode, the MCP write tier, the query classifier) is app code with a hosted test. `TableProMSSQLCoreTests` and `TableProOracleCoreTests` stay: the iOS app links that code.
- A check that needs a live server, or a service no workflow starts, is a hand-run probe in `apple/scripts/probes/`, never a test.

## Plans

- TableProCore and TableProOracle targets run under `swift test`, in no plan: a plan target that depends on the `TableProPluginKit` package makes the app and plugins compile against that module instead of the resilient framework. A package joins the Unit plan only when nothing it builds depends on that package.
- The test host gets no shell environment: a variable goes into the plan's environment entries or an in-process `setenv`. The Unit plan passes `DEVELOPER_DIR`, or a `/usr/bin` shim a test runs (`python3`) resolves through the Mac's selected Xcode.
- **The Unit plan never retries and runs serially.** In-process parallelism starts every `TableProTests` suite at once and starves the main actor, so time limits kill cases and then the host. A new Xcode target entry carries `"parallelizable": false`; package targets carry no key. `-parallel-testing-enabled YES` turns it back on even where the `.xctestrun` says off.
- **iOS tests have no plan and run with `-parallel-testing-enabled NO`** on one simulator: on the 3-core runner a second booted simulator killed runs with "(ipc/mig) server died". `apple/TableProMobile/project.yml` says `parallelizable: true`, which every run overrides.
- Build for testing scheme-wide, or let `verify.sh` build. `build-for-testing -testPlan UI` alone links TableProMCP statically, and a Unit run on those products loads two copies: "expected error of type MCPProtocolError, but MCPProtocolError was thrown".

## Adding a test target

- Xcode test targets live in `apple/project.yml`; a bundled plugin's uses the `PluginTests` template plus the plugin's linkage template. Name the folder after the target: `verify.sh` finds a test's target by that path component.
- `TableProTests` compiles only `apple/TableProTests/` and links only what the app does not (`TableProTestSupport`, `TableProPostgreSQLCore`, `TableProMCPTestSupport`); the app's packages reach it through `TEST_HOST`. A second link puts a second copy of a module in the bundle. `nm -m` on `TablePro.app/Contents/PlugIns/TableProTests.xctest/Contents/MacOS/TableProTests` must show no `Mn` descriptor of a module the app links; for TableProMCP (11 is the name's length) this prints nothing:

  ```bash
  nm -m "$BIN" | grep -v undefined | grep -E '_\$s11TableProMCP[0-9A-Za-z_]*Mn$'
  ```

- An Xcode target joins its plan by its PBXNativeTarget id from the generated `apple/TablePro.xcodeproj/project.pbxproj`, never the scheme's id. A package target joins with `containerPath: container:Packages/<Package>` and its name as identifier. `apple/scripts/ci/check-test-plans.py` checks plan membership.

## Writing a test

- New tests are Swift Testing; convert an XCTest file you rewrite. `TableProUITests` stays XCTest.
- Keep `@Suite` only to carry a trait, in every test folder: each top-level `@Suite` expansion walks every other one, so compile time grows with their square.
- MemberImportVisibility is on: a hosted test that names a PluginKit enum case imports `TableProPluginKit` beside `@testable import TablePro`. A plugin bundle test compiles the plugin's sources into its own module, so it never uses `@testable`.
- Await the event when one exists, else poll with `waitUntil`. Never a fixed `Task.sleep` or a `Task.yield` loop.
- `.serialized` orders one suite's cases only. A suite that swaps a process-wide value across a suspension (`.appSettings { }`, `.recordingClipboard`) nests under `GlobalStateSuites`, whose `.serialized` orders every suite inside it.

## Isolation and the app host

- With `TABLEPRO_UI_TEST_SANDBOX` set, `AppStorageEnvironment.shared` resolves every store, the defaults suite and the keychain (`SandboxKeychainStore`, a `keychain.json`) inside it. `main.swift` calls `AppStorageEnvironment.bootstrap()` before any static initializer runs.
- The unit host deletes the sandbox's `TablePro` folder at every launch.
- The defaults suite is `com.TablePro.uitest.<16 hex digits>`, a digest of the sandbox path, so each plan, checkout and worktree gets its own. A sandbox without the `.defaults-suite` marker empties its suite, since cfprefsd keeps a suite after its folder is deleted. Plugins derive the same suite through `PluginHostStorage`.
- ManagedPolicy, AppleLanguages, Sparkle and AppKit stay on `.standard`. So AppKit autosave names are nil in the unit host and under the sandbox, and under isolation the app starts neither the updater nor sync (`runPostLaunchActivationIfNeeded` in `AppDelegate`).
- `TABLEPRO_UI_TESTING=1` without a sandbox makes the app log a fault and exit. The app cannot detect XCUITest by itself.
- Under XCTest the app skips plugin loading and its normal startup; the `PluginManager` tests depend on that guard in `AppDelegate`. A hosted test gets plugin metadata from the curated built-in table, so test plugin logic in its bundle.
- `apple/scripts/clean-test-residue.sh` lists what older runs left on the Mac. Give the user the commands (dry run, `--apply`, dry run until every "Would remove" count is 0) rather than running `--apply` on their Mac.

## Shared helpers

Use one before writing a local helper.

- `TableProTestSupport` (TableProCore): `waitUntil`, `AsyncGate`, `ManualClock` (production code takes `clock: any Clock<Duration> = ContinuousClock()`), `BoundedCall`, `HeldOpenWriter`, `BackgroundPipeWriter`, `BackgroundPipeReader`.
- `apple/TableProTests/Helpers/`: `GlobalStateSuites`, `EphemeralDefaults`, `.appSettings { }`, `.recordingClipboard`, `CoordinatorFixture`, `OfflineRegistry`, `InMemoryColumnLayoutStore`, `InMemoryKeychain`, `PluginDriverStub`, `TestFixtures`, `AlwaysAllowGate`, `AlwaysDenyGate`.
- `TableProMCPTestSupport` (TableProMacCore): `MCPTestClock`, `MockHttpServer`, `RecordingBridgeLogger`. `TableProTLSTestFixtures` (TableProCore), also for the iOS tests.

## Known failures and flakes

- Mark a known failure in code (`.disabled("why")` with `.bug("<url>")`, `withKnownIssue { }`, `XCTExpectFailure`), never in a plan or a quarantine file. `.disabled(if:)` only for a real precondition.
- A flake is reproduced by `test-without-building` on the built `TablePro_Unit_macosx<version>-arm64.xctestrun` with `-only-testing:<Target>/<Suite> -test-iterations 10 -run-tests-until-failure`, the one place `-test-iterations` belongs.

## Traps

- One crashing test kills the host, and every later case reports failed at 0.000 s. Find the crash in `~/Library/Logs/DiagnosticReports`.
- `close()` on a test-created `NSWindow` releases it twice and kills the host. Set `isReleasedWhenClosed = false`, or use `orderOut(nil)`.
- A hosted case that reaches the real `ExecutionGate` raises an `NSAlert` nothing answers, and the run stalls. Inject `AlwaysAllowGate` or `AlwaysDenyGate`.
- `NSPasteboard.general` fails headless. Use `.recordingClipboard`.
- Injected `ConnectionSession`s start `.disconnected`. A shared service that treats "has a driver" as live starts real work from unrelated tests: check `.connected`.
- In an offscreen window a floating subview's container is offset by the header height, and `needsDisplay` cannot be observed: assert the geometry.
- `cacheDisplay` of an `NSTableView` runs an alternating-row pass the screen never shows and copies translucent fills as they are. Test the grid's drawing by calling it into a bitmap.
- CI runner windows are 1x and a developer Mac is 2x, so centred geometry lands half a point apart. Use `1 / window.backingScaleFactor` as the tolerance.
- AppKit's private view hierarchy differs between OS builds. Gate such a test on a host probe, `.enabled("why") { await Suite.probe() }`, and pair it with a test that runs everywhere.
- Inside `#expect`, a key path passed to a `rethrows` method (`allSatisfy(\.flag)`) or to a main-actor property (`filter(\.isSelected)`) does not compile. Write the closure: the error fails the whole target, so no suite runs.
