//! Defines a Sentinel type that connects to Redis sentinels and creates clients to
//! master or replica nodes.
//!
//! # Example
//! ```rust,no_run
//! use redis::TypedCommands;
//! use redis::sentinel::Sentinel;
//!
//! let nodes = vec!["redis://127.0.0.1:6379/", "redis://127.0.0.1:6378/", "redis://127.0.0.1:6377/"];
//! let mut sentinel = Sentinel::build(nodes).unwrap();
//! let mut master = sentinel.master_for("master_name", None).unwrap().get_connection().unwrap();
//! let mut replica = sentinel.replica_for("master_name", None).unwrap().get_connection().unwrap();
//!
//! master.set("test", "test_data").unwrap();
//! let rv = replica.get("test").unwrap().unwrap();
//!
//! assert_eq!(rv, "test_data");
//! ```
//!
//! There is also a SentinelClient which acts like a regular Client, providing the
//! `get_connection` and `get_async_connection` methods, internally using the Sentinel
//! type to create clients on demand for the desired node type (Master or Replica).
//!
//! # Example
//! ```rust,no_run
//! use redis::TypedCommands;
//! use redis::sentinel::{ SentinelServerType, SentinelClient };
//!
//! let nodes = vec!["redis://127.0.0.1:6379/", "redis://127.0.0.1:6378/", "redis://127.0.0.1:6377/"];
//! let mut master_client = SentinelClient::build(nodes.clone(), String::from("master_name"), None, SentinelServerType::Master).unwrap();
//! let mut replica_client = SentinelClient::build(nodes, String::from("master_name"), None, SentinelServerType::Replica).unwrap();
//! let mut master_conn = master_client.get_connection().unwrap();
//! let mut replica_conn = replica_client.get_connection().unwrap();
//!
//! master_conn.set("test", "test_data").unwrap();
//! let rv = replica_conn.get("test").unwrap().unwrap();
//!
//! assert_eq!(rv, "test_data");
//! ```
//!
//! If the sentinel's servers are using TLS, require authentication or using a non-zero DB, a full
//! SentinelNodeConnectionInfo struct may be used instead of just the master's name.
//! It's important to note that the sentinel nodes may have different usernames or passwords,
//! so the authentication info for them must be entered separately.
//!
//! # Example
//! ```rust,no_run
//! use redis::{ Commands, ConnectionAddr, ConnectionInfo, RedisConnectionInfo };
//! use redis::sentinel::{ Sentinel, SentinelNodeConnectionInfo };
//!
//! let nodes = vec!["redis://sentinel_user:sentinel_pass@127.0.0.1"];
//! let mut sentinel = Sentinel::build(nodes).unwrap();
//!
//! let redis_connection_info = RedisConnectionInfo::default()
//!     .set_db(1)
//!     .set_username("user")
//!     .set_password("pass");
//! let sentinel_master_node_connection_info = SentinelNodeConnectionInfo::default()
//!     .set_redis_connection_info(redis_connection_info);
//! let mut master_with_auth = sentinel
//!     .master_for(
//!         "master_name",
//!         Some(&sentinel_master_node_connection_info),
//!     )
//!     .unwrap()
//!     .get_connection()
//!     .unwrap();
//!
//! let sentinel_replica_node_connection_info = SentinelNodeConnectionInfo::default()
//!     .set_tls_mode(redis::TlsMode::Secure);
//! let mut replica_with_tls = sentinel
//!     .master_for(
//!         "master_name",
//!         Some(&sentinel_replica_node_connection_info),
//!     )
//!     .unwrap()
//!     .get_connection()
//!     .unwrap();
//! ```
//!
//! # Example
//! ```rust,no_run
//! use redis::{ Commands, RedisConnectionInfo };
//! use redis::sentinel::{ SentinelServerType, SentinelClient, SentinelNodeConnectionInfo };
//!
//! let nodes = vec!["redis://127.0.0.1:6379/", "redis://127.0.0.1:6378/", "redis://127.0.0.1:6377/"];
//! let redis_connection_info = RedisConnectionInfo::default()
//!     .set_username("user")
//!     .set_password("pass");
//! let sentinel_node_connection_info = SentinelNodeConnectionInfo::default()
//!     .set_tls_mode(redis::TlsMode::Insecure)
//!     .set_redis_connection_info(redis_connection_info);
//! let mut master_client = SentinelClient::build(
//!     nodes,
//!     String::from("master1"),
//!     Some(sentinel_node_connection_info),
//!     redis::sentinel::SentinelServerType::Master,
//! )
//! .unwrap();
//! ```
//!
//! In addition, there is a `SentinelClientBuilder` to provide the most fine-grained configuration possibilities
//!
//! # Example
//! ```rust,no_run
//! use redis::sentinel::SentinelClientBuilder;
//! use redis::{ConnectionAddr, TlsCertificates};
//! let nodes = vec![ConnectionAddr::Tcp(String::from("redis://127.0.0.1"), 6379), ConnectionAddr::Tcp(String::from("redis://127.0.0.1"), 6378), ConnectionAddr::Tcp(String::from("redis://127.0.0.1"), 6377)];
//!
//! let mut builder = SentinelClientBuilder::new(nodes, String::from("master"), redis::sentinel::SentinelServerType::Master).unwrap();
//!
//! builder = builder.set_client_to_sentinel_username(String::from("username1"));
//! builder = builder.set_client_to_sentinel_password(String::from("password1"));
//! builder = builder.set_client_to_sentinel_tls_mode(redis::TlsMode::Insecure);
//!
//! builder = builder.set_client_to_redis_username(String::from("username2"));
//! builder = builder.set_client_to_redis_password(String::from("password2"));
//! builder = builder.set_client_to_redis_tls_mode(redis::TlsMode::Secure);
//!
//!
//! let client = builder.build().unwrap();
//! ```
//!

#[cfg(feature = "aio")]
use crate::aio::MultiplexedConnection as AsyncConnection;
use arcstr::ArcStr;
#[cfg(feature = "aio")]
use futures_util::StreamExt;
use log::warn;
use rand::RngExt;
#[cfg(feature = "r2d2")]
use std::sync::Mutex;
use std::{collections::HashMap, num::NonZeroUsize};

#[cfg(feature = "tls-rustls")]
use crate::TlsCertificates;
#[cfg(feature = "aio")]
use crate::aio::MultiplexedConnection;
#[cfg(feature = "aio")]
use crate::client::AsyncConnectionConfig;
#[cfg(feature = "tls-rustls")]
use crate::tls::retrieve_tls_certificates;
use crate::{
    Client, Cmd, Connection, ConnectionAddr, ErrorKind, FromRedisValue, IntoConnectionInfo,
    ProtocolVersion, RedisConnectionInfo, RedisError, Role, TlsMode, cmd,
    connection::ConnectionInfo, errors::ServerErrorKind, io::tcp::TcpSettings, types::RedisResult,
};

fn not_a_sentinel_error() -> RedisError {
    const ERR_MSG: &str = "Address does not point to a sentinel node";
    RedisError::from((ErrorKind::InvalidClientConfig, ERR_MSG))
}

/// The Sentinel type, serves as a special purpose client which builds other clients on
/// demand.
pub struct Sentinel {
    sentinels_connection_info: Vec<ConnectionInfo>,
    connections_cache: Vec<Option<Connection>>,
    #[cfg(feature = "aio")]
    async_connections_cache: Vec<Option<AsyncConnection>>,
    replica_start_index: usize,
    #[cfg(feature = "tls-rustls")]
    certs: Option<TlsCertificates>,
}

