use std::cell::Cell;

use crate::workspace::CloseDecision;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_session::runtime::WatchForwarder;

use super::{SessionWindow, SessionWindowInput};
use crate::i18n::gettext;
use crate::persistence::StateFileError;
use crate::runtime::DeliverInput;
use crate::storage::AppStorage;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) enum StateFileKind {
    Layouts,
    Filters,
    Highlights,
}

impl StateFileKind {
    const ALL: [Self; 3] = [Self::Layouts, Self::Filters, Self::Highlights];

    fn failing(self, storage: &AppStorage) -> tokio::sync::watch::Receiver<bool> {
        match self {
            Self::Layouts => storage.column_layouts().failing(),
            Self::Filters => storage.filter_settings().failing(),
            Self::Highlights => storage.highlight_rules().failing(),
        }
    }

    fn error(self, storage: &AppStorage) -> Option<StateFileError> {
        match self {
            Self::Layouts => storage.column_layouts().current_error(),
            Self::Filters => storage.filter_settings().current_error(),
            Self::Highlights => storage.highlight_rules().current_error(),
        }
    }

    fn unsaved(self, storage: &AppStorage) -> bool {
        match self {
            Self::Layouts => storage.column_layouts().has_unsaved_changes(),
            Self::Filters => storage.filter_settings().has_unsaved_changes(),
            Self::Highlights => storage.highlight_rules().has_unsaved_changes(),
        }
    }

    fn revision(self, storage: &AppStorage) -> u64 {
        match self {
            Self::Layouts => storage.column_layouts().revision(),
            Self::Filters => storage.filter_settings().revision(),
            Self::Highlights => storage.highlight_rules().revision(),
        }
    }

    fn retry(self, storage: &AppStorage) -> bool {
        match self {
            Self::Layouts => storage.column_layouts().retry(),
            Self::Filters => storage.filter_settings().retry(),
            Self::Highlights => storage.highlight_rules().retry(),
        }
    }

    async fn flush(self, storage: &AppStorage) -> Result<(), StateFileError> {
        match self {
            Self::Layouts => storage.column_layouts().flush().await,
            Self::Filters => storage.filter_settings().flush().await,
            Self::Highlights => storage.highlight_rules().flush().await,
        }
    }

    fn message(self, retryable: bool) -> String {
        match (self, retryable) {
            (Self::Layouts, true) => gettext("Column layouts could not be saved"),
            (Self::Filters, true) => gettext("Table filters could not be saved"),
            (Self::Highlights, true) => gettext("Highlight rules could not be saved"),
            (Self::Layouts, false) => {
                gettext("Saved column layouts are unavailable. Their file has been kept unchanged.")
            }
            (Self::Filters, false) => {
                gettext("Saved table filters are unavailable. Their file has been kept unchanged.")
            }
            (Self::Highlights, false) => {
                gettext("Saved highlight rules are unavailable. Their file has been kept unchanged.")
            }
        }
    }
}

