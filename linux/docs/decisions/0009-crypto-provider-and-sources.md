# 0009: One crypto provider, upstream sources and dependency bans

- **Status**: Accepted; sources and the PostgreSQL and ClickHouse TLS setup superseded by [0016](0016-driver-contract-v2.md), the ring ban amended by [0023](0023-bundled-duckdb.md)
- **Date**: 2026-09-15

## Context

The dependency graph linked two TLS crypto backends at once: sqlx's `tls-rustls` and the testcontainers default feature pulled ring, while russh, tiberius and clickhouse used aws-lc-rs. Two providers double the audited crypto code, and rustls cannot pick a process default when both are compiled in. The graph also had no written rule for git sources, banned crates or accepted advisories.

## Decision

aws-lc-rs is the only crypto provider, and `deny.toml` enforces providers, sources, licenses and bans over the whole graph, dev-dependencies included.

## Rationale

- **Single provider**: sqlx uses `tls-rustls-aws-lc-rs` on the MySQL driver. Since [0016](0016-driver-contract-v2.md), PostgreSQL runs on tokio-postgres with tokio-postgres-rustls, whose provider features are off, and the clickhouse crate has its default features off while the driver dials through hyper-rustls with `aws-lc-rs`. testcontainers and testcontainers-modules use `aws-lc-rs` with default features off. `cargo tree -e all -i ring` finds no package. `crates/drivers/postgres/tests/tls_provider.rs` builds a rustls `ClientConfig` with the process default, which fails when zero or two providers are compiled in. The app never calls `CryptoProvider::install_default`.
- **Sources**: crates.io plus exactly one git source, `tiberius-rs/tiberius`, until tiberius 0.13 is published. No forks. tiberius 0.13 is on crates.io now, and `allow-git` in `deny.toml` is empty ([0016](0016-driver-contract-v2.md)).
- **Bans**: ring, openssl-sys, native-tls, rustls before 0.23, rustls-pemfile, bigdecimal, rust_decimal, backoff and instant are denied with a reason each, libsqlite3-sys may appear only once, rsa only under sqlx-mysql (below), and tablepro-test-fixtures only under the crates that test with it.
- **RUSTSEC-2023-0071** (Marvin attack on rsa):
  - Stage A, until the OpenSSH transport replaced russh: rsa signed SSH RSA identities in process, one blinded signature per authentication. Host-key verification and agent signing did not use it.
  - Stage B, since ADR 0013 removed russh: rsa is reached only through sqlx-mysql, which encrypts the MySQL password with the server's public key when the connection has no TLS. That key arrives in band and unauthenticated, so the encryption keeps the password only from a passive observer ([mysql.md](../drivers/mysql.md#tls)). The advisory is about private-key timing, and no private-key operation runs in process: the OpenSSH client or the agent signs SSH identities in its own process. `deny.toml` bans rsa under any other parent, so a dependency that brings an in-process RSA signer fails `cargo deny check bans` instead of passing under the ignore.
  - RSA identity files stay supported with no hint on the key row. Recommending Ed25519 or the agent was the Stage A mitigation; under Stage B it would warn about a working key with no exposure behind it.

## Consequences

- A new dependency that enables ring or OpenSSL fails `cargo deny check bans`.
- Every advisory ignore carries a reason tied to a removal commit.
- The CI supply-chain job, Renovate rules and license notices extend this ADR when they land.

## Alternatives considered

- **ring everywhere**: russh and tiberius already require aws-lc-rs, so ring would still leave two providers.
- **Installing a process default at startup**: hides a second provider instead of removing it.
- **cargo-vet or cargo-crev**: review attestations need a trust set this project does not have yet; cargo-deny covers the rules above.
