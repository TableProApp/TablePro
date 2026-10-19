# TablePro for macOS and iOS

A native macOS database client (AppKit and SwiftUI), macOS 13.0+, Swift 6 language mode for the app targets. `TableProMobile/` is the iOS app. A path here is relative to `apple/`, except `.claude/` and `.github/` at the repository root.

## Principles

- **Native only.** AppKit, SwiftUI and system frameworks, used as Apple documents them and the HIG describes. No cross-platform layer, no web view for native UI.
- **Open plugin domain.** `DatabaseType` is a string-backed struct, so a plugin's type round-trips. A `switch` over an open type keeps a `default:`; one over a closed enum stays exhaustive.

## Scope

Every capability is core, a module or a plugin. The first rule that fits decides:

1. Used weekly by app or backend developers or AI-first users, or only a row that runs nothing until clicked: **core**, no toggle.
2. UI for one engine: core, shown only for drivers that support it.
3. A database driver or a heavy native dependency: **plugin**, registry-shipped, signed by TablePro.
4. Any other advanced tool needing a session, the grid, the editor or native UI: **module**, compiled in, toggled as a unit.
5. A duplicate, or not worth maintaining: delete it, never park it in the registry.

- A new engine ships only as a registry plugin: no engine-specific code in `TablePro/`; engine UI uses a PluginKit capability or plugin metadata.
- A new advanced tool ships as a module, off by default.
- A module PR declares its id, default, off-state sink, residue test (a behavior test) and docs page.
- An off module leaves nothing behind: no menu item, key equivalent, context item, Settings section or Keyboard row; no launch work, observer, timer, listener or child process; no Keychain read or network call. A URL, AppleScript or MCP request for it gets an error naming where to enable it; only a click in TablePro enables it.

## Repository map

- `TablePro/`: the app.
- `Plugins/`: drivers and import/export formats as `.tableplugin` bundles, plus `TableProPluginKit`. Bundled plugins are the `copy: { destination: plugins }` targets in `project.yml`; the app never offers a registry install or update over one.
- `Packages/`: `TableProCore` (both apps), `TableProMacCore` (macOS only, never in the iOS project), `TableProOracle`, `TableProEditor`, `TableProGrammars`. Edit PluginKit in `Plugins/TableProPluginKit/` only; `TableProCore` symlinks it. Never pass `SWIFT_VERSION=` to `xcodebuild`.
- `Native/`: Rust and Go bridges. `Libs/`: static libraries from `scripts/download-libs.sh`, not in git.
- XcodeGen generates `TablePro.xcodeproj` and `TableProMobile/TableProMobile.xcodeproj`; never hand-edit them. Signing overrides go in `Configs/Secrets.xcconfig`.
- Architecture lives in `.claude/rules/`: `plugin-system.md`, `connection-window.md`, `editor.md`, `theme.md` and `data-sync-storage.md`.

## Commands

From the repository root:

```bash
apple/scripts/download-libs.sh  # first time, and after a libs update
apple/scripts/generate-project.sh [both|macos|ios]  # after a project.yml or Configs/ edit, or a new, moved or deleted source file
.claude/skills/fix-issue/scripts/verify.sh build
.claude/skills/fix-issue/scripts/verify.sh test [<Suite>|<Suite>/<case>()|<Target>/<Suite>...]  # none: the Unit plan
.claude/skills/fix-issue/scripts/verify.sh lint <file.swift>...
```

- `verify.sh --help` lists every step. When each runs: `.claude/skills/fix-issue/references/platform-apple.md`, Verify. Verdicts, test names and red CI checks: `.claude/skills/fix-issue/references/verification-apple.md`.
- A raw `xcodebuild` runs in `apple/` with `-skipPackagePluginValidation`, plus `-testPlan Unit` or `UI` for macOS tests (`CONTRIBUTING.md`, Tests).
- Never add `-parallel-testing-enabled`, `-test-iterations` or `-retry-tests-on-failure` to a macOS run, except to reproduce a flake: the plans own those. iOS tests pass `-parallel-testing-enabled NO`.
- Never run `swiftlint --fix`. Formatting SwiftLint leaves open: `CONTRIBUTING.md`, Code style.
- Releases: `RELEASING.md` and the `release` skill.

## Invariants that apply everywhere

- **AppKit lifecycle.** `main.swift` starts the app, `MainMenuBuilder.install` builds the menus, windows are `NSWindowController`s. Never add a SwiftUI `App`: it rewrites `NSApp.mainMenu`.
- **A refresh never clears what it refreshes.** Fetch, then commit over the old value; `.loading` only when nothing is loaded; keep good data on failure; `prepareForReload` to reload, `invalidate` on disconnect.
- **A canceled connect keeps running.** `Task.cancel()` cannot interrupt a blocking C call: poll the connect or resume through `runCancellableBlocking`, then check the `ConnectionAttemptRegistry` generation before adopting a driver.
- **Storage resolves through `AppStorageEnvironment.shared`**: stores, defaults suite and keychain.
- **An AppKit autosave name** (split view, window frame, table) **goes through `SplitViewAutosaveName.current(_:)`**: the sandbox does not redirect the defaults domain AppKit writes it to.
- **No new test-only branch in production code**: tests use injection or `TABLEPRO_UI_TEST_SANDBOX`.
- **macOS files the iOS app compiles** (listed in `TableProMobile/project.yml`) give each top-level declaration explicit isolation, usually `nonisolated`, since iOS defaults to `MainActor`. The iOS build is the check.
- **No package product in a macOS binary depends on the `TableProPluginKit` package**: a plugin would carry its own PluginKit types.
- **A source-text rule is a SwiftLint rule or a `scripts/ci` check**, never a test reading source.
- Never `ForEach($bindable.array) { $item in }` on an `@Observable` array that can shrink: index bindings crash. Use `ForEach(array)` and a manual binding.
- Log with `Logger(subsystem: "com.TablePro", category: ...)`, never `print()`.

## Every change

1. **Tests.** A test in the target owning the code. Read `.claude/rules/tests.md` before creating a test file. A UI flow only for a new or changed end-to-end flow (`.claude/rules/ui-tests.md`).
2. **Changelog.** A user-visible change adds `changelog.d/<PR>.<type>.md`; only a release PR edits `CHANGELOG.md` (`.claude/rules/changelog.md`).
3. **Localization.** `String(localized:)` outside SwiftUI literals, never interpolated: `String(format: String(localized: "Preview %@"), name)`. Technical terms stay unlocalized. A plugin or package string goes in the host app's catalog: run `python3 scripts/localization.py plugins --add` from `apple/`, plus `--target ios` for a package the iOS app links. Never hand-edit a `.xcstrings`.
4. **Docs.** A new shortcut, UI or settings change, or driver change gets a paired draft PR in TableProApp/docs naming this one; it merges after this one. `verify.sh docs` runs its checks here first.
5. **Lint** each changed Swift file with `verify.sh lint`.
