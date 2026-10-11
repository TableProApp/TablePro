use super::{AsyncPushSender, HandleContainer, RedisFuture};
#[cfg(feature = "cache-aio")]
use crate::caching::CacheManager;
use crate::{
    AsyncConnectionConfig, Client, Cmd, Pipeline, PushInfo, PushKind, ToRedisArgs,
    aio::{ConnectionLike, MultiplexedConnection, Runtime},
    check_resp3,
    client::{DEFAULT_CONNECTION_TIMEOUT, DEFAULT_RESPONSE_TIMEOUT},
    cmd,
    errors::RedisError,
    subscription_tracker::{SubscriptionAction, SubscriptionTracker},
    types::{RedisResult, Value},
};
use arc_swap::ArcSwap;
use backon::{ExponentialBuilder, Retryable};
use futures_channel::oneshot;
use futures_util::future::{BoxFuture, FutureExt, Shared};
use std::sync::{Arc, Weak};
use std::time::Duration;
use tokio::sync::Mutex;
use tokio::sync::mpsc::{UnboundedReceiver, unbounded_channel};

type OptionalPushSender = Option<Arc<dyn AsyncPushSender>>;

/// The configuration for reconnect mechanism and request timing for the [ConnectionManager]
#[derive(Clone)]
pub struct ConnectionManagerConfig {
    /// The resulting duration is calculated by taking the base to the `n`-th power,
    /// where `n` denotes the number of past attempts.
    exponent_base: f32,
    /// The minimal delay for reconnection attempts
    min_delay: Duration,
    /// Apply a maximum delay between connection attempts. The delay between attempts won't be longer than max_delay milliseconds.
    max_delay: Option<Duration>,
    /// number_of_retries times, with an exponentially increasing delay
    number_of_retries: usize,
    /// The new connection will time out operations after `response_timeout` has passed.
    response_timeout: Option<Duration>,
    /// Each connection attempt to the server will time out after `connection_timeout`.
    connection_timeout: Option<Duration>,
    /// sender channel for push values
    push_sender: Option<Arc<dyn AsyncPushSender>>,
    /// if true, the manager should resubscribe automatically to all pubsub channels after reconnect.
    resubscribe_automatically: bool,
    #[cfg(feature = "cache-aio")]
    pub(crate) cache_config: Option<crate::caching::CacheConfig>,
    pipeline_buffer_size: Option<usize>,
    concurrency_limit: Option<usize>,
    /// Flush threshold for the outbound write buffer; see [`AsyncConnectionConfig::set_write_backpressure_boundary`].
    write_backpressure_boundary: Option<usize>,
    /// Optional credentials provider for dynamic authentication (e.g., token-based authentication)
    #[cfg(feature = "token-based-authentication")]
    credentials_provider: Option<std::sync::Arc<dyn crate::auth::StreamingCredentialsProvider>>,
}

impl std::fmt::Debug for ConnectionManagerConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> Result<(), std::fmt::Error> {
        let &Self {
            exponent_base,
            min_delay,
            number_of_retries,
            max_delay,
            response_timeout,
            connection_timeout,
            push_sender,
            resubscribe_automatically,
            #[cfg(feature = "cache-aio")]
            cache_config,
            pipeline_buffer_size,
            concurrency_limit,
            write_backpressure_boundary,
            #[cfg(feature = "token-based-authentication")]
            credentials_provider,
        } = &self;
        let mut str = f.debug_struct("ConnectionManagerConfig");
        str.field("exponent_base", &exponent_base)
            .field("min_delay", &min_delay)
            .field("max_delay", &max_delay)
            .field("number_of_retries", &number_of_retries)
            .field("response_timeout", &response_timeout)
            .field("connection_timeout", &connection_timeout)
            .field("resubscribe_automatically", &resubscribe_automatically)
            .field("pipeline_buffer_size", &pipeline_buffer_size)
            .field("concurrency_limit", &concurrency_limit)
            .field("write_backpressure_boundary", &write_backpressure_boundary)
            .field(
                "push_sender",
                if push_sender.is_some() {
                    &"set"
                } else {
                    &"not set"
                },
            );

