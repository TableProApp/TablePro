# TablePro

Native database clients, one per platform, sharing no code: `apple/` holds the macOS and iOS apps (Swift, AppKit and SwiftUI), `linux/` the Linux app (Rust, GTK 4). This guide holds the rules both follow. Claude Code loads it through `CLAUDE.md`, Codex directly.

Each app has its own guide beside its code: `apple/AGENTS.md` and `linux/AGENTS.md`. Claude Code loads one through its `CLAUDE.md` once it reads a file in that folder; Codex reads one when started there, so otherwise read the guide before working in its folder.

## Principles

1. **Security first.** Validate at system boundaries; never introduce injection, credential exposure or a widened permission by accident.
2. **Fix the cause, not the symptom.** Diagnose (add logging if needed), then fix the cause. No workaround left behind.
3. **Tests define behavior.** Every testable change has a test. When a test fails, fix the code, never the test. A test that pins behavior the PR changes on purpose is updated in the same PR and named in its description.

## Repository map

- `apple/`: the macOS and iOS apps, their plugins, packages, native bridges, scripts and changelog.
- `linux/`: the GTK 4 Linux app, built with Meson and Cargo, with its own changelog.
- `.github/`: workflows, actions, the PR template, `plugin-registry.json` and the CI baselines.
- `.claude/`: the path-scoped rules (Area rules below) and the `fix-issue` and `release` skills.
- `scripts/`: what both apps share: `banned-words.txt` with `check-banned-words.sh`, `check-doc-symbols.sh`, the PR title, changelog and changed-path checks in `scripts/ci`, and the towncrier pin in `scripts/release`.
- `appcast.xml`: the legacy feed apps up to 0.81 read from `main` (`apple/RELEASING.md`, Channels). It stays at the root.
- Docs site: TableProApp/docs, cloned beside this repo as `../tablepro-docs`, under its own `AGENTS.md` and `STYLE.md`.

## Verification

`.claude/skills/fix-issue/scripts/verify.sh` runs every step from the repository root, keeps the full log and prints `PASS`, `FAIL` or `INCONCLUSIVE`. It picks the platform from the machine; `--platform linux` names one. `INCONCLUSIVE` is never a pass. Steps per platform: the `fix-issue` references, `platform-apple.md` and `platform-linux.md`.

## Writing style and docs

- All writing: short sentences, plain words, specific numbers and names, no em dash, no filler.
- `scripts/banned-words.txt` is the list; never copy its terms. `scripts/check-banned-words.sh --staged` checks a staged change.
- One home per fact; others point to it by repo path and section. No drifting counts or timings; a plan is not a fact.
- Code comments say why, never what. Delete what-comments in code you touch.
- A path in a platform's docs is relative to its folder; a root doc writes it from the repository root.
- Budgets: a platform guide 16 KiB, a rule 200 lines, a `SKILL.md` 500, a skill description 1,536 characters.
- `verify.sh agent-docs` checks backticked names in the guides, `CONTRIBUTING.md`, `RELEASING.md`, `.github/pull_request_template.md` and `.claude/`. Run it when one changes. Never state a plugin count in prose.

## Commits and PRs

- The PR title is the squash commit subject; branch commits use the same format. The body follows `.github/pull_request_template.md`, whose top comment holds the format, types and scopes. The `PR title` check (`scripts/ci/check-pr-title.py`) enforces the format, not scopes.
- A user-visible change adds a fragment to its app's `changelog.d/`; only a release PR edits a `CHANGELOG.md`. Format: `.claude/rules/changelog.md`.
- A rename or signature change updates every caller and test in the same commit.

## CI

- A PR into `main` or `release/*` merges on green macOS Tests, iOS and Package Tests, SwiftLint, Repo Hygiene, PR title and Linux. Nothing bypasses them.
- Read why a CI check failed before any re-run.
- Workflows: `.claude/rules/ci.md`. Red checks: `.claude/skills/fix-issue/references/verification-apple.md` and `verification-linux.md`, Reading CI.

## Area rules

Claude Code loads a rule when it reads or edits a file the rule covers. Under Codex, before editing a file, read every rule whose row matches it. Each row is the rule's `paths:` with a trailing `/**/*` dropped; `verify.sh agent-docs` keeps them equal.

