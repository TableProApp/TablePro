#[cfg(feature = "cluster-async")]
use crate::aio::AsyncPushSender;
#[cfg(all(feature = "token-based-authentication", feature = "cluster-async"))]
use crate::auth::StreamingCredentialsProvider;
#[cfg(all(feature = "cache-aio", feature = "cluster-async"))]
use crate::caching::{CacheConfig, CacheManager};
use crate::client::DEFAULT_CONNECTION_TIMEOUT;
use crate::cluster_handling::NodeAddress;
use crate::cluster_handling::read_routing::{RandomReplicaStrategy, ReadRoutingStrategyFactory};
use crate::connection::{ConnectionAddr, ConnectionInfo, IntoConnectionInfo};
use crate::errors::{ErrorKind, RedisError};
#[cfg(feature = "cluster-async")]
use crate::io::AsyncDNSResolver;
use crate::io::tcp::TcpSettings;
use crate::types::{ProtocolVersion, RedisResult};
use crate::{TlsMode, cluster};
use arcstr::ArcStr;
use rand::RngExt;
use std::collections::HashMap;
#[cfg(feature = "cluster-async")]
use std::num::NonZeroUsize;
use std::sync::Arc;
use std::time::Duration;

/// Controls the overall timeout behavior for a complete cluster request,
/// including all internal retries, reconnections, and redirections (e.g. MOVED/ASK).
#[cfg(feature = "cluster-async")]
#[derive(Clone, Debug, Default)]
enum OverallResponseTimeout {
    /// Use the same value as `response_timeout` for the overall timeout.
    #[default]
    MatchResponseTimeout,
    /// Use a specific duration, or disable the overall timeout with `None`.
    Explicit(Option<Duration>),
}

use crate::connection::TlsConnParams;

#[cfg(feature = "cluster-async")]
use crate::cluster_async;

#[cfg(feature = "tls-rustls")]
use crate::tls::{TlsCertificates, retrieve_tls_certificates};

/// Parameters specific to builder, so that
/// builder parameters may have different types
/// than final ClusterParams
#[derive(Default)]
struct BuilderParams {
    password: Option<ArcStr>,
    username: Option<ArcStr>,
    read_routing_factory: Option<Arc<dyn ReadRoutingStrategyFactory>>,
    tls: Option<TlsMode>,
    #[cfg(feature = "tls-rustls")]
    certs: Option<TlsCertificates>,
    #[cfg(any(feature = "tls-rustls-insecure", feature = "tls-native-tls"))]
    danger_accept_invalid_hostnames: bool,
    retries_configuration: RetryParams,
    connection_timeout: Option<Duration>,
    response_timeout: Option<Duration>,
    protocol: Option<ProtocolVersion>,
    database_id: Option<i64>,
    #[cfg(feature = "cluster-async")]
    async_push_sender: Option<Arc<dyn AsyncPushSender>>,
    pub(crate) tcp_settings: TcpSettings,
    #[cfg(feature = "cluster-async")]
    async_dns_resolver: Option<Arc<dyn AsyncDNSResolver>>,
    #[cfg(feature = "cache-aio")]
    cache_config: Option<CacheConfig>,
    #[cfg(all(feature = "token-based-authentication", feature = "cluster-async"))]
    credentials_provider: Option<std::sync::Arc<dyn StreamingCredentialsProvider>>,
    #[cfg(feature = "cluster-async")]
    overall_response_timeout: OverallResponseTimeout,
    #[cfg(feature = "cluster-async")]
    connection_concurrency_limit: Option<usize>,
    #[cfg(feature = "cluster-async")]
    write_backpressure_boundary: Option<usize>,
    node_address_map: Option<HashMap<NodeAddress, NodeAddress>>,
    #[cfg(feature = "cluster-async")]
    max_connection_attempts: Option<NonZeroUsize>,
}

#[derive(Clone)]
pub(crate) struct RetryParams {
    pub(crate) number_of_retries: u32,
    max_wait_time: u64,
    min_wait_time: u64,
    exponent_base: u64,
    factor: u64,
}

impl Default for RetryParams {
    fn default() -> Self {
        const DEFAULT_RETRIES: u32 = 16;
        const DEFAULT_MAX_RETRY_WAIT_TIME: u64 = 655360;
        const DEFAULT_MIN_RETRY_WAIT_TIME: u64 = 1280;
        const DEFAULT_EXPONENT_BASE: u64 = 2;
        const DEFAULT_FACTOR: u64 = 10;
        Self {
            number_of_retries: DEFAULT_RETRIES,
            max_wait_time: DEFAULT_MAX_RETRY_WAIT_TIME,
            min_wait_time: DEFAULT_MIN_RETRY_WAIT_TIME,
            exponent_base: DEFAULT_EXPONENT_BASE,
            factor: DEFAULT_FACTOR,
        }
    }
}

/// Exclusive upper bound (ms) for [`RetryParams::wait_time_for_retry`] jitter; see [`ClusterClientBuilder::retry_wait_formula`].
///
/// The result is always strictly greater than `min_wait` so the half-open jitter range is never empty
/// (e.g. when `max_retry_wait == min_retry_wait`, or when the clamp would otherwise equal `min_wait`).
fn cluster_retry_wait_upper_ms(base_wait: u64, min_wait: u64, max_wait: u64) -> u64 {
    let capped = base_wait.max(min_wait + 1).min(max_wait);
    if capped <= min_wait {
        min_wait.saturating_add(1)
    } else {
        capped
    }
}

impl RetryParams {
    pub(crate) fn wait_time_for_retry(&self, retry: u32) -> Duration {
        let base_wait = self.exponent_base.pow(retry) * self.factor;
        let clamped_wait =
            cluster_retry_wait_upper_ms(base_wait, self.min_wait_time, self.max_wait_time);
        let jittered_wait = rand::rng().random_range(self.min_wait_time..clamped_wait);
        Duration::from_millis(jittered_wait)
    }
}

