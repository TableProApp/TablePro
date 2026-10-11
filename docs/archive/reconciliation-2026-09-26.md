# Linux local/remote reconciliation — 2026-09-26

## Preserved inputs

- Remote: `fork/linux` in `cozyGarage/BookiE`, fetched at `8ae99ad66`.
- Local base: `d5583c75e0bcf44833e112614aae10e8f3495816`.
- Complete local working-tree snapshot: `47c4dd5d4` on
  `preserve/local-b2-b3-20260926`, including the previously untracked schema.
- Integration branch: `integrate/linux-20260926`, based on the remote tip.
  No force push, reset, remote rewrite, or deletion of ignored artifacts.

The remote contributes 53 commits since the local base. Preserve its history and
apply only the valuable local delta. The snapshot retains the original local
implementation, tests and evidence even where the integrated version supersedes it.

## Decisions

| Area | Decision and reason |
| --- | --- |
| Remote product work | Keep dedicated PostgreSQL/MySQL/SQLite/SQL Server sessions, guarded transaction lifecycle, built-in SSH agent and system OpenSSH transports, askpass, catalog/privileges, editor file relinking, timeouts and completion notifications. These are additive to the local work. |
| Remote correctness fixes | Keep SQL Server batch draining, SQLite catalog/FK fixes, PostgreSQL index metadata, collation/default/MariaDB handling, full-value editing/duplication and keyed-row regressions. Local binder/export fixes cover different loss paths. |
| GSettings contract | Keep remote schema IDs `com.tablepro.linux` and `com.tablepro.linux.Devel`, fixed stable/development paths, window geometry keys, legacy migration marker and rollback JSON import. Add the local version guard, read-back verification, malformed-source edit refusal, error propagation, mirror rollback and explicit flush. Use remote backup naming. |
| GSettings builds | Keep the single remote schema in `data/`, remote Meson/Arch/Debian/Flatpak install steps and askpass packaging. Point local Cargo schema compilation at that same file. Remove the duplicate local `data/schemas/` schema and redundant installers. Retain Debian schema validation. |
| History | Keep remote locking and private `VACUUM INTO` pre-migration snapshots. Retain local transactional-failure and older-client compatibility tests; they test distinct guarantees. |
| MCP | Keep remote catalog tool additions and local owned HTTP server, operation cancellation and graceful shutdown. Extract the HTTP router to satisfy the function-size guard without raising its baseline. |
| SQL export and writes | Keep local rejection of undecodable parameters in five SQL binders and rollback of failed batches. Keep INSERT export refusal for unsupported binary/undecodable/non-finite values, atomic destination preservation and Copy as IN skipping. This addresses the remote audit's binary export loss by refusing the operation; binary SQL serialization remains unimplemented. |
| Decoding and CSV | Keep local SQLite decode-failure distinction, Redis/DuckDB invalid-UTF-8 byte preservation and maximum-length duplicate CSV header fix. |
| Plans/evidence | Keep the remote sprint ledger and add this reconciliation checkpoint. Original local history remains in the preservation commit. Earlier test results prove their respective inputs, not this combined tree. B2 is implemented; B1 and B3–B7 remain open as listed in the sprint. |

## Integration finding

The retained remote migration regression failed on the first combined run: a
fresh GSettings handle saw migration version 0 instead of 1. The local backend
used delayed writes but omitted `apply()` after setting the migration markers.
The combined implementation applies those writes before syncing. This is why
both the remote rollback regression and local failure cases are retained.

## Verification

- `cargo check -p tablepro-app`: passed.
- `python3 scripts/check-function-size.py` and `git diff --check`: passed.
- Preferences regressions: 12 passed after the marker fix.
- Full fast gate: passed. Report:
  `target/quality/20260926T131153752414Z-full/report.json` (formatting, Clippy,
  workspace unit tests, sandbox integration including 17 SQLite tests).
- Isolated GTK: all 4 passed, including the remote long-cell edit regression.
  Report: `target/quality/20260926T131529265178Z-widgets/report.json`.
- Container integration: passed (PostgreSQL 23, Unix socket driver/agent 2,
  MySQL/MariaDB 17, SQL Server 19, ClickHouse 14, Redis 1). Report:
  `target/quality/20260926T131545539586Z-integration/report.json`.

Debian package fixture skipped because `dpkg-deb` is unavailable. The Arch
candidate fixture passed but is not an installed-package check. Optional DuckDB,
MongoDB containers, SSH containers, TLS/keyring/release tiers, real packaging,
Wayland install/upgrade/rollback and soak are not verified by these runs.

## Recovery

Inspect any original local file with
`git show preserve/local-b2-b3-20260926:path/to/file`, or compare the complete
original patch with `git diff d5583c75e preserve/local-b2-b3-20260926`.
The remote input remains an ancestor of the integration branch; its commits are
not cherry-picked, rewritten or discarded.
