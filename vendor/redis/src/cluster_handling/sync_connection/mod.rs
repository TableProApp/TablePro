//! This module extends the library to support Redis Cluster.
//!
//! The cluster connection is meant to abstract the fact that a cluster is composed of multiple nodes,
//! and to provide an API which is as close as possible to that of a single node connection. In order to do that,
//! the cluster connection maintains connections to each node in the Redis/ Valkey cluster, and can route
//! requests automatically to the relevant nodes. In cases that the cluster connection receives indications
//! that the cluster topology has changed, it will query nodes in order to find the current cluster topology.
//! If it disconnects from some nodes, it will automatically reconnect to those nodes.
//!
//! Note that pubsub & push sending functionality is not currently provided by this module.
//!
//! # Example
//! ```rust,no_run
//! use redis::TypedCommands;
//! use redis::cluster::ClusterClient;
//!
//! let nodes = vec!["redis://127.0.0.1:6379/", "redis://127.0.0.1:6378/", "redis://127.0.0.1:6377/"];
//! let client = ClusterClient::new(nodes).unwrap();
//! let mut connection = client.get_connection().unwrap();
//!
//! connection.set("test", "test_data").unwrap();
//! let rv = connection.get("test").unwrap().unwrap();
//!
//! assert_eq!(rv.as_str(), "test_data");
//! ```
//!
//! # Pipelining
//! ```rust,no_run
//! use redis::TypedCommands;
//! use redis::cluster::{cluster_pipe, ClusterClient};
//!
//! let nodes = vec!["redis://127.0.0.1:6379/", "redis://127.0.0.1:6378/", "redis://127.0.0.1:6377/"];
//! let client = ClusterClient::new(nodes).unwrap();
//! let mut connection = client.get_connection().unwrap();
//!
//! let key = "test";
//!
//! cluster_pipe()
//!     .rpush(key, "123").ignore()
//!     .ltrim(key, -10, -1).ignore()
//!     .expire(key, 60).ignore()
//!     .exec(&mut connection).unwrap();
//! ```
//!
//! # Sending request to specific node
//! In some cases you'd want to send a request to a specific node in the cluster, instead of
//! letting the cluster connection decide by itself to which node it should send the request.
//! This can happen, for example, if you want to send SCAN commands to each node in the cluster.
//!
//! ```rust,no_run
//! use redis::Commands;
//! use redis::cluster::ClusterClient;
//! use redis::cluster_routing::{ RoutingInfo, SingleNodeRoutingInfo };
//!
//! let nodes = vec!["redis://127.0.0.1:6379/", "redis://127.0.0.1:6378/", "redis://127.0.0.1:6377/"];
//! let client = ClusterClient::new(nodes).unwrap();
//! let mut connection = client.get_connection().unwrap();
//!
//! let routing_info = RoutingInfo::SingleNode(SingleNodeRoutingInfo::ByAddress{
//!     host: "redis://127.0.0.1".to_string(),
//!     port: 6378
//! });
//! let _: redis::Value = connection.route_command(&redis::cmd("PING"), routing_info).unwrap();
//! ```
use std::cell::RefCell;
use std::collections::HashSet;
use std::thread;
use std::time::Duration;

mod pipeline;

pub use super::NodeAddress;
pub use super::client::{ClusterClient, ClusterClientBuilder};
use super::topology::parse_slots;
use super::{
    client::ClusterParams,
    read_routing::ReadRoutingStrategy,
    routing::{Redirect, Route, RoutingInfo},
    slot_map::SlotMap,
};
use crate::IntoConnectionInfo;
pub use crate::TlsMode; // Pub for backwards compatibility
use crate::cluster_handling::{get_connection_info, slot_cmd};
use crate::cluster_routing::{
    MultipleNodeRoutingInfo, ResponsePolicy, Routable, SingleNodeRoutingInfo, Slot, SlotAddr,
};
use crate::cmd::{Cmd, cmd};
use crate::connection::{Connection, ConnectionInfo, ConnectionLike, connect};
use crate::errors::{ErrorKind, RedisError, RetryMethod};
use crate::parser::parse_redis_value;
use crate::types::{HashMap, RedisResult, Value};
use pipeline::UNROUTABLE_ERROR;
use rand::{rng, seq::IteratorRandom};

pub use pipeline::{ClusterPipeline, cluster_pipe};

#[derive(Clone)]
enum Input<'a> {
    Slice {
        cmd: &'a [u8],
        routable: Value,
    },
    Cmd(&'a Cmd),
    Commands {
        cmd: &'a [u8],
        offset: usize,
        count: usize,
    },
}

impl<'a> Input<'a> {
    fn send(&'a self, connection: &mut impl ConnectionLike) -> RedisResult<Output> {
        match self {
            Input::Slice { cmd, routable: _ } => connection
                .req_packed_command(cmd)
                .and_then(|value| value.extract_error())
                .map(Output::Single),
            Input::Cmd(cmd) => connection
                .req_command(cmd)
                .and_then(|value| value.extract_error())
                .map(Output::Single),
            Input::Commands { cmd, offset, count } => connection
                .req_packed_commands(cmd, *offset, *count)
                .and_then(Value::extract_error_vec)
                .map(Output::Multi),
        }
    }
}

