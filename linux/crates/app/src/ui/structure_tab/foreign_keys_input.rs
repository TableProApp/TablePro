use tablepro_core::ForeignKeyInfo;

use super::foreign_key_object::ForeignKeyObject;

/// What changes the draft's foreign keys.
#[derive(Debug)]
pub(crate) enum ForeignKeysInput {
    AddForeignKey(ForeignKeyInfo),
    RemoveForeignKey(ForeignKeyObject),
}
