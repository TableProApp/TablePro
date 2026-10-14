use futures::FutureExt;
use futures::future::LocalBoxFuture;
use gio::prelude::*;
use tablepro_core::NetworkEndpoint;
use tablepro_session::health::Reachability;

use super::ReachabilityProbe;

/// Asks GLib's network monitor, which checks the endpoint's addresses
/// against the routes it knows, through the network portal under
/// Flatpak. It resolves the name but never connects.
#[derive(Debug, Clone)]
pub struct GioReachability {
    monitor: gio::NetworkMonitor,
}

impl GioReachability {
    pub fn new(monitor: gio::NetworkMonitor) -> Self {
        Self { monitor }
    }
}

impl ReachabilityProbe for GioReachability {
    fn can_reach(&self, endpoint: &NetworkEndpoint) -> LocalBoxFuture<'static, Reachability> {
        let address = gio::NetworkAddress::new(endpoint.host(), endpoint.port());
        let host = endpoint.host().to_owned();
        self.monitor
            .can_reach_future(&address)
            .map(move |reached| match reached {
                Ok(()) => Reachability::Reachable,
                Err(error) => {
                    tracing::debug!(%host, %error, "the network cannot reach a session's server");
                    Reachability::Unreachable
                }
            })
            .boxed_local()
    }
}