/// Holds the connection information that a sentinel should use when connecting to the
/// servers (masters and replicas) belonging to it.
#[derive(Clone, Default)]
pub struct SentinelNodeConnectionInfo {
    /// The TLS mode of the connection, or None if we do not want to connect using TLS
    /// (just a plain TCP connection).
    tls_mode: Option<TlsMode>,

    /// The Redis specific/connection independent information to be used.
    redis_connection_info: Option<RedisConnectionInfo>,

    /// TCP settings for the connection.
    tcp_settings: Option<TcpSettings>,
}

impl SentinelNodeConnectionInfo {
    /// Sets the TLS mode of the connection
    pub fn set_tls_mode(self, tls_mode: TlsMode) -> Self {
        Self {
            tls_mode: Some(tls_mode),
            ..self
        }
    }

    /// Sets the Redis specific/connection independent information to be used, if needed
    pub fn set_redis_connection_info(self, redis_connection_info: RedisConnectionInfo) -> Self {
        Self {
            redis_connection_info: Some(redis_connection_info),
            ..self
        }
    }

    /// Sets the TCP settings for the connection
    pub fn set_tcp_settings(self, tcp_settings: TcpSettings) -> Self {
        Self {
            tcp_settings: Some(tcp_settings),
            ..self
        }
    }

    fn create_connection_info(
        &self,
        ip: String,
        port: u16,
        #[cfg(feature = "tls-rustls")] certs: &Option<TlsCertificates>,
    ) -> RedisResult<ConnectionInfo> {
        let addr = match self.tls_mode {
            None => crate::ConnectionAddr::Tcp(ip, port),
            Some(TlsMode::Secure) => crate::ConnectionAddr::TcpTls {
                host: ip,
                port,
                insecure: false,
                #[cfg(not(feature = "tls-rustls"))]
                tls_params: None,
                #[cfg(feature = "tls-rustls")]
                tls_params: certs.as_ref().map(retrieve_tls_certificates).transpose()?,
            },
            Some(TlsMode::Insecure) => crate::ConnectionAddr::TcpTls {
                host: ip,
                port,
                insecure: true,
                tls_params: None,
            },
        };

        Ok(ConnectionInfo {
            addr,
            redis: self.redis_connection_info.clone().unwrap_or_default(),
            tcp_settings: self.tcp_settings.clone().unwrap_or_default(),
        })
    }
}

impl Default for &SentinelNodeConnectionInfo {
    fn default() -> Self {
        static DEFAULT_VALUE: SentinelNodeConnectionInfo = SentinelNodeConnectionInfo {
            tls_mode: None,
            redis_connection_info: None,
            tcp_settings: None,
        };
        &DEFAULT_VALUE
    }
}

fn sentinel_masters_cmd() -> crate::Cmd {
    let mut cmd = crate::cmd("SENTINEL");
    cmd.arg("MASTERS");
    cmd
}

fn sentinel_replicas_cmd(master_name: &str) -> crate::Cmd {
    let mut cmd = crate::cmd("SENTINEL");
    cmd.arg("SLAVES"); // For compatibility with older redis versions
    cmd.arg(master_name);
    cmd
}

fn is_master_valid(master_info: &HashMap<String, String>, service_name: &str) -> bool {
    master_info.get("name").map(|s| s.as_str()) == Some(service_name)
        && master_info.contains_key("ip")
        && master_info.contains_key("port")
        && master_info.get("flags").is_some_and(|flags| {
            flags.contains("master") && !flags.contains("s_down") && !flags.contains("o_down")
        })
        && master_info["port"].parse::<u16>().is_ok()
}

fn is_replica_valid(replica_info: &HashMap<String, String>) -> bool {
    replica_info.contains_key("ip")
        && replica_info.contains_key("port")
        && replica_info
            .get("flags")
            .is_some_and(|flags| !flags.contains("s_down") && !flags.contains("o_down"))
        && replica_info["port"].parse::<u16>().is_ok()
}

/// Generates a random value in the 0..max range.
fn random_replica_index(max: NonZeroUsize) -> usize {
    rand::rng().random_range(0..max.into())
}

fn build_replica_clients(addresses: &[ConnectionInfo]) -> Result<Vec<Client>, crate::RedisError> {
    if addresses.is_empty() {
        fail!((
            ErrorKind::NoValidReplicasFoundBySentinel,
            "No valid replica found in sentinel for given name",
        ));
    }

    addresses
        .iter()
        .map(|addr| Client::open(addr.clone()))
        .collect()
}

fn try_connect_to_first_replica(
    addresses: &[ConnectionInfo],
    start_index: Option<usize>,
) -> Result<Client, crate::RedisError> {
    if addresses.is_empty() {
        fail!((
            ErrorKind::NoValidReplicasFoundBySentinel,
            "No valid replica found in sentinel for given name",
        ));
    }

    let start_index = start_index.unwrap_or(0);

    let mut last_err = None;
    for i in 0..addresses.len() {
        let index = (i + start_index) % addresses.len();
        match Client::open(addresses[index].clone()) {
            Ok(client) => return Ok(client),
            Err(err) => last_err = Some(err),
        }
    }

    // We can unwrap here because we know there is at least one error, since there is at
    // least one address, so we'll either return a client for it or store an error in
    // last_err.
    Err(last_err.expect("There should be an error because there is should be at least one address"))
}

fn valid_addrs<'a>(
    servers_info: Vec<HashMap<String, String>>,
    validate: impl Fn(&HashMap<String, String>) -> bool + 'a,
) -> impl Iterator<Item = (String, u16)> {
    servers_info
        .into_iter()
        .filter(move |info| validate(info))
        .map(|mut info| {
            // We can unwrap here because we already checked everything
            let ip = info.remove("ip").unwrap();
            let port = info["port"].parse::<u16>().unwrap();
            (ip, port)
        })
}

fn determine_master_from_role_or_info_replication(
    connection_info: &ConnectionInfo,
) -> RedisResult<bool> {
    let client = Client::open(connection_info.clone())?;
    let mut conn = client.get_connection()?;

    //Once the client discovered the address of the master instance, it should attempt a connection with the master, and call the ROLE command in order to verify the role of the instance is actually a master.
    let role_result = check_role(&mut conn);
    if let Ok(role) = role_result {
        return Ok(matches!(role, Role::Primary { .. }));
    }

    //If the ROLE commands is not available (it was introduced in Redis 2.8.12), a client may resort to the INFO replication command parsing the role: field of the output.
    let fallback_role_result = check_info_replication(&mut conn);
    if let Ok(role) = fallback_role_result {
        return Ok(role == "master");
    }

    evaluate_role_check_errors(role_result.unwrap_err(), fallback_role_result.unwrap_err())
}

fn get_node_role(connection_info: &ConnectionInfo) -> RedisResult<Role> {
    let client = Client::open(connection_info.clone())?;
    let mut conn = client.get_connection()?;
    crate::cmd("ROLE").query(&mut conn)
}

fn check_role(conn: &mut Connection) -> RedisResult<Role> {
    crate::cmd("ROLE").query(conn)
}

fn check_info_replication(conn: &mut Connection) -> RedisResult<String> {
    let info: String = crate::cmd("INFO").arg("REPLICATION").query(conn)?;

    //Taken from test_sentinel parse_replication_info
    let info_map = parse_replication_info(info);
    match info_map.get("role") {
        Some(x) => Ok(x.clone()),
        None => Err(RedisError::from((
            ErrorKind::UnexpectedReturnType,
            "Missing \"role\" field",
        ))),
    }
}