/// Redis cluster specific parameters.
#[derive(Default, Clone)]
pub(crate) struct ClusterParams {
    pub(crate) password: Option<ArcStr>,
    pub(crate) username: Option<ArcStr>,
    pub(crate) read_routing_factory: Option<Arc<dyn ReadRoutingStrategyFactory>>,
    /// tls indicates tls behavior of connections.
    /// When Some(TlsMode), connections use tls and verify certification depends on TlsMode.
    /// When None, connections do not use tls.
    pub(crate) tls: Option<TlsMode>,
    pub(crate) retry_params: RetryParams,
    pub(crate) tls_params: Option<TlsConnParams>,
    pub(crate) connection_timeout: Duration,
    pub(crate) response_timeout: Option<Duration>,
    pub(crate) protocol: Option<ProtocolVersion>,
    /// Index of the logical database each cluster connection should `SELECT`.
    ///
    /// `None` means unset, in which case the database is inherited from the
    /// initial nodes' URLs. Note that selecting a non-zero
    /// database in cluster mode requires a server that supports multiple databases
    /// in cluster mode; otherwise the connection handshake will fail.
    pub(crate) database_id: Option<i64>,
    #[cfg(feature = "cluster-async")]
    pub(crate) async_push_sender: Option<Arc<dyn AsyncPushSender>>,
    pub(crate) tcp_settings: TcpSettings,
    #[cfg(feature = "cluster-async")]
    pub(crate) async_dns_resolver: Option<Arc<dyn AsyncDNSResolver>>,
    #[cfg(all(feature = "cache-aio", feature = "cluster-async"))]
    pub(crate) cache_manager: Option<CacheManager>,
    #[cfg(all(feature = "token-based-authentication", feature = "cluster-async"))]
    pub(crate) credentials_provider: Option<std::sync::Arc<dyn StreamingCredentialsProvider>>,
    #[cfg(feature = "cluster-async")]
    pub(crate) overall_response_timeout: Option<Duration>,
    #[cfg(feature = "cluster-async")]
    pub(crate) connection_concurrency_limit: Option<usize>,
    #[cfg(feature = "cluster-async")]
    pub(crate) write_backpressure_boundary: Option<usize>,
    pub(crate) node_address_map: Option<HashMap<NodeAddress, NodeAddress>>,
    #[cfg(feature = "cluster-async")]
    pub(crate) max_connection_attempts: Option<NonZeroUsize>,
}

impl ClusterParams {
    fn from(value: BuilderParams) -> RedisResult<Self> {
        #[cfg(not(feature = "tls-rustls"))]
        let tls_params: Option<TlsConnParams> = None;

        #[cfg(feature = "tls-rustls")]
        let tls_params = {
            let retrieved_tls_params = value.certs.as_ref().map(retrieve_tls_certificates);

            retrieved_tls_params.transpose()?
        };

        #[cfg(any(feature = "tls-rustls-insecure", feature = "tls-native-tls"))]
        let tls_params = if value.danger_accept_invalid_hostnames {
            let mut tls_params = tls_params.unwrap_or(TlsConnParams {
                #[cfg(feature = "tls-rustls")]
                client_tls_params: None,
                #[cfg(feature = "tls-rustls")]
                root_cert_store: None,
                danger_accept_invalid_hostnames: false,
                verify_host: None,
            });
            tls_params.danger_accept_invalid_hostnames = true;
            Some(tls_params)
        } else {
            tls_params
        };

        #[cfg(all(feature = "cache-aio", feature = "cluster-async"))]
        let cache_manager = value
            .cache_config
            .as_ref()
            .map(|cache_config| CacheManager::new(*cache_config));

        Ok(Self {
            password: value.password,
            username: value.username,
            read_routing_factory: value.read_routing_factory,
            tls: value.tls,
            retry_params: value.retries_configuration,
            tls_params,
            connection_timeout: value
                .connection_timeout
                .unwrap_or(DEFAULT_CONNECTION_TIMEOUT.unwrap()),
            response_timeout: value.response_timeout,
            protocol: value.protocol,
            database_id: value.database_id,
            #[cfg(feature = "cluster-async")]
            async_push_sender: value.async_push_sender,
            tcp_settings: value.tcp_settings,
            #[cfg(feature = "cluster-async")]
            async_dns_resolver: value.async_dns_resolver,
            #[cfg(all(feature = "cache-aio", feature = "cluster-async"))]
            cache_manager,
            #[cfg(all(feature = "token-based-authentication", feature = "cluster-async"))]
            credentials_provider: value.credentials_provider,
            #[cfg(feature = "cluster-async")]
            overall_response_timeout: match value.overall_response_timeout {
                OverallResponseTimeout::MatchResponseTimeout => value.response_timeout,
                OverallResponseTimeout::Explicit(d) => d,
            },
            #[cfg(feature = "cluster-async")]
            connection_concurrency_limit: value.connection_concurrency_limit,
            #[cfg(feature = "cluster-async")]
            write_backpressure_boundary: value.write_backpressure_boundary,
            node_address_map: value.node_address_map,
            #[cfg(feature = "cluster-async")]
            max_connection_attempts: value.max_connection_attempts,
        })
    }

    fn with_config(mut self, config: cluster::ClusterConfig) -> Self {
        if let Some(connection_timeout) = config.connection_timeout {
            self.connection_timeout = connection_timeout;
        }
        self.response_timeout = config.response_timeout;

        #[cfg(feature = "cluster-async")]
        if let Some(async_push_sender) = config.async_push_sender {
            self.async_push_sender = Some(async_push_sender);
        }

        #[cfg(feature = "cluster-async")]
        if let Some(async_dns_resolver) = config.async_dns_resolver {
            self.async_dns_resolver = Some(async_dns_resolver);
        }

        self
    }
}