impl SessionWindow {
    pub(super) async fn confirm_state_files_before_close(&self, discarded: &Cell<Option<[u64; 3]>>) -> CloseDecision {
        if self.application().is_some_and(|application| {
            application
                .windows()
                .iter()
                .any(|window| window != self.upcast_ref::<gtk4::Window>())
        }) {
            return CloseDecision::Approved;
        }
        let Some(state) = self.state() else {
            return CloseDecision::Approved;
        };
        let storage = state.services.storage.clone();
        let _hold = state.services.hold().acquire();
        loop {
            let revisions = StateFileKind::ALL.map(|kind| kind.revision(&storage));
            if discarded.get() == Some(revisions) {
                return CloseDecision::Approved;
            }
            let mut failed = Vec::new();
            for kind in StateFileKind::ALL {
                if kind.flush(&storage).await.is_err() && kind.unsaved(&storage) {
                    failed.push(kind);
                }
            }
            if failed.is_empty() {
                if StateFileKind::ALL.into_iter().any(|kind| kind.unsaved(&storage)) {
                    continue;
                }
                return CloseDecision::Approved;
            }
            let revisions = StateFileKind::ALL.map(|kind| kind.revision(&storage));
            let retryable = failed
                .iter()
                .any(|kind| kind.error(&storage).is_some_and(|error| error.is_retryable()));
            let dialog = adw::AlertDialog::builder()
                .heading(gettext("Table Settings Could Not Be Saved"))
                .body(gettext(
                    "Closing now will lose changes to highlight rules, filters or column layouts.",
                ))
                .build();
            dialog.add_responses(&[
                ("cancel", &gettext("Keep Open")),
                ("discard", &gettext("Close Without Saving")),
            ]);
            if retryable {
                dialog.add_response("retry", &gettext("Retry"));
                dialog.set_response_appearance("retry", adw::ResponseAppearance::Suggested);
            }
            dialog.set_response_appearance("discard", adw::ResponseAppearance::Destructive);
            dialog.set_default_response(Some("cancel"));
            dialog.set_close_response("cancel");
            match crate::workspace::dialog_response::respond(&dialog, self.upcast_ref())
                .await
                .as_str()
            {
                "discard" => {
                    discarded.set(Some(revisions));
                }
                "retry" => {
                    for kind in failed {
                        if kind.error(&storage).is_some_and(|error| error.is_retryable()) {
                            kind.retry(&storage);
                        }
                    }
                }
                _ => return CloseDecision::Cancelled,
            }
        }
    }

    pub(super) fn watch_state_files(&self) {
        let (Some(state), Some(input)) = (self.state(), self.input()) else {
            return;
        };
        let watches = StateFileKind::ALL
            .into_iter()
            .map(|kind| {
                let input = input.clone();
                WatchForwarder::new(
                    kind.failing(&state.services.storage),
                    move |_| input.deliver(SessionWindowInput::StateFileStatus(kind)),
                    |future| {
                        glib::spawn_future_local(future);
                    },
                )
            })
            .collect();
        self.imp().state_file_watches.replace(watches);
    }

    pub(super) fn stop_state_file_watches(&self) {
        self.imp().state_file_watches.borrow_mut().clear();
        for (_, toast) in self.imp().state_file_toasts.borrow_mut().drain() {
            toast.dismiss();
        }
    }

    pub(super) fn show_state_file_status(&self, kind: StateFileKind) {
        if let Some(toast) = self.imp().state_file_toasts.borrow_mut().remove(&kind) {
            toast.dismiss();
        }
        let Some(state) = self.state() else {
            return;
        };
        let Some(error) = kind.error(&state.services.storage) else {
            return;
        };
        let retryable = error.is_retryable();
        let toast = adw::Toast::new(&kind.message(retryable));
        toast.set_timeout(0);
        if retryable && let Some(input) = self.input() {
            toast.set_button_label(Some(&gettext("Retry")));
            toast.connect_button_clicked(move |_| input.deliver(SessionWindowInput::RetryStateFile(kind)));
        }
        self.imp().state_file_toasts.borrow_mut().insert(kind, toast.clone());
        self.add_toast(toast);
    }

