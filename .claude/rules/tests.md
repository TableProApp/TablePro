---
paths:
  - "TableProTests/**/*"
  - "TableProUITests/**/*"
  - "Plugins/*Tests/**/*"
  - "Packages/*/Tests/**/*"
  - "TableProMobile/TableProMobileTests/**/*"
  - "TestPlans/**/*"
  - "scripts/ci/check-test-plans.py"
  - "scripts/clean-test-residue.sh"
---

# Tests

UI flows: `.claude/rules/ui-tests.md`. Running tests and reading verdicts: `.claude/skills/fix-issue/references/verification-apple.md`.

## Where a test goes

| Code under test | Target | Folder | Host | Runs in |
| --- | --- | --- | --- | --- |
| A TableProCore module | `<Module>Tests` | `Packages/TableProCore/Tests/<Module>Tests/` | none | `swift test`, iOS and Package Tests |
| A PluginKit API | `TableProPluginKitTests` | `Packages/TableProCore/Tests/TableProPluginKitTests/` | none | `swift test`, iOS and Package Tests |
| Logic a plugin and the iOS app share without PluginKit | the test target of its TableProCore product (`TableProMySQLCoreTests`, `TableProMSSQLCoreTests`) | `Packages/TableProCore/Tests/` | none | `swift test`, iOS and Package Tests |
| Oracle wire logic | `TableProOracleCoreTests` | `Packages/TableProOracle/Tests/TableProOracleCoreTests/` | none | `swift test`, iOS and Package Tests when the `oracle` detector fires |
| A TableProMacCore module | `<Module>Tests` | `Packages/TableProMacCore/Tests/<Module>Tests/` | none | Unit plan |
| The editor or the grammars | `TableProEditorKitTests`, `TableProTextEngineTests`, `TableProGrammarsTests` | `Packages/TableProEditor/Tests/`, `Packages/TableProGrammars/Tests/` | none | Unit plan |
| A bundled driver's logic | `<Engine>DriverTests` | `Plugins/<Engine>DriverTests/` | none | Unit plan |
| A bundled format plugin | `FormatPluginTests`, one bundle for all of them | `Plugins/FormatPluginTests/` | none | Unit plan |
| App code that needs the app host: AppKit windows, `DatabaseManager.shared`, a coordinator | `TableProTests` | `TableProTests/` | TablePro.app | Unit plan |
| The iOS app | `TableProMobileTests` | `TableProMobile/TableProMobileTests/` | the iOS app on a simulator | iOS and Package Tests, `verify.sh ios` |
| A new end-to-end user flow | `TableProUITests` | `TableProUITests/` | XCUITest drives TablePro.app | UI plan |

- Take the first row that can hold the test. A hostless target beats `TableProTests`.
- A registry-only driver gets no test target; `AllPlugins` only compiles it. An app-side gate around a registry engine (Safe Mode, the MCP write tier, the query classifier) is app code with a hosted test. `TableProMSSQLCoreTests` and `TableProOracleCoreTests` stay, because the iOS app links that code.
- A check that needs a live server, or a service no workflow starts, is a hand-run probe in `scripts/probes/`, never a test. No workflow runs a probe.

## Plans

