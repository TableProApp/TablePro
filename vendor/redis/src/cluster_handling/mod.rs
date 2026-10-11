use arcstr::ArcStr;

use crate::{
    Cmd, ConnectionAddr, ConnectionInfo, ErrorKind, RedisConnectionInfo, RedisError, RedisResult,
    TlsMode, cluster_handling::client::ClusterParams, connection::TlsConnParams,
};

use std::fmt;
use std::str::FromStr;

#[cfg(feature = "cluster-async")]
pub mod async_connection;
pub mod client;
/// Pluggable read routing strategies for cluster connections.
pub mod read_routing;
/// Routing information for cluster commands.
pub mod routing;
pub(crate) mod slot_map;
pub(crate) mod slot_range_map;
pub mod sync_connection;
pub(crate) mod topology;

/// The address of a node in a Redis Cluster.
///
/// Stores the host and port components separately, providing structured access
/// without repeated string parsing. The host may be an IPv4 address
/// (e.g. `127.0.0.1`), an IPv6 address (e.g. `dead::cafe:beef`), or a hostname
/// (e.g. `redis-node-1.example.com`).
#[derive(Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Default)]
pub struct NodeAddress {
    host: ArcStr,
    port: u16,
}

impl NodeAddress {
    /// Creates a new `NodeAddress` from a host and port.
    pub fn new(host: impl Into<ArcStr>, port: u16) -> Self {
        Self::from_parts(host.into(), port)
    }

    /// Creates a new `NodeAddress` from pre-constructed parts.
    ///
    /// This is a `const fn` variant of [`new`](Self::new), useful for defining
    /// compile-time constants via [`arcstr::literal!`]:
    ///
    /// ```ignore
    /// const ADDR: NodeAddress = NodeAddress::from_parts(arcstr::literal!("127.0.0.1"), 6379);
    /// ```
    pub const fn from_parts(host: ArcStr, port: u16) -> Self {
        Self { host, port }
    }

    /// Returns the hostname portion of the address.
    pub fn host(&self) -> &str {
        &self.host
    }

    /// Returns the port number.
    pub fn port(&self) -> u16 {
        self.port
    }
}

impl fmt::Display for NodeAddress {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}:{}", self.host, self.port)
    }
}

impl fmt::Debug for NodeAddress {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}:{}", self.host, self.port)
    }
}

impl TryFrom<&str> for NodeAddress {
    type Error = RedisError;

    fn try_from(s: &str) -> Result<Self, Self::Error> {
        let (host, port) = split_node_address(s)?;
        Ok(Self::new(host, port))
    }
}

impl TryFrom<&ConnectionAddr> for NodeAddress {
    type Error = RedisError;

    fn try_from(addr: &ConnectionAddr) -> Result<Self, Self::Error> {
        match addr {
            ConnectionAddr::Tcp(host, port) | ConnectionAddr::TcpTls { host, port, .. } => {
                Ok(Self::new(host.as_str(), *port))
            }
            ConnectionAddr::Unix(_) => Err(RedisError::from((
                ErrorKind::InvalidClientConfig,
                "Unix sockets are not supported in cluster mode",
            ))),
        }
    }
}

impl PartialEq<str> for NodeAddress {
    fn eq(&self, other: &str) -> bool {
        if let Ok(parsed) = Self::try_from(other) {
            self == &parsed
        } else {
            false
        }
    }
}

impl PartialEq<&str> for NodeAddress {
    fn eq(&self, other: &&str) -> bool {
        self == *other
    }
}

pub(crate) fn slot_cmd() -> Cmd {
    let mut cmd = Cmd::new();
    cmd.arg("CLUSTER").arg("SLOTS");
    cmd
}

pub(crate) fn split_node_address(node: &str) -> RedisResult<(&str, u16)> {
    let invalid_error =
        || RedisError::from((ErrorKind::InvalidClientConfig, "Invalid node string"));
    node.rsplit_once(':')
        .and_then(|(host, port)| {
            Some(host.trim_start_matches('[').trim_end_matches(']'))
                .filter(|h| !h.is_empty())
                .zip(u16::from_str(port).ok())
        })
        .ok_or_else(invalid_error)
}

