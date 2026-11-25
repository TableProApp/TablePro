use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use tablepro_records::Kind;
use tokio::sync::Notify;
use tokio::task::JoinHandle;

use super::backoff::{Backoff, retry_after_ms, retryable};
use super::stop::StopSignal;
use crate::api::control::PassReason;
use crate::api::error::SyncError;

// One provider's pass over its state file, which the scheduler runs one at a time (0054, Scheduling).
#[async_trait]
pub trait Pass: Send + Sync {
    async fn pass(&self, why: PassReason) -> Result<(), SyncError>;

    // The service's poll interval, or iCloud's fallback timer.
    fn poll_interval(&self) -> Duration;

    // The scheduler backs off for this long before the next try, or stopped backing off.
    fn waiting(&self, retry_in_ms: Option<u64>);
}

// What a store's write path tells once a write landed (0060): the kind, the ids the commit wrote and those it deleted.
// The engine only takes it as a reason for a pass; the diff decides what goes up.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JournalEntry {
    pub kind: Kind,
    pub written: Vec<String>,
    pub deleted: Vec<String>,
}

// Asks for a pass soon. A wake while a pass runs is kept, so that pass is followed by one more.
#[derive(Debug, Clone, Default)]
pub struct Wake(Arc<WakeInner>);

#[derive(Debug, Default)]
struct WakeInner {
    notify: Notify,
    reasons: Mutex<Vec<PassReason>>,
}

impl Wake {
    pub fn new() -> Self {
        Self::default()
    }

    fn reasons(&self) -> MutexGuard<'_, Vec<PassReason>> {
        self.0.reasons.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub fn pass_soon(&self, why: PassReason) {
        self.reasons().push(why);
        self.0.notify.notify_one();
    }

    pub fn journal(&self, entries: &[JournalEntry]) {
        if entries
            .iter()
            .any(|entry| !entry.written.is_empty() || !entry.deleted.is_empty())
        {
            self.pass_soon(PassReason::Journal);
        }
    }

    async fn next(&self) -> PassReason {
        loop {
            if let Some(why) = self.take() {
                return why;
            }
            self.0.notify.notified().await;
        }
    }

    // The first reason asked for since the last take; the others it covers.
    fn take(&self) -> Option<PassReason> {
        let mut reasons = self.reasons();
        let first = reasons.first().copied();
        reasons.clear();
        first
    }
}

pub struct SchedulerHandle {
    task: JoinHandle<()>,
}

impl Drop for SchedulerHandle {
    fn drop(&mut self) {
        self.task.abort();
    }
}

// Runs `pass` on a wake, on the poll interval, and after a failure once its backoff has passed. A stop ends the pass
// in flight and holds the next until the provider runs again.
pub fn spawn(pass: Arc<dyn Pass>, wake: Wake, stop: StopSignal, backoff: Backoff) -> SchedulerHandle {
    SchedulerHandle {
        task: tokio::spawn(run(pass, wake, stop, backoff)),
    }
}

async fn run(pass: Arc<dyn Pass>, wake: Wake, stop: StopSignal, mut backoff: Backoff) {
    loop {
        let why = tokio::select! {
            why = wake.next() => why,
            () = tokio::time::sleep(pass.poll_interval()) => PassReason::Poll,
        };
        if stop.is_stopped() {
            continue;
        }
        match pass.pass(why).await {
            Ok(()) => backoff.succeeded(),
            Err(error) if retryable(&error) => {
                let wait = backoff.failed(retry_after_ms(&error));
                pass.waiting(Some(wait));
                tokio::select! {
                    () = tokio::time::sleep(Duration::from_millis(wait)) => {}
                    () = stop.stopped() => {}
                }
                pass.waiting(None);
                wake.pass_soon(why);
            }
            Err(error) => {
                tracing::debug!(code = error.code(), "sync pass ended; waiting for the next trigger");
            }
        }
    }
}
