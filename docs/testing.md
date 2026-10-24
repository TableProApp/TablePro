# Testing

The [completion page](bookie-0.2-sprint.md) records 0.2.0 delivery status; current issue acceptance belongs to the owning boards. Start with the [validation playbook](validation-playbook.md) for the executable layer catalog, local commands, CI ownership, agent handoffs and regression intake. Dated audits in [archive](archive/) prove only their recorded source and environment.

Design rules distilled from past audits (test ownership, runner parsers, oracles, changing a guard) are in [test design rules](test-design-rules.md).

## Executable gates

`scripts/ci-local.sh` remains the shared local/CI entry for full, widgets and integration modes. Registrations for isolated GTK and keyring tests live in `scripts/isolated-tests.json`; zero selected tests is a failure. Each run saves its HEAD, worktree status, tracked diff digest, untracked input paths and digest, tool versions and logs under `target/quality/`. The runner hashes non-ignored untracked file paths and contents; Git-ignored build outputs are excluded. A clean tree skips the untracked scan. Reports still do not archive untracked file contents, so commit tested changes before handing them off for exact-source acceptance. Release mode does not certify package installation, Wayland, upgrade/rollback or retry-free candidate soak. See the [packaging guide](../apps/linux/packaging/README.md) and [manual checklist](manual-verification-0.2-features.md).

The script harness checks selected documented Rust declarations against source and generates the gettext template in memory and fails if extraction breaks. The template (`bookie.pot`) and `POTFILES.in` are build outputs, ignored by git; run `python3 scripts/update-translations.py` to write them. The catalog check needs GNU `xgettext` and does not load GTK GIR bindings or a desktop session.

`scripts/validate-evidence.py` distinguishes `run-test-layer.py` execution reports from evidence manifests. It checks a report's commit, worktree field, tracked-diff digest and any untracked-input paths and digest. It does not treat a dirty report as a clean checkout or rewrite its provenance. Durable evidence manifests keep their separate `source_commit` or `base_commit` contract.

## What a container run proves

Database fixtures, the GTK scenarios and the distro-floor jobs run in containers or virtual displays. A pass there shows the code behaves as designed against a disposable database; it is not acceptance of a connection path. Unix sockets, IPv6 loopback, desktop portals and the Secret Service behave differently across containers and desktop sessions; a container run has already hidden one such difference (Docker does not publish `::1`). Acceptance for those paths is the installed package connecting to a real database in the target native desktop session, on the host or a supported VM, as recorded under PKG-1 and in the [manual checklist](manual-verification-0.2-features.md).

## Remote lab and connection-fault checks

Use a separate BookiE profile and disposable database or dataset when checking a workstation-to-lab connection. Route only that profile through a TCP fault proxy such as Toxiproxy to test added latency, timeouts, and dropped connections. Do not use host-wide network fault rules for this; they can disrupt unrelated SSH, CI, and development traffic. The PostgreSQL release fixture already uses Toxiproxy for deterministic proxied-path tests.

A proxy fault checks BookiE's response to a broken network path; it does not test cluster election or replication. Test real failover only in an isolated cluster using its documented failover procedure. A write whose response is lost may already have committed, so verify the stored result and ensure reconnect does not replay it. Keep such checks on disposable data.

## Why B3 tests values beyond the driver

B3 covers the value path from the native driver through each relevant consumer, such as result display, grid editing, parameter binding, and export. Driver decoding alone cannot show that later code preserves the value. JSON or formatted text can display a value while hiding distinctions such as BSON integer width, exact decimal precision, or SQL `NULL` versus an empty value. This does not imply that another database client loses those distinctions; a correct-looking display alone does not establish round-trip fidelity.

[ADR 0007](decisions/0007-type-and-value-preservation.md) defines the outcomes: exact typed support, exact text fallback, explicit refusal, or untested. B3 is a data-correctness contract, not a requirement for one universal cross-engine type system. Use the selected case and its concrete consumer to decide what must be proven.

## Test runner

The sandbox tier selects `--test '*'` so every integration target in its crate list is discovered, including new files. Library and binary unit tests belong to the unit tier; Cargo's broader `--tests` flag also selects those targets and would execute them twice.