fn evaluate_role_check_errors(
    role_err: RedisError,
    fallback_role_err: RedisError,
) -> RedisResult<bool> {
    // unknown commands are expressed as response errors
    if role_err.kind() != ServerErrorKind::ResponseError.into() {
        return Err(role_err);
    }

    Err(fallback_role_err)
}

fn parse_replication_info(value: String) -> HashMap<String, String> {
    let info_map: std::collections::HashMap<String, String> = value
        .split("\r\n")
        .filter(|line| !line.trim_start().starts_with('#'))
        .filter_map(|line| line.split_once(':'))
        .map(|(key, val)| (key.to_string(), val.to_string()))
        .collect();
    info_map
}

/// Searches for a valid master with the given name in the list of masters returned by
/// a sentinel. A valid master is one which has a role of "master" (checked by running
/// the `ROLE` command and by seeing if its flags contains the "master" flag) and which
/// does not have the flags s_down or o_down set to it (these flags are returned by the
/// `SENTINEL MASTERS` command, and we expect the `masters` parameter to be the result of
/// that command).
fn find_valid_master(
    masters: Vec<HashMap<String, String>>,
    service_name: &str,
    node_connection_info: &SentinelNodeConnectionInfo,
    #[cfg(feature = "tls-rustls")] certs: &Option<TlsCertificates>,
) -> RedisResult<ConnectionInfo> {
    for (ip, port) in valid_addrs(masters, |m| is_master_valid(m, service_name)) {
        #[cfg(not(feature = "tls-rustls"))]
        let connection_info = node_connection_info.create_connection_info(ip, port)?;
        #[cfg(feature = "tls-rustls")]
        let connection_info = node_connection_info.create_connection_info(ip, port, certs)?;
        if determine_master_from_role_or_info_replication(&connection_info)? {
            return Ok(connection_info);
        }
    }

    fail!((
        ErrorKind::MasterNameNotFoundBySentinel,
        "Master with given name not found in sentinel",
    ))
}

#[cfg(feature = "aio")]
async fn async_determine_master_from_role_or_info_replication(
    connection_info: &ConnectionInfo,
) -> RedisResult<bool> {
    let client = Client::open(connection_info.clone())?;
    let mut conn = client.get_multiplexed_async_connection().await?;

    let role_result = async_check_role(&mut conn).await;
    if let Ok(role) = role_result {
        return Ok(matches!(role, Role::Primary { .. }));
    }

    //If the ROLE commands is not available (it was introduced in Redis 2.8.12), a client may resort to the INFO replication command parsing the role: field of the output.
    let fallback_role_result = async_check_info_replication(&mut conn).await;
    if let Ok(role) = fallback_role_result {
        return Ok(role == "master");
    }

    evaluate_role_check_errors(role_result.unwrap_err(), fallback_role_result.unwrap_err())
}

#[cfg(feature = "aio")]
async fn async_determine_slave_from_role_or_info_replication(
    connection_info: &ConnectionInfo,
) -> RedisResult<bool> {
    let client = Client::open(connection_info.clone())?;
    let mut conn = client.get_multiplexed_async_connection().await?;

    let role_result = async_check_role(&mut conn).await;
    if let Ok(role) = role_result {
        return Ok(matches!(role, Role::Replica { .. }));
    }

    //If the ROLE commands is not available (it was introduced in Redis 2.8.12), a client may resort to the INFO replication command parsing the role: field of the output.
    let fallback_role_result = async_check_info_replication(&mut conn).await;
    if let Ok(role) = fallback_role_result {
        return Ok(role == "slave");
    }

    evaluate_role_check_errors(role_result.unwrap_err(), fallback_role_result.unwrap_err())
}

#[cfg(feature = "aio")]
async fn async_check_role(conn: &mut MultiplexedConnection) -> RedisResult<Role> {
    let role: RedisResult<Role> = crate::cmd("ROLE").query_async(conn).await;
    role
}

#[cfg(feature = "aio")]
async fn async_check_info_replication(conn: &mut MultiplexedConnection) -> RedisResult<String> {
    let info: String = crate::cmd("INFO")
        .arg("REPLICATION")
        .query_async(conn)
        .await?;
    //Taken from test_sentinel parse_replication_info
    let info_map = parse_replication_info(info);
    match info_map.get("role") {
        Some(x) => Ok(x.clone()),
        None => Err(RedisError::from((
            ErrorKind::UnexpectedReturnType,
            "Missing \"role\" field",
        ))),
    }
}

/// Async version of [find_valid_master].
#[cfg(feature = "aio")]
async fn async_find_valid_master(
    masters: Vec<HashMap<String, String>>,
    service_name: &str,
    node_connection_info: &SentinelNodeConnectionInfo,
    #[cfg(feature = "tls-rustls")] certs: &Option<TlsCertificates>,
) -> RedisResult<ConnectionInfo> {
    for (ip, port) in valid_addrs(masters, |m| is_master_valid(m, service_name)) {
        #[cfg(not(feature = "tls-rustls"))]
        let connection_info = node_connection_info.create_connection_info(ip, port)?;
        #[cfg(feature = "tls-rustls")]
        let connection_info = node_connection_info.create_connection_info(ip, port, certs)?;
        if async_determine_master_from_role_or_info_replication(&connection_info).await? {
            return Ok(connection_info);
        }
    }

    fail!((
        ErrorKind::MasterNameNotFoundBySentinel,
        "Master with given name not found in sentinel",
    ))
}

#[cfg(not(feature = "tls-rustls"))]
fn get_valid_replicas_addresses(
    replicas: Vec<HashMap<String, String>>,
    node_connection_info: &SentinelNodeConnectionInfo,
) -> RedisResult<Vec<ConnectionInfo>> {
    let addresses = valid_addrs(replicas, is_replica_valid)
        .map(|(ip, port)| node_connection_info.create_connection_info(ip, port))
        .collect::<RedisResult<Vec<ConnectionInfo>>>()?;

    Ok(addresses
        .into_iter()
        .filter(|connection_info| {
            get_node_role(connection_info).is_ok_and(|x| matches!(x, Role::Replica { .. }))
        })
        .collect())
}

#[cfg(feature = "tls-rustls")]
fn get_valid_replicas_addresses(
    replicas: Vec<HashMap<String, String>>,
    node_connection_info: &SentinelNodeConnectionInfo,
    certs: &Option<TlsCertificates>,
) -> RedisResult<Vec<ConnectionInfo>> {
    let addresses = valid_addrs(replicas, is_replica_valid)
        .map(|(ip, port)| node_connection_info.create_connection_info(ip, port, certs))
        .collect::<RedisResult<Vec<ConnectionInfo>>>()?;

    Ok(addresses
        .into_iter()
        .filter(|connection_info| {
            get_node_role(connection_info).is_ok_and(|x| matches!(x, Role::Replica { .. }))
        })
        .collect())
}

#[cfg(all(feature = "aio", not(feature = "tls-rustls")))]
async fn async_get_valid_replicas_addresses(
    replicas: Vec<HashMap<String, String>>,
    node_connection_info: &SentinelNodeConnectionInfo,
) -> RedisResult<Vec<ConnectionInfo>> {
    async fn is_replica_role_valid(connection_info: ConnectionInfo) -> Option<ConnectionInfo> {
        match async_determine_slave_from_role_or_info_replication(&connection_info).await {
            Ok(x) => {
                if x {
                    Some(connection_info)
                } else {
                    None
                }
            }
            Err(_e) => None,
        }
    }

    let addresses = valid_addrs(replicas, is_replica_valid)
        .map(|(ip, port)| node_connection_info.create_connection_info(ip, port))
        .collect::<RedisResult<Vec<_>>>()?;

    Ok(futures_util::stream::iter(addresses)
        .filter_map(is_replica_role_valid)
        .collect()
        .await)
}

