# Testing

The [active sprint](bookie-0.2-sprint.md) owns current acceptance. Start with the [validation playbook](validation-playbook.md) for the executable layer catalog, local commands, CI ownership, agent handoffs and regression intake. Dated audits in [archive](archive/) prove only their recorded source and environment.

## Executable gates

`scripts/ci-local.sh` remains the shared local/CI entry for full, widgets and integration modes. Registrations for isolated GTK and keyring tests live in `scripts/isolated-tests.json`; zero selected tests is a failure. Every `ci-local.sh` run saves exact-tree evidence under `target/quality/`. Release mode does not certify package installation, Wayland, upgrade/rollback or retry-free candidate soak. See the [packaging guide](../apps/linux/packaging/README.md) and [manual checklist](manual-verification-0.2-features.md).

## What a container run proves

Database fixtures, the GTK scenarios and the distro-floor jobs run in containers or virtual displays. A pass there shows the code behaves as designed against a disposable database; it is not acceptance of a connection path. Unix sockets, IPv6 loopback, desktop portals and the Secret Service behave differently across containers and desktop sessions; a container run has already hidden one such difference (Docker does not publish `::1`). Acceptance for those paths is the installed package connecting to a real database in the target native desktop session, on the host or a supported VM, as recorded under PKG-1 and in the [manual checklist](manual-verification-0.2-features.md).

## Test runner

