---
paths:
  - "Plugins/**/*"
  - "Packages/TableProCore/Sources/TableProPluginKit/**/*"
  - "project.yml"
  - "TableProMobile/project.yml"
  - ".github/workflows/build-plugin.yml"
  - ".github/plugin-registry.json"
  - "scripts/*plugin*"
---

# Plugins and PluginKit

TableProPluginKit is built with Library Evolution, so an already-built plugin keeps loading under a newer app. These rules keep that true:

- **Never remove or change a published requirement or public signature.** A plugin built against it references its symbols by name and fails to load ("Bundle failed to load executable") when one disappears, even a requirement that defaulted to `nil`. To add a field to a transfer struct, add a new initializer overload and mark the old one `@_disfavoredOverload`.
- **Add a requirement only with a default implementation**, then bridge it in `PluginDriverAdapter`.
- **Every ABI change bumps `currentPluginKitVersion`** (in `PluginManager.swift`) and `TableProPluginKitVersion` in every plugin `Info.plist`, at most once per release cycle: later changes in the same cycle reuse the pending number (`scripts/ci/check-pluginkit-bump-cadence.py` checks it). A breaking change also raises `minimumCompatiblePluginKitVersion` and needs every registry plugin re-released with `scripts/release-all-plugins.sh <version>` before or with the app release.
- **Run `verify.sh abi <merge-base>`** (`scripts/check-pluginkit-abi.sh`) for any change under `Plugins/TableProPluginKit/`; no CI job runs it.
- **Mark a public enum `@frozen` only when its case set is truly closed.** `PluginCapability` and the transfer structs stay non-frozen so they can grow.
- **A driver fix reaches users of a shipped app** through `scripts/release-plugin-for-shipped-app.sh <pluginTag> [appTag]`. Never relabel a binary built from `main` with an older kit version.

Building and structure:

- **The app scheme builds only the bundled plugins**; run `verify.sh plugins` (the `AllPlugins` aggregate) whenever `Plugins/` changes.
- **A new driver** needs its `project.yml` target and an entry in the `AllPlugins` list, a `DatabaseType` constant, an entry in `.github/plugin-registry.json` keyed by its tag slug, a curated snapshot in `PluginMetadataRegistry` (without it the type never appears in the New Connection picker), a row in `docs/databases/index.mdx`, and a CHANGELOG entry.
- **A `Plugins/` file that `TableProMobile/project.yml` also compiles** marks every top-level declaration `nonisolated` and depends on no plugin-only code, because the iOS target defaults to `MainActor` (`scripts/ci/check-ios-shared-isolation.py` checks it).
- **Plugin tags** are `plugin-<slug>-v<version>`, where the slug is a key in `.github/plugin-registry.json`; check `git tag -l "plugin-*"` before creating one.
