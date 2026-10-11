use std::time::Duration;

#[cfg(feature = "aio")]
use crate::aio::{AsyncPushSender, DefaultAsyncDNSResolver};
#[cfg(feature = "token-based-authentication")]
use crate::auth::StreamingCredentialsProvider;
#[cfg(feature = "aio")]
use crate::io::AsyncDNSResolver;
use crate::{
    connection::{Connection, ConnectionInfo, ConnectionLike, IntoConnectionInfo, connect},
    types::{RedisResult, Value},
};
#[cfg(feature = "aio")]
use std::pin::Pin;

#[cfg(feature = "tls-rustls")]
use crate::tls::{TlsCertificates, inner_build_with_tls};

#[cfg(feature = "cache-aio")]
use crate::caching::CacheConfig;
#[cfg(all(
    feature = "cache-aio",
    any(feature = "connection-manager", feature = "cluster-async")
))]
use crate::caching::CacheManager;

/// The client type.
#[derive(Debug, Clone)]
pub struct Client {
    pub(crate) connection_info: ConnectionInfo,
}

/// The client acts as connector to the redis server.  By itself it does not
/// do much other than providing a convenient way to fetch a connection from
/// it.  In the future the plan is to provide a connection pool in the client.
///
/// When opening a client a URL in the following format should be used:
///
/// ```plain
/// redis://host:port/db
/// ```
///
/// Example usage::
///
/// ```rust,no_run
/// let client = redis::Client::open("redis://127.0.0.1/").unwrap();
/// let con = client.get_connection().unwrap();
/// ```
impl Client {
    /// Connects to a redis server and returns a client.  This does not
    /// actually open a connection yet but it does perform some basic
    /// checks on the URL that might make the operation fail.
    pub fn open<T: IntoConnectionInfo>(params: T) -> RedisResult<Self> {
        Ok(Self {
            connection_info: params.into_connection_info()?,
        })
    }

    /// Instructs the client to actually connect to redis and returns a
    /// connection object.  The connection object can be used to send
    /// commands to the server.  This can fail with a variety of errors
    /// (like unreachable host) so it's important that you handle those
    /// errors.
    pub fn get_connection(&self) -> RedisResult<Connection> {
        connect(&self.connection_info, None)
    }

    /// Instructs the client to actually connect to redis with specified
    /// timeout and returns a connection object.  The connection object
    /// can be used to send commands to the server.  This can fail with
    /// a variety of errors (like unreachable host) so it's important
    /// that you handle those errors.
    pub fn get_connection_with_timeout(&self, timeout: Duration) -> RedisResult<Connection> {
        connect(&self.connection_info, Some(timeout))
    }

    /// Returns a reference of client connection info object.
    pub fn get_connection_info(&self) -> &ConnectionInfo {
        &self.connection_info
    }

