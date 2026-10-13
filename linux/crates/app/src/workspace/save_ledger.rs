use std::cell::RefCell;
use std::collections::BTreeMap;
use std::future::Future;
use std::rc::Rc;

use futures::channel::oneshot;
use tablepro_core::WriteKind;
use tablepro_session::runtime::{HoldToken, ProcessHold};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use super::{CloseScope, SaveId, SaveTicket};

/// The saves a window has running, so closing it can wait for them or
/// stop them rather than poll.
///
/// Each running save holds the process, so quitting while one runs
/// still lets it settle and report.
#[derive(Default)]
pub struct SaveLedger {
    state: RefCell<LedgerState>,
    listeners: RefCell<Vec<Listener>>,
}

type Listener = Rc<dyn Fn(usize)>;

#[derive(Default)]
struct LedgerState {
    next: u64,
    entries: BTreeMap<SaveId, Entry>,
    waiters: Vec<(CloseScope, oneshot::Sender<()>)>,
}

struct Entry {
    tab: Uuid,
    kind: WriteKind,
    cancel: CancellationToken,
    _hold: HoldToken,
}

impl SaveLedger {
    pub fn new() -> Self {
        Self::default()
    }

    /// Record a save of `tab`, or `None` when one of the same kind is
    /// already running for it: a second would commit the same changes
    /// twice.
    pub fn begin(&self, hold: &dyn ProcessHold, tab: Uuid, kind: WriteKind) -> Option<SaveTicket> {
        let ticket = {
            let mut state = self.state.borrow_mut();
            if state
                .entries
                .values()
                .any(|entry| entry.tab == tab && entry.kind == kind)
            {
                return None;
            }
            state.next += 1;
            let id = SaveId::new(state.next);
            let cancel = CancellationToken::new();
            state.entries.insert(
                id,
                Entry {
                    tab,
                    kind,
                    cancel: cancel.clone(),
                    _hold: hold.acquire(),
                },
            );
            SaveTicket { id, cancel }
        };
        self.notify();
        Some(ticket)
    }

    /// The save ended. A second call for the same save does nothing and
    /// returns false.
    pub fn settle(&self, id: SaveId) -> bool {
        let (entry, woken) = {
            let mut state = self.state.borrow_mut();
            let Some(entry) = state.entries.remove(&id) else {
                return false;
            };
            let waiters = std::mem::take(&mut state.waiters);
            let (idle, waiting): (Vec<_>, Vec<_>) = waiters
                .into_iter()
                .partition(|(scope, _)| !state.entries.values().any(|entry| scope.covers(entry.tab)));
            state.waiters = waiting;
            (entry, idle)
        };
        // The hold goes only after the state is consistent, in case
        // dropping it ends the main loop.
        drop(entry);
        for (_, waiter) in woken {
            let _ = waiter.send(());
        }
        self.notify();
        true
    }

    pub fn in_flight(&self) -> usize {
        self.state.borrow().entries.len()
    }

    /// Saves running for the tabs `scope` covers.
    pub fn in_flight_in(&self, scope: CloseScope) -> usize {
        self.state
            .borrow()
            .entries
            .values()
            .filter(|entry| scope.covers(entry.tab))
            .count()
    }

    /// Resolves once no save `scope` covers is running.
    pub fn when_idle(&self, scope: CloseScope) -> impl Future<Output = ()> + use<> {
        let receiver = if self.in_flight_in(scope) == 0 {
            None
        } else {
            let (sender, receiver) = oneshot::channel();
            self.state.borrow_mut().waiters.push((scope, sender));
            Some(receiver)
        };
        async move {
            if let Some(receiver) = receiver {
                // A ledger dropped with saves running wakes nobody, and
                // a waiter that outlived it has nothing left to wait on.
                let _ = receiver.await;
            }
        }
    }

    /// Stop the saves `scope` covers. Each settles when its driver
    /// answers the cancel.
    pub fn cancel(&self, scope: CloseScope) {
        for entry in self.state.borrow().entries.values() {
            if scope.covers(entry.tab) {
                entry.cancel.cancel();
            }
        }
    }

    /// Call `listener` with the number of saves running whenever it
    /// changes.
    pub fn on_change(&self, listener: impl Fn(usize) + 'static) {
        self.listeners.borrow_mut().push(Rc::new(listener));
    }

    fn notify(&self) {
        let count = self.in_flight();
        let listeners: Vec<Listener> = self.listeners.borrow().clone();
        for listener in listeners {
            listener(count);
        }
    }
}

