use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use tokio::sync::watch;
use tokio_util::sync::CancellationToken;

use super::{RunEvent, RunListener, RunOutcome, TransactionStateTag};
use crate::results::ResultStore;

// A drain clears the pending wake before it takes the queue, so no event is lost and a busy app is woken once.
pub(crate) struct RunState {
    listener: Box<dyn RunListener>,
    queue: Mutex<Queue>,
    wake_pending: AtomicBool,
    outcome: watch::Sender<Option<RunOutcome>>,
    pub(crate) cancel: CancellationToken,
}

#[derive(Default)]
struct Queue {
    events: Vec<RunEvent>,
    sets: Vec<Arc<ResultStore>>,
}

impl RunState {
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
        queue.sets.push(store);
        u32::try_from(queue.sets.len() - 1).unwrap_or(u32::MAX)
    }

    pub(crate) fn set(&self, index: u32) -> Option<Arc<ResultStore>> {
        self.lock().sets.get(usize::try_from(index).ok()?).cloned()
    }

    // Called on a runtime thread.
    pub(crate) fn post(&self, event: RunEvent) {
        self.enqueue(event);
        self.wake();
    }

    fn enqueue(&self, event: RunEvent) {
        let mut queue = self.lock();
        match (queue.events.last_mut(), &event) {
            (
                Some(RunEvent::RowsAppended {
                    set_index: queued,
                    row_count,
                }),
                RunEvent::RowsAppended {
                    set_index,
                    row_count: latest,
                },
            ) if queued == set_index => *row_count = *latest,
            _ => queue.events.push(event),
        }
    }

    // Outside the lock. UniFFI panics when the app's callback throws, which loses this wake and not the run.
    fn wake(&self) {
        if self.wake_pending.swap(true, Ordering::AcqRel) {
            return;
        }
        if catch_unwind(AssertUnwindSafe(|| self.listener.events_pending())).is_err() {
            tracing::warn!("the app's run listener failed, so it was not told about waiting events");
        }
    }

    pub(crate) fn drain(&self) -> Vec<RunEvent> {
        self.wake_pending.store(false, Ordering::Release);
        std::mem::take(&mut self.lock().events)
    }

    // Every set holds what it will, and `Finished` is the last event.
    pub(crate) fn finish(&self, outcome: RunOutcome, transaction: TransactionStateTag) {
        let sets = self.lock().sets.clone();
        sets.iter().for_each(|store| store.finish());
        self.enqueue(RunEvent::Finished {
            outcome: outcome.clone(),
            transaction,
        });
        // Before the wake, so `QueryRun::outcome` returns whatever the listener does.
        self.outcome.send_replace(Some(outcome));
        self.wake();
    }

    pub(crate) fn outcome(&self) -> watch::Receiver<Option<RunOutcome>> {
        self.outcome.subscribe()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Queue> {
        self.queue.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

#[cfg(test)]
mod tests {
    use std::sync::OnceLock;
    use std::sync::atomic::AtomicUsize;

    use super::*;

    #[derive(Clone, Default)]
    struct CountingListener(Arc<AtomicUsize>);

    impl RunListener for CountingListener {
        fn events_pending(&self) {
            self.0.fetch_add(1, Ordering::SeqCst);
        }
    }

    fn rows(set_index: u32, row_count: u64) -> RunEvent {
        RunEvent::RowsAppended { set_index, row_count }
    }

    #[test]
    fn a_busy_app_is_woken_once_and_reads_the_latest_count() {
        let listener = CountingListener::default();
        let state = RunState::new(Box::new(listener.clone()));

        for count in 1..=100 {
            state.post(rows(0, count * 1_000));
        }

        assert_eq!(listener.0.load(Ordering::SeqCst), 1);
        assert_eq!(state.drain(), [rows(0, 100_000)]);
    }

    #[test]
    fn an_event_after_a_drain_wakes_the_app_again() {
        let listener = CountingListener::default();
        let state = RunState::new(Box::new(listener.clone()));

        state.post(rows(0, 1));
        state.drain();
        state.post(rows(0, 2));
        state.post(rows(1, 3));

        assert_eq!(listener.0.load(Ordering::SeqCst), 2);
        assert_eq!(state.drain(), [rows(0, 2), rows(1, 3)]);
        assert!(state.drain().is_empty());
    }

    #[test]
    fn finish_is_the_last_event_and_sets_the_outcome() {
        let state = RunState::new(Box::new(CountingListener::default()));
        let outcome = state.outcome();

        state.post(rows(0, 5));
        state.finish(RunOutcome::Cancelled, TransactionStateTag::InTransaction);

        assert_eq!(
            state.drain(),
            [
                rows(0, 5),
                RunEvent::Finished {
                    outcome: RunOutcome::Cancelled,
                    transaction: TransactionStateTag::InTransaction,
                }
            ]
        );
        assert_eq!(*outcome.borrow(), Some(RunOutcome::Cancelled));
    }

    // What UniFFI does when the app's callback throws: the call panics on the Rust side.
    #[derive(Clone, Default)]
    struct ThrowingListener {
        calls: Arc<AtomicUsize>,
        failures: usize,
    }

    impl RunListener for ThrowingListener {
        fn events_pending(&self) {
            if self.calls.fetch_add(1, Ordering::SeqCst) < self.failures {
                panic!("Callback interface failure: the dispatcher is shut down");
            }
        }
    }

    #[test]
    fn a_listener_that_throws_at_the_end_still_ends_the_run() {
        let state = RunState::new(Box::new(ThrowingListener {
            failures: usize::MAX,
            ..ThrowingListener::default()
        }));
        let outcome = state.outcome();

        state.finish(RunOutcome::Cancelled, TransactionStateTag::Idle);

        assert_eq!(*outcome.borrow(), Some(RunOutcome::Cancelled));
        assert_eq!(
            state.drain(),
            [RunEvent::Finished {
                outcome: RunOutcome::Cancelled,
                transaction: TransactionStateTag::Idle,
            }]
        );
    }

    #[test]
    fn a_listener_that_throws_loses_one_wake_and_no_events() {
        let listener = ThrowingListener {
            failures: 1,
            ..ThrowingListener::default()
        };
        let state = RunState::new(Box::new(listener.clone()));

        state.post(rows(0, 1));
        state.post(rows(0, 2));
        assert_eq!(listener.calls.load(Ordering::SeqCst), 1);
        assert_eq!(state.drain(), [rows(0, 2)]);

        state.post(rows(0, 3));
        assert_eq!(listener.calls.load(Ordering::SeqCst), 2);
        assert_eq!(state.drain(), [rows(0, 3)]);
    }

    #[derive(Clone, Default)]
    struct OutcomeAtWake {
        outcome: Arc<OnceLock<watch::Receiver<Option<RunOutcome>>>>,
        seen: Arc<Mutex<Vec<Option<RunOutcome>>>>,
    }

    impl RunListener for OutcomeAtWake {
        fn events_pending(&self) {
            let outcome = self.outcome.get().and_then(|outcome| outcome.borrow().clone());
            self.seen.lock().unwrap().push(outcome);
        }
    }

    #[test]
    fn the_outcome_is_set_before_the_last_wake() {
        let listener = OutcomeAtWake::default();
        let state = RunState::new(Box::new(listener.clone()));
        listener.outcome.set(state.outcome()).unwrap();

        state.finish(RunOutcome::Cancelled, TransactionStateTag::Idle);

        assert_eq!(*listener.seen.lock().unwrap(), [Some(RunOutcome::Cancelled)]);
    }
}
