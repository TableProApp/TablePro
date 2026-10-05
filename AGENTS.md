# TablePro

A native macOS database client (SwiftUI + AppKit), a lightweight alternative to TablePlus. macOS 13.0+, Swift 6 language mode for the app targets (`Configs/Base.xcconfig`), Universal Binary. `TableProMobile/` is the iOS app.

This file is the project guide for every agent. Claude Code loads it through `CLAUDE.md`; Codex loads it directly. Area rules live in `.claude/rules/` (index at the end), and Claude Code loads each one automatically when you touch a file its `paths:` names. Codex does not, so read the matching rule before editing those paths.

## Principles

1. **Security first.** Validate at system boundaries; never introduce injection, credential exposure or a widened permission by accident.
2. **Native only.** AppKit, SwiftUI and system frameworks. No cross-platform layers, no web views for native UI. Follow the documented Apple API and the HIG, not a hand-rolled equivalent.
3. **Fix the cause, not the symptom.** Diagnose (add OSLog if needed), then fix the actual cause. No temporary workarounds left in place.
4. **Clean architecture.** Separation of concerns, protocol-oriented design, dependency injection where it earns its place. Consider the effect of every change on the design, not just the immediate problem.
5. **Tests define behavior.** Every testable change has a test. When a test fails, fix the code, never the test.
6. **Open plugin domain.** `DatabaseType` is a string-backed struct, so unknown types from future plugins round-trip. A `switch` over an open type keeps a `default:`; a `switch` over a closed enum stays exhaustive so the compiler flags new cases.

## Repository map

- `TablePro/`: the app. `Core/` (services, business logic), `Views/`, `Models/`, `ViewModels/`, `Extensions/`, `Theme/`.
- `Plugins/`: every database driver and import/export format is a `.tableplugin` bundle, plus `TableProPluginKit`, the shared framework. Bundled plugins are the targets in the app's `copy: { destination: plugins }` phase in `project.yml`; the rest are registry-only and ship through [TableProApp/plugins](https://github.com/TableProApp/plugins). Some bundled plugins also have a registry entry (`"bundled": true` in `.github/plugin-registry.json`) so a fix can reach users before the next app release.
- `Packages/`: local SwiftPM packages (`TableProCore`, `TableProOracle`, `TableProEditor`, `TableProGrammars`). Each sets its own Swift language mode in its manifest; `SWIFT_VERSION` in the xcconfig does not reach them, and passing `SWIFT_VERSION=` to `xcodebuild` reaches every package and reports their errors as yours. `Packages/TableProCore/Sources/TableProPluginKit` is a symlink: edit `Plugins/TableProPluginKit/` only.
- `Native/`: first-party Rust and Go bridges (see `.claude/rules/native-bridges.md`).
- `Libs/`: prebuilt static libraries and iOS xcframeworks, downloaded by `scripts/download-libs.sh`, not in git.
- `TablePro.xcodeproj` and `TableProMobile/TableProMobile.xcodeproj` are generated from `project.yml` and `TableProMobile/project.yml` by XcodeGen. They are gitignored, except each one's tracked `Package.resolved`. Never hand-edit them. Signing overrides and secrets go in `Configs/Secrets.xcconfig` (template: `Secrets.xcconfig.example`).

## Commands

```bash
scripts/download-libs.sh          # first time, and after a libs update
scripts/generate-project.sh       # after editing project.yml or Configs/, or adding, moving or deleting a source file
```

Build, test and lint through the wrapper, which keeps the full log on disk and prints a short verdict (`PASS`, `FAIL`, `INCONCLUSIVE`):

```bash
.claude/skills/fix-issue/scripts/verify.sh build
.claude/skills/fix-issue/scripts/verify.sh test <SuiteType> [SuiteType...]
.claude/skills/fix-issue/scripts/verify.sh lint <file.swift> [...]
```

It also has `generate`, `uitest`, `package`, `ios`, `plugins`, `abi`, `l10n`, `docs` and `agent-docs`; `verify.sh --help` lists them. The raw equivalents always pass `-skipPackagePluginValidation`:

```bash
xcodebuild -project TablePro.xcodeproj -scheme TablePro -configuration Debug build -skipPackagePluginValidation
xcodebuild -project TablePro.xcodeproj -scheme TablePro test -skipPackagePluginValidation -only-testing:TableProTests/<SuiteType>
swiftlint lint --strict <files>
```

