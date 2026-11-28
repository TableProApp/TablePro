// What the engine does the same way for both providers (0054, The engine): the diff that decides what goes up, the
// settle step that meets a pulled copy, pushes split to the server's limits, the provider stop, backoff and the
// scheduler. `service` runs the TablePro Sync pass over them.

mod backoff;
mod batch;
mod diff;
mod held;
mod hooks;
mod scheduler;
mod settle;
mod stop;

use std::sync::Arc;

pub use backoff::{Backoff, retry_after_ms, retryable};
pub use batch::{change_bytes, split};
pub(crate) use diff::owner;
pub use diff::{
    Diffed, KeptOff, Pending, PendingOp, diff, forget_kept_off, hold_kept_off, hold_left_behind, kept_off_connections,
    left_behind_digest,
};
pub use held::Waiting;
pub use hooks::{EngineEvents, EngineHooks};
pub use scheduler::{Journal, JournalEntry, JournalIds, JournalObserver, Pass, SchedulerHandle, Wake, spawn};
pub use settle::{Judgement, Settled, base_of, key_base, mode, settle, settle_moved};
pub use stop::{Fence, StopSignal};

use crate::api::adapter::RecordAdapter;
use crate::api::ids::ScopeName;

// The store adapters, one per kind. Each holds its kind's records of every scope the kind syncs in and is asked for one
// scope at a time (0054, Adapters).
#[derive(Clone, Default)]
pub struct Adapters {
    all: Vec<Arc<dyn RecordAdapter>>,
    teams_only: bool,
}

impl Adapters {
    pub fn new(adapters: Vec<Arc<dyn RecordAdapter>>) -> Self {
        Self {
            all: adapters,
            teams_only: false,
        }
    }

    // The same stores asked for their team scopes' records only, as a device whose personal provider is not TablePro
    // Sync keeps them (0054, Providers). An envelope store holds both, so the scope decides, not the kind.
    #[must_use]
    pub fn teams_only(&self) -> Self {
        Self {
            all: self.all.clone(),
            teams_only: true,
        }
    }

    pub fn in_scope(&self, scope: ScopeName) -> Vec<Arc<dyn RecordAdapter>> {
        if self.teams_only && !matches!(scope, ScopeName::Team(_)) {
            return Vec::new();
        }
        self.all
            .iter()
            .filter(|adapter| adapter.kind().scopes().contains(&scope.records_scope()) && adapter.serves(scope))
            .map(Arc::clone)
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