#[cfg(all(feature = "aio", feature = "tls-rustls"))]
async fn async_get_valid_replicas_addresses(
    replicas: Vec<HashMap<String, String>>,
    node_connection_info: &SentinelNodeConnectionInfo,
    certs: &Option<TlsCertificates>,
) -> RedisResult<Vec<ConnectionInfo>> {
    async fn is_replica_role_valid(connection_info: ConnectionInfo) -> Option<ConnectionInfo> {
        match async_determine_slave_from_role_or_info_replication(&connection_info).await {
            Ok(x) => x.then_some(connection_info),
            Err(_e) => None,
        }
    }

    let addresses = valid_addrs(replicas, is_replica_valid)
        .map(|(ip, port)| node_connection_info.create_connection_info(ip, port, certs))
        .collect::<RedisResult<Vec<_>>>()?;

    Ok(futures_util::stream::iter(addresses)
        .filter_map(is_replica_role_valid)
        .collect()
        .await)
}

#[cfg(feature = "aio")]
async fn async_reconnect(
    connection: &mut Option<AsyncConnection>,
    connection_info: &ConnectionInfo,
) -> RedisResult<()> {
    let sentinel_client = Client::open(connection_info.clone())?;
    let new_connection = sentinel_client.get_multiplexed_async_connection().await?;
    connection.replace(new_connection);
    let role: Role = crate::cmd("ROLE")
        .query_async(connection.as_mut().unwrap())
        .await?;
    if !matches!(role, Role::Sentinel { .. }) {
        *connection = None;
        return Err(not_a_sentinel_error());
    }
    Ok(())
}

#[cfg(feature = "aio")]
async fn async_try_single_sentinel<T: FromRedisValue>(
    cmd: Cmd,
    connection_info: &ConnectionInfo,
    cached_connection: &mut Option<AsyncConnection>,
) -> RedisResult<T> {
    if cached_connection.is_none() {
        async_reconnect(cached_connection, connection_info).await?;
    }

    let result = cmd.query_async(cached_connection.as_mut().unwrap()).await;

    if let Err(err) = result {
        if err.is_unrecoverable_error() || err.is_io_error() {
            async_reconnect(cached_connection, connection_info).await?;
            cmd.query_async(cached_connection.as_mut().unwrap()).await
        } else {
            Err(err)
        }
    } else {
        result
    }
}

fn reconnect(
    connection: &mut Option<Connection>,
    connection_info: &ConnectionInfo,
) -> RedisResult<()> {
    let sentinel_client = Client::open(connection_info.clone())?;
    let new_connection = sentinel_client.get_connection()?;
    connection.replace(new_connection);
    let role: Role = crate::cmd("ROLE").query(connection.as_mut().unwrap())?;
    if !matches!(role, Role::Sentinel { .. }) {
        *connection = None;
        return Err(not_a_sentinel_error());
    }
    Ok(())
}

fn try_single_sentinel<T: FromRedisValue>(
    cmd: Cmd,
    connection_info: &ConnectionInfo,
    cached_connection: &mut Option<Connection>,
) -> RedisResult<T> {
    if cached_connection.is_none() {
        reconnect(cached_connection, connection_info)?;
    }

    let result = cmd.query(cached_connection.as_mut().unwrap());

    if let Err(err) = result {
        if err.is_unrecoverable_error() || err.is_io_error() {
            reconnect(cached_connection, connection_info)?;
            cmd.query(cached_connection.as_mut().unwrap())
        } else {
            Err(err)
        }
    } else {
        result
    }
}

// non-async methods
impl Sentinel {
    #[cfg(not(feature = "tls-rustls"))]
    /// Creates a Sentinel client performing some basic checks on the URLs that might
    /// make the operation fail.
    ///
    /// `params` must contain addresses of Redis Sentinel nodes, not regular Redis nodes.
    pub fn build<T: IntoConnectionInfo>(params: Vec<T>) -> RedisResult<Sentinel> {
        Self::build_inner(params)
    }

    #[cfg(feature = "tls-rustls")]
    /// Creates a Sentinel client performing some basic checks on the URLs that might
    /// make the operation fail.
    ///
    /// `params` must contain addresses of Redis Sentinel nodes, not regular Redis nodes.
    pub fn build<T: IntoConnectionInfo>(params: Vec<T>) -> RedisResult<Self> {
        Self::build_inner(params, None)
    }

    fn build_inner<T: IntoConnectionInfo>(
        params: Vec<T>,
        #[cfg(feature = "tls-rustls")] certs: Option<TlsCertificates>,
    ) -> RedisResult<Self> {
        if params.is_empty() {
            fail!((
                ErrorKind::EmptySentinelList,
                "At least one sentinel is required",
            ))
        }

        let sentinels_connection_info = params
            .into_iter()
            .map(|p| p.into_connection_info())
            .collect::<RedisResult<Vec<ConnectionInfo>>>()?;

        if sentinels_connection_info
            .iter()
            .any(|connection_info| connection_info.redis_settings().db != 0)
        {
            warn!(
                "Non-zero DB set for sentinel, will cause \"Unknown command 'SELECT'\". Use set_client_to_redis_db on SentinelClientBuilder"
            );
        }

        let mut connections_cache = vec![];
        connections_cache.resize_with(sentinels_connection_info.len(), Default::default);

        #[cfg(all(feature = "aio", feature = "tls-rustls"))]
        {
            let mut async_connections_cache = vec![];
            async_connections_cache.resize_with(sentinels_connection_info.len(), Default::default);

            Ok(Self {
                sentinels_connection_info,
                connections_cache,
                async_connections_cache,
                replica_start_index: random_replica_index(NonZeroUsize::new(1000000).unwrap()),
                certs,
            })
        }

        #[cfg(all(feature = "aio", not(feature = "tls-rustls")))]
        {
            let mut async_connections_cache = vec![];
            async_connections_cache.resize_with(sentinels_connection_info.len(), Default::default);

            Ok(Sentinel {
                sentinels_connection_info,
                connections_cache,
                async_connections_cache,
                replica_start_index: random_replica_index(NonZeroUsize::new(1000000).unwrap()),
            })
        }

        #[cfg(all(not(feature = "aio"), feature = "tls-rustls"))]
        {
            Ok(Sentinel {
                sentinels_connection_info,
                connections_cache,
                replica_start_index: random_replica_index(NonZeroUsize::new(1000000).unwrap()),
                certs,
            })
        }

        #[cfg(all(not(feature = "aio"), not(feature = "tls-rustls")))]
        {
            Ok(Sentinel {
                sentinels_connection_info,
                connections_cache,
                replica_start_index: random_replica_index(NonZeroUsize::new(1000000).unwrap()),
            })
        }
    }

    /// Try to execute the given command in each sentinel, returning the result of the
    /// first one that executes without errors. If all return errors, we return the
    /// error of the last attempt.
    ///
    /// For each sentinel, we first check if there is a cached connection, and if not
    /// we attempt to connect to it (skipping that sentinel if there is an error during
    /// the connection). Then, we attempt to execute the given command with the cached
    /// connection. If there is an error indicating that the connection is invalid, we
    /// reconnect and try one more time in the new connection.
    ///
    fn try_all_sentinels<T: FromRedisValue>(&mut self, cmd: Cmd) -> RedisResult<T> {
        let mut last_err = None;
        for (connection_info, cached_connection) in self
            .sentinels_connection_info
            .iter()
            .zip(self.connections_cache.iter_mut())
        {
            match try_single_sentinel(cmd.clone(), connection_info, cached_connection) {
                Ok(result) => {
                    return Ok(result);
                }
                Err(err) => {
                    last_err = Some(err);
                }
            }
        }

        // We can unwrap here because we know there is at least one connection info.
        Err(last_err.expect("There should be at least one connection info"))
    }

