use super::{ChangedAttributes, ColumnDefinition, DraftColumn};

/// A kept column whose definition changed. The draft carries the name
/// the column has once its rename, if any, has run.
#[derive(Debug, Clone, PartialEq)]
pub struct ColumnAlteration {
    pub original: ColumnDefinition,
    pub draft: DraftColumn,
    pub changed: ChangedAttributes,
}
