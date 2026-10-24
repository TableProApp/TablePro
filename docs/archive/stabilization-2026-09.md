# September Linux stabilization audit

Reviewed base: `7d82881323af083dc6e045971f31d505fdf03164`, branch `linux`, tracking `cozyGarage/TablePro:linux`. Review date: 2026-09-07; verification ledger finalized 2026-09-08. Stabilization candidate `751a458293eca384e8747d7661db1fe9f713401b` is committed and pushed to `origin/linux`. Local evidence below matches its implementation source hashes. Hosted candidate validation is pending.

At the time of this review, [PLAN.md](https://github.com/cozyGarage/BookiE/blob/f7a985ef2fe9c65e4ac5307d52e0d0185978631d/PLAN.md) recorded the ten-day sprint and phase order. Current sequencing is in the [active sprint](../bookie-0.2-sprint.md). [Upstream adoption](upstream-adoption.md) owns the whole-app comparison through pinned macOS 0.72. [Performance measurements](performance-2026-09.md) contain the reproducible raw samples.

## What changed

| Finding | Reproduction / evidence | Resolution |
|---|---|---|
| PostgreSQL text patterns on UUID/enum/numeric/date/JSON failed | New unit regression failed before the change; real PostgreSQL filter cases exercise cast and typed comparison paths | Cast only pattern operands requiring text; keep typed equality/order comparisons and binding |
| Invalid filters produced an unfiltered count | Count caller mapped every build error to no WHERE; the page builder instead returned an error | Shared pure browse planner; fail without dispatch and clear the count through its request-generation failure path |
| Daemon view metadata disappeared | Wrapper contract regression failed before forwarding was added | Forward ordinary and controlled calls, including returned errors and cancellation |
| Retired connection could replace sidebar metadata | Schema refresh response carried tables alone | Carry saved ID plus an opaque underlying-session token; match both at delivery |
| Editor schema cache reset for every request | DatabaseService constructs a new PolicyGuard for each handle, while SchemaIndex compared wrapper pointers | Atomically return a guarded handle and session identity; cache survives new guards and invalidates on actual reconnect; regression tests use the real service |
| Schema edits dispatched redundant reads with old column types | on_schema_changed dispatched columns, page and count; ColumnsLoaded dispatched page/count again | Wait for ColumnsLoaded before issuing page/count |
| DuckDB JSON/Parquet availability depended on external extensions | Offline JSON function regression failed with the original bundled-only dependency | Bundle both extensions; test formats, unusual paths, malformed/missing files; add optional driver/application CI |
| Large PostgreSQL results retained two representations | Million-row benchmark; original collector retained PgRows alongside decoded Values | Decode while streaming and cache type names once; about 58% lower peak RSS with a documented development-build latency tradeoff |
| GTK favorite test acted on an obsolete row | Original scenario failed; diagnostic wait for search rebuild passed | Wait for the filtered visible result set, click once, require dialog closure and persisted usage |
| GTK tests reused desktop services and inherited disabled accessibility | Isolated AT-SPI broker could not activate without systemd; portal inherited old DISPLAY and NO_AT_BRIDGE | Private runtime and D-Bus daemon, Xvfb activation environment, enabled accessibility, scoped FUSE cleanup |

## Ownership and transaction review

Browse tabs receive fresh UUIDs when created; closing/switching removes their controllers, so results for retired tabs do not attach to a newly created tab. Page/count results retain request-generation checks. Sidebar refresh and editor completion now use an identity independent of the policy wrapper. Metadata tokens expose no raw connection or authorization bypass.

PostgreSQL interactive editor transactions own a checked-out transaction handle. Structure batches start their own pooled transaction. The new real-engine test leaves an editor write uncommitted while a structure batch succeeds and another fails, then proves neither path commits nor rolls back the editor. This is PostgreSQL evidence, not a claim that every engine supports transactional DDL.

Recent pre-sprint changes reviewed include MySQL unsigned/wide-decimal mapping, SQLite decode fallback, SQL Server large numeric handling and custom CA wiring, cancellation task completion, audit raw-byte hashing, restored-tab indexing, MongoDB drop and connection errors, UTF-8 display and FK headers. Current default tests cover their local paths. Their unchanged external-driver evidence is the base-commit CI below.

## Verification ledger

Toolchain: Rust/Cargo 1.93.1; GTK 4.22.4, libadwaita 1.9.3, GtkSourceView 5.20.0. PostgreSQL 18.6 was extracted under `/tmp` and started on localhost:55433 with fixture TLS materials; no system package or database was changed. Temporary GTK dependencies were extracted under `/tmp` as well.

| Gate | Result / boundary |
|---|---|
| Baseline fast gate | Passed during planning; loopback restrictions required an unsandboxed rerun |
| Stabilization full fast gate | Passed: formatting, file/panic/bounded-operation guards, strict Clippy, workspace lib/bin tests and sandbox integration |
| PostgreSQL affected release targets | 32 passed: browse_filters (8), structure_ddl (6), parameters (5), policy_transactions (4), mcp_tools (9), including new row-cap and transaction-isolation tests |
| Optional DuckDB | Passed: seven driver tests, application feature check and full `cargo build --locked -p tablepro-app --features duckdb` |
| GTK | All 14 scenarios passed with the finalized isolated runner and rebuilt application; shutdown D-Bus warnings remain in the log |
| Dependency policy | `cargo deny check`: advisories, bans, licenses and sources passed |
| cargo-audit | Not installed locally; no standalone cargo-audit pass is claimed |
| Base hosted Build Linux | [Passed at 7d8288132](https://github.com/cozyGarage/TablePro/actions/runs/34107322448): preflight, GTK fast/smoke, driver integration, driver TLS and PostgreSQL fixture. Scheduled current-stable job was skipped in that push run |
| Base hosted Flatpak | [Passed at 7d8288132](https://github.com/cozyGarage/TablePro/actions/runs/34107322467); a build is not installed-package verification |
| Full Docker/TLS/SSH matrix on this working tree | Not rerun: Docker socket permission denied even outside sandbox; sudo requires a password. The local PostgreSQL alternative covers SQL/TLS-to-localhost behavior, not the bastion/Toxiproxy/other-engine fixtures |
| RC soak / installed Arch package | Not performed; no candidate tag, publication or 30-attempt soak credit |

The [validation manifest](evidence/2026-09-stabilization/validation.json) records commands, saved-log hashes and source hashes for the locally tested tree, now mapped to the committed candidate. The temporary PostgreSQL server was confirmed stopped during finalization. Prior process handles expired between sessions, so finalization verified saved completion output rather than recovering process exit codes.

The [generated ignored-test ledger](../../scripts/inventory-ignored-tests.py) lists exact tests and their activation requirements. Subprocess helpers are counted separately. Test counts are evidence inventory, not proof of defect absence.

Reproduce the affected real-engine slice against an isolated server compatible with the release fixture:

```bash
cd linux
TABLEPRO_FIXTURE_POSTGRES_RELEASE=1 TABLEPRO_FIXTURE_PROXY_PORT=55433 \
  cargo test --locked -p tablepro-release-tests \
  --test browse_filters --test structure_ddl --test parameters \
  --test policy_transactions --test mcp_tools -- --include-ignored --test-threads=1
```

The local server also used `tests/fixtures/postgres-release/seed/01-seed.sql` and generated localhost TLS materials. Port override alone is insufficient without that setup. The normal reproducible full fixture remains `scripts/test-postgres-release.sh` when Docker access is available.

## Remaining work, severity and acceptance

| Item | Severity / reproduction | Impact | Next action and acceptance |
|---|---|---|---|
| Full external-driver validation | Release gate: run the Docker/TLS/SSH scripts on this tree | Local PostgreSQL subset cannot prove other drivers or tunnel recovery | Candidate pushed; inspect existing hosted jobs and record exact resolved SHA with all relevant jobs green |
| Optional Oracle ODPI build | Known unsupported feature: build with odpi | Not a shippable driver | Keep unsupported; repair in separate driver project with a real fixture before advertising |
| Large-result latency tradeoff | P2: capped benchmark in performance report | Lower RSS, approximately 12% slower development-build median | Profile release binaries and evaluate decode batching; preserve row cap, cancellation, values and memory bound |
| PostgreSQL server-side row cap | P2: query beyond MAX_QUERY_ROWS | Client still has to stop receiving/discard remaining rows; memory optimization does not impose a server LIMIT | Design a driver/protocol solution with server-activity and pool-reuse tests; never blindly append LIMIT to arbitrary SQL |
| Credentials/certificates rotated in place | Closed: digest Secret Service values and SSH key / TLS CA file bytes into the session key | New opens after rotation use the new material; issued handles keep the session they already hold | Covered by transport material-digest tests and agentd cache-key tests |
| Restart restoration and JSON export proof | P2 coverage gaps | These workflows are implemented but incompletely tested through GTK | Add process-restart and JSON export scenarios before upgrading capability status |
| SQL Server TLS/Kerberos | P2 verification gap: no KDC or SQL Server TLS fixture | Configuration support is not negotiation evidence | Deterministic certificate and SPN/KDC fixture including refusal cases |
| Arch/Wayland release approval | Release gate: install/upgrade/rollback and 30-attempt soak absent | No production/package approval | Freeze one SHA and meet existing Phase 4/package criteria |

## Sprint disposition

S1–S3 and S5–S6 have concrete code, regressions and documentation. S4 delivers a measured memory optimization with its latency limitation. S7 supplies runnable local evidence; externally blocked release gates remain explicit follow-up work. This sprint adds no feature-parity promise, runtime plugins, new engines, entitlements or Apple code merge.

## Post-push review — 2026-09-08

Reviewed the committed browse planner, filter grouping and binding order, guarded session identity, asynchronous metadata delivery, streaming decoder, optional-driver workflow and GTK isolation changes. No new blocking defects were found. This is a continuation of the implementation review, not independent approval; the unresolved items above remain open. All implementation hashes in the validation manifest match the committed files, and `git diff --check` passed.

The changes were split into focused daemon, browse/ownership, PostgreSQL memory, DuckDB, GTK-test and documentation commits. [Build Linux](https://github.com/cozyGarage/TablePro/actions/runs/34272620179) and [Flatpak](https://github.com/cozyGarage/TablePro/actions/runs/34272619924) started for the candidate and were in progress when this review was recorded. The documentation follow-up push may supersede those runs under branch concurrency rules; use the [latest linux branch runs](https://github.com/cozyGarage/TablePro/actions?query=branch%3Alinux) for final results. No candidate CI success or release approval is claimed.

The first hosted run subsequently exposed a DuckDB workflow setup failure at “Record the commit under test”: the minimal container had not installed Git before checkout/commit recording. The follow-up installs Git and CA certificates before checkout, using `/tmp` as the working directory because the repository is not yet present. This also lets checkout retain real Git metadata. The corrected workflow needs a fresh hosted run; local driver/application test results are unchanged.