The unit and sandbox tiers run under [cargo-nextest](https://nexte.st), one process per test. `scripts/ensure-nextest.sh` downloads the pinned release, checks its SHA-256 and caches it under `~/.cache/bookie-tools` locally or the configured shared tools cache in CI; `.config/nextest.toml` requires that version. Both profiles keep `retries = 0`, so a flaky test fails instead of passing on a hidden retry, and stop a test that runs for five minutes. The `ci` profile also writes `target/nextest/ci/junit.xml`. The completed [#892 pilot](https://github.com/cozyGarage/BookiE/issues/892) qualified the unit and sandbox selections. Compare test names and source revisions rather than copying historical totals; parent-launched subprocess helpers can affect displayed counts. Driver, release, GTK and keyring tiers remain on `cargo test`. Moving a shared database fixture to one process per test requires separate ownership and isolation qualification; the headless pilot did not qualify that migration. `scripts/ci-local.sh full` runs its unit tier through the same nextest command as the Forgejo `unit` job, so local CI and CI use one runner. Doc tests are not part of these tiers.

Container images are not part of that retry rule: a dropped image download is not a flaky test. The Forgejo `driver` and `driver-tls` jobs, and the GitHub `Fast checks (GTK)` job before its app-server tests, run `scripts/prepull-test-images.sh <group>`, which pulls the images listed for that group in `ci/test-images.txt` (skipping any already on the host) with three attempts and a growing pause, and fails the step naming the image if none works. Each group must list exactly the images its tests start, including the default image a testcontainers module uses when a test sets no tag; `scripts/tests/test_prepull_test_images.py` fails when a group and its tests differ. When you add a fixture or change an image tag, update the group in the same change.

## Local checks and fixtures

Select Cargo test targets deliberately: `tablepro-app` puts UI and service tests in the `tablepro_app` library, while `agentd` has library, binary and integration tests. DuckDB stays out of the default gate because its optional native build is large. Contributor lint and test-target rules live in [AGENTS.md](../AGENTS.md).


`scripts/test-harness.sh` checks `apps/linux/packaging/THIRD_PARTY_NOTICES.md` with `cargo-about`, and it takes that tool from `scripts/ensure-cargo-about.sh` the same way: the pinned 0.9.2 release, its SHA-256 checked, cached beside nextest. It ignores any `cargo-about` already on `PATH`, because the notices are generated by that exact version and another one produces different license text. Arch's packaged 0.8.4, for example, makes the check report the notices as stale when they are not. On a machine other than x86_64 Linux, install 0.9.2 yourself and set `CARGO_ABOUT` to it.

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
| An expired MCP token never authenticates | `an_expired_token_is_refused` | `crates/mcp/src/tokens.rs` |
| Only the token hash is stored; the plaintext never reaches the token file or Debug output | `the_token_file_and_debug_never_hold_the_plaintext` | `crates/mcp/src/tokens.rs` |
| Every MCP tool refuses a connection outside a non-empty allowlist before opening one | `every_tool_refuses_a_connection_outside_a_nonempty_allowlist` | `crates/mcp/tests/enforce_policy.rs` |
| The MCP HTTP body is bounded by the same limit as stdio | `an_http_body_over_the_request_limit_is_refused` | `crates/mcp/src/server.rs` |
| Every audited read ends in exactly one terminal outcome, on success and failure, controlled or not | `every_audited_read_ends_in_exactly_one_terminal_outcome`, `no_read_under_a_cancelled_control_writes_two_outcomes` | `crates/policy/src/guard_tests_passthrough.rs` |
| An undecodable value stays visible and distinct from NULL in every export format and in copy; SQL export refuses it | `value_contract_every_export_keeps_undecodable_distinct_from_null` | `crates/core/src/export/stream_tests.rs` |

Add a row here when you add a guardrail.

## Storage tests

Storage tests use temporary directories and explicit file paths for JSON and audit behavior. Query-history tests use SQLite. The Secret Service round-trip test is ignored by default because it needs a keyring. `scripts/test-secret-service.sh` always creates an isolated D-Bus/keyring session, even when invoked from a desktop session. It first runs the `keyring-fresh` tests against a keyring daemon that has no default collection yet (reading or deleting a missing password must not create one), then unlocks a test keyring for the `keyring` tests.

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

To find UI-thread stalls while profiling or testing by hand, set `TABLEPRO_UI_STALL_MS=50` (any positive number of milliseconds). The app then logs a `UI thread stalled` warning with the stall length whenever the GTK main loop is late by at least that long. It is off by default and logs no content. It reports that a stall happened, not its cause; pair it with a profiler.

Every clickable control on the SQL editor screen must have a registered keyboard path in `apps/linux/app/tests/keyboard_paths.py`: a shortcut, a menu entry, a tab stop, or a `gap:` entry naming what is missing. The GTK scenario `sql_editor_clickables_all_have_a_keyboard_path` fails when a new button appears without an entry. Add an entry rather than widening a pattern.

The Forgejo driver matrix sets `TABLEPRO_TEST_RUN_ID` and runs each complete integration binary serially. PostgreSQL, MySQL and MariaDB fixtures reuse one primary server per engine and recreate the `test` database before each test; filtered and exact selectors start their own server. Deliberate restart tests also start a separate server. So a full-suite runtime estimate should count those cases rather than multiply every test by a database startup.

Disposable PostgreSQL fixtures use tmpfs and disable `fsync`, `synchronous_commit` and `full_page_writes`. MySQL and MariaDB use tmpfs and disable transaction-log, doublewrite and binlog syncing; SQL Server uses tmpfs with writable permissions for its non-root service account. Lost-ack, crash and restart cases use durable containers so they still exercise persistent storage. The Docker tests assert the database settings and mounted filesystem.

These tests require Docker or a compatible Podman API socket. Keep each container handle alive for the full test because dropping it stops the container.

PostgreSQL integration coverage includes controlled cancellation and timeout against a real server. The tests confirm the query appears in `pg_stat_activity`, trigger cancellation or a deadline, confirm the query leaves server activity, and verify that the pool remains usable. Transaction cancellation is followed by rollback and a data check.

## PostgreSQL release fixture

Run the PostgreSQL release fixture with:

```bash
./scripts/test-postgres-release.sh
```

The script generates fixture certificates and SSH keys, starts PostgreSQL 16 with TLS, an OpenSSH bastion, and Toxiproxy, builds the `tablepro-askpass` helper, verifies that agentd refuses an unknown system OpenSSH host key before allowing a guarded PostgreSQL query, then runs `tablepro-release-tests` with `--include-ignored --test-threads=1`. Only Toxiproxy publishes host ports, so the database is reachable through the proxied path or the bastion and either path can be cut during a test.

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

## Manual verification

The [manual checklist](manual-verification-0.2-features.md) records installed GTK workflows and layouts that need visual acceptance. Unit and widget tests do not establish installed desktop behavior. Each unchecked item remains unverified until a result is recorded.

## Regression case selection

The [historical test record](archive/testing-history.md#upstream-test-suite-parity) preserves the original cases and counts. The [scenario survey](archive/b3-test-scenario-survey.md) is a dated source study, not a current backlog; current B3 case status belongs to the board and [value-contract index](value-contracts.md). Failure reports are hypotheses, not confirmed BookiE defects; the active checklist is [#790](https://github.com/cozyGarage/BookiE/issues/790). Trace the matching BookiE path and reproduce a candidate against current source before changing code; a historical claim of zero tests does not establish a current coverage gap.

## File-size guard

`scripts/check-file-size.sh` enforces the Rust source limits recorded in `baselines/file-size-baselines.txt`:

| Limit | Lines | Result |
|---|---:|---|
| Soft | 1200 | Split the file or record an approved baseline |
| Hard | 1800 | Unlisted files fail |
| Ratchet | Recorded maximum | A listed oversized file may not grow past its baseline |

Lower a baseline in the same change when an oversized file shrinks.

When inline unit tests push a production module over the soft limit, move them to a sibling `tests.rs` and declare it with `#[cfg(test)] mod tests;`. Import the parent with `use super::*;` so private behavior stays directly testable without carrying the test bodies in the production file.

## Other test documents

- [GTK tests](testing-gtk.md)
- [CI tests and gates](testing-ci.md)
- [Test quality and performance contracts](testing-quality-and-performance.md)
