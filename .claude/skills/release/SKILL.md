---
name: release
description: >
  Prepares and ships a new TablePro release — bumps version numbers in
  project.pbxproj, finalizes CHANGELOG.md, commits, tags, and pushes.
  Also handles separate plugin releases (Redis, Oracle, ClickHouse,
  DuckDB). Use this skill whenever the user says "release", "bump
  version", "ship version", "tag a release", "cut a release", or
  provides a version number they want to release (e.g., "/release 0.5.0",
  "/release plugin-oracle 1.0.0").
---

# Release Version

Automate the full release pipeline for TablePro. Supports two modes:

- **App release**: `/release <version>` — bumps versions, finalizes
  changelog, commits, tags, and pushes.
- **Plugin release**: `/release plugin-<name> <version>` — tags and
  pushes a separate plugin bundle release.

## Usage

```
/release <version>              # App release (e.g., /release 0.5.0)
/release plugin-<name> <version> # Plugin release (e.g., /release plugin-oracle 1.0.0)
```

## Pre-flight Checks

Before making any changes, verify ALL of the following. If any check
fails, stop and tell the user what's wrong.

1. **Version argument exists** — the user must provide a semver version
   (e.g., `0.5.0`). If missing, ask for it.

2. **Version is valid semver** — must match `X.Y.Z` where X, Y, Z are
   non-negative integers. Pre-release suffixes like `-beta.1` or `-rc.1`
   are allowed.

3. **Version is newer** — compare against the current `MARKETING_VERSION`
   in `project.pbxproj`. The new version must be greater. Read the
   current value:
   ```
   Grep for "MARKETING_VERSION" in TablePro.xcodeproj/project.pbxproj
   ```

4. **Tag doesn't exist** — run `git tag -l "v<version>"` to confirm the
   tag is available.

5. **Working tree is clean** — run `git status --porcelain`. If there are
   uncommitted changes, warn the user and ask whether to proceed (the
   release commit will include those changes).

6. **Unreleased section has content** — read `CHANGELOG.md` and verify
   the `## [Unreleased]` section has entries. If empty, warn the user
   that the release will have no changelog entries.

7. **On main branch** — run `git branch --show-current`. Warn (but don't
   block) if not on `main`.

8. **SwiftLint passes** — run `swiftlint lint --strict`. If there are
   any warnings or errors, spawn a Task subagent to fix all issues
   before continuing with the release. The subagent should run
   `swiftlint --fix` first, then manually fix any remaining issues,
   and verify with `swiftlint lint --strict` until clean.

## Release Steps

### Step 1: Bump Version in project.pbxproj

File: `TablePro.xcodeproj/project.pbxproj`

Update the **main app target only** (Debug + Release configs = 2 lines
each):

- Set `MARKETING_VERSION` to the new version (e.g., `0.5.0`)
- Increment `CURRENT_PROJECT_VERSION` by 1 from its current value

**Do NOT touch** any other target's version lines. The pbxproj contains
many targets beyond the main app — all with `MARKETING_VERSION = 1.0`
and `CURRENT_PROJECT_VERSION = 1`:

- **Test target** (TableProTests)
- **TableProPluginKit** framework
- **Bundled plugins** (included in app bundle): MySQLDriverPlugin,
  PostgreSQLDriverPlugin, SQLiteDriverPlugin, plus export plugins
  (CSV, JSON, SQL export)
- **Separate plugin bundles** (not included in app bundle, distributed
  independently): OracleDriverPlugin, ClickHouseDriverPlugin,
  DuckDBDriverPlugin, MSSQLDriverPlugin, MongoDBDriverPlugin,
  RedisDriverPlugin, XLSXExportPlugin, MQLExportPlugin, SQLImportPlugin

Use `replace_all: true` for each edit — the main app target's version
values are always unique (e.g., `MARKETING_VERSION = 0.16.1` and
`CURRENT_PROJECT_VERSION = 30`), distinct from the `1.0` / `1` used by
all other targets, so `replace_all` safely targets only the correct
occurrences.

### Step 2: Finalize CHANGELOG.md