/// Used to configure and build a [`ClusterClient`].
pub struct ClusterClientBuilder {
    initial_nodes: RedisResult<Vec<ConnectionInfo>>,
    builder_params: BuilderParams,
}

impl ClusterClientBuilder {
    /// Creates a new `ClusterClientBuilder` with the provided initial_nodes.
    ///
    /// This is the same as `ClusterClient::builder(initial_nodes)`.
    pub fn new<T: IntoConnectionInfo>(initial_nodes: impl IntoIterator<Item = T>) -> Self {
        Self {
            initial_nodes: initial_nodes
                .into_iter()
                .map(|x| x.into_connection_info())
                .collect(),
            builder_params: Default::default(),
        }
    }

    /// Creates a new [`ClusterClient`] from the parameters.
    ///
    /// This does not create connections to the Redis Cluster, but only performs some basic checks
    /// on the initial nodes' URLs and passwords/usernames.
    ///
    /// When the `tls-rustls` feature is enabled and TLS credentials are provided, they are set for
    /// each cluster connection.
    ///
    /// # Errors
    ///
    /// Upon failure to parse initial nodes or if the initial nodes have different passwords or
    /// usernames, an error is returned.
    pub fn build(self) -> RedisResult<ClusterClient> {
        let initial_nodes = self.initial_nodes?;

        let first_node = match initial_nodes.first() {
            Some(node) => node,
            None => {
                return Err(RedisError::from((
                    ErrorKind::InvalidClientConfig,
                    "Initial nodes can't be empty.",
                )));
            }
        };

        let mut cluster_params = ClusterParams::from(self.builder_params)?;
        let password = if cluster_params.password.is_none() {
            cluster_params
                .password
                .clone_from(&first_node.redis.password.as_ref().map(|str| str.into()));
            &cluster_params.password
        } else {
            &None
        };
        let username = if cluster_params.username.is_none() {
            cluster_params
                .username
                .clone_from(&first_node.redis.username.as_ref().map(|str| str.into()));
            &cluster_params.username
        } else {
            &None
        };
        let tls = if cluster_params.tls.is_none() {
            cluster_params.tls = first_node.addr.tls_mode();
            cluster_params.tls
        } else {
            None
        };
        let protocol = if cluster_params.protocol.is_none() {
            cluster_params.protocol = Some(first_node.redis.protocol);
            cluster_params.protocol
        } else {
            None
        };
        let database_id = match cluster_params.database_id {
            Some(id) => id,
            None => first_node.redis.db,
        };
        cluster_params.database_id = Some(database_id);

        // Verify that the initial nodes match the cluster client's configuration.
        for node in &initial_nodes {
            if let ConnectionAddr::Unix(_) = node.addr {
                return Err(RedisError::from((
                    ErrorKind::InvalidClientConfig,
                    "This library cannot use unix socket because Redis's cluster command returns only cluster's IP and port.",
                )));
            }

            if password.is_some() && node.redis.password.as_deref() != password.as_deref() {
                return Err(RedisError::from((
                    ErrorKind::InvalidClientConfig,
                    "Cannot use different password among initial nodes.",
                )));
            }

            if username.is_some() && node.redis.username.as_deref() != username.as_deref() {
                return Err(RedisError::from((
                    ErrorKind::InvalidClientConfig,
                    "Cannot use different username among initial nodes.",
                )));
            }
            if protocol.is_some() && Some(node.redis.protocol) != protocol {
                return Err(RedisError::from((
                    ErrorKind::InvalidClientConfig,
                    "Cannot use different protocol among initial nodes.",
                )));
            }
            if node.redis.db != 0 && node.redis.db != database_id {
                return Err(RedisError::from((
                    ErrorKind::InvalidClientConfig,
                    "Cannot use different database among initial nodes.",
                )));
            }

            if tls.is_some() && node.addr.tls_mode() != tls {
                return Err(RedisError::from((
                    ErrorKind::InvalidClientConfig,
                    "Cannot use different TLS modes among initial nodes.",
                )));
            }
        }

        Ok(ClusterClient {
            initial_nodes,
            cluster_params,
        })
    }

    /// Sets password for the new ClusterClient.
    pub fn password(mut self, password: impl AsRef<str>) -> Self {
        self.builder_params.password = Some(password.as_ref().into());
        self
    }

    /// Sets username for the new ClusterClient.
    pub fn username(mut self, username: impl AsRef<str>) -> Self {
        self.builder_params.username = Some(username.as_ref().into());
        self
    }

    /// Sets number of retries for the new ClusterClient.
    pub fn retries(mut self, retries: u32) -> Self {
        self.builder_params.retries_configuration.number_of_retries = retries;
        self
    }

    /// Sets maximal wait time in millisceonds between retries for the new ClusterClient.
    pub fn max_retry_wait(mut self, max_wait: u64) -> Self {
        self.builder_params.retries_configuration.max_wait_time = max_wait;
        self
    }

    /// Sets minimal wait time in millisceonds between retries for the new ClusterClient.
    pub fn min_retry_wait(mut self, min_wait: u64) -> Self {
        self.builder_params.retries_configuration.min_wait_time = min_wait;
        self
    }

    /// Sets the factor and exponent base for the retry wait time.
    /// The formula for the wait is rand(min_wait_retry .. min(max_retry_wait , factor * exponent_base ^ retry))ms.
    pub fn retry_wait_formula(mut self, factor: u64, exponent_base: u64) -> Self {
        self.builder_params.retries_configuration.factor = factor;
        self.builder_params.retries_configuration.exponent_base = exponent_base;
        self
    }

