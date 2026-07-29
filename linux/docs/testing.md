# Testing

Three layers, three tools. Each crate's test policy follows from its position in the dependency graph.

| Crate | Layer | Tools | Required for merge? |
|---|---|---|---|
| `core` | Pure traits + types | Unit tests in `src/`, table-driven for type mappers | Yes |
| `storage` | Filesystem + libsecret + GSchema | Unit tests + integration tests with `tempfile` | Yes |
| `drivers/<engine>` | Real engines | Unit tests + `testcontainers-rs` integration tests | Yes |
| `app` | GTK4 + Relm4 components | Limited; pure logic in `services/` is unit-tested | No |

Two helper scripts sit on top: `scripts/ci-local.sh` runs the fast CI checks, `scripts/smoke-postgres.sh` runs the driver smoke against a Postgres you already have.

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

Run all unit tests:

```bash
cargo test --workspace --lib --bins
```

`--bins` is not optional: `tablepro-app` has no `lib.rs`, so `--lib` alone skips every test in the app crate. `scripts/ci-local.sh` runs this command; the CI workflow still passes `--lib` only.

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

Integration tests run in CI. Locally they require a Docker-compatible API socket.

### Docker or Podman

Upstream CI uses Docker. Fedora ships Podman instead, and on Debian it is the easier install; either way, point testcontainers at Podman's rootless socket:

```bash
sudo dnf install -y podman   # or: sudo apt install -y podman
systemctl --user enable --now podman.socket
export DOCKER_HOST=unix:///run/user/$(id -u)/podman/podman.sock
cargo test --test integration -p tablepro-driver-postgres -- --include-ignored --test-threads=1
cargo test --test integration -p tablepro-driver-mysql -- --include-ignored --test-threads=1
cargo test --test integration -p tablepro-driver-clickhouse -- --include-ignored --test-threads=1
```

Do not bother with `TESTCONTAINERS_RYUK_DISABLED`. That is a testcontainers-java / go setting; the Rust crate has no Ryuk reaper and stops each container when its handle drops.

`curl --unix-socket "${DOCKER_HOST#unix://}" http://localhost/_ping` should print `OK` before you run the suite. `--unix-socket` takes a filesystem path, so the `unix://` prefix has to come off.

A test that panics hard can still leave a container behind. `podman container prune` clears them.

### Local smoke without a container

`crates/drivers/postgres/tests/smoke_local.rs` runs connect, list tables, fetch rows, edit a cell against a Postgres that is already up. It is `#[ignore]`d like the container suites, so it never runs during a plain `cargo test`.

```bash
podman run -d --name tablepro-smoke -p 54329:5432 \
  -e POSTGRES_USER=tablepro -e POSTGRES_PASSWORD=tablepro -e POSTGRES_DB=tablepro \
  docker.io/library/postgres:16-alpine

./scripts/smoke-postgres.sh
```

Point it somewhere else with `SMOKE_PG_HOST`, `SMOKE_PG_PORT`, `SMOKE_PG_USER`, `SMOKE_PG_PASS`, `SMOKE_PG_DB`. The test creates, clears and drops `tablepro_smoke_items`, so use a scratch database.

Mark slow integration tests with `#[ignore]` if they take more than ~5 seconds:

```rust
#[tokio::test]
#[ignore]  // pulls a 1GB image
async fn import_pgdump_one_million_rows() { /* ... */ }
```

Run them explicitly: `cargo test --workspace -- --include-ignored`.

## App / UI tests

We do not write Relm4 component tests until we hit a bug that they would have caught. The reasoning:

- Relm4's testing helpers require a running GTK main loop, which makes CI flaky.
- Most app logic worth testing belongs in `app::services` modules — extract those into pure Rust and test directly.
- UI testing tools that drive GTK4 (`pyatspi`, `dogtail`) are more trouble than they are worth at this scale.

Policy:

- Pure logic: extract to `app::services::<thing>`, write unit tests there.
- View building: cover by manual QA. Add a screenshot to the PR description.
- Cross-component flows: covered by smoke test (see below).

If a UI bug ships and a regression test would have caught it, write the test then.

## End-to-end smoke test

There is no app-level end-to-end test yet. Driving the GTK app under `xvfb-run` through its registered `gtk::Application` actions is the intended shape when we add one.

What exists today is the driver-level smoke described above: `scripts/smoke-postgres.sh` against a Postgres you already run.

## CI

GitHub Actions (`.github/workflows/build-linux.yml`), Ubuntu runner, two jobs:

1. **Fast checks**: `cargo fmt --all -- --check`, `cargo clippy --all-targets -- -D warnings`, `cargo build --workspace`, `cargo test --workspace --lib`. Runs in an `ubuntu:25.10` container, which ships the glib version libadwaita 1.6 needs. `scripts/ci-local.sh` runs the same steps, but with `--lib --bins` so the app crate's tests actually run. The workflow should pick up `--bins` too.
2. **Driver integration tests**: runs after fast checks pass. Boots Docker on the host runner and runs the Postgres, MySQL, and ClickHouse suites with `--include-ignored`. The MSSQL suite exists but is not wired in yet.

PRs only merge when both jobs are green.

## Coverage

Tracked with `cargo-llvm-cov` once the codebase has substance. No hard coverage threshold; coverage is a discussion aid, not a gate.

## Mocking

Avoid mock objects. We do not mock drivers, the filesystem, or `tokio::time`. Either use a real implementation (testcontainers, `tempfile`, `tokio::time::pause`) or extract the logic to a pure function and test that.

If a test cannot be written without a mock, the design is wrong. Refactor before writing the mock.
