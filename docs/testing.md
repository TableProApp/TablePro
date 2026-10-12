# Testing

The [September 29 regression audit](archive/regression-audit-2026-09-29.md) records the latest findings, added tests, structure changes and execution evidence.

Start with the [validation playbook](validation-playbook.md) for the executable layer catalog, local commands, CI ownership, agent handoffs and regression intake. The shared runner retains reports and logs and fails on incomplete execution.

## Executable gates

Command catalogs, layer boundaries and CI ownership live in the [validation playbook](validation-playbook.md). Prefer `python3 scripts/run-test-layer.py --list` and the playbook’s Start here section over copying Cargo invocations from this page.

`scripts/ci-local.sh` remains the shared local/CI entry for full, widgets and integration modes. Registrations for isolated GTK and keyring tests live in `scripts/isolated-tests.json`; zero selected tests is a failure. Every `ci-local.sh` run saves exact-tree evidence under `target/quality/`. Release mode does not certify package installation, Wayland, upgrade/rollback or retry-free candidate soak. See [0.1.4 review actions and evidence](archive/release-0.1.4.md).

Run from the repository root. Current scope and acceptance are in [the active sprint](bookie-0.2-sprint.md); dated audits stay in [archive](archive/).

## What a container run proves

Database fixtures, the GTK scenarios and the distro-floor jobs run in containers or virtual displays. A pass there shows the code behaves as designed against a disposable database; it is not acceptance of a connection path. Unix sockets, IPv6 loopback, desktop portals and the Secret Service behave differently on a real host, and a container run has already hidden one such difference (Docker does not publish `::1`). Acceptance for those paths is the installed package connecting to a real database on a native desktop, recorded under PKG-1 and in the [manual checklist](manual-verification-0.2-features.md).

## Local checks and fixtures

Use `./scripts/preflight.sh` for the quick non-GTK gate and `python3 scripts/run-test-layer.py quick` / `full` for the playbook layers. Keep both `--lib` and `--bins` when invoking Cargo unit tests directly. `tablepro-app` puts UI and service tests in the `tablepro_app` library; `agentd` still has tests in both targets. DuckDB stays out of the default gate because its optional native build is large.

The workspace lints deny `unwrap`, `expect`, `panic!`, `todo!`, `unimplemented!`, the `print!` family and `dbg!`. Unit tests inside a `#[cfg(test)]` module are exempt through `clippy.toml`. A new standalone Cargo test target under `tests/` must start with:

```rust
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
```

Without it the file compiles locally but fails Clippy. See [error-handling.md](error-handling.md) for the production-path rules.

## Optional features and ignored tests

Validate DuckDB explicitly with the playbook `duckdb` / Build Linux DuckDB job commands. JSON and Parquet extensions are bundled; tests disable extension installation/loading when checking availability. Flat-file tests cover CSV/TSV/JSON/Parquet, quoted filenames and malformed/missing files.

The ignored-test inventory names every declaration, prerequisite and activation command. It is generated from the source and is not committed, so it never conflicts between pull requests. Print it with:

```bash
python3 scripts/inventory-ignored-tests.py
```

`python3 scripts/inventory-ignored-tests.py --check` (part of the harness job) fails when an ignored test is unmapped or an isolated-test registration is stale.

## Unit tests

Place focused tests beside the Rust module under `#[cfg(test)]`. Pure parsing, SQL generation, policy, mapping, persistence, and state-transition behavior should be tested without GTK where possible.

Driver value fixtures can live in `tests/support/value_contracts.rs` as modules of `tests/integration.rs`. Keep the module declaration in that target: support files are not independent Cargo test targets. PostgreSQL and MySQL use this layout; SQL Server unit tests live in `src/tests.rs` under `#[cfg(test)]`. Run the ignored-test inventory generator after moving tests so its links stay correct.

The full `--lib --bins` command builds and runs tests from library crates and binary crates. Application service and UI logic tests are included through the `tablepro_app` library target.

## Storage tests

Storage tests use temporary directories and explicit file paths for JSON and audit behavior. Query-history tests use SQLite. The Secret Service round-trip test is ignored by default because it needs a keyring. `scripts/test-secret-service.sh` always creates an isolated D-Bus/keyring session, even when invoked from a desktop session.

