use std::collections::HashSet;

use gtk4 as gtk;
use libadwaita as adw;
use libadwaita::prelude::*;
use uuid::Uuid;

use super::open_transaction_dialog::confirm_open_transactions;
use super::save_changes_dialog::{SaveChoice, ask_save_changes};
use super::unknown_outcome_dialog::{UnknownChoice, resolve_unknown_outcome};
use super::waiting_dialog::wait_for_saves;
use super::{CloseDecision, CloseScope, CloseStep, DirtyTab, SaveRejection, SaveStart, WorkspaceHandle};

/// Decides whether a tab, or every tab of a window, may close.
///
/// It reads the workspace again after every answer and every settled
/// save rather than following a plan made up front, so a save that
/// rolls back is asked about again and one that lands is not.
pub(crate) struct CloseGuard;

impl CloseGuard {
    pub(crate) async fn run(parent: &gtk::Widget, handle: &WorkspaceHandle, scope: CloseScope) -> CloseDecision {
        let mut acknowledged = HashSet::new();
        loop {
            match handle.close_step(scope, &acknowledged) {
                CloseStep::Approve => return CloseDecision::Approved,
                CloseStep::WaitForSaves => {
                    if !wait_for_saves(parent, handle, scope).await {
                        return CloseDecision::Cancelled;
                    }
                }
                CloseStep::ResolveUnknownOutcome(tabs) => match resolve_unknown_outcome(parent, &tabs).await {
                    UnknownChoice::KeepOpen => return CloseDecision::Cancelled,
                    UnknownChoice::Reload => {
                        handle.discard(&ids(&tabs), true);
                        return CloseDecision::Cancelled;
                    }
                    UnknownChoice::Discard => handle.discard(&ids(&tabs), false),
                },
                CloseStep::ConfirmOpenTransactions(tabs) => {
                    if !confirm_open_transactions(parent, &tabs).await {
                        return CloseDecision::Cancelled;
                    }
                    acknowledged.extend(ids(&tabs));
                }
                CloseStep::AskSaveChanges(tabs) => match ask_save_changes(parent, &tabs).await {
                    SaveChoice::Cancel => return CloseDecision::Cancelled,
                    SaveChoice::Proceed { save, discard } => {
                        handle.discard(&discard, false);
                        let refused: Vec<(Uuid, SaveRejection)> = save
                            .iter()
                            .zip(handle.save(&save))
                            .filter_map(|(tab, start)| match start {
                                SaveStart::Rejected(rejection) => Some((*tab, rejection)),
                                SaveStart::Started(_) | SaveStart::NothingToSave => None,
                            })
                            .collect();
                        if !refused.is_empty() {
                            show_refused(parent, &tabs, &refused);
                            return CloseDecision::Cancelled;
                        }
                    }
                },
            }
        }
    }
}

fn ids(tabs: &[DirtyTab]) -> Vec<Uuid> {
    tabs.iter().map(|tab| tab.id).collect()
}

