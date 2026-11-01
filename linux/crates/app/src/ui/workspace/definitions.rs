use std::sync::Arc;

use libadwaita::prelude::*;
use tablepro_core::meta::{ObjectDefinition, ObjectInfo};
use tablepro_session::runtime::TaskFailure;
use tablepro_session::{OperationError, OperationKind, Session};

use crate::runtime::DeliverInput;
use crate::ui::definition_dialog::{definition_dialog, no_definition_alert};
use crate::ui::error_text;
use crate::ui::workspace::{WorkspaceInput, WorkspaceModel};

#[derive(Debug)]
pub(super) struct DefinitionRead {
    id: u64,
    object: ObjectInfo,
}

impl WorkspaceModel {
    /// A second ask for the object being read waits on that read, and an
    /// ask for another object supersedes it: a read cannot be stopped, so
    /// only the last one asked for is shown.
    pub(super) fn on_show_definition(&mut self, object: ObjectInfo) {
        if self.definition_read.as_ref().is_some_and(|read| read.object == object) {
            return;
        }
        let Some(session) = self.context.active.get() else {
            self.show_error_alert(
                &crate::i18n::gettext("Could Not Show Definition"),
                &crate::i18n::gettext("No active connection."),
            );
            return;
        };
        self.definition_reads += 1;
        let id = self.definition_reads;
        self.definition_read = Some(DefinitionRead {
            id,
            object: object.clone(),
        });
        let work = read_definition(session, object.clone());
        let input = self.input.clone();
        crate::runtime::spawn_and_deliver(&self.context.tasks, work, move |result| {
            input.deliver(WorkspaceInput::DefinitionLoaded {
                read: id,
                object,
                result: result.unwrap_or_else(|failure: TaskFailure| Err(failure.into())),
            });
        });
    }

    pub(super) fn on_definition_loaded(
        &mut self,
        read: u64,
        object: &ObjectInfo,
        result: Result<Option<ObjectDefinition>, OperationError>,
    ) {
        if self.definition_read.as_ref().is_none_or(|pending| pending.id != read) {
            return;
        }
        self.definition_read = None;
        if let Ok(None) = result {
            // The row is most likely stale: the object was dropped since the list was read.
            self.refresh_catalog();
        }
        // The user went to another session while it was read, so a dialog
        // now would sit over that one.
        if !self.is_front() {
            return;
        }
        let parent = self.dialog_parent();
        let ObjectDefinition { sql, database } = match result {
            Ok(Some(definition)) => definition,
            Ok(None) => {
                no_definition_alert(object).present(parent.as_ref());
                return;
            }
            Err(error) => {
                self.show_error_alert(
                    &crate::i18n::gettext("Could Not Show Definition"),
                    &crate::i18n::gettext_f(
                        "Couldn't read the definition: {error}",
                        &[("error", &error_text::operation_error_message(&error))],
                    ),
                );
                return;
            }
        };
        let input = self.input.clone();
        let text = sql.clone();
        let dialog = definition_dialog(object, &sql, &self.settings, move || {
            input.deliver(WorkspaceInput::OpenSqlInEditor {
                sql: text.clone(),
                database: database.clone(),
            });
        });
        dialog.present(parent.as_ref());
    }
}

async fn read_definition(
    session: Arc<Session>,
    object: ObjectInfo,
) -> Result<Option<ObjectDefinition>, OperationError> {
    session
        .run(OperationKind::Metadata, move |lease, options| {
            let object = object.clone();
            async move { Ok(lease.fetch_object_definition(&object, options).await?) }
        })
        .await
}
