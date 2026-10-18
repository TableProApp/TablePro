use relm4::adw::prelude::*;
use relm4::gtk;
use relm4::prelude::*;
use uuid::Uuid;

use super::{App, AppMsg};

impl App {
    pub(super) fn persist_window_state(&self, sender: ComponentSender<Self>, for_close: bool) {
        let state = *self.window_state.borrow();
        let generation = crate::services::window_state::next_save_generation();
        let input_sender = sender.input_sender().clone();
        sender.command(move |_, shutdown| {
            shutdown
                .register(async move {
                    let result =
                        tokio::task::spawn_blocking(move || crate::services::window_state::save(&state, generation))
                            .await
                            .map_err(|error| error.to_string())
                            .and_then(|result| result);
                    let message = if for_close {
                        AppMsg::WindowStatePersistedForClose(result)
                    } else {
                        AppMsg::WindowStatePersisted(result)
                    };
                    let _ = input_sender.send(message);
                })
                .drop_on_shutdown()
        });
    }

    pub(super) fn set_last_connection_id(&mut self, id: Option<Uuid>, sender: ComponentSender<Self>) {
        if self.window_state.borrow().last_connection_id == id {
            return;
        }
        self.window_state.borrow_mut().last_connection_id = id;
        self.persist_window_state(sender, false);
    }

    pub(super) fn on_connection_deleted(&mut self, id: Uuid, sender: ComponentSender<Self>) {
        if self.window_state.borrow().last_connection_id == Some(id) {
            self.set_last_connection_id(None, sender);
        }
    }

    /// The active driver id, or "postgres" if no connection is active.
    ///
    /// Single fallback site (was duplicated at 7 call sites). The
    /// tracing::warn! makes the latent bug visible if anything ever
    /// asks for the driver id without an active connection — today
    /// that would silently corrupt SQL quoting on non-Postgres drivers.
    pub(super) fn driver_id(&self) -> &str {
        match self.current_driver_id.as_deref() {
            Some(id) => id,
            None => {
                tracing::warn!("driver_id called without active connection; falling back to postgres");
                "postgres"
            }
        }
    }
}

impl App {
    pub(super) fn on_show_saved_queries(&mut self, sender: ComponentSender<Self>) {
        let dialog = crate::ui::saved_queries_dialog::SavedQueriesDialog::builder()
            .launch(self.favorites.clone())
            .forward(sender.input_sender(), |out| match out {
                crate::ui::saved_queries_dialog::SavedQueriesOutput::OpenInNewTab(sql) => AppMsg::OpenHistoryQuery(sql),
                crate::ui::saved_queries_dialog::SavedQueriesOutput::Changed(saved) => {
                    AppMsg::SavedQueriesChanged(saved)
                }
            });
        dialog.model().dialog().present(Some(&self.window));
        self.saved_queries_dialog = Some(dialog);
    }

    pub(super) fn on_open_sql_file(&self, sender: ComponentSender<Self>) {
        let parent = self.window.clone().upcast::<gtk::Window>();
        crate::ui::editor::open_file::choose_sql_file(Some(parent), move |outcome| match outcome {
            Ok(text) => sender.input(AppMsg::SqlFileOpened(text)),
            Err(message) => sender.input(AppMsg::SqlFileFailed(message)),
        });
    }
}
