use std::ops::Deref;
use std::sync::Arc;

use tablepro_core::Connection;
use tokio_util::sync::WaitForCancellationFutureOwned;

use super::EstablishedConnection;
use crate::health::LinkGeneration;

/// The connection one operation runs on, and which generation it was.
///
/// A lease keeps its connection alive after the link moves on, so an
/// operation already running finishes on the connection it started
/// with, and its result is judged by the generation it carries.
#[derive(Clone)]
pub struct ConnectionLease {
    generation: LinkGeneration,
    established: Arc<EstablishedConnection>,
}

impl ConnectionLease {
    pub(crate) fn new(generation: LinkGeneration, established: Arc<EstablishedConnection>) -> Self {
        Self {
            generation,
            established,
        }
    }

    pub fn generation(&self) -> LinkGeneration {
        self.generation
    }

    pub fn connection(&self) -> &Arc<dyn Connection> {
        &self.established.connection
    }

    /// Fires when the SSH master this connection runs through exits.
    /// `None` for a direct connection.
    pub fn ssh_closed(&self) -> Option<WaitForCancellationFutureOwned> {
        self.established.ssh_session.as_ref().map(|session| session.closed())
    }
}

impl Deref for ConnectionLease {
    type Target = dyn Connection;

    fn deref(&self) -> &Self::Target {
        &*self.established.connection
    }
}

impl std::fmt::Debug for ConnectionLease {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ConnectionLease")
            .field("generation", &self.generation)
            .finish_non_exhaustive()
    }
}
