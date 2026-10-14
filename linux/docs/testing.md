# Testing

Three layers, three tools. Each crate's test policy follows from its position in the dependency graph.

| Crate | Layer | Tools | Required for merge? |
|---|---|---|---|
| `core` | Pure traits + types | Unit tests in `crates/core/src/`, table-driven for type mappers | Yes |
| `storage` | Filesystem + libsecret + GSchema | Unit tests + integration tests with `tempfile` | Yes |
| `session` | Sessions, connect, health | Unit tests with the `fakes` feature + `testcontainers-rs` tests | Yes |
| `drivers/<engine>` | Real engines | Unit tests, the conformance suites, `testcontainers-rs` integration tests | Yes |
| `app` | GTK 4 widgets | `#[gtk4::test]` widget tests; pure logic is unit-tested | Yes |

## Unit tests

In-crate, in `#[cfg(test)] mod tests` next to the code they cover. Standard Rust idiom.

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn verify_full_is_default() {
        let form = ConnectForm::new("postgres", drivers_postgres::PgDriver.capabilities());

        assert_eq!(form.tls.mode, TlsMode::VerifyFull);
    }
}
```

Run every test that needs no external service through meson, which sets the
environment each suite needs:

```bash
meson setup _build -Dprofile=development
dbus-run-session -- meson test -C _build --print-errorlogs
```

Three suites: `unit` is `cargo test --workspace --exclude tablepro`, `gtk`
is `cargo test -p tablepro` with `GSK_RENDERER=cairo` and `GTK_A11Y=test`,
and `data` runs `desktop-file-validate`, `glib-compile-schemas --strict` and `appstreamcli validate`.
Tests that need Docker or a Secret Service are ignored. Without a display
(SSH, containers), prefix with xvfb the way the CI fast job does:

```bash
xvfb-run -a dbus-run-session -- meson test -C _build --print-errorlogs
```

For a single crate, `meson devenv -C _build cargo test -p <crate>` runs
Cargo with the same environment.

## Integration tests

Per-crate `tests/` directory. One file per scenario.

For `storage`, integration tests use `tempfile::TempDir` to run against an isolated filesystem root, with `XDG_CONFIG_HOME` overridden via env var.

For drivers, integration tests use [`testcontainers`](https://docs.rs/testcontainers/latest/testcontainers/) through the fixtures in `tablepro-test-fixtures`. Each driver's `tests/integration/support.rs` turns a fixture into `ConnectOptions` and a connected `Connection`:

```rust
use tablepro_core::meta::{ObjectKind, ObjectScope};

