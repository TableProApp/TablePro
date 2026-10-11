//! redis-rs is a Rust implementation of a client library for Redis.  It exposes
//! a general purpose interface to Redis and also provides specific helpers for
//! commonly used functionality.
//!
//! The crate is called `redis` and you can depend on it via cargo:
//!
//! ```ini
//! [dependencies.redis]
//! version = "*"
//! ```
//!
//! If you want to use the git version:
//!
//! ```ini
//! [dependencies.redis]
//! git = "https://github.com/redis-rs/redis-rs.git"
//! ```
//!
//! # Basic Operation
//!
//! redis-rs exposes two API levels: a low- and a high-level part.
//! The high-level part does not expose all the functionality of redis and
//! might take some liberties in how it speaks the protocol.  The low-level
//! part of the API allows you to express any request on the redis level.
//! You can fluently switch between both API levels at any point.
//!
//! # TLS / SSL
//!
//! The user can enable TLS support using either RusTLS or native support (usually OpenSSL),
//! using the `tls-rustls` or `tls-native-tls` features respectively. In order to enable TLS
//! for async usage, the user must enable matching features for their runtime - either `tokio-native-tls-comp`,
//! `tokio-rustls-comp`, `smol-native-tls-comp`, or `smol-rustls-comp`. Additionally, the
//! `tls-rustls-webpki-roots` allows usage of of webpki-roots for the root certificate store.
//!
//! # TCP settings
//!
//! The user can set parameters of the underlying TCP connection by setting [io::tcp::TcpSettings] on the connection configuration objects,
//! and set the TCP parameters in a more specific manner there.
//!
//! ## Connection Handling
//!
//! For connecting to redis you can use a client object which then can produce
//! actual connections.  Connections and clients as well as results of
//! connections and clients are considered [ConnectionLike] objects and
//! can be used anywhere a request is made.
//!
//! The full canonical way to get a connection is to create a client and
//! to ask for a connection from it:
//!
//! ```rust,no_run
//! extern crate redis;
//!
//! fn do_something() -> redis::RedisResult<()> {
//!     let client = redis::Client::open("redis://127.0.0.1/")?;
//!     let mut con = client.get_connection()?;
//!
//!     /* do something here */
//!
//!     Ok(())
//! }
//! ```
//!
//! ## Connection Pooling
//!
//! When using a sync connection, it is recommended to use a connection pool in order to handle
//! disconnects or multi-threaded usage. This can be done using the `r2d2` feature.
//!
//! ```rust,no_run
//! # #[cfg(feature = "r2d2")]
//! # fn do_something() {
//! use redis::TypedCommands;
//!
//! let client = redis::Client::open("redis://127.0.0.1/").unwrap();
//! let pool = r2d2::Pool::builder().build(client).unwrap();
//! let mut conn = pool.get().unwrap();
//!
//! conn.set("KEY", "VALUE").unwrap();
//! let val = conn.get("KEY").unwrap();
//! # }
//! ```
//!
//! For async connections, connection pooling isn't necessary. The `MultiplexedConnection` is
//! cheap to clone and can be used safely concurrently from multiple threads, so a single connection can be easily
//! reused. For automatic reconnections consider using `ConnectionManager` with the `connection-manager` feature.
//! Async cluster connections also don't require pooling and are thread-safe and reusable.
//!
//! ## Optional Features
//!
//! There are a few features defined that can enable additional functionality
//! if so desired.  Some of them are turned on by default.
//!
//! * `acl`: enables acl support (enabled by default)
//! * `bloom`: enables support for the Bloom filter module (optional)
//! * `tokio-comp`: enables support for async usage with the Tokio runtime (optional)
//! * `smol-comp`: enables support for async usage with the Smol runtime (optional)
//! * `geospatial`: enables geospatial support (enabled by default)
//! * `script`: enables script support (enabled by default)
//! * `streams`: enables high-level interface for interaction with Redis streams (enabled by default)
//! * `r2d2`: enables r2d2 connection pool support (optional)
//! * `bb8`: enables bb8 connection pool support (optional)
//! * `ahash`: enables ahash map/set support & uses ahash internally (+7-10% performance) (optional)
//! * `cluster`: enables redis cluster support (optional)
//! * `cluster-async`: enables async redis cluster support (optional)
//! * `connection-manager`: enables support for automatic reconnection (optional)
//! * `rust_decimal`, `bigdecimal`, `num-bigint`: enables type conversions to large number representation from different crates (optional)
//! * `uuid`: enables type conversion to UUID (optional)
//! * `sentinel`: enables high-level interfaces for communication with Redis sentinels (optional)
//! * `json`: enables high-level interfaces for communication with the JSON module (optional)
//! * `search_unfinished`: enables high-level interfaces for communication with the Search module (optional) NOTE: Currently, this feature is incomplete and should be considered a work in progress.
//! * `cache-aio`: enables **experimental** client side caching for MultiplexedConnection, ConnectionManager and async ClusterConnection (optional)
//!
//! ## Connection Parameters
//!
//! redis-rs knows different ways to define where a connection should
//! go.  The parameter to [Client::open] needs to implement the
//! [IntoConnectionInfo] trait of which there are three implementations:
//!
//! * string slices in `redis://` URL format.
//! * URL objects from the redis-url crate.
//! * [ConnectionInfo] objects.
//!
//! The URL format is `redis://[<username>][:<password>@]<hostname>[:port][/[<db>][?protocol=<protocol>]]`
//!
//! If Unix socket support is available you can use a unix URL in this format:
//!
//! `redis+unix:///<path>[?db=<db>[&pass=<password>][&user=<username>][&protocol=<protocol>]]`
//!
//! For compatibility with some other libraries for Redis, the "unix" scheme
//! is also supported:
//!
//! `unix:///<path>[?db=<db>][&pass=<password>][&user=<username>][&protocol=<protocol>]]`
//!
//! ## Executing Low-Level Commands
//!
//! To execute low-level commands you can use the [cmd::cmd] function which allows
//! you to build redis requests.  Once you have configured a command object
//! to your liking you can send a query into any [ConnectionLike] object:
//!
//! ```rust,no_run
//! fn do_something(con: &mut redis::Connection) -> redis::RedisResult<()> {
//!     redis::cmd("SET").arg("my_key").arg(42).exec(con)?;
//!     Ok(())
//! }
//! ```
//!
//! Upon querying the return value is a result object.  If you do not care
//! about the actual return value (other than that it is not a failure)
//! you can always type annotate it to the unit type `()`.
//!
//! Note that commands with a sub-command (like "MEMORY USAGE", "ACL WHOAMI",
//! "LATENCY HISTORY", etc) must specify the sub-command as a separate `arg`:
//!
//! ```rust,no_run
//! fn do_something(con: &mut redis::Connection) -> redis::RedisResult<usize> {
//!     // This will result in a server error: "unknown command `MEMORY USAGE`"
//!     // because "USAGE" is technically a sub-command of "MEMORY".
//!     redis::cmd("MEMORY USAGE").arg("my_key").query::<usize>(con)?;
//!
//!     // However, this will work as you'd expect
//!     redis::cmd("MEMORY").arg("USAGE").arg("my_key").query(con)
//! }
//! ```
//!
//! ## Executing High-Level Commands
//!
//! The high-level interface is similar.  For it to become available you
//! need to use the `TypedCommands` or `Commands` traits in which case all `ConnectionLike`
//! objects the library provides will also have high-level methods which
//! make working with the protocol easier:
//!
//! ```rust,no_run
//! extern crate redis;
//! use redis::TypedCommands;
//!
//! fn do_something(con: &mut redis::Connection) -> redis::RedisResult<()> {
//!     con.set("my_key", 42)?;
//!     Ok(())
//! }
//! ```
//!
//! Note that high-level commands are work in progress and many are still
//! missing!
//!
//! ## Pre-typed Commands
//!
//! Because redis inherently is mostly type-less and the protocol is not
//! exactly friendly to developers, this library provides flexible support
//! for casting values to the intended results. This is driven through the [FromRedisValue] and [ToRedisArgs] traits.
//!
//! In most cases, you may like to use defaults provided by the library, to avoid the clutter and development overhead
//! of specifying types for each command.
//!
//! The library facilitates this by providing the [commands::TypedCommands] and [commands::AsyncTypedCommands]. These traits provide functions
//! with pre-defined and opinionated return types. For example, `set` returns `()`, avoiding the need
//! for developers to explicitly type each call as returning `()`.
//!
//! ```rust,no_run
//! use redis::TypedCommands;
//!
//! fn fetch_an_integer() -> redis::RedisResult<isize> {
//!     // connect to redis
//!     let client = redis::Client::open("redis://127.0.0.1/")?;
//!     let mut con = client.get_connection()?;
//!     // `set` returns a `()`, so we don't need to specify the return type manually unlike in the previous example.
//!     con.set("my_key", 42)?;
//!     // `get_int` returns Result<Option<isize>>, as the key may not be found, or some error may occur.
//!     Ok(con.get_int("my_key").unwrap().unwrap())
//! }
//! ```
//!
//! ## Custom Type Conversions
//!
//! In some cases, the user might want to define their own return value types to various Redis calls.
//! The library facilitates this by providing the [commands::Commands] and [commands::AsyncCommands]
//! as alternatives to [commands::TypedCommands] and [commands::AsyncTypedCommands] respectively.
//!
//! The `arg` method of the command will accept a wide range of types through
//! the [ToRedisArgs] trait and the `query` method of a command can convert the
//! value to what you expect the function to return through the [FromRedisValue]
//! trait. This is quite flexible and allows vectors, tuples, hashsets, hashmaps
//! as well as optional values:
//!
//! ```rust,no_run
//! # use redis::Commands;
//! # use std::collections::{HashMap, HashSet};
//! # fn do_something() -> redis::RedisResult<()> {
//! # let client = redis::Client::open("redis://127.0.0.1/").unwrap();
//! # let mut con = client.get_connection().unwrap();
//! let count : i32 = con.get("my_counter")?;
//! let count = con.get("my_counter").unwrap_or(0i32);
//! let k : Option<String> = con.get("missing_key")?;
//! let name : String = con.get("my_name")?;
//! let bin : Vec<u8> = con.get("my_binary")?;
//! let map : HashMap<String, i32> = con.hgetall("my_hash")?;
//! let keys : Vec<String> = con.hkeys("my_hash")?;
//! let mems : HashSet<i32> = con.smembers("my_set")?;
//! let (k1, k2) : (String, String) = con.mget(&["k1", "k2"])?;
//! # Ok(())
//! # }
//! ```
//!
//! # RESP3 support
//! Since Redis / Valkey version 6, a newer communication protocol called RESP3 is supported.
//! Using this protocol allows the user both to receive a more varied `Value` results, for users
//! who use the low-level `Value` type, and to receive out of band messages on the same connection. This allows the user to receive PubSub
//! messages on the same connection, instead of creating a new PubSub connection (see "RESP3 async pubsub").
//!