| Rule | Read before editing |
| --- | --- |
| `ai-mcp-security.md` | `apple/TablePro/Core/AI`, `apple/TablePro/Core/MCP`, `apple/Packages/TableProMacCore/Sources/TableProMCP` |
| `changelog.md` | `**/CHANGELOG.md`, `**/changelog.d`, `**/towncrier.toml` |
| `ci.md` | `.github/workflows`, `.github/actions`, `.github/actionlint.yaml`, `scripts/ci`, `apple/scripts/ci`, `scripts/release`, `apple/scripts/release`, `apple/.swiftlint.yml`, `**/.swiftlint.yml` |
| `connection-window.md` | `apple/TablePro/Core/Services/Infrastructure`, `apple/TablePro/Models/Connection`, `apple/TablePro/Core/Database/DatabaseManager*.swift`, `apple/Packages/TableProCore/Sources/TableProDatabase`, `apple/TablePro/Views/Main` |
| `data-grid.md` | `apple/TablePro/Views/Results`, `apple/TablePro/Core/DataGrid`, `apple/TableProTests/Views/Results` |
| `data-sync-storage.md` | `apple/TablePro/Core/**/*Storage*.swift`, `apple/TablePro/Core/**/*Sync*.swift`, `apple/TablePro/Core/Database`, `apple/TablePro/Core/Plugins/PluginMetadataRegistry*.swift`, `apple/TablePro/Core/Services/Query`, `apple/Packages/TableProCore/Sources/TableProSyncTransport`, `apple/CloudKit` |
| `editor.md` | `apple/Packages/TableProEditor`, `apple/TablePro/Theme`, `apple/TablePro/Views/Editor`, `apple/TablePro/Views/RowInspector` |
| `libs.md` | `apple/Libs`, `apple/scripts/download-libs.sh`, `apple/scripts/publish-libs.sh` |
| `mongodb-driver.md` | `apple/Plugins/MongoDBDriverPlugin`, `apple/Plugins/MQLExportPlugin` |
| `mysql-driver.md` | `apple/Plugins/MySQLDriverPlugin`, `apple/Packages/TableProCore/Sources/TableProMySQLCore`, `apple/TableProMobile/**/*MySQL*`, `apple/TableProMobile/**/*MariaDB*` |
| `native-bridges.md` | `apple/Native`, `apple/Plugins/DamengDriverPlugin`, `apple/Plugins/HanaDriverPlugin`, `apple/scripts/build-dameng.sh`, `apple/scripts/build-hana.sh` |
| `plugin-system.md` | `apple/Plugins`, `apple/Packages/TableProCore/Sources/TableProPluginKit`, `apple/Packages/TableProCore/Sources/TableProMySQLCore`, `apple/Packages/TableProCore/Sources/TableProPostgreSQLCore`, `apple/Packages/TableProCore/Sources/TableProRedisCore`, `apple/Packages/*/Package.swift`, `apple/project.yml`, `apple/TableProMobile/project.yml`, `apple/Configs/PluginKit.xcconfig`, `.github/plugin-registry.json`, `apple/scripts/*plugin*` |
| `redis-driver.md` | `apple/Plugins/RedisDriverPlugin`, `apple/Packages/TableProCore/Sources/TableProRedisCore` |
| `split-views.md` | `apple/TablePro/**/*Split*.swift`, `apple/TablePro/Core/Services/Infrastructure/WorkspacePane*.swift` |
| `tests.md` | `apple/TableProTests`, `apple/TableProUITests`, `apple/Plugins/*Tests`, `apple/Packages/*/Tests`, `apple/TableProMobile/TableProMobileTests`, `apple/TestPlans`, `apple/scripts/ci/check-test-plans.py`, `apple/scripts/clean-test-residue.sh` |
| `theme.md` | `apple/TablePro/Theme`, `apple/TablePro/Views`, `apple/TablePro/Core/Services/Infrastructure/*Window*`, `apple/Packages/TableProCore/Sources/TableProTheme` |
| `ui-lifecycle.md` | `apple/TablePro/Views`, `apple/TablePro/ViewModels`, `apple/TablePro/Core/Services/Infrastructure`, `apple/Packages/TableProEditor` |
| `ui-tests.md` | `apple/TableProUITests`, `apple/TestPlans/UI.xctestplan` |
| `welcome-library.md` | `apple/TablePro/Views/Welcome`, `apple/TablePro/ViewModels/WelcomeViewModel*.swift`, `apple/Packages/TableProCore/Sources/TableProConnectionLibrary` |

## Skills

`fix-issue` takes a problem to one green PR and holds `verify.sh` and its references; `release` ships a macOS version (the Linux runbook is `linux/docs/releasing.md`). Both live in `.claude/skills/`; Codex sees them through `.agents/skills/`.