use crate::support::{CALL, connect, setup, start, within};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_created_table_is_listed() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(connection.as_ref(), &["CREATE TABLE plain (id int)"]).await;

    let objects = connection
        .list_objects(&ObjectScope::DefaultSchema, within(CALL))
        .await
        .expect("the objects");

    assert!(objects.iter().any(|object| object.name == "plain" && object.kind == ObjectKind::Table));
}
```

Keep the fixture alive for the whole test: dropping it stops the container.

### Container fixtures

`crates/test-fixtures` (`tablepro-test-fixtures`) holds the containers that need more than a default image: a generated PKI, TLS turned on in the engine's own config format, and OpenSSH servers with a chosen auth method. It is a dev-dependency only and depends on no other TablePro crate.

`TestPki::generate()` writes `ca.pem`, `unrelated-ca.pem`, `server.pem`, `server.key`, `client.pem` and `client.key` to a `TempDir`, private keys at 0600. The server certificate carries SANs `localhost` and `db.tablepro.test` and no IP SAN, so verifying against `127.0.0.1` is a name mismatch. The client certificate's CN is `tablepro_client`, which PostgreSQL `cert` auth matches against the role name.

Every TLS fixture has two principals:

- `password_credentials()`: user `tablepro`, which the server forces onto TLS (`ALTER USER ... REQUIRE SSL`, `hostssl ... scram-sha-256`, `require_secure_transport=ON`).
- `certificate_credentials()`: user `tablepro_client`, which authenticates with the client certificate (`REQUIRE X509`, pg_hba `cert`, ClickHouse `ssl_certificates`).

SQL Server has only the `sa` principal, because its TLS contract carries no client identity.

`HbaMode` picks what the PostgreSQL fixture accepts: `Password` (the image defaults, no TLS), `HostSslOnly`, or `ClientCertificate`. `OpenSshFixture` takes an `SshAuthVariant`: `Password`, `PublicKey`, `KeyboardInteractive` or `HostCertificate`. `HostKeyRevocation` builds a KRL from the running server's host key, and `ScriptedAskpass` writes a 0700 script for `SSH_ASKPASS`.

### Conformance

Every driver runs the same contract tests against its real server. `tablepro_test_support::connection_conformance_suite!` emits them from an engine adapter the driver's `tests/integration/conformance_engine.rs` implements (`ConformanceEngine`: how to start the server, connect, and spell a scratch table, a statement that never ends and a row source):

```rust
tablepro_test_support::connection_conformance_suite! {
    engine: PgEngine,
    docker: true,
    endpoint: network,
    pool: pooled,
    editor_transactions: true,
    unsupported_types: true,
    bounded_ddl: true,
}
```

The cases every engine runs: a created table is listed with its key, a query bound times out within its deadline, a cancelled editor run reports it and leaves the session ready, a read-only connection refuses writes, a write batch commits every step and a failed one ends as the driver's atomicity says, a row guard mismatch applies nothing, `close` is idempotent, a commit the engine keeps no record of resolves as `Unresolvable`, and `stream_read` streams every row in bounded batches.

Each flag adds cases and needs its engine trait:

| Flag | Adds | Needs |
|---|---|---|
| `endpoint: network` | a dropped `query_bound` caller or editor run stops the server's statement, and the editor session then runs again or reports `Lost`; a lost transport reports `ConnectionLost` | `NetworkConformanceEngine` |
| `endpoint: file` | a dropped editor run stops, and the session takes the next run within the cancel grace | `ConformanceEngine` |
| `pool: pooled` | a probe succeeds while every pool slot is busy | `PooledConformanceEngine` |
| `editor_transactions: true` | the row limit keeps the transaction and the statements after it | `EditorTransactionEngine` |
| `unsupported_types: true` | an unsupported type never decodes as NULL | `TypedConformanceEngine` |
| `bounded_ddl: true` | a schema-change batch is not cut off by the statement timeout | `BoundedDdlEngine` |

A flag that is off emits no test. `suite_flags_match_driver_capabilities` is always emitted and never ignored: it fails when `endpoint` or `editor_transactions` disagrees with the driver's `DriverCapabilities`, so those cases cannot be skipped by declaring less. `pool`, `unsupported_types` and `bounded_ddl` have no capability behind them: they describe the server, and MySQL and MariaDB differ on `bounded_ddl` under one driver, so the adapter states them and review checks them. `docker: true` marks every other case `#[ignore = "requires docker"]`; SQLite passes `docker: false` and `endpoint: file`, so its suite runs in the unit suite.

Each case starts its own engine, then has two minutes (`CASE_LIMIT`) to finish. A driver that ignores a deadline or a cancel fails the case with its name instead of holding the test run.

### DDL conformance

`ddl_conformance_suite!` runs the structure tab's own plans against the server. The adapter implements `ConformanceDdlEngine` on top of `ConformanceEngine`: the engine's integer, text and timestamp types, its current-timestamp expression, and, for an engine whose `DdlDialect` creates no tables (ClickHouse), a CREATE TABLE of its own.

```rust
tablepro_test_support::ddl_conformance_suite! {
    engine: PgEngine,
    docker: true,
}
```

Every case plans through `connection.dialect().ddl()` and runs the plan with `write_batch`:

