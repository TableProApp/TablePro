use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use deadpool_postgres::{Object, Pool, Timeouts};
use tablepro_core::{CallResource, DriverError, StopRequest};
use tokio_postgres::Client;

use crate::cancel::PgStop;
use crate::errors::map_pool_error;

/// The pooled connection one workspace call runs on.
///
/// It starts empty and is filled inside the call, so the call's deadline
/// and cancel cover the wait for a slot too. deadpool's own recycle only
/// runs `""`, which succeeds inside a half-finished transaction, so any
/// connection whose flight did not end with an acknowledged COMMIT or
/// ROLLBACK is taken out of the pool instead of returned to it.
pub(crate) struct PgCall {
    object: Option<Object>,
    abandon: Arc<AtomicBool>,
}

impl PgCall {
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
        pool: &Pool,
        timeouts: &Timeouts,
        request: &StopRequest,
        stop: &PgStop,
    ) -> Result<(), DriverError> {
        let object = tokio::select! {
            biased;
            () = request.requested() => return Err(stop.interrupted(request)),
            object = pool.timeout_get(timeouts) => object.map_err(|error| map_pool_error(&error))?,
        };
        stop.arm(object.cancel_token());
        self.object = Some(object);
        // The stop may have been asked for between the slot arriving and
        // the cancel token being armed, and then no cancel request went
        // out; nothing has been sent yet, so stopping here is exact.
        if request.is_requested() {
            return Err(stop.interrupted(request));
        }
        Ok(())
    }

    pub(crate) fn client(&self) -> Result<&Client, DriverError> {
        self.object
            .as_deref()
            .map(|wrapper| &**wrapper)
            .ok_or_else(|| DriverError::Protocol("the call holds no connection".to_owned()))
    }

    /// The flight did not reach an acknowledged end, so the connection
    /// may still be inside a transaction.
    pub(crate) fn taint(&self) {
        self.abandon.store(true, Ordering::SeqCst);
    }

    fn take(&mut self) {
        if let Some(object) = self.object.take() {
            drop(Object::take(object));
        }
    }
}

impl CallResource for PgCall {
    fn abandon_flag(&self) -> Arc<AtomicBool> {
        self.abandon.clone()
    }

    fn discard(mut self) {
        self.take();
    }
}

impl Drop for PgCall {
    fn drop(&mut self) {
        if self.abandon.load(Ordering::SeqCst) {
            self.take();
        }
    }
}
