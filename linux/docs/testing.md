# Testing

Three layers, three tools. Each crate's test policy follows from its position in the dependency graph.

| Crate | Layer | Tools | Required for merge? |
|---|---|---|---|
| `core` | Pure traits + types | Unit tests in `src/`, table-driven for type mappers | Yes |
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

The cases every engine runs: a created table is listed with its key, a query bound times out within its deadline, a cancelled editor run reports it and leaves the session ready, a read-only connection refuses writes, a write batch commits every step and a failed one ends as the driver's atomicity says, a row guard mismatch applies nothing, `close` is idempotent, and `stream_read` streams every row in bounded batches.

Each flag adds cases and needs its engine trait:

| Flag | Adds | Needs |
|---|---|---|
| `endpoint: network` | a dropped caller stops the server's statement; a lost transport reports `ConnectionLost` | `NetworkConformanceEngine` |
| `pool: pooled` | a probe succeeds while every pool slot is busy | `PooledConformanceEngine` |
| `editor_transactions: true` | the row limit keeps the transaction and the statements after it | `EditorTransactionEngine` |
| `unsupported_types: true` | an unsupported type never decodes as NULL | `TypedConformanceEngine` |
| `bounded_ddl: true` | a schema-change batch is not cut off by the statement timeout | `BoundedDdlEngine` |

A flag that is off emits no test. `suite_flags_match_driver_capabilities` is always emitted and never ignored: it fails when `endpoint` or `editor_transactions` disagrees with the driver's `DriverCapabilities`, so a driver cannot skip a case by declaring less. `docker: true` marks every other case `#[ignore = "requires docker"]`; SQLite passes `docker: false` and `endpoint: file`, so its suite runs in the unit suite.

Each case starts its own engine, then has two minutes (`CASE_LIMIT`) to finish. A driver that ignores a deadline or a cancel fails the case with its name instead of holding the test run.

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

`.config/nextest.toml` puts each driver's tests in a test group with one thread, so the tests of one suite never compete for a container. The `ci` profile writes a JUnit report to `target/nextest/ci/junit.xml` and kills a test that runs past five minutes, so a hang fails with the test's name.

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

- `drain_main_context()` runs pending main-loop sources. `wait_until(timeout, condition)` iterates the main loop until the condition holds or the timeout passes, so a missing signal fails the test instead of hanging it.
- `SignalLog::connect(object, signal, extract)` records emissions and disconnects when dropped.
- `descendants`, `find_by_action_name` and `first_descendant_of_type` walk a widget tree.
- `assert_labelled(widget)` checks that a screen reader can name a control:
  - an `adw::PreferencesRow` needs a non-empty title;
  - an `adw::EntryRow` or `adw::PasswordEntryRow` must keep its inner text field labelled by that title;
  - an `adw::ActionRow` with an activatable widget must keep that widget labelled;
  - any other widget, such as an icon-only button or a bare entry, needs an accessible label or a labelled-by relation.

CI sets `GTK_A11Y=test` so results never depend on an AT-SPI bus. With `GTK_A11Y=none`, GTK records no accessible properties and `assert_labelled` returns `TestBackendMissing` instead of a wrong verdict.

Policy:

- Pure logic: extract to `app::services::<thing>` and write plain unit tests.
- Widgets the app builds: a `#[gtk4::test]` that constructs the widget, drives it through its actions or signals, checks the result, and runs `assert_labelled` on the controls a user reaches.
- UI changes still carry before and after screenshots in the PR description.

## End-to-end test

There is no app-level end-to-end test yet. Driving the GTK app under `xvfb-run` through its registered `gtk::Application` actions is the intended shape when we add one.

## CI

GitHub Actions (`.github/workflows/build-linux.yml`), Ubuntu runner:

1. **Fast checks**: `meson setup`, `cargo fmt --all -- --check`, clippy with and without default features, `meson compile`, `xvfb-run -a dbus-run-session -- meson test --print-errorlogs`, a Secret Service step under `gnome-keyring-daemon`, then `meson dist`. Runs in an `ubuntu:26.04` container, which ships GLib 2.88 plus the meson, appstream and desktop-file-utils packages. [CONTRIBUTING.md](../CONTRIBUTING.md#fast-job-commands) lists the same commands.
2. **Docker tests**: runs after fast checks pass. One matrix entry per package with docker tests (the PostgreSQL, MySQL, SQL Server and ClickHouse drivers, `tablepro-ssh` against an OpenSSH server container, and `tablepro-test-fixtures` for the fixtures themselves) runs that package's ignored docker tests through cargo-nextest on the host runner's Docker. `tablepro-session` builds storage, which needs GLib 2.88, so its job runs in the fast job's `ubuntu:26.04` image with the host's Docker socket mounted.

A Translations job also checks `po/POTFILES.in` and extracts the POT template. PRs only merge when every job is green.

## Coverage

Tracked with `cargo-llvm-cov` once the codebase has substance. No hard coverage threshold; coverage is a discussion aid, not a gate.

## Mocking

Avoid mock objects. We do not mock drivers, the filesystem, or `tokio::time`. Either use a real implementation (testcontainers, `tempfile`, `tokio::time::pause`) or extract the logic to a pure function and test that.

If a test cannot be written without a mock, the design is wrong. Refactor before writing the mock.
