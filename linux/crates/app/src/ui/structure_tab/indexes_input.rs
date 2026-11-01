use tablepro_core::IndexInfo;

use super::index_object::IndexObject;

/// What changes the draft's indexes.
#[derive(Debug)]
pub(crate) enum IndexesInput {
    AddIndex(IndexInfo),
    RemoveIndex(IndexObject),
    CopyStatement(IndexObject),
    ShowStatement(IndexObject),
}
