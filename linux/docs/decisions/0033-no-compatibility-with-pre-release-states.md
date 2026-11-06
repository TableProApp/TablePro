# 0033: No compatibility with pre-release states

- **Status**: Accepted
- **Date**: 2026-11-05

## Context

No `linux-v*` or `windows-v*` tag has shipped, yet the Linux app and the core stores it shares with the Windows app carried what earlier builds wrote: the connection list at version 3 with upgrades from 1 and 2, the workspace at 2, the open sessions at 3, the column widths at 2, three query-history migrations with a backfill, a reader of a CA file saved with Require, the removal of a tab file an older build left, and recovery of group and tag names those builds accepted. Every one of them existed for a developer's own data, and each new format change had to keep it working.

## Decision

Nothing reads or upgrades what a build before the first release wrote: every app-owned format starts at version 1 with no upgrade step, and the history schema is one migration.

## Rationale

- **No user has that data.** The only files in the old shapes are on the machines of people who built from source, and they can start over.
- **Less to carry.** Each step, fixture and fallback is code every later format change has to keep passing.
- **The mechanism stays.** `VersionedDocument` and its `UPGRADES`, the sqlx migrator and the refusal of a newer file are what the first change after a release uses.

## Consequences

- A file or database from a pre-release build reads as one from a newer build: the connection list and a workspace wait for Reset, the open sessions record moves aside, and the query history reports it cannot open until `history.db` is deleted.
- Column layouts move to `column_layouts.json`; the old `column_widths.json` is left as it is.
- The first release's formats are version 1, and their golden fixtures are `connections-v1.json` and `workspace-v1.json`. From then on, `docs/storage.md`, Changing a format, applies.
- What the macOS app reaches stays: the CloudKit mapping, and the escape a macOS group name of invisible characters reads as.
- Supersedes the version 2 upgrade in [core 0006](../../../core/docs/decisions/0006-connection-library.md) and, in [0022](0022-ai-assistant-and-mcp-server.md), the level of a connection saved before the External Clients level existed.