impl std::fmt::Debug for SaveLedger {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SaveLedger")
            .field("in_flight", &self.in_flight())
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;
    use std::pin::{Pin, pin};
    use std::task::{Context, Poll, Waker};

    use tablepro_session::runtime::CountingHold;

    use super::*;

    fn ready(future: impl Future<Output = ()>) -> bool {
        polled(pin!(future))
    }

    fn polled(future: Pin<&mut impl Future<Output = ()>>) -> bool {
        matches!(future.poll(&mut Context::from_waker(Waker::noop())), Poll::Ready(()))
    }

    #[test]
    fn settle_idempotent() {
        let ledger = SaveLedger::new();
        let hold = CountingHold::new();
        let changes = Rc::new(Cell::new(0));
        let seen = changes.clone();
        ledger.on_change(move |_| seen.set(seen.get() + 1));
        let ticket = ledger
            .begin(&hold, Uuid::new_v4(), WriteKind::RowChanges)
            .expect("a ticket");

        assert!(ledger.settle(ticket.id));
        assert!(!ledger.settle(ticket.id), "a second settle counted again");
        assert_eq!(ledger.in_flight(), 0);
        assert_eq!(changes.get(), 2, "a second settle reported a change");
    }

    #[test]
    fn when_idle_resolves_after_last_settle() {
        let ledger = SaveLedger::new();
        let hold = CountingHold::new();
        let first = ledger
            .begin(&hold, Uuid::new_v4(), WriteKind::RowChanges)
            .expect("a ticket");
        let second = ledger
            .begin(&hold, Uuid::new_v4(), WriteKind::SchemaChanges)
            .expect("a ticket");
        let mut idle = pin!(ledger.when_idle(CloseScope::Window));

        assert!(!polled(idle.as_mut()));
        ledger.settle(first.id);
        assert!(!polled(idle.as_mut()), "idle with a save still running");
        ledger.settle(second.id);
        assert!(polled(idle.as_mut()));
        assert!(
            ready(ledger.when_idle(CloseScope::Window)),
            "an idle ledger kept a waiter waiting"
        );
    }

    #[test]
    fn when_tab_idle_waits_only_for_that_tab() {
        let ledger = SaveLedger::new();
        let hold = CountingHold::new();
        let (tab, other) = (Uuid::new_v4(), Uuid::new_v4());
        let mine = ledger.begin(&hold, tab, WriteKind::RowChanges).expect("a ticket");
        let _theirs = ledger.begin(&hold, other, WriteKind::RowChanges).expect("a ticket");
        let idle = pin!(ledger.when_idle(CloseScope::Tab(tab)));

        ledger.settle(mine.id);

        assert!(polled(idle));
        assert_eq!(ledger.in_flight_in(CloseScope::Tab(other)), 1);
    }

    #[test]
    fn begin_refuses_duplicate_kind() {
        let ledger = SaveLedger::new();
        let hold = CountingHold::new();
        let tab = Uuid::new_v4();

        let first = ledger.begin(&hold, tab, WriteKind::RowChanges).expect("a ticket");
        assert!(ledger.begin(&hold, tab, WriteKind::RowChanges).is_none());
        assert!(ledger.begin(&hold, tab, WriteKind::SchemaChanges).is_some());
        ledger.settle(first.id);
        assert!(ledger.begin(&hold, tab, WriteKind::RowChanges).is_some());
    }

    #[test]
    fn cancel_scope_cancels_only_scoped_tokens() {
        let ledger = SaveLedger::new();
        let hold = CountingHold::new();
        let (tab, other) = (Uuid::new_v4(), Uuid::new_v4());
        let mine = ledger.begin(&hold, tab, WriteKind::RowChanges).expect("a ticket");
        let theirs = ledger.begin(&hold, other, WriteKind::RowChanges).expect("a ticket");

        ledger.cancel(CloseScope::Tab(tab));
        assert!(mine.cancel.is_cancelled());
        assert!(!theirs.cancel.is_cancelled());

        ledger.cancel(CloseScope::Window);
        assert!(theirs.cancel.is_cancelled());
    }

    #[test]
    fn entry_holds_counting_hold_until_settle() {
        let ledger = SaveLedger::new();
        let hold = CountingHold::new();
        let ticket = ledger
            .begin(&hold, Uuid::new_v4(), WriteKind::RowChanges)
            .expect("a ticket");

        assert_eq!(hold.live(), 1);
        ledger.cancel(CloseScope::Window);
        assert_eq!(hold.live(), 1, "a stopped save let go of the process before it settled");
        ledger.settle(ticket.id);
        assert_eq!(hold.live(), 0);
    }
}