    /// Constructs a new `Client` with parameters necessary to create a TLS connection.
    ///
    /// - `conn_info` - URL using the `rediss://` scheme.
    /// - `tls_certs` - `TlsCertificates` structure containing:
    ///     - `client_tls` - Optional `ClientTlsConfig` containing byte streams for
    ///         - `client_cert` - client's byte stream containing client certificate in PEM format
    ///         - `client_key` - client's byte stream containing private key in PEM format
    ///     - `root_cert` - Optional byte stream yielding PEM formatted file for root certificates.
    ///
    /// If `ClientTlsConfig` ( cert+key pair ) is not provided, then client-side authentication is not enabled.
    /// If `root_cert` is not provided, then system root certificates are used instead.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// use std::{fs::File, io::{BufReader, Read}};
    ///
    /// use redis::{Client, AsyncTypedCommands as _, TlsCertificates, ClientTlsConfig};
    ///
    /// async fn do_redis_code(
    ///     url: &str,
    ///     root_cert_file: &str,
    ///     cert_file: &str,
    ///     key_file: &str
    /// ) -> redis::RedisResult<()> {
    ///     let root_cert_file = File::open(root_cert_file).expect("cannot open private cert file");
    ///     let mut root_cert_vec = Vec::new();
    ///     BufReader::new(root_cert_file)
    ///         .read_to_end(&mut root_cert_vec)
    ///         .expect("Unable to read ROOT cert file");
    ///
    ///     let cert_file = File::open(cert_file).expect("cannot open private cert file");
    ///     let mut client_cert_vec = Vec::new();
    ///     BufReader::new(cert_file)
    ///         .read_to_end(&mut client_cert_vec)
    ///         .expect("Unable to read client cert file");
    ///
    ///     let key_file = File::open(key_file).expect("cannot open private key file");
    ///     let mut client_key_vec = Vec::new();
    ///     BufReader::new(key_file)
    ///         .read_to_end(&mut client_key_vec)
    ///         .expect("Unable to read client key file");
    ///
    ///     let client = Client::build_with_tls(
    ///         url,
    ///         TlsCertificates {
    ///             client_tls: Some(ClientTlsConfig{
    ///                 client_cert: client_cert_vec,
    ///                 client_key: client_key_vec,
    ///             }),
    ///             root_cert: Some(root_cert_vec),
    ///         }
    ///     )
    ///     .expect("Unable to build client");
    ///
    ///     let connection_info = client.get_connection_info();
    ///
    ///     println!(">>> connection info: {connection_info:?}");
    ///
    ///     let mut con = client.get_multiplexed_async_connection().await?;
    ///
    ///     con.set("key1", b"foo").await?;
    ///
    ///     redis::cmd("SET")
    ///         .arg(&["key2", "bar"])
    ///         .exec_async(&mut con)
    ///         .await?;
    ///
    ///     let result = redis::cmd("MGET")
    ///         .arg(&["key1", "key2"])
    ///         .query_async(&mut con)
    ///         .await;
    ///     assert_eq!(result, Ok(("foo".to_string(), b"bar".to_vec())));
    ///     println!("Result from MGET: {result:?}");
    ///
    ///     Ok(())
    /// }
    /// ```
    #[cfg(feature = "tls-rustls")]
    pub fn build_with_tls<C: IntoConnectionInfo>(
        conn_info: C,
        tls_certs: TlsCertificates,
    ) -> RedisResult<Self> {
        let connection_info = conn_info.into_connection_info()?;

        inner_build_with_tls(connection_info, &tls_certs)
    }
}

#[cfg(feature = "cache-aio")]
#[derive(Clone)]
pub(crate) enum Cache {
    Config(CacheConfig),
    #[cfg(any(feature = "connection-manager", feature = "cluster-async"))]
    Manager(CacheManager),
}

#[cfg(feature = "aio")]
pub(crate) const DEFAULT_RESPONSE_TIMEOUT: Option<Duration> = Some(Duration::from_millis(500));
#[cfg(any(feature = "aio", feature = "cluster"))]
pub(crate) const DEFAULT_CONNECTION_TIMEOUT: Option<Duration> = Some(Duration::from_secs(1));

/// Options for creation of async connection
#[cfg(feature = "aio")]
#[derive(Clone)]
pub struct AsyncConnectionConfig {
    /// Maximum time to wait for a response from the server
    pub(crate) response_timeout: Option<Duration>,
    /// Maximum time to wait for a connection to be established
    pub(crate) connection_timeout: Option<Duration>,
    pub(crate) push_sender: Option<std::sync::Arc<dyn AsyncPushSender>>,
    #[cfg(feature = "cache-aio")]
    pub(crate) cache: Option<Cache>,
    pub(crate) dns_resolver: Option<std::sync::Arc<dyn AsyncDNSResolver>>,
    pub(crate) pipeline_buffer_size: Option<usize>,
    pub(crate) concurrency_limit: Option<usize>,
    /// Flush threshold for the outbound write buffer; see [`AsyncConnectionConfig::set_write_backpressure_boundary`].
    pub(crate) write_backpressure_boundary: Option<usize>,
    /// Optional credentials provider for dynamic authentication (e.g., token-based authentication)
    #[cfg(feature = "token-based-authentication")]
    pub(crate) credentials_provider: Option<std::sync::Arc<dyn StreamingCredentialsProvider>>,
}