//!
//! ## RESP3 pubsub
//! If you're targeting a Redis/Valkey server of version 6 or above, you can receive
//! pubsub messages from it without creating another connection, by setting a push sender on the connection.
//!
//! ```rust,no_run
//! # #[cfg(feature = "aio")]
//! # {
//! # use futures::prelude::*;
//! # use redis::AsyncTypedCommands;
//!
//! # async fn func() -> redis::RedisResult<()> {
//! let client = redis::Client::open("redis://127.0.0.1/?protocol=resp3").unwrap();
//! let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
//! let config = redis::AsyncConnectionConfig::new().set_push_sender(tx);
//! let mut con = client.get_multiplexed_async_connection_with_config(&config).await?;
//! con.subscribe(&["channel_1", "channel_2"]).await?;
//!
//! loop {
//!   println!("Received {:?}", rx.recv().await.unwrap());
//! }
//! # Ok(()) }
//! # }
//! ```
//!
//! sync example:
//!
//! ```rust,no_run
//! # {
//! # use redis::TypedCommands;
//!
//! # async fn func() -> redis::RedisResult<()> {
//! let client = redis::Client::open("redis://127.0.0.1/?protocol=resp3").unwrap();
//! let (tx, rx) = std::sync::mpsc::channel();
//! let mut con = client.get_connection().unwrap();
//! con.set_push_sender(tx);
//! con.subscribe_resp3(&["channel_1", "channel_2"])?;
//!
//! loop {
//!   std::thread::sleep(std::time::Duration::from_millis(10));
//!   // the connection only reads when actively polled, so it must constantly send and receive requests.
//!   _ = con.ping().unwrap();
//!   println!("Received {:?}", rx.try_recv().unwrap());
//! }
//! # Ok(()) }
//! # }
//!  ```
//!
//! # Iteration Protocol
//!
//! In addition to sending a single query, iterators are also supported.  When
//! used with regular bulk responses they don't give you much over querying and
//! converting into a vector (both use a vector internally) but they can also
//! be used with `SCAN` like commands in which case iteration will send more
//! queries until the cursor is exhausted:
//!
//! ```rust,ignore
//! # fn do_something() -> redis::RedisResult<()> {
//! # let client = redis::Client::open("redis://127.0.0.1/").unwrap();
//! # let mut con = client.get_connection().unwrap();
//! let mut iter : redis::Iter<isize> = redis::cmd("SSCAN").arg("my_set")
//!     .cursor_arg(0).clone().iter(&mut con)?;
//! for x in iter {
//!     // do something with the item
//! }
//! # Ok(()) }
//! ```
//!
//! As you can see the cursor argument needs to be defined with `cursor_arg`
//! instead of `arg` so that the library knows which argument needs updating
//! as the query is run for more items.
//!
//! # Pipelining
//!
//! In addition to simple queries you can also send command pipelines.  This
//! is provided through the `pipe` function.  It works very similar to sending
//! individual commands but you can send more than one in one go.  This also
//! allows you to ignore individual results so that matching on the end result
//! is easier:
//!
//! ```rust,no_run
//! # fn do_something() -> redis::RedisResult<()> {
//! # let client = redis::Client::open("redis://127.0.0.1/").unwrap();
//! # let mut con = client.get_connection().unwrap();
//! let (k1, k2) : (i32, i32) = redis::pipe()
//!     .cmd("SET").arg("key_1").arg(42).ignore()
//!     .cmd("SET").arg("key_2").arg(43).ignore()
//!     .cmd("GET").arg("key_1")
//!     .cmd("GET").arg("key_2").query(&mut con)?;
//! # Ok(()) }
//! ```
//!
//! If you want the pipeline to be wrapped in a `MULTI`/`EXEC` block you can
//! easily do that by switching the pipeline into `atomic` mode.  From the
//! caller's point of view nothing changes, the pipeline itself will take
//! care of the rest for you:
//!
//! ```rust,no_run
//! # fn do_something() -> redis::RedisResult<()> {
//! # let client = redis::Client::open("redis://127.0.0.1/").unwrap();
//! # let mut con = client.get_connection().unwrap();
//! let (k1, k2) : (i32, i32) = redis::pipe()
//!     .atomic()
//!     .cmd("SET").arg("key_1").arg(42).ignore()
//!     .cmd("SET").arg("key_2").arg(43).ignore()
//!     .cmd("GET").arg("key_1")
//!     .cmd("GET").arg("key_2").query(&mut con)?;
//! # Ok(()) }
//! ```
//!
//! You can also use high-level commands on pipelines:
//!
//! ```rust,no_run
//! # fn do_something() -> redis::RedisResult<()> {
//! # let client = redis::Client::open("redis://127.0.0.1/").unwrap();
//! # let mut con = client.get_connection().unwrap();
//! let (k1, k2) : (i32, i32) = redis::pipe()
//!     .atomic()
//!     .set("key_1", 42).ignore()
//!     .set("key_2", 43).ignore()
//!     .get("key_1")
//!     .get("key_2").query(&mut con)?;
//! # Ok(()) }
//! ```
//!
//! NOTE: Pipelines return a collection of results, even when there's only a single response.
//!       Make sure to wrap single-result pipeline responses in a collection. For example:
//!
//! ```rust,no_run
//! # let client = redis::Client::open("redis://127.0.0.1/").unwrap();
//! # let mut con = client.get_connection().unwrap();
//! let (k1,): (i32,) = redis::pipe()
//!     .cmd("SET").arg("key_1").arg(42).ignore()
//!     .cmd("GET").arg("key_1").query(&mut con).unwrap();
//! ```
//!
//! # Transactions
//!
//! Transactions are available through atomic pipelines.  In order to use
//! them in a more simple way you can use the `transaction` function of a
//! connection:
//!
//! ```rust,no_run
//! # fn do_something() -> redis::RedisResult<()> {
//! use redis::Commands;
//! # let client = redis::Client::open("redis://127.0.0.1/").unwrap();
//! # let mut con = client.get_connection().unwrap();
//! let key = "the_key";
//! let (new_val,) : (isize,) = redis::transaction(&mut con, &[key], |con, pipe| {
//!     let old_val : isize = con.get(key)?;
//!     pipe
//!         .set(key, old_val + 1).ignore()
//!         .get(key).query(con)
//! })?;
//! println!("The incremented number is: {}", new_val);
//! # Ok(()) }
//! ```
//!
//! For more information see the `transaction` function.
//!
//! # PubSub
//!
//! Pubsub is provided through the `PubSub` connection object for sync usage, or the `aio::PubSub`
//! for async usage.
//!
//! Example usage:
//!
//! ```rust,no_run
//! # fn do_something() -> redis::RedisResult<()> {
//! let client = redis::Client::open("redis://127.0.0.1/")?;
//! let mut con = client.get_connection()?;
//! let mut pubsub = con.as_pubsub();
//! pubsub.subscribe(&["channel_1", "channel_2"])?;
//!
//! loop {
//!     let msg = pubsub.get_message()?;
//!     let payload : String = msg.get_payload()?;
//!     println!("channel '{}': {}", msg.get_channel_name(), payload);
//! }
//! # }
//! ```
//! In order to update subscriptions while concurrently waiting for messages, the async PubSub can be split into separate sink & stream components. The sink can be receive subscription requests while the stream is awaited for messages.
//!
//! ```rust,no_run
//! # #[cfg(feature = "aio")]
//! use futures_util::StreamExt;
//! # #[cfg(feature = "aio")]
//! # async fn do_something() -> redis::RedisResult<()> {
//! let client = redis::Client::open("redis://127.0.0.1/")?;
//! let (mut sink, mut stream) = client.get_async_pubsub().await?.split();
//! sink.subscribe("channel_1").await?;
//!
//! loop {
//!     let msg = stream.next().await.unwrap();
//!     let payload : String = msg.get_payload().unwrap();
//!     println!("channel '{}': {}", msg.get_channel_name(), payload);
//! }
//! # Ok(()) }
//! ```
//!
#![deny(clippy::disallowed_macros)]
#![cfg_attr(test, allow(clippy::disallowed_macros))]
#![cfg_attr(
    feature = "script",
    doc = r##"