        #[cfg(feature = "cache-aio")]
        str.field("cache_config", &cache_config);

        #[cfg(feature = "token-based-authentication")]
        str.field(
            "credentials_provider",
            if credentials_provider.is_some() {
                &"set"
            } else {
                &"not set"
            },
        );

        str.finish()
    }
}

impl ConnectionManagerConfig {
    const DEFAULT_CONNECTION_RETRY_EXPONENT_BASE: f32 = 2.0;
    const DEFAULT_CONNECTION_RETRY_MIN_DELAY: Duration = Duration::from_millis(100);
    const DEFAULT_NUMBER_OF_CONNECTION_RETRIES: usize = 6;

    /// Creates a new instance of the options with nothing set
    pub fn new() -> Self {
        Self::default()
    }

    /// Returns the minimum delay between connection attempts.
    pub fn min_delay(&self) -> Duration {
        self.min_delay
    }

    /// Returns the maximum delay between connection attempts.
    pub fn max_delay(&self) -> Option<Duration> {
        self.max_delay
    }

    /// Returns the base used for calculating the exponential backoff between retries.
    pub fn exponent_base(&self) -> f32 {
        self.exponent_base
    }

    /// Returns the maximum number of connection retry attempts.
    pub fn number_of_retries(&self) -> usize {
        self.number_of_retries
    }

    /// Returns the timeout applied to command responses.
    ///
    /// If `None`, responses do not time out.
    pub fn response_timeout(&self) -> Option<Duration> {
        self.response_timeout
    }

    /// Returns the timeout applied to establishing a new connection.
    ///
    /// If `None`, connection attempts to do not time out.
    pub fn connection_timeout(&self) -> Option<Duration> {
        self.connection_timeout
    }

    /// Returns `true` if automatic resubscription is enabled after reconnecting.
    pub fn automatic_resubscription(&self) -> bool {
        self.resubscribe_automatically
    }

    /// Returns the current cache configuration, if caching is enabled.
    #[cfg(feature = "cache-aio")]
    pub fn cache_config(&self) -> Option<&crate::caching::CacheConfig> {
        self.cache_config.as_ref()
    }

    /// Set the minimal delay for reconnect attempts.
    pub fn set_min_delay(mut self, min_delay: Duration) -> Self {
        self.min_delay = min_delay;
        self
    }

    /// Apply a maximum delay between connection attempts. The delay between attempts won't be longer than max_delay milliseconds.
    pub fn set_max_delay(mut self, time: Duration) -> Self {
        self.max_delay = Some(time);
        self
    }

    /// The resulting duration is calculated by taking the base to the `n`-th power,
    /// where `n` denotes the number of past attempts.
    pub fn set_exponent_base(mut self, base: f32) -> Self {
        self.exponent_base = base;
        self
    }

    /// number_of_retries times, with an exponentially increasing delay.
    pub fn set_number_of_retries(mut self, amount: usize) -> Self {
        self.number_of_retries = amount;
        self
    }

    /// The new connection will time out operations after `response_timeout` has passed.
    ///
    /// Set `None` if you don't want requests to time out.
    pub fn set_response_timeout(mut self, duration: Option<Duration>) -> Self {
        self.response_timeout = duration;
        self
    }