- `ddl_plans_apply_and_read_back` creates a table with a quoted literal default and an expression default, then adds, renames and drops a column, changes its nullability and default, adds an index and a foreign key, renames the table, which has to stay listed in its own schema, and drops the tables. After each step `fetch_table_definition` has to match the draft. A step the dialect refuses has to be refused by its plan as well, with a reason, so no step is skipped without a check. Once the foreign key exists, the referenced primary key has to read as held by it.
- `failed_ddl_batch_outcome_matches_ddl_atomicity` sends two plans whose second statement the server rejects, and checks the outcome against `ddl_writes`: `RolledBack` and nothing applied, or `PartiallyApplied` and the first plan applied.
- `create_table_script_recreates_the_table` drops a table and runs its `create_table_script`, which has to bring back the same column definitions and index keys.
- `structure_changes_keep_rows_and_indexes` fills an indexed table, then changes a default and a nullability. The rows and the index have to come through, which on SQLite means through the table rebuild.

The PostgreSQL, MySQL, SQL Server, ClickHouse and SQLite targets run it, and the MySQL target runs it on MariaDB as well. SQLite passes `docker: false`, so its cases run in the unit suite.

### TLS conformance

Every network driver also runs `tls_conformance_suite!` against a TLS-only server built from `TestPki`:

```rust
tablepro_test_support::tls_conformance_suite! {
    engine: PgTlsEngine,
    client_identity: true,
}
```

The adapter (`TlsConformanceEngine`) gives the issuing and the unrelated CA file, the name on the server certificate and the error category a plaintext connect gets. The cases: Verify full with the issuing CA connects; with an unrelated CA it reports `UnknownIssuer`; with the wrong server name it reports `NameMismatch`; Require connects without a CA; Disable against the TLS-only server is refused. `client_identity: true` adds a case where the server requires the client certificate, through `ClientIdentityEngine`; SQL Server passes `false`. Every case needs Docker, and `tls_suite_flags_match_driver_capabilities` checks the flag against the driver's TLS capabilities without it.

### Ignore reasons

Two reasons are allowed:

- `#[ignore = "requires docker"]` for testcontainers suites.
- `#[ignore = "requires a Secret Service"]` for tests that talk to a keyring.

The workspace denies `clippy::ignore_without_reason`, so a bare `#[ignore]` fails the build.

### Running the docker tests

CI runs one job per package with docker tests:

```bash
cargo nextest run --locked --profile ci -p tablepro-driver-mssql --run-ignored only
```

`.config/nextest.toml` puts each package's docker tests in a test group with one thread, so the tests of one suite never compete for a container. The `ci` profile writes a JUnit report to `target/nextest/ci/junit.xml` and kills a test that runs past five minutes, so a hang fails with the test's name.

