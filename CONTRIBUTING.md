# Contributing to TablePro

## Setup

Requirements: Xcode 26.0+, [XcodeGen](https://github.com/yonaskolb/XcodeGen). Optional: SwiftLint, GitHub CLI (`gh`).

Fork the repo on GitHub, then:

```bash
git clone https://github.com/<your-fork>/TablePro.git && cd TablePro
brew install xcodegen swiftlint
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

`.swiftlint.yml` is the source of truth, and CI runs it on every pull request. The short version:

- 4-space indent, 120-char lines
- Explicit access control (`private`, `internal`, `public`)
- No force unwraps (`!`) or force casts (`as!`)
- `String(localized:)` for user-facing strings
- OSLog only, no `print()`

Before committing:

```bash
swiftlint lint --strict <changed .swift files>
```

## Commits

[Conventional Commits](https://www.conventionalcommits.org/). Pull requests are squash-merged with the PR title as the commit subject, so the title is what lands on `main`: at most 72 characters, checked by CI. Explain the change in the PR description, not in commit bodies.

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

One logical change per PR, described with the template the PR form opens with. Before you open it:

- Tests added or updated.
- `CHANGELOG.md` updated under `[Unreleased]` (skip for a fix to something still unreleased). Leave the credit off: the release adds `(#123 by @you)` to every entry from your pull request.
- Docs updated in `docs/` if the change affects user-facing behavior.
- User-facing strings localized.
- SwiftLint clean.

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

Translate through Xcode's export and import, one XLIFF file per language. Never edit
`Localizable.xcstrings` by hand: Xcode is the only tool that writes it, so a translation diff holds
your language and nothing else.

```bash
xcodebuild -exportLocalizations -project TablePro.xcodeproj -scheme TablePro \
    -localizationPath Localization -exportLanguage fr
# translate Localization/fr.xcloc in Xcode, or its Localized Contents/fr.xliff in any XLIFF editor
xcodebuild -importLocalizations -project TablePro.xcodeproj -localizationPath Localization/fr.xcloc
scripts/localization.py status              # what is translated, per language
```

The export builds the app first, so run `scripts/download-libs.sh` and
`scripts/generate-project.sh` once before it. Pass an existing language code to fill gaps, or a new
one to start a language. Commit the catalog, not the export: `Localization/` is ignored. The iPhone
and iPad app has a catalog of its own: run the same commands on
`TableProMobile/TableProMobile.xcodeproj` with the `TableProMobile` scheme.

Strings from plugins and from packages under `Packages/` live in the app's catalog too, marked
"Managed Manually" so that Xcode keeps them. `scripts/localization.py plugins --add` adds new ones.

## Reporting Bugs

Open a [GitHub issue](https://github.com/TableProApp/TablePro/issues) with:

- macOS version
- TablePro version
- Reproduction steps
- Database type and version (for database-specific bugs)

## License

Contributions are licensed under [AGPLv3](LICENSE).