    /// Each connection attempt to the server will time out after `connection_timeout`.
    ///
    /// Set `None` if you don't want the connection attempt to time out.
    pub fn set_connection_timeout(mut self, duration: Option<Duration>) -> Self {
        self.connection_timeout = duration;
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
    /// # use redis::aio::ConnectionManagerConfig;
    /// let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    /// let config = ConnectionManagerConfig::new().set_push_sender(tx);
    /// ```
    ///
    /// ```rust
    /// # use std::sync::{Mutex, Arc};
    /// # use redis::aio::ConnectionManagerConfig;
    /// let messages = Arc::new(Mutex::new(Vec::new()));
    /// let config = ConnectionManagerConfig::new().set_push_sender(move |msg|{
    ///     let Ok(mut messages) = messages.lock() else {
    ///         return Err(redis::aio::SendError);
    ///     };
    ///     messages.push(msg);
    ///     Ok(())
    /// });
    /// ```
    pub fn set_push_sender(mut self, sender: impl AsyncPushSender) -> Self {
        self.push_sender = Some(Arc::new(sender));
        self
    }

    /// Configures the connection manager to automatically resubscribe to all pubsub channels after reconnecting.
    pub fn set_automatic_resubscription(mut self) -> Self {
        self.resubscribe_automatically = true;
        self
    }

    /// Set the cache behavior.
    #[cfg(feature = "cache-aio")]
    pub fn set_cache_config(self, cache_config: crate::caching::CacheConfig) -> Self {
        Self {
            cache_config: Some(cache_config),
            ..self
        }
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
    /// See [`AsyncConnectionConfig::set_concurrency_limit`] for full semantics.
    pub fn set_concurrency_limit(mut self, limit: usize) -> Self {
        self.concurrency_limit = Some(limit);
        self
    }

    /// Sets the flush threshold (backpressure boundary) for the outbound write buffer.
    ///
    /// See [`AsyncConnectionConfig::set_write_backpressure_boundary`] for full semantics.
    /// When left unset, the connection keeps `tokio_util`'s default boundary.
    pub fn set_write_backpressure_boundary(mut self, boundary: usize) -> Self {
        self.write_backpressure_boundary = Some(boundary);
        self
    }

    /// Sets a credentials provider for dynamic authentication.
    ///
    /// This is useful for token-based authentication where credentials need to be
    /// refreshed periodically (e.g., Azure Entra ID tokens).
    ///
    /// # Examples
    ///
    /// ```rust,no_run
    /// # #[cfg(feature = "entra-id")]
    /// # async fn example() -> redis::RedisResult<()> {
    /// use redis::aio::ConnectionManagerConfig;
    /// use redis::{EntraIdCredentialsProvider, RetryConfig};
    ///
    /// let mut provider = EntraIdCredentialsProvider::new_developer_tools()?;
    /// provider.start(RetryConfig::default());
    ///
    /// let config = ConnectionManagerConfig::new()
    ///     .set_credentials_provider(provider);
    /// # Ok(())
    /// # }
    /// ```
    #[cfg(feature = "token-based-authentication")]
    pub fn set_credentials_provider<P>(mut self, provider: P) -> Self
    where
        P: crate::auth::StreamingCredentialsProvider + 'static,
    {
        self.credentials_provider = Some(std::sync::Arc::new(provider));
        self
    }
}

impl Default for ConnectionManagerConfig {
    fn default() -> Self {
        Self {
            exponent_base: Self::DEFAULT_CONNECTION_RETRY_EXPONENT_BASE,
            min_delay: Self::DEFAULT_CONNECTION_RETRY_MIN_DELAY,
            max_delay: None,
            number_of_retries: Self::DEFAULT_NUMBER_OF_CONNECTION_RETRIES,
            response_timeout: DEFAULT_RESPONSE_TIMEOUT,
            connection_timeout: DEFAULT_CONNECTION_TIMEOUT,
            push_sender: None,
            resubscribe_automatically: false,
            #[cfg(feature = "cache-aio")]
            cache_config: None,
            pipeline_buffer_size: None,
            concurrency_limit: None,
            write_backpressure_boundary: None,
            #[cfg(feature = "token-based-authentication")]
            credentials_provider: None,
        }
    }
}

struct Internals {
    /// Information used for the connection. This is needed to be able to reconnect.
    client: Client,
    /// The connection future.
    ///
    /// The `ArcSwap` is required to be able to replace the connection
    /// without making the `ConnectionManager` mutable.
    connection: ArcSwap<SharedRedisFuture<MultiplexedConnection>>,

    runtime: Runtime,
    retry_strategy: ExponentialBuilder,
    connection_config: AsyncConnectionConfig,
    subscription_tracker: Option<Mutex<SubscriptionTracker>>,
    #[cfg(feature = "cache-aio")]
    cache_manager: Option<CacheManager>,
    _task_handle: HandleContainer,
}

/// A `ConnectionManager` is a proxy that wraps a [multiplexed
/// connection][multiplexed-connection] and automatically reconnects to the
/// server when necessary.
///
/// Like the [`MultiplexedConnection`][multiplexed-connection], this
/// manager can be cloned, allowing requests to be sent concurrently on
/// the same underlying connection (tcp/unix socket).
///
/// ## Behavior
///
/// - When creating an instance of the `ConnectionManager`, an initial
///   connection will be established and awaited. Connection errors will be
///   returned directly.
/// - When a command sent to the server fails with an error that represents
///   a "connection dropped" condition, that error will be passed on to the
///   user, but it will trigger a reconnection in the background.
/// - The reconnect code will atomically swap the current (dead) connection
///   with a future that will eventually resolve to a `MultiplexedConnection`
///   or to a `RedisError`
/// - All commands that are issued after the reconnect process has been
///   initiated, will have to await the connection future.
/// - If reconnecting fails, all pending commands will be failed as well. A
///   new reconnection attempt will be triggered if the error is an I/O error.
/// - If the connection manager uses RESP3 connection,it actively listens to updates from the
///   server, and so it will cause the manager to reconnect after a disconnection, even if the manager was unused at
///   the time of the disconnect.
///
/// [multiplexed-connection]: struct.MultiplexedConnection.html
#[derive(Clone)]
pub struct ConnectionManager(Arc<Internals>);

impl std::fmt::Debug for ConnectionManager {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ConnectionManager")
            .field("client", &self.0.client)
            .field("retry_strategy", &self.0.retry_strategy)
            .finish()
    }
}

/// Type alias for a shared boxed future that will resolve to a `RedisResult`.
type SharedRedisFuture<T> = Shared<BoxFuture<'static, RedisResult<T>>>;

/// Handle a command result. If the connection was dropped, reconnect.
macro_rules! reconnect_if_dropped {
    ($self:expr, $result:expr, $current:expr) => {
        if let Err(e) = $result {
            if e.is_unrecoverable_error() {
                Self::reconnect(Arc::downgrade(&$self.0), $current);
            }
        }
    };
}

/// Handle a connection result. If there's an I/O error, reconnect.
/// Propagate any error.
macro_rules! reconnect_if_io_error {
    ($self:expr, $result:expr, $current:expr) => {
        if let Err(e) = $result {
            if e.is_io_error() {
                Self::reconnect(Arc::downgrade(&$self.0), $current);
            }
            return Err(e);
        }
    };
}

impl ConnectionManager {
    /// Connect to the server and store the connection inside the returned `ConnectionManager`.
    ///
    /// This requires the `connection-manager` feature, which will also pull in
    /// the Tokio executor.
    pub async fn new(client: Client) -> RedisResult<Self> {
        let config = ConnectionManagerConfig::new();
        Self::new_with_config(client, config).await
    }

