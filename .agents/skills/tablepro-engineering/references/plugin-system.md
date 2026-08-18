# Plugin System

### Plugin System

All database drivers are `.tableplugin` bundles loaded at runtime by `PluginManager` (`Core/Plugins/`):

- **TableProPluginKit** (`Plugins/TableProPluginKit/`): shared framework with `PluginDatabaseDriver`, `DriverPlugin`, `TableProPlugin` protocols and transfer types (`PluginQueryResult`, `PluginColumnInfo`, etc.). This is the single source of truth; the SwiftPM target at `Packages/TableProCore/Sources/TableProPluginKit` is a symlink to it, so edit the files under `Plugins/TableProPluginKit/` only.
- **PluginDriverAdapter** (`Core/Plugins/PluginDriverAdapter.swift`): bridges `PluginDatabaseDriver` → `DatabaseDriver` protocol
- **DatabaseDriverFactory** (`Core/Database/DatabaseDriver.swift`): looks up plugins via `DatabaseType.pluginTypeId`
- **DatabaseManager** (`Core/Database/DatabaseManager.swift`): connection pool, lifecycle, primary interface for views/coordinators
- **ConnectionHealthMonitor**: 30s ping, auto-reconnect with exponential backoff

When adding a new driver: create a new plugin bundle under `Plugins/`, implement `DriverPlugin` + `PluginDatabaseDriver`, add the target to `project.yml`, add `DatabaseType` static constant, add case to `resolve_plugin_info()` in `.github/workflows/build-plugin.yml`, add row to `docs/index.mdx` supported databases table, and add CHANGELOG entry. See `docs/development/plugin-development.mdx` and `docs/development/plugin-registry.mdx` for details.

When adding a new method to the driver protocol: add to `PluginDatabaseDriver` (with default implementation), then update `PluginDriverAdapter` to bridge it to `DatabaseDriver`. This is an additive, ABI-safe change (see below) and needs no version bump.

**PluginKit ABI (resilient)**: TableProPluginKit is built with `BUILD_LIBRARY_FOR_DISTRIBUTION = YES` (Swift Library Evolution), so its public ABI is resilient. The Swift runtime instantiates witness tables for already-built plugins and fills any requirement the plugin did not implement from the protocol's default, so a plugin built against an older PluginKit keeps loading under a newer app.

**Additive changes are binary-compatible and need NO version bump**: adding a requirement to `DriverPlugin` / `PluginDatabaseDriver` that has a default implementation, reordering requirements, or adding a field to a non-`@frozen` transfer struct.

**Never remove a published protocol requirement, even one that defaulted to `nil`.** Library Evolution fills in requirements *added* after a plugin was built, but it cannot rescue a requirement *removed* out from under an already-built plugin. Removing one deletes both its method descriptor and its default-implementation symbol, and every shipped plugin that relied on the default hard-references both in its witness table, so it fails to load with "Bundle failed to load executable". If the app stops using a requirement, leave it in place with its default (it costs nothing). Removing it is a breaking change: bump `currentPluginKitVersion` and re-release every plugin. (#1917, and it broke MongoDB, Oracle, Cassandra, and Elasticsearch on 0.58.)

**Adding a field to a transfer struct is additive ONLY if every existing public initializer keeps its exact signature.** Adding a parameter to an existing public init or function, even with a default value, replaces its mangled symbol and breaks every already-built plugin (this shipped in 0.49.0: `PluginQueryResult` gained `columnMeta:` on its init and every registry plugin failed to load with "Bundle failed to load executable"). Add a NEW overload for the new field and keep the old signature; mark the old overload `@_disfavoredOverload` so new code resolves to the full init while old binaries keep their symbol. Before any PluginKit change run `scripts/check-pluginkit-abi.sh` (see below) and act on the result: either the diff is additive (verify no symbol disappeared) or it is breaking (bump and re-release).

**Bump `currentPluginKitVersion` (in `PluginManager.swift`) and `TableProPluginKitVersion` in every plugin `Info.plist` ONLY for a breaking change**: changing or removing an existing requirement's signature, adding a requirement without a default, adding a case to a `@frozen` enum, or changing a frozen type's layout. Mark a public enum `@frozen` only when an exhaustive switch over it forces it (the compiler flags the switch) and its case set is genuinely closed; leave the rest non-frozen so they can gain cases. `PluginCapability` stays non-frozen with `@unknown default` because it is a growing capability set, not a closed vocabulary. The driver protocols and transfer structs stay non-frozen so they can grow. The strict version gate in `validateBundleVersions` still rejects a stale plugin cleanly after a breaking bump (no `EXC_BAD_INSTRUCTION`).

**ABI check** (manual): `scripts/check-pluginkit-abi.sh [base-ref]` generates the project from `project.yml` on both sides, builds TableProPluginKit at the current tree and at the base ref with the same toolchain, then diffs their public interfaces. A base ref that predates `project.yml` cannot be compared. There is no committed baseline, so a Swift version difference between machines never produces a false diff. Run it before merging any change under `Plugins/TableProPluginKit/**`, comparing against the merge base. A reported diff is a real ABI change: additive needs no bump; breaking needs the version bump above plus `release-all-plugins.sh`. (Until Library Evolution is on the base too, the base emits no interface and the check passes as a bootstrap.)

**Post-ABI-bump checklist (mandatory, breaking bumps only)**: Bumps are now rare (only the breaking changes listed above). After one, every registry-published plugin must be rebuilt against the new ABI. Run `release-all-plugins.sh` for the new version BEFORE or WITH the app release, never after, or users on the new app hit `noCompatibleBinary` until the registry catches up. App auto-update reconciliation handles the user-facing recovery, but the registry has to carry binaries for the new PluginKit version first.

1. Commit the bump (updates `PluginManager.swift` and every bundled plugin's `Info.plist`). Bundled plugins ship with the next app release. Do not tag them.
2. Trigger the bulk re-release:
   ```bash
   ./scripts/release-all-plugins.sh <newPluginKitVersion>
   ```
   The workflow runs all registry plugins as a parallel matrix, publishes ZIPs to GitHub Releases, and updates `plugins.json` (via `.github/scripts/update-registry.py`, which appends new binaries and prunes per the `--keep-kit-versions 2` policy). No manual `plugins.json` editing.
3. Verify by installing one plugin from the registry on a build with the new PluginKit version.

**Binary retention policy**: The registry keeps binaries for the two most recent PluginKit versions per plugin (`--keep-kit-versions 2`). Users on the previous app version can still install plugins; users two or more versions behind hit `noCompatibleBinary` and need to update the app.


- Use `DatabaseType.allKnownTypes` (not `allCases`) for the canonical list
