use std::sync::Arc;
use std::sync::atomic::AtomicBool;

use tablepro_core::{CallResource, DriverError, StopRequest};
use tokio_util::sync::CancellationToken;

use crate::cancel::unconfirmed_stop;
use crate::endpoint::MssqlEndpoint;
use crate::physical::MssqlLink;

/// A physical connection opened for one call and closed after it, for
/// reads that must never hold a pool slot. Dropping it closes the
/// socket, which is all a connection used once needs.
pub(crate) struct Standalone {
    link: Option<MssqlLink>,
    abandon: Arc<AtomicBool>,
}

impl Standalone {
    pub(crate) fn new() -> Self {
        Self {
            link: None,
            abandon: Arc::new(AtomicBool::new(false)),
        }
    }

    /// Open the connection inside the call, so its deadline and cancel
    /// cover the login too.
    pub(crate) async fn open(&mut self, endpoint: &MssqlEndpoint, request: &StopRequest) -> Result<(), DriverError> {
        let never = CancellationToken::new();
        let link = tokio::select! {
            biased;
            () = request.requested() => return Err(unconfirmed_stop(request)),
            opened = endpoint.open_workspace(&never) => opened?,
        };
        self.link = Some(link);
        Ok(())
    }

    pub(crate) fn link(&mut self) -> Result<&mut MssqlLink, DriverError> {
        self.link
            .as_mut()
            .ok_or_else(|| DriverError::Protocol("the call holds no connection".to_owned()))
    }
}

impl CallResource for Standalone {
    fn abandon_flag(&self) -> Arc<AtomicBool> {
        self.abandon.clone()
    }

    fn discard(mut self) {
        self.link = None;
    }
}