impl Routable for Input<'_> {
    fn arg_idx(&self, idx: usize) -> Option<&[u8]> {
        match self {
            Input::Slice { cmd: _, routable } => routable.arg_idx(idx),
            Input::Cmd(cmd) => cmd.arg_idx(idx),
            Input::Commands { .. } => None,
        }
    }

    fn position(&self, candidate: &[u8]) -> Option<usize> {
        match self {
            Input::Slice { cmd: _, routable } => routable.position(candidate),
            Input::Cmd(cmd) => cmd.position(candidate),
            Input::Commands { .. } => None,
        }
    }
}

enum Output {
    Single(Value),
    Multi(Vec<Value>),
}

impl From<Output> for Value {
    fn from(value: Output) -> Self {
        match value {
            Output::Single(value) => value,
            Output::Multi(values) => Self::Array(values),
        }
    }
}

impl From<Output> for Vec<Value> {
    fn from(value: Output) -> Self {
        match value {
            Output::Single(value) => vec![value],
            Output::Multi(values) => values,
        }
    }
}

/// Implements the process of connecting to a Redis server
/// and obtaining and configuring a connection handle.
pub trait Connect: Sized {
    /// Connect to a node, returning handle for command execution.
    fn connect<T>(info: T, timeout: Option<Duration>) -> RedisResult<Self>
    where
        T: IntoConnectionInfo;

    /// Sends an already encoded (packed) command into the TCP socket and
    /// does not read a response.  This is useful for commands like
    /// `MONITOR` which yield multiple items.  This needs to be used with
    /// care because it changes the state of the connection.
    fn send_packed_command(&mut self, cmd: &[u8]) -> RedisResult<()>;

    /// Sets the write timeout for the connection.
    ///
    /// If the provided value is `None`, then `send_packed_command` call will
    /// block indefinitely. It is an error to pass the zero `Duration` to this
    /// method.
    fn set_write_timeout(&self, dur: Option<Duration>) -> RedisResult<()>;

    /// Sets the read timeout for the connection.
    ///
    /// If the provided value is `None`, then `recv_response` call will
    /// block indefinitely. It is an error to pass the zero `Duration` to this
    /// method.
    fn set_read_timeout(&self, dur: Option<Duration>) -> RedisResult<()>;

    /// Fetches a single response from the connection.  This is useful
    /// if used in combination with `send_packed_command`.
    fn recv_response(&mut self) -> RedisResult<Value>;
}

impl Connect for Connection {
    fn connect<T>(info: T, timeout: Option<Duration>) -> RedisResult<Self>
    where
        T: IntoConnectionInfo,
    {
        connect(&info.into_connection_info()?, timeout)
    }

    fn send_packed_command(&mut self, cmd: &[u8]) -> RedisResult<()> {
        Self::send_packed_command(self, cmd)
    }

    fn set_write_timeout(&self, dur: Option<Duration>) -> RedisResult<()> {
        Self::set_write_timeout(self, dur)
    }

    fn set_read_timeout(&self, dur: Option<Duration>) -> RedisResult<()> {
        Self::set_read_timeout(self, dur)
    }

    fn recv_response(&mut self) -> RedisResult<Value> {
        Self::recv_response(self)
    }
}

/// Options for creation of connection
#[derive(Clone, Default)]
pub struct ClusterConfig {
    pub(crate) connection_timeout: Option<Duration>,
    pub(crate) response_timeout: Option<Duration>,
    #[cfg(feature = "cluster-async")]
    pub(crate) async_push_sender: Option<std::sync::Arc<dyn crate::aio::AsyncPushSender>>,
    #[cfg(feature = "cluster-async")]
    pub(crate) async_dns_resolver: Option<std::sync::Arc<dyn crate::io::AsyncDNSResolver>>,
}

impl ClusterConfig {
    /// Creates a new instance of the options with nothing set
    pub fn new() -> Self {
        Self::default()
    }

    /// Sets the connection timeout
    pub fn set_connection_timeout(mut self, connection_timeout: std::time::Duration) -> Self {
        self.connection_timeout = Some(connection_timeout);
        self
    }

    /// Sets the response timeout
    pub fn set_response_timeout(mut self, response_timeout: std::time::Duration) -> Self {
        self.response_timeout = Some(response_timeout);
        self
    }