/// A save that could not start keeps its tab open, with the reason.
fn show_refused(parent: &gtk::Widget, tabs: &[DirtyTab], refused: &[(Uuid, SaveRejection)]) {
    let lines: Vec<String> = refused
        .iter()
        .map(|(id, rejection)| {
            let name = tabs
                .iter()
                .find(|tab| tab.id == *id)
                .map(|tab| tab.title.clone())
                .unwrap_or_default();
            crate::i18n::gettext_f("“{tab}”: {reason}", &[("tab", &name), ("reason", &rejection.message())])
        })
        .collect();
    let dialog = adw::AlertDialog::new(Some(&crate::i18n::gettext("Could Not Save")), Some(&lines.join("\n")));
    dialog.add_response("close", &crate::i18n::gettext("_Close"));
    dialog.set_close_response("close");
    dialog.set_default_response(Some("close"));
    dialog.present(Some(parent));
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::rc::Rc;
    use std::time::Duration;

    use tablepro_core::{DriverError, LossPhase, WriteReport};
    use tablepro_test_support::{CallCounters, ConnectionScript, FakeReply};

    use super::*;
    use crate::test_support::wait_until;
    use crate::workspace::dialog_response::{answer, visible_alert};
    use crate::workspace::test_workspace::{WAIT, Workspace};
    use crate::workspace::{PendingState, WorkspaceEvent};

    fn window() -> adw::Window {
        adw::init().expect("libadwaita initialises under the test backend");
        if let Some(settings) = gtk::Settings::default() {
            settings.set_gtk_enable_animations(false);
        }
        let window = adw::Window::new();
        window.present();
        window
    }

    fn guard(window: &adw::Window, handle: &WorkspaceHandle, scope: CloseScope) -> Rc<RefCell<Option<CloseDecision>>> {
        let decision = Rc::new(RefCell::new(None));
        let sink = decision.clone();
        let parent = window.clone().upcast::<gtk::Widget>();
        let handle = handle.clone();
        gtk::glib::spawn_future_local(async move {
            let decided = CloseGuard::run(&parent, &handle, scope).await;
            sink.replace(Some(decided));
        });
        decision
    }

    /// Wait for an alert with `heading` other than `seen`, and answer
    /// it with `response`. Returns the alert answered.
    fn answer_next(
        window: &adw::Window,
        heading: &str,
        response: &str,
        seen: Option<&adw::AlertDialog>,
    ) -> adw::AlertDialog {
        let mut shown = None;
        wait_until(WAIT, || {
            shown = visible_alert(window)
                .filter(|alert| alert.heading().as_deref() == Some(heading) && Some(alert) != seen);
            shown.is_some()
        })
        .unwrap_or_else(|_| panic!("no “{heading}” alert"));
        assert!(answer(window, response));
        shown.expect("the alert")
    }

    fn decided(decision: &Rc<RefCell<Option<CloseDecision>>>) -> CloseDecision {
        wait_until(WAIT, || decision.borrow().is_some()).expect("the guard to decide");
        decision.borrow().expect("a decision")
    }

    fn rolled_back() -> DriverError {
        DriverError::RolledBack {
            statement_index: 0,
            source: Box::new(DriverError::server("duplicate key")),
        }
    }

    #[gtk4::test]
    fn cancel_keeps_window() {
        let workspace = Workspace::open(ConnectionScript::default());
        let window = window();

        let decision = guard(&window, &workspace.handle, CloseScope::Window);
        answer_next(&window, "Save Changes?", "cancel", None);

        assert_eq!(decided(&decision), CloseDecision::Cancelled);
        assert_eq!(workspace.tracker.pending_state(), PendingState::Unsaved);
        assert_eq!(CallCounters::get(&workspace.counters().write_batch), 0);
    }

    #[gtk4::test]
    fn discard_closes() {
        let workspace = Workspace::open(ConnectionScript::default());
        let window = window();

        let decision = guard(&window, &workspace.handle, CloseScope::Window);
        answer_next(&window, "Save Changes?", "discard", None);

        assert_eq!(decided(&decision), CloseDecision::Approved);
        assert_eq!(workspace.tracker.pending_state(), PendingState::Clean);
        assert!(workspace.events.borrow().iter().any(|event| matches!(
            event,
            WorkspaceEvent::Discarded { tabs, reload: false } if tabs == &[workspace.tab]
        )));
    }

    #[gtk4::test]
    fn save_closes_once_the_save_lands() {
        let mut script = ConnectionScript::default();
        script
            .write_batch
            .always(FakeReply::ok(WriteReport::new(vec![Some(1)])));
        let workspace = Workspace::open(script);
        let window = window();

        let decision = guard(&window, &workspace.handle, CloseScope::Window);
        answer_next(&window, "Save Changes?", "save", None);

        assert_eq!(decided(&decision), CloseDecision::Approved);
        assert_eq!(workspace.tracker.pending_state(), PendingState::Clean);
        assert_eq!(CallCounters::get(&workspace.counters().write_batch), 1);
    }

    #[gtk4::test]
    fn rolled_back_save_represents() {
        let mut script = ConnectionScript::default();
        script.write_batch.always(FakeReply::err(rolled_back()));
        let workspace = Workspace::open(script);
        let window = window();

        let decision = guard(&window, &workspace.handle, CloseScope::Window);
        let first = answer_next(&window, "Save Changes?", "save", None);
        answer_next(&window, "Save Changes?", "cancel", Some(&first));

        assert_eq!(decided(&decision), CloseDecision::Cancelled);
        assert_eq!(CallCounters::get(&workspace.counters().write_batch), 1);
        assert_eq!(workspace.tracker.pending_state(), PendingState::Unsaved);
    }

    #[gtk4::test]
    fn in_flight_save_waiting_dialog_force_closes_on_settle() {
        let mut script = ConnectionScript::default();
        script.write_batch.always(FakeReply::Bounded {
            after: Duration::from_millis(500),
            outcome: Ok(WriteReport::new(vec![Some(1)])),
        });
        let workspace = Workspace::open(script);
        let window = window();
        assert!(matches!(
            workspace.handle.save(&[workspace.tab]).as_slice(),
            [SaveStart::Started(_)]
        ));

        let decision = guard(&window, &workspace.handle, CloseScope::Window);
        wait_until(WAIT, || {
            visible_alert(&window).is_some_and(|alert| alert.heading().as_deref() == Some("Saving Changes"))
        })
        .expect("the waiting dialog");

        assert_eq!(decided(&decision), CloseDecision::Approved);
        crate::test_support::drain_main_context();
        assert!(visible_alert(&window).is_none(), "the waiting dialog stayed up");
        assert_eq!(workspace.tracker.pending_state(), PendingState::Clean);
    }

    #[gtk4::test]
    fn unknown_reload_cancels_close_and_write_batch_count_stays_one() {
        let mut script = ConnectionScript::default();
        script
            .write_batch
            .always(FakeReply::err(DriverError::CommitOutcomeUnknown {
                token: None,
                source: Box::new(DriverError::ConnectionLost {
                    during: LossPhase::Commit,
                }),
            }));
        let workspace = Workspace::open(script);
        let window = window();
        workspace.save();
        assert!(matches!(
            workspace.tracker.pending_state(),
            PendingState::OutcomeUnknown(_)
        ));

        let decision = guard(&window, &workspace.handle, CloseScope::Window);
        answer_next(&window, "Save Result Unknown", "reload", None);

        assert_eq!(decided(&decision), CloseDecision::Cancelled);
        assert_eq!(CallCounters::get(&workspace.counters().write_batch), 1);
        assert_eq!(workspace.tracker.pending_state(), PendingState::Clean);
        assert!(
            workspace
                .events
                .borrow()
                .iter()
                .any(|event| matches!(event, WorkspaceEvent::Discarded { reload: true, .. }))
        );
    }

    #[gtk4::test]
    fn stop_saving_settles_and_reevaluates() {
        let mut script = ConnectionScript::default();
        script
            .write_batch
            .always(FakeReply::StoppedWith(Err(DriverError::RolledBack {
                statement_index: 0,
                source: Box::new(DriverError::Cancelled),
            })));
        let workspace = Workspace::open(script);
        let window = window();
        assert!(matches!(
            workspace.handle.save(&[workspace.tab]).as_slice(),
            [SaveStart::Started(_)]
        ));

        let decision = guard(&window, &workspace.handle, CloseScope::Window);
        answer_next(&window, "Saving Changes", "stop", None);
        answer_next(&window, "Save Changes?", "cancel", None);

        assert_eq!(decided(&decision), CloseDecision::Cancelled);
        let observed = workspace.fake.connection.observed_cancels("write_batch");
        assert!(!observed.is_empty(), "the write never ran");
        assert!(
            observed.iter().all(|cancel| cancel.is_cancelled()),
            "the write never saw the stop"
        );
        assert_eq!(workspace.handle.ledger().in_flight(), 0);
        assert_eq!(workspace.tracker.pending_state(), PendingState::Unsaved);
        assert!(visible_alert(&window).is_none(), "a waiting dialog stayed up");
    }

    #[gtk4::test]
    fn window_close_asks_about_open_editor_transactions_once() {
        let workspace = Workspace::open(ConnectionScript::default());
        workspace.open_transaction_tab();
        let window = window();

        let decision = guard(&window, &workspace.handle, CloseScope::Window);
        answer_next(&window, "Close With Open Transactions?", "close", None);
        answer_next(&window, "Save Changes?", "discard", None);

        assert_eq!(decided(&decision), CloseDecision::Approved);
    }

    #[gtk4::test]
    fn an_open_transaction_cancel_keeps_the_window() {
        let workspace = Workspace::open(ConnectionScript::default());
        workspace.handle.discard(&[workspace.tab], false);
        workspace.open_transaction_tab();
        let window = window();

        let decision = guard(&window, &workspace.handle, CloseScope::Window);
        answer_next(&window, "Close With Open Transactions?", "cancel", None);

        assert_eq!(decided(&decision), CloseDecision::Cancelled);
    }

    #[gtk4::test]
    fn a_tab_close_asks_only_about_that_tab() {
        let workspace = Workspace::open(ConnectionScript::default());
        let editor = workspace.open_transaction_tab();
        let window = window();

        let decision = guard(&window, &workspace.handle, CloseScope::Tab(editor));
        answer_next(&window, "Close With Open Transactions?", "close", None);

        assert_eq!(decided(&decision), CloseDecision::Approved);
        assert_eq!(workspace.tracker.pending_state(), PendingState::Unsaved);
    }
}
