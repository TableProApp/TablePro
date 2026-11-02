use crate::statement::Statement;

/// What the schema has to hold for a plan to apply, counted in the
/// write's transaction before its first statement. A plan that writes
/// a table again from the definition it was built from would otherwise
/// undo whatever changed the table after that read.
#[derive(Debug, Clone, PartialEq)]
pub struct DdlPrecondition {
    pub probe: Statement,
    /// The count the probe has to return.
    pub rows: u64,
}
