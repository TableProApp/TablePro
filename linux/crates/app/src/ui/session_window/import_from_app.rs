use libadwaita::prelude::*;
use tablepro_foreign_import::review::{ImportPlan, ImportReview, QueryImportOutcome};
use tablepro_storage::StorageError;

use super::{SessionWindow, SessionWindowInput};
use crate::i18n::{gettext, ngettext_f};
use crate::runtime::DeliverInput;
use crate::services::saved_connection_editor::ImportedFromApp;
use crate::services::saved_connection_error::SavedConnectionError;
use crate::ui::import_from_app::{ImportFromAppDialog, ImportFromAppInit};

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
                    window.import_from_app(review, plan);
                }
            }),
        });
        dialog.present(Some(self));
    }

    fn import_from_app(&self, review: ImportReview, plan: ImportPlan) {
        let (Some(state), Some(input)) = (self.state(), self.input()) else {
            return;
        };
        let editor = state.services.saved_connection_editor.clone();
        let history = state.services.history().ready_store();
        crate::runtime::spawn_held(&state.services.tasks, &*state.services.hold(), async move {
            let message = match editor.add_imported(review, plan).await {
                Ok(imported) => {
                    let (queries, queries_available) = if imported.applied.queries.is_empty() {
                        (None, false)
                    } else if let Some(history) = history.await {
                        let store = history.saved_queries();
                        (
                            Some(editor.save_imported_queries(&imported.applied, &store).await),
                            true,
                        )
                    } else {
                        (None, false)
                    };
                    imported_message(&imported, queries, queries_available)
                }
                Err(SavedConnectionError::Storage(StorageError::ImportOutdated)) => {
                    gettext("The saved connections changed while you were deciding. Import again.")
                }
                Err(error) => {
                    tracing::warn!(%error, "could not import from another app");
                    crate::ui::error_text::saved_connection_error_message(&error)
                }
            };
            input.deliver(SessionWindowInput::ShowToast(message));
        });
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
}
