use libadwaita::prelude::*;
use tablepro_foreign_import::review::{ImportPlan, ImportReview, QueryImportOutcome};
use tablepro_storage::{SavedConnection, StorageError};

use super::session_page::SessionPage;
use super::{SessionWindow, SessionWindowInput};
use crate::application::{TableProApplication, WindowLaunch};
use crate::i18n::{gettext, ngettext_f};
use crate::runtime::{DeliverInput, spawn_and_deliver};
use crate::services::saved_connection_editor::ImportedFromApp;
use crate::services::saved_connection_error::SavedConnectionError;
use crate::services::setup_guide::{SetupEnding, handoff, import_source};
use crate::ui::import_from_app::{ImportFromAppDialog, ImportFromAppInit};

pub(super) type ImportWritten = Box<dyn FnOnce(Vec<SavedConnection>)>;

impl SessionWindow {
    pub(super) fn on_import_from_app(&self) {
        let Some(state) = self.state() else {
            return;
        };
        let services = &state.services;
        let window = self.downgrade();
        let dialog = ImportFromAppDialog::new(ImportFromAppInit {
            dirs: tablepro_linux_platform::foreign_app_dirs(),
            drivers: services.drivers.clone(),
            connections: services.storage.connections().clone(),
            tasks: services.tasks.clone(),
            on_import: Box::new(move |review, plan| {
                if let Some(window) = window.upgrade() {
                    let source = import_source(review.app());
                    let handing = window.downgrade();
                    window.import_from_app(
                        review,
                        plan,
                        Box::new(move |written: Vec<SavedConnection>| {
                            if let Some(window) = handing.upgrade() {
                                let ids: Vec<uuid::Uuid> = written.iter().map(|saved| saved.id).collect();
                                window.hand_off_import(handoff(&ids, source));
                            }
                        }),
                    );
                }
            }),
        });
        dialog.present(Some(self));
    }

    // The caller picks the ending, since only an import from an app's own store opens one (core ADR 0057).
    pub(super) fn hand_off_import(&self, ending: SetupEnding) {
        match ending {
            SetupEnding::Open(id) => self.open_stored(id),
            SetupEnding::Select(ids) => match reveal_place(self.page()) {
                RevealPlace::Here => self.focus_connections(&ids),
                RevealPlace::PickerWindow => self.reveal_in_picker_window(&ids),
            },
            SetupEnding::NewConnection | SetupEnding::Sample | SetupEnding::Stay => {}
        }
    }

    // The session here stays open, so the library shows in an idle picker window, or a new one.
    fn reveal_in_picker_window(&self, ids: &[uuid::Uuid]) {
        let Some(app) = self.application().and_downcast::<TableProApplication>() else {
            return;
        };
        let picker = app
            .windows()
            .into_iter()
            .filter_map(|window| window.downcast::<SessionWindow>().ok())
            .find(SessionWindow::is_idle)
            .or_else(|| app.open_window(WindowLaunch::Picker).and_downcast::<SessionWindow>());
        match picker {
            Some(picker) => {
                picker.focus_connections(ids);
                picker.present();
            }
            None => tracing::warn!("no window opened to show the imported connections"),
        }
    }