    #[cfg(feature = "cluster-async")]
    /// Sets a sender to receive pushed values.
    ///
    /// The sender can be a channel, or an arbitrary function that handles [crate::PushInfo] values.
    /// This will fail client creation if the connection isn't configured for RESP3 communications via the [crate::RedisConnectionInfo::set_protocol] function.
    ///
    /// # Examples
    ///
    /// ```rust
    /// # use redis::cluster::ClusterConfig;
    /// let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    /// let config = ClusterConfig::new().set_push_sender(tx);
    /// ```
    ///
    /// ```rust
    /// # use std::sync::{Mutex, Arc};
    /// # use redis::cluster::ClusterConfig;
    /// let messages = Arc::new(Mutex::new(Vec::new()));
    /// let config = ClusterConfig::new().set_push_sender(move |msg|{
    ///     let Ok(mut messages) = messages.lock() else {
    ///         return Err(redis::aio::SendError);
    ///     };
    ///     messages.push(msg);
    ///     Ok(())
    /// });
    pub fn set_push_sender(mut self, sender: impl crate::aio::AsyncPushSender) -> Self {
        self.async_push_sender = Some(std::sync::Arc::new(sender));
        self
    }

    /// Set asynchronous DNS resolver for the underlying TCP connection.
    ///
    /// The parameter resolver must implement the [`crate::io::AsyncDNSResolver`] trait.
    #[cfg(feature = "cluster-async")]
    pub fn set_dns_resolver(mut self, resolver: impl crate::io::AsyncDNSResolver) -> Self {
        self.async_dns_resolver = Some(std::sync::Arc::new(resolver));
        self
    }
}

/// This represents a Redis Cluster connection.
///
/// It stores the underlying connections maintained for each node in the cluster,
/// as well as common parameters for connecting to nodes and executing commands.
pub struct ClusterConnection<C = Connection> {
    initial_nodes: Vec<ConnectionInfo>,
    connections: RefCell<HashMap<NodeAddress, C>>,
    slots: RefCell<SlotMap>,
    auto_reconnect: RefCell<bool>,
    read_timeout: RefCell<Option<Duration>>,
    write_timeout: RefCell<Option<Duration>>,
    routing_strategy: Option<Box<dyn ReadRoutingStrategy>>,
    cluster_params: ClusterParams,
}