    /// Sets TLS mode for the new ClusterClient.
    ///
    /// It is extracted from the first node of initial_nodes if not set.
    #[cfg(any(feature = "tls-native-tls", feature = "tls-rustls"))]
    pub fn tls(mut self, tls: TlsMode) -> Self {
        self.builder_params.tls = Some(tls);
        self
    }

    /// Configure hostname verification when connecting with TLS.
    ///
    /// If `insecure` is true, this **disables** hostname verification, while
    /// leaving other aspects of certificate checking enabled. This mode is
    /// similar to what `redis-cli` does: TLS connections do check certificates,
    /// but hostname errors are ignored.
    ///
    /// # Warning
    ///
    /// You should think very carefully before you use this method. If hostname
    /// verification is not used, any valid certificate for any site will be
    /// trusted for use from any other. This introduces a significant
    /// vulnerability to man-in-the-middle attacks.
    #[cfg(any(feature = "tls-rustls-insecure", feature = "tls-native-tls"))]
    pub fn danger_accept_invalid_hostnames(mut self, insecure: bool) -> Self {
        self.builder_params.danger_accept_invalid_hostnames = insecure;
        self
    }

    /// Sets raw TLS certificates for the new ClusterClient.
    ///
    /// When set, enforces the connection must be TLS secured.
    ///
    /// All certificates must be provided as byte streams loaded from PEM files their consistency is
    /// checked during `build()` call.
    ///
    /// - `certificates` - `TlsCertificates` structure containing:
    ///     - `client_tls` - Optional `ClientTlsConfig` containing byte streams for
    ///         - `client_cert` - client's byte stream containing client certificate in PEM format
    ///         - `client_key` - client's byte stream containing private key in PEM format
    ///
    ///     - `root_cert` - Optional byte stream yielding PEM formatted file for root certificates.
    ///
    /// If `ClientTlsConfig` ( cert+key pair ) is not provided, then client-side authentication is not enabled.
    /// If `root_cert` is not provided, then system root certificates are used instead.
    #[cfg(feature = "tls-rustls")]
    pub fn certs(mut self, certificates: TlsCertificates) -> Self {
        if self.builder_params.tls.is_none() {
            self.builder_params.tls = Some(TlsMode::Secure);
        }

        self.builder_params.certs = Some(certificates);
        self
    }

    /// Enables reading from replicas for all new connections (default is disabled).
    ///
    /// Read queries will go to a random replica node and write queries will go to the
    /// primary node. If there are no replica nodes, then all queries will go to the primary node.
    #[deprecated(note = "Use `read_routing_strategy(RandomReplicaStrategy)` instead")]
    pub fn read_from_replicas(mut self) -> Self {
        self.builder_params.read_routing_factory = Some(Arc::new(RandomReplicaStrategy));
        self
    }

    /// Sets a custom `ReadRoutingStrategyFactory` for routing read commands within Shards.
    ///
    /// Cluster slots are assigned to a shard consisting of a primary node and zero or more
    /// replica nodes. By default, the cluster client will route all commands to the primary
    /// node of a shard.
    ///
    /// By providing a strategy factory here, you can control how read requests will be routed
    /// within a shard. This allows the routing of reads to replicas.
    ///
    /// The strategy factory is responsible for producing a `ReadRoutingStrategy` each time
    /// a new connection is created from this client.
    ///
    /// A blanket implementation of `ReadRoutingStrategyFactory` is provided for any
    /// `T: ReadRoutingStrategy + Default + 'static`, so simple strategies can be passed directly.
    /// The blanket implementation uses default to construct a new strategy for each connection.
    ///
    /// The `cluster_read_routing` module provides built-in simple strategies such as
    /// `RandomReplicaStrategy` and `RoundRobinReplicaStrategy`.
    ///
    /// You can implement your own `ReadRoutingStrategy` using the provided traits.
    ///
    /// For strategies that need to maintain shared state, such as cross-connection latency tracking,
    /// implement `ReadRoutingStrategyFactory` directly.
    ///
    /// # Examples
    ///
    /// ```rust,no_run
    /// use redis::cluster::ClusterClientBuilder;
    /// use redis::cluster_read_routing::{ReadRoutingStrategy, ReadCandidates};
    /// use redis::cluster::NodeAddress;
    ///
    /// /// Routes reads to the first replica.
    /// #[derive(Default)]
    /// struct FirstReplica;
    ///
    /// impl ReadRoutingStrategy for FirstReplica {
    ///     fn route_read<'a>(&self, candidates: &ReadCandidates<'a>) -> &'a NodeAddress {
    ///         match candidates {
    ///             ReadCandidates::AnyNode(c) => c.replicas().first(),
    ///             ReadCandidates::ReplicasOnly(c) => c.replicas().first(),
    ///         }
    ///     }
    /// }
    ///
    /// let client = ClusterClientBuilder::new(vec!["redis://127.0.0.1:6379/"])
    ///     .read_routing_strategy(FirstReplica)
    ///     .build()
    ///     .unwrap();
    /// ```
    pub fn read_routing_strategy(
        mut self,
        strategy: impl ReadRoutingStrategyFactory + 'static,
    ) -> Self {
        self.builder_params.read_routing_factory = Some(Arc::new(strategy));
        self
    }

    /// Enables timing out on slow connection time.
    ///
    /// If enabled, the cluster will only wait the given time on each connection attempt to each node.
    pub fn connection_timeout(mut self, connection_timeout: Duration) -> Self {
        self.builder_params.connection_timeout = Some(connection_timeout);
        self
    }