    /// Get a list of all masters (using the command SENTINEL MASTERS) from the
    /// sentinels.
    fn get_sentinel_masters(&mut self) -> RedisResult<Vec<HashMap<String, String>>> {
        self.try_all_sentinels(sentinel_masters_cmd())
    }

    fn get_sentinel_replicas(
        &mut self,
        service_name: &str,
    ) -> RedisResult<Vec<HashMap<String, String>>> {
        self.try_all_sentinels(sentinel_replicas_cmd(service_name))
    }

    #[cfg(not(feature = "tls-rustls"))]
    fn find_master_address(
        &mut self,
        service_name: &str,
        node_connection_info: &SentinelNodeConnectionInfo,
    ) -> RedisResult<ConnectionInfo> {
        let masters = self.get_sentinel_masters()?;
        find_valid_master(masters, service_name, node_connection_info)
    }

    #[cfg(feature = "tls-rustls")]
    fn find_master_address(
        &mut self,
        service_name: &str,
        node_connection_info: &SentinelNodeConnectionInfo,
    ) -> RedisResult<ConnectionInfo> {
        let masters = self.get_sentinel_masters()?;
        find_valid_master(masters, service_name, node_connection_info, &self.certs)
    }

    #[cfg(not(feature = "tls-rustls"))]
    fn find_valid_replica_addresses(
        &mut self,
        service_name: &str,
        node_connection_info: &SentinelNodeConnectionInfo,
    ) -> RedisResult<Vec<ConnectionInfo>> {
        let replicas = self.get_sentinel_replicas(service_name)?;
        get_valid_replicas_addresses(replicas, node_connection_info)
    }

    #[cfg(feature = "tls-rustls")]
    fn find_valid_replica_addresses(
        &mut self,
        service_name: &str,
        node_connection_info: &SentinelNodeConnectionInfo,
    ) -> RedisResult<Vec<ConnectionInfo>> {
        let replicas = self.get_sentinel_replicas(service_name)?;
        get_valid_replicas_addresses(replicas, node_connection_info, &self.certs)
    }

    /// Determines the master's address for the given name, and returns a client for that
    /// master. This will connect to the master node to verify that it considers itself
    /// master so errors can originate from interaction either with Sentinel or with the
    /// master node.
    pub fn master_for(
        &mut self,
        service_name: &str,
        node_connection_info: Option<&SentinelNodeConnectionInfo>,
    ) -> RedisResult<Client> {
        let connection_info =
            self.find_master_address(service_name, node_connection_info.unwrap_or_default())?;
        Client::open(connection_info)
    }

    /// Returns Redis `Client` objects for all valid replicas of the given master name.
    /// Each client can be used to establish a connection later.
    ///
    /// This may return errors originating from either Sentinel or during client construction.
    pub fn get_replica_clients(
        &mut self,
        service_name: &str,
        node_connection_info: Option<&SentinelNodeConnectionInfo>,
    ) -> RedisResult<Vec<Client>> {
        let addresses = self
            .find_valid_replica_addresses(service_name, node_connection_info.unwrap_or_default())?;
        build_replica_clients(&addresses)
    }

    /// Connects to a randomly chosen replica of the given master name.
    pub fn replica_for(
        &mut self,
        service_name: &str,
        node_connection_info: Option<&SentinelNodeConnectionInfo>,
    ) -> RedisResult<Client> {
        let addresses = self
            .find_valid_replica_addresses(service_name, node_connection_info.unwrap_or_default())?;
        let start_index = NonZeroUsize::new(addresses.len()).map(random_replica_index);
        try_connect_to_first_replica(&addresses, start_index)
    }

    /// Attempts to connect to a different replica of the given master name each time.
    /// There is no guarantee that we'll actually be connecting to a different replica
    /// in the next call, but in a static set of replicas (no replicas added or
    /// removed), on average we'll choose each replica the same number of times.
    pub fn replica_rotate_for(
        &mut self,
        service_name: &str,
        node_connection_info: Option<&SentinelNodeConnectionInfo>,
    ) -> RedisResult<Client> {
        let addresses = self
            .find_valid_replica_addresses(service_name, node_connection_info.unwrap_or_default())?;
        if !addresses.is_empty() {
            self.replica_start_index = (self.replica_start_index + 1) % addresses.len();
        }
        try_connect_to_first_replica(&addresses, Some(self.replica_start_index))
    }
}

// Async versions of the public methods above, along with async versions of private
// methods required for the public methods.
#[cfg(feature = "aio")]
impl Sentinel {
    async fn async_try_all_sentinels<T: FromRedisValue>(&mut self, cmd: Cmd) -> RedisResult<T> {
        let mut last_err = None;
        for (connection_info, cached_connection) in self
            .sentinels_connection_info
            .iter()
            .zip(self.async_connections_cache.iter_mut())
        {
            match async_try_single_sentinel(cmd.clone(), connection_info, cached_connection).await {
                Ok(result) => {
                    return Ok(result);
                }
                Err(err) => {
                    last_err = Some(err);
                }
            }
        }

        // We can unwrap here because we know there is at least one connection info.
        Err(last_err.expect("There should be at least one connection info"))
    }

    async fn async_get_sentinel_masters(&mut self) -> RedisResult<Vec<HashMap<String, String>>> {
        self.async_try_all_sentinels(sentinel_masters_cmd()).await
    }

    async fn async_get_sentinel_replicas(
        &mut self,
        service_name: &str,
    ) -> RedisResult<Vec<HashMap<String, String>>> {
        self.async_try_all_sentinels(sentinel_replicas_cmd(service_name))
            .await
    }

    #[cfg(not(feature = "tls-rustls"))]
    async fn async_find_master_address(
        &mut self,
        service_name: &str,
        node_connection_info: &SentinelNodeConnectionInfo,
    ) -> RedisResult<ConnectionInfo> {
        let masters = self.async_get_sentinel_masters().await?;
        async_find_valid_master(masters, service_name, node_connection_info).await
    }

    #[cfg(feature = "tls-rustls")]
    async fn async_find_master_address(
        &mut self,
        service_name: &str,
        node_connection_info: &SentinelNodeConnectionInfo,
    ) -> RedisResult<ConnectionInfo> {
        let masters = self.async_get_sentinel_masters().await?;
        async_find_valid_master(masters, service_name, node_connection_info, &self.certs).await
    }

    #[cfg(not(feature = "tls-rustls"))]
    async fn async_find_valid_replica_addresses(
        &mut self,
        service_name: &str,
        node_connection_info: &SentinelNodeConnectionInfo,
    ) -> RedisResult<Vec<ConnectionInfo>> {
        let replicas = self.async_get_sentinel_replicas(service_name).await?;
        async_get_valid_replicas_addresses(replicas, node_connection_info).await
    }

    #[cfg(feature = "tls-rustls")]
    async fn async_find_valid_replica_addresses(
        &mut self,
        service_name: &str,
        node_connection_info: &SentinelNodeConnectionInfo,
    ) -> RedisResult<Vec<ConnectionInfo>> {
        let replicas = self.async_get_sentinel_replicas(service_name).await?;
        async_get_valid_replicas_addresses(replicas, node_connection_info, &self.certs).await
    }

