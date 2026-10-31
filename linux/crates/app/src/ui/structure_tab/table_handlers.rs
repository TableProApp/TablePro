use gtk4::prelude::*;

use super::{StructureEffects, StructureModel, StructureTabOutput, TableInput};

impl StructureModel {
    pub(super) fn on_table(&mut self, input: TableInput, fx: &mut StructureEffects) {
        match input {
            TableInput::TableNameEdited(text) => {
                if self.table.name == text {
                    return;
                }
                self.table.name = text;
                self.recompute_dirty_state(fx);
            }
            TableInput::CharacterSetPicked(name) => self.pick_table_character_set(name, fx),
            TableInput::CollationPicked(name) => self.edit_table_options(fx, |options| options.collation = Some(name)),
            TableInput::ConvertColumnsToggled(converts) => {
                self.edit_table_options(fx, |options| options.converts_columns = converts);
            }
            TableInput::NextAutoIncrementEdited(text) => {
                self.next_auto_increment.text = text;
                self.recompute_dirty_state(fx);
            }
            TableInput::DropTableRequested => {
                if self.read_only {
                    tracing::error!("Drop reached a structure tab on a read-only connection");
                    return;
                }
                let table = match &self.context.borrow().definition {
                    Some(definition) => definition.table.clone(),
                    None => self.table.clone(),
                };
                fx.output(StructureTabOutput::DropTableRequested {
                    schema: table.schema,
                    table: table.name,
                });
            }
        }
    }

    /// Write the draft's name into the entry without it reading as an
    /// edit.
    pub(super) fn show_table_name(&self) {
        if self.widgets.name_entry.text() == self.table.name {
            return;
        }
        self.widgets.name_entry.block_signal(&self.widgets.name_changed);
        self.widgets.name_entry.set_text(&self.table.name);
        self.widgets.name_entry.unblock_signal(&self.widgets.name_changed);
    }
}
