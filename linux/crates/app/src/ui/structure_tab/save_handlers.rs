use gtk4 as gtk;
use gtk4::prelude::*;
use tablepro_core::ddl::TableDraft;

use super::save_gate::SaveGate;
use super::sql_preview::no_pending_changes;
use super::{
    ColumnsInput, SaveInput, StructureEffects, StructureMode, StructureModel, StructureTabInput, StructureTabOutput,
    StructureTabSender,
};
use crate::ui::discard_alert::confirm_discard;
use crate::ui::error_text::{build_error_text, save_blocker_text};

impl StructureModel {
    pub(super) fn on_save(&mut self, input: SaveInput, fx: &mut StructureEffects) {
        match input {
            SaveInput::Save => self.save(fx),
            SaveInput::SaveStarted => self.show_saving(true),
            SaveInput::StopSaving => fx.output(StructureTabOutput::StopSaveRequested),
            SaveInput::ConfirmDiscard => {
                let pending = self.pending().change_count();
                if pending > 0 {
                    let sender = StructureTabSender { tab: self.this.clone() };
                    confirm_discard(&self.widgets.inner_stack, pending, move || {
                        sender.input(SaveInput::Discard);
                    });
                }
            }
            SaveInput::Reload => {
                // A table the save may have created has nothing to read
                // yet, so a new one is only cleared.
                match self.mode() {
                    StructureMode::Edit => self.read_definition(fx),
                    StructureMode::New => fx.input(SaveInput::Discard),
                }
            }
            SaveInput::Discard => {
                // This also lets go of a save whose outcome was unknown.
                self.tracker.clear();
                if self.mode() == StructureMode::Edit && self.definition_stale {
                    fx.input(SaveInput::Reload);
                    return;
                }
                // New mode clears everything but the name, since a new
                // table starts empty.
                let restored = match self.context.borrow().original() {
                    Some(definition) => TableDraft::from_definition(definition),
                    None => TableDraft::new(self.table.clone()),
                };
                self.show_draft(restored);
                self.recompute_dirty_state(fx);
            }
            SaveInput::SaveCompleted { new_table_name } => self.save_completed(new_table_name, fx),
            SaveInput::SaveFailed(message) => {
                self.show_saving(false);
                self.recompute_dirty_state(fx);
                fx.output(StructureTabOutput::ShowAlert {
                    title: crate::i18n::gettext("Save Failed"),
                    body: message,
                });
            }
            SaveInput::TableChangedBeforeSave => {
                self.definition_stale = true;
                self.show_saving(false);
                self.recompute_dirty_state(fx);
                fx.output(StructureTabOutput::ShowAlert {
                    title: crate::i18n::gettext("Save Failed"),
                    body: crate::i18n::gettext(
                        "The table changed after this tab read it, so nothing was saved. Discard the changes to read the table again, then make them again.",
                    ),
                });
            }
            SaveInput::SaveOutcomeUnknown(message) => {
                self.show_saving(false);
                self.recompute_dirty_state(fx);
                fx.output(StructureTabOutput::ShowAlert {
                    title: crate::i18n::gettext("Save Result Unknown"),
                    body: message,
                });
            }
        }
    }

    fn save(&self, fx: &mut StructureEffects) {
        let pending = self.pending();
        match SaveGate::of(&pending) {
            SaveGate::Enabled => {}
            SaveGate::Blocked(blocker) => {
                fx.output(StructureTabOutput::ShowToast(save_blocker_text(&blocker)));
                return;
            }
            SaveGate::NothingToSave => {
                fx.output(StructureTabOutput::ShowToast(crate::i18n::gettext("Nothing to save.")));
                return;
            }
        }
        let context = self.context.borrow();
        let Some(ddl) = context.ddl() else {
            fx.output(StructureTabOutput::ShowToast(crate::i18n::gettext(
                "Connect to a database first.",
            )));
            return;
        };
        // Planned here only to refuse early in the user's words: the
        // window plans again with the connection that runs the save.
        match pending.plan(ddl) {
            Ok(_) => {
                self.tracker.set_pending(Some(pending));
                fx.output(StructureTabOutput::SaveRequested);
            }
            Err(error) => fx.output(StructureTabOutput::ShowAlert {
                title: crate::i18n::gettext("Cannot Save"),
                body: build_error_text(&error),
            }),
        }
    }