    /// Determines the master's address for the given name, and returns a client for that
    /// master. This will connect to the master node to verify that it considers itself
    /// master so errors can originate from interaction either with Sentinel or with the
    /// master node.
    pub async fn async_master_for(
        &mut self,
        service_name: &str,
        node_connection_info: Option<&SentinelNodeConnectionInfo>,
    ) -> RedisResult<Client> {
        let address = self
            .async_find_master_address(service_name, node_connection_info.unwrap_or_default())
            .await?;
        Client::open(address)
    }

    /// Returns Redis `Client` objects for all valid replicas of the given master name.
    /// Each client can be used to establish a connection later.
    ///
    /// This may return errors originating from either Sentinel or during client construction.
    pub async fn async_get_replica_clients(
        &mut self,
        service_name: &str,
        node_connection_info: Option<&SentinelNodeConnectionInfo>,
    ) -> RedisResult<Vec<Client>> {
        let addresses = self
            .async_find_valid_replica_addresses(
                service_name,
                node_connection_info.unwrap_or_default(),
            )
            .await?;
        build_replica_clients(&addresses)
    }

    /// Connects to a randomly chosen replica of the given master name. Errors can originate
    /// from interaction either with Sentinel or with the replica.
    pub async fn async_replica_for(
        &mut self,
        service_name: &str,
        node_connection_info: Option<&SentinelNodeConnectionInfo>,
    ) -> RedisResult<Client> {
        let addresses = self
            .async_find_valid_replica_addresses(
                service_name,
                node_connection_info.unwrap_or_default(),
            )
            .await?;
        let start_index = NonZeroUsize::new(addresses.len()).map(random_replica_index);
        try_connect_to_first_replica(&addresses, start_index)
    }

    /// Attempts to connect to a different replica of the given master name each time.
    /// There is no guarantee that we'll actually be connecting to a different replica
    /// in the next call, but in a static set of replicas (no replicas added or
    /// removed), on average we'll choose each replica the same number of times.
    pub async fn async_replica_rotate_for(
        &mut self,
        service_name: &str,
        node_connection_info: Option<&SentinelNodeConnectionInfo>,
    ) -> RedisResult<Client> {
        let addresses = self
            .async_find_valid_replica_addresses(
                service_name,
                node_connection_info.unwrap_or_default(),
            )
            .await?;
        if !addresses.is_empty() {
            self.replica_start_index = (self.replica_start_index + 1) % addresses.len();
        }
        try_connect_to_first_replica(&addresses, Some(self.replica_start_index))
    }
}

/// Enum defining the server types from a sentinel's point of view.
#[derive(Debug, Clone)]
#[non_exhaustive]
pub enum SentinelServerType {
    /// Master connections only
    Master,
    /// Replica connections only
    Replica,
}

/// LockedSentinelClient is a wrapper around SentinelClient usable in r2d2.
// [internal comment]: this was added since SentinelClient requires &mut ref for get_connection()
// and we can't use it like this inside the r2d2 Manager, which requires a shared reference.
#[cfg(feature = "r2d2")]
pub struct LockedSentinelClient(pub(crate) Mutex<SentinelClient>);

#[cfg(feature = "r2d2")]
impl LockedSentinelClient {
    /// new creates a LockedSentinelClient by wrapping a new Mutex around the SentinelClient
    pub fn new(client: SentinelClient) -> Self {
        Self(Mutex::new(client))
    }

    /// get_connection is the override for LockedSentinelClient to make it possible to
    /// use LockedSentinelClient with r2d2 macro.
    pub fn get_connection(&self) -> RedisResult<Connection> {
        self.0.lock().unwrap().get_connection()
    }
}

#[cfg(all(feature = "bb8", feature = "tokio-comp", feature = "sentinel"))]
use tokio::sync::Mutex as TokioMutex;

/// AsyncLockedSentinelClient is a wrapper around SentinelClient usable in bb8.
// [internal comment]: bb8 is based on r2d2 so it came with the same constrainst
// this was added since SentinelClient requires &mut ref for get_connection()
// and we can't use it like this inside the r2d2 Manager, which requires a shared reference.
#[cfg(all(feature = "bb8", feature = "tokio-comp", feature = "sentinel"))]
pub struct AsyncLockedSentinelClient(pub(crate) TokioMutex<SentinelClient>);

#[cfg(all(feature = "bb8", feature = "tokio-comp", feature = "sentinel"))]
impl AsyncLockedSentinelClient {
    /// new creates a AsyncLockedSentinelClient by wrapping a new tokio Mutex around the SentinelClient
    pub fn new(client: SentinelClient) -> Self {
        Self(TokioMutex::new(client))
    }

    /// get_async_connection is the override for AsyncLockedSentinelClient to make it possible to
    /// use get_async_connection with bb8 macro.
    pub async fn get_async_connection(&self) -> RedisResult<MultiplexedConnection> {
        self.0.lock().await.get_async_connection().await
    }
}

/// A utility wrapping `Sentinel` with an interface similar to [Client].
///
/// Uses the Sentinel type internally. This is a utility to help make it easier
/// to use sentinels but with an interface similar to the client (`get_connection` and
/// `get_async_connection`). The type of server (master or replica) and name of the
/// desired master are specified when constructing an instance, so it will always
/// return connections to the same target (for example, always to the master with name
/// "mymaster123", or always to replicas of the master "another-master-abc").
pub struct SentinelClient {
    sentinel: Sentinel,
    service_name: ArcStr,
    node_connection_info: SentinelNodeConnectionInfo,
    server_type: SentinelServerType,
}

impl SentinelClient {
    #[cfg(not(feature = "tls-rustls"))]
    /// Creates a SentinelClient performing some basic checks on the URLs that might
    /// result in an error.
    ///
    /// `params` must contain addresses of Redis Sentinel nodes, not regular Redis nodes.
    pub fn build<T: IntoConnectionInfo>(
        params: Vec<T>,
        service_name: String,
        node_connection_info: Option<SentinelNodeConnectionInfo>,
        server_type: SentinelServerType,
    ) -> RedisResult<Self> {
        Self::build_inner(params, service_name, node_connection_info, server_type)
    }

    #[cfg(feature = "tls-rustls")]
    /// Creates a SentinelClient performing some basic checks on the URLs that might
    /// result in an error.
    ///
    /// `params` must contain addresses of Redis Sentinel nodes, not regular Redis nodes.
    pub fn build<T: IntoConnectionInfo>(
        params: Vec<T>,
        service_name: impl AsRef<str>,
        node_connection_info: Option<SentinelNodeConnectionInfo>,
        server_type: SentinelServerType,
    ) -> RedisResult<Self> {
        Self::build_inner(
            params,
            service_name,
            node_connection_info,
            server_type,
            None,
        )
    }

    fn build_inner<T: IntoConnectionInfo>(
        params: Vec<T>,
        service_name: impl AsRef<str>,
        node_connection_info: Option<SentinelNodeConnectionInfo>,
        server_type: SentinelServerType,
        #[cfg(feature = "tls-rustls")] certs: Option<TlsCertificates>,
    ) -> RedisResult<Self> {
        Ok(Self {
            #[cfg(not(feature = "tls-rustls"))]
            sentinel: Sentinel::build_inner(params)?,
            #[cfg(feature = "tls-rustls")]
            sentinel: Sentinel::build_inner(params, certs)?,
            service_name: service_name.as_ref().into(),
            node_connection_info: node_connection_info.unwrap_or_default(),
            server_type,
        })
    }