# Scripts

Lua scripts are supported through the `Script` type in a convenient
way.  It will automatically load the script if it does not exist and invoke it.

Example:

```rust,no_run
# fn do_something() -> redis::RedisResult<()> {
# let client = redis::Client::open("redis://127.0.0.1/").unwrap();
# let mut con = client.get_connection().unwrap();
let script = redis::Script::new(r"
    return tonumber(ARGV[1]) + tonumber(ARGV[2]);
");
let result: isize = script.arg(1).arg(2).invoke(&mut con)?;
assert_eq!(result, 3);
# Ok(()) }
```

Scripts can also be pipelined:

```rust,no_run
# fn do_something() -> redis::RedisResult<()> {
# let client = redis::Client::open("redis://127.0.0.1/").unwrap();
# let mut con = client.get_connection().unwrap();
let script = redis::Script::new(r"
    return tonumber(ARGV[1]) + tonumber(ARGV[2]);
");
let (a, b): (isize, isize) = redis::pipe()
    .invoke_script(script.arg(1).arg(2))
    .invoke_script(script.arg(2).arg(3))
    .query(&mut con)?;

assert_eq!(a, 3);
assert_eq!(b, 5);
# Ok(()) }
```

Note: unlike a call to [`invoke`](ScriptInvocation::invoke), if the script isn't loaded during the pipeline operation,
it will not automatically be loaded and retried. The script can be loaded using the
[`load`](ScriptInvocation::load) operation.
"##
)]
//!
#![cfg_attr(
    feature = "aio",
    doc = r##"