    /// Connect to the server and store the connection inside the returned `ConnectionManager`.
    ///
    /// This requires the `connection-manager` feature, which will also pull in
    /// the Tokio executor.
    ///
    /// In case of reconnection issues, the manager will retry reconnection
    /// number_of_retries times, with an exponentially increasing delay, calculated as
    /// min(max_delay, rand(0 .. min_delay * (exponent_base ^ current-try))).
    ///
    /// The new connection will time out operations after `response_timeout` has passed.
    /// Each connection attempt to the server will time out after `connection_timeout`.
    pub async fn new_with_config(
        client: Client,
        config: ConnectionManagerConfig,
    ) -> RedisResult<Self> {
        // Create the lazy connection manager
        let manager = Self::new_lazy_with_config(client, config)?;

        // Trigger the connection by loading and awaiting it
        let guard = manager.0.connection.load();
        (**guard).clone().await?;

        Ok(manager)
    }

    /// Creates a `ConnectionManager` with config without establishing a connection.
    ///
    /// The connection will be established lazily on the first request.
    /// This is a synchronous function that returns immediately.
    ///
    /// This requires the `connection-manager` feature, which will also pull in
    /// the Tokio executor.
    pub fn new_lazy_with_config(
        client: Client,
        config: ConnectionManagerConfig,
    ) -> RedisResult<Self> {
        let runtime = Runtime::locate();

        if config.resubscribe_automatically && config.push_sender.is_none() {
            return Err((crate::ErrorKind::Client, "Cannot set resubscribe_automatically without setting a push sender to receive messages.").into());
        }

        let mut retry_strategy = ExponentialBuilder::default()
            .with_factor(config.exponent_base)
            .with_min_delay(config.min_delay)
            .with_max_times(config.number_of_retries)
            .with_jitter();
        if let Some(max_delay) = config.max_delay {
            retry_strategy = retry_strategy.with_max_delay(max_delay);
        }

        let mut connection_config = AsyncConnectionConfig::new()
            .set_connection_timeout(config.connection_timeout)
            .set_response_timeout(config.response_timeout);
        connection_config.pipeline_buffer_size = config.pipeline_buffer_size;
        connection_config.concurrency_limit = config.concurrency_limit;
        connection_config.write_backpressure_boundary = config.write_backpressure_boundary;

        #[cfg(feature = "cache-aio")]
        let cache_manager = config
            .cache_config
            .as_ref()
            .map(|cache_config| CacheManager::new(*cache_config));
        #[cfg(feature = "cache-aio")]
        if let Some(cache_manager) = cache_manager.as_ref() {
            connection_config = connection_config.set_cache_manager(cache_manager.clone());
        }

        #[cfg(feature = "token-based-authentication")]
        if let Some(credentials_provider) = config.credentials_provider {
            connection_config.credentials_provider = Some(credentials_provider);
        }

        let (oneshot_sender, oneshot_receiver) = oneshot::channel();
        let _task_handle = HandleContainer::new(
            runtime.spawn(Self::check_for_disconnect_pushes(oneshot_receiver)),
        );

        let mut components_for_reconnection_on_push = None;
        if let Some(push_sender) = config.push_sender.clone() {
            check_resp3!(
                client.connection_info.redis.protocol,
                "Can only pass push sender to a connection using RESP3"
            );

            let (internal_sender, internal_receiver) = unbounded_channel();
            components_for_reconnection_on_push = Some((internal_receiver, Some(push_sender)));

            connection_config =
                connection_config.set_push_sender_internal(Arc::new(internal_sender));
        } else if client.connection_info.redis.protocol.supports_resp3() {
            let (internal_sender, internal_receiver) = unbounded_channel();
            components_for_reconnection_on_push = Some((internal_receiver, None));

            connection_config =
                connection_config.set_push_sender_internal(Arc::new(internal_sender));
        }

        let subscription_tracker = config
            .resubscribe_automatically
            .then(|| Mutex::new(SubscriptionTracker::default()));

        let client_clone = client.clone();
        let retry_strategy_clone = retry_strategy;
        let connection_config_clone = connection_config.clone();

        // Create a lazy connection future that will be resolved on first use
        let lazy_connection: SharedRedisFuture<MultiplexedConnection> = async move {
            Self::new_connection(
                &client_clone,
                retry_strategy_clone,
                &connection_config_clone,
                None,
            )
            .await
        }
        .boxed()
        .shared();

        let new_self = Self(Arc::new(Internals {
            client,
            connection: ArcSwap::from_pointee(lazy_connection),
            runtime,
            retry_strategy,
            connection_config,
            subscription_tracker,
            #[cfg(feature = "cache-aio")]
            cache_manager,
            _task_handle,
        }));

        if let Some((internal_receiver, external_sender)) = components_for_reconnection_on_push {
            oneshot_sender
                .send((
                    Arc::downgrade(&new_self.0),
                    internal_receiver,
                    external_sender,
                ))
                .map_err(|_| {
                    crate::RedisError::from((
                        crate::ErrorKind::Client,
                        "Failed to set automatic resubscription",
                    ))
                })?;
        }

        Ok(new_self)
    }

