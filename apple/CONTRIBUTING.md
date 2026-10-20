# Contributing to TablePro for macOS and iOS

This file covers the macOS and iOS apps in `apple/`, and every command in it runs from `apple/`. [`AGENTS.md`](AGENTS.md) holds the invariants and the rules every change meets; where this file and it disagree, it wins. What both apps share, branch naming and pull requests among it, is in the root [`CONTRIBUTING.md`](../CONTRIBUTING.md). The docs site lives in [TableProApp/docs](https://github.com/TableProApp/docs), and releasing is in [`RELEASING.md`](RELEASING.md). The Linux app has its own setup and rules in [`linux/CONTRIBUTING.md`](../linux/CONTRIBUTING.md).

## Setup

| Software | Version | Notes |
|---|---|---|
| Xcode | 27.1 | What CI selects in `.github/actions/setup-xcode`. Code that needs the macOS 27 SDK sits behind `SDK_MACOS_27` (`Configs/Base.xcconfig`) so Xcode 26 can still build, though nothing on CI builds with 26. Symbols newer than the deployment target ([`AGENTS.md`](AGENTS.md)) sit behind `#available` |
| XcodeGen | 2.46.0 exactly | The generated project differs between versions, so `scripts/generate-project.sh` warns on any other |
| SwiftLint | 0.65.1 | The version CI runs |
| GitHub CLI | any | Optional: `scripts/download-libs.sh` falls back to `curl` |
| Go | `toolchain` in `Native/HanaBridge/go.mod` | SAP HANA plugin only: run `scripts/build-hana.sh` with no argument before building `HanaDriver` or `AllPlugins`. When the installed `go` is another release, `go` switches to that toolchain itself |
| Rust | `Native/DamengBridge/rust-toolchain.toml` | Dameng plugin only, through [rustup](https://rustup.rs), which installs it: run `scripts/build-dameng.sh arm64` before building `DamengDriver` or `AllPlugins` |

Fork the repo on GitHub, then:

```bash
git clone https://github.com/<your-fork>/TablePro.git && cd TablePro/apple
brew install xcodegen swiftlint
scripts/download-libs.sh
cp Configs/Secrets.xcconfig.example Configs/Secrets.xcconfig
scripts/generate-project.sh
open TablePro.xcodeproj
```

Select the **TablePro** scheme and **My Mac**, then press `Cmd+R`.

### Static libraries

`scripts/download-libs.sh` fetches two archives from the `libs-<n>` GitHub release that `Libs/release` names: the macOS `.a` files (libmariadb, libpq, libduckdb, libmongoc and the rest) and the iOS xcframeworks. None of it is in git, so a build that skips this step fails at link time. Every run, including one that downloads nothing, verifies `Libs/` against the checksums committed at `HEAD`. Publishing a rebuilt library is in `RELEASING.md`, Static libraries.

## Building with a personal Apple team

Edit `Configs/Secrets.xcconfig`. The template ships the literal `YOUR_TEAM_ID`, which fails to sign the same way a missing file does:

```
TABLEPRO_DEVELOPMENT_TEAM = <your team id>
TABLEPRO_APP_BUNDLE_IDENTIFIER = com.<yourhandle>.TablePro
```

A free personal team works. Debug builds sign against `TablePro/TablePro.Debug.entitlements`, which drops iCloud, so sync turns itself off. Plugin bundles sign with the same team, and the MCP helper signs ad hoc. The file is gitignored, so these settings never reach a commit and survive regenerating the project. Signing changed in the Xcode UI does not: the next `scripts/generate-project.sh` discards it. To check it, save a connection password, relaunch, and reopen the connection: the password is still there.

## Building

```bash
xcodebuild -project TablePro.xcodeproj -scheme TablePro -configuration Debug build -skipPackagePluginValidation
```

Xcode and the command line both write the app to `~/Library/Developer/Xcode/DerivedData/TablePro-*/Build/Products/Debug/TablePro.app`. When to regenerate the project, and why never to pass `SWIFT_VERSION=`: [`AGENTS.md`](AGENTS.md), Commands and Repository map. Debug builds sign with the team from `TABLEPRO_DEVELOPMENT_TEAM`, and a plugin in the user plugins folder must carry the same team as the running app.

### Every plugin

The app scheme compiles only the plugins the app embeds. The `AllPlugins` aggregate compiles all of them; when to run it is in `.claude/rules/plugin-system.md`, Building.

```bash
xcodebuild build -project TablePro.xcodeproj -scheme AllPlugins -destination 'platform=macOS' -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO
```

`scripts/install-plugin-dev.sh <Target>` copies a registry plugin you built in Debug into the user plugins folder.

### A Release build

`scripts/release/build.sh` builds the app and the registry plugins the way a tag does, universal, into `build/release/`; `package.sh` writes the assets to `dist/`. Release Build runs the same:

```bash
export VERSION=0.0.0-dev BUILD=9999999
scripts/release/build.sh app --unsigned && scripts/release/package.sh app --unsigned
scripts/build-dameng.sh both && scripts/build-hana.sh both
scripts/release/build.sh plugins --unsigned && scripts/release/package.sh plugins --unsigned
```

Signed: drop `--unsigned`, with the Developer ID identity and the provisioning profile `scripts/release/ExportOptions.plist` names. `scripts/release/notarize.sh <path>...` needs the profile `xcrun notarytool store-credentials TablePro --key <p8> --key-id <id> --issuer <issuer>` creates.

### Clean builds

| Reach for | When |
|---|---|
| `Cmd+Shift+K` in Xcode | The usual case |
| `xcodebuild -project TablePro.xcodeproj -scheme TablePro clean` | Same, from a terminal |
| `rm -rf ~/Library/Developer/Xcode/DerivedData` | Package resolution is stuck or a stale module keeps coming back. Clears every project on the machine |

## Tests

From the repository root, prefer `.claude/skills/fix-issue/scripts/verify.sh test <Suite>` ([`AGENTS.md`](AGENTS.md), Commands): it finds the target that declares the suite and fails a run that executed nothing. Where a test goes and how to write one: `.claude/rules/tests.md`; UI flows: `.claude/rules/ui-tests.md`.

The raw equivalents, in order: a suite in the Unit plan, a UI flow (needs Automation Mode: `.claude/skills/fix-issue/references/verification-apple.md`, INCONCLUSIVE), a TableProCore or TableProOracle suite (no Xcode plan lists those two packages), and the iOS app:

```bash
xcodebuild -project TablePro.xcodeproj -scheme TablePro test -testPlan Unit -skipPackagePluginValidation -only-testing:<Target>/<Suite>
xcodebuild -project TablePro.xcodeproj -scheme TablePro test -testPlan UI -skipPackagePluginValidation -only-testing:TableProUITests/<Suite>
swift test --package-path Packages/TableProCore --filter '<Target>.<Suite>'
xcodebuild -project TableProMobile/TableProMobile.xcodeproj -scheme TableProMobile test -only-testing:TableProMobileTests/<Suite> \
    -destination 'platform=iOS Simulator,name=<iPhone>' -parallel-testing-enabled NO -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO ARCHS=arm64
```

## Code style

`.swiftlint.yml` is the source of truth. Run `swiftlint lint --strict <changed .swift files>`; CI lints all of `apple/` the same way on every pull request, and nothing lints during an Xcode build. Formatting the linter leaves to you:

| Rule | Value |
|---|---|
| Indentation | 4 spaces |
| Line length | Wrap at 120 |
| Braces | K&R |
| Wrapped arguments | One per line |
| Trailing commas | None |
| `self.` | Only where the compiler needs it |

Logging, storage and localization: [`AGENTS.md`](AGENTS.md), Invariants that apply everywhere and Every change.

## Architecture

The architecture is in the area rules under `.claude/rules/`, and its invariants in [`AGENTS.md`](AGENTS.md), Invariants that apply everywhere.

| Dependency | Source | Purpose |
|---|---|---|
| TableProEditor | `Packages/`, vendored from CodeEditSourceEditor and CodeEditTextView | The SQL editor |
| TableProGrammars | `Packages/` | Tree-sitter grammars |
| TableProCore | `Packages/` | Modules the macOS and iOS apps share |
| TableProMacCore | `Packages/` | macOS-only modules the app links: utilities, autocomplete, SSH config, MCP |
| TableProOracle | `Packages/`, wraps a pinned fork of OracleNIO | Oracle wire protocol |
| Sparkle | SPM | Updates, EdDSA-signed |
| Yams | SPM | YAML for project folder import |
| swift-nio, swift-nio-ssl, zstd | SPM | The Kafka plugin's transport, TLS and zstd codec |

## Adding a database driver

A new engine ships as a registry plugin: a `.tableplugin` bundle under `Plugins/` that implements `DriverPlugin` and `PluginDatabaseDriver` from `TableProPluginKit`, with a target in `project.yml`. The checklist is in `.claude/rules/plugin-system.md`, Structure. Guides: [Plugin Development](https://docs.tablepro.app/development/plugin-development) and [Plugin Registry](https://docs.tablepro.app/development/plugin-registry).

## Translating

Translate through Xcode's export and import, one XLIFF file per language. Never edit `Localizable.xcstrings` by hand: Xcode is the only tool that writes it, so a translation diff holds your language and nothing else.

```bash
xcodebuild -exportLocalizations -project TablePro.xcodeproj -scheme TablePro \
    -localizationPath Localization -exportLanguage fr
# translate Localization/fr.xcloc in Xcode, or its Localized Contents/fr.xliff in any XLIFF editor
xcodebuild -importLocalizations -project TablePro.xcodeproj -localizationPath Localization/fr.xcloc
scripts/localization.py status              # what is translated, per language
```

The export builds the app first, so run `scripts/download-libs.sh` and `scripts/generate-project.sh` once before it. Pass an existing language code to fill gaps, or a new one to start a language. Commit the catalog, not the export: `Localization/` is ignored. The iPhone and iPad app has its own catalog: run the same commands on `TableProMobile/TableProMobile.xcodeproj` with the `TableProMobile` scheme. Plugin and package strings, and strings a command-line build added: [`AGENTS.md`](AGENTS.md), Every change 3.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `xcodegen: command not found` | `brew install xcodegen`, then check `xcodegen --version` reports 2.46.0 |
| `TablePro.xcodeproj` does not exist | Run `scripts/generate-project.sh` |
| A new source file does not compile | Run `scripts/generate-project.sh` |
| `Undefined symbols for architecture arm64` | `Libs/` is empty or stale: `scripts/download-libs.sh`, or `--force` to overwrite |
| `Libs does not match the checksums committed in git.` | Re-run `scripts/download-libs.sh --force`. A library rebuilt on purpose is published as [`RELEASING.md`](RELEASING.md#static-libraries) describes |
| `error: …/tablepro-hana-helper is missing or has no <arch> slice` | Run `scripts/build-hana.sh` with no argument, which builds both architectures |
| Signing errors after a fresh clone | `Configs/Base.xcconfig` defaults to the maintainer's team and includes `Secrets.xcconfig` optionally, so a build without it still runs and fails to sign. Create the file with your team |
| Package resolution fails | `Cmd+Shift+K` and reopen Xcode; then `rm -rf ~/Library/Developer/Xcode/DerivedData` |
| Test runs left defaults domains (`com.TablePro.tests.*`, `com.TablePro.uitest.*`) or temp folders behind | Quit TablePro, then run `scripts/clean-test-residue.sh`. It only reports until you pass `--apply` |