# Async

In addition to the synchronous interface that's been explained above there also exists an
asynchronous interface based on [`futures`][] and [`tokio`][] or [`smol`](https://docs.rs/smol/latest/smol/).
 All async connections are cheap to clone, and clones can be used concurrently from multiple threads.

This interface exists under the `aio` (async io) module (which requires that the `aio` feature
is enabled) and largely mirrors the synchronous with a few concessions to make it fit the
constraints of `futures`.

```rust,no_run
use futures::prelude::*;
use redis::AsyncTypedCommands;

# #[tokio::main]
# async fn main() -> redis::RedisResult<()> {
let client = redis::Client::open("redis://127.0.0.1/").unwrap();
let mut con = client.get_multiplexed_async_connection().await?;

con.set("key1", b"foo").await?;

redis::cmd("SET").arg(&["key2", "bar"]).exec_async(&mut con).await?;

let result = redis::cmd("MGET")
  .arg(&["key1", "key2"])
  .query_async(&mut con)
  .await;
assert_eq!(result, Ok(("foo".to_string(), b"bar".to_vec())));
# Ok(()) }
```

## Runtime support
The crate supports multiple runtimes, including `tokio` and `smol`. For Tokio, the crate will
spawn tasks on the current thread runtime. For smol, the crate will spawn tasks on the the global runtime.
It is recommended that the crate be used with support only for a single runtime. If the crate is compiled with multiple runtimes,
the user should call [`crate::aio::prefer_tokio`] or [`crate::aio::prefer_smol`] to set the preferred runtime.
These functions set global state which automatically chooses the correct runtime for the async connection.

"##
)]
//!
//! [`futures`]:https://crates.io/crates/futures
//! [`tokio`]:https://tokio.rs
#![cfg_attr(
    feature = "sentinel",
    doc = r##"
