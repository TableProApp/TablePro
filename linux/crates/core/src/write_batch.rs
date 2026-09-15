use crate::meta::TableRef;
use crate::statement::GuardedStatement;

/// What a write is changing, which decides how it is wrapped.
///
/// Row changes and schema changes differ in more than their SQL: an
/// engine may be transactional for one and not the other, and a schema
/// change runs without the statement timeout a row edit gets.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum WriteKind {
    RowChanges,
    SchemaChanges,
}

/// One save, as the steps that make it up.
///
/// The table travels with the steps because whether the engine can undo
/// them is a property of that table, not of the server: MySQL decides
/// it per storage engine.
#[derive(Debug, Clone, PartialEq)]
pub struct WriteBatch {
    pub kind: WriteKind,
    pub table: TableRef,
    pub steps: Vec<GuardedStatement>,
}

impl WriteBatch {
    pub fn new(kind: WriteKind, table: TableRef, steps: Vec<GuardedStatement>) -> Self {
        Self { kind, table, steps }
    }

    pub fn is_empty(&self) -> bool {
        self.steps.is_empty()
    }

    pub fn len(&self) -> usize {
        self.steps.len()
    }
}
