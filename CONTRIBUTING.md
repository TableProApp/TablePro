# Contributing

## Setup

You'll need macOS 14.0+, Xcode 15+, and [Git LFS](https://git-lfs.github.com/) (static libs in `Libs/` are LFS-tracked). Install [SwiftLint](https://github.com/realm/SwiftLint) and [SwiftFormat](https://github.com/nicklockwood/SwiftFormat) too.

```bash
git clone https://github.com/<your-username>/TablePro.git
cd TablePro
git lfs pull
```

Build with the `-skipPackagePluginValidation` flag (needed for the SwiftLint plugin in CodeEditSourceEditor):

```bash
xcodebuild -project TablePro.xcodeproj -scheme TablePro -configuration Debug build -skipPackagePluginValidation
```

Run tests:

```bash
xcodebuild -project TablePro.xcodeproj -scheme TablePro test -skipPackagePluginValidation
```

## Code Style

`.swiftlint.yml` and `.swiftformat` are the source of truth. The short version:

- 4-space indentation, 120-char line length target
- Explicit access control (`private`, `internal`, `public`)
- No force unwraps or force casts. Use `guard let`, `if let`, `as?`
- `String(localized:)` for user-facing strings. SwiftUI view literals auto-localize
- OSLog only, no `print()`

Run both before committing:

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

One change per PR. Make sure tests pass and lint is clean. Link related issues.

Before opening, check:

- [ ] Tests added or updated
- [ ] `CHANGELOG.md` updated under `[Unreleased]` (skip for unreleased-only fixes)
- [ ] Docs updated in `docs/` and `docs/vi/` if the change affects user-facing behavior
- [ ] User-facing strings localized
- [ ] No SwiftLint/SwiftFormat violations

## Project Layout

```
TablePro/              # App source (Core/, Views/, Models/, ViewModels/, etc.)
Plugins/               # Database driver .tableplugin bundles
  TableProPluginKit/   # Shared plugin framework
  MySQLDriverPlugin/   # MySQL/MariaDB
  PostgreSQLDriverPlugin/
  SQLiteDriverPlugin/
  ...
Libs/                  # Pre-built static libraries (Git LFS)
TableProTests/         # Tests
docs/                  # Mintlify docs site
scripts/               # Build and release scripts
```

## Adding a Database Driver

Drivers are `.tableplugin` bundles loaded at runtime. Create a new bundle under `Plugins/`, implement `DriverPlugin` + `PluginDatabaseDriver` from `TableProPluginKit`, and add the target to the Xcode project. Details in `docs/development/plugin-system/`.

## Reporting Bugs

Open a [GitHub issue](https://github.com/datlechin/TablePro/issues) with your macOS version, TablePro version, and reproduction steps. For database-specific bugs, include the database type and version.

## CLA

You'll need to sign the Contributor License Agreement on your first PR. The CLA bot will walk you through it. One-time thing.

## License

Contributions are licensed under [AGPLv3](LICENSE).