- Tests are Swift Testing. `-only-testing` matches the Swift type name of a suite (one case: `<SuiteType>/<test>()`), and a filter that matches nothing still prints `TEST SUCCEEDED`, so check the executed count.
- A full `TableProTests` run is not a gate: run the suites that own the types you changed.
- Release builds: `scripts/build-release.sh arm64|x86_64|both` and `scripts/create-dmg.sh`; the `release` skill runs the whole release.
- SwiftLint (`.swiftlint.yml`) is the enforced style and runs on every PR. Pass it file paths: a directory outside its `included:` scope lints nothing and reports zero violations.

## Architecture

**Plugins.** `PluginManager` (`Core/Plugins/`) loads bundles at runtime. `PluginDatabaseDriver` and `DriverPlugin` live in TableProPluginKit; `PluginDriverAdapter` bridges a plugin driver to the app's `DatabaseDriver`; `DatabaseDriverFactory` finds a plugin by `DatabaseType.pluginTypeId`; `DatabaseManager` owns sessions and is what views and coordinators talk to. A new protocol method goes on `PluginDatabaseDriver` with a default implementation, then into `PluginDriverAdapter`. PluginKit is ABI-resilient and its compatibility rules are in `.claude/rules/plugin-system.md`; read them before touching it.

**DatabaseType.** A string-backed struct, not an enum. Use the static constants (`.mysql`, `.postgresql`) for known types and `DatabaseType.allKnownTypes` for the canonical list.

**Main window.** `MainContentCoordinator` is the central coordinator, split into extension files in `Views/Main/Extensions/`. Each connection a window hosts is a `ConnectionWorkspace` with its own phase; see `.claude/rules/connection-window.md`.

**Change tracking.** A cell edit goes to `DataChangeManager`; Save turns it into statements through `SQLStatementGenerator`; `AnyChangeManager` abstracts the concrete managers. Undo comes from `StructureChangeManager`'s private `UndoManager` and `ConnectionWorkspace.undoManager`.

**Editor.** `ThemeEngine` owns the active theme, editor colors and fonts. `CompletionEngine` is framework-agnostic and `QueryCompletionAdapter` bridges it to the editor. Editor tabs are drawn by `EditorTabStrip`, not native window tabs. Details: `.claude/rules/editor.md`.

**Storage.** Passwords in the Keychain, preferences in UserDefaults, query history in SQLite FTS5, tab state as JSON. The full table of which store owns what is in `.claude/rules/data-sync-storage.md`.

## Invariants that apply everywhere

- **The app runs the AppKit lifecycle.** `main.swift` starts it, `MainMenuBuilder.install` builds the menu bar in `applicationWillFinishLaunching`, and every window is an `NSWindowController`. Never add a SwiftUI `App`: it rewrites `NSApp.mainMenu` after launch.
- **A refresh never clears the cache it refreshes.** Fetch, then commit over the old value. Enter `.loading` only when nothing is loaded, keep the good data when a refresh fails, and use `prepareForReload` for a reload, keeping `invalidate` for disconnect or a database switch.
- **Canceling a connect does not stop the driver.** `Task.cancel()` cannot interrupt a blocking C call, so a connect must be abortable (poll it, or resume through `runCancellableBlocking` and let the late call close its own handle), and every attempt checks its `ConnectionAttemptRegistry` generation before adopting a driver.

## Code style

`.swiftlint.yml` is the source of truth. Beyond it:

- **Comments say why, never what.** A short `///` (one or two lines) belongs where the code would surprise a careful reader: a platform quirk, an invariant, a workaround and the reason for it. Never narrate what the code does, cite tickets, or describe callers. Remove a what-comment when you touch its code.
- Early returns with `guard`; small focused functions; self-explanatory names.
- Explicit access control, declared on the extension rather than on each member.
- No force unwrapping or force casting.
- OSLog (`Logger(subsystem: "com.TablePro", category: "...")`), never `print()`.
- Imports: system frameworks alphabetically, then third-party, then local.
- Approaching a SwiftLint size limit: extract into `TypeName+Category.swift`, grouped by domain.

## Performance pitfalls

- Never `ForEach($bindable.array) { $item in }` on an `@Observable` array that can shrink: index bindings crash. Use `ForEach(array)` and a manual binding.
- On large strings, use `(string as NSString).length` and `character(at:)`, never `.count` or `index(_:offsetBy:)` in a loop.
- Never call `ensureLayout(forCharacterRange:)`; it defeats non-contiguous layout.
- A SQL dump can have one line of millions of characters: cap regex and highlight ranges at 10k characters.

