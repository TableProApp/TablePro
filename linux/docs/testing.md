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

Run all unit tests:

```bash
cargo test --workspace --lib
```

## Integration tests

Per-crate `tests/` directory. One file per scenario.

For `storage`, integration tests use `tempfile::TempDir` to run against an isolated filesystem root, with `XDG_CONFIG_HOME` overridden via env var.

For drivers, integration tests use [`testcontainers`](https://docs.rs/testcontainers/latest/testcontainers/) to spin up a real database. The pattern is identical for every driver:

```rust
use testcontainers::{clients::Cli, images::generic::GenericImage};

#[tokio::test]
async fn list_tables_returns_seeded_tables() {
    let docker = Cli::default();
    let image = GenericImage::new("postgres", "16")
        .with_env_var("POSTGRES_PASSWORD", "test")
        .with_exposed_port(5432);
    let node = docker.run(image);
    let port = node.get_host_port_ipv4(5432);

    let driver = PgDriver;
    let conn = driver.connect(opts_for(port)).await.unwrap();

    conn.execute("CREATE TABLE foo (id INT)").await.unwrap();
    let tables = conn.list_tables().await.unwrap();
    assert!(tables.iter().any(|t| t.name == "foo"));
}
```

Integration tests run in CI. Locally they require a Docker-compatible API socket.

### Docker or Podman

Upstream CI uses Docker. On hosts that only ship Podman (Debian / Fedora defaults), point testcontainers at Podman's rootless socket:

```bash
systemctl --user enable --now podman.socket
export DOCKER_HOST=unix:///run/user/$(id -u)/podman/podman.sock
export TESTCONTAINERS_RYUK_DISABLED=true   # Ryuk needs privileges rootless Podman will not grant
cargo test --test integration -p tablepro-driver-postgres -- --include-ignored --test-threads=1
cargo test --test integration -p tablepro-driver-mysql -- --include-ignored --test-threads=1
```

`curl --unix-socket "$DOCKER_HOST" http://localhost/_ping` should print `OK` before you run the suite.

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

`crates/app/tests/smoke.rs` runs at the top of the CI pipeline. It launches the app under `xvfb-run`, sends a fixed sequence of D-Bus actions through `gtk::Application`'s registered actions, and asserts that the app reaches "connected to PostgreSQL, table list visible" without panicking.

The smoke test is not exhaustive. Its job is to fail loudly when something fundamental is broken before the slower per-driver integration tests run.

## CI

GitHub Actions, Linux runner, two jobs:

1. **Fast** (~2 min) — `cargo fmt --check`, `cargo clippy --all -- -D warnings`, `cargo build --workspace`, `cargo test --workspace --lib`.
2. **Full** (~10 min) — runs after fast passes. Boots Docker, runs all integration tests including the smoke test.

PRs only merge when both jobs are green.

## Coverage

Tracked with `cargo-llvm-cov` once the codebase has substance. No hard coverage threshold; coverage is a discussion aid, not a gate.

## Mocking

Avoid mock objects. We do not mock drivers, the filesystem, or `tokio::time`. Either use a real implementation (testcontainers, `tempfile`, `tokio::time::pause`) or extract the logic to a pure function and test that.

If a test cannot be written without a mock, the design is wrong. Refactor before writing the mock.