    /// Enables timing out on slow responses.
    ///
    /// If enabled, the cluster will only wait the given time to each response from each node.
    /// This timeout is also used as the overall response timeout (including retries) unless
    /// overridden with [`Self::overall_response_timeout`].
    pub fn response_timeout(mut self, response_timeout: Duration) -> Self {
        self.builder_params.response_timeout = Some(response_timeout);
        self
    }

    /// Sets the overall timeout for a complete cluster request, including all retries,
    /// reconnections, and redirections (e.g. MOVED/ASK).
    ///
    /// By default this matches `response_timeout`, meaning the same duration is used both
    /// per-attempt and overall. This can cause requests to time out when retries are needed,
    /// since the retry must complete within whatever time remains from the original timeout.
    ///
    /// Set to `None` to disable the overall response timeout. Each individual attempt will
    /// still be bounded by `response_timeout`, but the total operation can take longer when
    /// retries occur. Set to `Some(duration)` to use a specific overall timeout independent
    /// of `response_timeout`.
    #[cfg(feature = "cluster-async")]
    pub fn overall_response_timeout(mut self, timeout: Option<Duration>) -> Self {
        self.builder_params.overall_response_timeout = OverallResponseTimeout::Explicit(timeout);
        self
    }

    /// Sets the protocol with which the client should communicate with the server.
    pub fn use_protocol(mut self, protocol: ProtocolVersion) -> Self {
        self.builder_params.protocol = Some(protocol);
        self
    }

    /// Sets the numbered database for the cluster client.
    ///
    /// If left unset, the database is inherited from the first
    /// node's URL (e.g. `redis://127.0.0.1:6379/4`), in which case all initial
    /// nodes must specify the same database. If set, it must not conflict with a
    /// database carried by any initial node's URL.
    ///
    /// The selected database is reapplied automatically after reconnects.
    ///
    /// Note that selecting a non-zero database in cluster mode requires a server that
    /// supports multiple databases in cluster mode; otherwise the connection handshake
    /// will fail.
    pub fn database_id(mut self, database_id: i64) -> Self {
        self.builder_params.database_id = Some(database_id);
        self
    }

    #[cfg(feature = "cluster-async")]
    /// Sets sender sender for push values.
    ///
    /// The sender can be a channel, or an arbitrary function that handles [crate::PushInfo] values.
    /// This will fail client creation if the connection isn't configured for RESP3 communications via the [crate::RedisConnectionInfo::set_protocol] function.
    ///
    /// # Examples
    ///
    /// ```rust
    /// # use redis::cluster::ClusterClientBuilder;
    /// let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    /// let config = ClusterClientBuilder::new(vec!["redis://127.0.0.1:6379/"])
    ///     .use_protocol(redis::ProtocolVersion::RESP3)
    ///     .push_sender(tx);
    /// ```
    ///
    /// ```rust
    /// # use std::sync::{Mutex, Arc};
    /// # use redis::cluster::ClusterClientBuilder;
    /// let messages = Arc::new(Mutex::new(Vec::new()));
    /// let config = ClusterClientBuilder::new(vec!["redis://127.0.0.1:6379/"])
    ///     .use_protocol(redis::ProtocolVersion::RESP3)
    ///     .push_sender(move |msg|{
    ///         let Ok(mut messages) = messages.lock() else {
    ///             return Err(redis::aio::SendError);
    ///         };
    ///         messages.push(msg);
    ///         Ok(())
    ///     });
    /// ```
    pub fn push_sender(mut self, push_sender: impl AsyncPushSender) -> Self {
        self.builder_params.async_push_sender = Some(Arc::new(push_sender));
        self
    }

    /// Set the behavior of the underlying TCP connections.
    pub fn tcp_settings(mut self, tcp_settings: TcpSettings) -> Self {
        self.builder_params.tcp_settings = tcp_settings;
        self
    }

    /// Sets a node address map for remapping cluster node addresses.
    ///
    /// In TLS-enabled clusters, nodes may advertise IP addresses via `CLUSTER SLOTS`,
    /// but TLS certificates are issued for domain names. This causes TLS verification
    /// to fail because the certificate's Subject Alternative Names don't include
    /// the IP address.
    ///
    /// The node address map lets you provide a mapping from the IP-based addresses
    /// returned by `CLUSTER SLOTS` to the hostnames that match the TLS certificates.
    /// The mapping is applied at connection time only — the internal slot map retains
    /// the original addresses so that `MOVED`/`ASK` redirects continue to work.
    pub fn node_address_map(mut self, map: HashMap<NodeAddress, NodeAddress>) -> Self {
        self.builder_params.node_address_map = Some(map);
        self
    }

    /// Set asynchronous DNS resolver for the underlying TCP connections.
    ///
    /// The parameter resolver must implement the [`crate::io::AsyncDNSResolver`] trait.
    #[cfg(feature = "cluster-async")]
    pub fn async_dns_resolver(mut self, resolver: impl AsyncDNSResolver) -> Self {
        self.builder_params.async_dns_resolver = Some(Arc::new(resolver));
        self
    }

    /// Sets cache config for [`crate::cluster_async::ClusterConnection`], check CacheConfig for more details.
    #[cfg(all(feature = "cache-aio", feature = "cluster-async"))]
    pub fn cache_config(mut self, cache_config: CacheConfig) -> Self {
        self.builder_params.cache_config = Some(cache_config);
        self
    }