    async fn new_connection(
        client: &Client,
        exponential_backoff: ExponentialBuilder,
        connection_config: &AsyncConnectionConfig,
        additional_commands: Option<Pipeline>,
    ) -> RedisResult<MultiplexedConnection> {
        let connection_config = connection_config.clone();
        let get_conn = || async {
            client
                .get_multiplexed_async_connection_with_config(&connection_config)
                .await
        };
        let mut conn = get_conn
            .retry(exponential_backoff)
            .sleep(|duration| async move { Runtime::locate().sleep(duration).await })
            .await?;
        if let Some(pipeline) = additional_commands {
            // TODO - should we ignore these failures?
            let _ = pipeline.exec_async(&mut conn).await;
        }
        Ok(conn)
    }

    /// Reconnect and overwrite the old connection.
    ///
    /// The `current` guard points to the shared future that was active
    /// when the connection loss was detected.
    fn reconnect(
        internals: Weak<Internals>,
        current: arc_swap::Guard<Arc<SharedRedisFuture<MultiplexedConnection>>>,
    ) {
        let Some(internals) = internals.upgrade() else {
            return;
        };
        let internals_clone = internals.clone();
        #[cfg(not(feature = "cache-aio"))]
        let connection_config = internals.connection_config.clone();
        #[cfg(feature = "cache-aio")]
        let mut connection_config = internals.connection_config.clone();
        #[cfg(feature = "cache-aio")]
        if let Some(manager) = internals.cache_manager.as_ref() {
            let new_cache_manager = manager.clone_and_increase_epoch();
            connection_config = connection_config.set_cache_manager(new_cache_manager);
        }
        let new_connection: SharedRedisFuture<MultiplexedConnection> = async move {
            let additional_commands = match &internals_clone.subscription_tracker {
                Some(subscription_tracker) => Some(
                    subscription_tracker
                        .lock()
                        .await
                        .get_subscription_pipeline(),
                ),
                None => None,
            };

            let con = Self::new_connection(
                &internals_clone.client,
                internals_clone.retry_strategy,
                &connection_config,
                additional_commands,
            )
            .await?;
            Ok(con)
        }
        .boxed()
        .shared();

        // Update the connection in the connection manager
        let new_connection_arc = Arc::new(new_connection.clone());
        let prev = internals
            .connection
            .compare_and_swap(&current, new_connection_arc);

        // If the swap happened...
        if Arc::ptr_eq(&prev, &current) {
            // ...start the connection attempt immediately but do not wait on it.
            internals.runtime.spawn(new_connection.map(|_| ())).detach();
        }
    }

