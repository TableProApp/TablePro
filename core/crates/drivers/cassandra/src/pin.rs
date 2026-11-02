//! Keeping a scylla session on the one node the transport reaches.
//!
//! Every other node advertises an address the transport does not carry:
//! a forward reaches one host, and a node behind NAT or in a container
//! advertises an address the desktop cannot dial. So the session takes
//! one node, as cqlsh does, and every address it would dial is the
//! relay's.

use std::net::SocketAddr;
use std::sync::{Mutex, PoisonError};

use async_trait::async_trait;
use scylla::cluster::metadata::Peer;
use scylla::errors::TranslationError;
use scylla::policies::address_translator::{AddressTranslator, UntranslatedPeer};
use scylla::policies::host_filter::HostFilter;
use uuid::Uuid;

#[derive(Debug)]
pub(crate) struct ContactPin {
    relay: SocketAddr,
    host: Mutex<Option<Uuid>>,
}

impl ContactPin {
    pub(crate) fn new(relay: SocketAddr) -> Self {
        Self {
            relay,
            host: Mutex::new(None),
        }
    }

    /// Pin the node that answered through the relay. Whether that moved
    /// the pin off the node the session first took.
    pub(crate) fn pin(&self, host: Uuid) -> bool {
        let mut pinned = self.host.lock().unwrap_or_else(PoisonError::into_inner);
        let moved = *pinned != Some(host);
        *pinned = Some(host);
        moved
    }
}

/// The topology lists the peers in no fixed order and says none of them
/// is the node on the other end, so the first one asked about is taken
/// until a query through the relay names the real one.
impl HostFilter for ContactPin {
    fn accept(&self, peer: &Peer) -> bool {
        self.holds(peer.host_id)
    }
}

impl ContactPin {
    fn holds(&self, host: Uuid) -> bool {
        let mut pinned = self.host.lock().unwrap_or_else(PoisonError::into_inner);
        *pinned.get_or_insert(host) == host
    }
}

#[async_trait]
impl AddressTranslator for ContactPin {
    async fn translate_address(&self, _peer: &UntranslatedPeer) -> Result<SocketAddr, TranslationError> {
        Ok(self.relay)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_first_host_asked_about_is_held_until_pinned_elsewhere() {
        let pin = ContactPin::new(SocketAddr::from(([127, 0, 0, 1], 9042)));
        let (first, second) = (Uuid::from_u128(1), Uuid::from_u128(2));

        assert!(pin.holds(first));
        assert!(!pin.holds(second), "a second node was enabled");
        assert!(pin.holds(first));
        assert!(pin.pin(second), "pinning the node that answered moves the pin");
        assert!(pin.holds(second) && !pin.holds(first));
        assert!(!pin.pin(second), "pinning the same node again moves nothing");
    }
}
