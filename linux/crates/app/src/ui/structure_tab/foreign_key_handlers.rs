use super::foreign_key_object::ForeignKeyObject;
use super::{ForeignKeysInput, StructureEffects, StructureModel};

impl StructureModel {
    pub(super) fn on_foreign_keys(&mut self, input: ForeignKeysInput, fx: &mut StructureEffects) {
        match input {
            ForeignKeysInput::AddForeignKey(key) => {
                self.foreign_keys.append(&ForeignKeyObject::new(key));
                self.recompute_dirty_state(fx);
            }
            ForeignKeysInput::RemoveForeignKey(key) => {
                if let Some(position) = self.foreign_keys.find(&key) {
                    self.foreign_keys.remove(position);
                    self.recompute_dirty_state(fx);
                }
            }
        }
    }
}