    async fn check_for_disconnect_pushes(
        receiver: oneshot::Receiver<(
            Weak<Internals>,
            UnboundedReceiver<PushInfo>,
            OptionalPushSender,
        )>,
    ) {
        let Ok((this, mut internal_receiver, external_sender)) = receiver.await else {
            return;
        };
        while let Some(push_info) = internal_receiver.recv().await {
            if push_info.kind == PushKind::Disconnection {
                let Some(internals) = this.upgrade() else {
                    return;
                };
                Self::reconnect(Arc::downgrade(&internals), internals.connection.load());
            }
            if let Some(sender) = external_sender.as_ref() {
                let _ = sender.send(push_info);
            }
        }
    }

    /// Sends an already encoded (packed) command into the TCP socket and
    /// reads the single response from it.
    pub async fn send_packed_command(&mut self, cmd: &Cmd) -> RedisResult<Value> {
        // Clone connection to avoid having to lock the ArcSwap in write mode
        let guard = self.0.connection.load();
        let connection_result = (**guard).clone().await;
        reconnect_if_io_error!(self, connection_result, guard);
        let result = connection_result?.send_packed_command(cmd).await;
        reconnect_if_dropped!(self, &result, guard);
        result
    }

    /// Sends multiple already encoded (packed) command into the TCP socket
    /// and reads `count` responses from it.  This is used to implement
    /// pipelining.
    pub async fn send_packed_commands(
        &mut self,
        cmd: &crate::Pipeline,
        offset: usize,
        count: usize,
    ) -> RedisResult<Vec<Value>> {
        // Clone shared connection future to avoid having to lock the ArcSwap in write mode
        let guard = self.0.connection.load();
        let connection_result = (**guard).clone().await;
        reconnect_if_io_error!(self, connection_result, guard);
        let result = connection_result?
            .send_packed_commands(cmd, offset, count)
            .await;
        reconnect_if_dropped!(self, &result, guard);
        result
    }