pub(crate) fn get_connection_addr(
    host: String,
    port: u16,
    tls: Option<TlsMode>,
    tls_params: Option<TlsConnParams>,
) -> ConnectionAddr {
    match tls {
        Some(TlsMode::Secure) => ConnectionAddr::TcpTls {
            host,
            port,
            insecure: false,
            tls_params,
        },
        Some(TlsMode::Insecure) => ConnectionAddr::TcpTls {
            host,
            port,
            insecure: true,
            tls_params,
        },
        _ => ConnectionAddr::Tcp(host, port),
    }
}

pub(crate) fn get_connection_info(
    node: &NodeAddress,
    cluster_params: &ClusterParams,
) -> ConnectionInfo {
    let mapped = cluster_params
        .node_address_map
        .as_ref()
        .and_then(|map| map.get(node));
    let (host, port) = match mapped {
        Some(addr) => (addr.host().to_string(), addr.port()),
        None => (node.host().to_string(), node.port()),
    };
    ConnectionInfo {
        addr: get_connection_addr(
            host,
            port,
            cluster_params.tls,
            cluster_params.tls_params.clone(),
        ),
        redis: RedisConnectionInfo {
            db: cluster_params.database_id.unwrap_or(0),
            password: cluster_params.password.clone(),
            username: cluster_params.username.clone(),
            protocol: cluster_params.protocol.unwrap_or_default(),
            ..Default::default()
        },
        tcp_settings: cluster_params.tcp_settings.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_node_address() {
        let cases = vec![
            ("127.0.0.1:6379", "127.0.0.1", 6379),
            ("localhost.localdomain:6379", "localhost.localdomain", 6379),
            ("dead::cafe:beef:30001", "dead::cafe:beef", 30001),
            ("[fe80::cafe:beef%en1]:30001", "fe80::cafe:beef%en1", 30001),
        ];

        for (input, expected_host, expected_port) in cases {
            let addr = NodeAddress::try_from(input).unwrap();
            assert_eq!(addr.host(), expected_host);
            assert_eq!(addr.port(), expected_port);
        }
    }

    #[test]
    fn reject_invalid_node_address() {
        let cases = vec![":0", "[]:6379"];
        for input in cases {
            let res = NodeAddress::try_from(input);
            assert_eq!(
                res.err(),
                Some(RedisError::from((
                    ErrorKind::InvalidClientConfig,
                    "Invalid node string",
                ))),
            );
        }
    }

    #[test]
    fn get_connection_info_uses_node_address_map() {
        let node = NodeAddress::new("10.0.0.1", 8501);
        let mapped = NodeAddress::new("node1.westeurope.redis.azure.net", 8501);

        let mut map = std::collections::HashMap::new();
        map.insert(node.clone(), mapped);

        let params = ClusterParams {
            node_address_map: Some(map),
            ..Default::default()
        };

        let info = get_connection_info(&node, &params);
        match info.addr {
            ConnectionAddr::Tcp(host, port) => {
                assert_eq!(host, "node1.westeurope.redis.azure.net");
                assert_eq!(port, 8501);
            }
            _ => panic!("expected Tcp connection addr"),
        }
    }

    #[test]
    fn get_connection_info_falls_back_without_mapping() {
        let node = NodeAddress::new("10.0.0.1", 8501);
        let other = NodeAddress::new("10.0.0.2", 8501);
        let mapped = NodeAddress::new("node2.westeurope.redis.azure.net", 8501);

        let mut map = std::collections::HashMap::new();
        map.insert(other, mapped);

        let params = ClusterParams {
            node_address_map: Some(map),
            ..Default::default()
        };

        let info = get_connection_info(&node, &params);
        match info.addr {
            ConnectionAddr::Tcp(host, port) => {
                assert_eq!(host, "10.0.0.1");
                assert_eq!(port, 8501);
            }
            _ => panic!("expected Tcp connection addr"),
        }
    }

    #[test]
    fn get_connection_info_without_map() {
        let node = NodeAddress::new("10.0.0.1", 6379);
        let params = ClusterParams::default();

        let info = get_connection_info(&node, &params);
        match info.addr {
            ConnectionAddr::Tcp(host, port) => {
                assert_eq!(host, "10.0.0.1");
                assert_eq!(port, 6379);
            }
            _ => panic!("expected Tcp connection addr"),
        }
    }
}
