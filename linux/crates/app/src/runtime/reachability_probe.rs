use futures::future::LocalBoxFuture;
use tablepro_core::NetworkEndpoint;
use tablepro_session::health::Reachability;

/// Whether the network can reach one endpoint right now.
///
/// Answered per endpoint, not from the default route: a LAN server with
/// no internet behind it is reachable, and a host behind a VPN that is
/// down is not, whatever the rest of the network looks like.
pub trait ReachabilityProbe {
    fn can_reach(&self, endpoint: &NetworkEndpoint) -> LocalBoxFuture<'static, Reachability>;
}