#[cfg(feature = "aio")]
impl Default for AsyncConnectionConfig {
    fn default() -> Self {
        Self {
            response_timeout: DEFAULT_RESPONSE_TIMEOUT,
            connection_timeout: DEFAULT_CONNECTION_TIMEOUT,
            push_sender: Default::default(),
            #[cfg(feature = "cache-aio")]
            cache: Default::default(),
            dns_resolver: Default::default(),
            pipeline_buffer_size: None,
            concurrency_limit: None,
            write_backpressure_boundary: None,
            #[cfg(feature = "token-based-authentication")]
            credentials_provider: None,
        }
    }
}

#[cfg(feature = "aio")]
impl AsyncConnectionConfig {
    /// Creates a new instance of the config with all parameters set to default values.
    pub fn new() -> Self {
        Self::default()
    }

    /// Each connection attempt to the server will time out after `connection_timeout`.
    ///
    /// Set `None` if you don't want the connection attempt to time out.
    pub fn set_connection_timeout(mut self, connection_timeout: Option<Duration>) -> Self {
        self.connection_timeout = connection_timeout;
        self
    }

    /// The new connection will time out operations after `response_timeout` has passed.
    ///
    /// Set `None` if you don't want requests to time out.
    pub fn set_response_timeout(mut self, response_timeout: Option<Duration>) -> Self {
        self.response_timeout = response_timeout;
        self
    }

    /// Sets sender sender for push values.
    ///
    /// The sender can be a channel, or an arbitrary function that handles [crate::PushInfo] values.
    /// This will fail client creation if the connection isn't configured for RESP3 communications via the [crate::RedisConnectionInfo::set_protocol] function.
    ///
    /// # Examples
    ///
    /// ```rust
    /// # use redis::AsyncConnectionConfig;
    /// let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    /// let config = AsyncConnectionConfig::new().set_push_sender(tx);
    /// ```
    ///
    /// ```rust
    /// # use std::sync::{Mutex, Arc};
    /// # use redis::AsyncConnectionConfig;
    /// let messages = Arc::new(Mutex::new(Vec::new()));
    /// let config = AsyncConnectionConfig::new().set_push_sender(move |msg|{
    ///     let Ok(mut messages) = messages.lock() else {
    ///         return Err(redis::aio::SendError);
    ///     };
    ///     messages.push(msg);
    ///     Ok(())
    /// });
    /// ```
    pub fn set_push_sender(self, sender: impl AsyncPushSender) -> Self {
        self.set_push_sender_internal(std::sync::Arc::new(sender))
    }

    pub(crate) fn set_push_sender_internal(
        mut self,
        sender: std::sync::Arc<dyn AsyncPushSender>,
    ) -> Self {
        self.push_sender = Some(sender);
        self
    }

    /// Sets cache config for MultiplexedConnection, check CacheConfig for more details.
    #[cfg(feature = "cache-aio")]
    pub fn set_cache_config(mut self, cache_config: CacheConfig) -> Self {
        self.cache = Some(Cache::Config(cache_config));
        self
    }

