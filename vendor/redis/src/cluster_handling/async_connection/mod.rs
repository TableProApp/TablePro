//! This module provides async functionality for connecting to Redis / Valkey Clusters.
//!
//! The cluster connection is meant to abstract the fact that a cluster is composed of multiple nodes,
//! and to provide an API which is as close as possible to that of a single node connection. In order to do that,
//! the cluster connection maintains connections to each node in the Redis/ Valkey cluster, and can route
//! requests automatically to the relevant nodes. In cases that the cluster connection receives indications
//! that the cluster topology has changed, it will query nodes in order to find the current cluster topology.
//! If it disconnects from some nodes, it will automatically reconnect to those nodes.
//!
//! By default, [`ClusterConnection`] makes use of [`MultiplexedConnection`] and maintains a pool
//! of connections to each node in the cluster.
//!
//! # Example
//! ```rust,no_run
//! use redis::cluster::ClusterClient;
//! use redis::AsyncTypedCommands;
//!
//! async fn fetch_an_integer() -> String {
//!     let nodes = vec!["redis://127.0.0.1/"];
//!     let client = ClusterClient::new(nodes).unwrap();
//!     let mut connection = client.get_async_connection().await.unwrap();
//!     connection.set("test", "test_data").await.unwrap();
//!     let rv = connection.get("test").await.unwrap().unwrap();
//!     return rv;
//! }
//! ```
//!
//! # Pipelining
//! ```rust,no_run
//! use redis::cluster::ClusterClient;
//! use redis::{Value, AsyncCommands};
//!
//! async fn fetch_an_integer() -> redis::RedisResult<()> {
//!     let nodes = vec!["redis://127.0.0.1/"];
//!     let client = ClusterClient::new(nodes).unwrap();
//!     let mut connection = client.get_async_connection().await.unwrap();
//!     let key = "test";
//!
//!     redis::pipe()
//!         .rpush(key, "123").ignore()
//!         .ltrim(key, -10, -1).ignore()
//!         .expire(key, 60).ignore()
//!         .exec_async(&mut connection).await
//! }
//! ```
//!
//! # Pubsub
//!
//! Pubsub, and generally receiving push messages from the cluster nodes, is now supported
//! when defining a connection with [crate::ProtocolVersion::RESP3] and some
//! [crate::aio::AsyncPushSender] to receive the messages on.
//!
//! ```rust,no_run
//! use redis::cluster::ClusterClientBuilder;
//! use redis::{Value, AsyncCommands};
//!
//! async fn fetch_an_integer() -> redis::RedisResult<()> {
//!     let nodes = vec!["redis://127.0.0.1/?protocol=3"];
//!     let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
//!     let client = ClusterClientBuilder::new(nodes)
//!         .use_protocol(redis::ProtocolVersion::RESP3)
//!         .push_sender(tx).build()?;
//!     let mut connection = client.get_async_connection().await?;
//!     connection.subscribe("channel").await?;
//!     while let Some(msg) = rx.recv().await {
//!         println!("Got: {:?}", msg);
//!     }
//!     Ok(())
//! }
//! ```
//!
//! # Sending request to specific node
//! In some cases you'd want to send a request to a specific node in the cluster, instead of
//! letting the cluster connection decide by itself to which node it should send the request.
//! This can happen, for example, if you want to send SCAN commands to each node in the cluster.
//!
//! ```rust,no_run
//! use redis::cluster::ClusterClient;
//! use redis::{Value, AsyncCommands};
//! use redis::cluster_routing::{ RoutingInfo, SingleNodeRoutingInfo };
//!
//! async fn fetch_an_integer() -> redis::RedisResult<Value> {
//!     let nodes = vec!["redis://127.0.0.1/"];
//!     let client = ClusterClient::new(nodes)?;
//!     let mut connection = client.get_async_connection().await?;
//!     let routing_info = RoutingInfo::SingleNode(SingleNodeRoutingInfo::ByAddress{
//!         host: "redis://127.0.0.1".to_string(),
//!         port: 6378
//!     });
//!     connection.route_command(redis::cmd("PING"), routing_info).await
//! }
//! ```
use std::{
    collections::{HashMap, HashSet},
    fmt,
    future::Future,
    io,
    ops::Deref,
    pin::{Pin, pin},
    sync::{Arc, Mutex},
    task::{self, Poll},
    time::Duration,
};

mod addressed_push_sender;
mod request;
mod routing;
use crate::{
    AsyncConnectionConfig, Cmd, ConnectionInfo, ErrorKind, IntoConnectionInfo, PushInfo,
    RedisError, RedisFuture, RedisResult, ToRedisArgs, Value,
    aio::{ConnectionLike, HandleContainer, MultiplexedConnection, Runtime},
    check_resp3,
    cluster_async::{addressed_push_sender::AddressedPushSender, request::ResultExpectation},
    cluster_handling::{
        NodeAddress,
        client::ClusterParams,
        get_connection_info,
        read_routing::ReadRoutingStrategy,
        routing::{
            MultipleNodeRoutingInfo, Redirect, ResponsePolicy, RoutingInfo, SingleNodeRoutingInfo,
        },
        slot_cmd,
        slot_map::{SlotMap, SlotRange},
        topology::parse_slots,
    },
    cmd,
    errors::closed_connection_error,
    subscription_tracker::SubscriptionTracker,
};

use crate::ProtocolVersion;
#[cfg(feature = "cache-aio")]
use crate::caching::{CacheManager, CacheStatistics};
use futures_channel::mpsc::UnboundedSender;
use futures_util::{
    future::{self, BoxFuture, FutureExt, select},
    ready,
    sink::Sink,
    stream::{self, Stream, StreamExt},
};
use log::{debug, error, info, trace, warn};
use rand::{rng, seq::IteratorRandom};
use request::{CmdArg, PendingRequest, Request, RequestState, Retry};
use routing::{InternalRoutingInfo, InternalSingleNodeRouting, route_for_pipeline};
use tokio::sync::{RwLock, mpsc, oneshot};

struct ClientSideState {
    protocol: ProtocolVersion,
    _task_handle: HandleContainer,
    overall_response_timeout: Option<Duration>,
    runtime: Runtime,
    #[cfg(feature = "cache-aio")]
    cache_manager: Option<CacheManager>,
}

/// This represents an async Redis Cluster connection.
///
/// It stores the underlying connections maintained for each node in the cluster,
/// as well as common parameters for connecting to nodes and executing commands.
#[derive(Clone)]
pub struct ClusterConnection<C = MultiplexedConnection> {
    state: Arc<ClientSideState>,
    sender: mpsc::Sender<Message<C>>,
}

