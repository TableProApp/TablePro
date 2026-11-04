use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use tablepro_core::{CallResource, DriverError, StopRequest};
use tokio::task::JoinHandle;
use tokio_postgres::Client;
use tokio_util::sync::CancellationToken;
use tokio_util::task::TaskTracker;
use tracing::debug;

use crate::cancel::PgStop;
use crate::physical::PgEndpoint;

/// A physical connection opened for one call and closed after it, for
/// reads that must never hold a pool slot.
pub(crate) struct Standalone {
    client: Option<Client>,
    driving: Option<JoinHandle<()>>,
    abandon: Arc<AtomicBool>,
    conforming: bool,
}

impl Standalone {
    pub(crate) fn new() -> Self {
        Self {
            client: None,
            driving: None,
            abandon: Arc::new(AtomicBool::new(false)),
            conforming: true,
        }
    }

    /// Open the connection inside the call, so its deadline and cancel
    /// cover the login too.
    pub(crate) async fn open(
        &mut self,
        endpoint: &PgEndpoint,
        tracker: &TaskTracker,
        request: &StopRequest,
        stop: &PgStop,
    ) -> Result<(), DriverError> {
        let never = CancellationToken::new();
        let opened = tokio::select! {
            biased;
            () = request.requested() => return Err(stop.interrupted(request)),
            opened = endpoint.open(&never) => opened?,
        };
        let (client, connection) = opened;
        self.conforming = connection.parameter("standard_conforming_strings") != Some("off");
        stop.arm(client.cancel_token());
        self.driving = Some(tracker.spawn(async move {
            if let Err(error) = connection.await {
                debug!(%error, "a standalone PostgreSQL connection ended");
            }
        }));
        self.client = Some(client);
        if request.is_requested() {
            return Err(stop.interrupted(request));
        }
        Ok(())
    }

    /// The session's `standard_conforming_strings` as the login reported
    /// it.
    pub(crate) fn standard_conforming_strings(&self) -> bool {
        self.conforming
    }

    pub(crate) fn client(&self) -> Result<&Client, DriverError> {
        self.client
            .as_ref()
            .ok_or_else(|| DriverError::Protocol("the call holds no connection".to_owned()))
    }
}

impl CallResource for Standalone {
    fn abandon_flag(&self) -> Arc<AtomicBool> {
        self.abandon.clone()
    }

    fn discard(mut self) {
        self.client = None;
        if let Some(driving) = self.driving.take() {
            driving.abort();
        }
    }
}

impl Drop for Standalone {
    fn drop(&mut self) {
        // Dropping the client lets the connection send Terminate and end
        // on its own; one whose call was abandoned is cut off instead.
        self.client = None;
        if self.abandon.load(Ordering::SeqCst)
            && let Some(driving) = self.driving.take()
        {
            driving.abort();
        }
    }
}