## Every change

1. **Tests.** Unit tests for testable behavior; `TableProUITests` automation for a user flow that runs deterministically, or the reason in the PR. UI suites subclass `UITestCase`. Details: `.claude/rules/tests.md`.
2. **CHANGELOG.md.** A user-visible change gets one fragment under `[Unreleased]`, in the existing canonical section. Format: `.claude/rules/changelog.md`.
3. **Localization.** `String(localized:)` for user-facing strings outside SwiftUI literals, never with interpolation (use `String(format: String(localized: "Preview %@"), name)`). Do not localize technical terms. Plugin and package messages must be in the app catalog, managed manually: `python3 scripts/localization.py plugins --add`. Never hand-edit a `.xcstrings`; translations go through `xcodebuild -exportLocalizations` and `-importLocalizations`.
4. **Docs.** A new shortcut, UI or settings change, or driver change updates `docs/` (Mintlify). Follow `docs/STYLE.md`.
5. **Lint** the changed Swift files with `swiftlint lint --strict`.
6. **Atomic API changes.** A rename or signature change updates every caller and test in the same commit.
7. **Commits and pull requests.** Squash merges use the PR title as the commit subject, so the title is the record: Conventional Commits (`<type>(<scope>): <description>`, `!` for breaking), at most 72 characters, a canonical scope when one fits. CI checks it. Branch commits follow the same format; put the explanation in the PR description, which follows `.github/pull_request_template.md`.
   - Types: `feat`, `fix`, `refactor`, `perf`, `test`, `docs`, `build`, `ci`, `chore`, `style`, `revert`. The `release` skill alone writes `release: v<version>`.
   - Scopes: `ai-chat`, `ai-providers`, `mcp`, `copilot`, `inline-suggest`, `editor`, `datagrid`, `tabs`, `coordinator`, `sidebar`, `connections`, `connection-form`, `welcome`, `settings`, `toolbar`, `hig`, `ssh`, `ios`, `windows`, `perf`, `launch`, `plugins`, `plugin-<name>`, `changelog`, `claude-md`, `docs`, `ci`, `release`.

## Writing style

For everything: docs, commits, CHANGELOG, UI strings, errors, PR descriptions. Short sentences, plain words, specific numbers and names. No em dashes, no filler. `scripts/banned-words.txt` is the list, and `scripts/check-banned-words.sh --staged` checks the added lines of a staged change.

## CI

- **PRs:** `macos-tests.yml`, `ios-tests.yml`, `docs.yml`, `swiftlint.yml` (pinned, `--strict`), `pr-title.yml` (Conventional Commits, at most 72 characters) and `repo-hygiene.yml` (actionlint, shellcheck and the repo's source-scanning checks).
- **Releases:** `build.yml` runs on `v*` tags and produces the DMG, the ZIP and the Sparkle feed, with notes taken from `CHANGELOG.md`.
- **Plugins:** `build-plugin.yml` runs on `plugin-<slug>-v*` tags, where the slug is a key in `.github/plugin-registry.json`.

## Area rules

| Rule | Covers |
| --- | --- |
| `ai-mcp-security.md` | `TablePro/Core/AI`, `TablePro/Core/MCP`, the external API docs |
| `changelog.md` | `CHANGELOG.md` |
| `connection-window.md` | connection windows, workspaces, sessions, `DatabaseManager` |
| `data-grid.md` | the data grid under `TablePro/Views/Results` |
| `data-sync-storage.md` | storage, CloudKit sync, the database core |
| `docs-authoring.md` | `docs/` |
| `editor.md` | `Packages/TableProEditor`, `TablePro/Theme`, editor views |
| `libs.md` | `Libs/` and the libs scripts |
| `mongodb-driver.md`, `mysql-driver.md`, `redis-driver.md` | those drivers |
| `native-bridges.md` | `Native/` and the Dameng and HANA plugins |
| `plugin-system.md` | `Plugins/`, TableProPluginKit, `project.yml`, plugin CI |
| `split-views.md` | split view controllers and workspace panes |
| `tests.md` | `TableProTests`, `TableProUITests` |
| `ui-lifecycle.md` | views, view models, UI tests |
| `welcome-library.md` | the welcome window's connection list |

Skills live in `.claude/skills/`; Codex sees them through `.agents/skills/`. `fix-issue` takes an issue to a pull request; `release` ships a version.