    #[cfg(all(
        feature = "cache-aio",
        any(feature = "connection-manager", feature = "cluster-async")
    ))]
    pub(crate) fn set_cache_manager(mut self, cache_manager: CacheManager) -> Self {
        self.cache = Some(Cache::Manager(cache_manager));
        self
    }

    /// Set the DNS resolver for the underlying TCP connection.
    ///
    /// The parameter resolver must implement the [`crate::io::AsyncDNSResolver`] trait.
    pub fn set_dns_resolver(self, dns_resolver: impl AsyncDNSResolver) -> Self {
        self.set_dns_resolver_internal(std::sync::Arc::new(dns_resolver))
    }

    pub(super) fn set_dns_resolver_internal(
        mut self,
        dns_resolver: std::sync::Arc<dyn AsyncDNSResolver>,
    ) -> Self {
        self.dns_resolver = Some(dns_resolver);
        self
    }

    /// Sets the buffer size for the internal pipeline channel.
    ///
    /// The multiplexed connection uses an internal channel to queue Redis commands
    /// before sending them to the server. This setting controls how many commands
    /// can be buffered in that channel.
    ///
    /// When the buffer is full, callers will asynchronously wait until space becomes
    /// available. A larger buffer allows more commands to be queued during bursts of
    /// activity, reducing wait time for callers. However, this comes at the cost of
    /// increased memory usage.
    ///
    /// The default value is 50. Consider increasing this value for high-concurrency
    /// scenarios (e.g., web servers handling many simultaneous requests) where
    /// buffer contention may increase overall latency and cause upstream timeouts.
    pub fn set_pipeline_buffer_size(mut self, size: usize) -> Self {
        self.pipeline_buffer_size = Some(size);
        self
    }

    /// Sets the maximum number of concurrent in-flight requests on this connection.
    ///
    /// When set, at most `limit` requests can be awaiting a response at any given time.
    /// Additional requests will wait until an in-flight request completes.
    ///
    /// Pipelined commands try to acquire one permit per command, but will proceed with
    /// fewer if not all are immediately available. This means a pipeline may temporarily
    /// push the effective in-flight count above the limit.
    ///
    /// This is useful for preventing a large backlog of commands from building up when the
    /// server becomes slow or unresponsive. Without a limit, requests continue to queue
    /// unboundedly. When the server is degraded, requests near the back of the queue spend
    /// most of their time waiting behind earlier requests and are likely to hit their response
    /// timeout before the server even processes them -- wasting work on both sides. Setting a
    /// concurrency limit caps the number of in-flight requests, so backpressure is applied
    /// earlier and fewer requests are lost to timeouts.
    ///
    /// By default there is no limit.
    pub fn set_concurrency_limit(mut self, limit: usize) -> Self {
        self.concurrency_limit = Some(limit);
        self
    }

    /// Sets the flush threshold (backpressure boundary) for the outbound write buffer.
    ///
    /// The multiplexed connection encodes commands into an in-memory buffer before
    /// writing them to the socket. This value controls how many bytes may accumulate
    /// in that buffer before the connection flushes to the socket and applies
    /// backpressure to newly queued commands.
    ///
    /// With a small threshold the buffer flushes frequently and, when commands are
    /// produced faster than the socket drains, it repeatedly grows by reallocation. A
    /// larger threshold lets the buffer reach a stable capacity and batch larger writes,
    /// trading a higher peak memory bound (roughly this many bytes per connection) for
    /// fewer reallocations and syscalls. The buffer still grows lazily, so idle
    /// connections do not hold this much memory.
    ///
    /// When left unset, the connection keeps `tokio_util`'s default boundary (8 KiB).
    pub fn set_write_backpressure_boundary(mut self, boundary: usize) -> Self {
        self.write_backpressure_boundary = Some(boundary);
        self
    }

    /// Sets a credentials provider for dynamic authentication (e.g., token-based authentication).
    ///
    /// This is useful for authentication mechanisms that require periodic credential refresh,
    /// such as Microsoft Entra ID (formerly Azure AD).
    ///
    /// # Example
    ///
    /// ```rust,no_run
    /// # #[cfg(feature = "entra-id")]
    /// # {
    /// use redis::{AsyncConnectionConfig, EntraIdCredentialsProvider, RetryConfig};
    ///
    /// # async fn example() -> redis::RedisResult<()> {
    /// let mut provider = EntraIdCredentialsProvider::new_developer_tools()?;
    /// provider.start(RetryConfig::default());
    ///
    /// let config = AsyncConnectionConfig::new()
    ///     .set_credentials_provider(provider);
    /// # Ok(())
    /// # }
    /// # }
    /// ```
    #[cfg(feature = "token-based-authentication")]
    pub fn set_credentials_provider<P>(self, provider: P) -> Self
    where
        P: StreamingCredentialsProvider + 'static,
    {
        self.set_credentials_provider_internal(std::sync::Arc::new(provider))
    }

    #[cfg(feature = "token-based-authentication")]
    pub(crate) fn set_credentials_provider_internal(
        mut self,
        provider: std::sync::Arc<dyn StreamingCredentialsProvider>,
    ) -> Self {
        self.credentials_provider = Some(provider);
        self
    }
}