impl<C> ClusterConnection<C>
where
    C: ConnectionLike + Connect,
{
    pub(crate) fn new(
        cluster_params: ClusterParams,
        initial_nodes: Vec<ConnectionInfo>,
    ) -> RedisResult<Self> {
        let routing_strategy = cluster_params
            .read_routing_factory
            .as_ref()
            .map(|f| f.create_strategy());

        let connection = Self {
            connections: RefCell::new(HashMap::new()),
            slots: RefCell::new(SlotMap::new()),
            auto_reconnect: RefCell::new(true),
            read_timeout: RefCell::new(cluster_params.response_timeout),
            write_timeout: RefCell::new(None),
            routing_strategy,
            initial_nodes: initial_nodes.to_vec(),
            cluster_params,
        };
        connection.create_initial_connections()?;

        Ok(connection)
    }

    /// Set an auto reconnect attribute.
    /// Default value is true;
    pub fn set_auto_reconnect(&self, value: bool) {
        let mut auto_reconnect = self.auto_reconnect.borrow_mut();
        *auto_reconnect = value;
    }

    /// Sets the write timeout for the connection.
    ///
    /// If the provided value is `None`, then `send_packed_command` call will
    /// block indefinitely. It is an error to pass the zero `Duration` to this
    /// method.
    pub fn set_write_timeout(&self, dur: Option<Duration>) -> RedisResult<()> {
        // Check if duration is valid before updating local value.
        if dur.is_some() && dur.unwrap().is_zero() {
            return Err(RedisError::from((
                ErrorKind::InvalidClientConfig,
                "Duration should be None or non-zero.",
            )));
        }

        let mut t = self.write_timeout.borrow_mut();
        *t = dur;
        let connections = self.connections.borrow();
        for conn in connections.values() {
            conn.set_write_timeout(dur)?;
        }
        Ok(())
    }

    /// Sets the read timeout for the connection.
    ///
    /// If the provided value is `None`, then `recv_response` call will
    /// block indefinitely. It is an error to pass the zero `Duration` to this
    /// method.
    pub fn set_read_timeout(&self, dur: Option<Duration>) -> RedisResult<()> {
        // Check if duration is valid before updating local value.
        if dur.is_some() && dur.unwrap().is_zero() {
            return Err(RedisError::from((
                ErrorKind::InvalidClientConfig,
                "Duration should be None or non-zero.",
            )));
        }

        let mut t = self.read_timeout.borrow_mut();
        *t = dur;
        let connections = self.connections.borrow();
        for conn in connections.values() {
            conn.set_read_timeout(dur)?;
        }
        Ok(())
    }

    /// Check that all connections it has are available (`PING` internally).
    #[doc(hidden)]
    pub fn check_connection(&mut self) -> bool {
        <Self as ConnectionLike>::check_connection(self)
    }

    pub(crate) fn execute_pipeline(&mut self, pipe: &ClusterPipeline) -> RedisResult<Vec<Value>> {
        self.send_recv_and_retry_cmds(pipe.commands())
    }

    /// Returns the connection status.
    ///
    /// The connection is open until any `read_response` call received an
    /// invalid response from the server (most likely a closed or dropped
    /// connection, otherwise a Redis protocol error). When using unix
    /// sockets the connection is open until writing a command failed with a
    /// `BrokenPipe` error.
    fn create_initial_connections(&self) -> RedisResult<()> {
        let mut connections = HashMap::with_capacity(self.initial_nodes.len());
        let mut failed_connections = Vec::new();

        for info in self.initial_nodes.iter() {
            let addr = NodeAddress::try_from(&info.addr)?;

            match self.connect(&addr) {
                Ok(mut conn) => {
                    if conn.check_connection() {
                        connections.insert(addr, conn);
                        break;
                    } else {
                        failed_connections.push((
                            addr,
                            RedisError::from((
                                ErrorKind::Io,
                                "Node failed to respond to connection check,",
                            )),
                        ));
                    }
                }
                Err(conn_err) => {
                    failed_connections.push((addr, conn_err));
                }
            }
        }

        if connections.is_empty() {
            // Create a composite description of why connecting to each node failed.
            let detail = if failed_connections.is_empty() {
                "List of initial nodes is empty".to_string()
            } else {
                let mut formatted_detail = "Failed to connect to each cluster node (".to_string();

                for (index, (addr, conn_err)) in failed_connections.into_iter().enumerate() {
                    if index != 0 {
                        formatted_detail += "; ";
                    }
                    use std::fmt::Write;
                    let _ = write!(&mut formatted_detail, "{addr}: {conn_err}");
                }
                formatted_detail += ")";
                formatted_detail
            };

            return Err(RedisError::from((
                ErrorKind::Io,
                "It failed to check startup nodes.",
                detail,
            )));
        }

        *self.connections.borrow_mut() = connections;
        self.refresh_slots()?;
        Ok(())
    }

    // Query a node to discover slot-> master mappings.
    fn refresh_slots(&self) -> RedisResult<()> {
        let mut slots = self.slots.borrow_mut();
        *slots = self.create_new_slots()?;

        if let Some(ref strategy) = self.routing_strategy {
            strategy.on_topology_changed(slots.topology());
        }

        let mut nodes = slots.values().flatten().collect::<Vec<_>>();
        nodes.sort_unstable();
        nodes.dedup();

        let mut connections = self.connections.borrow_mut();
        *connections = nodes
            .into_iter()
            .filter_map(|addr| {
                if let Some(mut conn) = connections.remove(addr)
                    && conn.check_connection()
                {
                    return Some((addr.clone(), conn));
                }

                if let Ok(mut conn) = self.connect(addr)
                    && conn.check_connection()
                {
                    return Some((addr.clone(), conn));
                }

                None
            })
            .collect();

        Ok(())
    }

    fn create_new_slots(&self) -> RedisResult<SlotMap> {
        let mut connections = self.connections.borrow_mut();
        let mut new_slots = None;

        for (addr, conn) in connections.iter_mut() {
            let value = conn.req_command(&slot_cmd())?;
            if let Ok(slots_data) = parse_slots(value, addr.host()) {
                new_slots = Some(SlotMap::from_slots(slots_data));
                break;
            }
        }

        match new_slots {
            Some(new_slots) => Ok(new_slots),
            None => Err(RedisError::from((
                ErrorKind::Client,
                "Slot refresh error. didn't get any slots from server",
            ))),
        }
    }

    fn connect(&self, node: &NodeAddress) -> RedisResult<C> {
        let info = get_connection_info(node, &self.cluster_params);

        let mut conn = C::connect(info, Some(self.cluster_params.connection_timeout))?;
        // If READONLY is sent to primary nodes, it will have no effect.
        // We set this unconditionally, because we don't know whether we'll be making read calls
        // to replicas. (We allow overriding routing per-call)
        cmd("READONLY").exec(&mut conn)?;
        conn.set_read_timeout(*self.read_timeout.borrow())?;
        conn.set_write_timeout(*self.write_timeout.borrow())?;
        Ok(conn)
    }

    fn get_connection<'a>(
        &self,
        connections: &'a mut HashMap<NodeAddress, C>,
        route: Route,
    ) -> (NodeAddress, RedisResult<&'a mut C>) {
        let slots = self.slots.borrow();
        if let Some(addr) = slots.slot_addr_for_route(route, self.routing_strategy.as_deref()) {
            (addr.clone(), self.get_connection_by_addr(connections, addr))
        } else {
            // try a random node next.  This is safe if slots are involved
            // as a wrong node would reject the request.
            get_random_connection_or_error(connections)
        }
    }

    fn get_connection_by_addr<'a>(
        &self,
        connections: &'a mut HashMap<NodeAddress, C>,
        addr: &NodeAddress,
    ) -> RedisResult<&'a mut C> {
        match connections.entry(addr.clone()) {
            std::collections::hash_map::Entry::Occupied(occupied_entry) => {
                Ok(occupied_entry.into_mut())
            }
            std::collections::hash_map::Entry::Vacant(vacant_entry) => {
                // Create new connection.
                // TODO: error handling
                let conn = self.connect(addr)?;
                Ok(vacant_entry.insert(conn))
            }
        }
    }

    fn get_addr_for_cmd(&self, cmd: &Cmd) -> RedisResult<NodeAddress> {
        let slots = self.slots.borrow();

        let addr_for_slot = |route: Route| -> RedisResult<NodeAddress> {
            let slot_addr = slots
                .slot_addr_for_route(route, self.routing_strategy.as_deref())
                .ok_or((ErrorKind::Client, "Missing slot coverage"))?;
            Ok(slot_addr.clone())
        };

        match RoutingInfo::for_routable(cmd) {
            Some(RoutingInfo::SingleNode(SingleNodeRoutingInfo::Random)) => Ok(addr_for_slot(
                Route::with_slot(Slot::new_random(), SlotAddr::Master),
            )?),
            Some(RoutingInfo::SingleNode(SingleNodeRoutingInfo::SpecificNode(route))) => {
                Ok(addr_for_slot(route)?)
            }
            _ => fail!(UNROUTABLE_ERROR),
        }
    }

    fn map_cmds_to_nodes(&self, cmds: &[Cmd]) -> RedisResult<Vec<NodeCmd>> {
        let mut cmd_map: HashMap<NodeAddress, NodeCmd> = HashMap::new();

        for (idx, cmd) in cmds.iter().enumerate() {
            let addr = self.get_addr_for_cmd(cmd)?;
            let nc = cmd_map
                .entry(addr.clone())
                .or_insert_with(|| NodeCmd::new(addr));
            nc.indexes.push(idx);
            cmd.write_packed_command(&mut nc.pipe);
        }

        let mut result = Vec::new();
        for (_, v) in cmd_map.drain() {
            result.push(v);
        }
        Ok(result)
    }

    fn execute_on_all<'a>(
        &'a self,
        input: Input,
        addresses: HashSet<&'a NodeAddress>,
    ) -> Vec<RedisResult<(&'a NodeAddress, Value)>> {
        addresses
            .into_iter()
            .map(|addr| {
                self.request(
                    input.clone(),
                    Some(RoutingInfo::SingleNode(SingleNodeRoutingInfo::ByAddress {
                        host: addr.host().to_string(),
                        port: addr.port(),
                    })),
                )
                .map(|res| match res {
                    Output::Single(value) => (addr, value),
                    // technically this shouldn't be possible, but I prefer not to crash here.
                    Output::Multi(values) => (addr, Value::Array(values)),
                })
            })
            .collect()
    }

    fn execute_on_all_nodes<'a>(
        &'a self,
        input: Input,
        slots: &'a mut SlotMap,
    ) -> Vec<RedisResult<(&'a NodeAddress, Value)>> {
        self.execute_on_all(input, slots.addresses_for_all_nodes())
    }

    fn execute_on_all_primaries<'a>(
        &'a self,
        input: Input,
        slots: &'a mut SlotMap,
    ) -> Vec<RedisResult<(&'a NodeAddress, Value)>> {
        self.execute_on_all(input, slots.addresses_for_all_primaries())
    }

    fn execute_multi_slot<'a, 'b>(
        &'a self,
        input: Input,
        slots: &'a mut SlotMap,
        connections: &'a mut HashMap<NodeAddress, C>,
        routes: &'b [(Route, Vec<usize>)],
    ) -> Vec<RedisResult<(&'a NodeAddress, Value)>>
    where
        'b: 'a,
    {
        slots
            .addresses_for_multi_slot(routes, self.routing_strategy.as_deref())
            .enumerate()
            .map(|(index, addr)| {
                let addr = addr
                    .ok_or_else(|| RedisError::from((ErrorKind::Io, "Couldn't find connection")))?;
                let connection = self.get_connection_by_addr(connections, addr)?;
                let (_, indices) = routes.get(index).unwrap();
                let cmd =
                    crate::cluster_routing::command_for_multi_slot_indices(&input, indices.iter());
                connection.req_command(&cmd).map(|res| (addr, res))
            })
            .collect()
    }

    fn execute_on_multiple_nodes(
        &self,
        input: Input,
        routing: MultipleNodeRoutingInfo,
        response_policy: Option<ResponsePolicy>,
    ) -> RedisResult<Value> {
        let mut connections = self.connections.borrow_mut();
        let mut slots = self.slots.borrow_mut();

        let results = match &routing {
            MultipleNodeRoutingInfo::MultiSlot((routes, _)) => {
                self.execute_multi_slot(input, &mut slots, &mut connections, routes)
            }
            MultipleNodeRoutingInfo::AllMasters => {
                drop(connections);
                self.execute_on_all_primaries(input, &mut slots)
            }
            MultipleNodeRoutingInfo::AllNodes => {
                drop(connections);
                self.execute_on_all_nodes(input, &mut slots)
            }
        };

        match response_policy {
            Some(ResponsePolicy::AllSucceeded) => {
                let mut last_result = None;
                for result in results {
                    last_result = Some(result?);
                }

                last_result
                    .ok_or_else(|| {
                        (
                            ErrorKind::ClusterConnectionNotFound,
                            "No results received for multi-node operation",
                        )
                            .into()
                    })
                    .map(|(_, res)| res)
            }
            Some(ResponsePolicy::OneSucceeded) => {
                let mut last_failure = None;

                for result in results {
                    match result {
                        Ok((_, val)) => return Ok(val),
                        Err(err) => last_failure = Some(err),
                    }
                }

                Err(last_failure
                    .unwrap_or_else(|| (ErrorKind::Io, "Couldn't find a connection").into()))
            }
            Some(ResponsePolicy::CombineMaps) => crate::cluster_routing::combine_map_results(
                results
                    .into_iter()
                    .map(|result| result.map(|(_, value)| value))
                    .collect::<RedisResult<Vec<_>>>()?,
            ),
            Some(ResponsePolicy::FirstSucceededNonEmptyOrAllEmpty) => {
                // Attempt to return the first result that isn't `Nil` or an error.
                // If no such response is found and all servers returned `Nil`, it indicates that all shards are empty, so return `Nil`.
                // If we received only errors, return the last received error.
                // If we received a mix of errors and `Nil`s, we can't determine if all shards are empty,
                // thus we return the last received error instead of `Nil`.
                let mut last_failure = None;
                let num_of_results = results.len();
                let mut nil_counter = 0;
                for result in results {
                    match result.map(|(_, res)| res) {
                        Ok(Value::Nil) => nil_counter += 1,
                        Ok(val) => return Ok(val),
                        Err(err) => last_failure = Some(err),
                    }
                }
                if nil_counter == num_of_results {
                    Ok(Value::Nil)
                } else {
                    Err(last_failure
                        .unwrap_or_else(|| (ErrorKind::Io, "Couldn't find a connection").into()))
                }
            }
            Some(ResponsePolicy::Aggregate(op)) => {
                let results = results
                    .into_iter()
                    .map(|res| res.map(|(_, val)| val))
                    .collect::<RedisResult<Vec<_>>>()?;
                crate::cluster_routing::aggregate(results, op)
            }
            Some(ResponsePolicy::AggregateLogical(op)) => {
                let results = results
                    .into_iter()
                    .map(|res| res.map(|(_, val)| val))
                    .collect::<RedisResult<Vec<_>>>()?;
                crate::cluster_routing::logical_aggregate(results, op)
            }
            Some(ResponsePolicy::CombineArrays) => {
                let results = results
                    .into_iter()
                    .map(|res| res.map(|(_, val)| val))
                    .collect::<RedisResult<Vec<_>>>()?;
                match routing {
                    MultipleNodeRoutingInfo::MultiSlot((vec, pattern)) => {
                        crate::cluster_routing::combine_and_sort_array_results(
                            results, &vec, &pattern,
                        )
                    }
                    _ => crate::cluster_routing::combine_array_results(results),
                }
            }
            Some(ResponsePolicy::Special) | None => {
                // This is our assumption - if there's no coherent way to aggregate the responses, we just map each response to the sender, and pass it to the user.
                // TODO - once Value::Error is merged, we can use join_all and report separate errors and also pass successes.
                let results = results
                    .into_iter()
                    .map(|result| {
                        result.map(|(addr, val)| {
                            (Value::BulkString(addr.to_string().into_bytes()), val)
                        })
                    })
                    .collect::<RedisResult<Vec<_>>>()?;
                Ok(Value::Map(results))
            }
        }
    }

    #[allow(clippy::unnecessary_unwrap)]
    fn request(&self, input: Input, route_option: Option<RoutingInfo>) -> RedisResult<Output> {
        let single_node_routing = match route_option {
            Some(RoutingInfo::SingleNode(single_node_routing)) => single_node_routing,
            Some(RoutingInfo::MultiNode((multi_node_routing, response_policy))) => {
                return self
                    .execute_on_multiple_nodes(input, multi_node_routing, response_policy)
                    .map(Output::Single);
            }
            None => fail!(UNROUTABLE_ERROR),
        };

        let mut retries = 0;
        let mut redirected = None::<Redirect>;

        loop {
            // Get target address and response.
            let (addr, rv) = {
                let mut connections = self.connections.borrow_mut();
                let (addr, conn) = if let Some(redirected) = redirected.take() {
                    let (addr, is_asking) = match redirected {
                        Redirect::Moved(addr) => (addr, false),
                        Redirect::Ask(addr) => (addr, true),
                    };
                    let mut conn = self.get_connection_by_addr(&mut connections, &addr);
                    if is_asking {
                        // if we are in asking mode we want to feed a single
                        // ASKING command into the connection before what we
                        // actually want to execute.
                        conn = conn.and_then(|conn| {
                            conn.req_packed_command(&b"*1\r\n$6\r\nASKING\r\n"[..])
                                .and_then(|value| value.extract_error())?;
                            Ok(conn)
                        });
                    }
                    (addr, conn)
                } else {
                    match &single_node_routing {
                        SingleNodeRoutingInfo::Random => {
                            get_random_connection_or_error(&mut connections)
                        }
                        SingleNodeRoutingInfo::SpecificNode(route) => {
                            self.get_connection(&mut connections, *route)
                        }
                        SingleNodeRoutingInfo::ByAddress { host, port } => {
                            let address = NodeAddress::new(host.as_str(), *port);
                            let conn = self.get_connection_by_addr(&mut connections, &address);
                            (address, conn)
                        }
                        SingleNodeRoutingInfo::RandomPrimary => {
                            self.get_connection(&mut connections, Route::new_random_primary())
                        }
                    }
                };
                (addr, conn.and_then(|conn| input.send(conn)))
            };

            match rv {
                Ok(rv) => return Ok(rv),
                Err(err) => {
                    if err.kind() == ErrorKind::ClusterConnectionNotFound
                        && *self.auto_reconnect.borrow()
                    {
                        for node in &self.initial_nodes {
                            let addr = NodeAddress::try_from(&node.addr)?;
                            if let Ok(mut conn) = self.connect(&addr)
                                && conn.check_connection()
                            {
                                self.connections.borrow_mut().insert(addr, conn);
                            }
                        }
                        self.refresh_slots()?;
                    }

                    if retries == self.cluster_params.retry_params.number_of_retries {
                        return Err(err);
                    }
                    retries += 1;

                    match err.retry_method() {
                        RetryMethod::AskRedirect => {
                            redirected = err.redirect_node().and_then(|(node, _slot)| {
                                NodeAddress::try_from(node).ok().map(Redirect::Ask)
                            });
                        }
                        RetryMethod::MovedRedirect => {
                            // Refresh slots.
                            self.refresh_slots()?;
                            // Request again.
                            redirected = err.redirect_node().and_then(|(node, _slot)| {
                                NodeAddress::try_from(node).ok().map(Redirect::Moved)
                            });
                        }
                        RetryMethod::WaitAndRetry => {
                            // Sleep and retry.
                            let sleep_time = self
                                .cluster_params
                                .retry_params
                                .wait_time_for_retry(retries);
                            thread::sleep(sleep_time);
                        }
                        RetryMethod::RefreshSlotsAndRetry => {
                            // Stale slot map (e.g. READONLY after failover). Sleep first to give
                            // the cluster time to converge, then refresh so the retry (by slot,
                            // hence `redirected` stays None) routes on the freshest topology.
                            let sleep_time = self
                                .cluster_params
                                .retry_params
                                .wait_time_for_retry(retries);
                            thread::sleep(sleep_time);
                            self.refresh_slots()?;
                        }
                        RetryMethod::Reconnect => {
                            if *self.auto_reconnect.borrow() {
                                // if the connection is no longer valid, we should remove it.
                                self.connections.borrow_mut().remove(&addr);
                                if let Ok(mut conn) = self.connect(&addr)
                                    && conn.check_connection()
                                {
                                    self.connections.borrow_mut().insert(addr, conn);
                                }
                            }
                        }
                        RetryMethod::NoRetry => {
                            return Err(err);
                        }
                        RetryMethod::RetryImmediately => {}
                        RetryMethod::ReconnectFromInitialConnections => {
                            // TODO - implement reconnect from initial connections
                            if *self.auto_reconnect.borrow()
                                && let Ok(mut conn) = self.connect(&addr)
                                && conn.check_connection()
                            {
                                self.connections.borrow_mut().insert(addr, conn);
                            }
                        }
                    }
                }
            }
        }
    }

    fn send_recv_and_retry_cmds(&self, cmds: &[Cmd]) -> RedisResult<Vec<Value>> {
        // Vector to hold the results, pre-populated with `Nil` values. This allows the original
        // cmd ordering to be re-established by inserting the response directly into the result
        // vector (e.g., results[10] = response).
        let mut results = vec![Value::Nil; cmds.len()];

        let to_retry = self
            .send_all_commands(cmds)
            .and_then(|node_cmds| self.recv_all_commands(&mut results, &node_cmds))?;

        if to_retry.is_empty() {
            return Ok(results);
        }

        // Refresh the slots to ensure that we have a clean slate for the retry attempts.
        self.refresh_slots()?;

        // Given that there are commands that need to be retried, it means something in the cluster
        // topology changed. Execute each command separately to take advantage of the existing
        // retry logic that handles these cases.
        for retry_idx in to_retry {
            let cmd = &cmds[retry_idx];
            let routing = RoutingInfo::for_routable(cmd);
            results[retry_idx] = self.request(Input::Cmd(cmd), routing)?.into();
        }
        Ok(results)
    }

    // Build up a pipeline per node, then send it
    fn send_all_commands(&self, cmds: &[Cmd]) -> RedisResult<Vec<NodeCmd>> {
        let mut connections = self.connections.borrow_mut();

        let node_cmds = self.map_cmds_to_nodes(cmds)?;
        for nc in &node_cmds {
            self.get_connection_by_addr(&mut connections, &nc.addr)?
                .send_packed_command(&nc.pipe)?;
        }
        Ok(node_cmds)
    }

    // Receive from each node, keeping track of which commands need to be retried.
    fn recv_all_commands(
        &self,
        results: &mut [Value],
        node_cmds: &[NodeCmd],
    ) -> RedisResult<Vec<usize>> {
        let mut to_retry = Vec::new();
        let mut connections = self.connections.borrow_mut();
        let mut first_err = None;

        for nc in node_cmds {
            for cmd_idx in &nc.indexes {
                match self
                    .get_connection_by_addr(&mut connections, &nc.addr)?
                    .recv_response()
                {
                    Ok(item) => results[*cmd_idx] = item,
                    Err(err) if err.is_cluster_error() => to_retry.push(*cmd_idx),
                    Err(err) => first_err = first_err.or(Some(err)),
                }
            }
        }
        match first_err {
            Some(err) => Err(err),
            None => Ok(to_retry),
        }
    }

    /// Send a command to the given `routing`.
    pub fn route_command(&mut self, cmd: &Cmd, routing: RoutingInfo) -> RedisResult<Value> {
        self.request(Input::Cmd(cmd), Some(routing))
            .map(|res| res.into())
    }
}