# Sentinel
Sentinel types allow users to connect to Redis sentinels and find primaries and replicas.

```rust,no_run
use redis::{ Commands, RedisConnectionInfo };
use redis::sentinel::{ SentinelServerType, SentinelClient, SentinelNodeConnectionInfo };

let nodes = vec!["redis://127.0.0.1:6379/", "redis://127.0.0.1:6378/", "redis://127.0.0.1:6377/"];
let sentinel_node_connection_info = SentinelNodeConnectionInfo::default()
  .set_tls_mode(redis::TlsMode::Insecure);
let mut sentinel = SentinelClient::build(
    nodes,
    String::from("primary1"),
    Some(sentinel_node_connection_info),
    redis::sentinel::SentinelServerType::Master,
)
.unwrap();

let primary = sentinel.get_connection().unwrap();
```

An async API also exists:

```rust,no_run
use futures::prelude::*;
use redis::{ Commands, RedisConnectionInfo };
use redis::sentinel::{ SentinelServerType, SentinelClient, SentinelNodeConnectionInfo };

# #[tokio::main]
# async fn main() -> redis::RedisResult<()> {
let nodes = vec!["redis://127.0.0.1:6379/", "redis://127.0.0.1:6378/", "redis://127.0.0.1:6377/"];
let sentinel_node_connection_info = SentinelNodeConnectionInfo::default()
  .set_tls_mode(redis::TlsMode::Insecure);
let mut sentinel = SentinelClient::build(
    nodes,
    String::from("primary1"),
    Some(sentinel_node_connection_info),
    redis::sentinel::SentinelServerType::Master,
)
.unwrap();

let primary = sentinel.get_async_connection().await.unwrap();
# Ok(()) }
```
"##
)]
//!
//! # Testing
//!
//! The [`redis-test`](https://docs.rs/redis-test) crate provides tools for testing Redis clients.
//! It includes a `MockRedisConnection` for unit testing without a real Redis server,
//! as well as helpers like `RedisCluster` and `RedisSentinelCluster` to easily spin up
//! local Redis clusters and Sentinels for integration tests.
//!
//! # Upgrading to version 1
//!
//! * Iterators are now safe by default, without an opt out. This means that the iterators return `RedisResult<Value>` instead of `Value`. See [this PR](https://github.com/redis-rs/redis-rs/pull/1641) for background. If you previously used the "safe_iterators" feature to opt-in to this behavior, just remove the feature declaration. Otherwise you will need to adjust your usage of iterators to account for potential conversion failures.
//! * Parsing values using [FromRedisValue] no longer returns [RedisError] on failure, in order to save the users checking for various server & client errors in such scenarios. if you rely on the error type when using this trait, you will need to adjust your error handling code. [ParsingError] should only be printed, since it does not contain any user actionable info outside of its error message.
//! * If you used the `tcp_nodelay` or `keep-alive` features, you'll need to set these values on the connection info you pass to the client use [ConnectionInfo::set_tcp_settings].
//! * If you used the `disable-client-setinfo` features, you'll need to set [RedisConnectionInfo::skip_set_lib_name].
//! * If you create [ConnectionInfo], [RedisConnectionInfo], or [sentinel::SentinelNodeConnectionInfo] objects explicitly, now you need to use the builder pattern setters instead of setting fields.
//! * if you used `MultiplexedConnection::new_with_response_timeout`, it is replaced by [aio::MultiplexedConnection::new_with_config]. `Client::get_multiplexed_tokio_connection_with_response_timeouts`, `Client::get_multiplexed_tokio_connection`, `Client::create_multiplexed_tokio_connection_with_response_timeout`, `Client::create_multiplexed_tokio_connection` were replaced by [Client::get_multiplexed_async_connection_with_config].
//! * If you're using `tokio::time::pause()` or otherwise manipulating time, you might need to opt out of timeouts using `AsyncConnectionConfig::new().set_connection_timeout(None).set_response_timeout(None)`.
//! * Async connections now have default timeouts. If you're using blocking commands or other potentially long running commands, you should adjust the timeouts accordingly.
//! * If you're manually setting `ConnectionManager`'s retry setting, then please re-examine the values you set. `exponential_base` has been made a f32, and `factor` was replaced by `min_delay`, in order to match the documented behavior, instead of the actual erroneous behavior of past versions.
//! * Vector set types have been moved into the `vector_sets` module, instead of being exposed directly.
//! * ErrorKind::TypeError was renamed ErrorKind::UnexpectedReturnType, to clarify its meaning. Also fixed some cases where it and ErrorKind::Parse were used interchangeably.
//! * Connecting to a wildcard address (`0.0.0.0` or `::`) is now explicitly disallowed and will return an error. This change prevents connection timeouts and provides a clearer error message. This affects both standalone and cluster connections. Users relying on this behavior should now connect to a specific, non-wildcard address.
//! * If you implemented [crate::FromRedisValue] directly, or used `FromRedisValue::from_redis_value`/`FromRedisValue::from_owned_redis_value`, notice that the trait's semantics changed - now the trait requires an owned value by default, instead of a reference. See [the PR](https://github.com/redis-rs/redis-rs/pull/1784) for details.
//! * The implicit replacement of `GET` with `MGET` or `SET` with `MSET` has been replaced, and limited these and other commands to only take values that serialize into single redis values, as enforced by a compilation failure. Example:
//!
//! ```rust,no_run,compile_fail
//! use redis::Commands;
//! fn main() -> redis::RedisResult<()> {
//!     let client = redis::Client::open("redis://127.0.0.1/")?;
//!     let mut con = client.get_connection()?;
//!     // `get` should fail compilation, because it receives multiple values
//!     _ = con.get(["foo","bar"]);
//!     Ok(())
//! }
//! ```
//!
//!