Locally, with [cargo-nextest](https://nexte.st/) installed:

```bash
cargo nextest run -p tablepro-driver-postgres --run-ignored only
```

meson and distro builds use cargo test, which works too:

```bash
cargo test -p tablepro-driver-postgres -- --ignored --test-threads=1
```

### Docker or Podman

Upstream CI uses Docker. Fedora ships Podman instead, and on Debian it is the easier install; either way, point testcontainers at Podman's rootless socket:

```bash
sudo dnf install -y podman   # or: sudo apt install -y podman
systemctl --user enable --now podman.socket
export DOCKER_HOST=unix:///run/user/$(id -u)/podman/podman.sock
cargo nextest run -p tablepro-driver-postgres --run-ignored only
```

Do not bother with `TESTCONTAINERS_RYUK_DISABLED`. That is a testcontainers-java / go setting; the Rust crate has no Ryuk reaper and stops each container when its handle drops.

`curl --unix-socket "${DOCKER_HOST#unix://}" http://localhost/_ping` should print `OK` before you run the suite. `--unix-socket` takes a filesystem path, so the `unix://` prefix has to come off.

A test that panics hard can still leave a container behind. `podman container prune` clears them.

### Regression names

A test that guards a critical audit finding starts with the finding id, `f001_` to `f006_`. `cargo test --workspace -- f001_` runs the guards for that finding.

## App / UI tests

GTK code is tested with `#[gtk4::test]`, which runs each test on a single GTK thread after `gtk::init`. Pure logic still belongs in `app::services` with plain unit tests.

Helpers live in `crates/app/src/test_support`, compiled only for tests:

- `drain_main_context()` runs pending main-loop sources. `wait_until(timeout, condition)` iterates the main loop until the condition holds or the timeout passes, so a missing signal fails the test instead of hanging it. `finish_on_main(timeout, future)` runs a future on the main context and gives it up at the timeout.
- `SignalLog::connect(object, signal, extract)` records emissions and disconnects when dropped.
- `descendants`, `find_by_action_name` and `first_descendant_of_type` walk a widget tree.
- `MemorySettings` compiles the schema into a `TempDir` behind the memory backend, so a test never touches the developer's dconf database.
- `FakeSession` is a session over a fake connection; `FakeClocks` and `FakeProbe` stand in for the suspend clocks and the reachability check.
- `KeyInjector` presses real keys through XTEST, so a test meets every capture, class and bubble handler in the order GTK runs them. It needs an X11 display, which is why the gtk suite sets `GDK_BACKEND=x11`; `focus_only` first closes any window an earlier test left open. Such a test goes in a `real_keys` module, which nextest runs with no other test beside it, since a window another test presents takes the keyboard focus.
- `shortcut_keys` reads the keys a controller or a widget class binds, for the accelerator table's collision tests.
- `assert_labelled(widget)` checks that a screen reader can name a control:
  - an `adw::PreferencesRow` needs a non-empty title;
  - an `adw::EntryRow` or `adw::PasswordEntryRow` must keep its inner text field labelled by that title;
  - an `adw::ActionRow` with an activatable widget must keep that widget labelled;
  - any other widget, such as an icon-only button or a bare entry, needs an accessible label or a labelled-by relation.
- `unlabelled_icon_buttons(root)` lists the icon-only buttons under `root` that a screen reader reaches and cannot name, and `tooltips_with_keys(root)` the tooltips that spell out a key, which belongs on the accessible node. `ui::a11y::tests` walks every template in the GResource: an icon-only button the template does not label needs an id, and a label once its class is built, which is where `describe_icon_button` gives it one.

CI sets `GTK_A11Y=test` so results never depend on an AT-SPI bus. With `GTK_A11Y=none`, GTK records no accessible properties and `assert_labelled` returns `TestBackendMissing` instead of a wrong verdict.

Two harnesses build the app's real objects over fakes:

- `TestWindow` (`crates/app/src/ui/session_window/tests.rs`) starts a `TableProApplication` with one window on the picker, a saved connection in its list and a `FakeConnector`. `TestWindow::connected` opens that connection and waits for its workspace. Each test registers an application id of its own, so it never meets another test, or a TablePro the developer has open, on the session bus. `test.hold` is the application's `CountingHold`.
- `workspace::test_workspace::Workspace` builds a `WorkspaceHandle` with one tab over a scripted connection, for the save and close prompt tests.

Both turn GTK animations off, so a dialog or a page change finishes before the next line runs.

### Background work and time

A `#[gtk4::test]` has no tokio runtime. `test_runtime()` builds an `AppRuntime` the test owns, and its `tasks()` go to the code under test. A `#[tokio::test]` gets the `Tasks` of its own runtime from `paused_tasks()`, and with `start_paused = true` tokio's clock stands still and jumps to the next timer whenever every task is waiting, so a test of a deadline, a backoff or a debounce runs in no time and never flakes on a slow runner. The session crate's tests use the same pattern for the health monitor, the catalog and the operation runner.

### Holds

`CountingHold` (`tablepro_session::runtime`) is the test `ProcessHold`: it counts live tokens. A test that work holds the process checks that `live()` is 1 while the work runs and 0 once it ends, and that the work's effect is in place before the count drops.

### Dialogs

- `workspace::answer(window, response)` clicks the button of the alert `window` shows, so the alert closes itself and emits its response in the order a user's click does. `workspace::visible_alert(window)` returns that alert.
- `test_support::respond(dialog, response)` clicks the button of a presented alert the test holds. Never emit `response` by name: that skips the close a click makes first, so a `closed` handler sees the signals in an order no user can produce.

A test that a step logs no GLib critical turns criticals fatal around that step and restores the old mask after:

```rust
let previous = glib::log_set_always_fatal(glib::LogLevels::LEVEL_CRITICAL);
let answered = crate::workspace::answer(&test.window, "reset");
crate::test_support::drain_main_context();
glib::log_set_always_fatal(previous);
```

A critical then aborts the process with the message, for example libadwaita's "Trying to close AdwAlertDialog ... that's not presented". cargo-nextest runs each test in a process of its own, so it reports that one test as failed. `cargo test`, which the Meson `gtk` suite runs, has every test of the `tablepro` library in one process: the abort ends the whole binary and the tests after it never run.

### Fakes

`tablepro-test-support` holds the driver contract's fakes, which every crate's tests share: `FakeDriver`, `FakeConnection` scripted through `ConnectionScript`, `FakeEditorSession` with `FakeRun`, `FakeSecretVault`, `FakePrompter` and `FaultTransport`. A `FakeReply` answers at once, after a delay unless the deadline or cancel comes first, late whatever the caller asked, only once stopped, or never. `CallCounters` counts the calls a connection received after it was handed over. `tablepro_session::fakes` adds `FakeConnector` and `FakeCredentialSource` behind the session crate's `fakes` feature, which only the app's dev-dependencies turn on.

### Application tests

The tests in `crates/app/tests` that start TablePro run without the test harness (`harness = false` in `crates/app/Cargo.toml`): GTK allows one application per process, on its main thread. Each binary has its own `main` and runs TablePro in child processes. The ones that talk to it over D-Bus give it a private session bus through `gio::TestDBus`, so a TablePro the developer has open never answers.

| Test | What it checks |
|---|---|
| `application_uniqueness` | a second plain launch activates the running instance and exits without opening a window, and `--new-window` opens one there |
| `application_lifecycle` | Quit waits for a session's close within the close timeout and gives up on a close that hangs, a cancelled close keeps the app running, and an editor session's close holds the process |
| `application_session_restore` | the windows open at quit open again at the next launch, and a window closed first does not |
| `open_files` | a file handed over D-Bus opens a window on it, the same file brings that window forward, and another file opens a second window |
| `startup`, `i18n_catalog`, `logging` | the command-line options, a missing schema, the translation catalogue and the log setup |

They need a display and a session bus, so run them the way CI does:

```bash
xvfb-run -a dbus-run-session -- meson test -C _build --suite gtk --print-errorlogs
```

or one at a time, `xvfb-run -a dbus-run-session -- meson devenv -C _build cargo test -p tablepro --test application_lifecycle`. `startup` needs the build Meson configures, so it fails under plain Cargo. cargo-nextest asks each test binary to list its tests, which a harness-free binary does not do, so run these with `cargo test`.

Policy:

- Pure logic: extract to `app::services::<thing>` and write plain unit tests.
- Widgets the app builds: a `#[gtk4::test]` that constructs the widget, drives it through its actions or signals, checks the result, and runs `assert_labelled` on the controls a user reaches.
- A flow across windows or launches: an application test.
- UI changes still carry before and after screenshots in the PR description.

## Scripts, the editor and structure review

### The script planner

`crates/core/tests/script_corpus.rs` holds the planner's fixtures, by grammar:

- A named case for each rule an engine's client follows: dollar quotes and `BEGIN ATOMIC` bodies, a procedure with `DELIMITER` and one without, trigger bodies, `GO` with a count, heredocs, `#` and `//` comments, backslash escapes with the setting on and off, and text left open, which keeps the statements before it.
- `lexer_matches_sqlparser_where_engines_agree` checks the semicolons the lexer finds in `AGREED_CASES` against sqlparser's tokenizer, on cases where sqlparser reads the text as the engine does.
- A proptest runs every grammar over random text with multibyte characters: the tokens cover the text with no gap, every range ends on a character boundary, and batches never overlap.

`crates/drivers/sqlite/tests/script_plan_matches_sqlite3_complete.rs` checks every prefix of a SQLite corpus against SQLite's own `sqlite3_complete`. A new rule gets a named case, and a place in `AGREED_CASES` when sqlparser reads it the engine's way.

The real servers run scripts in tests ignored with `requires docker`: MySQL and MariaDB create a trigger and procedures with and without `DELIMITER` (`create_trigger_and_procedure_in_session`), SQL Server runs `GO` batches past a failed one (`go_batches_run_in_order_and_continue_after_an_error`), and PostgreSQL splits with backslash escapes once `standard_conforming_strings` is off (`standard_conforming_strings_off_splits_with_backslash_escapes`).

### The editor

Editor tests run on a `FakeEditorSession` scripted with `Replies<FakeRun>`, never a server:

- `FakeRun::completed` streams the events it is given, `failed` ends in a statement the server refused, `session_error` fails the session itself (`EditorSessionBusy`, a lost connection), and `until_stopped` ends only at a cancel or the deadline. `taking` adds a delay, and `leaving` sets the `TransactionState` the run leaves.
- `Replies::when_sql_contains` ties an answer to a statement, so a test can fail the third of five.
- `texts` returns what each run was sent, so a test asserts the split itself, such as `GO 2` sending its batch twice. `stopped_runs` counts the runs a cancel or a timeout ended, and `close_count` the closes.
- The fake keeps the session's rules: a run while another runs gets `EditorSessionBusy`, and a lost session stays lost.

The tests in `crates/app/src/ui/editor/script_runner.rs` drive `run_batches` under tokio and fold its events into a `RunLog`. The widget tests in `crates/app/src/ui/editor/tests.rs` build a `SqlEditor` over a `Session` whose `ConnectionScript` hands out the fake from `open_editor_session`, run it, wait until `is_running` is false, then check the results list, the transaction label, the history and what was sent.

### Structure review

`crates/app/src/workspace/structure_review_tests.rs` saves a structure tab through `WorkspaceHandle::save` on the `workspace::test_workspace::Workspace` harness and answers the review with `workspace::answer`. A dropped column shows the review with its SQL, Cancel sends nothing, Apply runs one write batch, an additive save on an engine that applies DDL in one transaction starts without a review, a draft changed during the review is not saved, and a second save during the review opens no second one. The close guard's own tests check that its Save reviews too, and that a declined review keeps the window open with no alert and starts none of the saves after it.

## CI

GitHub Actions (`.github/workflows/build-linux.yml`), Ubuntu runner:

1. **Fast checks**: `meson setup`, `cargo fmt --all -- --check`, clippy with and without default features, `meson compile`, `xvfb-run -a dbus-run-session -- meson test --print-errorlogs`, a Secret Service step under `gnome-keyring-daemon`, then `meson dist`. Runs in an `ubuntu:26.04` container, which ships GLib 2.88 plus the meson, appstream and desktop-file-utils packages. [CONTRIBUTING.md](../CONTRIBUTING.md#fast-job-commands) lists the same commands.
2. **Docker tests**: runs after fast checks pass. One matrix entry per package with docker tests (the PostgreSQL, MySQL, SQL Server and ClickHouse drivers, `tablepro-ssh` against an OpenSSH server container, and `tablepro-test-fixtures` for the fixtures themselves) runs that package's ignored docker tests through cargo-nextest on the host runner's Docker. `tablepro-session` builds storage, which needs GLib 2.88, so its job runs in the fast job's `ubuntu:26.04` image with the host's Docker socket mounted. The app's docker tests (`crates/app/tests/tracker_save_postgres.rs`) run the same way, since the app links GTK; that job names its test targets, because the app's `startup` test needs Meson.

A Translations job also checks `po/POTFILES.in` and extracts the POT template. PRs only merge when every job is green.

## Coverage

Tracked with `cargo-llvm-cov` once the codebase has substance. No hard coverage threshold; coverage is a discussion aid, not a gate.

## Mocking

Avoid mock objects. We do not mock drivers, the filesystem, or `tokio::time`. Either use a real implementation (testcontainers, `tempfile`, `tokio::time::pause`) or extract the logic to a pure function and test that. The fakes in `tablepro-test-support` are not mocks: they implement the driver contract and keep its rules, so the code under test meets what a conforming driver does, and each real driver runs the conformance suites against its own server.

If a test cannot be written without a mock, the design is wrong. Refactor before writing the mock.
