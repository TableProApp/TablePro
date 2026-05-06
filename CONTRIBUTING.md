# Contributing to TablePro

## Setup

Requirements: macOS 14.0+, Xcode 15+. Optional: SwiftLint, SwiftFormat, GitHub CLI (`gh`).

Fork the repo on GitHub, then:

```bash
git clone https://github.com/<your-fork>/TablePro.git && cd TablePro
scripts/download-libs.sh
touch Secrets.xcconfig
brew install swiftlint swiftformat
```

If you're signing the Debug build with a non-official Apple Developer team (e.g. a free personal team), three things in the project file are tied to the official team and need a one-time local override in Xcode. Open `TablePro.xcodeproj`, select the `TablePro` target, then:

1. **Team**: Signing & Capabilities tab → click the **Debug** sub-tab at the top (so the change scopes to Debug only) → set Team to your personal team. If the build fails with a signing error on a different target (driver plugin, framework, mcp-server, tests), repeat for that target — codesign signs each target independently.
2. **Bundle Identifier**: same Debug sub-tab → change `com.TablePro` to something unique under your team (e.g. `com.<yourhandle>.TablePro`). The default `com.TablePro` is reserved for the official team in Apple's developer portal. Plugin sub-IDs (`com.TablePro.MySQLDriver` etc.) are auto-registered under your team and don't need renaming.
3. **Entitlements**: Build Settings tab → search "Code Signing Entitlements" → in the **Debug** row, change `TablePro/TablePro.entitlements` to `TablePro/TablePro.Debug.entitlements`. This second file already ships with the repo (you don't need to create it); it is identical to the default minus the iCloud keys, which free personal teams don't support. iCloud sync is automatically disabled at runtime when the entitlement is absent.

These changes will appear in `TablePro.xcodeproj/project.pbxproj`. **Don't commit them**, or you'll break the official Release signing. Either revert with `git checkout TablePro.xcodeproj/project.pbxproj` before every commit, or run `git update-index --skip-worktree TablePro.xcodeproj/project.pbxproj` once to make git ignore your local changes to that file. Release builds and official-team Debug builds keep using `com.TablePro` and `TablePro/TablePro.entitlements` unchanged.

Verify the setup by saving a database connection with a password, quitting and relaunching the app, then re-opening the connection: the password should still be there.

Build:

```bash
xcodebuild -project TablePro.xcodeproj -scheme TablePro -configuration Debug build -skipPackagePluginValidation
```

Tests:

```bash
xcodebuild -project TablePro.xcodeproj -scheme TablePro test -skipPackagePluginValidation
```

## Code Style

`.swiftlint.yml` and `.swiftformat` are the source of truth. The short version:

- 4-space indent, 120-char lines
- Explicit access control (`private`, `internal`, `public`)
- No force unwraps (`!`) or force casts (`as!`)
- `String(localized:)` for user-facing strings
- OSLog only, no `print()`

Before committing:

```bash
swiftlint lint --strict
swiftformat .
```

## Commits

[Conventional Commits](https://www.conventionalcommits.org/), single line, no body.

```
feat: add CSV export for query results
fix: prevent crash on empty query result
docs: update keyboard shortcuts page
```

## Branch Naming

Branch off `main`:

- `feat/add-cassandra-support`
- `fix/query-editor-crash`
- `docs/update-keyboard-shortcuts`

## Pull Requests

One logical change per PR. Make sure tests pass and lint is clean.

Checklist:

- [ ] Tests added or updated
- [ ] `CHANGELOG.md` updated under `[Unreleased]` (skip for unreleased-only fixes)
- [ ] Docs updated in `docs/` if the change affects user-facing behavior
- [ ] User-facing strings localized
- [ ] No SwiftLint/SwiftFormat violations

## Project Layout

```
TablePro/              App source (Core/, Views/, Models/, ViewModels/, Extensions/, Theme/)
Plugins/               .tableplugin bundles + TableProPluginKit framework
Libs/                  Pre-built static libraries (downloaded via script, not in git)
TableProTests/         Tests
docs/                  Mintlify docs site
scripts/               Build and release scripts
```

## Adding a Database Driver

Drivers are `.tableplugin` bundles loaded at runtime. Create a new bundle under `Plugins/`, implement `DriverPlugin` + `PluginDatabaseDriver` from `TableProPluginKit`, and add the target to the Xcode project.

Full guide: [docs/development/plugin-registry](https://docs.tablepro.app/development/plugin-registry)

## Reporting Bugs

Open a [GitHub issue](https://github.com/TableProApp/TablePro/issues) with:

- macOS version
- TablePro version
- Reproduction steps
- Database type and version (for database-specific bugs)

## CLA

Sign the Contributor License Agreement on your first PR. The CLA bot walks you through it. One-time thing.

## License

Contributions are licensed under [AGPLv3](LICENSE).