- `TestPlans/Unit.xctestplan` is the `TablePro` scheme's default plan. `TestPlans/UI.xctestplan` holds `TableProUITests` alone.
- Unit holds `TableProTests`, the hostless plugin bundles, the Editor and Grammars package targets and the TableProMacCore package targets.
- TableProCore and TableProOracle test targets are in no plan and run under `swift test`. Some depend on the `TableProPluginKit` package, and a plan target that does makes the app and plugins compile against that module instead of the resilient framework. A package joins the Unit plan only when nothing it builds depends on that package; the top of `Packages/TableProMacCore/Package.swift` says so.
- Unit plan settings: language `en`, region `US`, timeouts on with a 60 s default and a 120 s maximum per case, no code coverage, the sandbox variable (Isolation below). UI plan settings are in `.claude/rules/ui-tests.md`.
- The Unit plan never retries. A red case is a bug, or a flake to fix.
- The Unit plan runs serially. Its Xcode targets carry `"parallelizable": false`; the package targets carry no key, so their suites run in parallel in-process. A new Xcode target entry stays serial too.
- Why serial: in-process parallelism starts every `TableProTests` suite at once and starves the main actor, so time limits kill cases and then the host. Parallel clones never split the Swift Testing suites of a hosted target: they all run in one clone. The plugin bundles in parallel save about 1% of the Unit step.
- `-parallel-testing-enabled YES` overrides the plan: it turns in-process Swift Testing parallelism on even where the `.xctestrun` says off.
- Build for testing scheme-wide, or let `verify.sh` build. `build-for-testing -testPlan UI` alone has no `TableProTests` in its graph, so it links TableProMCP statically into the app. `test-without-building -testPlan Unit` on those products then loads two copies, and the MCP cases fail with "expected error of type MCPProtocolError, but MCPProtocolError was thrown". `verify.sh` runs `xcodebuild test -testPlan` for the plan it tests, and CI builds once with no plan.

## Adding a test target

