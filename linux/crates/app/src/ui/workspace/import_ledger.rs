use std::cell::RefCell;
use std::collections::BTreeMap;
use std::future::Future;
use std::rc::Rc;

use futures::channel::oneshot;
use futures::future::LocalBoxFuture;
use tablepro_session::runtime::{HoldToken, ProcessHold};
use tokio_util::sync::CancellationToken;

use crate::i18n::{gettext, ngettext_f};
use crate::ui::format::plural_count;
use crate::workspace::{CloseBlockPrompt, CloseBlocker, InhibitReason, WindowInhibitor};

/// The CSV imports a workspace has running.
///
/// Each one holds the process, so quitting while one writes lets it
/// commit or roll back and report, and closing the window asks before
/// it stops one. While any runs, the session is asked not to log out or
/// suspend under it.
pub(crate) struct ImportLedger {
    hold: Rc<dyn ProcessHold>,
    inhibitor: RefCell<WindowInhibitor>,
    state: RefCell<LedgerState>,
}

#[derive(Default)]
struct LedgerState {
    next: u64,
    running: BTreeMap<u64, Running>,
    waiters: Vec<oneshot::Sender<()>>,
    /// The workspace shut down: its close already asked about the
    /// imports, and a new one would have no window to report to.
    shut_down: bool,
}

struct Running {
    cancel: CancellationToken,
    _hold: HoldToken,
}

/// A started import: its id to settle it by, and the token that stops
/// it.
#[derive(Debug, Clone)]
pub(crate) struct ImportTicket {
    pub id: u64,
    pub cancel: CancellationToken,
}

impl ImportLedger {
    pub(crate) fn new(hold: Rc<dyn ProcessHold>, inhibitor: WindowInhibitor) -> Rc<Self> {
        Rc::new(Self {
            hold,
            inhibitor: RefCell::new(inhibitor),
            state: RefCell::default(),
        })
    }

    /// Record an import, unless the workspace has shut down.
    pub(crate) fn begin(&self) -> Option<ImportTicket> {
        let ticket = {
            let mut state = self.state.borrow_mut();
            if state.shut_down {
                return None;
            }
            state.next += 1;
            let ticket = ImportTicket {
                id: state.next,
                cancel: CancellationToken::new(),
            };
            state.running.insert(
                ticket.id,
                Running {
                    cancel: ticket.cancel.clone(),
                    _hold: self.hold.acquire(),
                },
            );
            ticket
        };
        self.refresh_inhibitor();
        Some(ticket)
    }

    /// The import ended. A second call for the same one does nothing.
    pub(crate) fn settle(&self, id: u64) {
        let (finished, woken) = {
            let mut state = self.state.borrow_mut();
            let finished = state.running.remove(&id);
            let woken = match state.running.is_empty() {
                true => std::mem::take(&mut state.waiters),
                false => Vec::new(),
            };
            (finished, woken)
        };
        self.refresh_inhibitor();
        // The hold goes only after the state is consistent, in case
        // dropping it ends the main loop.
        drop(finished);
        for waiter in woken {
            let _ = waiter.send(());
        }
    }

    pub(crate) fn in_flight(&self) -> usize {
        self.state.borrow().running.len()
    }

    /// Resolves once no import is running.
    pub(crate) fn when_idle(&self) -> impl Future<Output = ()> + use<> {
        let receiver = match self.in_flight() {
            0 => None,
            _ => {
                let (sender, receiver) = oneshot::channel();
                self.state.borrow_mut().waiters.push(sender);
                Some(receiver)
            }
        };
        async move {
            if let Some(receiver) = receiver {
                // A ledger dropped with imports running wakes nobody,
                // and a waiter that outlived it has nothing to wait on.
                let _ = receiver.await;
            }
        }
    }

    /// Stop every running import. Each settles once its driver has
    /// answered the stop.
    pub(crate) fn cancel_all(&self) {
        for running in self.state.borrow().running.values() {
            running.cancel.cancel();
        }
    }