const MULTI: &[u8] = "*1\r\n$5\r\nMULTI\r\n".as_bytes();
impl<C: Connect + ConnectionLike> ConnectionLike for ClusterConnection<C> {
    fn supports_pipelining(&self) -> bool {
        false
    }

    fn req_command(&mut self, cmd: &Cmd) -> RedisResult<Value> {
        if cmd.is_empty() {
            return Err(RedisError::make_empty_command());
        }
        let routing = RoutingInfo::for_routable(cmd);
        self.request(Input::Cmd(cmd), routing).map(|res| res.into())
    }

    fn req_packed_command(&mut self, cmd: &[u8]) -> RedisResult<Value> {
        if cmd.is_empty() {
            return Err(RedisError::make_empty_command());
        }
        let actual_cmd = if cmd.starts_with(MULTI) {
            &cmd[MULTI.len()..]
        } else {
            cmd
        };
        let value = parse_redis_value(actual_cmd)?;
        let routing = RoutingInfo::for_routable(&value);
        self.request(
            Input::Slice {
                cmd,
                routable: value,
            },
            routing,
        )
        .map(|res| res.into())
    }

    fn req_packed_commands(
        &mut self,
        cmd: &[u8],
        offset: usize,
        count: usize,
    ) -> RedisResult<Vec<Value>> {
        if cmd.is_empty() {
            return Err(RedisError::make_empty_command());
        }
        let actual_cmd = if cmd.starts_with(MULTI) {
            &cmd[MULTI.len()..]
        } else {
            cmd
        };
        let value = parse_redis_value(actual_cmd)?;
        let route = match RoutingInfo::for_routable(&value) {
            // we don't allow routing multiple commands to multiple nodes.
            Some(RoutingInfo::SingleNode(route)) => Some(route),
            Some(RoutingInfo::MultiNode(_)) | None => None,
        }
        .unwrap_or(SingleNodeRoutingInfo::Random);
        self.request(
            Input::Commands { cmd, offset, count },
            Some(RoutingInfo::SingleNode(route)),
        )
        .map(|res| res.into())
    }

