use std::path::PathBuf;

use crate::NetworkEndpoint;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum TransportRoute {
    Tcp(NetworkEndpoint),
    UnixSocket(PathBuf),
    // Only `Transport::open` reaches the server, so a library that dials needs the driver's relay.
    InProcess,
}