impl<C> ClusterConnection<C>
where
    C: ConnectionLike + Connect + Clone + Send + Sync + Unpin + 'static,
{
    pub(crate) async fn new(
        initial_nodes: &[ConnectionInfo],
        cluster_params: ClusterParams,
    ) -> RedisResult<Self> {
        let (connection, connect_receiver) = Self::new_inner(initial_nodes, cluster_params);
        connect_receiver.await.map_err(|_| {
            RedisError::from((ErrorKind::Io, "Cluster connection task were dropped"))
        })??;
        Ok(connection)
    }

    pub(crate) fn new_pending(
        initial_nodes: &[ConnectionInfo],
        cluster_params: ClusterParams,
    ) -> Self {
        let (connection, _connect_receiver) = Self::new_inner(initial_nodes, cluster_params);
        connection
    }

    pub(crate) fn new_inner(
        initial_nodes: &[ConnectionInfo],
        mut cluster_params: ClusterParams,
    ) -> (Self, oneshot::Receiver<RedisResult<()>>) {
        let protocol = cluster_params.protocol.unwrap_or_default();
        let overall_response_timeout = cluster_params.overall_response_timeout;
        #[cfg(feature = "cache-aio")]
        let cache_manager = cluster_params.cache_manager.clone();
        let runtime = Runtime::locate();

        let (push_sender, mut push_receiver) = futures_channel::mpsc::unbounded();
        let external_push_sender = cluster_params.async_push_sender.take();
        let has_push_sender = external_push_sender.is_some();
        let (sender, mut receiver) = mpsc::channel::<Message<_>>(100);
        let weak_sender = sender.downgrade();

        let mut inner =
            ClusterConnInner::new(initial_nodes, cluster_params, push_sender, has_push_sender);

        let reconnect_from_pushes_task = if protocol.supports_resp3() {
            async move {
                while let Some((addr, msg)) = push_receiver.next().await {
                    if msg.kind == crate::PushKind::Disconnection
                        && let Some(sender) = weak_sender.upgrade()
                    {
                        _ = sender
                            .send(Message {
                                cmd: CmdArg::Reconnect(addr.clone()),
                                sender: ResultExpectation::Internal,
                            })
                            .await;
                    }
                    if let Some(push_sender) = &external_push_sender {
                        _ = push_sender.send(msg);
                    }
                }
            }
            .boxed()
        } else {
            future::pending().boxed()
        };

        let (connect_sender, connect_receiver) = oneshot::channel::<RedisResult<()>>();
        let request_stream = async move {
            let connect_result = inner.wait_for_initial_connection().await;
            let _ = connect_sender
                .send(connect_result)
                .inspect_err(|e| debug!("failed internal sending with {e:?}"));

            let _ = stream::poll_fn(move |cx| receiver.poll_recv(cx))
                .map(Ok)
                .forward(inner)
                .await;
        };
        let _task_handle = HandleContainer::new(runtime.spawn(async move {
            select(pin!(request_stream), pin!(reconnect_from_pushes_task)).await;
        }));

        (
            Self {
                sender,
                state: Arc::new(ClientSideState {
                    protocol,
                    _task_handle,
                    overall_response_timeout,
                    runtime,
                    #[cfg(feature = "cache-aio")]
                    cache_manager,
                }),
            },
            connect_receiver,
        )
    }

    /// Send a command to the given `routing`, and aggregate the response according to `response_policy`.
    pub async fn route_command(&mut self, cmd: Cmd, routing: RoutingInfo) -> RedisResult<Value> {
        trace!("send_packed_command");
        let (sender, receiver) = oneshot::channel();
        let request = async {
            self.sender
                .send(Message {
                    cmd: CmdArg::Cmd {
                        cmd: Arc::new(cmd),
                        routing: routing.into(),
                    },
                    sender: ResultExpectation::External(sender),
                })
                .await
                .map_err(|_| {
                    RedisError::from(io::Error::new(
                        io::ErrorKind::BrokenPipe,
                        "redis_cluster: Unable to send command",
                    ))
                })?;

            receiver
                .await
                .unwrap_or_else(|_| {
                    Err(RedisError::from(io::Error::new(
                        io::ErrorKind::BrokenPipe,
                        "redis_cluster: Unable to receive command",
                    )))
                })
                .map(|response| match response {
                    Response::Single(value) => value,
                    Response::Multiple(_) => unreachable!(),
                })
        };

        match self.state.overall_response_timeout {
            Some(duration) => self.state.runtime.timeout(duration, request).await?,
            None => request.await,
        }
    }

    /// Send commands in `pipeline` to the given `route`. If `route` is [None], it will be sent to a random node.
    pub async fn route_pipeline(
        &mut self,
        pipeline: crate::Pipeline,
        offset: usize,
        count: usize,
        route: SingleNodeRoutingInfo,
    ) -> RedisResult<Vec<Value>> {
        let (sender, receiver) = oneshot::channel();

        let request = async {
            self.sender
                .send(Message {
                    cmd: CmdArg::Pipeline {
                        pipeline: Arc::new(pipeline),
                        offset,
                        count,
                        route: route.into(),
                    },
                    sender: ResultExpectation::External(sender),
                })
                .await
                .map_err(|_| closed_connection_error())?;
            receiver
                .await
                .unwrap_or_else(|_| Err(closed_connection_error()))
                .map(|response| match response {
                    Response::Multiple(values) => values,
                    Response::Single(_) => unreachable!(),
                })
        };

        match self.state.overall_response_timeout {
            Some(duration) => self.state.runtime.timeout(duration, request).await?,
            None => request.await,
        }
    }

    /// Subscribes to a new channel(s).
    ///
    /// Updates from the sender will be sent on the push sender that was passed to the manager.
    /// If the manager was configured without a push sender, the connection won't be able to pass messages back to the user.
    ///
    /// This method is only available when the connection is using RESP3 protocol, and will return an error otherwise.
    /// It should be noted that the subscription will be automatically resubscribed after disconnections, so the user might
    /// receive additional pushes with [crate::PushKind::Subscribe], later after the subscription completed.
    ///
    /// ```rust,no_run
    /// # async fn func() -> redis::RedisResult<()> {
    /// let nodes = vec!["redis://127.0.0.1/protocol=3"];
    /// let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    /// let client = redis::cluster::ClusterClientBuilder::new(nodes)
    ///   .use_protocol(redis::ProtocolVersion::RESP3)
    ///   .push_sender(tx).build()?;
    /// let mut con = client.get_async_connection().await?;
    /// con.subscribe(&["channel_1", "channel_2"]).await?;
    /// con.unsubscribe(&["channel_1", "channel_2"]).await?;
    /// # Ok(()) }
    /// ```
    pub async fn subscribe(&mut self, channel_name: impl ToRedisArgs) -> RedisResult<()> {
        check_resp3!(self.state.protocol);
        let mut cmd = cmd("SUBSCRIBE");
        cmd.arg(channel_name);
        cmd.exec_async(self).await?;
        Ok(())
    }

    /// Unsubscribes from channel(s).
    ///
    /// This method is only available when the connection is using RESP3 protocol, and will return an error otherwise.
    pub async fn unsubscribe(&mut self, channel_name: impl ToRedisArgs) -> RedisResult<()> {
        check_resp3!(self.state.protocol);
        let mut cmd = cmd("UNSUBSCRIBE");
        cmd.arg(channel_name);
        cmd.exec_async(self).await?;
        Ok(())
    }

    /// Subscribes to new channel(s) with pattern(s).
    ///
    /// Updates from the sender will be sent on the push sender that was passed to the manager.
    /// If the manager was configured without a push sender, the manager won't be able to pass messages back to the user.
    ///
    /// This method is only available when the connection is using RESP3 protocol, and will return an error otherwise.
    /// It should be noted that the subscription will be automatically resubscribed after disconnections, so the user might
    /// receive additional pushes with [crate::PushKind::PSubscribe], later after the subscription completed.
    ///
    /// ```rust,no_run
    /// # #[cfg(feature = "aio")]
    /// # async fn do_something() -> redis::RedisResult<()> {
    /// let nodes = vec!["redis://127.0.0.1/protocol=3"];
    /// let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    /// let client = redis::cluster::ClusterClientBuilder::new(nodes)
    ///   .use_protocol(redis::ProtocolVersion::RESP3)
    ///   .push_sender(tx).build()?;
    /// let mut connection = client.get_async_connection().await?;
    /// connection.psubscribe("channel*_1").await?;
    /// connection.psubscribe(&["channel*_2", "channel*_3"]).await?;
    /// # Ok(())
    /// # }
    /// ```
    pub async fn psubscribe(&mut self, channel_pattern: impl ToRedisArgs) -> RedisResult<()> {
        check_resp3!(self.state.protocol);
        let mut cmd = cmd("PSUBSCRIBE");
        cmd.arg(channel_pattern);
        cmd.exec_async(self).await?;
        Ok(())
    }

    /// Unsubscribes from channel pattern(s).
    ///
    /// This method is only available when the connection is using RESP3 protocol, and will return an error otherwise.
    pub async fn punsubscribe(&mut self, channel_pattern: impl ToRedisArgs) -> RedisResult<()> {
        check_resp3!(self.state.protocol);
        let mut cmd = cmd("PUNSUBSCRIBE");
        cmd.arg(channel_pattern);
        cmd.exec_async(self).await?;
        Ok(())
    }

    /// Subscribes to a new sharded channel(s).
    ///
    /// Updates from the sender will be sent on the push sender that was passed to the manager.
    /// If the manager was configured without a push sender, the manager won't be able to pass messages back to the user.
    ///
    /// This method is only available when the connection is using RESP3 protocol, and will return an error otherwise.
    /// It should be noted that the subscription will be automatically resubscribed after disconnections, so the user might
    /// receive additional pushes with [crate::PushKind::SSubscribe], later after the subscription completed.
    ///
    /// ```rust,no_run
    /// # async fn func() -> redis::RedisResult<()> {
    /// let nodes = vec!["redis://127.0.0.1/protocol=3"];
    /// let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    /// let client = redis::cluster::ClusterClientBuilder::new(nodes)
    ///   .use_protocol(redis::ProtocolVersion::RESP3)
    ///   .push_sender(tx).build()?;
    /// let mut connection = client.get_async_connection().await?;
    /// connection.ssubscribe(&["channel_1", "channel_2"]).await?;
    /// connection.sunsubscribe(&["channel_1", "channel_2"]).await?;
    /// # Ok(()) }
    /// ```
    pub async fn ssubscribe(&mut self, channel_name: impl ToRedisArgs) -> RedisResult<()> {
        check_resp3!(self.state.protocol);
        let mut cmd = cmd("SSUBSCRIBE");
        cmd.arg(channel_name);
        cmd.exec_async(self).await?;
        Ok(())
    }

    /// Unsubscribes from sharded channel(s).
    ///
    /// This method is only available when the connection is using RESP3 protocol, and will return an error otherwise.
    pub async fn sunsubscribe(&mut self, channel_name: impl ToRedisArgs) -> RedisResult<()> {
        check_resp3!(self.state.protocol);
        let mut cmd = cmd("SUNSUBSCRIBE");
        cmd.arg(channel_name);
        cmd.exec_async(self).await?;
        Ok(())
    }
    /// Gets [`CacheStatistics`] for cluster connection if caching is enabled.
    #[cfg(feature = "cache-aio")]
    #[cfg_attr(docsrs, doc(cfg(feature = "cache-aio")))]
    pub fn get_cache_statistics(&self) -> Option<CacheStatistics> {
        self.state.cache_manager.as_ref().map(|cm| cm.statistics())
    }
}