    /// While a save runs, Save and Discard are off, so a double click
    /// cannot send two, and Stop Saving takes their place.
    fn show_saving(&mut self, saving: bool) {
        self.saving = saving;
        self.widgets.saving_spinner.set_visible(saving);
        self.widgets.stop_button.set_visible(saving);
        if saving {
            self.widgets.save_button.set_sensitive(false);
            self.widgets.discard_button.set_sensitive(false);
        }
        self.sync_editable();
    }

    /// The draft holds still from the moment a save takes it until the
    /// table is read again after a commit. That read replaces the draft,
    /// so an edit made before it would be lost without a prompt.
    pub(super) fn edits_locked(&self) -> bool {
        self.saving || self.refetching || self.tracker.is_saving()
    }

    pub(super) fn sync_editable(&self) {
        let editable = !self.saving && !self.refetching;
        for widget in [
            self.widgets.name_row.upcast_ref::<gtk::Widget>(),
            self.widgets.columns_box.upcast_ref(),
            self.widgets.indexes_box.upcast_ref(),
            self.widgets.fks_box.upcast_ref(),
        ] {
            widget.set_sensitive(editable);
        }
    }

    /// An edit that reached the tab while its draft was locked, from a
    /// dialog opened before the save or a row the save had not turned
    /// off yet: the controls go back to what the draft holds.
    pub(super) fn refuse_edit(&self, msg: &StructureTabInput, fx: &mut StructureEffects) {
        self.show_table_name();
        if let StructureTabInput::Columns(ColumnsInput::ColumnEdited { column, .. }) = msg
            && let Some(position) = self.columns.find(column)
        {
            self.columns.splice(position, 1, std::slice::from_ref(column));
        }
        // The save landed and the read after it failed, so only Retry
        // unlocks the draft.
        let read_failed = self.refetching && !self.saving && !self.tracker.is_saving() && !self.load.is_running();
        let text = match read_failed {
            true => {
                crate::i18n::gettext("The table couldn't be read after the save. Retry, then make the change again.")
            }
            false => crate::i18n::gettext("Wait for the save to finish, then make the change again."),
        };
        fx.output(StructureTabOutput::ShowToast(text));
    }

    fn save_completed(&mut self, new_table_name: Option<String>, fx: &mut StructureEffects) {
        self.show_saving(false);
        if let Some(name) = new_table_name {
            self.context.borrow_mut().mode = StructureMode::Edit;
            self.table.name = name;
            self.show_table_name();
            self.widgets.drop_button.set_visible(!self.read_only);
            self.widgets.name_row.set_visible(false);
        }
        if self.mode() != StructureMode::Edit {
            return;
        }
        // The diff against the pre-save definition would show the changes
        // just committed as still pending until the read lands, and a
        // close in that window would offer to save them again. So the
        // dirty state goes to zero now, and so does a CREATE TABLE left
        // in the preview by a draft that just became the table.
        self.tracker.clear();
        self.refresh_buttons(0, true);
        self.widgets.sql_buffer.set_text(&no_pending_changes());
        if self.last_dirty {
            self.last_dirty = false;
            fx.output(StructureTabOutput::DirtyChanged(false));
        }
        self.refetching = true;
        self.sync_editable();
        self.read_definition(fx);
    }

    pub(super) fn refresh_buttons(&self, pending_count: usize, defaults_parsed: bool) {
        let has_pending = pending_count > 0 && !self.saving;
        self.widgets.save_button.set_sensitive(has_pending && defaults_parsed);
        self.widgets.discard_button.set_sensitive(has_pending);
        if has_pending {
            let label = crate::i18n::ngettext_f(
                "{n} pending change",
                "{n} pending changes",
                u32::try_from(pending_count).unwrap_or(u32::MAX),
                &[("n", &pending_count.to_string())],
            );
            self.widgets.pending_label.set_label(&label);
            self.widgets.pending_label.set_visible(true);
        } else {
            self.widgets.pending_label.set_visible(false);
        }
    }
}