#![deny(non_camel_case_types)]
#![warn(missing_docs)]
#![cfg_attr(docsrs, warn(rustdoc::broken_intra_doc_links))]
// When on docs.rs we want to show tuple variadics in the docs.
// This currently requires internal/unstable features in Rustdoc.
#![cfg_attr(
    docsrs,
    feature(doc_cfg, rustdoc_internals),
    expect(
        internal_features,
        reason = "rustdoc_internals is needed for fake_variadic"
    )
)]
#![cfg_attr(not(test), forbid(clippy::print_stdout))]
#![cfg_attr(not(test), forbid(clippy::panic))]
#![cfg_attr(not(test), forbid(clippy::infinite_loop))]
// #![cfg_attr(not(test), forbid(clippy::cast_possible_truncation))]

// public api
#[cfg(feature = "aio")]
pub use crate::client::AsyncConnectionConfig;
pub use crate::client::Client;
#[cfg(feature = "cache-aio")]
pub use crate::cmd::CommandCacheConfig;
pub use crate::cmd::{Arg, Cmd, Iter, cmd, pack_command, pipe};
pub use crate::commands::{
    Commands, ControlFlow, CopyOptions, Direction, FlushAllOptions, FlushDbOptions,
    HashFieldExpirationOptions, HotkeysCommands, IncrexOptions, LposOptions, MSetOptions,
    PubSubCommands, ScanOptions, SetOptions, SortedSetAddOptions, TypedCommands, UpdateCheck,
    hotkeys::{
        HOTKEYS_COUNT_MAX, HOTKEYS_COUNT_MIN, HotKeyEntry, HotkeysOptions, HotkeysResponse,
        SlotRange,
    },
};
pub use crate::connection::{
    Connection, ConnectionAddr, ConnectionInfo, ConnectionLike, IntoConnectionInfo, Msg, PubSub,
    RedisConnectionInfo, TlsMode, parse_redis_url, transaction,
};
pub use crate::parser::{Parser, parse_redis_value};
pub use crate::pipeline::Pipeline;
#[cfg(feature = "script")]
#[cfg_attr(docsrs, doc(cfg(feature = "script")))]
pub use crate::script::{Script, ScriptInvocation};
#[cfg(feature = "token-based-authentication")]
pub use crate::{
    auth::{BasicAuth, StreamingCredentialsProvider},
    auth_management::{RetryConfig, TokenRefreshConfig},
};
#[cfg(feature = "entra-id")]
pub use {
    crate::entra_id::{ClientCertificate, EntraIdCredentialsProvider, REDIS_SCOPE_DEFAULT},
    azure_identity::{
        ClientCertificateCredentialOptions, ClientSecretCredentialOptions,
        DeveloperToolsCredentialOptions, ManagedIdentityCredentialOptions, UserAssignedId,
    },
};