    /// Returns a [`Client`] considering the server type.
    pub fn get_client(&mut self) -> RedisResult<Client> {
        match self.server_type {
            SentinelServerType::Master => self
                .sentinel
                .master_for(self.service_name.as_str(), Some(&self.node_connection_info)),
            SentinelServerType::Replica => self
                .sentinel
                .replica_for(self.service_name.as_str(), Some(&self.node_connection_info)),
        }
    }

    /// Returns a [`Client`] connected to **the first Sentinel node that
    /// responds successfully to `ROLE` with the expected value**.
    ///
    /// The function walks through the list supplied in
    /// `Sentinel::sentinels_connection_info`, trying each address in order:
    ///
    /// 1. [Client::open] attempts to build a client for that Sentinel.
    /// 2. We immediately issue `ROLE` to confirm the node is reachable and is a Setinel node.
    /// 3. The **first** node that passes both checks, the client is returned.
    ///
    /// If **none** of the Sentinel addresses respond successfully or, an error occurs when
    /// establishing a connection, the method returns the appropriate error.
    ///
    /// Use this client when you need Sentinel-specific features—e.g.
    /// subscribing to `+switch-master` Pub/Sub events or running topology
    /// queries—rather than talking to the Redis master itself.
    pub fn get_sentinel_client(&mut self) -> RedisResult<Client> {
        let mut err = Err(RedisError::from((
            ErrorKind::InvalidClientConfig,
            "Couldn't open connection to a sentinel node.",
        )));

        for connection_info in &self.sentinel.sentinels_connection_info {
            if let Ok(client) = Client::open(connection_info.clone()) {
                match try_single_sentinel::<Role>(
                    cmd::cmd("ROLE"),
                    connection_info,
                    self.sentinel
                        .connections_cache
                        .first_mut()
                        .unwrap_or(&mut None),
                ) {
                    Ok(Role::Sentinel { .. }) => {
                        return Ok(client);
                    }
                    Ok(_) => {
                        // Do nothing, the node is not a sentinel node. If no Sentinel node is found
                        // the client will receive the appropriate error
                    }
                    Err(e) => {
                        err = Err(e);
                    }
                }
            }
        }

        err
    }

    /// Creates a new connection to the desired type of server (based on the
    /// service/master name, and the server type). We use a Sentinel to create a client
    /// for the target type of server, and then create a connection using that client.
    pub fn get_connection(&mut self) -> RedisResult<Connection> {
        let client = self.get_client()?;
        client.get_connection()
    }
}

/// To enable async support you need to chose one of the supported runtimes and active its
/// corresponding feature: `tokio-comp` or `smol-comp`
#[cfg(feature = "aio")]
#[cfg_attr(docsrs, doc(cfg(feature = "aio")))]
impl SentinelClient {
    /// Returns a [`Client`] considering the server type.
    pub async fn async_get_client(&mut self) -> RedisResult<Client> {
        match self.server_type {
            SentinelServerType::Master => {
                self.sentinel
                    .async_master_for(self.service_name.as_str(), Some(&self.node_connection_info))
                    .await
            }
            SentinelServerType::Replica => {
                self.sentinel
                    .async_replica_for(self.service_name.as_str(), Some(&self.node_connection_info))
                    .await
            }
        }
    }

    /// Returns a [`Client`] connected to **the first Sentinel node that
    /// responds successfully to `ROLE` with the expected value**.
    ///
    /// The function walks through the list supplied in
    /// `Sentinel::sentinels_connection_info`, trying each address in order:
    ///
    /// 1. [`Client::open`] attempts to build a client for that Sentinel.
    /// 2. We immediately issue `ROLE` to confirm the node is reachable and is a Setinel node.
    /// 3. The **first** node that passes both checks, the client is returned.
    ///
    /// If **none** of the Sentinel addresses respond successfully or, an error occurs when
    /// establishing a connection, the method returns the appropriate error.
    ///
    /// Use this client when you need Sentinel-specific features—e.g.
    /// subscribing to `+switch-master` Pub/Sub events or running topology
    /// queries—rather than talking to the Redis master itself.
    pub async fn async_get_sentinel_client(&mut self) -> RedisResult<Client> {
        let mut err = Err(RedisError::from((
            ErrorKind::InvalidClientConfig,
            "Couldn't open connection to a sentinel node.",
        )));

        for connection_info in &self.sentinel.sentinels_connection_info {
            if let Ok(client) = Client::open(connection_info.clone()) {
                match async_try_single_sentinel::<Role>(
                    cmd::cmd("ROLE"),
                    connection_info,
                    self.sentinel
                        .async_connections_cache
                        .first_mut()
                        .unwrap_or(&mut None),
                )
                .await
                {
                    Ok(Role::Sentinel { .. }) => {
                        return Ok(client);
                    }
                    Ok(_) => {
                        // Do nothing, the node is not a sentinel node. If no Sentinel node is found
                        // the client will receive the appropriate error
                    }
                    Err(e) => {
                        err = Err(e);
                    }
                }
            }
        }

        err
    }

    /// Returns an async connection from the client, using the same logic from
    /// `SentinelClient::get_connection`.
    #[cfg(feature = "aio")]
    pub async fn get_async_connection(&mut self) -> RedisResult<AsyncConnection> {
        self.get_async_connection_with_config(&AsyncConnectionConfig::new())
            .await
    }

    /// Returns an async connection from the client with options, using the same logic from
    /// `SentinelClient::get_connection`.
    #[cfg(feature = "aio")]
    pub async fn get_async_connection_with_config(
        &mut self,
        config: &AsyncConnectionConfig,
    ) -> RedisResult<AsyncConnection> {
        self.async_get_client()
            .await?
            .get_multiplexed_async_connection_with_config(config)
            .await
    }
}

struct BuilderConnectionParams {
    tls_mode: Option<TlsMode>,
    db: Option<i64>,
    username: Option<ArcStr>,
    password: Option<ArcStr>,
    protocol: Option<ProtocolVersion>,
    tcp_settings: TcpSettings,
    #[cfg(feature = "tls-rustls")]
    certificates: Option<TlsCertificates>,
}

/// Used to configure and build a [`SentinelClient`].
/// There are two connections that can be configured independently
/// 1. The connection towards the redis nodes (configured via `set_client_to_redis_..` functions)
/// 2. The connection towards the sentinel nodes (configure via `set_client_to_sentinel_..` functions)
pub struct SentinelClientBuilder {
    sentinels: Vec<ConnectionAddr>,
    service_name: ArcStr,
    server_type: SentinelServerType,
    client_to_redis_params: BuilderConnectionParams,
    client_to_sentinel_params: BuilderConnectionParams,
}

impl SentinelClientBuilder {
    /// Creates a new `SentinelClientBuilder`
    /// - `sentinels` - Addresses of Redis Sentinel nodes (not regular Redis nodes)
    /// - `service_name` - The name of the service to be queried via the sentinels
    /// - `server_type` - The server type to be queried via the sentinels
    pub fn new<T: IntoIterator<Item = ConnectionAddr>>(
        sentinels: T,
        service_name: impl AsRef<str>,
        server_type: SentinelServerType,
    ) -> RedisResult<Self> {
        Ok(Self {
            sentinels: sentinels.into_iter().collect::<Vec<_>>(),
            service_name: service_name.as_ref().into(),
            server_type,
            client_to_redis_params: BuilderConnectionParams {
                tls_mode: None,
                db: None,
                username: None,
                password: None,
                protocol: None,
                tcp_settings: TcpSettings::default(),
                #[cfg(feature = "tls-rustls")]
                certificates: None,
            },
            client_to_sentinel_params: BuilderConnectionParams {
                tls_mode: None,
                db: None,
                username: None,
                password: None,
                protocol: None,
                tcp_settings: TcpSettings::default(),
                #[cfg(feature = "tls-rustls")]
                certificates: None,
            },
        })
    }

