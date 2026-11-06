use crate::file_endpoint::FileEndpoint;
use crate::network_target::NetworkTarget;

/// Where a connection goes.
#[derive(Debug, Clone)]
#[expect(
    clippy::large_enum_variant,
    reason = "one per connect; inline fields keep every driver's match on the network target direct"
)]
pub enum ConnectTarget {
    Network(NetworkTarget),
    File(FileEndpoint),
}