The unit and sandbox tiers run under [cargo-nextest](https://nexte.st), one process per test. `scripts/ensure-nextest.sh` downloads the pinned release, checks its SHA-256 and caches it under `~/.cache/bookie-tools` (Forgejo uses `/var/cache/ci/tools`); `.config/nextest.toml` requires that version. Both profiles keep `retries = 0`, so a flaky test fails instead of passing on a hidden retry, and stop a test that runs for five minutes. The `ci` profile also writes `target/nextest/ci/junit.xml`. Nextest runs the same tests as `cargo test` for these tiers (1690 unit and 1706 sandbox names on 2026-10-16); its pass total is lower only because libtest also counts subprocess helpers that a parent test launches. Driver, release, GTK and keyring tiers stay on `cargo test` until the PostgreSQL shared fixture has ownership across processes ([#892](https://github.com/cozyGarage/BookiE/issues/892)). Doc tests are not part of these tiers.

## Local checks and fixtures

Select Cargo test targets deliberately: `tablepro-app` puts UI and service tests in the `tablepro_app` library, while `agentd` has library, binary and integration tests. DuckDB stays out of the default gate because its optional native build is large. Contributor lint and test-target rules live in [AGENTS.md](../AGENTS.md).

## Optional features and ignored tests

JSON and Parquet extensions are bundled; tests disable extension installation/loading when checking availability. Flat-file tests cover CSV/TSV/JSON/Parquet, quoted filenames and malformed/missing files. The ignored-test inventory records each declaration, prerequisite and activation layer. It is generated rather than committed; the harness rejects unmapped tests or stale isolated-test registrations.

## Unit tests

Place focused tests beside the Rust module under `#[cfg(test)]`. Pure parsing, SQL generation, policy, mapping, persistence, and state-transition behavior should be tested without GTK where possible.

Driver value fixtures can live in `tests/support/value_contracts.rs` as modules of `tests/integration.rs`. Keep the module declaration in that target: support files are not independent Cargo test targets. PostgreSQL and MySQL use this layout; SQL Server unit tests live in `src/tests.rs` under `#[cfg(test)]`. Run the ignored-test inventory generator after moving tests so its links stay correct.

The full `--lib --bins` command builds and runs tests from library crates and binary crates. Application service and UI logic tests are included through the `tablepro_app` library target.

## Contract guardrails

A guardrail test pins a contract that other code relies on but that no feature test exercises on its own, so a refactor cannot break it silently. Each one names the invariant it protects, and each was checked by injecting the regression it guards against and watching it fail. When a guardrail fails, the change broke the contract: fix the change, not the test. Weakening or removing a guardrail needs the owner of the contract (the ADR or the lane that owns the code) to agree in the pull request.

| Contract | Test | Where |
| --- | --- | --- |
| A finished call, successful or failed, never cancels its caller's operation control, so the next statement can reuse it | `a_finished_call_leaves_the_callers_token_usable_for_the_next_call` | `crates/core/src/operation.rs` |
| A completed call never asks the server to stop it | `a_completed_operation_never_dispatches_server_cancellation` | `crates/core/src/operation.rs` |
| A cancel after dispatch is an unknown outcome, never a clean cancel | `a_cancel_after_dispatch_is_an_unknown_outcome_not_a_clean_cancel` | `crates/core/src/operation.rs` |
| Guarded queries, writes and transactions leave the caller's control usable, after success or failure | `guarded_calls_leave_the_callers_control_usable_for_the_next_statement`, `a_failed_guarded_call_never_cancels_the_callers_control` | `crates/policy/src/guard_tests_passthrough.rs` |
| The guard cancels the caller's token only when the approval deadline passes | `an_approved_controlled_write_never_cancels_the_callers_token` | `crates/policy/src/guard_tests_gating.rs` |
| A completed MCP HTTP request delivers its response and never cancels | `a_completed_http_request_delivers_its_response_and_never_cancels` | `crates/mcp/src/server.rs` |

Add a row here when you add a guardrail.

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

For the backup and restore runner:

```bash
./scripts/test-pg-dump.sh
```

It runs `pg_dump` and `pg_restore` from the `postgres:18-alpine` image through wrappers, so the host needs Docker but no PostgreSQL client. Set `TABLEPRO_PG_DUMP_IMAGE` to test another client version. Forgejo runs it as the `pg-dump` job.

## Manual verification after the 0.2 feature sprint

The upstream feature adoption merged in September 2026 added GTK surfaces whose logic is unit-tested and whose layout has never been displayed. The checklist is [manual-verification-0.2-features.md](manual-verification-0.2-features.md). Treat it as outstanding until each line carries a result.

## GTK tests

Run the installed safety suite with:

```bash
./scripts/test-gtk-safety.sh
```

The script builds `tablepro-app`, always starts a private runtime directory, isolated D-Bus session and Xvfb display, and drives the real application through PyAT-SPI. Each scenario gets temporary XDG directories and a fixture SQLite database. A scenario may mark its saved fixture connection as production to test policy prompts; it never opens a user's saved connection or production database. The runner uses a standalone AT-SPI D-Bus daemon and passes the Xvfb display to D-Bus activation, so it does not reuse desktop accessibility or portal processes. GTK tests exercise the X11/GTK portal path; they do not replace installed Wayland package testing.

After its configured retry a failed scenario is recorded and the runner carries on with the rest. Each failure prints a `FAILED:` line and its assertion text, and the run ends with one line that lists every failed scenario and exits non-zero. A scenario that fails only because an earlier one left a shared fixture in a bad state can still fail alongside it, so read the first failure first.

When `TABLEPRO_GTK_ARTIFACT_DIR` is set, every scenario writes a JSON result and application stderr, including successful scenarios. Failures additionally retain the accessibility tree and a screenshot when available. Successful runs therefore have uploadable evidence; a missing artifact still fails CI. Python regressions exercise both result paths without needing a display.

Representative end-to-end scenarios in the suite are listed below; the current registry, including scenarios from the GTK workbook, parameter, XML and UX modules, is in [`gtk_safety.py`](../apps/linux/app/tests/gtk_safety.py).

1. Dismissing approval for a fixture connection marked production leaves its SQLite database unchanged.
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
TABLEPRO_GTK_ARTIFACT_DIR=target/gtk-evidence \
bash scripts/test-gtk-safety.sh
```

Use `cancelled_workbook_export_preserves_existing_file` for the cancellation case. Record the binary's commit/checksum; a prebuilt binary is not evidence for later Rust edits. Omit `TABLEPRO_GTK_BINARY` to build the current release profile.

Each scenario creates a temporary profile and fixture connection/database. Its `environment` attribute selects the policy environment to exercise, and `audit_available` controls whether the fixture audit journal is present. These tests do not use existing saved connections or a user's production database.

The Open Quickly scenario waits for the filtered result set before invoking its single action; the already-visible favorite is not proof that the debounced row rebuild has completed. It still requires the window to close and usage to be persisted.

Buttons and rows are invoked through named AT-SPI actions; the harness re-queries the row while waiting up to 15 seconds for its action to appear in the accessibility tree. There is no generic Return-key fallback. Keyboard events exercise shortcuts and the export format combo's navigation. The combo has no AT-SPI click/focus action: its scenario tabs until the named control reports focus, opens its list, navigates to the requested format, and verifies its selected label before exporting. Each denial assertion requires the row count to hold for a settle window rather than matching once.

On Arch or Omarchy, install the harness dependencies with:

```bash
sudo pacman -S --needed dbus xorg-server-xvfb at-spi2-core python-atspi
```

Ubuntu CI uses `dbus-daemon`, `gnome-keyring`, `xvfb`, `xauth`, `at-spi2-core`, `python3-pyatspi`, and `scrot`. GitHub pull requests run the required GTK fast checks and widget regressions; the installed GTK safety smoke runs only on a schedule or manual dispatch. The separate daily GTK Safety Soak runs five retry-free attempts and uploads stdout, stderr, accessibility snapshots, and screenshots on failure. 0.2.0 qualification requires 30 consecutive attempts across at least six runs at the same source SHA. Service-level tests still cover pure state and policy behavior, but they do not replace these cross-layer tests.

The nightly workflow runs in stages (unit-tier coverage, then the Docker-tier coverage and mutation jobs, then the soak and package jobs), two shards at a time, so a red stage is a finding and not a lost runner. Each driver crate is measured with its Docker suite against `baselines/coverage-floors-crates.txt` (`scripts/check-crate-coverage-floors.py`). Mutation results are compared with `baselines/mutants/<package>.txt` by `scripts/check-mutants-baseline.py`: a missed mutant that is not in the baseline fails the run, and baseline lines that a test now catches are listed for deletion. A missing baseline file means no missed mutant is accepted. The soak is three runs of five attempts each per night.

### Reading a red nightly

Sort each red job before touching code. The class decides what the fix and its regression test are.

| Class | How to recognise it | What to do |
| --- | --- | --- |
| Setup failure | The job fails before any test runs: a missing script or path, a wrong binary name, a package missing from an image, a port already in use | Fix the workflow or script, and add a contract test in `scripts/tests/test_ci_workflow.py` or next to the helper. A setup failure hides every later check in that job. |
| Missed mutant | The log lists `NEW missed mutant` | Write a test that asserts the behaviour the mutant changes. Baseline only a mutant that no test can observe, with the reason in the file header. |
| Scenario failure | The soak or an installed GTK shard names a scenario and an assertion | Read the assertion first. The runner carries on after a failure and lists every failed scenario at the end, so start with the first one in the list. |
| Known gap | `gtk-ubuntu` is allowed to fail ([TEST-28](backlog.md)) | Do not chase it from the nightly. |

Every nightly finding that is a product or test gap gets a regression test in the lowest tier that can show it, and an issue when the fix is not immediate. Check a mutation change locally with `cargo mutants -p <crate> --file <file>` and then `python3 scripts/check-mutants-baseline.py <package> <output dir> 3`, which uses the nightly's own judgement. Run a few times: a mutant caught by a timing accident shows up as an occasional miss.

A manual dispatch runs the whole nightly, and the soak and package jobs wait for the mutation jobs. A fix to a nightly-only job is therefore proven by the next night. The contract tests cover its static part.

Forgejo workflows on the host executors use no JavaScript actions, because those executors have no Node; `scripts/tests/test_ci_workflow.py` fails on any `uses:` line. The distro-floor jobs share one Ubuntu 24.04 package per commit: `scripts/distro-floor-package.sh <sha>` builds it once per host under a lock, caches it for a day and hands the root-owned build output back to the runner user. The runtime image carries the GTK 4 Python bindings because the paste scenario starts a clipboard helper with them. When a floor job fails, its output lists the failing scenario and assertion, not the end of the log.

SQLite integration regressions also distinguish NULL from zero, false, empty text, and empty blobs in declared columns, and preserve binary values despite declared-type affinity mismatches. Export unit tests overlap writers deterministically and check that pre-existing temporary symlinks cannot redirect writes. Workspace tests preserve active-tab identity when unknown records are removed.

For ordinary UI changes, test the affected flow manually and include before and after screenshots. Add deterministic automation when a regression can be reproduced without timing or desktop-session assumptions.

## CI

Where each check runs is owned by [CI tiers in the validation playbook](validation-playbook.md#ci-tiers). GitHub runs the cheap tier on pull requests; Forgejo runs the merge tier on branch pushes. Documentation-only changes skip the heavy path. Do not treat a skipped GitHub merge-tier job as a pass.

### Gating several pull requests at once

`scripts/forgejo-train.sh BRANCH BRANCH...` merges the named remote branches onto `origin/linux` in a throwaway worktree, skips any that conflict, and gates the combined result once. A pass proves that combination only; each pull request still needs its required gate on the head to be merged, as described in the [validation playbook](validation-playbook.md#hosted-checks). A failed train can help isolate conflicts or interactions; gate its branches individually to locate the cause. `FORGEJO_TRAIN_DRY=1` only builds the train. `CHANGELOG.md` and the PostgreSQL `connection_paths.rs` registry merge by union (`.gitattributes`), because every pull request appends to them and they were the usual cause of conflicts.

### Reading a red run

`scripts/classify-ci-failure.py --run RUN_ID` (or `--log FILE`) tags each failed job from its log. It reads the Forgejo endpoint and token from the same configuration as `scripts/forgejo-gate.sh`.

| Tag | Meaning | What to do |
|---|---|---|
| `infra` | Image pull or fixture start timeout, compiler crash, rate limit, runner volume path, a job log that ends without a result (runner or Forgejo connection lost) | Retry before reading code |
| `gui-timing` | The window did not appear | Retry once |
| `gui` | A GUI assertion failed | Ambiguous: a missing accessible node can be load or a real regression. Rerun once; if the same scenario fails again on a quiet runner, treat it as code |
| `code` | Test panic, compile or lint error, application crash, startup layout abort | Read the log and fix |

The tag is advice only and never changes a result. A new infrastructure signature goes in the `SIGNATURES` table with a test in `scripts/tests/test_classify_ci_failure.py`.

## Measuring how good the tests are

The [September CI audit](archive/ci-audit-2026-09-27.md) distinguishes executed tests, intentional exclusions and packaging-only green runs. Mutation and coverage run on a schedule. The unit-tier line-coverage score has its own ratcheted floor in `baselines/coverage-floor.txt` (59%; 59.41% measured on 2026-10-11). The nightly workflow separately measures Docker suites for PostgreSQL, MySQL, SQLite, MongoDB, Redis and ClickHouse against `baselines/coverage-floors-crates.txt`. Installed GTK is outside both coverage reports. These floors do not measure every crate or prove assertion quality; the current manual measurements and unmeasured areas are recorded in [#782](https://github.com/cozyGarage/BookiE/issues/782). Mutation survivors need investigation. Dated first-run mutation notes are in [testing history](archive/testing-history.md#mutation-first-run-notes-2026-08-22).

### Mutation testing

```bash
cargo install cargo-mutants --locked
cargo mutants --package tablepro-core --test-tool cargo -- --lib
cargo mutants --package tablepro-core --file crates/core/src/sql_lex.rs --test-tool cargo -- --lib
```

Prefer `core` and `policy`. GitHub's Linux test quality workflow mutates `core`, `policy`, `ssh`, Redis and selected PostgreSQL decoders. The Forgejo nightly also mutates `agentd`, `transport` and `app-services`; agentd mutations run against its library, binaries and integration tests, including saved-connection lookup. Forgejo compares missed mutants with per-package baselines and fails on unaccepted survivors; GitHub reports survivors for review. The PostgreSQL mutation job covers numeric, array, temporal and binary-text decoders with unit tests; Docker-backed value regressions stay in the driver layers. Follow [ADR 0007](decisions/0007-type-and-value-preservation.md) and the [B3 board](type-contract-strategy.md). Equivalent mutants and timeout findings are discussed in the archived first-run notes above.

### Coverage

```bash
cargo install cargo-llvm-cov --locked
rustup component add llvm-tools-preview
cargo llvm-cov --workspace --exclude tablepro-driver-duckdb --exclude tablepro-app \
  --lib --bins --tests --summary-only
```

Exclude app and fixture tiers so the map does not depend on Docker or a display. Coverage shows execution, not assertion quality.

## Upstream test-suite parity

The [September adoption record](archive/testing-history.md#upstream-test-suite-parity) preserves the original cases and counts. Current case candidates and ownership are in [the scenario survey](archive/b3-test-scenario-survey.md) and the B3/B4 boards. Competitor issue-derived checks are hypotheses, not confirmed BookiE defects; the open checklist is in [#790](https://github.com/cozyGarage/BookiE/issues/790). Reproduce a candidate against current source before changing it; a historical claim of zero tests does not establish a current coverage gap.

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