type ConnectionMap<C> = HashMap<NodeAddress, ConnState<C>>;

enum ConnState<C> {
    // Connection has been successfully established at some point.
    Connected(C),
    // Connection is being repaired/reconnected. The old C is retained for faster reconnect.
    Reconnecting(C),
    // New connection that we are trying to connect to.
    Connecting,
}

impl<C> std::fmt::Debug for ConnState<C> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Connected(_) => f.debug_tuple("Connected").finish(),
            Self::Reconnecting(_) => f.debug_tuple("Reconnecting").finish(),
            Self::Connecting => write!(f, "Connecting"),
        }
    }
}

impl<C> ConnState<C> {
    fn connected(&self) -> Option<C>
    where
        C: Clone,
    {
        match self {
            Self::Connected(conn) => Some(conn.clone()),
            Self::Reconnecting(_) | Self::Connecting => None,
        }
    }

    // Get the underlying connection anyway whether it is being reconnected or not.
    fn connected_or_reconnecting(&self) -> Option<C>
    where
        C: Clone,
    {
        match self {
            Self::Connected(conn) | Self::Reconnecting(conn) => Some(conn.clone()),
            Self::Connecting => None,
        }
    }

    fn into_conn(self) -> Option<C> {
        match self {
            Self::Connected(conn) | Self::Reconnecting(conn) => Some(conn),
            Self::Connecting => None,
        }
    }
}

fn mark_reconnecting<C>(connections: &mut ConnectionMap<C>, addr: NodeAddress) {
    connections
        .entry(addr.clone())
        .and_modify(|state| {
            *state = match std::mem::replace(state, ConnState::Connecting) {
                ConnState::Connected(conn) => {
                    warn!("ClusterConnInner: connection to {addr:?} lost; repairing in background");
                    ConnState::Reconnecting(conn)
                }
                other => other,
            };
        })
        .or_insert(ConnState::Connecting);
}

/// This is the internal representation of an async Redis Cluster connection. It stores the
/// underlying connections maintained for each node in the cluster, as well
/// as common parameters for connecting to nodes and executing commands.
struct InnerCore<C> {
    conn_lock: RwLock<(ConnectionMap<C>, SlotMap)>,
    cluster_params: ClusterParams,
    pending_requests_tx: mpsc::UnboundedSender<PendingRequest<C>>,
    initial_nodes: Vec<ConnectionInfo>,
    subscription_tracker: Option<Mutex<SubscriptionTracker>>,
    routing_strategy: Option<Box<dyn ReadRoutingStrategy>>,
    push_sender: UnboundedSender<(NodeAddress, PushInfo)>,
}

/// This is a clonable wrapper.
#[derive(Clone)]
struct Core<C>(Arc<InnerCore<C>>);

impl<C> Deref for Core<C> {
    type Target = InnerCore<C>;

    fn deref(&self) -> &InnerCore<C> {
        &self.0
    }
}

