use std::sync::Arc;
use std::sync::atomic::AtomicBool;

use sqlx::mysql::MySqlConnection;
use tablepro_core::{CallResource, DriverError, StopRequest};
use tokio_util::sync::CancellationToken;

use crate::cancel::{MySqlStop, interrupted};
use crate::flavour::MySqlFlavour;
use crate::physical::{MySqlPhysical, MysqlEndpoint, SessionKind};
use crate::session_statements::SessionLimits;

/// A login opened for one call and closed after it, for reads that must
/// never hold a pool slot. Nothing else ever runs on it, so a KILL that
/// arrives late has nothing to hit.
pub(crate) struct Standalone {
    physical: Option<MySqlPhysical>,
    abandon: Arc<AtomicBool>,
}

impl Standalone {
    pub(crate) fn new() -> Self {
        Self {
            physical: None,
            abandon: Arc::new(AtomicBool::new(false)),
        }
    }

    /// Log in inside the call, so its deadline and cancel cover the
    /// login too.
    pub(crate) async fn open(
        &mut self,
        endpoint: &MysqlEndpoint,
        limits: &SessionLimits,
        request: &StopRequest,
        stop: &MySqlStop,
    ) -> Result<(), DriverError> {
        let never = CancellationToken::new();
        let physical = tokio::select! {
            biased;
            () = request.requested() => return Err(interrupted(request)),
            opened = endpoint.connect_physical(SessionKind::Workspace, limits, &never) => opened?,
        };
        stop.arm(physical.connection_id);
        self.physical = Some(physical);
        if request.is_requested() {
            return Err(interrupted(request));
        }
        Ok(())
    }

    pub(crate) fn connection(&mut self) -> Result<(&mut MySqlConnection, MySqlFlavour), DriverError> {
        let physical = self
            .physical
            .as_mut()
            .ok_or_else(|| DriverError::Protocol("the call holds no connection".to_owned()))?;
        let flavour = physical.flavour;
        Ok((&mut physical.connection, flavour))
    }
}

impl CallResource for Standalone {
    fn abandon_flag(&self) -> Arc<AtomicBool> {
        self.abandon.clone()
    }

    fn discard(mut self) {
        self.physical = None;
    }
}
