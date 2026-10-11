# MongoDB Rust Driver

[![Crates.io](https://img.shields.io/crates/v/mongodb.svg)](https://crates.io/crates/mongodb) [![docs.rs](https://docs.rs/mongodb/badge.svg)](https://docs.rs/mongodb) [![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](https://github.com/mongodb/mongo-rust-driver/blob/main/LICENSE)

This is the officially supported MongoDB Rust driver, a client side library that can be used to interact with MongoDB deployments in Rust applications. It uses the [`bson`](https://docs.rs/bson/latest) crate for BSON support. The driver contains a fully async API that requires [`tokio`](https://docs.rs/tokio). The driver also has a sync API that may be enabled via feature flags. The MongoDB Rust driver follows [semantic versioning](https://semver.org/) for its releases.

For more details, including features, runnable examples, troubleshooting resources, and more, please see the [official documentation](https://www.mongodb.com/docs/drivers/rust/current/).

## Installation

### Requirements

- Rust 1.88.0+ (See the [MSRV policy](#minimum-supported-rust-version-msrv-policy) for more information)
- MongoDB 4.4+

#### Supported Platforms

The driver tests against Linux, MacOS, and Windows in CI.

### Importing

The driver is available on [crates.io](https://crates.io/crates/mongodb). To use the driver in your application, simply add it to your project's `Cargo.toml`.

```toml
[dependencies]
mongodb = "3.9.1"
```

Version 1 of this crate has reached end of life and will no longer be receiving any updates or bug fixes, so all users are recommended to always depend on the latest 2.x release. See the [2.0.0 release notes](https://github.com/mongodb/mongo-rust-driver/releases/tag/v2.0.0) for migration information if upgrading from a 1.x version.

#### Enabling the sync API

The driver also provides a blocking sync API. To enable this, add the `"sync"` feature to your `Cargo.toml`:

```toml
[dependencies.mongodb]
version = "3.9.1"
features = ["sync"]
```

**Note:** The sync-specific types can be imported from `mongodb::sync` (e.g. `mongodb::sync::Client`).

### All Feature Flags

| Feature              | Description                                                                                                                                                                                                       |
| :------------------- | :---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `dns-resolver`       | Enable DNS resolution to allow `mongodb+srv` URI handling. **Enabled by default.**                                                                                                                                |
| `rustls-tls`         | Use [`rustls`](https://docs.rs/rustls/latest/rustls/) for TLS connection handling, with the [`ring`](https://docs.rs/ring/latest/ring/) crypto provider. **Enabled by default.**               
| `rustls-tls-aws-lc`         | Use [`rustls`](https://docs.rs/rustls/latest/rustls/) for TLS connection handling, with the [`aws-lc-rs`](https://docs.rs/aws-lc-rs/latest/aws_lc_rs/) crypto provider.                                                                                                        |
| `openssl-tls`        | Use [`openssl`](https://docs.rs/openssl/latest/openssl/) for TLS connection handling.                                                                                                                             |
| `sync`               | Expose the synchronous API (`mongodb::sync`).                                                                                                                                                                     |
| `aws-auth`           | Enable support for the MONGODB-AWS authentication mechanism.                                                                                                                                                      |
| `zlib-compression`   | Enable support for compressing messages with [`zlib`](https://zlib.net/).                                                                                                                                         |
| `zstd-compression`   | Enable support for compressing messages with [`zstd`](http://facebook.github.io/zstd/).                                                                                                                           |
| `snappy-compression` | Enable support for compressing messages with [`snappy`](http://google.github.io/snappy/).                                                                                                                         |
| `in-use-encryption`  | Enable support for client-side field level encryption and queryable encryption. Note that re-exports from the `mongocrypt` crate may change in backwards-incompatible ways while that crate is below version 1.0. |
| `tracing-unstable`   | Enable support for emitting [`tracing`](https://docs.rs/tracing/latest/tracing/) events. This API is unstable and may be subject to breaking changes in minor releases.                                           |
| `compat-3-0-0`       | Required for future compatibility if default features are disabled.                                                                                                                                               |
| `azure-oidc`         | Enable support for Azure OIDC environment authentication. |
| `gcp-oidc`           | Enable support for GCP OIDC environment authentication. |
| `error-backtrace`    | Capture backtraces in `Error` values.  This can be slow, memory intensive, and very verbose. |
| `bson-3`             | Use version 3.x of the `bson` crate; for backwards compatibility, without this feature enabled `bson` 2.x is used. |
| `socks5-proxy`       | Enable SOCKS5 proxy support. |

## Web Framework Examples

### Actix

The driver can be used easily with the Actix web framework by storing a `Client` in Actix application data. A full example application for using MongoDB with Actix can be found [here](https://github.com/actix/examples/tree/master/databases/mongodb).

### Axum

A simple CRUD API example using Axum and MongoDB can be found [here](https://github.com/tokio-rs/axum/tree/main/examples/mongodb).

### Rocket

The Rocket web framework provides built-in support for MongoDB via the Rust driver. The documentation for the [`rocket_db_pools`](https://api.rocket.rs/v0.5/rocket_db_pools/index.html) crate contains instructions for using MongoDB with your Rocket application.

## Warning about timeouts / cancellation

In async Rust, it is common to implement cancellation and timeouts by dropping a future after a
certain period of time instead of polling it to completion. This is how
[`tokio::time::timeout`](https://docs.rs/tokio/1.10.1/tokio/time/fn.timeout.html) works, for
example. However, doing this with futures returned by the driver can leave the driver's internals in
an inconsistent state, which may lead to unpredictable or incorrect behavior (see [RUST-937](https://jira.mongodb.org/browse/RUST-937) for more
details). As such, it is **_highly_** recommended to poll all futures returned from the driver to
completion. In order to still use timeout mechanisms like `tokio::time::timeout` with the driver,
one option is to spawn tasks and time out on their
[`JoinHandle`](https://docs.rs/tokio/1.10.1/tokio/task/struct.JoinHandle.html) futures instead of on
the driver's futures directly. This will ensure the driver's futures will always be completely polled
while also allowing the application to continue in the event of a timeout.

## Bug Reporting / Feature Requests

To file a bug report or submit a feature request, please open a ticket on our [Jira project](https://jira.mongodb.org/browse/RUST):

- Create an account and login at [jira.mongodb.org](https://jira.mongodb.org)
- Navigate to the RUST project at [jira.mongodb.org/browse/RUST](https://jira.mongodb.org/browse/RUST)
- Click **Create Issue** - If the ticket you are filing is a bug report, please include as much detail as possible about the issue and how to reproduce it.

Before filing a ticket, please use the search functionality of Jira to see if a similar issue has already been filed.

## Contributing

We encourage and would happily accept contributions in the form of GitHub pull requests. Before opening one, be sure to run the tests locally; check out the [testing section](#running-the-tests) for information on how to do that. Once you open a pull request, your branch will be run against the same testing matrix that we use for our [continuous integration](#continuous-integration) system, so it is usually sufficient to only run the integration tests locally against a standalone. Remember to always run the linter tests before opening a pull request.

## Running the tests

### Integration and unit tests

In order to run the tests (which are mostly integration tests), you must have access to a MongoDB deployment. You may specify a [MongoDB connection string](https://www.mongodb.com/docs/manual/reference/connection-string/) in the `MONGODB_URI` environment variable, and the tests will use it to connect to the deployment. If `MONGODB_URI` is unset, the tests will attempt to connect to a local deployment on port 27017.

**Note:** The integration tests will clear out the databases/collections they need to use, but they do not clean up after themselves.

To actually run the tests, you can use `cargo` like you would in any other crate:

```bash
cargo test --verbose # runs against localhost:27017
export MONGODB_URI="mongodb://localhost:123"
cargo test --verbose # runs against localhost:123
```

#### Auth tests

The authentication tests will only be included in the test run if certain requirements are met:

- The deployment must have `--auth` enabled
- Credentials must be specified in `MONGODB_URI`
- The credentials specified in `MONGODB_URI` must be valid and have root privileges on the deployment

```bash
export MONGODB_URI="mongodb://user:pass@localhost:27017"
cargo test --verbose # auth tests included
```

#### Topology-specific tests

Certain tests will only be run against certain topologies. To ensure that the entire test suite is run, make sure to run the tests separately against standalone, replicated, and sharded deployments.

```bash
export MONGODB_URI="mongodb://my-standalone-host:27017" # mongod running on 27017
cargo test --verbose
export MONGODB_URI="mongodb://localhost:27018,localhost:27019,localhost:27020/?replicaSet=repl" # replicaset running on ports 27018, 27019, 27020 with name repl
cargo test --verbose
export MONGODB_URI="mongodb://localhost:27021" # mongos running on 27021
cargo test --verbose
```

#### Run the tests with TLS/SSL

To run the tests with TLS/SSL enabled, you must enable it on the deployment and in `MONGODB_URI`.

```bash
export MONGODB_URI="mongodb://localhost:27017/?tls=true&tlsCertificateKeyFile=cert.pem&tlsCAFile=ca.pem"
cargo test --verbose
```

**Note:** When you open a pull request, your code will be run against a comprehensive testing matrix, so it is usually not necessary to run the integration tests against all combinations of topology/auth/TLS locally.

### Linter Tests

Our linter tests use the nightly version of `rustfmt` to verify that the source is formatted properly and the stable version of `clippy` to statically detect any common mistakes.
You can use `rustup` to install them both:

```bash
rustup component add clippy --toolchain stable
rustup component add rustfmt --toolchain nightly
```

Our linter tests also use `rustdoc` to verify that all necessary documentation is present and properly formatted. `rustdoc` is included in the standard Rust distribution.

To run the linter tests, run the `check-clippy.sh`, `check-rustfmt.sh`, and `check-rustdoc.sh` scripts in the `.evergreen` directory. To run all three, use the `check-all.sh` script.

```bash
bash .evergreen/check-all.sh
```

## Continuous Integration

Commits to main are run automatically on [evergreen](https://evergreen.mongodb.com/waterfall/mongo-rust-driver).

## Minimum supported Rust version (MSRV) policy

The MSRV for this crate is currently 1.88.0. Increases to the MSRV will only happen in a minor or major version release, and will be to a Rust version at least six months old.

## License

This project is licensed under the [Apache License 2.0](https://github.com/10gen/mongo-rust-driver/blob/main/LICENSE).

This product includes software developed by the OpenSSL Project for use in the OpenSSL Toolkit (<http://www.openssl.org/>).