Make these edits to `CHANGELOG.md`:

1. **Convert Unreleased to versioned heading** — replace:
   ```
   ## [Unreleased]
   ```
   with:
   ```
   ## [Unreleased]

   ## [<version>] - <YYYY-MM-DD>
   ```
   where `<YYYY-MM-DD>` is today's date.

2. **Update footer links** — at the bottom of the file:

   Replace the `[Unreleased]` compare link:
   ```
   [Unreleased]: https://github.com/datlechin/tablepro/compare/v<old-version>...HEAD
   ```
   with:
   ```
   [Unreleased]: https://github.com/datlechin/tablepro/compare/v<version>...HEAD
   [<version>]: https://github.com/datlechin/tablepro/compare/v<old-version>...v<version>
   ```

   `<old-version>` is the previous release version (the one currently in
   the `[Unreleased]` compare link).

### Step 3: Commit (main repo)

Stage the changed files and commit:

```bash
git add TablePro.xcodeproj/project.pbxproj CHANGELOG.md docs/changelog.mdx docs/vi/changelog.mdx
git commit -m "$(cat <<'EOF'
release: v<version>
EOF
)"
```

If there were other staged/unstaged changes from the pre-flight check
that the user agreed to include, stage those too.

### Step 4: Tag

```bash
git tag v<version>
```

### Step 5: Push

Push the commit and the tag **separately** — `--follow-tags` only pushes
annotated tags, but `git tag` creates lightweight tags:

```bash
git push origin main && git push origin v<version>
```

This triggers the CI/CD pipeline (`.github/workflows/build.yml`) which
automatically:
- Builds arm64 and x86_64 binaries
- Creates DMG and ZIP artifacts
- Signs with Sparkle EdDSA
- Generates and commits `appcast.xml`
- Creates the GitHub Release with release notes extracted from CHANGELOG.md

### Step 6: Update Documentation Changelogs

The documentation lives in the main repo under `docs/`. Two changelog
files need a new `<Update>` entry:

- `docs/changelog.mdx` (English)
- `docs/vi/changelog.mdx` (Vietnamese)

**How to write the entry:**

1. Read the new version's section from `CHANGELOG.md` (the entries you
   finalized in Step 2).
2. Rewrite them as a user-friendly `<Update>` block — group entries
   under `### New Features`, `### Improvements`, `### Bug Fixes`, etc.
   (not the raw Added/Changed/Fixed/Removed from Keep a Changelog).
3. Write concise, user-facing descriptions (not developer-internal
   details). Skip purely internal refactors unless they have visible
   impact.

**English format** (`docs/changelog.mdx`):

```mdx
<Update label="<Month Day, Year>" description="v<version>">
  ### New Features

  - **Feature Name**: Description

  ### Improvements

  - Description

  ### Bug Fixes

  - Description
</Update>
```

Insert the new `<Update>` block at the top of the file, right after the
frontmatter `---` closing delimiter (before the first existing `<Update>`).

**Vietnamese format** (`docs/vi/changelog.mdx`):

Same structure but with Vietnamese text. Use the date format
`<Day> tháng <Month>, <Year>` (e.g., `19 tháng 2, 2026`). Translate
feature names and descriptions to Vietnamese. Follow the style of
existing Vietnamese entries in the file.

**Important:** These changelog files are staged and committed together
with the release in Step 3 — no separate commit needed.

### Step 7: Check for Separate Plugin Changes

After the app release is pushed, check if any **separate plugin bundles**
(Oracle, ClickHouse, DuckDB, MSSQL, MongoDB, Redis, XLSX, MQL,
SQLImport) have changes since their last
release. Also check `Plugins/TableProPluginKit/` — changes there affect
all plugins.

**Detection**: For each separate plugin, find its latest tag and check
for commits:

