use std::sync::Arc;

use tokio::sync::watch;

use super::{ConnectionLease, EstablishedConnection, RetiredConnection};
use crate::health::LinkGeneration;

#[derive(Clone)]
struct LinkSlot {
    generation: LinkGeneration,
    established: Option<Arc<EstablishedConnection>>,
    /// Set by `take`. A reconnect that finishes after the session shut
    /// down must not put a connection back nobody will close.
    taken: bool,
}

/// Where the session's current connection lives.
///
/// Replacing bumps the generation, so a loss reported by an operation
/// that leased the old connection is told apart from a loss of the new
/// one. Subscribers learn of every replacement through `subscribe`.
pub struct ConnectionLink {
    slot: watch::Sender<LinkSlot>,
    generation: watch::Sender<LinkGeneration>,
}

impl ConnectionLink {
    pub fn new(established: EstablishedConnection) -> Self {
        let generation = LinkGeneration::FIRST;
        Self {
            slot: watch::Sender::new(LinkSlot {
                generation,
                established: Some(Arc::new(established)),
                taken: false,
            }),
            generation: watch::Sender::new(generation),
        }
    }

    /// The current connection, or `None` once the link was taken.
    pub fn lease(&self) -> Option<ConnectionLease> {
        let slot = self.slot.borrow();
        slot.established
            .clone()
            .map(|established| ConnectionLease::new(slot.generation, established))
    }

    pub fn generation(&self) -> LinkGeneration {
        self.slot.borrow().generation
    }

    pub fn subscribe(&self) -> watch::Receiver<LinkGeneration> {
        self.generation.subscribe()
    }

    /// Put a new connection in place and hand back the old one to close.
    ///
    /// Once the link was taken the new connection is refused and handed
    /// straight back as retired, so the caller closes it.
    pub fn replace(&self, established: EstablishedConnection) -> (LinkGeneration, Option<RetiredConnection>) {
        let established = Arc::new(established);
        let mut retired = None;
        let mut generation = LinkGeneration::FIRST;
        let mut adopted = false;
        self.slot.send_if_modified(|slot| {
            generation = slot.generation;
            if slot.taken {
                retired = Some(RetiredConnection::new(slot.generation, established.clone()));
                return false;
            }
            retired = slot
                .established
                .take()
                .map(|old| RetiredConnection::new(slot.generation, old));
            slot.generation = slot.generation.next();
            slot.established = Some(established.clone());
            generation = slot.generation;
            adopted = true;
            true
        });
        if adopted {
            self.generation.send_replace(generation);
        }
        (generation, retired)
    }

    pub fn is_taken(&self) -> bool {
        self.slot.borrow().taken
    }

    /// Empty the link for good, handing back the connection to close.
    pub fn take(&self) -> Option<RetiredConnection> {
        let mut retired = None;
        self.slot.send_modify(|slot| {
            slot.taken = true;
            retired = slot
                .established
                .take()
                .map(|old| RetiredConnection::new(slot.generation, old));
        });
        retired
    }
}

impl std::fmt::Debug for ConnectionLink {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ConnectionLink")
            .field("generation", &self.generation())
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use tablepro_core::CallOptions;
    use tablepro_test_support::{CallCounters, CloseBehaviour, ConnectionScript, FakeConnection, FakeReply};
    use tokio_util::sync::CancellationToken;

    use super::*;
    use crate::link::CloseReport;

    fn established(script: ConnectionScript) -> (EstablishedConnection, Arc<FakeConnection>) {
        let connection = Arc::new(FakeConnection::new(script));
        (
            EstablishedConnection {
                connection: connection.clone(),
                ssh_session: None,
            },
            connection,
        )
    }

    fn probing() -> ConnectionScript {
        let mut script = ConnectionScript::default();
        script.probe.always(FakeReply::ok(()));
        script
    }

    #[tokio::test]
    async fn lease_survives_replace() {
        let (first, first_connection) = established(probing());
        let link = ConnectionLink::new(first);
        let lease = link.lease().unwrap();
        let mut changes = link.subscribe();

        let (second, _) = established(probing());
        let (generation, retired) = link.replace(second);

        assert_eq!(lease.generation(), LinkGeneration::FIRST);
        assert_eq!(generation, LinkGeneration::FIRST.next());
        assert_eq!(link.generation(), generation);
        assert!(changes.has_changed().unwrap());
        assert_eq!(*changes.borrow_and_update(), generation);
        lease
            .probe(CallOptions::new(None, CancellationToken::new()))
            .await
            .expect("the old lease still reaches its connection");
        assert_eq!(CallCounters::get(&first_connection.counters().probe), 1);
        assert_eq!(retired.unwrap().generation(), LinkGeneration::FIRST);
        assert_eq!(link.lease().unwrap().generation(), generation);
    }

    #[tokio::test]
    async fn take_empties_the_link() {
        let (first, connection) = established(probing());
        let link = ConnectionLink::new(first);

        let retired = link.take().unwrap();

        assert!(link.lease().is_none());
        assert!(link.take().is_none(), "a second take found something");
        assert_eq!(retired.close(Duration::from_secs(1)).await, CloseReport::Closed);
        assert!(connection.is_closed());
    }

    #[tokio::test]
    async fn a_taken_link_hands_a_late_replacement_back_to_close() {
        let (first, _) = established(probing());
        let link = ConnectionLink::new(first);
        drop(link.take());
        let changes = link.subscribe();

        let (late, late_connection) = established(probing());
        let (generation, retired) = link.replace(late);

        assert_eq!(generation, LinkGeneration::FIRST);
        assert!(link.lease().is_none(), "a shut-down link adopted a connection");
        assert!(!changes.has_changed().unwrap());
        assert_eq!(
            retired.unwrap().close(Duration::from_secs(1)).await,
            CloseReport::Closed
        );
        assert!(late_connection.is_closed());
    }

    #[tokio::test(start_paused = true)]
    async fn a_hanging_close_is_abandoned_at_its_deadline() {
        let (hanging, _) = established(ConnectionScript {
            close: CloseBehaviour::Hang,
            ..ConnectionScript::default()
        });
        let link = ConnectionLink::new(hanging);

        let report = link.take().unwrap().close(Duration::from_secs(10)).await;

        assert_eq!(report, CloseReport::Abandoned);
    }
}