    pub(super) fn retry_state_file(&self, kind: StateFileKind) {
        let (Some(state), Some(input)) = (self.state(), self.input()) else {
            return;
        };
        let storage = state.services.storage.clone();
        if !kind.retry(&storage) {
            return;
        }
        let hold = state.services.hold().acquire();
        glib::spawn_future_local(async move {
            if let Err(error) = kind.flush(&storage).await {
                tracing::warn!(%error, "table settings retry failed");
            }
            // A repeated failure leaves the watch unchanged, but still needs its Retry button back.
            input.deliver(SessionWindowInput::StateFileStatus(kind));
            drop(hold);
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::application::WindowLaunch;
    use crate::services::change_tracker::RowKey;
    use crate::services::grid::HighlightRule;
    use crate::services::save_batch::SaveTarget;
    use crate::services::tracker_edit::TrackerEdit;
    use crate::test_support::{drain_main_context, wait_until};
    use crate::ui::session_window::tests::{TestWindow, WAIT};
    use crate::ui::workspace::{OpenMode, Workspace, WorkspaceInput};
    use crate::workspace::dialog_response::{answer, visible_alert};
    use crate::workspace::test_workspace::integer;
    use tablepro_core::Value;
    use tablepro_core::meta::TableRef;

    const SETTINGS_PROMPT: &str = "Table Settings Could Not Be Saved";

    fn wait_for_prompt(window: &SessionWindow, heading: &str) {
        wait_until(WAIT, || {
            visible_alert(window).is_some_and(|alert| alert.heading().as_deref() == Some(heading))
        })
        .expect("the expected close prompt");
    }

    fn fail_rule_write(test: &TestWindow) {
        let store = test.services.storage.highlight_rules();
        std::fs::create_dir(store.path()).expect("block file replacement");
        store.set_rules(test.saved.id, None, "orders", vec![HighlightRule::new("status")]);
        wait_until(WAIT, || store.current_error().is_some()).expect("the failed write");
    }

    fn edit_table(workspace: &Workspace, name: &str) {
        let before = workspace.open_tabs().unwrap_or_default();
        workspace
            .sender()
            .expect("workspace input")
            .deliver(WorkspaceInput::SelectTable {
                schema: None,
                name: name.to_owned(),
                open_mode: OpenMode::NewTab,
            });
        let mut opened = None;
        wait_until(WAIT, || {
            opened = workspace
                .open_tabs()
                .and_then(|tabs| tabs.into_iter().find(|tab| !before.contains(tab)));
            opened.is_some()
        })
        .expect("the table tab");
        let tracker = crate::ui::workspace::tests::row_tracker(workspace, opened.expect("opened tab"))
            .expect("the table tracker");
        let _ = tracker.set_target(SaveTarget {
            table: TableRef::unqualified(name),
            columns: vec![integer("id", true), integer("n", false)],
        });
        let _ = tracker.apply(TrackerEdit::Cell {
            row_key: RowKey::from_pk_values(&[Value::Int(1)]).expect("row key"),
            col: 1,
            original: Value::Int(1),
            value: tablepro_core::edit::CellInput::Value(Value::Int(2)),
        });
    }

    fn second_connected_window(test: &TestWindow) -> SessionWindow {
        let saved = tablepro_storage::SavedConnection {
            id: uuid::Uuid::new_v4(),
            name: "Second".to_owned(),
            database: test.dir().join("second.db").display().to_string(),
            ..test.saved.clone()
        };
        test.services
            .storage
            .connections()
            .upsert_blocking(saved.clone())
            .expect("save second connection");
        wait_until(WAIT, || test.services.saved_connections.get(saved.id).is_some()).expect("saved list updated");
        let window = test
            .app
            .open_window(WindowLaunch::Connect(Box::new(saved)))
            .and_then(|window| window.downcast::<SessionWindow>().ok())
            .expect("second window");
        wait_until(WAIT, || window.page_name() == "workspace").expect("second window connected");
        window
    }

    #[gtk4::test]
    fn a_failed_rule_write_offers_retry_and_success_dismisses_the_notice() {
        let test = TestWindow::picker("HighlightWriteFailure");
        let store = test.services.storage.highlight_rules();
        let path = store.path().to_owned();
        std::fs::create_dir(&path).expect("block file replacement");
        store.set_rules(test.saved.id, None, "orders", vec![HighlightRule::new("status")]);
        wait_until(WAIT, || {
            test.window
                .imp()
                .state_file_toasts
                .borrow()
                .contains_key(&StateFileKind::Highlights)
        })
        .expect("write failure notice");
        let toast = test
            .window
            .imp()
            .state_file_toasts
            .borrow()
            .get(&StateFileKind::Highlights)
            .cloned()
            .expect("toast");
        assert_eq!(toast.button_label().as_deref(), Some("Retry"));
        assert_eq!(test.window.imp().state_file_toasts.borrow().len(), 1);
        std::fs::remove_dir(&path).expect("allow writes again");
        toast.emit_by_name::<()>("button-clicked", &[]);
        wait_until(WAIT, || {
            path.is_file() && test.window.imp().state_file_toasts.borrow().is_empty()
        })
        .expect("retry saves and dismisses");
        assert!(
            std::fs::read_to_string(&path)
                .expect("saved document")
                .contains("status")
        );
        drain_main_context();
    }
    #[gtk4::test]
    fn closing_waits_for_a_failed_write_and_can_retry_without_losing_rules() {
        let test = TestWindow::picker("HighlightCloseFailure");
        let store = test.services.storage.highlight_rules();
        let path = store.path().to_owned();
        std::fs::create_dir(&path).expect("block write");
        store.set_rules(test.saved.id, None, "orders", vec![HighlightRule::new("status")]);
        test.window.close();
        wait_until(WAIT, || {
            test.window
                .visible_dialog()
                .and_downcast::<adw::AlertDialog>()
                .is_some()
        })
        .expect("failed close asks before losing state");
        assert!(test.window.is_visible());
        std::fs::remove_dir(&path).expect("allow retry");
        assert!(crate::workspace::dialog_response::answer(&test.window, "retry"));
        wait_until(WAIT, || !test.window.is_visible()).expect("close after saved");
        assert!(
            std::fs::read_to_string(path)
                .expect("saved on close")
                .contains("status")
        );
    }

    #[gtk4::test]
    fn the_last_of_two_pending_window_closes_checks_shared_failed_settings_again() {
        let test = TestWindow::connected("TwoWindowSettingsClose");
        let second = second_connected_window(&test);
        edit_table(&test.workspace(), "first_edits");
        edit_table(&second.workspace().expect("second workspace"), "second_edits");
        fail_rule_write(&test);

        test.window.close();
        second.close();
        wait_for_prompt(&test.window, "Save Changes?");
        wait_for_prompt(&second, "Save Changes?");
        assert_eq!(test.app.windows().len(), 2);
        assert!(answer(&test.window, "discard"));
        wait_until(WAIT, || !test.window.is_visible() && test.app.windows().len() == 1)
            .expect("the first close completes while the second waits");
        assert!(answer(&second, "discard"));

        wait_for_prompt(&second, SETTINGS_PROMPT);
        assert!(second.is_visible());
        assert!(test.services.storage.highlight_rules().has_unsaved_changes());
        assert!(answer(&second, "cancel"));
        wait_until(WAIT, || visible_alert(&second).is_none()).expect("keep the last window open");
        assert!(second.is_visible());
    }

    #[gtk4::test]
    fn unchanged_settings_discard_is_asked_once_across_workspace_close_prompts() {
        let test = TestWindow::connected("SettingsDiscardOnce");
        edit_table(&test.workspace(), "orders");
        fail_rule_write(&test);

        test.window.close();
        wait_for_prompt(&test.window, SETTINGS_PROMPT);
        assert!(answer(&test.window, "discard"));
        wait_for_prompt(&test.window, "Save Changes?");
        assert!(answer(&test.window, "discard"));

        wait_until(WAIT, || !test.window.is_visible()).expect("unchanged settings consent remains valid");
        assert!(test.services.storage.highlight_rules().has_unsaved_changes());
    }

    #[gtk4::test]
    fn settings_changed_during_the_workspace_prompt_need_new_discard_consent() {
        let test = TestWindow::connected("SettingsDiscardRevision");
        edit_table(&test.workspace(), "orders");
        fail_rule_write(&test);

        test.window.close();
        wait_for_prompt(&test.window, SETTINGS_PROMPT);
        assert!(answer(&test.window, "discard"));
        wait_for_prompt(&test.window, "Save Changes?");
        let changed = HighlightRule::new("new_status");
        test.services
            .storage
            .highlight_rules()
            .set_rules(test.saved.id, None, "orders", vec![changed.clone()]);
        assert!(answer(&test.window, "discard"));

        wait_for_prompt(&test.window, SETTINGS_PROMPT);
        assert!(test.window.is_visible());
        assert_eq!(
            test.services
                .storage
                .highlight_rules()
                .rules(test.saved.id, None, "orders"),
            [changed]
        );
        assert!(answer(&test.window, "cancel"));
        wait_until(WAIT, || visible_alert(&test.window).is_none()).expect("keep the changed settings open");
        assert!(test.window.is_visible());
    }
}
