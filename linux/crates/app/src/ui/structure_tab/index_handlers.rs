use super::index_object::IndexObject;
use super::{IndexesInput, StructureEffects, StructureModel, StructureTabOutput};

impl StructureModel {
    pub(super) fn on_indexes(&mut self, input: IndexesInput, fx: &mut StructureEffects) {
        match input {
            IndexesInput::AddIndex(index) => {
                self.indexes.append(&IndexObject::new(index));
                self.recompute_dirty_state(fx);
            }
            IndexesInput::RemoveIndex(index) => {
                if let Some(position) = self.indexes.find(&index) {
                    self.indexes.remove(position);
                    self.recompute_dirty_state(fx);
                }
            }
            IndexesInput::CopyStatement(index) => {
                let (Some(sql), Some(tab)) = (index.create_statement(), self.this.upgrade()) else {
                    return;
                };
                let report = std::cell::RefCell::new(None);
                crate::ui::clipboard::copy_text(&tab, sql, |message| {
                    report.replace(Some(message.to_owned()));
                });
                if let Some(message) = report.into_inner() {
                    fx.output(StructureTabOutput::ShowToast(message));
                }
            }
            IndexesInput::ShowStatement(index) => {
                if let Some(sql) = index.create_statement() {
                    fx.output(StructureTabOutput::OpenInEditor(sql));
                }
            }
        }
    }
}