impl<C> Core<C>
where
    C: ConnectionLike + Connect + Clone + Send + Sync + 'static,
{
    async fn execute_on_multiple_nodes<'a>(
        &self,
        cmd: &'a Arc<Cmd>,
        routing: &'a MultipleNodeRoutingInfo,
        response_policy: Option<ResponsePolicy>,
    ) -> OperationResult {
        let read_guard = self.conn_lock.read().await;
        if read_guard.0.is_empty() {
            return (
                OperationTarget::FanOut,
                Result::Err(
                    (
                        ErrorKind::ClusterConnectionNotFound,
                        "No connections found for multi-node operation",
                    )
                        .into(),
                ),
            );
        }
        let (receivers, requests): (Vec<_>, Vec<_>) = {
            let to_request = |(addr, cmd): (&NodeAddress, Arc<Cmd>)| {
                read_guard
                    .0
                    .get(addr)
                    // For a fan-out, we do not want to silently return a partial response
                    // by skipping a shard because of a connection issue.
                    // We are intentionally using a connection under repair (Reconnecting state).
                    // It may or may not succeed. But the aggregate response will be honest.
                    .and_then(ConnState::connected_or_reconnecting)
                    .map(|conn| {
                        let (sender, receiver) = oneshot::channel();
                        let addr = addr.clone();
                        (
                            (addr.clone(), receiver),
                            PendingRequest {
                                retry: 0,
                                sender: request::ResultExpectation::External(sender),
                                cmd: CmdArg::Cmd {
                                    cmd,
                                    routing: InternalSingleNodeRouting::Connection {
                                        identifier: addr,
                                        conn,
                                    }
                                    .into(),
                                },
                            },
                        )
                    })
            };
            let slot_map = &read_guard.1;

            // TODO - these filter_map calls mean that we ignore nodes that are missing. Should we report an error in such cases?
            // since some of the operators drop other requests, mapping to errors here might mean that no request is sent.
            match routing {
                MultipleNodeRoutingInfo::AllNodes => slot_map
                    .addresses_for_all_nodes()
                    .into_iter()
                    .filter_map(|addr| to_request((addr, cmd.clone())))
                    .unzip(),
                MultipleNodeRoutingInfo::AllMasters => slot_map
                    .addresses_for_all_primaries()
                    .into_iter()
                    .filter_map(|addr| to_request((addr, cmd.clone())))
                    .unzip(),
                MultipleNodeRoutingInfo::MultiSlot((routes, _)) => slot_map
                    .addresses_for_multi_slot(routes, self.routing_strategy.as_deref())
                    .enumerate()
                    .filter_map(|(index, addr_opt)| {
                        addr_opt.and_then(|addr| {
                            let (_, indices) = routes.get(index).unwrap();
                            let cmd =
                                Arc::new(crate::cluster_routing::command_for_multi_slot_indices(
                                    cmd.as_ref(),
                                    indices.iter(),
                                ));
                            to_request((addr, cmd))
                        })
                    })
                    .unzip(),
            }
        };
        drop(read_guard);
        for request in requests {
            let _ = self.pending_requests_tx.send(request);
        }

        (
            OperationTarget::FanOut,
            Self::aggregate_results(receivers, routing, response_policy)
                .await
                .map(Response::Single),
        )
    }

    async fn aggregate_results(
        receivers: Vec<(NodeAddress, oneshot::Receiver<RedisResult<Response>>)>,
        routing: &MultipleNodeRoutingInfo,
        response_policy: Option<ResponsePolicy>,
    ) -> RedisResult<Value> {
        if receivers.is_empty() {
            return Err((
                ErrorKind::ClusterConnectionNotFound,
                "No nodes found for multi-node operation",
            )
                .into());
        }

        let extract_result = |response| match response {
            Response::Single(value) => value,
            Response::Multiple(_) => unreachable!(),
        };

        let convert_result = |res: Result<RedisResult<Response>, _>| {
            res.map_err(|_| RedisError::from((ErrorKind::Client, "request wasn't handled due to internal failure"))) // this happens only if the result sender is dropped before usage.
               .and_then(|res| res.map(extract_result))
        };

        let get_receiver = |(_, receiver): (_, oneshot::Receiver<RedisResult<Response>>)| async {
            convert_result(receiver.await)
        };

        match response_policy {
            Some(ResponsePolicy::AllSucceeded) => {
                future::try_join_all(receivers.into_iter().map(get_receiver))
                    .await
                    .and_then(|mut results| {
                        results.pop().ok_or_else(|| {
                            (
                                ErrorKind::ClusterConnectionNotFound,
                                "No results received for multi-node operation",
                            )
                                .into()
                        })
                    })
            }
            Some(ResponsePolicy::OneSucceeded) => future::select_ok(
                receivers
                    .into_iter()
                    .map(|tuple| Box::pin(get_receiver(tuple))),
            )
            .await
            .map(|(result, _)| result),
            Some(ResponsePolicy::FirstSucceededNonEmptyOrAllEmpty) => {
                // We want to see each response as it arrives, and:
                //  • If we see `Value::Nil`, increment a counter.
                //  • If we see `Value::ServerError`, remember it as `last_err`.
                //  • If we see `other_value`, return it immediately.
                //
                // Once the stream is exhausted:
                //  – if all successes were Nil → return Value::Nil (indicates that all shards are empty).
                //  – else → return the last error we saw (or a generic “all‐unavailable” error).
                //
                // If we received a mix of errors and `Nil`s, we can't determine if all shards are empty, thus we return the last received error instead of `Nil`.
                let mut nil_counter = 0;
                let mut last_err = None;
                let resolved = future::join_all(receivers.into_iter().map(get_receiver)).await;
                let num_results = resolved.len();

                for val in resolved {
                    match val {
                        Ok(Value::Nil) => nil_counter += 1,
                        Ok(Value::ServerError(err)) => {
                            last_err = Some(err.into());
                        }
                        Ok(val) => return Ok(val),
                        Err(err) => {
                            last_err = Some(err);
                        }
                    }
                }

                if nil_counter == num_results {
                    Ok(Value::Nil)
                } else {
                    Err(last_err.unwrap_or_else(|| {
                        (
                            ErrorKind::ClusterConnectionNotFound,
                            "Couldn't find any connection",
                        )
                            .into()
                    }))
                }
            }
            Some(ResponsePolicy::Aggregate(op)) => {
                future::try_join_all(receivers.into_iter().map(get_receiver))
                    .await
                    .and_then(|results| crate::cluster_routing::aggregate(results, op))
            }
            Some(ResponsePolicy::AggregateLogical(op)) => {
                future::try_join_all(receivers.into_iter().map(get_receiver))
                    .await
                    .and_then(|results| crate::cluster_routing::logical_aggregate(results, op))
            }
            Some(ResponsePolicy::CombineArrays) => {
                future::try_join_all(receivers.into_iter().map(get_receiver))
                    .await
                    .and_then(|results| match routing {
                        MultipleNodeRoutingInfo::MultiSlot((vec, pattern)) => {
                            crate::cluster_routing::combine_and_sort_array_results(
                                results, vec, pattern,
                            )
                        }
                        _ => crate::cluster_routing::combine_array_results(results),
                    })
            }
            Some(ResponsePolicy::CombineMaps) => {
                let resolved =
                    future::try_join_all(receivers.into_iter().map(get_receiver)).await?;
                crate::cluster_routing::combine_map_results(resolved)
            }
            Some(ResponsePolicy::Special) | None => {
                // This is our assumption - if there's no coherent way to aggregate the responses, we just map each response to the sender, and pass it to the user.
                let results =
                    future::join_all(receivers.into_iter().map(|(addr, receiver)| async move {
                        let result =
                            convert_result(receiver.await).or_else(|err| match err.try_into() {
                                Ok(server_error) => Ok(Value::ServerError(server_error)),
                                Err(err) => Err(err),
                            })?;
                        Ok::<_, RedisError>((
                            Value::BulkString(addr.to_string().into_bytes()),
                            result,
                        ))
                    }))
                    .await
                    .into_iter()
                    .collect::<Result<Vec<_>, _>>()?;
                Ok(Value::Map(results))
            }
        }
    }

    async fn try_cmd_request(
        &self,
        cmd: Arc<Cmd>,
        routing: InternalRoutingInfo<C>,
    ) -> OperationResult {
        let route = match routing {
            InternalRoutingInfo::SingleNode(single_node_routing) => single_node_routing,
            InternalRoutingInfo::MultiNode((multi_node_routing, response_policy)) => {
                return self
                    .execute_on_multiple_nodes(&cmd, &multi_node_routing, response_policy)
                    .await;
            }
        };

        match self.get_connection(route).await {
            Ok((addr, mut conn)) => (
                addr.into(),
                conn.req_packed_command(&cmd)
                    .await
                    .inspect(|res| {
                        if !matches!(res, Value::ServerError(_))
                            && let Some(tracker) = &self.subscription_tracker
                            && let Some((action, args)) =
                                SubscriptionTracker::to_request(cmd.as_ref())
                        {
                            let mut tracker = tracker.lock().unwrap();
                            tracker.update_with_request(action, args);
                        }
                    })
                    .map(Response::Single),
            ),
            Err(err) => (OperationTarget::NotFound, Err(err)),
        }
    }

    async fn try_pipeline_request(
        &self,
        pipeline: Arc<crate::Pipeline>,
        offset: usize,
        count: usize,
        route: InternalSingleNodeRouting<C>,
    ) -> OperationResult {
        match self.get_connection(route).await {
            Ok((addr, mut conn)) => (
                OperationTarget::Node { address: addr },
                conn.req_packed_commands(&pipeline, offset, count)
                    .await
                    .inspect(|res| {
                        let Some(tracker) = &self.subscription_tracker else {
                            return;
                        };
                        let res = if pipeline.is_transaction() {
                            debug_assert_eq!(res.len(), 1);
                            match res[0] {
                                Value::Array(ref arr) => arr,
                                _ => res,
                            }
                        } else {
                            res
                        };
                        let mut iterator = pipeline
                            .cmd_iter()
                            .enumerate()
                            .flat_map(|(index, cmd)| {
                                if matches!(res[index], Value::ServerError(_)) {
                                    None
                                } else {
                                    SubscriptionTracker::to_request(cmd)
                                }
                            })
                            .peekable();
                        if iterator.peek().is_some() {
                            let mut tracker = tracker.lock().unwrap();
                            for (action, args) in iterator {
                                tracker.update_with_request(action, args);
                            }
                        }
                    })
                    .map(Response::Multiple),
            ),
            Err(err) => (OperationTarget::NotFound, Err(err)),
        }
    }

    async fn try_request(self, cmd: CmdArg<C>) -> OperationResult {
        match cmd {
            CmdArg::Reconnect(addr) => (
                OperationTarget::Node { address: addr },
                // this is intended to make the caller trigger reconnection
                Err(RedisError::from((ErrorKind::Io, "connection dropped"))),
            ),
            CmdArg::Cmd { cmd, routing } => self.try_cmd_request(cmd, routing).await,
            CmdArg::Pipeline {
                pipeline,
                offset,
                count,
                route,
            } => {
                self.try_pipeline_request(pipeline, offset, count, route)
                    .await
            }
        }
    }

    async fn get_connection(
        &self,
        route: InternalSingleNodeRouting<C>,
    ) -> RedisResult<(NodeAddress, C)> {
        let route = match route {
            InternalSingleNodeRouting::Random => {
                let read_guard = self.conn_lock.read().await;
                return match get_random_connection(&read_guard.0) {
                    Some((addr, conn)) => Ok((addr, conn)),
                    None => {
                        Err((ErrorKind::ClusterConnectionNotFound, "No connections found").into())
                    }
                };
            }
            InternalSingleNodeRouting::SpecificNode(route) => route,
            InternalSingleNodeRouting::Connection { identifier, conn } => {
                return Ok((identifier, conn));
            }
            InternalSingleNodeRouting::Redirect { redirect, .. } => {
                // redirected requests shouldn't use a random connection, so they have a separate codepath.
                return self.get_redirected_connection(redirect).await;
            }
            InternalSingleNodeRouting::ByAddress(address) => {
                let read_guard = self.conn_lock.read().await;
                return match read_guard.0.get(&address).and_then(ConnState::connected) {
                    Some(conn) => Ok((address, conn)),
                    None => Err((
                        ErrorKind::ClusterConnectionNotFound,
                        "Requested connection not found",
                        address.to_string(),
                    )
                        .into()),
                };
            }
        };

        let read_guard = self.conn_lock.read().await;
        let preferred = read_guard
            .1
            .slot_addr_for_route(route, self.routing_strategy.as_deref())
            .cloned();

        if let Some(ref addr) = preferred
            && let Some(conn) = read_guard.0.get(addr).and_then(ConnState::connected)
        {
            return Ok((addr.clone(), conn));
        }

        // The preferred node is not connected (e.g. it is being repaired by the `reconnect_loop` future).
        // Instead of erroring or waiting we try a fallback (within the same shard).
        let fallback = read_guard
            .1
            .shard_fallback_addrs(route)
            .into_iter()
            .find_map(|candidate| {
                read_guard
                    .0
                    .get(&candidate)
                    .and_then(ConnState::connected)
                    .map(|conn| (candidate, conn))
            });
        drop(read_guard);
        if let Some(found) = fallback {
            return Ok(found);
        }

        let read_guard = self.conn_lock.read().await;
        if let Some((random_addr, random_conn)) = get_random_connection(&read_guard.0) {
            drop(read_guard);
            return Ok((random_addr, random_conn));
        }

        Err((ErrorKind::ClusterConnectionNotFound, "No connections found").into())
    }

    async fn get_redirected_connection(&self, redirect: Redirect) -> RedisResult<(NodeAddress, C)> {
        let asking = matches!(redirect, Redirect::Ask(_));
        let addr = match redirect {
            Redirect::Moved(addr) | Redirect::Ask(addr) => addr,
        };
        let read_guard = self.conn_lock.read().await;
        let conn = read_guard.0.get(&addr).and_then(ConnState::connected);
        drop(read_guard);
        let mut conn = match conn {
            Some(conn) => conn,
            None => self.connect_check_and_add(&addr).await?,
        };
        if asking {
            let mut asking_cmd = crate::cmd::cmd("ASKING");
            asking_cmd.skip_concurrency_limit = true;
            conn.req_packed_command(&asking_cmd)
                .await
                .and_then(|value| value.extract_error())?;
        }

        Ok((addr, conn))
    }

    async fn connect_check_and_add(&self, addr: &NodeAddress) -> RedisResult<C> {
        let conn = connect_and_check::<C>(addr, &self.cluster_params, &self.push_sender).await?;
        self.conn_lock
            .write()
            .await
            .0
            .insert(addr.clone(), ConnState::Connected(conn.clone()));
        Ok(conn)
    }

    async fn query_slots(conn: &mut C, addr: &NodeAddress, slots: &mut SlotMap) -> RedisResult<()> {
        let mut slot_refresh_cmd = slot_cmd();
        slot_refresh_cmd.skip_concurrency_limit = true;
        let value = conn
            .req_packed_command(&slot_refresh_cmd)
            .await
            .and_then(|value| value.extract_error())?;
        let v: Vec<SlotRange> = parse_slots(value, addr.host())?;
        build_slot_map(slots, v)
    }

    // Query a node to discover slot-> master mappings.
    async fn refresh_slots(self) -> RedisResult<()> {
        let mut write_guard = self.conn_lock.write().await;
        let (connections, slots) = &mut *write_guard;

        let mut found = false;
        let mut last_err = None;

        // First pass is to query previously-known good connections for the new slots.
        for (addr, state) in &mut *connections {
            let ConnState::Connected(conn) = state else {
                continue;
            };
            match Self::query_slots(conn, addr, slots).await {
                Ok(()) => {
                    found = true;
                    break;
                }
                Err(err) => last_err = Some(err),
            }
        }

        // Second pass is to attempt to repair connections on-demand as we iterate through each one.
        // We include Connected connections in this pass, in addition to the first pass above,
        // so that we can do inline connection repairs, if needed (via `get_or_create_conn`).
        if !found {
            for (addr, state) in &mut *connections {
                let prev = std::mem::replace(state, ConnState::Connecting).into_conn();
                match get_or_create_conn(addr, prev, &self.cluster_params, &self.push_sender).await
                {
                    Ok(mut conn) => {
                        let res = Self::query_slots(&mut conn, addr, slots).await;
                        *state = ConnState::Connected(conn);
                        match res {
                            Ok(()) => {
                                found = true;
                                break;
                            }
                            Err(err) => last_err = Some(err),
                        }
                    }
                    Err(err) => last_err = Some(err),
                }
            }
        }

        if !found {
            return Err(last_err.unwrap_or_else(|| {
                (ErrorKind::ClusterConnectionNotFound, "No connections found").into()
            }));
        }

        if let Some(ref strategy) = self.routing_strategy {
            strategy.on_topology_changed(slots.topology());
        }

        let nodes = slots.values().flatten().cloned().collect::<HashSet<_>>();

        connections.retain(|addr, _| nodes.contains(addr));

        self.refresh_connections_locked(connections, nodes).await;

        Ok(())
    }

    async fn refresh_connections_locked(
        &self,
        connections: &mut ConnectionMap<C>,
        nodes: HashSet<NodeAddress>,
    ) {
        let nodes_len = nodes.len();
        let addresses_and_connections_iter = nodes
            .into_iter()
            .map(|addr| {
                let connection = connections.remove(&addr).and_then(ConnState::into_conn);
                async move {
                    let res = get_or_create_conn(
                        &addr,
                        connection,
                        &self.cluster_params,
                        &self.push_sender,
                    )
                    .await;
                    (addr, res)
                }
            })
            .collect::<Vec<_>>();

        stream::iter(addresses_and_connections_iter)
            .buffer_unordered(nodes_len.max(8))
            .fold(connections, |connections, (addr, result)| async move {
                if let Ok(conn) = result {
                    connections.insert(addr, ConnState::Connected(conn));
                }
                connections
            })
            .await;
    }

    fn resubscribe_all(&self) {
        let Some(subscription_tracker) = self.subscription_tracker.as_ref() else {
            return;
        };

        let subscription_pipe = subscription_tracker
            .lock()
            .unwrap()
            .get_subscription_pipeline();

        // we send request per cmd, instead of sending the pipe together, in order to send each command to the relevant node, instead of all together to a single node.
        let requests = subscription_pipe.into_cmd_iter().map(|cmd| {
            let routing = RoutingInfo::for_routable(&cmd)
                .unwrap_or(RoutingInfo::SingleNode(SingleNodeRoutingInfo::Random))
                .into();
            PendingRequest {
                retry: 0,
                sender: request::ResultExpectation::Internal,
                cmd: CmdArg::Cmd {
                    cmd: Arc::new(cmd),
                    routing,
                },
            }
        });

        for request in requests {
            let _ = self
                .pending_requests_tx
                .send(request)
                .inspect_err(|err| debug!("failed internal send {err}"));
        }
    }

    fn resubscribe_node(&self, reconnected_addr: &NodeAddress) {
        let Some(subscription_tracker) = self.subscription_tracker.as_ref() else {
            return;
        };

        // Determine if there are other connected nodes
        let guard = self.conn_lock.try_read().ok();
        let other_nodes_connected = if let Some(guard) = &guard {
            guard.0.iter().any(|(addr, state)| {
                addr != reconnected_addr && matches!(state, ConnState::Connected(_))
            })
        } else {
            false
        };

        let subscription_pipe = subscription_tracker
            .lock()
            .unwrap()
            .get_subscription_pipeline();

        let requests = subscription_pipe.into_cmd_iter().filter_map(|cmd| {
            let routing = RoutingInfo::for_routable(&cmd)
                .unwrap_or(RoutingInfo::SingleNode(SingleNodeRoutingInfo::Random));

            match &routing {
                RoutingInfo::SingleNode(SingleNodeRoutingInfo::SpecificNode(route)) => {
                    // For specific node routing (like SSUBSCRIBE/shard pubsub),
                    // only send if it routes to the reconnected_addr.
                    let target_addr = guard.as_ref().and_then(|g| {
                        g.1.slot_addr_for_route(*route, self.routing_strategy.as_deref())
                    });
                    if target_addr != Some(reconnected_addr) {
                        return None;
                    }
                }
                // For random/any-node routing (like SUBSCRIBE/PSUBSCRIBE),
                // only send if this is the first connected node.
                _ if other_nodes_connected => {
                    return None;
                }
                _ => {}
            }

            Some(PendingRequest {
                retry: 0,
                sender: request::ResultExpectation::Internal,
                cmd: CmdArg::Cmd {
                    cmd: Arc::new(cmd),
                    routing: routing.into(),
                },
            })
        });

        for request in requests {
            let _ = self
                .pending_requests_tx
                .send(request)
                .inspect_err(|e| debug!("Failed internal send {e:?}"));
        }
    }
}