// preserve grouping and order
#[rustfmt::skip]
pub use crate::types::{
    // utility functions
    from_redis_value_ref,
    from_redis_value,

    // conversion traits
    FromRedisValue,

    // utility types
    InfoDict,
    NumericBehavior,
    Expiry,
    SetExpiry,
    ExistenceCheck,
    FieldExistenceCheck,
    ExpireOption,
    Role,
    ReplicaInfo,
    IntegerReplyOrNoOp,
    IncrexResult,
    ValueType,
    RedisResult,
    RedisWrite,
    ToRedisArgs,
    ToSingleRedisArg,
    ValueComparison,

    // low level values
    Value,
    PushKind,
    VerbatimFormat,
    ProtocolVersion,
    PushInfo,
};

pub use crate::types::{calculate_value_digest, is_valid_16_bytes_hex_digest};

pub use crate::errors::{
    ErrorKind, ParsingError, RedisError, RetryMethod, ServerError, ServerErrorKind,
    make_extension_error,
};

#[cfg(feature = "aio")]
#[cfg_attr(docsrs, doc(cfg(feature = "aio")))]
pub use crate::{
    cmd::AsyncIter, commands::AsyncCommands, commands::AsyncTypedCommands,
    parser::parse_redis_value_async, types::RedisFuture,
};

mod macros;
mod pipeline;

#[cfg(feature = "acl")]
#[cfg_attr(docsrs, doc(cfg(feature = "acl")))]
pub use commands::acl;

