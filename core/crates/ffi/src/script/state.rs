use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError, Weak};

use tokio::sync::watch;
use tokio_util::sync::CancellationToken;

use super::events::{ScriptRunEvent, ScriptRunSummary};
use crate::results::ResultStore;
use crate::run::RunListener;

// A drain clears the pending wake before it takes the queue, so no event
// is lost and a busy app is woken once. The sets are the same slots a
// single run keeps (`run::run_state`), one store per result set.
pub(crate) struct ScriptState {
    listener: Box<dyn RunListener>,
    queue: Mutex<Queue>,
    wake_pending: AtomicBool,
    outcome: watch::Sender<Option<ScriptRunSummary>>,
    pub(crate) cancel: CancellationToken,
}

#[derive(Default)]
struct Queue {
    events: Vec<ScriptRunEvent>,
    // A released set keeps its slot, so every later set keeps its index.
    sets: Vec<Slot>,
}

enum Slot {
    Held(Arc<ResultStore>),
    // Weak, so a `ResultSet` the app still holds is finished with the run.
    Released(Weak<ResultStore>),
}

impl ScriptState {
    pub(crate) fn new(listener: Box<dyn RunListener>) -> Self {
        Self {
            listener,
            queue: Mutex::new(Queue::default()),
            wake_pending: AtomicBool::new(false),
            outcome: watch::channel(None).0,
            cancel: CancellationToken::new(),
        }
    }

    pub(crate) fn add_set(&self, store: Arc<ResultStore>) -> u32 {
        let mut queue = self.lock();
        queue.sets.push(Slot::Held(store));
        u32::try_from(queue.sets.len() - 1).unwrap_or(u32::MAX)
    }

    pub(crate) fn set(&self, index: u32) -> Option<Arc<ResultStore>> {
        match self.lock().sets.get(usize::try_from(index).ok()?)? {
            Slot::Held(store) => Some(store.clone()),
            Slot::Released(_) => None,
        }
    }

    pub(crate) fn release_set(&self, index: u32) {
        let Ok(index) = usize::try_from(index) else {
            return;
        };
        let released = {
            let mut queue = self.lock();
            let Some(slot) = queue.sets.get_mut(index) else {
                return;
            };
            let Slot::Held(store) = slot else {
                return;
            };
            let weak = Arc::downgrade(store);
            std::mem::replace(slot, Slot::Released(weak))
        };
        // Outside the lock: freeing a large set's rows takes a while.
        drop(released);
    }

    // Called on a runtime thread.
    pub(crate) fn post(&self, event: ScriptRunEvent) {
        self.lock().events.push(event);
        self.wake();
    }

    // Outside the lock. UniFFI panics when the app's callback throws,
    // which loses this wake and not the run.
    fn wake(&self) {
        if self.wake_pending.swap(true, Ordering::AcqRel) {
            return;
        }
        if catch_unwind(AssertUnwindSafe(|| self.listener.events_pending())).is_err() {
            tracing::warn!("the app's run listener failed, so it was not told about waiting events");
        }
    }

    pub(crate) fn drain(&self) -> Vec<ScriptRunEvent> {
        self.wake_pending.store(false, Ordering::Release);
        std::mem::take(&mut self.lock().events)
    }

    // Every set holds what it will, and `Finished` is the last event.
    pub(crate) fn finish(&self, summary: ScriptRunSummary, finished: ScriptRunEvent) {
        let sets: Vec<_> = self
            .lock()
            .sets
            .iter()
            .filter_map(|slot| match slot {
                Slot::Held(store) => Some(store.clone()),
                Slot::Released(store) => store.upgrade(),
            })
            .collect();
        sets.iter().for_each(|store| store.finish_with_run());
        self.lock().events.push(finished);
        // Before the wake, so `ScriptRun::outcome` returns whatever the listener does.
        self.outcome.send_replace(Some(summary));
        self.wake();
    }

    pub(crate) fn outcome(&self) -> watch::Receiver<Option<ScriptRunSummary>> {
        self.outcome.subscribe()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Queue> {
        self.queue.lock().unwrap_or_else(PoisonError::into_inner)
    }
}
