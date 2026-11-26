use std::collections::{HashMap, HashSet};
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
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JournalEntry {
    pub kind: Kind,
    pub written: Vec<String>,
    pub deleted: Vec<String>,
}

pub type JournalIds = HashMap<Kind, HashSet<String>>;

// The records the journal named since the last pass took them. A pass a journal signal started diffs only those, so
// no signal diffs a whole store; any other pass diffs every store, so a missed signal only delays a push (0060).
#[derive(Debug, Clone, Default)]
pub struct Journal {
    ids: Arc<Mutex<JournalIds>>,
    wake: Wake,
}

impl Journal {
    pub fn new(wake: Wake) -> Self {
        Self {
            ids: Arc::default(),
            wake,
        }
    }

    fn ids(&self) -> MutexGuard<'_, JournalIds> {
        self.ids.lock().unwrap_or_else(PoisonError::into_inner)
    }

    // From the store's write path, after the write landed: returns at once.
    pub fn changed(&self, entries: &[JournalEntry]) {
        let mut named = false;
        let mut ids = self.ids();
        for entry in entries {
            let held = ids.entry(entry.kind).or_default();
            for id in entry.written.iter().chain(&entry.deleted) {
                named |= held.insert(id.clone());
            }
        }
        drop(ids);
        if named {
            self.wake.pass_soon(PassReason::Journal);
        }
    }

    pub fn take(&self) -> JournalIds {
        std::mem::take(&mut *self.ids())
    }

    // A pass that failed gives back what it took, for the next one.
    pub fn give_back(&self, taken: JournalIds) {
        let mut ids = self.ids();
        for (kind, named) in taken {
            ids.entry(kind).or_default().extend(named);
        }
    }
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

    async fn next(&self) -> PassReason {
        loop {
            if let Some(why) = self.take() {
                return why;
            }
            self.0.notify.notified().await;
        }
    }

    // One pass covers every reason asked for since the last take. It is a journal pass only when nothing else asked,
    // since a journal pass diffs only the records the journal named.
    fn take(&self) -> Option<PassReason> {
        let mut reasons = self.reasons();
        let why = reasons
            .iter()
            .copied()
            .find(|why| *why != PassReason::Journal)
            .or_else(|| reasons.first().copied());
        reasons.clear();
        why
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

// The poll falls due a poll interval after the last full pass, so journal passes, which diff only what they were told
// of, never put it off.
async fn run(pass: Arc<dyn Pass>, wake: Wake, stop: StopSignal, mut backoff: Backoff) {
    let mut poll_at = tokio::time::Instant::now() + pass.poll_interval();
    loop {
        let why = tokio::select! {
            why = wake.next() => why,
            () = tokio::time::sleep_until(poll_at) => PassReason::Poll,
        };
        if why != PassReason::Journal {
            poll_at = tokio::time::Instant::now() + pass.poll_interval();
        }
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
