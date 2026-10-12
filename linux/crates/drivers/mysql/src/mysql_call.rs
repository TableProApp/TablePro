use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use deadpool::managed::{Object, Timeouts};
use sqlx::mysql::MySqlConnection;
use tablepro_core::{CallResource, DriverError, StopRequest};

use crate::cancel::{MySqlStop, interrupted};
use crate::errors::map_pool_error;
use crate::flavour::MySqlFlavour;
use crate::mysql_manager::{MysqlManager, MysqlPool};

/// The pooled connection one workspace call runs on.
///
/// It starts empty and is filled inside the call, so the call's deadline
/// and cancel cover the wait for a slot too. A connection whose call did
/// not end cleanly, one a KILL may still be chasing or one left inside a
/// transaction, is taken out of the pool instead of returned to it.
pub(crate) struct MysqlCall {
    object: Option<Object<MysqlManager>>,
    abandon: Arc<AtomicBool>,
}

impl MysqlCall {
    pub(crate) fn new() -> Self {
        Self {
            object: None,
            abandon: Arc::new(AtomicBool::new(false)),
        }
    }

    /// Take a slot from the pool, giving up as soon as the call is
    /// stopped. Once the slot is held, the stop can reach the server.
    pub(crate) async fn acquire(
        &mut self,
        pool: &MysqlPool,
        timeouts: &Timeouts,
        request: &StopRequest,
        stop: &MySqlStop,
    ) -> Result<(), DriverError> {
        let object = tokio::select! {
            biased;
            () = request.requested() => return Err(interrupted(request)),
            object = pool.timeout_get(timeouts) => object.map_err(|error| map_pool_error(&error))?,
        };
        stop.arm(object.connection_id);
        self.object = Some(object);
        // The stop may have been asked for between the slot arriving and
        // the stop being armed, and then a KILL may be on its way to an
        // idle connection; nothing of this call ran, so it ends here and
        // the connection goes.
        if request.is_requested() {
            self.taint();
            return Err(interrupted(request));
        }
        Ok(())
    }

    pub(crate) fn connection(&mut self) -> Result<(&mut MySqlConnection, MySqlFlavour), DriverError> {
        let object = self
            .object
            .as_mut()
            .ok_or_else(|| DriverError::Protocol("the call holds no connection".to_owned()))?;
        let flavour = object.flavour;
        Ok((&mut object.connection, flavour))
    }

    /// The call did not reach a clean end, so the connection is not
    /// handed to the next caller.
    pub(crate) fn taint(&self) {
        self.abandon.store(true, Ordering::SeqCst);
    }

    /// What taints the call while its connection is borrowed.
    pub(crate) fn tainter(&self) -> Tainter {
        Tainter(self.abandon.clone())
    }

    fn take(&mut self) {
        if let Some(object) = self.object.take() {
            drop(Object::take(object));
        }
    }
}

impl CallResource for MysqlCall {
    fn abandon_flag(&self) -> Arc<AtomicBool> {
        self.abandon.clone()
    }

    fn discard(mut self) {
        self.take();
    }
}

impl Drop for MysqlCall {
    fn drop(&mut self) {
        if self.abandon.load(Ordering::SeqCst) {
            self.take();
        }
    }
}

/// Taints a call from code that holds its connection.
#[derive(Debug, Clone)]
pub(crate) struct Tainter(Arc<AtomicBool>);

impl Tainter {
    pub(crate) fn taint(&self) {
        self.0.store(true, Ordering::SeqCst);
    }
}