Tests that change XDG environment variables must avoid racing with other tests. Prefer internal functions that accept a path when the module already provides them.

Certificate rejection tests open and ping a trusted control before testing the rejected configuration, then require a TLS error or explicit certificate-verification reason. MySQL unwraps rustls verification details from SQLx I/O errors so rejected certificates retain the TLS classification. Wrong-authority cases exercise both verifying modes across all five TLS fixture drivers; fixture outages and authentication errors cannot stand in for certificate rejection.

Run the driver TLS fixtures with `bash scripts/test-driver-tls.sh`. The MySQL and SQL Server fixtures also expose TLS-only servers behind the built-in SSH tunnel, so the same tier checks service identity through forwarding and refuses invalid certificates without plaintext fallback.

SQL Server Kerberos is an opt-in local fixture because its Samba AD domain controller needs privileged Docker execution. Run `bash scripts/test-mssql-kerberos.sh` to verify a real Kerberos ticket, SQL Server service keytab, SPN refusal, and `VerifyFull` TLS through the BookiE driver. The fixture uses Samba AD DC and does not replace a Windows AD lab.

## Real-driver integration tests

Run all configured Docker suites with:

```bash
./scripts/ci-local.sh integration
```

This gate also runs the MCP MongoDB Extended JSON target and PostgreSQL policy session rollback/commit regressions. The app parser, typed grid-edit and mixed BSON metadata contracts need GTK build libraries as well as Docker:

```bash
python3 scripts/run-test-layer.py app-server
```

The GTK fast CI job runs the app-server registry with the host Docker socket. Testcontainers resolves the Docker bridge gateway from inside the job container. The local release gate uses the same registration.

The exact driver list and supplementary targets are owned by [`ci-local.sh::run_integration`](../scripts/ci-local.sh). It includes six network drivers, MCP BSON, policy PostgreSQL sessions, Unix sockets and SSH. Reuse that script rather than a copied list that can omit newly registered targets.

The Forgejo driver matrix sets `TABLEPRO_TEST_RUN_ID` and runs each complete integration binary serially. PostgreSQL, MySQL and MariaDB fixtures reuse one primary server per engine and recreate the `test` database before each test; filtered and exact selectors start their own server. Deliberate restart tests also start a separate server. So a full-suite runtime estimate should count those cases rather than multiply every test by a database startup.

Disposable PostgreSQL fixtures use tmpfs and disable `fsync`, `synchronous_commit` and `full_page_writes`. MySQL and MariaDB use tmpfs and disable transaction-log, doublewrite and binlog syncing; SQL Server uses tmpfs with writable permissions for its non-root service account. Lost-ack, crash and restart cases use durable containers so they still exercise persistent storage. The Docker tests assert the database settings and mounted filesystem.

These tests require Docker or a compatible Podman API socket. Keep each container handle alive for the full test because dropping it stops the container.

PostgreSQL integration coverage includes controlled cancellation and timeout against a real server. The tests confirm the query appears in `pg_stat_activity`, trigger cancellation or a deadline, confirm the query leaves server activity, and verify that the pool remains usable. Transaction cancellation is followed by rollback and a data check.

## PostgreSQL release fixture

Run the Phase 3 release gate with:

```bash
./scripts/test-postgres-release.sh
```

The script generates fixture certificates and SSH keys, starts PostgreSQL 16 with TLS, an OpenSSH bastion, and Toxiproxy, builds the `tablepro-askpass` helper, runs the agentd system OpenSSH G5 acceptance test, then runs `tablepro-release-tests` with `--include-ignored --test-threads=1`. Only Toxiproxy publishes host ports, so the database is reachable through the proxied path or the bastion and either path can be cut during a test.

The suite verifies certificate hostname and authority checks, tunnelled access to a database with no published port, that a tunnelled `VerifyFull` verifies the original database hostname while a TCP-forwarded one refuses to verify the local dial address, read-only denial of data-changing CTEs and administrative functions, batch and interactive rollback, activity and blocking-lock queries, and direct and SSH reconnect.

`tests/fixtures/postgres-release/README.md` documents the topology, generated materials, and `TABLEPRO_FIXTURE_KEEP_UP=1` for keeping the containers running.

## Local PostgreSQL smoke test

For a PostgreSQL server you already run:

