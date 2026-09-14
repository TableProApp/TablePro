use std::path::PathBuf;

use crate::NetworkEndpoint;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum TransportRoute {
    Tcp(NetworkEndpoint),
    UnixSocket(PathBuf),
}
