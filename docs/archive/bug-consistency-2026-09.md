# Bug and consistency stabilization

Reviewed starting commit: `89979e51a3d70b52c2a4082d0fa44ac72528c8ea` on `linux`. Implementation and verification: 2026-09-08–09. This is a code baseline review, not package release approval. The active sprint owns current scope; this audit's feature deferrals applied to its 2026-09 review baseline.

## Baseline choice

Verified implementation commit: `f8a0ba7055dfe609308aa5326fb10c82982c70b9`. The following documentation commit only records its evidence.

Retain the current Linux implementation with the focused corrections below. No reproduction justified rolling the branch back or replacing its architecture. In particular, retain the earlier browse planner/session identity fixes, PostgreSQL streaming decoder, wide numeric decoding, and bundled DuckDB extensions. Existing tests alone did not establish correctness: new tests reproduced data-loss and restoration defects on the starting implementation.

The starting commit's [Build Linux run](https://github.com/cozyGarage/TablePro/actions/runs/34272811689) passed preflight, GTK fast checks, installed GTK smoke, driver integration, driver TLS, PostgreSQL release, and supply-chain checks. Optional DuckDB failed at `git rev-parse HEAD` with dubious repository ownership, before compilation. [Flatpak built successfully](https://github.com/cozyGarage/TablePro/actions/runs/34272811661). These hosted results apply only to the starting commit; the corrected workflow needs a new hosted run.

The [validation manifest](../evidence/2026-09-bug-consistency/validation.json) records commands, results, local log hashes, and the exact implementation/test source hashes. Tests were run during this session, not inferred from the old audit. Temporary logs are local evidence, not permanent hosted artifacts.

## Confirmed defects and resolutions

| ID / priority | Reproduction and effect | Resolution and regression |
|---|---|---|
| B1 / P1 | SQLite declared INTEGER, REAL, BOOLEAN, DATE, TIME, DATETIME and BLOB columns decode NULL as zero, false or empty values. The new GTK JSON fixture first exposed NULL blobs becoming empty blobs. | Check the raw value for NULL before declared-type decoding. Real SQLite tests assert all seven NULL types and distinguish NULL, empty and nonempty blobs through ordinary and controlled parameterized queries. |
| B2 / P1 | A BLOB stored in a REAL-affinity column falls back to hexadecimal **text**, losing its value type. | Reuse the runtime-type decoder for fallback. A real SQLite regression preserves `00ff41` as bytes despite the declared REAL type. The existing text-affinity mismatch test still passes. |
| B3 / P1 | JSON page export replaces binary contents with a `<N bytes>` label. | Encode bytes as `\x`-prefixed lowercase hexadecimal, matching CSV and MCP. Pure regression fails on the old renderer; GTK asserts the exact first 100 objects from 150 rows, including NULL, empty blobs, Unicode and escaped text. |
| B4 / P1 | Overlapping exports share `<destination>.tablepro-part`; one writer renames the other's staging file. A pre-existing symlink at that path redirects writes into an unrelated file. | Use exclusive, unique, private sibling temporary files with cleanup on failure. Deterministically interleaved writers and symlink tests both fail before the fix. Also assert preservation of an existing destination after failure and same-filesystem staging. |
| B5 / P2 | Removing an unknown persisted tab leaves `active_idx` pointing to another editor. | Remap the selected tab's original index among retained records, falling back to the first tab if the selection was removed or truncated. Two regressions fail before the fix. Persisted formats are unchanged. |
| B6 / P2 | The daemon session wrapper uses default controlled index/foreign-key methods, bypassing the underlying driver's controlled overrides. | Forward both controlled metadata methods with the original target and control. Regression proves dispatch forwarding, error preservation and pre-dispatch cancellation; it fails on the old wrapper. |
| B7 / CI | Optional DuckDB's container rejects repository ownership before testing. | Trust only `$GITHUB_WORKSPACE` in that container. A local Git test with `GIT_TEST_ASSUME_DIFFERENT_OWNER=1` reproduces refusal and verifies the exact-workspace fix without altering the user's Git configuration. Hosted confirmation remains pending. |
| B8 / tests | The local integration script omits Redis although hosted CI includes it. GTK re-execution fails when invoked as `bash linux/scripts/test-gtk-safety.sh` from the repository root. Secret Service tests use the caller's desktop bus and assume the workspace cwd. | Add Redis locally; use absolute self-paths for GTK; resolve the Secret Service workspace and always create a private keyring bus. All fixture paths were executed after correction. |
| B9 / tests | Mutation CI reads reports from `mutants-core/` although cargo-mutants writes `mutants-core/mutants.out/`; missing reports appear as zeros and command errors are suppressed. | Read actual report paths, expose step outcomes, separate unviable mutations and report unavailable evidence explicitly. Measurement remains advisory through `continue-on-error`. Execute the summary against actual reports and a missing-report case. |

## Review coverage

