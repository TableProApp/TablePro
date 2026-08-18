---
paths:
  - "Plugins/**/*"
  - "Packages/TableProCore/Sources/TableProPluginKit/**/*"
  - "project.yml"
  - ".github/workflows/build-plugin.yml"
  - "scripts/*plugin*"
---

# Plugin changes

Read `### Plugin System` and `### DatabaseType (String-Based Struct)` in `CLAUDE.md` before editing. Binding constraints for this path:

- **The plugin domain is open.** `DatabaseType` is a string-backed struct, not an enum. Unknown types from future plugins must round-trip through Codable, and every `switch` over it keeps a `default:`.
- **Binary compatibility.** TableProPluginKit ships with Library Evolution, so adding a protocol method with a default implementation is ABI-safe. Adding a parameter to an existing public initializer is not: it replaces the symbol and breaks every shipped plugin. Add an overload instead. Run `.claude/skills/fix-issue/scripts/verify.sh abi <merge-base>` for any shared plugin API change; nothing in CI does it for you.
- **Edit the real files.** The SwiftPM target at `Packages/TableProCore/Sources/TableProPluginKit` is a symlink to `Plugins/TableProPluginKit/`. Edit the files under `Plugins/` only.
- **Bundled versus registry-only.** The app scheme depends on the bundled plugins alone, and PR CI never compiles the registry-only ones, so a hard compile error there still produces `BUILD SUCCEEDED`. Build the aggregate yourself with `verify.sh plugins`.
- **Regenerate after any target change.** `project.yml` is the source of truth and the `.xcodeproj` is generated. Never hand-edit or commit it.

A new driver also needs its `project.yml` target, its `DatabaseType` constant, a `case` arm in the `Resolve plugin info` step of `.github/workflows/build-plugin.yml` (the `case "$PLUGIN_NAME"` block that maps the tag to its target, bundle id, display name, and type ids), a row in the `docs/index.mdx` table, and a CHANGELOG entry.

This rule adds domain constraints and does not pick your workflow.
