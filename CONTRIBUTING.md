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

### Building with a personal Apple team

The project's signing settings are read from `Configurations/Shared.xcconfig`, which optionally includes a gitignored `Local.xcconfig` for per-developer overrides. To Debug-build under your own team, copy the example file and edit:

```bash
cp Local.xcconfig.example Local.xcconfig
```

In `Local.xcconfig`, uncomment and set the values you need:

- `DEVELOPMENT_TEAM`: your team ID (Xcode > Settings > Accounts > Manage Certificates).
- `PRODUCT_BUNDLE_IDENTIFIER`: make it unique under your team (e.g. `com.yourhandle.TablePro`).
- `CODE_SIGN_ENTITLEMENTS = TablePro/TablePro.Debug.entitlements`: only if your team is free (no iCloud capability). Sync auto-disables at runtime.

That's it. No pbxproj edits. `Local.xcconfig` is gitignored so your overrides stay local; the project file keeps signing for the official team.

Note: free personal teams hit Apple's 10-bundle-IDs-per-7-days limit because the project signs around a dozen plugin bundles. Expect occasional waits if you re-create your team's signing identity often.

To verify: save a connection password, relaunch, reopen. The password should still be there.

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
