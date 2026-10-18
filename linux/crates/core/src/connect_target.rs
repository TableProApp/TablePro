use crate::file_endpoint::FileEndpoint;
use crate::network_target::NetworkTarget;

/// Where a connection goes.
#[derive(Debug, Clone)]
pub enum ConnectTarget {
    Network(NetworkTarget),
    File(FileEndpoint),
}