/// To enable async support you need to chose one of the supported runtimes and active its
/// corresponding feature: `tokio-comp` or `smol-comp`
#[cfg(feature = "aio")]
#[cfg_attr(docsrs, doc(cfg(feature = "aio")))]
impl Client {
    /// Returns an async connection from the client.
    #[cfg(feature = "aio")]
    #[cfg_attr(docsrs, doc(cfg(feature = "aio")))]
    pub async fn get_multiplexed_async_connection(
        &self,
    ) -> RedisResult<crate::aio::MultiplexedConnection> {
        self.get_multiplexed_async_connection_with_config(&AsyncConnectionConfig::new())
            .await
    }

    /// Returns an async connection from the client.
    #[cfg(feature = "aio")]
    #[cfg_attr(docsrs, doc(cfg(feature = "aio")))]
    pub async fn get_multiplexed_async_connection_with_config(
        &self,
        config: &AsyncConnectionConfig,
    ) -> RedisResult<crate::aio::MultiplexedConnection> {
        match Runtime::locate() {
            #[cfg(feature = "tokio-comp")]
            rt @ Runtime::Tokio => self
                .get_multiplexed_async_connection_inner_with_timeout::<crate::aio::tokio::Tokio>(
                    config, rt,
                )
                .await,

            #[cfg(feature = "smol-comp")]
            rt @ Runtime::Smol => {
                self.get_multiplexed_async_connection_inner_with_timeout::<crate::aio::smol::Smol>(
                    config, rt,
                )
                .await
            }
        }
    }

    /// Returns an async [`ConnectionManager`][connection-manager] from the client.
    ///
    /// The connection manager wraps a
    /// [`MultiplexedConnection`][multiplexed-connection]. If a command to that
    /// connection fails with a connection error, then a new connection is
    /// established in the background and the error is returned to the caller.
    ///
    /// This means that on connection loss at least one command will fail, but
    /// the connection will be re-established automatically if possible. Please
    /// refer to the [`ConnectionManager`][connection-manager] docs for
    /// detailed reconnecting behavior.
    ///
    /// A connection manager can be cloned, allowing requests to be sent concurrently
    /// on the same underlying connection (tcp/unix socket).
    ///
    /// [connection-manager]: aio/struct.ConnectionManager.html
    /// [multiplexed-connection]: aio/struct.MultiplexedConnection.html
    #[cfg(feature = "connection-manager")]
    #[cfg_attr(docsrs, doc(cfg(feature = "connection-manager")))]
    pub async fn get_connection_manager(&self) -> RedisResult<crate::aio::ConnectionManager> {
        crate::aio::ConnectionManager::new(self.clone()).await
    }

    /// Returns an async [`ConnectionManager`][connection-manager] from the client without establishing a connection.
    ///
    /// The connection will be established lazily on the first request.
    ///
    /// [connection-manager]: aio/struct.ConnectionManager.html
    #[cfg(feature = "connection-manager")]
    #[cfg_attr(docsrs, doc(cfg(feature = "connection-manager")))]
    pub fn get_connection_manager_lazy(
        &self,
        config: crate::aio::ConnectionManagerConfig,
    ) -> RedisResult<crate::aio::ConnectionManager> {
        crate::aio::ConnectionManager::new_lazy_with_config(self.clone(), config)
    }