    fn get_db(&self) -> i64 {
        0
    }

    fn is_open(&self) -> bool {
        let connections = self.connections.borrow();
        for conn in connections.values() {
            if !conn.is_open() {
                return false;
            }
        }
        true
    }

    fn check_connection(&mut self) -> bool {
        let mut connections = self.connections.borrow_mut();
        for conn in connections.values_mut() {
            if !conn.check_connection() {
                return false;
            }
        }
        true
    }
}

#[derive(Debug)]
struct NodeCmd {
    // The original command indexes
    indexes: Vec<usize>,
    pipe: Vec<u8>,
    addr: NodeAddress,
}

impl NodeCmd {
    fn new(a: NodeAddress) -> Self {
        Self {
            indexes: vec![],
            pipe: vec![],
            addr: a,
        }
    }
}

fn get_random_connection<C: ConnectionLike + Connect + Sized>(
    connections: &mut HashMap<NodeAddress, C>,
) -> Option<(NodeAddress, &mut C)> {
    connections
        .iter_mut()
        .choose(&mut rng())
        .map(|(addr, conn)| (addr.clone(), conn))
}

fn get_random_connection_or_error<C: ConnectionLike + Connect + Sized>(
    connections: &mut HashMap<NodeAddress, C>,
) -> (NodeAddress, RedisResult<&mut C>) {
    match get_random_connection(connections) {
        Some((addr, conn)) => (addr, Ok(conn)),
        None => (
            // we need to add a fake address in order for the error to be handled - the code that uses it assumes there's an address attached.
            NodeAddress::default(),
            Err(RedisError::from((
                ErrorKind::ClusterConnectionNotFound,
                "No connections found",
            ))),
        ),
    }
}