    async fn update_subscription_tracker(
        &self,
        action: SubscriptionAction,
        args: impl ToRedisArgs,
    ) {
        let Some(subscription_tracker) = &self.0.subscription_tracker else {
            return;
        };
        let args = args.to_redis_args().into_iter();
        subscription_tracker
            .lock()
            .await
            .update_with_request(action, args);
    }

    /// Subscribes to a new channel(s).
    ///
    /// Updates from the sender will be sent on the push sender that was passed to the manager.
    /// If the manager was configured without a push sender, the connection won't be able to pass messages back to the user.
    ///
    /// This method is only available when the connection is using RESP3 protocol, and will return an error otherwise.
    /// It should be noted that unless [ConnectionManagerConfig::set_automatic_resubscription] was called,
    /// the subscription will be removed on a disconnect and must be re-subscribed.
    ///  
    /// ```rust,no_run
    /// # async fn func() -> redis::RedisResult<()> {
    /// let client = redis::Client::open("redis://127.0.0.1/?protocol=resp3").unwrap();
    /// let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    /// let config = redis::aio::ConnectionManagerConfig::new().set_push_sender(tx);
    /// let mut con = client.get_connection_manager_with_config(config).await?;
    /// con.psubscribe("channel*_1").await?;
    /// con.psubscribe(&["channel*_2", "channel*_3"]).await?;
    /// # Ok(())
    /// # }
    /// ```
    pub async fn subscribe(&mut self, channel_name: impl ToRedisArgs) -> RedisResult<()> {
        check_resp3!(self.0.client.connection_info.redis.protocol);
        let mut cmd = cmd("SUBSCRIBE");
        cmd.arg(&channel_name);
        cmd.exec_async(self).await?;
        self.update_subscription_tracker(SubscriptionAction::Subscribe, channel_name)
            .await;

        Ok(())
    }

    /// Unsubscribes from channel(s).
    ///
    /// This method is only available when the connection is using RESP3 protocol, and will return an error otherwise.
    pub async fn unsubscribe(&mut self, channel_name: impl ToRedisArgs) -> RedisResult<()> {
        check_resp3!(self.0.client.connection_info.redis.protocol);
        let mut cmd = cmd("UNSUBSCRIBE");
        cmd.arg(&channel_name);
        cmd.exec_async(self).await?;
        self.update_subscription_tracker(SubscriptionAction::Unsubscribe, channel_name)
            .await;
        Ok(())
    }

    /// Subscribes to new channel(s) with pattern(s).
    ///
    /// Updates from the sender will be sent on the push sender that was passed to the manager.
    /// If the manager was configured without a push sender, the manager won't be able to pass messages back to the user.
    ///
    /// This method is only available when the connection is using RESP3 protocol, and will return an error otherwise.
    /// It should be noted that unless [ConnectionManagerConfig::set_automatic_resubscription] was called,
    /// the subscription will be removed on a disconnect and must be re-subscribed.
    ///
    /// ```rust,no_run
    /// # async fn func() -> redis::RedisResult<()> {
    /// let client = redis::Client::open("redis://127.0.0.1/?protocol=resp3").unwrap();
    /// let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    /// let config = redis::aio::ConnectionManagerConfig::new().set_push_sender(tx);
    /// let mut con = client.get_connection_manager_with_config(config).await?;
    /// con.psubscribe("channel*_1").await?;
    /// con.psubscribe(&["channel*_2", "channel*_3"]).await?;
    /// # Ok(())
    /// # }
    /// ```
    pub async fn psubscribe(&mut self, channel_pattern: impl ToRedisArgs) -> RedisResult<()> {
        check_resp3!(self.0.client.connection_info.redis.protocol);
        let mut cmd = cmd("PSUBSCRIBE");
        cmd.arg(&channel_pattern);
        cmd.exec_async(self).await?;
        self.update_subscription_tracker(SubscriptionAction::PSubscribe, channel_pattern)
            .await;
        Ok(())
    }

    /// Unsubscribes from channel pattern(s).
    ///
    /// This method is only available when the connection is using RESP3 protocol, and will return an error otherwise.
    pub async fn punsubscribe(&mut self, channel_pattern: impl ToRedisArgs) -> RedisResult<()> {
        check_resp3!(self.0.client.connection_info.redis.protocol);
        let mut cmd = cmd("PUNSUBSCRIBE");
        cmd.arg(&channel_pattern);
        cmd.exec_async(self).await?;
        self.update_subscription_tracker(SubscriptionAction::PUnsubscribe, channel_pattern)
            .await;
        Ok(())
    }