- **Data and transactions:** reviewed SQLite decode/fallback and GUI/MCP/CSV conversion seams; exercised driver integrations and PostgreSQL rollback, bound parameters and structure-batch isolation. Existing wide MySQL/SQL Server numeric fixes remain in place. Driver limits are intentional unless contradicted by a reproduction.
- **Sessions and async delivery:** reviewed daemon wrapper methods and cache keys, browse page/count planning, and workspace save/restore selection. Existing service tests exercise request generations and connection identity; GTK exercises successful/failed switches, cancellation before switching, two windows, pending edits and debounce persistence.
- **Policy and audit:** ran the full policy/MCP/daemon tests and PostgreSQL guarded-operation fixture. Targeted mutation of policy rules exposed missing assertions for denial metadata, inclusive blast-radius limits and categorical human approval; those assertions are now explicit. No production policy relaxation was made.
- **Persistence:** existing atomic-save, concurrent-process and malformed-state tests remain in the fast/sandbox tiers. The new GTK process-restart case gracefully quits immediately after editing, restores connection B and the active editor without executing it, explicitly runs the restored statement only against B, and reopens the saved browse tab. It is not a crash-recovery or multi-window restoration claim.
- **UI consistency:** preserve native layouts; correct exported values and tab selection. Defaults, capability restrictions and intentional per-principal policy differences remain. The GTK harness retains diagnostics on failures.

## Test quality findings

Targeted cargo-mutants 27.1.0 runs used scratch copies, never in-place mutation:

- Export atomic-write logic: initially one of two mutations survived. It changed staging-directory selection. A new assertion pins staging to the destination directory; both mutations are now caught.
- Policy rules: initially 10 missed, 18 caught, 10 unviable and two timed out. Add assertions for the actual audit rule name, denials not being authorization, row estimates below/at/above the limit, unknown estimates, and DDL/unscoped approval under otherwise permissive defaults.
- The two timeout logs already contained failed assertions, but an audit test waited forever for a write the mutated policy denied. Bound that test's dispatch wait to five seconds. The follow-up full rules run caught 28 with no misses, and focused reruns caught both previously timed-out mutations. The other ten replacements do not compile; they are not coverage successes or equivalent mutants.
- No new line-coverage percentage is claimed. cargo-llvm-cov/llvm-tools were unavailable locally; mutation measurements and concrete regressions supplied the actionable test-quality evidence. Coverage remains an advisory CI measurement, not an acceptance gate.

## Verification ledger

| Gate | Result |
|---|---|
| Starting baseline full fast gate | Passed outside sandbox after loopback EPERM inside sandbox |
| Final full fast gate | Passed: file-size/panic/bounded-operation guards, formatting, strict Clippy, workspace libraries and binaries, sandbox integration |
| PostgreSQL release fixture | 51 tests passed, including TLS/SSH, reconnect, cancellation, policy, parameters, and transactions |
| Cross-driver TLS fixture | 23 tests passed across MySQL, ClickHouse, MongoDB, and Redis |
| Docker driver integration | 46 tests passed on the final implementation, including PostgreSQL Unix-socket and Redis paths |
| SQLite integration | Eight tests passed, including both new NULL/binary regressions; also included in final fast gate |
| Installed GTK | All 16 scenarios passed using the release binary and isolated temporary Xvfb/AT-SPI dependencies |
| Optional DuckDB | Seven driver tests and the full GTK application build with `--features duckdb` passed |
| Secret Service | One real round-trip passed on a private bus/keyring |
| Dependency policy | `cargo deny check` passed advisories, bans, licenses, and sources |
| Repository/CI checks | Diff whitespace, shell syntax, GTK Python syntax, ignored-test inventory, Git ownership reproduction, and mutation summary execution passed |

## Compatibility and remaining limits

- No saved-data schema, MCP wire format, public connection trait or driver registration changes. JSON **file** exports now preserve binary data using the existing CSV/MCP encoding convention. Empty bytes are `"\\x"` in JSON text and NULL remains `null`.
- Export destinations are atomically replaced only after successful write/flush/sync. Concurrent successful exports use last-completed replacement semantics. Export files are private by default. This does not establish a database snapshot or directory-fsync durability after power loss.
- **Credential/certificate rotation:** daemon session keys include saved transport fields plus a digest of Secret Service secret values and SSH key / TLS CA file contents. Rotating those values opens a new session. Already issued handles keep the session they already hold until released. Secret Service or material-file failures refuse a new open instead of serving the cache.
- **PostgreSQL result caps:** the client stops collecting at its row cap; this is not a server-side LIMIT. Preserve the streaming memory improvement and existing cancellation/pool-reuse tests. Server workload bounding and the documented development-build latency tradeoff remain separate work; do not append LIMIT to arbitrary SQL.
- SQL Server TLS/Kerberos negotiation still lacks an equivalent deterministic KDC/TLS fixture. That gap is not upgraded by other engines' passing fixtures.
- New hosted CI, installed Arch/Wayland install/upgrade/rollback, and the 30-attempt GTK release soak remain pending. Adding GTK scenarios restarts the release soak ledger. No publication or production/package approval is claimed.