    /// Returns an async [`ConnectionManager`][connection-manager] from the client.
    ///
    /// The connection manager wraps a
    /// [`MultiplexedConnection`][multiplexed-connection]. If a command to that
    /// connection fails with a connection error, then a new connection is
    /// established in the background and the error is returned to the caller.
    ///
    /// This means that on connection loss at least one command will fail, but
    /// the connection will be re-established automatically if possible. Please
    /// refer to the [`ConnectionManager`][connection-manager] docs for
    /// detailed reconnecting behavior.
    ///
    /// A connection manager can be cloned, allowing requests to be sent concurrently
    /// on the same underlying connection (tcp/unix socket).
    ///
    /// [connection-manager]: aio/struct.ConnectionManager.html
    /// [multiplexed-connection]: aio/struct.MultiplexedConnection.html
    #[cfg(feature = "connection-manager")]
    #[cfg_attr(docsrs, doc(cfg(feature = "connection-manager")))]
    pub async fn get_connection_manager_with_config(
        &self,
        config: crate::aio::ConnectionManagerConfig,
    ) -> RedisResult<crate::aio::ConnectionManager> {
        crate::aio::ConnectionManager::new_with_config(self.clone(), config).await
    }

    async fn get_multiplexed_async_connection_inner_with_timeout<T>(
        &self,
        config: &AsyncConnectionConfig,
        rt: Runtime,
    ) -> RedisResult<crate::aio::MultiplexedConnection>
    where
        T: crate::aio::RedisRuntime,
    {
        let result = if let Some(connection_timeout) = config.connection_timeout {
            rt.timeout(
                connection_timeout,
                self.get_multiplexed_async_connection_inner::<T>(config),
            )
            .await
        } else {
            Ok(self
                .get_multiplexed_async_connection_inner::<T>(config)
                .await)
        };

        match result {
            Ok(Ok(connection)) => Ok(connection),
            Ok(Err(e)) => Err(e),
            Err(elapsed) => Err(elapsed.into()),
        }
    }

    async fn get_multiplexed_async_connection_inner<T>(
        &self,
        config: &AsyncConnectionConfig,
    ) -> RedisResult<crate::aio::MultiplexedConnection>
    where
        T: crate::aio::RedisRuntime,
    {
        let (mut connection, driver) = self
            .create_multiplexed_async_connection_inner::<T>(config)
            .await?;
        let handle = T::spawn(driver);
        connection.set_task_handle(handle);
        Ok(connection)
    }

    async fn create_multiplexed_async_connection_inner<T>(
        &self,
        config: &AsyncConnectionConfig,
    ) -> RedisResult<(
        crate::aio::MultiplexedConnection,
        impl std::future::Future<Output = ()> + 'static,
    )>
    where
        T: crate::aio::RedisRuntime,
    {
        let resolver = config
            .dns_resolver
            .as_deref()
            .unwrap_or(&DefaultAsyncDNSResolver);
        let con = self.get_simple_async_connection::<T>(resolver).await?;
        crate::aio::MultiplexedConnection::new_with_config(
            &self.connection_info.redis,
            con,
            config.clone(),
        )
        .await
    }

    async fn get_simple_async_connection_dynamically(
        &self,
        dns_resolver: &dyn AsyncDNSResolver,
    ) -> RedisResult<Pin<Box<dyn crate::aio::AsyncStream + Send + Sync>>> {
        match Runtime::locate() {
            #[cfg(feature = "tokio-comp")]
            Runtime::Tokio => {
                self.get_simple_async_connection::<crate::aio::tokio::Tokio>(dns_resolver)
                    .await
            }

            #[cfg(feature = "smol-comp")]
            Runtime::Smol => {
                self.get_simple_async_connection::<crate::aio::smol::Smol>(dns_resolver)
                    .await
            }
        }
    }

    async fn get_simple_async_connection<T>(
        &self,
        dns_resolver: &dyn AsyncDNSResolver,
    ) -> RedisResult<Pin<Box<dyn crate::aio::AsyncStream + Send + Sync>>>
    where
        T: crate::aio::RedisRuntime,
    {
        Ok(
            crate::aio::connect_simple::<T>(&self.connection_info, dns_resolver)
                .await?
                .boxed(),
        )
    }