    /// Stop every running import and refuse new ones, for a workspace
    /// that is going away.
    pub(crate) fn shut_down(&self) {
        self.state.borrow_mut().shut_down = true;
        self.cancel_all();
    }

    fn refresh_inhibitor(&self) {
        let reason = (self.in_flight() > 0).then_some(InhibitReason::SavingChanges);
        self.inhibitor.borrow_mut().update(reason);
    }
}

impl CloseBlocker for ImportLedger {
    fn blocking(&self) -> Option<CloseBlockPrompt> {
        let running = self.in_flight();
        (running > 0).then(|| CloseBlockPrompt {
            heading: gettext("Stop Imports?"),
            body: ngettext_f(
                "{n} CSV import is still running. Stopping it rolls back the rows it wrote, unless the table has no transactions.",
                "{n} CSV imports are still running. Stopping them rolls back the rows they wrote, unless the table has no transactions.",
                plural_count(running as u64),
                &[("n", &running.to_string())],
            ),
            keep_label: gettext("_Keep Importing"),
            stop_label: gettext("_Stop Imports"),
        })
    }

    fn stop(&self) -> LocalBoxFuture<'static, ()> {
        self.cancel_all();
        Box::pin(self.when_idle())
    }
}

impl std::fmt::Debug for ImportLedger {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ImportLedger")
            .field("in_flight", &self.in_flight())
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;

    use gtk4 as gtk;
    use tablepro_session::runtime::CountingHold;

    use super::*;
    use crate::workspace::InhibitTarget;

    /// Counts the inhibitions held.
    #[derive(Clone, Default)]
    struct Session {
        held: Rc<Cell<u32>>,
    }

    impl InhibitTarget for Session {
        fn inhibit(&self, _flags: gtk::ApplicationInhibitFlags, _reason: &str) -> u32 {
            self.held.set(self.held.get() + 1);
            self.held.get()
        }

        fn uninhibit(&self, _cookie: u32) {
            self.held.set(self.held.get() - 1);
        }
    }

    fn ledger() -> (Rc<ImportLedger>, Rc<CountingHold>, Session) {
        let hold = Rc::new(CountingHold::new());
        let session = Session::default();
        let ledger = ImportLedger::new(hold.clone(), WindowInhibitor::new(session.clone()));
        (ledger, hold, session)
    }

    #[test]
    fn a_running_import_holds_the_process_and_asks_before_a_close() {
        let (ledger, hold, session) = ledger();
        assert_eq!(ledger.blocking(), None);

        let ticket = ledger.begin().expect("an import starts");
        let prompt = ledger.blocking().expect("a running import blocks the close");

        assert_eq!(prompt.heading, "Stop Imports?");
        assert!(
            prompt.body.starts_with("1 CSV import is still running."),
            "{}",
            prompt.body
        );
        assert_eq!(hold.live(), 1);
        assert_eq!(session.held.get(), 1);

        ledger.settle(ticket.id);

        assert_eq!(ledger.blocking(), None);
        assert_eq!(hold.live(), 0);
        assert_eq!(session.held.get(), 0);
    }

    #[tokio::test]
    async fn stop_cancels_the_import_and_waits_for_it_to_settle() {
        let (ledger, _, _) = ledger();
        let ticket = ledger.begin().expect("an import starts");

        let mut stopped = ledger.stop();
        assert!(ticket.cancel.is_cancelled(), "the stop did not reach the write");
        assert!(
            futures::poll!(&mut stopped).is_pending(),
            "the stop ended before the import settled"
        );
        ledger.settle(ticket.id);

        stopped.await;
        assert_eq!(ledger.in_flight(), 0);
    }

    #[test]
    fn a_workspace_that_shut_down_starts_no_import() {
        let (ledger, _, _) = ledger();
        let running = ledger.begin().expect("an import starts");

        ledger.shut_down();

        assert!(running.cancel.is_cancelled());
        assert!(ledger.begin().is_none());
    }
}
