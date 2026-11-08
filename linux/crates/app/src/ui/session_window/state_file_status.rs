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
    pub(super) async fn confirm_state_files_before_close(&self) -> CloseDecision {
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
            let mut failed = Vec::new();
            for kind in StateFileKind::ALL {
                if kind.flush(&storage).await.is_err() && kind.unsaved(&storage) {
                    failed.push(kind);
                }
            }
            if failed.is_empty() {
                return CloseDecision::Approved;
            }
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
                "discard" => return CloseDecision::Approved,
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
    use crate::services::grid::HighlightRule;
    use crate::test_support::{drain_main_context, wait_until};
    use crate::ui::session_window::tests::{TestWindow, WAIT};

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
}