```bash
./scripts/smoke-postgres.sh
```

The ignored smoke test creates and drops `tablepro_smoke_items`. Use a disposable database. Configure another target with `SMOKE_PG_HOST`, `SMOKE_PG_PORT`, `SMOKE_PG_USER`, `SMOKE_PG_PASS`, and `SMOKE_PG_DB`.

For the deterministic direct Unix-socket fixture:

```bash
./scripts/test-postgres-socket.sh
```

It exposes a PostgreSQL 16 socket directory from a disposable container and verifies query, write, pre-dispatch cancellation, close, and reconnect without opening a TCP database port.

## Manual verification after the 0.2 feature sprint

The upstream feature adoption merged in September 2026 added GTK surfaces whose logic is unit-tested and whose layout has never been displayed. The checklist is [manual-verification-0.2-features.md](manual-verification-0.2-features.md). Treat it as outstanding until each line carries a result.

## GTK tests

Run the installed safety suite with:

```bash
./scripts/test-gtk-safety.sh
```

The script builds `tablepro-app`, always starts a private runtime directory, isolated D-Bus session and Xvfb display, and drives the real application through PyAT-SPI. Each scenario gets temporary XDG directories and a production or local SQLite saved connection. The runner uses a standalone AT-SPI D-Bus daemon and passes the Xvfb display to D-Bus activation, so it does not reuse desktop accessibility or portal processes. GTK tests exercise the X11/GTK portal path; they do not replace installed Wayland package testing.

When `TABLEPRO_GTK_ARTIFACT_DIR` is set, every scenario writes a JSON result and application stderr, including successful scenarios. Failures additionally retain the accessibility tree and a screenshot when available. Successful runs therefore have uploadable evidence; a missing artifact still fails CI. Python regressions exercise both result paths without needing a display.

The suite verifies:

1. Dismissing a production approval leaves SQLite unchanged.
2. Approving once performs one mutation and prompts again for the next operation.
3. Unavailable audit storage denies the mutation without showing an approval path around the failure.
4. A named `:parameter` in the editor prompts for a value and writes the bound value, not the placeholder text.
5. Ctrl+D saves the editor query as a favorite, and Ctrl+P finds it, opens it, and records the use.
6. A successful saved-connection switch tears down the old workspace and sends writes only to the new database.
7. A failed candidate connection leaves the original editor and database usable.
8. A running read is cancelled and fully settles before the candidate connection is activated; subsequent writes reach only the new database.
9. Current-page CSV export writes exactly the first 100 PK-ordered rows from a 150-row fixture through the real portal chooser.
10. Pending edits gate a connection switch; discarding does not write to either database.
11. A browse tab reopened after switching reads the new connection.
12. Two windows keep queries attached to their own databases.
13. Switching away and back after the persistence debounce preserves workspace tabs.
14. Switching one window preserves another window's pending edits.
15. Current-page JSON export preserves order, Unicode, escaped text, empty text, NULL, and binary values; binary values use `\x`-prefixed hexadecimal, including `\x` for an empty blob.
16. Graceful quit and a new process restore the last connection and selected editor text without executing it; a subsequent explicit Run writes only to that connection. The saved browse tab also reopens.
17. Keyboard column search jumps to the selected column.
18. Committed editor DDL refreshes the sidebar.
19. SQL character warnings leave the editor query unchanged.
20. Current-page XLSX export preserves typed SQLite values, nanosecond times/timestamps, BC/year-10000 dates, wide signed integers, infinity, NULL and formula-like Unicode text. Workbook XML proves native versus text cells and the 100-row page boundary; all source rows remain unchanged.
21. Cancelling the workbook save chooser preserves an existing destination, leaves no temporary export, and leaves all source rows unchanged.
22. Empty text in workbook results produces a visible error with the row/column and CSV/JSON alternatives. No lossy workbook or temporary export is published, and source rows remain unchanged.
23. Repeated named parameters insert exact minimum/maximum signed integers and SQL-like Unicode text into two rows, preserving binding order and treating the payload as data.
24. Cancelling the parameter dialog writes no rows; retrying the same statement uses the replacement values and never executes the cancelled values.
25. XML export round-trips carriage returns, CRLF, LF, tabs, literal entity-looking text and Unicode through an independent XML parser; NULL remains distinct from empty text.
26. XML export of NUL-containing text shows the code point and row/column error, publishes no file, leaves no temporary export and does not change source rows.

