use std::sync::Arc;

use libadwaita::prelude::*;
use tablepro_core::meta::ObjectInfo;
use tablepro_session::runtime::TaskFailure;
use tablepro_session::{OperationError, OperationKind, Session};

use crate::runtime::DeliverInput;
use crate::ui::definition_dialog::{definition_dialog, no_definition_alert};
use crate::ui::error_text;
use crate::ui::workspace::{WorkspaceInput, WorkspaceModel};

impl WorkspaceModel {
    /// Read the SQL that defines a routine, a sequence or a trigger, then
    /// show it.
    pub(super) fn on_show_definition(&self, object: ObjectInfo) {
        let title = crate::i18n::gettext("Could Not Show Definition");
        let Some(session) = self.context.active.get() else {
            self.show_error_alert(&title, &crate::i18n::gettext("No active connection."));
            return;
        };
        let work = read_definition(session, object.clone());
        let input = self.input.clone();
        crate::runtime::spawn_and_deliver(&self.context.tasks, work, move |result| {
            match result.unwrap_or_else(|failure: TaskFailure| Err(failure.into())) {
                Ok(sql) => input.deliver(WorkspaceInput::DefinitionLoaded { object, sql }),
                Err(error) => input.deliver(WorkspaceInput::ShowAlert {
                    title,
                    body: crate::i18n::gettext_f(
                        "Couldn't read the definition: {error}",
                        &[("error", &error_text::operation_error_message(&error))],
                    ),
                }),
            }
        });
    }

    pub(super) fn on_definition_loaded(&self, object: &ObjectInfo, sql: &str) {
        let parent = self.dialog_parent();
        if sql.trim().is_empty() {
            no_definition_alert(object).present(parent.as_ref());
            return;
        }
        let input = self.input.clone();
        let dialog = definition_dialog(object, sql, move |sql| {
            input.deliver(WorkspaceInput::OpenDefinitionInEditor(sql));
        });
        dialog.present(parent.as_ref());
    }
}

async fn read_definition(session: Arc<Session>, object: ObjectInfo) -> Result<String, OperationError> {
    session
        .run(OperationKind::Metadata, move |lease, options| {
            let object = object.clone();
            async move { Ok(lease.fetch_object_definition(&object, options).await?) }
        })
        .await
}
