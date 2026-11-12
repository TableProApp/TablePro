use std::sync::Arc;

use tablepro_session::runtime::Tasks;

use super::{RunEvent, RunOutcome, RunState};
use crate::error::CoreError;
use crate::results::ResultSet;
use crate::runtime::on_runtime;

/// The app's handle on a running statement. Dropping it stops the run.
#[derive(uniffi::Object)]
pub struct QueryRun {
    state: Arc<RunState>,
    tasks: Tasks,
}

/// Told that events are waiting, on a runtime thread. It only schedules
/// a drain on the app's own thread: no work, and nothing that blocks.
#[uniffi::export(callback_interface)]
pub trait RunListener: Send + Sync {
    fn events_pending(&self);
}

impl QueryRun {
    pub(crate) fn new(state: Arc<RunState>, tasks: Tasks) -> Self {
        Self { state, tasks }
    }
}

#[uniffi::export]
impl QueryRun {
    /// Every event since the last drain, which also acknowledges the wake.
    pub fn drain_events(&self) -> Vec<RunEvent> {
        self.state.drain()
    }

    pub fn result_set(&self, index: u32) -> Option<Arc<ResultSet>> {
        self.state
            .set(index)
            .map(|store| Arc::new(ResultSet::new(index, store)))
    }

    /// The app shows this set no more, so the run lets go of its rows; they go once no `ResultSet` holds them.
    pub fn release_set(&self, index: u32) {
        self.state.release_set(index);
    }

    pub fn cancel(&self) {
        self.state.cancel.cancel();
    }

    /// Waits for the run to end. Dropping the wait leaves the run going.
    pub async fn outcome(&self) -> Result<RunOutcome, CoreError> {
        let mut outcome = self.state.outcome();
        on_runtime(&self.tasks, async move {
            let ended = outcome
                .wait_for(Option::is_some)
                .await
                .map_err(|_| CoreError::failed("ffi.run_lost", "the run ended without an outcome"))?;
            ended
                .clone()
                .ok_or_else(|| CoreError::failed("ffi.run_lost", "the run ended without an outcome"))
        })
        .await
    }
}

impl Drop for QueryRun {
    fn drop(&mut self) {
        self.state.cancel.cancel();
    }
}

impl std::fmt::Debug for QueryRun {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("QueryRun").finish_non_exhaustive()
    }
}