    /// Sets the maximum number of outstanding requests allowed per connection to a cluster node.
    ///
    /// When set, each node connection will allow at most `limit` concurrent in-flight requests.
    /// Additional requests will wait until an in-flight request completes.
    ///
    /// Pipelined commands try to acquire one permit per command, but will proceed with
    /// fewer if not all are immediately available. This means a pipeline may temporarily
    /// push the effective in-flight count above the limit.
    ///
    /// This is useful for preventing a large backlog of commands from building up when a node
    /// goes offline or becomes slow. Without a limit, requests continue to queue unboundedly
    /// on the connection. When the node is degraded, requests near the back of the queue
    /// spend most of their time waiting behind earlier requests and are likely to hit their
    /// response timeout before the server even processes them -- wasting work on both sides.
    /// Setting a concurrency limit caps the number of in-flight requests per node, so
    /// backpressure is applied earlier and fewer requests are lost to timeouts.
    ///
    /// By default there is no limit.
    #[cfg(feature = "cluster-async")]
    pub fn connection_concurrency_limit(mut self, limit: usize) -> Self {
        self.builder_params.connection_concurrency_limit = Some(limit);
        self
    }

    /// Sets the flush threshold (backpressure boundary) for each node connection's outbound write buffer.
    ///
    /// See [`crate::AsyncConnectionConfig::set_write_backpressure_boundary`] for full semantics.
    /// This value is applied identically to every node connection in the cluster.
    ///
    /// When left unset, connections keep `tokio_util`'s default boundary.
    #[cfg(feature = "cluster-async")]
    pub fn write_backpressure_boundary(mut self, boundary: usize) -> Self {
        self.builder_params.write_backpressure_boundary = Some(boundary);
        self
    }

    /// Sets a credentials provider for dynamic authentication (e.g., token-based authentication)
    /// on all cluster node connections.
    ///
    /// Each node connection will independently subscribe to the provider and automatically
    /// re-authenticate when new credentials are emitted.
    #[cfg(all(feature = "token-based-authentication", feature = "cluster-async"))]
    pub fn set_credentials_provider<P>(mut self, provider: P) -> Self
    where
        P: StreamingCredentialsProvider + 'static,
    {
        self.builder_params.credentials_provider = Some(std::sync::Arc::new(provider));
        self
    }

    /// Sets the maximum number of connection attempts to a cluster node before giving up, and removing the
    /// node from the cluster. This is useful for clusters with a large number of nodes, where some nodes may be temporarily unavailable.
    /// Removed nodes will be re-added to the cluster after a topology refresh.
    /// If the value isn't set, reconnect attempts will continue indefinitely until the node is available again.
    #[cfg(feature = "cluster-async")]
    pub fn max_connection_attempts(mut self, max_attempts: NonZeroUsize) -> Self {
        self.builder_params.max_connection_attempts = Some(max_attempts);
        self
    }
}

/// A Redis Cluster client, used to create connections.
#[derive(Clone)]
pub struct ClusterClient {
    initial_nodes: Vec<ConnectionInfo>,
    cluster_params: ClusterParams,
}

impl ClusterClient {
    /// Creates a `ClusterClient` with the default parameters.
    ///
    /// This does not create connections to the Redis Cluster, but only performs some basic checks
    /// on the initial nodes' URLs and passwords/usernames.
    ///
    /// # Errors
    ///
    /// Upon failure to parse initial nodes or if the initial nodes have different passwords or
    /// usernames, an error is returned.
    pub fn new<T: IntoConnectionInfo>(
        initial_nodes: impl IntoIterator<Item = T>,
    ) -> RedisResult<Self> {
        Self::builder(initial_nodes).build()
    }

    /// Creates a [`ClusterClientBuilder`] with the provided initial_nodes.
    pub fn builder<T: IntoConnectionInfo>(
        initial_nodes: impl IntoIterator<Item = T>,
    ) -> ClusterClientBuilder {
        ClusterClientBuilder::new(initial_nodes)
    }

    /// Creates new connections to Redis Cluster nodes and returns a
    /// [`cluster::ClusterConnection`].
    ///
    /// # Errors
    ///
    /// An error is returned if there is a failure while creating connections or slots.
    pub fn get_connection(&self) -> RedisResult<cluster::ClusterConnection> {
        cluster::ClusterConnection::new(self.cluster_params.clone(), self.initial_nodes.clone())
    }

    /// Creates new connections to Redis Cluster nodes with a custom config and returns a
    /// [`cluster_async::ClusterConnection`].
    ///
    /// # Errors
    ///
    /// An error is returned if there is a failure while creating connections or slots.
    pub fn get_connection_with_config(
        &self,
        config: cluster::ClusterConfig,
    ) -> RedisResult<cluster::ClusterConnection> {
        cluster::ClusterConnection::new(
            self.cluster_params.clone().with_config(config),
            self.initial_nodes.clone(),
        )
    }

    /// Creates new connections to Redis Cluster nodes and returns a
    /// [`cluster_async::ClusterConnection`].
    ///
    /// # Errors
    ///
    /// An error is returned if there is a failure while creating connections or slots.
    #[cfg(feature = "cluster-async")]
    pub async fn get_async_connection(&self) -> RedisResult<cluster_async::ClusterConnection> {
        cluster_async::ClusterConnection::new(&self.initial_nodes, self.cluster_params.clone())
            .await
    }

    /// Creates new connections to Redis Cluster nodes with a custom config and returns a
    /// [`cluster_async::ClusterConnection`].
    ///
    /// # Errors
    ///
    /// An error is returned if there is a failure while creating connections or slots.
    #[cfg(feature = "cluster-async")]
    pub async fn get_async_connection_with_config(
        &self,
        config: cluster::ClusterConfig,
    ) -> RedisResult<cluster_async::ClusterConnection> {
        cluster_async::ClusterConnection::new(
            &self.initial_nodes,
            self.cluster_params.clone().with_config(config),
        )
        .await
    }

