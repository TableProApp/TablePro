---
paths:
  - "Plugins/**/*"
  - "Packages/TableProCore/Sources/TableProPluginKit/**/*"
  - "Packages/TableProCore/Sources/TableProMySQLCore/**/*"
  - "Packages/TableProCore/Sources/TableProPostgreSQLCore/**/*"
  - "Packages/TableProCore/Sources/TableProRedisCore/**/*"
  - "Packages/*/Package.swift"
  - "project.yml"
  - "TableProMobile/project.yml"
  - "Configs/PluginKit.xcconfig"
  - ".github/plugin-registry.json"
  - "scripts/*plugin*"
---

# Plugins and PluginKit

TableProPluginKit is built with Library Evolution, so an already-built plugin keeps loading under a newer app.

## ABI

- Never remove or change a published requirement or public signature. A plugin references its symbols by name and fails to load ("Bundle failed to load executable") when one disappears, even a requirement that defaulted to `nil`.
- To add a field to a transfer struct, add an initializer overload and mark the old one `@_disfavoredOverload`.
- Add a requirement only with a default implementation, then bridge it in `PluginDriverAdapter`.
- Additive: a new requirement with a default, a new field on a non-`@frozen` struct, a new case on a non-`@frozen` enum, a reordering.
- Breaking: a changed, removed or renamed requirement or signature, a requirement without a default, a new case on a `@frozen` enum, a change to a frozen type's layout.
- Every ABI change bumps `TABLEPRO_PLUGINKIT_VERSION` in `Configs/PluginKit.xcconfig`, at most one past the newest `vX.Y.Z` tag: later changes reuse the pending number. `scripts/ci/check-pluginkit-bump-cadence.py` checks it in Repo Hygiene. A `release/*` line never bumps it.
- The build stamps that value into `TableProPluginKitVersion` of the app and of every plugin. A plugin's `Info.plist` holds `<integer>TABLEPRO_PLUGINKIT_VERSION</integer>` and is preprocessed, because every shipped app reads the key with `as? Int`; the source file therefore fails `plutil -lint`.
- After an additive change, built plugins keep loading, and the bump makes an older app refuse a plugin rebuilt against the new API instead of failing its load.
- A breaking change also raises `TABLEPRO_PLUGINKIT_MINIMUM_VERSION`. Every tag ships every registry plugin built against its own kit, so the release that carries the change carries plugins in its range.
- Check with `verify.sh abi <merge-base>` (`scripts/check-pluginkit-abi.sh`). It builds PluginKit at HEAD and at the base with the same toolchain and diffs the public `.swiftinterface`. A base with no interface passes; a diff prints the additive and breaking rules and exits 1.
- It refuses uncommitted changes, so run it after the commit and before the push. No workflow runs it.
- The diff is textual, so a `-` line can be a declaration that moved. Only a removed line with no matching added line, or a requirement added without a default, is breaking. This lists the removed lines that do not come back:

  ```bash
  L=<the log verify.sh abi printed>
  comm -23 <(grep -E '^-[^-]' "$L" | sed 's/^-[[:space:]]*//' | sort -u) \
           <(grep -E '^\+[^+]' "$L" | sed 's/^+[[:space:]]*//' | sort -u)
  ```

- Mark a public enum `@frozen` only when its case set is closed. `PluginCapability` and the transfer structs stay non-frozen so they can grow.
- PluginKit code with no callers stays: removing it is an ABI change.

## One PluginKit per process

- R1 (the rule is in `AGENTS.md`, Invariants that apply everywhere): a plugin that linked a package product depending on the `TableProPluginKit` package would carry its own copy of PluginKit's types, and the host's casts across that boundary fail. Products a plugin and the iOS app share stay PluginKit-free for that reason.
- The R1 check runs per binary (each plugin, each plugin test bundle, the app) and must print nothing:

  ```bash
  nm -m "$BIN" | grep -v undefined | grep -E '_\$s17TableProPluginKit[0-9A-Za-z_]*Mn$' \
    | awk '{print $NF}' | xcrun swift-demangle \
    | awk '!/\(extension in / || /\(extension in TableProPluginKit\)/'
  ```

- Without the demangle filter, `TablePro.debug.dylib` prints one false positive: an extension the app declares on a PluginKit type. `TableProPluginKit.framework` itself prints many lines, which makes it the positive control.
- R2: `<DerivedData>/Build/Products/Debug/TableProPluginKit.swiftmodule` must not exist. The only PluginKit module is inside `TableProPluginKit.framework`.
- No CI check runs R1 or R2. Run both after changing a package manifest, a package dependency or a plugin's linkage.
- A bundled plugin and its test bundle share one linkage template in `project.yml`, so they never link differently.

## Building

- The `TablePro` scheme builds only the bundled plugins, and a registry plugin's compile error still ends in `BUILD SUCCEEDED`. Run `verify.sh plugins` (the `AllPlugins` aggregate) after any change under `Plugins/`.
- `scripts/ci/verify-plugin-loads.sh <dir>...` dlopens every built `.tableplugin` and names any that will not load. It does not instantiate the principal class.

## Structure

- PluginKit-free logic a plugin shares with the iOS app lives in a TableProCore product, such as `TableProMySQLCore`, `TableProPostgreSQLCore` or `TableProRedisCore`.
- A new driver needs: its `project.yml` target and a `RegistryPlugins` entry (`BundledPlugins` and the app's `copy: { destination: plugins }` dependency for a bundled one), a `DatabaseType` constant, for a registry one an entry in `.github/plugin-registry.json` keyed by its target, with `name` (a bundled one stays out of it), a curated snapshot in `PluginMetadataRegistry` (without it the type never appears in the New Connection picker), its `TableProProvides*` keys (below), a row in `../tablepro-docs/databases/index.mdx` through a paired docs PR, and a changelog fragment.
- A new engine ships as a registry plugin (`AGENTS.md`, Scope).
- `PluginManager` registers a plugin from the `TableProProvidesDatabaseTypeIds`, `TableProProvidesExportFormatIds` and `TableProProvidesImportFormatIds` arrays in its `Info.plist` and loads its code on first use. A plugin with none of them loads at launch. The first database type id is the primary one.
- `scripts/ci/check-plugin-provides.py` checks those arrays against the class's `databaseTypeId`, `additionalDatabaseTypeIds` and `formatId` in Repo Hygiene; `--write` stamps them.
- Where a plugin's tests go, and how a test target is added in `project.yml`: `.claude/rules/tests.md`, Where a test goes and Adding a test target.

## Releases

- Registry plugins have no tags of their own: each app tag builds and publishes all of them at the app's version (`RELEASING.md`, Plugins).
- A driver fix reaches stable users through a patch on `release/<X.Y>`.
