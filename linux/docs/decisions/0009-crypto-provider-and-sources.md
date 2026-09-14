# 0009: One crypto provider, upstream sources and dependency bans

- **Status**: Accepted
- **Date**: 2026-09-15

## Context

The dependency graph linked two TLS crypto backends at once: sqlx's `tls-rustls` and the testcontainers default feature pulled ring, while russh, tiberius and clickhouse used aws-lc-rs. Two providers double the audited crypto code, and rustls cannot pick a process default when both are compiled in. The graph also had no written rule for git sources, banned crates or accepted advisories.

## Decision

aws-lc-rs is the only crypto provider, and `deny.toml` enforces providers, sources, licenses and bans over the whole graph, dev-dependencies included.

## Rationale

- **Single provider**: sqlx uses `tls-rustls-aws-lc-rs` on the MySQL and PostgreSQL drivers, clickhouse uses `rustls-tls-aws-lc` with webpki roots, and testcontainers and testcontainers-modules use `aws-lc-rs` with default features off. `cargo tree -e all -i ring` finds no package. `crates/drivers/postgres/tests/tls_provider.rs` builds a rustls `ClientConfig` with the process default, which fails when zero or two providers are compiled in. The app never calls `CryptoProvider::install_default`.
- **Sources**: crates.io plus exactly one git source, `tiberius-rs/tiberius`, until tiberius 0.13 is published. No forks.
- **Bans**: ring, openssl-sys, native-tls, rustls before 0.23, rustls-pemfile, bigdecimal, backoff and instant are denied with a reason each, and libsqlite3-sys may appear only once.
- **RUSTSEC-2023-0071** (Marvin attack on rsa):
  - Stage A, until the OpenSSH transport replaces russh: rsa signs SSH RSA identities in process, one blinded signature per authentication. Host-key verification and agent signing do not use it. sqlx-mysql only encrypts a password with the server's public key.
  - Stage B, written by the commit that removes russh: rsa is reached only through sqlx-mysql's public-key encryption.

## Consequences

- A new dependency that enables ring or OpenSSL fails `cargo deny check bans`.
- Every advisory ignore carries a reason tied to a removal commit.
- The CI supply-chain job, Renovate rules and license notices extend this ADR when they land.

## Alternatives considered

- **ring everywhere**: russh and tiberius already require aws-lc-rs, so ring would still leave two providers.
- **Installing a process default at startup**: hides a second provider instead of removing it.
- **cargo-vet or cargo-crev**: review attestations need a trust set this project does not have yet; cargo-deny covers the rules above.
