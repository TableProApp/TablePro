use std::sync::Arc;
use std::time::Duration;

use super::{CloseReport, EstablishedConnection};
use crate::health::LinkGeneration;

/// A connection the link no longer hands out.
///
/// Whoever retired it closes it straight away: it was replaced because
/// it was lost or suspect, so there is nothing to wait for. Leases still
/// holding it fail with a stale generation, which the monitor ignores.
pub struct RetiredConnection {
    generation: LinkGeneration,
    established: Arc<EstablishedConnection>,
}

impl RetiredConnection {
    pub(crate) fn new(generation: LinkGeneration, established: Arc<EstablishedConnection>) -> Self {
        Self {
            generation,
            established,
        }
    }

    pub fn generation(&self) -> LinkGeneration {
        self.generation
    }

    pub async fn close(self, close_timeout: Duration) -> CloseReport {
        match tokio::time::timeout(close_timeout, self.established.connection.close()).await {
            Ok(Ok(())) => CloseReport::Closed,
            Ok(Err(error)) => CloseReport::CloseFailed(error),
            Err(_) => CloseReport::Abandoned,
        }
    }
}

impl std::fmt::Debug for RetiredConnection {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RetiredConnection")
            .field("generation", &self.generation)
            .finish_non_exhaustive()
    }
}
