use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use uuid::Uuid;

use tablepro_core::WriteKind;

use super::{WorkspaceInput, WorkspaceModel};
use crate::runtime::DeliverInput;
use crate::ui::{browse_tab, structure_tab};
use crate::workspace::{
    CloseScope, DirtyTab, SaveOutcome, SaveSettled, SaveStart, WorkKind, WorkOutcome, WorkspaceEvent,
};

impl WorkspaceModel {
    /// Save one tab, from its own Save button or Ctrl+S. A structure
    /// save may wait on its review first.
    pub(super) fn request_save(&self, tab: Uuid) {
        let Some(parent) = self.dialog_parent() else {
            return;
        };
        let (handle, input) = (self.workspace_handle.clone(), self.input.clone());
        glib::spawn_future_local(async move {
            for start in handle.save(&parent, &[tab]).await {
                match start {
                    SaveStart::Started(save) => tracing::debug!(?save, %tab, "save started"),
                    SaveStart::Rejected(rejection) if rejection.needs_alert() => {
                        input.deliver(WorkspaceInput::ShowAlert {
                            title: crate::i18n::gettext("Cannot Save"),
                            body: rejection.message(),
                        });
                    }
                    SaveStart::Saved | SaveStart::NothingToSave | SaveStart::Rejected(_) => {}
                }
            }
        });
    }

    pub(super) fn stop_saving(&self, tab: Uuid) {
        self.workspace_handle.stop_saves(CloseScope::Tab(tab));
    }

    pub(super) fn on_workspace_event(&mut self, event: WorkspaceEvent) {
        match event {
            WorkspaceEvent::SaveStarted { tab } => {
                self.dispatch_to_tab(tab, browse_tab::SaveInput::SaveStarted);
                self.send_to_structure_tab(tab, structure_tab::SaveInput::SaveStarted);
            }
            WorkspaceEvent::SaveSettled { settled, in_prompt } => self.on_save_settled(*settled, in_prompt),
            WorkspaceEvent::Discarded { tabs, reload } => {
                for tab in tabs {
                    let browse = match reload {
                        true => browse_tab::SaveInput::DiscardAndRefresh,
                        false => browse_tab::SaveInput::DiscardAll,
                    };
                    self.dispatch_to_tab(tab, browse);
                    let structure = match reload {
                        true => structure_tab::SaveInput::Reload,
                        false => structure_tab::SaveInput::Discard,
                    };
                    self.send_to_structure_tab(tab, structure);
                }
            }
        }
        self.refresh_unsaved();
    }

    /// The window's spinner and its logout inhibitor read whether any
    /// session is saving, so it is set before they hear.
    pub(super) fn on_saves_in_flight_changed(&mut self, count: usize) {
        if let Some(workspace) = self.this.upgrade() {
            workspace.imp().saving.set(count > 0);
            let count = u32::try_from(count).unwrap_or(u32::MAX);
            workspace.emit_by_name::<()>("saves-in-flight-changed", &[&count]);
        }
        self.refresh_unsaved();
    }

    fn on_save_settled(&mut self, settled: SaveSettled, in_prompt: bool) {
        let SaveSettled {
            tab,
            kind,
            outcome,
            failing,
            saved_table_name,
            origins,
        } = settled;
        let work = WorkOutcome::from(&outcome);
        match (kind, outcome) {
            (WriteKind::RowChanges, SaveOutcome::Committed { .. }) => {
                // No Undo button: the save has already committed, and
                // Ctrl+Z is for edits before Save. A shorter timeout
                // keeps the confirmation from outstaying the moment.
                let toast = adw::Toast::builder()
                    .title(crate::i18n::gettext("Saved"))
                    .use_markup(false)
                    .timeout(4)
                    .build();
                self.add_toast(toast);
                self.dispatch_to_tab(tab, browse_tab::SaveInput::SaveCommitted(origins));
            }
            (WriteKind::RowChanges, SaveOutcome::RolledBack(cause)) => {
                // The row behind the failing step is marked before the
                // error shows, so the user sees which one it was.
                if let Some(source) = failing {
                    self.dispatch_to_tab(tab, browse_tab::SaveInput::MarkErrorRow(source));
                }
                self.dispatch_to_tab(tab, browse_tab::SaveInput::SaveFailed(cause.message()));
            }
            (WriteKind::RowChanges, SaveOutcome::Unknown(cause)) => {
                let message = cause.sentence(&self.tab_name(tab));
                self.dispatch_to_tab(tab, browse_tab::SaveInput::SaveOutcomeUnknown(message));
            }
            (WriteKind::SchemaChanges, SaveOutcome::Committed { .. }) => {
                self.on_structure_save_completed(tab, saved_table_name);
            }
            (WriteKind::SchemaChanges, SaveOutcome::RolledBack(cause)) => {
                let input = match cause.found_changes() {
                    true => structure_tab::SaveInput::TableChangedBeforeSave,
                    false => structure_tab::SaveInput::SaveFailed(cause.message()),
                };
                self.send_to_structure_tab(tab, input);
            }
            (WriteKind::SchemaChanges, SaveOutcome::Unknown(cause)) => {
                let message = cause.sentence(&self.tab_name(tab));
                self.send_to_structure_tab(tab, structure_tab::SaveInput::SaveOutcomeUnknown(message));
            }
        }
        // The close prompt waited for the save in front of the user, and
        // goes on to close the tab or asks about it again.
        if !in_prompt {
            self.report_work(tab, WorkKind::Save, work);
        }
    }

    /// The tab's name for a sentence, quoted as the close prompts quote
    /// it.
    fn tab_name(&self, tab: Uuid) -> String {
        let title = self
            .workspace_tabs
            .borrow()
            .get(&tab)
            .map(|slot| slot.page().title().to_string());
        DirtyTab::quote(&title.unwrap_or_default())
    }
}