    // `done` hears the connections written, none when the write failed, after the toast says what happened.
    pub(super) fn import_from_app(&self, review: ImportReview, plan: ImportPlan, done: ImportWritten) {
        let Some(state) = self.state() else {
            return;
        };
        let editor = state.services.saved_connection_editor.clone();
        let saved = state.services.history().ready_saved();
        // Another app has no projects, so what it adds lands in the active one.
        let project = state
            .services
            .saved_connections
            .active_project()
            .map(|project| project.id);
        let hold = state.services.hold().acquire();
        let window = self.downgrade();
        spawn_and_deliver(
            &state.services.tasks,
            async move {
                match editor.add_imported(review, plan, project).await {
                    Ok(imported) => {
                        let (queries, queries_available) = if imported.applied.queries.is_empty() {
                            (None, false)
                        } else if let Some(saved) = saved.await {
                            let store = saved.saved_queries();
                            (
                                Some(editor.save_imported_queries(&imported.applied, &store).await),
                                true,
                            )
                        } else {
                            (None, false)
                        };
                        let written: Vec<SavedConnection> = imported
                            .applied
                            .connections
                            .iter()
                            .map(|applied| applied.connection.clone())
                            .collect();
                        (imported_message(&imported, queries, queries_available), written)
                    }
                    Err(SavedConnectionError::Storage(StorageError::ImportOutdated)) => (
                        gettext("The saved connections changed while you were deciding. Import again."),
                        Vec::new(),
                    ),
                    Err(error) => {
                        tracing::warn!(%error, "could not import from another app");
                        (
                            crate::ui::error_text::saved_connection_error_message(&error),
                            Vec::new(),
                        )
                    }
                }
            },
            move |outcome| {
                let (message, written) = outcome.unwrap_or_else(|failure| {
                    tracing::warn!(%failure, "the import from another app did not finish");
                    (gettext("The import did not finish."), Vec::new())
                });
                if let Some(window) = window.upgrade()
                    && let Some(input) = window.input()
                {
                    input.deliver(SessionWindowInput::ShowToast(message));
                }
                done(written);
                drop(hold);
            },
        );
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RevealPlace {
    Here,
    PickerWindow,
}

// Only the picker shows the window's library; any other page hides it.
fn reveal_place(page: SessionPage) -> RevealPlace {
    match page {
        SessionPage::Picker => RevealPlace::Here,
        SessionPage::Connecting(_) | SessionPage::Failed | SessionPage::Shell | SessionPage::Setup => {
            RevealPlace::PickerWindow
        }
    }
}

pub(super) fn imported_message(
    imported: &ImportedFromApp,
    queries: Option<Result<QueryImportOutcome, SavedConnectionError>>,
    queries_available: bool,
) -> String {
    let connections = imported.applied.connections.len();
    let mut parts = Vec::new();
    if connections > 0 {
        parts.push(ngettext_f(
            "Imported {n} connection.",
            "Imported {n} connections.",
            connections,
            &[("n", &connections.to_string())],
        ));
    }
    if let Some(Ok(queries)) = &queries {
        if queries.added > 0 {
            parts.push(ngettext_f(
                "Added {n} saved query.",
                "Added {n} saved queries.",
                queries.added,
                &[("n", &queries.added.to_string())],
            ));
        }
        if queries.failed > 0 {
            parts.push(ngettext_f(
                "{n} saved query could not be added.",
                "{n} saved queries could not be added.",
                queries.failed,
                &[("n", &queries.failed.to_string())],
            ));
        }
    } else if let Some(Err(error)) = queries {
        tracing::warn!(%error, "saved query import could not finish");
        parts.push(match error {
            SavedConnectionError::NotFound(_) => {
                gettext("Saved query import was interrupted because a connection was deleted.")
            }
            _ => gettext("Saved query import could not finish. Some queries may have been saved."),
        });
    } else if !queries_available && !imported.applied.queries.is_empty() {
        parts.push(gettext(
            "Saved queries were not added: the query history is not available.",
        ));
    }
    if imported.secrets_not_kept > 0 {
        parts.push(ngettext_f(
            "{n} password could not be kept in the keyring.",
            "{n} passwords could not be kept in the keyring.",
            imported.secrets_not_kept,
            &[("n", &imported.secrets_not_kept.to_string())],
        ));
    }
    if parts.is_empty() {
        return gettext("Nothing was imported.");
    }
    parts.join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn query_cleanup_failures_are_visible_without_claiming_success() {
        let imported = ImportedFromApp {
            applied: Default::default(),
            secrets_not_kept: 0,
        };
        let message = imported_message(
            &imported,
            Some(Err(SavedConnectionError::Storage(StorageError::NotInitialised))),
            true,
        );
        assert_eq!(
            message,
            "Saved query import could not finish. Some queries may have been saved."
        );
        let message = imported_message(
            &imported,
            Some(Err(SavedConnectionError::NotFound(uuid::Uuid::new_v4()))),
            true,
        );
        assert_eq!(
            message,
            "Saved query import was interrupted because a connection was deleted."
        );
    }

    #[gtk4::test]
    fn an_idle_picker_window_ends_its_search_to_show_an_import_from_a_session() {
        use crate::services::library_outline::LibrarySection;
        use crate::test_support::{descendants, saved_connection, wait_until};
        use crate::ui::session_window::tests::{TestWindow, WAIT};
        use crate::ui::welcome_view::WelcomeView;

        let test = TestWindow::connected("ImportRevealIdlePicker");
        let picker = test
            .app
            .open_window(WindowLaunch::Picker)
            .and_then(|window| window.downcast::<SessionWindow>().ok())
            .expect("a picker window");
        wait_until(WAIT, || picker.page_name() == "picker").expect("the second window's picker");
        let (bar, entry) = picker.picker_search().expect("the picker's search");
        bar.set_search_mode(true);
        entry.set_text("nothing-like-it");
        let (first, second) = (saved_connection("first"), saved_connection("second"));
        let store = test.services.storage.connections();
        store.upsert_blocking(first.clone()).expect("the save");
        store.upsert_blocking(second.clone()).expect("the save");

        test.window
            .hand_off_import(SetupEnding::Select(vec![first.id, second.id]));

        assert!(!bar.is_search_mode(), "the search stayed open");
        assert_eq!(entry.text(), "");
        let view = descendants(&picker)
            .into_iter()
            .find_map(|widget| widget.downcast::<WelcomeView>().ok())
            .expect("the picker");
        wait_until(WAIT, || {
            view.visible_page().as_deref() == Some("list") && view.node(LibrarySection::Tree, "first").is_some()
        })
        .expect("the imported connections listed");
        wait_until(WAIT, || view.focused_title().as_deref() == Some("first"))
            .expect("the first imported connection to take the focus");
    }

    #[test]
    fn imported_connections_are_shown_here_only_from_the_picker() {
        assert_eq!(reveal_place(SessionPage::Picker), RevealPlace::Here);
        for hidden in [
            SessionPage::Shell,
            SessionPage::Connecting(1),
            SessionPage::Failed,
            SessionPage::Setup,
        ] {
            assert_eq!(reveal_place(hidden), RevealPlace::PickerWindow, "{hidden:?}");
        }
    }
}
