# Contributing to TablePro

[`AGENTS.md`](AGENTS.md) holds the architecture invariants and the rules every change has to meet; where this file and it disagree, it wins. The docs site lives in [TableProApp/docs](https://github.com/TableProApp/docs), and releasing is in [`RELEASING.md`](RELEASING.md).

## Setup

| Software | Version | Notes |
|----------|---------|-------|
| Xcode | 26.0+ | The app calls macOS 26 SDK symbols behind `#available`. The deployment target stays macOS 13.0. Every CI job pins 26.4.1 through `.github/actions/setup-xcode` |
| XcodeGen | 2.46.0 exactly | Generated `pbxproj` output differs between versions, so `scripts/generate-project.sh` warns on any other |
| SwiftLint | any | The pull request gate runs `swiftlint lint --strict` |
| SwiftFormat | any | Not run in CI |
| GitHub CLI | any | Optional: `scripts/download-libs.sh` falls back to `curl` |
| Go | 1.27.1 | SAP HANA plugin only: run `scripts/build-hana.sh` with no argument before building `HanaDriver` or `AllPlugins`. The script fetches 1.27.1 when the installed `go` is another release |
| Rust | 1.91.1 | Dameng plugin only, through [rustup](https://rustup.rs): run `scripts/build-dameng.sh arm64` before building `DamengDriver` or `AllPlugins` |

Fork the repo on GitHub, then:

```bash
git clone https://github.com/<your-fork>/TablePro.git && cd TablePro
brew install xcodegen swiftlint swiftformat
scripts/download-libs.sh
cp Configs/Secrets.xcconfig.example Configs/Secrets.xcconfig
scripts/generate-project.sh
open TablePro.xcodeproj
```

Select the **TablePro** scheme and **My Mac**, then press `Cmd+R`.

### Static libraries

`scripts/download-libs.sh` fetches two archives from the `libs-v1` GitHub Release: the macOS `.a` files (libmariadb, libpq, libduckdb, libmongoc and the rest) and the iOS xcframeworks, 257 MB downloaded and 621 MB on disk. None of it is in git, so a build that skips this step fails at link time. Every run, including one that downloads nothing, verifies `Libs/` against the checksums committed at `HEAD`.

### Signing with your own team

Edit `Configs/Secrets.xcconfig`. The template ships the literal `YOUR_TEAM_ID`, which fails to sign the same way a missing file does:

```
TABLEPRO_DEVELOPMENT_TEAM = YOUR_TEAM_ID
TABLEPRO_APP_BUNDLE_IDENTIFIER = com.<yourhandle>.TablePro
```

A free personal team works. Debug builds sign against `TablePro/TablePro.Debug.entitlements`, which drops iCloud, so sync turns itself off at runtime. Plugin bundles and the MCP helper sign ad-hoc. The file is gitignored, so these settings never reach a commit and survive regenerating the project. Signing changed in the Xcode UI does not last: the next `scripts/generate-project.sh` discards it.

To check it works, save a connection password, relaunch, and reopen the connection. The password should still be there.

### The generated project

`scripts/generate-project.sh` writes `TablePro.xcodeproj` and `TableProMobile/TableProMobile.xcodeproj` from their `project.yml` specs; pass `macos` or `ios` for one. Neither project is in git. Run it again after editing a `project.yml` or anything in `Configs/`, and after adding, moving or deleting a source file: XcodeGen collects sources at generation time. Never hand-edit a generated project.

The Swift language mode comes from `SWIFT_VERSION` in `Configs/Base.xcconfig`, and each package under `Packages/` sets its own. Never pass `SWIFT_VERSION=` to `xcodebuild`: it reaches the packages too and reports their errors as yours.

## Building

```bash
xcodebuild -project TablePro.xcodeproj -scheme TablePro -configuration Debug build -skipPackagePluginValidation
```

`-skipPackagePluginValidation` belongs on every `xcodebuild` invocation. Xcode writes the app to DerivedData; the command line writes it to `build/Debug/` inside the repo.

Debug builds sign with the team from `TABLEPRO_DEVELOPMENT_TEAM`, and that matters locally too: a plugin in the user plugins directory has to carry the same team as the running app.

### Every plugin

The app scheme compiles only the plugins the app embeds. The `AllPlugins` aggregate compiles all of them, and is the check to run after changing anything under `Plugins/TableProPluginKit/`:

```bash
xcodebuild build -project TablePro.xcodeproj -scheme AllPlugins -destination 'platform=macOS' -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO
```

`scripts/build-plugin.sh <PluginTarget>` builds one signed, packaged bundle. Target names are the keys under `targets:` in `project.yml`, such as `OracleDriver`.

### Clean builds

| Reach for | When |
|---|---|
| `Cmd+Shift+K` in Xcode | The usual case |
| `xcodebuild -project TablePro.xcodeproj -scheme TablePro clean` | Same, from a terminal |
| `rm -rf ~/Library/Developer/Xcode/DerivedData` | Package resolution is stuck or a stale module keeps coming back. Clears every project on the machine |

## Tests

```bash
xcodebuild -project TablePro.xcodeproj -scheme TablePro test -skipPackagePluginValidation -only-testing:TableProTests/<SuiteType>
```

Tests are Swift Testing. `-only-testing` matches the suite's Swift type name, or `<SuiteType>/<test>()` for one case. A filter that matches nothing still reports success, so check how many tests ran. `-only-testing:TableProUITests` runs the UI automation, whose suites subclass `UITestCase`. Run the suites that own the types you changed; a full run is not a gate.

## Code style

`.swiftlint.yml` is the source of truth, and CI runs it on every pull request:

```bash
swiftlint lint --strict <changed .swift files>
```

`--strict` turns warnings into errors, and several rules are warnings on purpose, so a plain `swiftlint lint` passes code CI rejects. Nothing lints during an Xcode build. The scope is `included: [TablePro]`, and that key beats a path on the command line: `swiftlint lint Plugins/` lints `TablePro/` and exits 0. Do not run `swiftlint --fix` unreviewed; check its diff.

| Rule | Value |
|---|---|
| Indentation | 4 spaces; `case` not indented inside `switch` |
| Line length | Wrap at 120; SwiftLint warns at 180 and errors at 300 |
| Braces | K&R, `else` on the closing brace line |
| Wrapped arguments | One per line |
| Trailing commas, semicolons | None |
| `self.` | Only where the compiler needs it |
| Booleans | `is`, `has`, `can` or `should` prefix |
| Factory methods | `make` prefix |
| Acronyms | All caps, as in Apple's APIs: `SQLStatementGenerator`, `MCPAuditLogger` |
| Imports | One alphabetical block, no blank lines inside it |

Beyond the linter:

- Explicit access control, declared on the extension rather than on each member.
- No force unwraps (`!`) or force casts (`as!`). `force_try` is disabled in SwiftLint; the rule still applies.
- OSLog, never `print()`.
- Comments say why, never what.
- Storage goes through `AppStorageEnvironment.shared`: two custom rules fail on `applicationSupportDirectory` and `UserDefaults.standard` anywhere else, because a UI test would otherwise write into your own store.
- A type nearing a size limit splits into `TypeName+Category.swift` files under an `Extensions/` folder beside it, grouped by domain. `MainContentCoordinator` is the worked example.
- User-facing strings use `String(localized:)`, never with interpolation: `String(localized: "Preview \(name)")` builds a new key on every call and ships untranslated. Use `String(format: String(localized: "Preview %@"), name)`. Font names, database types and SQL keywords stay unlocalized.

## Architecture

Every database driver is a bundle the app loads at runtime, so nothing switches on database type and `DatabaseType` is a string-backed struct, not an enum. The UI is SwiftUI on an AppKit lifecycle, async work is Swift concurrency, and database connectivity is native C libraries linked from `Libs/`.

| Component | Location | Role |
|-----------|----------|------|
| TableProPluginKit | `Plugins/TableProPluginKit/` | The plugin protocols and transfer types, ABI-resilient |
| PluginManager | `TablePro/Core/Plugins/` | Discovers, validates and loads plugin bundles |
| PluginDriverAdapter | `TablePro/Core/Plugins/` | Bridges a plugin driver to the app's `DatabaseDriver` |
| DatabaseManager | `TablePro/Core/Database/` | Owns connections and sessions; what views and coordinators talk to |
| MainContentCoordinator | `TablePro/Views/Main/` | One per connection session, split across `Views/Main/Extensions/` |
| DataChangeManager, SQLStatementGenerator | `TablePro/Core/ChangeTracking/` | Pending cell edits, and the statements Save turns them into |
| CompletionEngine | `TablePro/Core/Autocomplete/` | Ranks completions; `QueryCompletionAdapter` in `Views/Editor/` bridges it to the editor |
| MCP server | `TablePro/Core/MCP/` | Loopback-only HTTP; its contract is documented under [developers](https://docs.tablepro.app/developers/mcp-protocol) |

| Store | Holds |
|---|---|
| Keychain | Connection passwords |
| UserDefaults | Preferences, favorites, recents |
| SQLite FTS5 | Query history |
| JSON files | Tab state, per-table filters |

| Dependency | Source | Purpose |
|---|---|---|
| TableProEditor | `Packages/`, a fork of CodeEditSourceEditor and CodeEditTextView | The SQL editor |
| TableProGrammars | `Packages/` | Tree-sitter grammars |
| TableProCore | `Packages/` | Modules the macOS and iOS apps share |
| TableProOracle | `Packages/`, wraps a pinned fork of OracleNIO | Oracle wire protocol |
| Sparkle | SPM | Updates, EdDSA-signed |
| swift-certificates | SPM | X.509 types |
| Yams | SPM | YAML for project folder import |

`Plugins/DamengDriverPlugin` links a Rust bridge from `Native/DamengBridge`. `Plugins/HanaDriverPlugin` runs `tablepro-hana-helper`, a Go executable from `Native/HanaBridge`, as one process per session and talks JSON over stdin and stdout.

## Project layout

```
project.yml            Xcode project definition (XcodeGen); the .xcodeproj is generated, not in git
Configs/               Shared build settings (.xcconfig), app version, signing template
TablePro/              App source: Core/, Views/, Models/, ViewModels/, Extensions/, Theme/
Plugins/               .tableplugin bundles and the TableProPluginKit framework
Packages/              Local SwiftPM packages
Native/                Rust and Go bridges for the Dameng and SAP HANA plugins
TableProMobile/        iOS app, widget extension, and its own project.yml
Libs/                  Prebuilt static libraries, downloaded by script, not in git
TableProTests/         Unit tests
TableProUITests/       UI automation
scripts/               Build, release and library scripts
```

`Packages/TableProCore/Sources/TableProPluginKit` is a symlink to `Plugins/TableProPluginKit`. Edit the files under `Plugins/` only.

## Commits

[Conventional Commits](https://www.conventionalcommits.org/). Pull requests are squash-merged with the PR title as the commit subject, so the title is what lands on `main`: at most 72 characters, checked by CI. Explain the change in the PR description, not in commit bodies.

```
feat: add CSV export for query results
fix: prevent crash on empty query result
```

## Branch naming

Branch off `main`:

- `feat/add-cassandra-support`
- `fix/query-editor-crash`

## Pull requests

One logical change per PR, described with the template the PR form opens with. Before you open it:

- Tests added or updated.
- `CHANGELOG.md` updated under `[Unreleased]` (skip for a fix to something still unreleased). Leave the credit off: the release adds `(#123 by @you)` to every entry from your pull request.
- User-facing behavior documented in a paired pull request in [TableProApp/docs](https://github.com/TableProApp/docs) that links this one. It merges after this one does, because its CI checks the app's `main`.
- User-facing strings localized.
- SwiftLint clean.

On every pull request, `macos-tests.yml` builds every plugin, loads each built bundle, then runs the package tests, `TableProTests` and the UI tests in three shards; its first job skips the suites when nothing relevant changed. `ios-tests.yml` covers the iOS app, `swiftlint.yml` the linter, `pr-title.yml` the title, and `repo-hygiene.yml` runs actionlint, shellcheck and the repo's source-scanning checks.

## Adding a database driver

Drivers are `.tableplugin` bundles loaded at runtime. Create a new bundle under `Plugins/`, implement `DriverPlugin` and `PluginDatabaseDriver` from `TableProPluginKit`, and add the target to `project.yml`. Guides: [Plugin Development](https://docs.tablepro.app/development/plugin-development) and [Plugin Registry](https://docs.tablepro.app/development/plugin-registry).

## Translating

Translate through Xcode's export and import, one XLIFF file per language. Never edit `Localizable.xcstrings` by hand: Xcode is the only tool that writes it, so a translation diff holds your language and nothing else.

```bash
xcodebuild -exportLocalizations -project TablePro.xcodeproj -scheme TablePro \
    -localizationPath Localization -exportLanguage fr
# translate Localization/fr.xcloc in Xcode, or its Localized Contents/fr.xliff in any XLIFF editor
xcodebuild -importLocalizations -project TablePro.xcodeproj -localizationPath Localization/fr.xcloc
scripts/localization.py status              # what is translated, per language
```

The export builds the app first, so run `scripts/download-libs.sh` and `scripts/generate-project.sh` once before it. Pass an existing language code to fill gaps, or a new one to start a language. Commit the catalog, not the export: `Localization/` is ignored. The iPhone and iPad app has a catalog of its own: run the same commands on `TableProMobile/TableProMobile.xcodeproj` with the `TableProMobile` scheme.

Strings from plugins and from packages under `Packages/` live in the app's catalog too, marked "Managed Manually" so that Xcode keeps them. `scripts/localization.py plugins --add` adds new ones.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `xcodegen: command not found` | `brew install xcodegen`, then check `xcodegen --version` reports 2.46.0 |
| `TablePro.xcodeproj` does not exist | Run `scripts/generate-project.sh` |
| A new source file does not compile | Run `scripts/generate-project.sh` |
| `Undefined symbols for architecture arm64` | `Libs/` is empty or stale: `scripts/download-libs.sh`, or `--force` to overwrite |
| `Libs does not match the checksums committed in git.` | Re-run `scripts/download-libs.sh --force`. A library rebuilt on purpose is published as [`RELEASING.md`](RELEASING.md#static-libraries) describes |
| `Build input file cannot be found: '…/tablepro-hana-helper'`, or the helper has no slice for your architecture | Run `scripts/build-hana.sh` with no argument, which builds both architectures |
| Signing errors after a fresh clone | `Configs/Base.xcconfig` defaults to the maintainer's team and includes `Secrets.xcconfig` optionally, so a build without it still runs and fails to sign. Create the file with your team |
| Package resolution fails | `Cmd+Shift+K` and reopen Xcode; then `rm -rf ~/Library/Developer/Xcode/DerivedData` |

## Reporting bugs

Open a [GitHub issue](https://github.com/TableProApp/TablePro/issues) with:

- macOS version
- TablePro version
- Reproduction steps
- Database type and version (for database-specific bugs)

## License

Contributions are licensed under [AGPLv3](LICENSE).
