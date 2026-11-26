// What the engine does the same way for both providers (0054, The engine): the diff that decides what goes up, the
// settle step that meets a pulled copy, pushes split to the server's limits, the provider stop, backoff and the
// scheduler. `service` runs the TablePro Sync pass over them.

mod backoff;
mod batch;
mod diff;
mod hooks;
mod scheduler;
mod settle;
mod stop;

use std::sync::Arc;

pub use backoff::{Backoff, retry_after_ms, retryable};
pub use batch::{change_bytes, split};
pub use diff::{Diffed, Pending, PendingOp, diff};
pub use hooks::{EngineEvents, EngineHooks};
pub use scheduler::{Journal, JournalEntry, JournalIds, Pass, SchedulerHandle, Wake, spawn};
pub use settle::{Judgement, Settled, base_of, mode, settle};
pub use stop::StopSignal;

use crate::api::adapter::RecordAdapter;
use crate::api::ids::ScopeName;

// The adapters whose records sync in a scope. Team scopes come and go with the scopes body, so the host answers for
// any scope it is asked about.
pub trait AdapterSet: Send + Sync {
    fn adapters(&self, scope: ScopeName) -> Vec<Arc<dyn RecordAdapter>>;
}

impl AdapterSet for Vec<(ScopeName, Arc<dyn RecordAdapter>)> {
    fn adapters(&self, scope: ScopeName) -> Vec<Arc<dyn RecordAdapter>> {
        self.iter()
            .filter(|(held, _)| *held == scope)
            .map(|(_, adapter)| Arc::clone(adapter))
            .collect()
    }
}

pub trait Clock: Send + Sync {
    fn now_ms(&self) -> i64;
}

#[derive(Debug, Clone, Copy, Default)]
pub struct SystemClock;

impl Clock for SystemClock {
    fn now_ms(&self) -> i64 {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default();
        i64::try_from(now.as_millis()).unwrap_or(i64::MAX)
    }
}