    /// Creates a new `SentinelClient` from the parameters
    pub fn build(mut self) -> RedisResult<SentinelClient> {
        let mut client_to_redis_connection_info = RedisConnectionInfo::default();

        if let Some(db) = self.client_to_redis_params.db {
            client_to_redis_connection_info.db = db;
        }

        if let Some(username) = self.client_to_redis_params.username {
            client_to_redis_connection_info.username = Some(username);
        }

        if let Some(password) = self.client_to_redis_params.password {
            client_to_redis_connection_info.password = Some(password);
        }

        if let Some(protocol) = self.client_to_redis_params.protocol {
            client_to_redis_connection_info.protocol = protocol;
        }

        let client_to_redis_connection_info = SentinelNodeConnectionInfo {
            tls_mode: self.client_to_redis_params.tls_mode,
            redis_connection_info: Some(client_to_redis_connection_info),
            tcp_settings: Some(self.client_to_redis_params.tcp_settings),
        };

        for sentinel in &mut self.sentinels {
            match sentinel {
                ConnectionAddr::Tcp(_, _) => {
                    if self.client_to_sentinel_params.tls_mode.is_some() {
                        return Err(RedisError::from((
                            ErrorKind::InvalidClientConfig,
                            "Tls mode cannot be set for Tcp connection.",
                        )));
                    }
                    #[cfg(feature = "tls-rustls")]
                    if self.client_to_sentinel_params.certificates.is_some() {
                        return Err(RedisError::from((
                            ErrorKind::InvalidClientConfig,
                            "Certificates cannot be set for Tcp connection.",
                        )));
                    }
                }
                ConnectionAddr::TcpTls {
                    host: _,
                    port: _,
                    insecure,
                    #[cfg(feature = "tls-rustls")]
                    tls_params,
                    #[cfg(not(feature = "tls-rustls"))]
                        tls_params: _,
                } => {
                    if let Some(tls_mode) = self.client_to_sentinel_params.tls_mode {
                        match tls_mode {
                            TlsMode::Secure => {
                                *insecure = false;
                            }
                            TlsMode::Insecure => {
                                *insecure = true;
                            }
                        }
                    }
                    #[cfg(feature = "tls-rustls")]
                    if let Some(certs) = &self.client_to_sentinel_params.certificates {
                        let new_tls_params = retrieve_tls_certificates(certs)?;
                        *tls_params = Some(new_tls_params);
                    }
                }
                ConnectionAddr::Unix(_) => {
                    if self.client_to_sentinel_params.tls_mode.is_some() {
                        return Err(RedisError::from((
                            ErrorKind::InvalidClientConfig,
                            "Tls mode cannot be set for unix sockets.",
                        )));
                    }
                    #[cfg(feature = "tls-rustls")]
                    if self.client_to_sentinel_params.certificates.is_some() {
                        return Err(RedisError::from((
                            ErrorKind::InvalidClientConfig,
                            "Certificates cannot be set for unix sockets.",
                        )));
                    }
                }
            }
        }

        let mut client_to_sentinel_redis_connection_info = RedisConnectionInfo::default();

        if let Some(db) = self.client_to_sentinel_params.db {
            client_to_sentinel_redis_connection_info.db = db;
        }

        if let Some(username) = self.client_to_sentinel_params.username.as_ref() {
            client_to_sentinel_redis_connection_info.username = Some(username.clone());
        }

        if let Some(password) = self.client_to_sentinel_params.password.as_ref() {
            client_to_sentinel_redis_connection_info.password = Some(password.clone());
        }

        if let Some(protocol) = self.client_to_sentinel_params.protocol {
            client_to_sentinel_redis_connection_info.protocol = protocol;
        }

        let sentinels = self
            .sentinels
            .into_iter()
            .map(|connection_addr| ConnectionInfo {
                addr: connection_addr,
                redis: client_to_sentinel_redis_connection_info.clone(),
                tcp_settings: self.client_to_sentinel_params.tcp_settings.clone(),
            })
            .collect();

        SentinelClient::build_inner(
            sentinels,
            self.service_name,
            Some(client_to_redis_connection_info),
            self.server_type,
            #[cfg(feature = "tls-rustls")]
            self.client_to_redis_params.certificates,
        )
    }

    /// Set tls mode for the connection to redis
    pub fn set_client_to_redis_tls_mode(mut self, tls_mode: TlsMode) -> Self {
        self.client_to_redis_params.tls_mode = Some(tls_mode);
        self
    }

    /// Set db for the connection to redis
    pub fn set_client_to_redis_db(mut self, db: i64) -> Self {
        self.client_to_redis_params.db = Some(db);
        self
    }

    /// Set username for the connection to redis
    pub fn set_client_to_redis_username(mut self, username: impl AsRef<str>) -> Self {
        self.client_to_redis_params.username = Some(username.as_ref().into());
        self
    }

    /// Set password for the connection to redis
    pub fn set_client_to_redis_password(mut self, password: impl AsRef<str>) -> Self {
        self.client_to_redis_params.password = Some(password.as_ref().into());
        self
    }

    /// Set protocol for the connection to redis
    pub fn set_client_to_redis_protocol(mut self, protocol: ProtocolVersion) -> Self {
        self.client_to_redis_params.protocol = Some(protocol);
        self
    }

    #[cfg(feature = "tls-rustls")]
    /// Set certificates for the connection to redis
    pub fn set_client_to_redis_certificates(mut self, certificates: TlsCertificates) -> Self {
        self.client_to_redis_params.certificates = Some(certificates);
        self
    }

    /// Set TCP settings for the connection to the Redis nodes
    pub fn set_client_to_redis_tcp_settings(mut self, tcp_settings: TcpSettings) -> Self {
        self.client_to_redis_params.tcp_settings = tcp_settings;
        self
    }

    /// Set tls mode for the connection to the sentinels
    pub fn set_client_to_sentinel_tls_mode(mut self, tls_mode: TlsMode) -> Self {
        self.client_to_sentinel_params.tls_mode = Some(tls_mode);
        self
    }

    /// Set username for the connection to the sentinels
    pub fn set_client_to_sentinel_username(mut self, username: impl AsRef<str>) -> Self {
        self.client_to_sentinel_params.username = Some(username.as_ref().into());
        self
    }

    /// Set password for the connection to the sentinels
    pub fn set_client_to_sentinel_password(mut self, password: impl AsRef<str>) -> Self {
        self.client_to_sentinel_params.password = Some(password.as_ref().into());
        self
    }

    /// Set TCP settings for the connection to the sentinels
    pub fn set_client_to_sentinel_tcp_settings(mut self, tcp_settings: TcpSettings) -> Self {
        self.client_to_sentinel_params.tcp_settings = tcp_settings;
        self
    }

    /// Set protocol for the connection to the sentinels
    pub fn set_client_to_sentinel_protocol(mut self, protocol: ProtocolVersion) -> Self {
        self.client_to_sentinel_params.protocol = Some(protocol);
        self
    }

    #[cfg(feature = "tls-rustls")]
    /// Set certificate for the connection to the sentinels
    pub fn set_client_to_sentinel_certificates(mut self, certificates: TlsCertificates) -> Self {
        self.client_to_sentinel_params.certificates = Some(certificates);
        self
    }
}
