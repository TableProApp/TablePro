use libadwaita::prelude::*;
use tablepro_foreign_import::review::{ImportPlan, ImportReview, QueryImportOutcome, save_queries};
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
        let saved_queries = state.services.history().store().map(|history| history.saved_queries());
        crate::runtime::spawn_held(&state.services.tasks, &*state.services.hold(), async move {
            let message = match editor.add_imported(review, plan).await {
                Ok(imported) => {
                    let queries = match &saved_queries {
                        Some(store) if !imported.applied.queries.is_empty() => {
                            Some(save_queries(&imported.applied, store).await)
                        }
                        _ => None,
                    };
                    imported_message(&imported, queries, saved_queries.is_some())
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
    queries: Option<QueryImportOutcome>,
    queries_available: bool,
) -> String {
    let connections = imported.applied.connections.len();
    let mut parts = Vec::new();
    if connections > 0 {
        parts.push(ngettext_f(
            "Imported {n} connection.",
            "Imported {n} connections.",
            count(connections),
            &[("n", &connections.to_string())],
        ));
    }
    if let Some(queries) = queries {
        if queries.added > 0 {
            parts.push(ngettext_f(
                "Added {n} saved query.",
                "Added {n} saved queries.",
                count(queries.added),
                &[("n", &queries.added.to_string())],
            ));
        }
        if queries.failed > 0 {
            parts.push(ngettext_f(
                "{n} saved query could not be added.",
                "{n} saved queries could not be added.",
                count(queries.failed),
                &[("n", &queries.failed.to_string())],
            ));
        }
    } else if !queries_available && !imported.applied.queries.is_empty() {
        parts.push(gettext(
            "Saved queries were not added: the query history is not available.",
        ));
    }
    if imported.secrets_not_kept > 0 {
        parts.push(ngettext_f(
            "{n} password could not be kept in the keyring.",
            "{n} passwords could not be kept in the keyring.",
            count(imported.secrets_not_kept),
            &[("n", &imported.secrets_not_kept.to_string())],
        ));
    }
    if parts.is_empty() {
        return gettext("Nothing was imported.");
    }
    parts.join(" ")
}

fn count(n: usize) -> u32 {
    u32::try_from(n).unwrap_or(u32::MAX)
}
