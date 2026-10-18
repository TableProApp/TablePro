use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use deadpool::managed::{Object, Timeouts};
use tablepro_core::{CallResource, DriverError, StopRequest};

use crate::cancel::{MssqlStop, unconfirmed_stop};
use crate::errors::map_pool_error;
use crate::in_band_request::{StopPolicy, Watch, conclude};
use crate::mssql_manager::{MssqlManager, MssqlPool};
use crate::physical::MssqlLink;
use crate::workspace_call::ReadOp;

/// The pooled connection one workspace call runs on.
///
/// It starts empty and is filled inside the call, so the call's deadline
/// and cancel cover the wait for a slot too. A connection whose request
/// did not end cleanly is taken out of the pool instead of returned.
pub(crate) struct MssqlPooled {
    object: Option<Object<MssqlManager>>,
    abandon: Arc<AtomicBool>,
}

impl MssqlPooled {
    pub(crate) fn new() -> Self {
        Self {
            object: None,
            abandon: Arc::new(AtomicBool::new(false)),
        }
    }

    /// Take a slot from the pool, giving up as soon as the call is
    /// stopped.
    pub(crate) async fn acquire(
        &mut self,
        pool: &MssqlPool,
        timeouts: &Timeouts,
        request: &StopRequest,
    ) -> Result<(), DriverError> {
        let object = tokio::select! {
            biased;
            () = request.requested() => return Err(unconfirmed_stop(request)),
            object = pool.timeout_get(timeouts) => object.map_err(map_pool_error)?,
        };
        self.object = Some(object);
        Ok(())
    }

    pub(crate) fn link(&mut self) -> Result<&mut MssqlLink, DriverError> {
        self.object
            .as_deref_mut()
            .ok_or_else(|| DriverError::Protocol("the call holds no connection".to_owned()))
    }

    /// Run one read on the held connection and settle it, however it
    /// ended.
    pub(crate) async fn read<T>(
        &mut self,
        request: &StopRequest,
        policy: StopPolicy,
        stop: &MssqlStop,
        op: ReadOp<T>,
    ) -> Result<T, DriverError> {
        let link = self.link()?;
        let watch = Watch::new(request.clone(), link.tally(), policy);
        let outcome = op(&mut link.client, &watch).await;
        let concluded = conclude(&mut link.client, &watch, outcome, stop, true).await;
        if !concluded.reusable {
            self.taint();
        }
        concluded.result
    }

    /// Ask the held connection one trivial question. A probe cut off by
    /// its deadline leaves the question on the wire, so the connection
    /// counts as abandoned until the answer is in.
    pub(crate) async fn ping(&mut self) -> Result<(), DriverError> {
        self.abandon.store(true, Ordering::SeqCst);
        self.link()?.batch("SELECT 1").await?;
        self.abandon.store(false, Ordering::SeqCst);
        Ok(())
    }

    /// Hold a connection taken from the pool outside a call.
    pub(crate) fn hold(object: Object<MssqlManager>) -> Self {
        Self {
            object: Some(object),
            abandon: Arc::new(AtomicBool::new(false)),
        }
    }

    /// The connection may be inside a transaction or a response, so it
    /// must not go back into the pool.
    pub(crate) fn taint(&self) {
        self.abandon.store(true, Ordering::SeqCst);
    }

    fn take(&mut self) {
        if let Some(object) = self.object.take() {
            drop(Object::take(object));
        }
    }
}

impl CallResource for MssqlPooled {
    fn abandon_flag(&self) -> Arc<AtomicBool> {
        self.abandon.clone()
    }

    fn discard(mut self) {
        self.take();
    }
}

impl Drop for MssqlPooled {
    fn drop(&mut self) {
        if self.abandon.load(Ordering::SeqCst) {
            self.take();
        }
    }
}