/// This is the sink for requests sent by the user.
/// It holds the stream of requests which are "in flight", E.G. on their way to the server,
/// and the inner representation of the connection.
struct ClusterConnInner<C> {
    inner: Core<C>,
    state: ConnectionState,
    #[allow(clippy::complexity)]
    in_flight_requests: stream::FuturesUnordered<Pin<Box<Request<C>>>>,
    reconnect_futures: stream::FuturesUnordered<BoxFuture<'static, NodeAddress>>,
    pending_requests_rx: mpsc::UnboundedReceiver<PendingRequest<C>>,
    refresh_error: Option<RedisError>,
}

// Keep trying to repair `addr` until it is re-connected, or the node
// has left the topology.
// This is a continuous attempt to reconnect rather than one-shot.
async fn reconnect_loop<C>(core: Core<C>, addr: NodeAddress) -> NodeAddress
where
    C: ConnectionLike + Connect + Clone + Send + Sync + 'static,
{
    {
        let mut guard = core.conn_lock.write().await;

        if matches!(
            guard.0.get(&addr),
            Some(ConnState::Reconnecting(_) | ConnState::Connecting)
        ) {
            return addr;
        }
        mark_reconnecting(&mut guard.0, addr.clone());
    }

    let mut backoff = Duration::from_millis(50);
    let mut attempts = 0;
    loop {
        attempts += 1;
        if core
            .cluster_params
            .max_connection_attempts
            .is_some_and(|max| max.get() < attempts)
        {
            core.conn_lock.write().await.0.remove(&addr);
            break;
        }
        let prev = {
            let guard = core.conn_lock.read().await;
            let in_topology = guard.1.addresses_for_all_nodes().contains(&addr);
            let entry = guard.0.get(&addr);
            if matches!(entry, Some(ConnState::Connected(_))) {
                break;
            }
            let prev_conn = entry.and_then(ConnState::connected_or_reconnecting);
            drop(guard);

            if !in_topology {
                core.conn_lock.write().await.0.remove(&addr);

                break;
            }
            prev_conn
        };

        match get_or_create_conn(&addr, prev, &core.cluster_params, &core.push_sender).await {
            Ok(conn) => {
                let newly_installed = {
                    let mut guard = core.conn_lock.write().await;

                    if matches!(guard.0.get(&addr), Some(ConnState::Connected(_))) {
                        false
                    } else {
                        guard.0.insert(addr.clone(), ConnState::Connected(conn));
                        true
                    }
                };

                if newly_installed {
                    info!("ClusterConnInner: reconnected to {addr:?} ");
                    // TODO: make the resubscribe semantic more granular.
                    // Right now resubscribe() re-sends every subscription across all nodes.
                    // We should re-subscribe for the newly repaired node.
                    core.resubscribe_node(&addr);
                }
                break;
            }
            Err(err) => {
                debug!("repair_node: failed to reconnect {addr:?}: {err:?}");
            }
        }

        boxed_sleep(backoff).await;
        backoff = (backoff * 2).min(Duration::from_secs(1));
    }
    addr
}