```bash
# Separate plugins and their directory + tag-name mappings:
#   Oracle:     Plugins/OracleDriverPlugin/     plugin-oracle
#   ClickHouse: Plugins/ClickHouseDriverPlugin/  plugin-clickhouse
#   DuckDB:     Plugins/DuckDBDriverPlugin/      plugin-duckdb
#   MSSQL:      Plugins/MSSQLDriverPlugin/       plugin-mssql
#   MongoDB:    Plugins/MongoDBDriverPlugin/     plugin-mongodb
#   Redis:      Plugins/RedisDriverPlugin/       plugin-redis
#   XLSX:       Plugins/XLSXExportPlugin/        plugin-xlsx
#   MQL:        Plugins/MQLExportPlugin/         plugin-mql
#   SQLImport:  Plugins/SQLImportPlugin/         plugin-sqlimport

# For each plugin, find the latest tag:
LAST_TAG=$(git tag -l "plugin-<name>-v*" --sort=-version:refname | head -1)

# Check for changes since that tag (include PluginKit as shared dependency):
git log --oneline "$LAST_TAG"..HEAD -- Plugins/<PluginDir>/ Plugins/TableProPluginKit/
```

If `LAST_TAG` is empty (never released), check for changes since the
beginning of the repo.

**If changes are found**: Tell the user which plugins have changes, show
the relevant commits, and ask if they want to release them. Suggest
bumping the patch version from the last tag (e.g., `1.0.0` → `1.0.1`).
If the user confirms, proceed with the plugin release steps below for
each plugin.

**If no changes**: Skip — do not release plugins unnecessarily.

## Post-release Summary

After all pushes, print a summary:

```
Release v<version> (build <build-number>) pushed successfully.

CI will now build arm64 + x86_64, create DMG/ZIP, update appcast.xml, create GitHub Release.
Monitor: https://github.com/datlechin/TablePro/actions
Release: https://github.com/datlechin/TablePro/releases/tag/v<version>
```

If plugin releases were also triggered, append:

```
Plugin releases:
- <DisplayName> v<plugin-version>: https://github.com/datlechin/TablePro/releases/tag/plugin-<name>-v<plugin-version>
```

---

## Plugin Releases

Separate plugin bundles (Oracle, ClickHouse, DuckDB, MSSQL, MongoDB,
Redis, XLSX, MQL, SQLImport) are released independently from the main
app via a dedicated workflow
(`.github/workflows/build-plugin.yml`). They are also checked
automatically during app releases (Step 7 above).

### Usage

```
/release plugin-<name> <version>
```

Example: `/release plugin-oracle 1.0.0`

### Tag Format

```
plugin-<name>-v<version>
```

Examples: `plugin-oracle-v1.0.0`, `plugin-clickhouse-v1.2.0`

The `<name>` must match one of the cases in the workflow's mapping:
`oracle`, `clickhouse`, `duckdb`, `cassandra`, `mssql`, `mongodb`,
`redis`, `xlsx`, `mql`, `sqlimport`.

### Plugin Release Steps

1. **Verify tag is available** — `git tag -l "plugin-<name>-v<version>"`
2. **Tag** — `git tag plugin-<name>-v<version>`
3. **Push tag** — `git push origin plugin-<name>-v<version>`

No version bumps or changelog edits needed — plugin bundles keep
`MARKETING_VERSION = 1.0` and `CURRENT_PROJECT_VERSION = 1` in pbxproj.
The version is embedded via the tag only.

### What CI Does

The `build-plugin.yml` workflow:

1. Extracts plugin name and version from the tag
2. Builds ARM64 and x86_64 via `scripts/build-plugin.sh`
3. Strips binaries, code signs, creates ZIPs with SHA-256 checksums
4. Optionally notarizes (if `NOTARIZE_PLUGINS` var is set)
5. Creates a GitHub Release with both arch ZIPs
6. Updates the plugin registry (`datlechin/tablepro-plugins` repo's
   `plugins.json`) with download URLs, SHA-256 hashes, and
   `minAppVersion` (read from the current `MARKETING_VERSION`)

### Post-plugin-release Summary

```
Plugin <DisplayName> v<version> tag pushed.

CI will build arm64 + x86_64, create ZIPs, update plugin registry.
Monitor: https://github.com/datlechin/TablePro/actions
Release: https://github.com/datlechin/TablePro/releases/tag/plugin-<name>-v<version>
```