- Xcode test targets are defined in `project.yml`. A bundled plugin's target uses the `PluginTests` template plus that plugin's linkage template, and compiles `Plugins/<plugin folder>`, `Plugins/Shared` and `Plugins/<test target>` against the PluginKit framework.
- Name the folder after the target: `verify.sh` finds a test's target by that path component.
- `TableProTests` compiles only `TableProTests/`. Never add a plugin or package source to it.
- `TableProTests` depends only on what the app does not link: `TableProTestSupport`, `TableProPostgreSQLCore`, `TableProMCPTestSupport`. The app's packages reach it through `TEST_HOST`.
- A second link compiles a second copy of a module into the test bundle. Check with `nm -m` on `<DerivedData>/Build/Products/Debug/TablePro.app/Contents/PlugIns/TableProTests.xctest/Contents/MacOS/TableProTests`: it must define no `Mn` descriptor of a module the app links. For TableProMCP (the number is the name's length) this prints nothing:

  ```bash
  nm -m "$BIN" | grep -v undefined | grep -E '_\$s11TableProMCP[0-9A-Za-z_]*Mn$'
  ```

- Add the target to its plan. An Xcode target goes in by its PBXNativeTarget id from the generated `TablePro.xcodeproj/project.pbxproj`, never the scheme's id. A package target goes in with `containerPath: container:Packages/<Package>` and its name as identifier.
- `scripts/ci/check-test-plans.py`, run by Repo Hygiene, fails on: a test target missing from its plan or in the wrong one; a plan entry with no target; a TableProCore or TableProOracle target in a plan; a wrong `containerPath`; a duplicate entry; an Xcode test target with no folder of its name; `enabled: false`, `skippedTests` or `selectedTests`.
- It reads target types from `project.yml`, templates included, and test targets from every `Packages/*/Package.swift`, so a new package needs no script change.

## Writing a test

- New tests are Swift Testing. Convert an XCTest file you rewrite. `TableProUITests` stays XCTest.
- No bare top-level `@Suite` in `TableProTests`, `Plugins/*Tests` or `Packages/TableProMacCore/Tests`. Each top-level `@Suite` expansion walks every other one, so compile time grows with their square. Keep `@Suite` only to carry a trait. SwiftLint's `suite_without_trait` enforces it in those folders; the other package test folders are not covered yet, so follow it there by hand.
- Hosted tests reach app code through `@testable import TablePro`. MemberImportVisibility is on, so a file that names a PluginKit enum case also imports `TableProPluginKit`.
- A plugin bundle test compiles the plugin's sources into its own module: it imports `TableProPluginKit` and `Testing`, never `@testable import`.
- A test does not depend on the machine. Pin the locale, use `.recordingClipboard` rather than the real pasteboard, keep the network out (`OfflineRegistry` for the plugin registry), inject the clock (`ManualClock`).
- Wait for an effect no event reports with `waitUntil`, which polls every 5 ms and throws `WaitTimeout` naming the file and line. Await an event when one exists. Never a fixed `Task.sleep` or a `Task.yield` loop.
- `.serialized` orders the cases of one suite only; it is not isolation. A suite that swaps a process-wide value across a suspension nests under `GlobalStateSuites`, whose `.serialized` orders every suite inside it. Users of `.appSettings { }` and `.recordingClipboard` nest there.
- A regression test proves something only once it fails without the fix. Revert the fix and watch it fail, or name the change that turns it red.

## Isolation and the app host

- When `TABLEPRO_UI_TEST_SANDBOX` is set, `AppStorageEnvironment.shared` resolves every store, the defaults suite and the keychain inside it. `main.swift` calls `AppStorageEnvironment.bootstrap()` before any static initializer runs. The rule for production code is in `AGENTS.md`, Invariants that apply everywhere.
- The Unit plan sets the sandbox to `$(TARGET_TEMP_DIR)/UnitTestStorage`, under DerivedData. The unit host deletes the sandbox's `TablePro/` folder at every launch, so every run starts empty.
- The defaults suite is `com.TablePro.uitest.<16 hex digits>`, a digest of the sandbox path, so each plan, checkout and worktree gets its own. A sandbox without the `.defaults-suite` marker is new and empties its suite, since cfprefsd keeps a suite after its folder is deleted. Plugins derive the same suite through `PluginHostStorage`.
- Under isolation the keychain is `SandboxKeychainStore`, a `keychain.json` in the sandbox.
- AppKit autosave names (split views, window frames, tables) are nil in the unit host and under the sandbox, because AppKit writes those records to the real domain. The rule for a new one is in `AGENTS.md`, Invariants that apply everywhere.
- Stores default to `AppStorageEnvironment.shared.defaults`. ManagedPolicy, AppleLanguages, Sparkle and AppKit stay on `.standard`.
- Sparkle reads the real domain, so under isolation the app starts neither the updater nor sync (`runPostLaunchActivationIfNeeded` in `AppDelegate`).
- `TABLEPRO_UI_TESTING=1` without a sandbox makes the app log a fault and exit. The app cannot detect XCUITest by itself.
- The test host gets no shell environment. A variable goes into the plan's environment entries, or an in-process `setenv`.
- Under XCTest the app skips plugin loading and its normal startup. Keep that guard in `AppDelegate`; the `PluginManager` tests depend on it. Plugin metadata in a hosted test comes from the curated built-in table, so test plugin logic in its bundle.
- `PluginManager.waitForInitialLoad()` returns at once unless `loadPlugins()` started a load. Its 10 s timeout, on the injected `initialLoadClock`, still covers a load that hangs.
- A known write to the real domain, accepted: a test that changes the general settings runs `AppLanguage.apply()`, which writes `AppleLanguages` to `.standard`.
- Proof a change writes nothing real: `ls ~/Library/Preferences | wc -l` and `defaults read com.TablePro | wc -l` give the same numbers before and after one Unit run and one UI run.
- `scripts/clean-test-residue.sh` lists what older test runs left on the Mac: test defaults domains, test keys and sandboxed autosave records in `com.TablePro`, `mcp-audit-test_` databases, test folders in the user temp directory. It never touches per-connection keys.
- Its `--apply` backs everything up to `~/TablePro-test-residue-<timestamp>/` before removing it, and refuses while TablePro or a TablePro test run is active. Give the user the commands (dry run, `--apply`, dry run again until every "Would remove" count is 0) rather than running `--apply` on their Mac.

## Shared helpers

Use one before writing a local helper.

| Helper | Where | Use |
| --- | --- | --- |
| `waitUntil` | `TableProTestSupport` | poll for an effect no event reports |
| `AsyncGate` | `TableProTestSupport` | hold callers until the case calls `open()`; `arrived(_:)` waits for that many callers |
| `ManualClock` | `TableProTestSupport` | time moves only on `advance(by:)`; production code takes `clock: any Clock<Duration> = ContinuousClock()` |
| `BoundedCall`, `HeldOpenWriter`, `BackgroundPipeWriter`, `BackgroundPipeReader` | `TableProTestSupport` | bound a call that can block; drive a pipe from another thread |
| `GlobalStateSuites` | `TableProTests/Helpers/` | parent of every suite that swaps a process-wide value |
| `EphemeralDefaults` | `TableProTests/Helpers/` | a defaults suite that deletes its domain and plist with its owner |
| `.appSettings { }`, `.recordingClipboard` | `TableProTests/Helpers/` | traits that swap the app settings or the clipboard for one case |
| `CoordinatorFixture` | `TableProTests/Helpers/` | a coordinator that is torn down with the fixture |
| `OfflineRegistry` | `TableProTests/Helpers/` | a registry client that never reaches the network |
| `InMemoryColumnLayoutStore`, `InMemoryKeychain`, `PluginDriverStub`, `TestFixtures` | `TableProTests/Helpers/` | stores and driver doubles |
| `AlwaysAllowGate`, `AlwaysDenyGate` | `TableProTests/Helpers/StubExecutionGates.swift` | an `ExecutionGate` that never raises the real alert |
| `TableProMCPTestSupport` | `Packages/TableProMacCore/Tests/TableProMCPTestSupport/` | MCP doubles: `MCPTestClock`, `MockHttpServer`, `RecordingBridgeLogger` |
| `TableProTLSTestFixtures` | `Packages/TableProCore/Tests/TableProTLSTestFixtures/` | TLS fixtures, also used by the iOS tests |

`TableProTestSupport` is the TableProCore product at `Packages/TableProCore/Tests/TableProTestSupport/`.

## Known failures and flakes

- Mark a known failure in code: `@Test(.disabled("why"), .bug("<url>"))`, `withKnownIssue { }`, or `XCTExpectFailure` in XCTest. `.disabled(if:)` only for a real precondition.
- There are no quarantine files, and a plan never skips a test (`check-test-plans.py` refuses it).
- To reproduce an intermittent failure, build scheme-wide, then run the built plan repeatedly. This is the one place `-test-iterations` belongs:

  ```bash
  xcodebuild test-without-building -destination platform=macOS \
    -xctestrun <DerivedData>/Build/Products/TablePro_Unit_macosx<version>-arm64.xctestrun \
    -only-testing:<Target>/<Suite> -test-iterations 10 -run-tests-until-failure
  ```

- A UI flow that fails only on CI: `.claude/rules/ui-tests.md`, Known failures.

## Traps

- One crashing test kills the host, and every later case reports failed at 0.000 s. Find the crash in `~/Library/Logs/DiagnosticReports`.
- `close()` on a test-created `NSWindow` releases it twice and kills the host. Set `isReleasedWhenClosed = false`, or use `orderOut(nil)`.
- A hosted case that reaches the real `ExecutionGate` raises an `NSAlert` that nothing answers, and the run stalls. Inject a gate.
- `NSPasteboard.general` fails headless. Use `.recordingClipboard`.
- On the main actor, a `Task.yield` loop starves what it waits for.
- Awaiting a finished Task does not suspend.
- A synchronous `@MainActor` test that pumps the run loop never runs main-actor Tasks.
- Injected `ConnectionSession`s start `.disconnected`. A shared service that treats "has a driver" as live starts real work from unrelated tests, so such a service checks for `.connected`.
- In an offscreen window a floating subview's container is offset by the header height, and `needsDisplay` cannot be observed. Assert the geometry, not the flag.
- `cacheDisplay` of an `NSTableView` runs an alternating-row pass the screen never shows and copies translucent fills as they are. Test the grid's drawing by calling it into a bitmap.
- CI runner windows are 1x and a developer Mac is 2x, so centred geometry lands half a point apart. Use `1 / window.backingScaleFactor` as the tolerance.
- AppKit's private view hierarchy differs between OS builds (selection material, effect views). Gate such a test on a host probe, `.enabled("why") { await Suite.probe() }`, and pair it with a test that runs everywhere.
- Inside `#expect`, a key path passed to a `rethrows` method (`allSatisfy(\.flag)`) does not compile, nor does a key path to a main-actor property (`filter(\.isSelected)`). Write the closure. The compile error fails the whole target, so no suite runs.
