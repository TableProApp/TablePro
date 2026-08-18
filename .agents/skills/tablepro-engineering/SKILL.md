---
name: tablepro-engineering
description: End-to-end engineering workflow for the TablePro macOS and iOS repository. Use for any TablePro feature, refactor, test, build, plugin, driver, AI, MCP, sync, storage, UI, or documentation task that reads or changes repository files. It routes to the project invariant that governs the subsystem, coordinates independent investigation, enforces one-writer ownership, and requires build, test, lint, and review evidence.
---

# TablePro Engineering

`AGENTS.md` is the workflow: scope, principles, work sequence, code rules, verification, and the
change contract all live there and are not repeated here. This file does one thing AGENTS.md
cannot: it routes you to the specific knowledge a subsystem needs, and it holds the few practices
that differ from the general rule.

In Claude Code, a GitHub issue goes to `$fix-issue` instead of here. Do not load both.

## Route to the invariant that governs your change

The project reference is split by domain. Find the rule by symptom or symbol, not by reading a file:

```bash
rg -n '^####' .agents/skills/tablepro-engineering/references/invariants-*.md
rg -n '<symbol>|<subsystem>|<issue>' .agents/skills/tablepro-engineering/references/
```

| Working on | Read |
| --- | --- |
| Views, coordinators, windows, tabs, split panes, the data grid | `references/invariants-ui.md` |
| Connect and cancel, schema loading, caches, session state, pooling | `references/invariants-connections.md` |
| CloudKit sync, stored records, driver read and write paths | `references/invariants-data.md` |
| `Plugins/` or `TableProPluginKit` | `references/plugin-system.md` |
| Adding a file or target, orienting in a subsystem | `references/architecture.md` |
| `Libs/`, CI failures, shipping | `references/build-and-release.md` |
| Commit scopes, docs routing, lint limits, performance pitfalls | `references/conventions.md` |
| AI or MCP | `TablePro/Core/AI`, `TablePro/Core/MCP`, the tool policy, token scopes, connection allowlists, `docs/external-api/` |
| A driver or dialect | the driver invariant, the vendored header, the build script, and the sibling driver that already works |

Read the full paragraph of a matching invariant. Each exists because it was violated and shipped a
bug. If one names a symbol that no longer exists, correct it in the same change rather than working
around it.

Verification, quarantine lists, and environment traps: `.claude/skills/fix-issue/references/verification.md`.
Platform, SDK, and HIG sources: `.claude/skills/fix-issue/references/research-sources.md`.

## Delegating investigation

Give every lane the same problem statement and one narrow question. Require confirmed facts,
inferences, and unknowns to be labeled separately. Ask for the smallest answer that supports a
decision, anchored to `file:line`, and verify at those anchors rather than re-reading whole files.

Beyond the default lenses in AGENTS.md, add a UI and HIG specialist when the change is user-facing:
native behavior, focus, the responder chain, and accessibility are decided by the HIG and by this
app's existing interaction language, not by what is easiest to build.

## Where this differs from the general rule

- **Run the smallest relevant test suite before the app build**, not after. A wedged XCTest host or
  a stale generated project shows up in seconds there and costs a full build cycle later.
- **Fix the source when a test fails.** Never adjust a test to match incorrect output.
- **No compatibility shims and no temporary workarounds left in place.** If the shape cannot express
  the behavior, change the shape.
- **Every verification step goes through the wrapper**, `.claude/skills/fix-issue/scripts/verify.sh`,
  which stores the log and prints a verdict. A raw `xcodebuild` failure returns a truncated excerpt
  with no log to read back, which is the one case where the whole output matters.