    /// Creates new connections to Redis Cluster nodes with a custom config and returns a
    /// [`cluster_async::ClusterConnection`]. The connections to the cluster nodes are done in the
    /// background so the caller won't know if the cluster is available until the first command is sent.
    #[cfg(feature = "cluster-async")]
    pub fn get_pending_async_connection_with_config(
        &self,
        config: cluster::ClusterConfig,
    ) -> cluster_async::ClusterConnection {
        cluster_async::ClusterConnection::new_pending(
            &self.initial_nodes,
            self.cluster_params.clone().with_config(config),
        )
    }

    #[doc(hidden)]
    pub fn get_generic_connection<C>(&self) -> RedisResult<cluster::ClusterConnection<C>>
    where
        C: crate::ConnectionLike + crate::cluster::Connect + Send,
    {
        cluster::ClusterConnection::new(self.cluster_params.clone(), self.initial_nodes.clone())
    }

    #[doc(hidden)]
    #[cfg(feature = "cluster-async")]
    pub async fn get_async_generic_connection<C>(
        &self,
    ) -> RedisResult<cluster_async::ClusterConnection<C>>
    where
        C: crate::aio::ConnectionLike
            + cluster_async::Connect
            + Clone
            + Send
            + Sync
            + Unpin
            + 'static,
    {
        cluster_async::ClusterConnection::new(&self.initial_nodes, self.cluster_params.clone())
            .await
    }
}

#[cfg(test)]
mod tests {
    use super::{ClusterClient, ClusterClientBuilder, ConnectionInfo, IntoConnectionInfo};
    use std::time::Duration;

    fn get_connection_data() -> Vec<ConnectionInfo> {
        vec![
            "redis://127.0.0.1:6379".into_connection_info().unwrap(),
            "redis://127.0.0.1:6378".into_connection_info().unwrap(),
            "redis://127.0.0.1:6377".into_connection_info().unwrap(),
        ]
    }

    fn get_connection_data_with_password() -> Vec<ConnectionInfo> {
        vec![
            "redis://:password@127.0.0.1:6379"
                .into_connection_info()
                .unwrap(),
            "redis://:password@127.0.0.1:6378"
                .into_connection_info()
                .unwrap(),
            "redis://:password@127.0.0.1:6377"
                .into_connection_info()
                .unwrap(),
        ]
    }

    fn get_connection_data_with_username_and_password() -> Vec<ConnectionInfo> {
        vec![
            "redis://user1:password@127.0.0.1:6379"
                .into_connection_info()
                .unwrap(),
            "redis://user1:password@127.0.0.1:6378"
                .into_connection_info()
                .unwrap(),
            "redis://user1:password@127.0.0.1:6377"
                .into_connection_info()
                .unwrap(),
        ]
    }

    #[test]
    fn give_no_password() {
        let client = ClusterClient::new(get_connection_data()).unwrap();
        assert_eq!(client.cluster_params.password, None);
    }

    #[test]
    fn give_password_by_initial_nodes() {
        let client = ClusterClient::new(get_connection_data_with_password()).unwrap();
        assert_eq!(client.cluster_params.password, Some("password".into()));
    }

    #[test]
    fn give_username_and_password_by_initial_nodes() {
        let client = ClusterClient::new(get_connection_data_with_username_and_password()).unwrap();
        assert_eq!(client.cluster_params.password, Some("password".into()));
        assert_eq!(client.cluster_params.username, Some("user1".into()));
    }

    #[test]
    fn fail_if_received_different_password_between_initial_nodes() {
        let result = ClusterClient::new(vec![
            "redis://:password1@127.0.0.1:6379",
            "redis://:password2@127.0.0.1:6378",
            "redis://:password3@127.0.0.1:6377",
        ]);
        assert!(result.is_err());
    }

    #[test]
    fn fail_if_received_different_username_between_initial_nodes() {
        let result = ClusterClient::new(vec![
            "redis://user1:password@127.0.0.1:6379",
            "redis://user2:password@127.0.0.1:6378",
            "redis://user1:password@127.0.0.1:6377",
        ]);
        assert!(result.is_err());
    }

    #[test]
    fn fail_if_received_different_protocol_between_initial_nodes() {
        let result = ClusterClient::new(vec![
            "redis://127.0.0.1:6379/?protocol=3",
            "redis://127.0.0.1:6378",
            "redis://127.0.0.1:6377",
        ]);
        assert!(result.is_err());
    }

    #[test]
    fn fail_if_received_different_tls_between_initial_nodes() {
        let result = ClusterClient::new(vec![
            "rediss://127.0.0.1:6379/",
            "redis://127.0.0.1:6378",
            "redis://127.0.0.1:6377",
        ]);
        assert!(result.is_err());
    }

    #[test]
    fn give_username_password_by_method() {
        let client = ClusterClientBuilder::new(get_connection_data_with_username_and_password())
            .password("password")
            .username("user1")
            .build()
            .unwrap();
        assert_eq!(client.cluster_params.password, Some("password".into()));
        assert_eq!(client.cluster_params.username, Some("user1".into()));
    }

    #[test]
    fn give_empty_initial_nodes() {
        let client = ClusterClient::new(Vec::<String>::new());
        assert!(client.is_err());
    }

    #[test]
    fn database_id_defaults_to_zero() {
        let client = ClusterClient::new(get_connection_data()).unwrap();
        assert_eq!(client.cluster_params.database_id, Some(0));
    }

    #[test]
    fn give_database_id_by_method() {
        let client = ClusterClientBuilder::new(get_connection_data())
            .database_id(4)
            .build()
            .unwrap();
        assert_eq!(client.cluster_params.database_id, Some(4));
    }

    #[test]
    fn give_database_id_by_initial_nodes() {
        let client = ClusterClient::new(vec![
            "redis://127.0.0.1:6379/4",
            "redis://127.0.0.1:6378/4",
            "redis://127.0.0.1:6377/4",
        ])
        .unwrap();
        assert_eq!(client.cluster_params.database_id, Some(4));
    }