    #[cfg(feature = "connection-manager")]
    pub(crate) fn connection_info(&self) -> &ConnectionInfo {
        &self.connection_info
    }

    /// Returns an async receiver for pub-sub messages.
    #[cfg(feature = "aio")]
    // TODO - do we want to type-erase pubsub using a trait, to allow us to replace it with a different implementation later?
    pub async fn get_async_pubsub(&self) -> RedisResult<crate::aio::PubSub> {
        let connection = self
            .get_simple_async_connection_dynamically(&DefaultAsyncDNSResolver)
            .await?;

        crate::aio::PubSub::new(&self.connection_info.redis, connection).await
    }

    /// Returns an async receiver for monitor messages.
    #[cfg(feature = "aio")]
    pub async fn get_async_monitor(&self) -> RedisResult<crate::aio::Monitor> {
        let connection = self
            .get_simple_async_connection_dynamically(&DefaultAsyncDNSResolver)
            .await?;
        crate::aio::Monitor::new(&self.connection_info.redis, connection).await
    }
}

#[cfg(feature = "aio")]
use crate::aio::Runtime;

impl ConnectionLike for Client {
    fn req_packed_command(&mut self, cmd: &[u8]) -> RedisResult<Value> {
        self.get_connection()?.req_packed_command(cmd)
    }

    fn req_packed_commands(
        &mut self,
        cmd: &[u8],
        offset: usize,
        count: usize,
    ) -> RedisResult<Vec<Value>> {
        self.get_connection()?
            .req_packed_commands(cmd, offset, count)
    }

    fn get_db(&self) -> i64 {
        self.connection_info.redis.db
    }

    fn check_connection(&mut self) -> bool {
        if let Ok(mut conn) = self.get_connection() {
            conn.check_connection()
        } else {
            false
        }
    }

    fn is_open(&self) -> bool {
        if let Ok(conn) = self.get_connection() {
            conn.is_open()
        } else {
            false
        }
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use assert_matches::assert_matches;

    #[test]
    fn regression_293_parse_ipv6_with_interface() {
        assert_matches!(Client::open(("fe80::cafe:beef%eno1", 6379)), Ok(_));
    }

    #[cfg(feature = "aio")]
    #[test]
    fn test_async_connection_config_pipeline_buffer_size_default() {
        let config = AsyncConnectionConfig::new();
        assert_eq!(config.pipeline_buffer_size, None);
    }

    #[cfg(feature = "aio")]
    #[test]
    fn test_async_connection_config_pipeline_buffer_size_custom() {
        let config = AsyncConnectionConfig::new().set_pipeline_buffer_size(100);
        assert_eq!(config.pipeline_buffer_size, Some(100));
    }

    #[cfg(feature = "aio")]
    #[test]
    fn test_async_connection_config_concurrency_limit_default() {
        let config = AsyncConnectionConfig::new();
        assert_eq!(config.concurrency_limit, None);
    }

    #[cfg(feature = "aio")]
    #[test]
    fn test_async_connection_config_concurrency_limit_custom() {
        let config = AsyncConnectionConfig::new().set_concurrency_limit(128);
        assert_eq!(config.concurrency_limit, Some(128));
    }

    #[cfg(feature = "aio")]
    #[test]
    fn test_async_connection_config_write_backpressure_boundary_default() {
        let config = AsyncConnectionConfig::new();
        assert_eq!(config.write_backpressure_boundary, None);
    }

    #[cfg(feature = "aio")]
    #[test]
    fn test_async_connection_config_write_backpressure_boundary_custom() {
        let config = AsyncConnectionConfig::new().set_write_backpressure_boundary(16 * 1024 * 1024);
        assert_eq!(config.write_backpressure_boundary, Some(16 * 1024 * 1024));
    }
}
