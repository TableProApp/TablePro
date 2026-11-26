use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use tokio::sync::Notify;

use crate::api::error::SyncError;

// A provider stop: sync turned off, another provider chosen, or a policy that stops it (P1-M4). A pass checks it before
// every store write and every state commit, so once it is set the pass writes no store and commits nothing more.
#[derive(Debug, Clone, Default)]
pub struct StopSignal(Arc<Inner>);

#[derive(Debug, Default)]
struct Inner {
    stopped: AtomicBool,
    changed: Notify,
}

impl StopSignal {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn stop(&self) {
        self.0.stopped.store(true, Ordering::SeqCst);
        self.0.changed.notify_waiters();
    }

    // The provider runs again; a pass that ended on the stop is not resumed, the next one starts afresh.
    pub fn resume(&self) {
        self.0.stopped.store(false, Ordering::SeqCst);
        self.0.changed.notify_waiters();
    }

    pub fn is_stopped(&self) -> bool {
        self.0.stopped.load(Ordering::SeqCst)
    }

    pub fn check(&self) -> Result<(), SyncError> {
        if self.is_stopped() {
            Err(SyncError::Cancelled)
        } else {
            Ok(())
        }
    }

    pub async fn stopped(&self) {
        loop {
            let changed = self.0.changed.notified();
            if self.is_stopped() {
                return;
            }
            changed.await;
        }
    }
}