fn boxed_sleep(duration: Duration) -> BoxFuture<'static, ()> {
    Box::pin(Runtime::locate_and_sleep(duration))
}

#[derive(Debug, PartialEq)]
pub(crate) enum Response {
    Single(Value),
    Multiple(Vec<Value>),
}

#[derive(Debug)]
enum OperationTarget {
    Node { address: NodeAddress },
    NotFound,
    FanOut,
}
type OperationResult = (OperationTarget, Result<Response, RedisError>);

impl From<NodeAddress> for OperationTarget {
    fn from(address: NodeAddress) -> Self {
        Self::Node { address }
    }
}

struct Message<C> {
    cmd: CmdArg<C>,
    sender: ResultExpectation,
}

enum RecoverFuture {
    RecoverSlots(BoxFuture<'static, RedisResult<()>>),
    ReconnectInitial(BoxFuture<'static, RedisResult<()>>),
}

enum ConnectionState {
    PollComplete,
    Recover(RecoverFuture),
}

impl fmt::Debug for ConnectionState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{}",
            match self {
                Self::PollComplete => "PollComplete",
                Self::Recover(_) => "Recover",
            }
        )
    }
}

fn build_slot_map(slot_map: &mut SlotMap, slots_data: Vec<SlotRange>) -> RedisResult<()> {
    slot_map.clear();
    slot_map.fill_slots(slots_data);
    trace!("{slot_map:?}");
    Ok(())
}