    /// Gets [`crate::caching::CacheStatistics`] for current connection if caching is enabled.
    #[cfg(feature = "cache-aio")]
    #[cfg_attr(docsrs, doc(cfg(feature = "cache-aio")))]
    pub fn get_cache_statistics(&self) -> Option<crate::caching::CacheStatistics> {
        self.0.cache_manager.as_ref().map(|cm| cm.statistics())
    }
}

impl ConnectionLike for ConnectionManager {
    fn req_packed_command<'a>(&'a mut self, cmd: &'a Cmd) -> RedisFuture<'a, Value> {
        (async move { self.send_packed_command(cmd).await }).boxed()
    }

    fn req_packed_commands<'a>(
        &'a mut self,
        pipeline: &'a crate::Pipeline,
        offset: usize,
        count: usize,
    ) -> RedisFuture<'a, Vec<Value>> {
        (async move { self.send_packed_commands(pipeline, offset, count).await }).boxed()
    }

    fn get_db(&self) -> i64 {
        self.0.client.connection_info().redis.db
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_connection_manager_config_pipeline_buffer_size_default() {
        let config = ConnectionManagerConfig::new();
        assert_eq!(config.pipeline_buffer_size, None);
    }

    #[test]
    fn test_connection_manager_config_pipeline_buffer_size_custom() {
        let config = ConnectionManagerConfig::new().set_pipeline_buffer_size(100);
        assert_eq!(config.pipeline_buffer_size, Some(100));
    }

    #[test]
    fn test_connection_manager_config_concurrency_limit_default() {
        let config = ConnectionManagerConfig::new();
        assert_eq!(config.concurrency_limit, None);
    }

    #[test]
    fn test_connection_manager_config_concurrency_limit_custom() {
        let config = ConnectionManagerConfig::new().set_concurrency_limit(128);
        assert_eq!(config.concurrency_limit, Some(128));
    }

    #[test]
    fn test_connection_manager_config_write_backpressure_boundary_default() {
        let config = ConnectionManagerConfig::new();
        assert_eq!(config.write_backpressure_boundary, None);
    }

    #[test]
    fn test_connection_manager_config_write_backpressure_boundary_custom() {
        let config =
            ConnectionManagerConfig::new().set_write_backpressure_boundary(16 * 1024 * 1024);
        assert_eq!(config.write_backpressure_boundary, Some(16 * 1024 * 1024));
    }

    #[tokio::test]
    async fn test_lazy_connection_manager_with_config() {
        // Test that lazy connection manager can be created with custom config
        let client = Client::open("redis://127.0.0.1/").unwrap();
        let config = ConnectionManagerConfig::new()
            .set_pipeline_buffer_size(100)
            .set_concurrency_limit(128)
            .set_number_of_retries(3);
        let result = ConnectionManager::new_lazy_with_config(client, config);
        result.unwrap();
    }

    #[tokio::test]
    async fn test_lazy_connection_manager_wires_write_backpressure_boundary() {
        let client = Client::open("redis://127.0.0.1/").unwrap();
        let config =
            ConnectionManagerConfig::new().set_write_backpressure_boundary(16 * 1024 * 1024);
        let manager = ConnectionManager::new_lazy_with_config(client, config).unwrap();
        assert_eq!(
            manager.0.connection_config.write_backpressure_boundary,
            Some(16 * 1024 * 1024)
        );
    }

    #[test]
    fn test_lazy_connection_manager_rejects_invalid_config() {
        // Test that lazy connection manager rejects invalid configuration
        let client = Client::open("redis://127.0.0.1/?protocol=resp3").unwrap();
        let config = ConnectionManagerConfig::new().set_automatic_resubscription(); // This requires a push sender
        let result = ConnectionManager::new_lazy_with_config(client, config);
        assert_matches::assert_matches!(result, Err(err) if err.kind() == crate::ErrorKind::Client);
    }
}
