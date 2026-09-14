# Testing

Three layers, three tools. Each crate's test policy follows from its position in the dependency graph.

| Crate | Layer | Tools | Required for merge? |
|---|---|---|---|
| `core` | Pure traits + types | Unit tests in `src/`, table-driven for type mappers | Yes |
| `storage` | Filesystem + libsecret + GSchema | Unit tests + integration tests with `tempfile` | Yes |
| `drivers/<engine>` | Real engines | Unit tests + `testcontainers-rs` integration tests | Yes |
| `app` | GTK4 + Relm4 components | Limited; pure logic in `services/` is unit-tested | No |

`scripts/ci-local.sh` runs the fast CI checks locally.

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

Run every test that needs no external service:

```bash
cargo test --workspace --locked
```

This runs unit tests, doc tests and every test target. Tests that need Docker or a Secret Service are ignored. The CI fast job and `scripts/ci-local.sh` run this exact command.

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

We do not write Relm4 component tests until we hit a bug that they would have caught. The reasoning:

- Relm4's testing helpers require a running GTK main loop, which makes CI flaky.
- Most app logic worth testing belongs in `app::services` modules: extract those into pure Rust and test directly.
- UI testing tools that drive GTK4 (`pyatspi`, `dogtail`) are more trouble than they are worth at this scale.

Policy:

- Pure logic: extract to `app::services::<thing>`, write unit tests there.
- View building: cover by manual QA. Add a screenshot to the PR description.
- Cross-component flows: manual QA until the end-to-end test below exists.

If a UI bug ships and a regression test would have caught it, write the test then.

## End-to-end test

There is no app-level end-to-end test yet. Driving the GTK app under `xvfb-run` through its registered `gtk::Application` actions is the intended shape when we add one.

## CI

GitHub Actions (`.github/workflows/build-linux.yml`), Ubuntu runner, two jobs:

1. **Fast checks**: `cargo fmt --all -- --check`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo build --workspace --locked`, `cargo test --workspace --locked`. Runs in an `ubuntu:25.10` container, which ships the glib version libadwaita 1.6 needs. `scripts/ci-local.sh` runs the same steps with the same flags.
2. **Docker tests**: runs after fast checks pass. One matrix entry per driver package (PostgreSQL, MySQL, SQL Server, ClickHouse) runs that package's ignored docker tests through cargo-nextest on the host runner's Docker.

PRs only merge when both jobs are green.

## Coverage

Tracked with `cargo-llvm-cov` once the codebase has substance. No hard coverage threshold; coverage is a discussion aid, not a gate.

## Mocking

Avoid mock objects. We do not mock drivers, the filesystem, or `tokio::time`. Either use a real implementation (testcontainers, `tempfile`, `tokio::time::pause`) or extract the logic to a pure function and test that.

If a test cannot be written without a mock, the design is wrong. Refactor before writing the mock.