The XML scenarios live in `apps/linux/app/tests/gtk_xml.py`. Run `xml_export_preserves_line_endings_and_null_distinctions` or `xml_export_refuses_illegal_text_without_publishing` with `TABLEPRO_GTK_SCENARIO`. Their Python oracle tests deliberately normalize carriage returns and collapse empty text into NULL, requiring both corruptions to fail. Core tests independently check atomic destination preservation for XML-illegal controls and U+FFFE/U+FFFF.

The parameter scenarios live in `apps/linux/app/tests/gtk_parameters.py`; select `repeated_parameters_preserve_wide_ids_and_sql_like_text` or `cancelled_parameters_never_execute_and_retry_uses_new_values` through `TABLEPRO_GTK_SCENARIO` to run one. Registration tests require both in the default suite. Each checks committed SQLite rows independently of the visible UI result.

The workbook scenarios live in `apps/linux/app/tests/gtk_workbook.py` and are registered in the default suite. Their XML oracle has separate negative tests that reject rounded values, wrong types, lost precision, formulas and incorrect page boundaries. SQLite supplies typed Date/Time/DateTime for these UI scenarios; typed TimestampTz UI coverage against a network server remains separate from the core and PostgreSQL contracts. The cancellation UI test stops at the chooser; a core regression also cancels after writing a row and checks atomic destination preservation.

To run one scenario using an already-built candidate (without another Cargo build):

```bash
TABLEPRO_GTK_BINARY=/absolute/path/to/bookie \
TABLEPRO_GTK_SCENARIO=current_page_workbook_preserves_typed_values \
TABLEPRO_GTK_ARTIFACT_DIR=/tmp/bookie-workbook-evidence \
bash scripts/test-gtk-safety.sh
```

Use `cancelled_workbook_export_preserves_existing_file` for the cancellation case. Record the binary's commit/checksum; a prebuilt binary is not evidence for later Rust edits. Omit `TABLEPRO_GTK_BINARY` to build the current release profile.

Each scenario declares its own fixture shape through `environment` and `audit_available` attributes, so a scenario can run against a local or production saved connection.

The Open Quickly scenario waits for the filtered result set before invoking its single action; the already-visible favorite is not proof that the debounced row rebuild has completed. It still requires the window to close and usage to be persisted.

Buttons and rows are invoked through named AT-SPI actions; the harness re-queries the row while waiting up to 15 seconds for its action to appear in the accessibility tree. There is no generic Return-key fallback. Keyboard events exercise shortcuts and the export format combo's navigation. The combo has no AT-SPI click/focus action: its scenario tabs until the named control reports focus, opens its list, navigates to the requested format, and verifies its selected label before exporting. Each denial assertion requires the row count to hold for a settle window rather than matching once.

On Arch or Omarchy, install the harness dependencies with:

```bash
sudo pacman -S --needed dbus xorg-server-xvfb at-spi2-core python-atspi
```

Ubuntu CI uses `dbus-daemon`, `gnome-keyring`, `xvfb`, `xauth`, `at-spi2-core`, `python3-pyatspi`, and `scrot`. The PR smoke job is required. A separate daily workflow runs five retry-free attempts and uploads stdout, stderr, accessibility snapshots, and screenshots on failure. RC promotion requires 30 consecutive attempts across at least six runs. Service-level tests still cover pure state and policy behavior, but they do not replace these cross-layer tests.

SQLite integration regressions also distinguish NULL from zero, false, empty text, and empty blobs in declared columns, and preserve binary values despite declared-type affinity mismatches. Export unit tests overlap writers deterministically and check that pre-existing temporary symlinks cannot redirect writes. Workspace tests preserve active-tab identity when unknown records are removed.

For ordinary UI changes, test the affected flow manually and include before and after screenshots. Add deterministic automation when a regression can be reproduced without timing or desktop-session assumptions.

## CI