    #[test]
    fn fail_if_database_id_method_conflicts_with_initial_nodes() {
        let result = ClusterClientBuilder::new(vec![
            "redis://127.0.0.1:6379/2",
            "redis://127.0.0.1:6378/2",
            "redis://127.0.0.1:6377/2",
        ])
        .database_id(7)
        .build();
        assert!(result.is_err());
    }

    #[test]
    fn fail_if_explicit_database_id_zero_conflicts_with_initial_nodes() {
        let result = ClusterClientBuilder::new(vec![
            "redis://127.0.0.1:6379/4",
            "redis://127.0.0.1:6378/4",
            "redis://127.0.0.1:6377/4",
        ])
        .database_id(0)
        .build();
        assert!(result.is_err());
    }

    #[test]
    fn give_database_id_by_method_matching_initial_nodes() {
        let client = ClusterClientBuilder::new(vec![
            "redis://127.0.0.1:6379/4",
            "redis://127.0.0.1:6378/4",
            "redis://127.0.0.1:6377/4",
        ])
        .database_id(4)
        .build()
        .unwrap();
        assert_eq!(client.cluster_params.database_id, Some(4));
    }

    #[test]
    fn give_database_id_zero_by_method_matching_initial_nodes() {
        let client = ClusterClientBuilder::new(vec![
            "redis://127.0.0.1:6379/0",
            "redis://127.0.0.1:6378/0",
            "redis://127.0.0.1:6377/0",
        ])
        .database_id(0)
        .build()
        .unwrap();
        assert_eq!(client.cluster_params.database_id, Some(0));
    }

    #[test]
    fn fail_if_received_different_database_between_initial_nodes() {
        let result = ClusterClient::new(vec![
            "redis://127.0.0.1:6379/4",
            "redis://127.0.0.1:6378/5",
            "redis://127.0.0.1:6377/4",
        ]);
        assert!(result.is_err());
    }

    #[cfg(feature = "cluster-async")]
    #[test]
    fn overall_response_timeout_defaults_to_response_timeout() {
        let client = ClusterClientBuilder::new(get_connection_data())
            .response_timeout(Duration::from_secs(5))
            .build()
            .unwrap();
        assert_eq!(
            client.cluster_params.overall_response_timeout,
            Some(Duration::from_secs(5))
        );
    }

    #[cfg(feature = "cluster-async")]
    #[test]
    fn overall_response_timeout_can_be_disabled() {
        let client = ClusterClientBuilder::new(get_connection_data())
            .response_timeout(Duration::from_secs(5))
            .overall_response_timeout(None)
            .build()
            .unwrap();
        assert_eq!(client.cluster_params.overall_response_timeout, None);
    }

    #[cfg(feature = "cluster-async")]
    #[test]
    fn overall_response_timeout_can_be_set_independently() {
        let client = ClusterClientBuilder::new(get_connection_data())
            .response_timeout(Duration::from_secs(5))
            .overall_response_timeout(Some(Duration::from_secs(30)))
            .build()
            .unwrap();
        assert_eq!(
            client.cluster_params.overall_response_timeout,
            Some(Duration::from_secs(30))
        );
    }

    #[cfg(feature = "cluster-async")]
    #[test]
    fn connection_concurrency_limit_default() {
        let client = ClusterClient::new(get_connection_data()).unwrap();
        assert_eq!(client.cluster_params.connection_concurrency_limit, None);
    }

    #[cfg(feature = "cluster-async")]
    #[test]
    fn connection_concurrency_limit_custom() {
        let client = ClusterClientBuilder::new(get_connection_data())
            .connection_concurrency_limit(128)
            .build()
            .unwrap();
        assert_eq!(
            client.cluster_params.connection_concurrency_limit,
            Some(128)
        );
    }

    #[cfg(feature = "cluster-async")]
    #[test]
    fn write_backpressure_boundary_default() {
        let client = ClusterClient::new(get_connection_data()).unwrap();
        assert_eq!(client.cluster_params.write_backpressure_boundary, None);
    }

    #[cfg(feature = "cluster-async")]
    #[test]
    fn write_backpressure_boundary_custom() {
        let client = ClusterClientBuilder::new(get_connection_data())
            .write_backpressure_boundary(16 * 1024 * 1024)
            .build()
            .unwrap();
        assert_eq!(
            client.cluster_params.write_backpressure_boundary,
            Some(16 * 1024 * 1024)
        );
    }

    #[test]
    fn cluster_retry_clamp_order_caps_at_max_after_floor() {
        // Documented chain is `max(base, min+1).min(max)`; the old `.min(max).max(min+1)` overshoots `max` here.
        let base = 10u64;
        let min_w = 100u64;
        let max_w = 50u64;
        assert_eq!(base.max(min_w + 1).min(max_w), 50);
        assert_eq!(base.min(max_w).max(min_w + 1), 101);
        // Exclusive upper must exceed `min_wait` for `random_range`, so we lift when the clamp hits `min_wait`.
        assert_eq!(
            super::cluster_retry_wait_upper_ms(base, min_w, max_w),
            min_w + 1
        );
    }

    #[test]
    fn cluster_retry_wait_upper_strictly_above_min_when_min_equals_max() {
        assert_eq!(super::cluster_retry_wait_upper_ms(10, 100, 100), 101);
    }

    #[test]
    fn cluster_retry_wait_time_does_not_panic_when_min_equals_max() {
        let p = super::RetryParams {
            number_of_retries: 16,
            max_wait_time: 100,
            min_wait_time: 100,
            exponent_base: 2,
            factor: 10,
        };
        let _ = p.wait_time_for_retry(0);
    }
}
