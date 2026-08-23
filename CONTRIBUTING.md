# Contributing to TablePro

## Setup

Requirements: macOS 14.0+, Xcode 26.0+, [XcodeGen](https://github.com/yonaskolb/XcodeGen). Optional: SwiftLint, SwiftFormat, GitHub CLI (`gh`).

Fork the repo on GitHub, then:

```bash
git clone https://github.com/<your-fork>/TablePro.git && cd TablePro
brew install xcodegen swiftlint swiftformat
scripts/download-libs.sh
scripts/generate-project.sh
```

`TablePro.xcodeproj` is generated from `project.yml` and is not in git. Re-run
`scripts/generate-project.sh` whenever you change `project.yml` or `Configs/`, and whenever you
add, move, or delete a source file. Never hand-edit the generated project: the next generate
throws the edit away.

### Building with a personal Apple team

Copy the template and fill in your own team. `Configs/Secrets.xcconfig` is gitignored, so your
signing settings can never reach a commit and they survive regenerating the project.

```bash
cp Configs/Secrets.xcconfig.example Configs/Secrets.xcconfig
```

```
TABLEPRO_DEVELOPMENT_TEAM = YOUR_TEAM_ID
TABLEPRO_APP_BUNDLE_IDENTIFIER = com.<yourhandle>.TablePro
```

The Debug configuration already uses `TablePro/TablePro.Debug.entitlements`, which drops iCloud
because free teams don't support it. Sync auto-disables at runtime.

Don't change signing in the Xcode UI: the project is generated, so the next
`scripts/generate-project.sh` discards it.

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
project.yml            Xcode project definition (XcodeGen); .xcodeproj is generated, not in git
Configs/               Shared build settings (.xcconfig), app version, secrets template
TablePro/              App source (Core/, Views/, Models/, ViewModels/, Extensions/, Theme/)
Plugins/               .tableplugin bundles + TableProPluginKit framework
TableProMobile/        iOS app, widget extension, and its own project.yml
Libs/                  Pre-built static libraries (downloaded via script, not in git)
TableProTests/         Tests
docs/                  Mintlify docs site
scripts/               Build and release scripts
```

## Adding a Database Driver

Drivers are `.tableplugin` bundles loaded at runtime. Create a new bundle under `Plugins/`, implement `DriverPlugin` + `PluginDatabaseDriver` from `TableProPluginKit`, and add the target to `project.yml`.

Full guide: [docs/development/plugin-registry](https://docs.tablepro.app/development/plugin-registry)

## Translating

Strings live in a `.xcstrings` catalog, which interleaves every language inside every key. Editing
one by hand means working in a 109,000-line file next to languages you do not speak.

`scripts/localization.py` gives you one flat file per language instead.

```bash
scripts/localization.py status              # what is translated, per language
scripts/localization.py export vi           # Localization/mac.vi.json
# edit the "translation" values
scripts/localization.py import vi           # merge back into the catalog
```

Add `--target ios` for the iPhone and iPad app, which has its own catalog.

Commit the catalog, not the exported file: `Localization/` is ignored, and the catalog stays the
single source of truth. A merge only rewrites the strings you actually changed, so the diff shows
your work and nothing else.

A string marked `needs_review` carries a `"state"` field in the export so you can find it. The
merge never writes that field back: whether a string still needs review is the reviewer's call, not
a side effect of editing the file.

Run `scripts/localization.py verify` if you change the script. It checks that reading and rewriting
each catalog reproduces it byte for byte, which is what keeps a translation diff small.

## Reporting Bugs

Open a [GitHub issue](https://github.com/TableProApp/TablePro/issues) with:

- macOS version
- TablePro version
- Reproduction steps
- Database type and version (for database-specific bugs)

## License

Contributions are licensed under [AGPLv3](LICENSE).
