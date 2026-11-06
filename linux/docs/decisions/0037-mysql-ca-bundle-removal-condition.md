# 0037: When the MySQL CA bundle goes

- **Status**: Accepted
- **Date**: 2026-11-05

## Context

[0005](0005-supply-chain-policy.md) keeps `mysql_ca_bundle_pem` because sqlx takes MySQL CA certificates only as PEM bytes. Its watch list says sqlx [#4044](https://github.com/transact-rs/sqlx/issues/4044) and [#4045](https://github.com/transact-rs/sqlx/pull/4045) "let a caller pass a rustls `ClientConfig`". They do not. #4044 asks for rustls-platform-verifier support, and #4045 adds the `tls-rustls-aws-lc-rs-platform-verifier` and `tls-rustls-ring-platform-verifier` features and drops rustls-native-certs. No caller-supplied configuration or verifier comes with them.

## Decision

The bundle goes in the commit that switches MySQL to an sqlx release whose own TLS verifies the system trust store, accepts the connection's CA file as an extra root, and checks the server name, each proven by a test against a MySQL server. #4045 merging is a reason to run those tests, not a removal on its own.

## Consequences

- 0005's watch entry for the bundle reads as this one.
- If #4045 lands without extra roots beside the platform verifier, the bundle stays, and the watch moves to an sqlx API that takes a rustls `ClientConfig` or verifier.