impl<C> ClusterConnInner<C>
where
    C: ConnectionLike + Connect + Clone + Send + Sync + 'static,
{
    fn new(
        initial_nodes: &[ConnectionInfo],
        cluster_params: ClusterParams,
        push_sender: UnboundedSender<(NodeAddress, PushInfo)>,
        has_push_sender: bool,
    ) -> Self {
        let subscription_tracker =
            has_push_sender.then(|| Mutex::new(SubscriptionTracker::default()));

        let routing_strategy = cluster_params
            .read_routing_factory
            .as_ref()
            .map(|f| f.create_strategy());

        let (pending_requests_tx, pending_requests_rx) = mpsc::unbounded_channel();
        let inner = Arc::new(InnerCore {
            conn_lock: RwLock::new((Default::default(), SlotMap::new())),
            cluster_params,
            pending_requests_tx,
            initial_nodes: initial_nodes.to_vec(),
            subscription_tracker,
            routing_strategy,
            push_sender,
        });
        let core = Core(inner);
        let mut inner = Self {
            inner: core,
            in_flight_requests: Default::default(),
            reconnect_futures: Default::default(),
            pending_requests_rx,
            refresh_error: None,
            state: ConnectionState::PollComplete,
        };
        inner.state = ConnectionState::Recover(RecoverFuture::ReconnectInitial(Box::pin(
            inner.reconnect_to_initial_nodes(),
        )));
        inner
    }

    async fn create_initial_connections(
        initial_nodes: &[ConnectionInfo],
        params: &ClusterParams,
        push_sender: &UnboundedSender<(NodeAddress, PushInfo)>,
    ) -> RedisResult<ConnectionMap<C>> {
        let (connections, error) = stream::iter(initial_nodes.iter().cloned())
            .map(async move |info| {
                let addr = NodeAddress::try_from(&info.addr)?;
                let result = connect_and_check(&addr, params, push_sender).await;
                match result {
                    Ok(conn) => Ok((addr, conn)),
                    Err(e) => {
                        debug!("Failed to connect to initial node: {e:?}");
                        Err(e)
                    }
                }
            })
            .buffer_unordered(initial_nodes.len())
            .fold(
                (ConnectionMap::<C>::with_capacity(initial_nodes.len()), None),
                |(mut connections, mut error), result| async move {
                    match result {
                        Ok((addr, conn)) => {
                            connections.insert(addr, ConnState::Connected(conn));
                        }
                        Err(err) => {
                            // Store at least one error to use as detail in the connection error if
                            // all connections fail.
                            error = Some(err);
                        }
                    }
                    (connections, error)
                },
            )
            .await;
        if connections.is_empty() {
            if let Some(err) = error {
                return Err(RedisError::from((
                    ErrorKind::Io,
                    "Failed to create initial connections",
                    err.to_string(),
                )));
            } else {
                return Err(RedisError::from((
                    ErrorKind::Io,
                    "Failed to create initial connections",
                )));
            }
        }
        Ok(connections)
    }

    fn reconnect_to_initial_nodes(&mut self) -> impl Future<Output = RedisResult<()>> + use<C> {
        debug!("Received request to reconnect to initial nodes");
        let inner = self.inner.clone();
        async move {
            let connection_map = Self::create_initial_connections(
                &inner.initial_nodes,
                &inner.cluster_params,
                &inner.push_sender,
            )
            .await?;
            *inner.conn_lock.write().await = (connection_map, SlotMap::new());
            inner.refresh_slots().await?;
            Ok(())
        }
    }

    // Create reconnecting futures and register them into `reconnect_futures`
    // so we can poll them at the next poll_flush iteration.
    fn register_reconnect_futures(&mut self, addrs: HashSet<NodeAddress>) {
        // This is best-effort, non-blocking, opportunistic check to see
        // if there is already a repair in progress.
        // This is not load-bearing since the real dedupe logic lives inside reconnect_loop.
        let opportunistic_read_guard = self.inner.conn_lock.try_read().ok();
        for addr in addrs {
            if let Some(guard) = &opportunistic_read_guard
                && matches!(
                    guard.0.get(&addr),
                    Some(ConnState::Reconnecting(_) | ConnState::Connecting)
                )
            {
                continue;
            }
            self.reconnect_futures
                .push(Box::pin(reconnect_loop(self.inner.clone(), addr)));
        }
    }

    fn poll_reconnects(&mut self, cx: &mut task::Context<'_>) {
        while let Poll::Ready(Some(_)) = Pin::new(&mut self.reconnect_futures).poll_next(cx) {}
    }

    async fn wait_for_initial_connection(&mut self) -> RedisResult<()> {
        if let ConnectionState::Recover(fut) =
            std::mem::replace(&mut self.state, ConnectionState::PollComplete)
        {
            match fut {
                RecoverFuture::RecoverSlots(fut) | RecoverFuture::ReconnectInitial(fut) => {
                    fut.await?;
                }
            }
        }
        Ok(())
    }

    fn poll_recover(&mut self, cx: &mut task::Context<'_>) -> Poll<Result<(), RedisError>> {
        let recover_future = match &mut self.state {
            ConnectionState::PollComplete => return Poll::Ready(Ok(())),
            ConnectionState::Recover(future) => future,
        };
        let res = match recover_future {
            RecoverFuture::RecoverSlots(future) => match ready!(future.as_mut().poll(cx)) {
                Ok(_) => {
                    info!("async cluster client recovery: slot refresh complete");
                    self.state = ConnectionState::PollComplete;
                    Ok(())
                }
                Err(err) => {
                    error!("async cluster client recovery: slot refresh failed: `{err}`");
                    *future = Box::pin(self.inner.clone().refresh_slots());
                    Err(err)
                }
            },
            RecoverFuture::ReconnectInitial(future) => {
                match ready!(future.as_mut().poll(cx)) {
                    Ok(()) => {
                        info!("async cluster client recovery: reconnect to initial nodes complete");
                    }
                    Err(err) => {
                        error!(
                            "async cluster client recovery: reconnect to initial nodes failed: `{err}`"
                        );
                    }
                }
                self.state = ConnectionState::PollComplete;
                Ok(())
            }
        };
        if res.is_ok() {
            self.inner.resubscribe_all();
        }
        Poll::Ready(res)
    }

    fn handle_retries(&mut self, request_handling: Option<Retry<C>>) {
        match request_handling {
            Some(Retry::MoveToPending { request }) => {
                let _ = self.inner.pending_requests_tx.send(request);
            }
            Some(Retry::Immediately { request }) => {
                let future = self.inner.clone().try_request(request.cmd.clone());
                self.in_flight_requests.push(Box::pin(Request {
                    retry_params: self.inner.cluster_params.retry_params.clone(),
                    request: Some(request),
                    future: RequestState::Future {
                        future: Box::pin(future),
                    },
                }));
            }
            Some(Retry::AfterSleep {
                request,
                sleep_duration,
            }) => {
                let future = RequestState::Sleep {
                    sleep: boxed_sleep(sleep_duration),
                };
                self.in_flight_requests.push(Box::pin(Request {
                    retry_params: self.inner.cluster_params.retry_params.clone(),
                    request: Some(request),
                    future,
                }));
            }
            None => {}
        }
    }

    fn dispatch_pending(&mut self) {
        loop {
            let request = match self.pending_requests_rx.try_recv() {
                Ok(request) => request,
                Err(tokio::sync::mpsc::error::TryRecvError::Empty)
                | Err(tokio::sync::mpsc::error::TryRecvError::Disconnected) => break,
            };

            // Drop the request if no-one is waiting for a response to free up resources for
            // requests callers care about (load shedding). It will be ambiguous whether the
            // request actually goes through regardless.
            if request.sender.is_closed() {
                continue;
            }

            let future = self.inner.clone().try_request(request.cmd.clone()).boxed();
            self.in_flight_requests.push(Box::pin(Request {
                retry_params: self.inner.cluster_params.retry_params.clone(),
                request: Some(request),
                future: RequestState::Future { future },
            }));
        }
    }

    fn poll_in_flight(&mut self, cx: &mut task::Context<'_>) -> Poll<PollFlushAction> {
        let mut poll_flush_action = PollFlushAction::None;

        loop {
            let (request_handling, next) =
                match Pin::new(&mut self.in_flight_requests).poll_next(cx) {
                    Poll::Ready(Some(result)) => result,
                    Poll::Ready(None) | Poll::Pending => break,
                };

            self.handle_retries(request_handling);
            poll_flush_action = poll_flush_action.change_state(next);
        }

        if !matches!(poll_flush_action, PollFlushAction::None) || self.in_flight_requests.is_empty()
        {
            Poll::Ready(poll_flush_action)
        } else {
            Poll::Pending
        }
    }

    fn poll_complete(&mut self, cx: &mut task::Context<'_>) -> Poll<PollFlushAction> {
        self.dispatch_pending();
        self.poll_in_flight(cx)
    }

    fn send_refresh_error(&mut self) {
        let Some(refresh_error) = self.refresh_error.take() else {
            return;
        };

        let mut inflight_requests = Vec::new();
        for mut request in Pin::new(&mut self.in_flight_requests).iter_pin_mut() {
            let mut request = request.as_mut();
            let Some(pending_request) = request.request.take() else {
                continue;
            };

            inflight_requests.push((pending_request, std::mem::take(&mut request.retry_params)));
        }
        if inflight_requests.is_empty() {
            // Use a separate binding for this to release the lock guard before calling send.
            let maybe_request = self.pending_requests_rx.try_recv().ok();
            if let Some(request) = maybe_request {
                inflight_requests.push((request, self.inner.cluster_params.retry_params.clone()));
            }
        }
        for (pending_request, retry_params) in inflight_requests {
            self.handle_retries(
                request::choose_response(
                    (OperationTarget::NotFound, Err(refresh_error.clone())),
                    pending_request,
                    &retry_params,
                )
                .0,
            );
        }
    }
}

async fn get_or_create_conn<C>(
    addr: &NodeAddress,
    conn_option: Option<C>,
    params: &ClusterParams,
    push_sender: &UnboundedSender<(NodeAddress, PushInfo)>,
) -> RedisResult<C>
where
    C: Connect + ConnectionLike + Clone + Send + Sync + 'static,
{
    if let Some(mut conn) = conn_option
        && check_connection(&mut conn).await.is_ok()
    {
        Ok(conn)
    } else {
        connect_and_check(addr, params, push_sender).await
    }
}

