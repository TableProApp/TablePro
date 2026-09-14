# Testing

Three layers, three tools. Each crate's test policy follows from its position in the dependency graph.

| Crate | Layer | Tools | Required for merge? |
|---|---|---|---|
| `core` | Pure traits + types | Unit tests in `src/`, table-driven for type mappers | Yes |
| `storage` | Filesystem + libsecret + GSchema | Unit tests + integration tests with `tempfile` | Yes |
| `drivers/<engine>` | Real engines | Unit tests + `testcontainers-rs` integration tests | Yes |
| `app` | GTK4 + Relm4 components | Limited; pure logic in `services/` is unit-tested | No |

## Unit tests

In-crate, in `#[cfg(test)] mod tests` next to the code they cover. Standard Rust idiom.

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_unique_violation_to_query_error() {
        let err = sqlx::Error::Database(/* ... */);
        let mapped = map_sqlx_error(err);
        assert!(matches!(mapped, DriverError::Query { sqlstate: Some(_), .. }));
    }
}
```

Run every test that needs no external service. GTK tests need a display and the GTK test accessibility backend:

```bash
GTK_A11Y=test dbus-run-session -- cargo test --workspace --locked
```

This runs unit tests, GTK tests, doc tests and every test target. Tests that need Docker or a Secret Service are ignored. Without a display (SSH, containers), run the command the CI fast job uses:

```bash
GTK_A11Y=test GSK_RENDERER=cairo xvfb-run -a dbus-run-session -- cargo test --workspace --locked
```

## Integration tests

Per-crate `tests/` directory. One file per scenario.

For `storage`, integration tests use `tempfile::TempDir` to run against an isolated filesystem root, with `XDG_CONFIG_HOME` overridden via env var.

For drivers, integration tests use [`testcontainers`](https://docs.rs/testcontainers/latest/testcontainers/) to spin up a real database. The pattern is identical for every driver:

```rust
use testcontainers::ImageExt;
use testcontainers_modules::postgres::Postgres;
use testcontainers_modules::testcontainers::runners::AsyncRunner;

#[tokio::test]
#[ignore = "requires docker"]
async fn list_tables_returns_seeded_tables() {
    let container = Postgres::default().with_tag("16-alpine").start().await.unwrap();
    let host = container.get_host().await.unwrap().to_string();
    let port = container.get_host_port_ipv4(5432).await.unwrap();

    let conn = PgDriver.connect(opts_for(host, port)).await.unwrap();

    conn.execute("CREATE TABLE foo (id INT)").await.unwrap();
    let tables = conn.list_tables().await.unwrap();
    assert!(tables.iter().any(|t| t.name == "foo"));
}
```

Keep the container alive for the whole test: dropping the handle stops it.

### Container fixtures

`crates/test-fixtures` (`tablepro-test-fixtures`) holds the containers that need more than a default image: a generated PKI, TLS turned on in the engine's own config format, and OpenSSH servers with a chosen auth method. It is a dev-dependency only and depends on no other TablePro crate.

`TestPki::generate()` writes `ca.pem`, `unrelated-ca.pem`, `server.pem`, `server.key`, `client.pem` and `client.key` to a `TempDir`, private keys at 0600. The server certificate carries SANs `localhost` and `db.tablepro.test` and no IP SAN, so verifying against `127.0.0.1` is a name mismatch. The client certificate's CN is `tablepro_client`, which PostgreSQL `cert` auth matches against the role name.

Every TLS fixture has two principals:

- `password_credentials()`: user `tablepro`, which the server forces onto TLS (`ALTER USER ... REQUIRE SSL`, `hostssl ... scram-sha-256`, `require_secure_transport=ON`).
- `certificate_credentials()`: user `tablepro_client`, which authenticates with the client certificate (`REQUIRE X509`, pg_hba `cert`, ClickHouse `ssl_certificates`).

SQL Server has only the `sa` principal, because its TLS contract carries no client identity.

`HbaMode` picks what the PostgreSQL fixture accepts: `Password` (the image defaults, no TLS), `HostSslOnly`, or `ClientCertificate`. `OpenSshFixture` takes an `SshAuthVariant`: `Password`, `PublicKey`, `KeyboardInteractive` or `HostCertificate`. `HostKeyRevocation` builds a KRL from the running server's host key, and `ScriptedAskpass` writes a 0700 script for `SSH_ASKPASS`.

### Ignore reasons

Two reasons are allowed:

- `#[ignore = "requires docker"]` for testcontainers suites.
- `#[ignore = "requires a Secret Service"]` for tests that talk to a keyring.

The workspace denies `clippy::ignore_without_reason`, so a bare `#[ignore]` fails the build.

### Running the docker tests

CI runs one job per driver package:

```bash
cargo nextest run --locked --profile ci -p tablepro-driver-mssql --run-ignored only
```

`.config/nextest.toml` puts each driver's tests in a test group with one thread, so the tests of one suite never compete for a container. The `ci` profile writes a JUnit report to `target/nextest/ci/junit.xml`.

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

GitHub Actions (`.github/workflows/build-linux.yml`), Ubuntu runner, two jobs:

1. **Fast checks**: `cargo fmt --all -- --check`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo build --workspace --locked`, `xvfb-run -a dbus-run-session -- cargo test --workspace --locked` with `GTK_A11Y=test` and `GSK_RENDERER=cairo`. Runs in an `ubuntu:25.10` container, which ships the glib version libadwaita 1.6 needs. [CONTRIBUTING.md](../CONTRIBUTING.md#fast-job-commands) lists the same commands.
2. **Docker tests**: runs after fast checks pass. One matrix entry per package with docker tests (the PostgreSQL, MySQL, SQL Server and ClickHouse drivers, `tablepro-ssh` against an OpenSSH server container, and `tablepro-test-fixtures` for the fixtures themselves) runs that package's ignored docker tests through cargo-nextest on the host runner's Docker.

PRs only merge when both jobs are green.

## Coverage

Tracked with `cargo-llvm-cov` once the codebase has substance. No hard coverage threshold; coverage is a discussion aid, not a gate.

## Mocking

Avoid mock objects. We do not mock drivers, the filesystem, or `tokio::time`. Either use a real implementation (testcontainers, `tempfile`, `tokio::time::pause`) or extract the logic to a pure function and test that.

If a test cannot be written without a mock, the design is wrong. Refactor before writing the mock.
