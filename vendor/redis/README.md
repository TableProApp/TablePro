# redis-rs

[![Rust](https://github.com/redis-rs/redis-rs/actions/workflows/rust.yml/badge.svg)](https://github.com/redis-rs/redis-rs/actions/workflows/rust.yml)
[![crates.io](https://img.shields.io/crates/v/redis.svg)](https://crates.io/crates/redis)
[![Chat](https://img.shields.io/discord/976380008299917365?logo=discord)](https://discord.gg/WHKcJK9AKP)

Redis-rs is a Rust library implementing a high-level client for Redis, Valkey
and any other RESP (Redis Serialization Protocol) compliant DB server. It
provides convenient access to all Redis functionality through a very flexible
but low-level API. It uses a customizable type conversion trait so that any
operation can return results in just the type you are expecting. This makes for
a very pleasant development experience.

Most Redis and ValKey version should work, but CI runs against Redis 6+
and ValKey 7+.

The crate is called `redis` and you can depend on it via cargo:

```ini
[dependencies]
redis = "1"
```

Documentation on the library can be found at
[docs.rs/redis](https://docs.rs/redis).


## Basic Operation

To open a connection you need to create a client and then to fetch a
connection from it.

Many commands are implemented through the `TypedCommands` or `Commands` traits but manual
command creation is also possible. The `TypedCommands` trait provides pre-specified and opinionated return value types to commands,
but if you want to use other return value types, you can use `Commands` as long as the chosen return value type
implements the `FromRedisValue` trait.

```rust
use redis::TypedCommands;

fn fetch_an_integer() -> Option<isize> {
    // connect to redis
    let client = redis::Client::open("redis://127.0.0.1/")?;
    let mut con = client.get_connection()?;
    // `set` returns a `()`, so we don't need to specify the return type manually unlike in the previous example.
    con.set("my_key", 42)?;
    // `get_int` returns Option<isize>, as the key may not be found.
    con.get_int("my_key").unwrap()
}
```

```rust
use redis::Commands;

fn fetch_an_integer() -> redis::RedisResult<isize> {
    // connect to redis
    let client = redis::Client::open("redis://127.0.0.1/")?;
    let mut con = client.get_connection()?;
    // throw away the result, just make sure it does not fail
    let _: () = con.set("my_key", 42)?;
    // read back the key and return it.  Because the return value
    // from the function is a result for integer this will automatically
    // convert into one.
    con.get("my_key")
}
```

Variables are converted to and from the Redis format for a wide variety of types
(`String`, num types, tuples, `Vec<u8>`). If you want to use it with your own types,
you can implement the `FromRedisValue` and `ToRedisArgs` traits, or derive it with the
[redis-macros](https://github.com/daniel7grant/redis-macros/#json-wrapper-with-redisjson) crate.

## Async support

To enable asynchronous clients, enable the relevant feature in your Cargo.toml,
`tokio-comp` for tokio users, `smol-comp` for smol users.

```
# if you use tokio
redis = { version = "1", features = ["tokio-comp"] }

# if you use smol
redis = { version = "1", features = ["smol-comp"] }
```

You can then use either the `AsyncTypedCommands` or `AsyncCommands` traits. All async connections are cheap to clone, and clones can be used concurrently from multiple threads.

## Connection Pooling

When using a sync connection, it is recommended to use a connection pool in order to handle
disconnects or multi-threaded usage. This can be done using the `r2d2` feature.

```
redis = { version = "1", features = ["r2d2"] }
```

For async connections, connection pooling isn't necessary, unless blocking commands are used.
The `MultiplexedConnection` is cheaply cloneable and can be used safely from multiple threads, so a 
single connection can be easily reused. For automatic reconnections consider using 
`ConnectionManager` with the `connection-manager` feature.
Async cluster connections also don't require pooling and are thread-safe and reusable.

Multiplexing won't help if blocking commands are used since the server won't handle commands
from blocked connections until the connection is unblocked. If you want to be able to handle
non-blocking commands concurrently with blocking commands, you should send the blocking
commands on another connection.

## TLS Support

To enable TLS support, you need to use the relevant feature entry in your Cargo.toml.
Currently, `native-tls` and `rustls` are supported.

To use `native-tls`:

```
redis = { version = "1", features = ["tls-native-tls"] }

# if you use tokio
redis = { version = "1", features = ["tokio-native-tls-comp"] }

# if you use smol
redis = { version = "1", features = ["smol-native-tls-comp"] }
```

To use `rustls`:

```
redis = { version = "1", features = ["tls-rustls"] }

# if you use tokio
redis = { version = "1", features = ["tokio-rustls-comp"] }

# if you use smol
redis = { version = "1", features = ["smol-rustls-comp"] }
```

Add `rustls` to dependencies

```
rustls = { version = "0.23" }
```

And then, before creating a connection, ensure that you install a crypto provider. For example:

```rust
    rustls::crypto::aws_lc_rs::default_provider()
        .install_default()
        .expect("Failed to install rustls crypto provider");
```


With `rustls`, you can add the following feature flags on top of other feature flags to enable additional features:

-   `tls-rustls-insecure`: Allow insecure TLS connections
-   `tls-rustls-webpki-roots`: Use `webpki-roots` (Mozilla's root certificates) instead of native root certificates

then you should be able to connect to a redis instance using the `rediss://` URL scheme:

```rust
let client = redis::Client::open("rediss://127.0.0.1/")?;
```

To enable insecure mode, append `#insecure` at the end of the URL:

```rust
let client = redis::Client::open("rediss://127.0.0.1/#insecure")?;
```

## Token-Based Authentication with Azure Entra ID

Redis-rs supports token-based authentication using Azure Entra ID, providing secure, dynamic authentication for Redis connections. This feature is particularly useful for Azure-hosted applications and enterprise environments.

To enable Entra ID authentication, add the `entra-id` feature to your Cargo.toml:

```toml
redis = { version = "1", features = ["entra-id", "tokio-comp"] }
```

### Supported Authentication Flows

- **DeveloperToolsCredential**: Authenticates through developer tools such as the Azure CLI.
It tries the following credential types, in this order, stopping when one provides a token:
* [`AzureCliCredential`]
* [`AzureDeveloperCliCredential`]
`DeveloperToolsCredential` uses the first credential that provides a token for all subsequent token requests. It never tries the others again.
- **Service Principal**: `Client secret` and `certificate-based` authentication
- **Managed Identity**: `System-assigned` or `user-assigned` managed identities
- **Custom Credentials**: Support for any `TokenCredential` implementation

### Features

- **Automatic Token Refresh & Streaming of Credentials**: Seamlessly handle token expiration and stream updated credentials to prevent connection errors due to token expiration
- **Configurable Refresh Policies**: Customizable refresh thresholds and retry behavior

### Async-First Design
- Full async/await support for non-blocking operations
- Seamless integration with multiplexed connections

## Cluster Support

Support for Redis Cluster can be enabled by enabling the `cluster` feature in your Cargo.toml:

`redis = { version = "1", features = [ "cluster"] }`

Then you can simply use the `ClusterClient`, which accepts a list of available nodes. Note
that only one node in the cluster needs to be specified when instantiating the client, though
you can specify multiple.

```rust
use redis::cluster::ClusterClient;
use redis::TypedCommands;

fn fetch_an_integer() -> String {
    let nodes = vec!["redis://127.0.0.1/"];
    let client = ClusterClient::new(nodes).unwrap();
    let mut connection = client.get_connection().unwrap();
    connection.set("test", "test_data").unwrap();
    return connection.get("test").unwrap();
}
```

Async Redis Cluster support can be enabled by enabling the `cluster-async` feature, along
with your preferred async runtime, e.g.:

`redis = { version = "1", features = [ "cluster-async", "tokio-comp" ] }`

```rust
use redis::cluster::ClusterClient;
use redis::AsyncTypedCommands;

async fn fetch_an_integer() -> String {
    let nodes = vec!["redis://127.0.0.1/"];
    let client = ClusterClient::new(nodes).unwrap();
    let mut connection = client.get_async_connection().await.unwrap();
    connection.set("test", "test_data").await.unwrap();
    return connection.get("test").await.unwrap();
}
```

## JSON Support

Support for the RedisJSON Module can be enabled by specifying "json" as a feature in your Cargo.toml.

`redis = { version = "1", features = ["json"] }`

Then you can simply import the `JsonCommands` trait which will add the `json` commands to all Redis Connections (not to be confused with just `Commands` which only adds the default commands)

```rust
use redis::Client;
use redis::JsonCommands;
use redis::RedisResult;
use redis::ToRedisArgs;

// Result returns Ok(true) if the value was set
// Result returns Err(e) if there was an error with the server itself OR serde_json was unable to serialize the boolean
fn set_json_bool<P: ToRedisArgs>(key: P, path: P, b: bool) -> RedisResult<bool> {
    let client = Client::open("redis://127.0.0.1").unwrap();
    let connection = client.get_connection().unwrap();

    // runs `JSON.SET {key} {path} {b}`
    connection.json_set(key, path, b)?
}

```

To parse the results, you'll need to use `serde_json` (or some other json lib) to deserialize
the results from the bytes. It will always be a `Vec`, if no results were found at the path it'll
be an empty `Vec`. If you want to handle deserialization and `Vec` unwrapping automatically,
you can use the `Json` wrapper from the
[redis-macros](https://github.com/daniel7grant/redis-macros/#json-wrapper-with-redisjson) crate.

## Testing
 
 The [`redis-test`](https://docs.rs/redis-test) crate provides tools for testing Redis clients.
 It includes a `MockRedisConnection` for unit testing without a real Redis server,
 as well as helpers like `RedisCluster` and `RedisSentinelCluster` to easily spin up
 local Redis clusters and Sentinels for integration tests.
 
 ## Webassembly Support

redis-rs tests that WebAssembly successfully builds for the sync client. Async
clients on `wasm32-wasip2` are supported via the existing `tokio-comp` feature
and [Tokio's wasm32-wasip2 networking](https://github.com/tokio-rs/tokio/pull/7933)
(Tokio 1.51+).

Build requirements for `wasm32-wasip2` with `tokio-comp`:

- `rustup target add wasm32-wasip2`
- Tokio 1.51 or newer in your dependency graph
- `RUSTFLAGS="--cfg tokio_unstable"` (required by Tokio for WASIp2 until stabilized)
- A `current_thread` Tokio runtime (WASIp2 is single-threaded)
- A WASM host with network access (e.g. `wasmtime -S inherit-network`)

```bash
RUSTFLAGS="--cfg tokio_unstable" cargo build -p redis \
  --target wasm32-wasip2 \
  --no-default-features \
  --features tokio-comp
```

This uses the standard `tokio-comp` code path — no redis-rs-specific WASI transport layer.

CI currently only verifies that redis-rs compiles for WebAssembly targets.

## Development

See [DEVELOPMENT.md](DEVELOPMENT.md)