Where each check runs is owned by [CI tiers in the validation playbook](validation-playbook.md#ci-tiers). GitHub runs the cheap tier on pull requests; Forgejo runs the merge tier on branch pushes. Documentation-only changes skip the heavy path. Do not treat a skipped GitHub merge-tier job as a pass.

### Reading a red run

`scripts/classify-ci-failure.py --run RUN_ID` (or `--log FILE`) tags each failed job from its log. It reads `FORGEJO_API` or derives it from the `forgejo` remote, and the token from `~/.config/forgejo/token`, like `scripts/forgejo-gate.sh`.

| Tag | Meaning | What to do |
|---|---|---|
| `infra` | Image pull or fixture start timeout, compiler crash, rate limit, runner volume path | Retry before reading code |
| `gui-timing` | The window did not appear | Retry once |
| `gui` | A GUI assertion failed | Ambiguous: a missing accessible node can be load or a real regression. Rerun once; if the same scenario fails again on a quiet runner, treat it as code |
| `code` | Test panic, compile or lint error, application crash, startup layout abort | Read the log and fix |

The tag is advice only and never changes a result. A new infrastructure signature goes in the `SIGNATURES` table with a test in `scripts/tests/test_classify_ci_failure.py`.

## Measuring how good the tests are

The [September CI audit](archive/ci-audit-2026-09-27.md) distinguishes executed tests, intentional exclusions and packaging-only green runs. Mutation and coverage run on a schedule. The Forgejo nightly job measures line coverage of the unit tier only and holds a ratcheted floor in `baselines/coverage-floor.txt` (59%; 59.41% measured on 2026-10-11). Integration, installed GTK and value-contract tests are not part of that percentage. Mutation survivors need investigation. Dated first-run mutation notes are in [testing history](archive/testing-history.md#mutation-first-run-notes-2026-08-22).

### Mutation testing

```bash
cargo install cargo-mutants --locked
cargo mutants --package tablepro-core --test-tool cargo -- --lib
cargo mutants --package tablepro-core --file crates/core/src/sql_lex.rs --test-tool cargo -- --lib
```

Prefer `core` and `policy`. CI also covers `ssh` and `driver-redis`. The PostgreSQL mutation job covers numeric, array, temporal and binary-text decoders with unit tests; Docker-backed value regressions stay in the driver layers. Follow [ADR 0007](decisions/0007-type-and-value-preservation.md) and the [B3 board](type-contract-strategy.md). Equivalent mutants and timeout findings are discussed in the archived first-run notes above.

### Coverage

```bash
cargo install cargo-llvm-cov --locked
rustup component add llvm-tools-preview
cargo llvm-cov --workspace --exclude tablepro-driver-duckdb --exclude tablepro-app \
  --lib --bins --tests --summary-only
```

Exclude app and fixture tiers so the map does not depend on Docker or a display. Coverage shows execution, not assertion quality.

## Upstream test-suite parity

The [September adoption record](archive/testing-history.md#upstream-test-suite-parity) preserves the original cases and counts. Current case candidates and ownership are in [the scenario survey](archive/b3-test-scenario-survey.md) and the B3/B4 boards. Reproduce a candidate against current source before changing it; a historical claim of zero tests does not establish a current coverage gap.

## File-size guard

`scripts/check-file-size.sh` enforces the Rust source limits recorded in `baselines/file-size-baselines.txt`:

| Limit | Lines | Result |
|---|---:|---|
| Soft | 1200 | Split the file or record an approved baseline |
| Hard | 1800 | Unlisted files fail |
| Ratchet | Recorded maximum | A listed oversized file may not grow past its baseline |

Lower a baseline in the same change when an oversized file shrinks.

When inline unit tests push a production module over the soft limit, move them to a sibling `tests.rs` and declare it with `#[cfg(test)] mod tests;`. Import the parent with `use super::*;` so private behavior stays directly testable without carrying the test bodies in the production file.

## Browse performance

See [the September measurements](archive/performance-2026-09.md) and the `browse_benchmark` example in the release-test crate. One warm-up plus five measured samples cover first, filtered, deep, wide and capped result sets. Run each case in a separate process against a disposable fixture, with builds complete before measuring. Report memory improvements and latency regressions separately.

The [bug and consistency audit](archive/bug-consistency-2026-09.md) records the newer targeted mutation findings. cargo-mutants creates its report beneath `<output>/mutants.out/`; CI summaries distinguish missing reports from zero findings and retain the measurement step outcome.
