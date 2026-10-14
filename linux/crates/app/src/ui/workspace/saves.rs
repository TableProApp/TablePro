use gtk4::prelude::*;
use libadwaita as adw;
use uuid::Uuid;

use tablepro_core::WriteKind;

use super::WorkspaceModel;
use crate::ui::browse_tab::BrowseTabInput;
use crate::ui::structure_tab::StructureTabInput;
use crate::workspace::{CloseScope, DirtyTab, SaveOutcome, SaveSettled, SaveStart, WorkspaceEvent};

impl WorkspaceModel {
    /// Save one tab, from its own Save button or Ctrl+S.
    pub(super) fn request_save(&self, tab: Uuid) {
        for start in self.workspace_handle.save(&[tab]) {
            match start {
                SaveStart::Started(save) => tracing::debug!(?save, %tab, "save started"),
                SaveStart::Rejected(rejection) if rejection.needs_alert() => {
                    self.show_error_alert(&crate::i18n::gettext("Cannot Save"), &rejection.message());
                }
                SaveStart::NothingToSave | SaveStart::Rejected(_) => {}
            }
        }
    }

    pub(super) fn stop_saving(&self, tab: Uuid) {
        self.workspace_handle.stop_saves(CloseScope::Tab(tab));
    }

    pub(super) fn on_workspace_event(&mut self, event: WorkspaceEvent) {
        match event {
            WorkspaceEvent::SaveStarted { tab } => {
                self.dispatch_to_tab(tab, BrowseTabInput::SaveStarted);
                self.send_to_structure_tab(tab, StructureTabInput::SaveStarted);
            }
            WorkspaceEvent::SaveSettled(settled) => self.on_save_settled(*settled),
            WorkspaceEvent::Discarded { tabs, reload } => {
                for tab in tabs {
                    let browse = match reload {
                        true => BrowseTabInput::DiscardAndRefresh,
                        false => BrowseTabInput::DiscardAll,
                    };
                    self.dispatch_to_tab(tab, browse);
                    let structure = match reload {
                        true => StructureTabInput::Reload,
                        false => StructureTabInput::Discard,
                    };
                    self.send_to_structure_tab(tab, structure);
                }
            }
        }
        self.refresh_inhibitor();
    }

    pub(super) fn on_saves_in_flight_changed(&mut self, count: usize) {
        self.set_row_op_in_flight(count > 0);
        if let Some(workspace) = self.this.upgrade() {
            let count = u32::try_from(count).unwrap_or(u32::MAX);
            workspace.emit_by_name::<()>("saves-in-flight-changed", &[&count]);
        }
        self.refresh_inhibitor();
    }

    fn on_save_settled(&mut self, settled: SaveSettled) {
        let SaveSettled {
            tab,
            kind,
            outcome,
            failing,
            saved_table_name,
        } = settled;
        match (kind, outcome) {
            (WriteKind::RowChanges, SaveOutcome::Committed { .. }) => {
                // No Undo button: the save has already committed, and
                // Ctrl+Z is for edits before Save. A shorter timeout
                // keeps the confirmation from outstaying the moment.
                let toast = adw::Toast::builder()
                    .title(crate::i18n::gettext("Saved"))
                    .timeout(4)
                    .build();
                self.toast_overlay.add_toast(toast);
                self.dispatch_to_tab(tab, BrowseTabInput::SaveCommitted);
            }
            (WriteKind::RowChanges, SaveOutcome::RolledBack(cause)) => {
                // The row behind the failing step is flashed before the
                // error shows, so the user sees which one it was.
                if let Some(source) = failing {
                    self.dispatch_to_tab(tab, BrowseTabInput::FlashErrorRow(source));
                }
                self.dispatch_to_tab(tab, BrowseTabInput::SaveFailed(cause.message()));
            }
            (WriteKind::RowChanges, SaveOutcome::Unknown(cause)) => {
                let message = cause.sentence(&self.tab_name(tab));
                self.dispatch_to_tab(tab, BrowseTabInput::SaveOutcomeUnknown(message));
            }
            (WriteKind::SchemaChanges, SaveOutcome::Committed { .. }) => {
                self.on_structure_save_completed(tab, saved_table_name);
            }
            (WriteKind::SchemaChanges, SaveOutcome::RolledBack(cause)) => {
                let input = match cause.found_changes() {
                    true => StructureTabInput::TableChangedBeforeSave,
                    false => StructureTabInput::SaveFailed(cause.message()),
                };
                self.send_to_structure_tab(tab, input);
            }
            (WriteKind::SchemaChanges, SaveOutcome::Unknown(cause)) => {
                let message = cause.sentence(&self.tab_name(tab));
                self.send_to_structure_tab(tab, StructureTabInput::SaveOutcomeUnknown(message));
            }
        }
    }

    /// The tab's name for a sentence, quoted as the close prompts quote
    /// it.
    fn tab_name(&self, tab: Uuid) -> String {
        let title = self.workspace_tabs.borrow().get(&tab).map(|slot| {
            let title = slot.page().title();
            title.strip_prefix("• ").unwrap_or(&title).to_owned()
        });
        DirtyTab::quote(&title.unwrap_or_default())
    }
}
