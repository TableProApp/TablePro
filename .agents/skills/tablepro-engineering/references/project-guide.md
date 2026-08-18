# TablePro Project Reference

This file is an index. The knowledge lives in the files below, split so a task opens one of them
instead of all of it. `AGENTS.md` owns the principles, the code rules, the work sequence, and the
change contract, and none of them are repeated here.

| File | What is in it | Open it when |
| --- | --- | --- |
| `invariants-ui.md` | Windows, tabs, split panes, the data grid, app lifecycle | Editing anything under `TablePro/Views/`, a coordinator, a window, or a split view |
| `invariants-connections.md` | Connect and cancel, schema loading, caches, session state, pooling | Touching connection lifecycle, schema refresh, or the sidebar tree |
| `invariants-data.md` | CloudKit sync ordering, MongoDB writes, driver data handling | Touching sync, stored records, or driver read and write paths |
| `plugin-system.md` | Plugin layout, `DatabaseType`, PluginKit ABI rules, registry versus bundled | Any change under `Plugins/` or `TableProPluginKit` |
| `architecture.md` | Project layout and generation, editor bridge, window close, storage map | Orienting in a subsystem, or adding a file or target |
| `build-and-release.md` | Commands beyond the wrapper, static libraries, the CI job graph | Updating `Libs/`, reading a CI failure, or shipping |
| `conventions.md` | Logging, lint limits, commit scopes, docs routing, performance pitfalls, writing style extras | Before a commit, or when naming a scope or a docs page |

Each invariant carries its own `####` heading naming the subsystem and the failure it prevents, so
search for the symptom or the symbol rather than reading a whole file:

```bash
rg -n '^####' .agents/skills/tablepro-engineering/references/invariants-*.md
rg -n '<symbol>|<subsystem>|<issue>' .agents/skills/tablepro-engineering/references/
```

Read the full paragraph of a matching invariant, not the heading alone. Each one exists because it
was violated and shipped a bug.

## What is not here

- Build, test, and lint verification, the quarantine lists, and the environment traps:
  `.claude/skills/fix-issue/references/verification.md`.
- Release and tagging: `$release`.
- SwiftUI and AppKit view rules: `$swiftui`.
- Lint numbers, formatter settings, and plugin tag names are read from `.swiftlint.yml`,
  `.swiftformat`, and `.github/workflows/build-plugin.yml`. Those files are authoritative; a copy
  here would drift.

## Keeping it honest

An invariant that names a symbol which no longer exists is worse than no invariant, because it is
followed confidently. Five such drifts were found and fixed in this reference. When you touch a
subsystem, check the invariant that governs it still matches the code, and correct it in the same
change.