#[derive(Debug, PartialEq)]
enum PollFlushAction {
    None,
    RebuildSlots,
    Reconnect(HashSet<NodeAddress>),
    ReconnectFromInitialConnections,
}

impl PollFlushAction {
    fn change_state(self, next_state: Self) -> Self {
        match (self, next_state) {
            (Self::None, next_state) | (next_state, Self::None) => next_state,
            (Self::ReconnectFromInitialConnections, _)
            | (_, Self::ReconnectFromInitialConnections) => Self::ReconnectFromInitialConnections,

            (Self::RebuildSlots, _) | (_, Self::RebuildSlots) => Self::RebuildSlots,

            (Self::Reconnect(mut addrs), Self::Reconnect(new_addrs)) => {
                addrs.extend(new_addrs);
                Self::Reconnect(addrs)
            }
        }
    }
}

impl<C> Sink<Message<C>> for ClusterConnInner<C>
where
    C: ConnectionLike + Connect + Clone + Send + Sync + Unpin + 'static,
{
    type Error = ();

    fn poll_ready(self: Pin<&mut Self>, _cx: &mut task::Context) -> Poll<Result<(), Self::Error>> {
        Poll::Ready(Ok(()))
    }

    fn start_send(self: Pin<&mut Self>, item: Message<C>) -> Result<(), Self::Error> {
        trace!("start_send");
        let Message { cmd, sender } = item;

        let _ = self.inner.pending_requests_tx.send(PendingRequest {
            retry: 0,
            sender,
            cmd,
        });
        Ok(())
    }

    fn poll_flush(
        mut self: Pin<&mut Self>,
        cx: &mut task::Context,
    ) -> Poll<Result<(), Self::Error>> {
        trace!("poll_flush: {:?}", self.state);
        loop {
            self.send_refresh_error();
            self.poll_reconnects(cx);

            if let Err(err) = ready!(self.as_mut().poll_recover(cx)) {
                self.refresh_error = Some(err);

                // Give other tasks a chance to progress before we try to recover
                // again. Since the future may not have registered a wake up we do so
                // now so the task is not forgotten
                cx.waker().wake_by_ref();
                return Poll::Pending;
            }

            match ready!(self.poll_complete(cx)) {
                PollFlushAction::None => return Poll::Ready(Ok(())),
                PollFlushAction::RebuildSlots => {
                    warn!("async cluster client recovery: beginning slot refresh");
                    self.state = ConnectionState::Recover(RecoverFuture::RecoverSlots(Box::pin(
                        self.inner.clone().refresh_slots(),
                    )));
                }
                PollFlushAction::Reconnect(addrs) => {
                    self.register_reconnect_futures(addrs);
                }
                PollFlushAction::ReconnectFromInitialConnections => {
                    warn!("async cluster client recovery: beginning reconnect to initial nodes");
                    self.state = ConnectionState::Recover(RecoverFuture::ReconnectInitial(
                        Box::pin(self.reconnect_to_initial_nodes()),
                    ));
                }
            }
        }
    }

    fn poll_close(
        mut self: Pin<&mut Self>,
        cx: &mut task::Context,
    ) -> Poll<Result<(), Self::Error>> {
        // Try to drive any in flight requests to completion
        match self.poll_complete(cx) {
            Poll::Ready(PollFlushAction::None) | Poll::Pending => (),
            Poll::Ready(_) => Err(())?,
        }
        // If we no longer have any requests in flight we are done (skips any reconnection
        // attempts)
        if self.in_flight_requests.is_empty() {
            return Poll::Ready(Ok(()));
        }

        self.poll_flush(cx)
    }
}

impl<C> ConnectionLike for ClusterConnection<C>
where
    C: ConnectionLike + Send + Clone + Unpin + Sync + Connect + 'static,
{
    fn req_packed_command<'a>(&'a mut self, cmd: &'a Cmd) -> RedisFuture<'a, Value> {
        let routing = RoutingInfo::for_routable(cmd)
            .unwrap_or(RoutingInfo::SingleNode(SingleNodeRoutingInfo::Random));
        self.route_command(cmd.clone(), routing).boxed()
    }

    fn req_packed_commands<'a>(
        &'a mut self,
        pipeline: &'a crate::Pipeline,
        offset: usize,
        count: usize,
    ) -> RedisFuture<'a, Vec<Value>> {
        async move {
            let route = route_for_pipeline(pipeline)?;
            self.route_pipeline(pipeline.clone(), offset, count, route.into())
                .await
        }
        .boxed()
    }

    fn get_db(&self) -> i64 {
        0
    }
}
/// Implements the process of connecting to a Redis server
/// and obtaining a connection handle.
pub trait Connect: Sized {
    /// Connect to a node, returning handle for command execution.
    fn connect_with_config<'a, T>(info: T, config: AsyncConnectionConfig) -> RedisFuture<'a, Self>
    where
        T: IntoConnectionInfo + Send + 'a;
}

impl Connect for MultiplexedConnection {
    fn connect_with_config<'a, T>(info: T, config: AsyncConnectionConfig) -> RedisFuture<'a, Self>
    where
        T: IntoConnectionInfo + Send + 'a,
    {
        async move {
            let connection_info = info.into_connection_info()?;
            let client = crate::Client::open(connection_info)?;
            client
                .get_multiplexed_async_connection_with_config(&config)
                .await
        }
        .boxed()
    }
}

async fn connect_and_check<C>(
    node: &NodeAddress,
    params: &ClusterParams,
    push_sender: &UnboundedSender<(NodeAddress, PushInfo)>,
) -> RedisResult<C>
where
    C: ConnectionLike + Connect + Send + 'static,
{
    let info = get_connection_info(node, params);
    let mut config =
        AsyncConnectionConfig::default().set_connection_timeout(Some(params.connection_timeout));
    config = config.set_response_timeout(params.response_timeout);

    if info.redis.protocol.supports_resp3() {
        config =
            config.set_push_sender(AddressedPushSender::new(node.clone(), push_sender.clone()));
    }
    if let Some(resolver) = &params.async_dns_resolver {
        config = config.set_dns_resolver_internal(resolver.clone());
    }
    #[cfg(feature = "cache-aio")]
    if let Some(cache_manager) = &params.cache_manager {
        config = config.set_cache_manager(cache_manager.clone_and_increase_epoch());
    }
    #[cfg(feature = "token-based-authentication")]
    if let Some(credentials_provider) = &params.credentials_provider {
        config = config.set_credentials_provider_internal(credentials_provider.clone());
    }
    if let Some(limit) = params.connection_concurrency_limit {
        config = config.set_concurrency_limit(limit);
    }
    if let Some(boundary) = params.write_backpressure_boundary {
        config = config.set_write_backpressure_boundary(boundary);
    }
    let mut conn = match C::connect_with_config(info, config).await {
        Ok(conn) => conn,
        Err(err) => {
            warn!("Failed to connect to node: {node:?}, due to: {err:?}");
            return Err(err);
        }
    };
    // If READONLY is sent to primary nodes, it will have no effect.
    // We set this unconditionally, because we don't know whether we'll be making read calls
    // to replicas. (We allow overriding routing per-call)
    let mut readonly_cmd = cmd("READONLY");
    readonly_cmd.skip_concurrency_limit = true;
    conn.req_packed_command(&readonly_cmd).await?;
    Ok(conn)
}

async fn check_connection<C>(conn: &mut C) -> RedisResult<()>
where
    C: ConnectionLike + Send + 'static,
{
    let mut ping_cmd = cmd("PING");
    ping_cmd.skip_concurrency_limit = true;
    conn.req_packed_command(&ping_cmd)
        .await
        .and_then(|v| v.extract_error())?;
    Ok(())
}

fn get_random_connection<C>(connections: &ConnectionMap<C>) -> Option<(NodeAddress, C)>
where
    C: Clone,
{
    connections
        .iter()
        .filter_map(|(addr, state)| state.connected().map(|conn| (addr.clone(), conn)))
        .choose(&mut rng())
}
