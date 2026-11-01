use super::index_object::IndexObject;
use super::{IndexesInput, StructureEffects, StructureModel};

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
        }
    }
}