#[cfg(feature = "aio")]
#[cfg_attr(docsrs, doc(cfg(feature = "aio")))]
pub mod aio;

#[cfg(feature = "bloom")]
#[cfg_attr(docsrs, doc(cfg(feature = "bloom")))]
pub mod bloom;

#[cfg(feature = "json")]
#[cfg_attr(docsrs, doc(cfg(feature = "json")))]
pub use crate::commands::{JsonCommands, json};

#[cfg(all(feature = "json", feature = "aio"))]
#[cfg_attr(docsrs, doc(cfg(all(feature = "json", feature = "aio"))))]
pub use crate::commands::JsonAsyncCommands;

#[cfg(feature = "aio")]
#[cfg_attr(docsrs, doc(cfg(feature = "aio")))]
pub use crate::commands::AsyncHotkeysCommands;

#[cfg(feature = "vector-sets")]
#[cfg_attr(docsrs, doc(cfg(feature = "vector-sets")))]
pub use crate::commands::vector_sets;

#[cfg(feature = "search_unfinished")]
#[cfg_attr(docsrs, doc(cfg(feature = "search_unfinished")))]
pub use crate::commands::search;

#[cfg(feature = "geospatial")]
#[cfg_attr(docsrs, doc(cfg(feature = "geospatial")))]
pub use commands::geo;

#[cfg(any(feature = "connection-manager", feature = "cluster-async"))]
mod subscription_tracker;

#[cfg(feature = "cluster")]
mod cluster_handling;

#[cfg(feature = "cluster")]
#[cfg_attr(docsrs, doc(cfg(feature = "cluster")))]
pub use cluster_handling::sync_connection as cluster;

/// Routing information for cluster commands.
#[cfg(feature = "cluster")]
#[cfg_attr(docsrs, doc(cfg(feature = "cluster")))]
pub use cluster_handling::routing as cluster_routing;

/// Pluggable read routing strategies for cluster connections.
#[cfg(feature = "cluster")]
#[cfg_attr(docsrs, doc(cfg(feature = "cluster")))]
pub use cluster_handling::read_routing as cluster_read_routing;

#[cfg(feature = "r2d2")]
#[cfg_attr(docsrs, doc(cfg(feature = "r2d2")))]
mod r2d2;

#[cfg(all(feature = "bb8", feature = "aio"))]
#[cfg_attr(docsrs, doc(cfg(all(feature = "bb8", feature = "aio"))))]
mod bb8;

#[cfg(feature = "streams")]
#[cfg_attr(docsrs, doc(cfg(feature = "streams")))]
pub use commands::streams;

#[cfg(feature = "cluster-async")]
#[cfg_attr(docsrs, doc(cfg(all(feature = "cluster", feature = "aio"))))]
pub use cluster_handling::async_connection as cluster_async;

#[cfg(feature = "sentinel")]
#[cfg_attr(docsrs, doc(cfg(feature = "sentinel")))]
pub mod sentinel;

#[cfg(feature = "tls-rustls")]
mod tls;

#[cfg(feature = "tls-rustls")]
#[cfg_attr(docsrs, doc(cfg(feature = "tls-rustls")))]
pub use crate::tls::{ClientTlsConfig, TlsCertificates};

#[cfg(feature = "cache-aio")]
#[cfg_attr(docsrs, doc(cfg(feature = "cache-aio")))]
pub mod caching;

#[cfg(feature = "entra-id")]
#[cfg_attr(docsrs, doc(cfg(feature = "entra-id")))]
pub mod entra_id;

#[cfg(feature = "token-based-authentication")]
#[cfg_attr(docsrs, doc(cfg(feature = "token-based-authentication")))]
pub mod auth;
#[cfg(feature = "token-based-authentication")]
#[cfg_attr(docsrs, doc(cfg(feature = "token-based-authentication")))]
pub mod auth_management;

mod client;
mod cmd;
mod commands;
mod connection;
mod errors;
/// Module for defining I/O behavior.
pub mod io;
mod parser;
mod script;
mod types;

macro_rules! check_resp3 {
    ($protocol: expr) => {
        if !$protocol.supports_resp3() {
            return Err(RedisError::from((
                crate::ErrorKind::InvalidClientConfig,
                "RESP3 is required for this command",
            )));
        }
    };

    ($protocol: expr, $message: expr) => {
        if !$protocol.supports_resp3() {
            return Err(RedisError::from((
                crate::ErrorKind::InvalidClientConfig,
                $message,
            )));
        }
    };
}

pub(crate) use check_resp3;

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn test_is_send() {
        const fn assert_send<T: Send>() {}

        assert_send::<Connection>();
        #[cfg(feature = "cluster")]
        assert_send::<cluster::ClusterConnection>();
    }
}
