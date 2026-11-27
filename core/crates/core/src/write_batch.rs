use crate::error::DriverError;
use crate::foreign_key_mode::ForeignKeyMode;
use crate::meta::TableRef;
use crate::read_only_refusal::ReadOnlyRefusal;
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
    /// Creates or drops a database. PostgreSQL and SQL Server refuse
    /// that inside a transaction, so each statement runs on its own.
    DatabaseChanges,
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
    pub foreign_keys: ForeignKeyMode,
}

impl WriteBatch {
    pub fn new(kind: WriteKind, table: TableRef, steps: Vec<GuardedStatement>, foreign_keys: ForeignKeyMode) -> Self {
        Self {
            kind,
            table,
            steps,
            foreign_keys,
        }
    }

    pub fn is_empty(&self) -> bool {
        self.steps.is_empty()
    }

    pub fn len(&self) -> usize {
        self.steps.len()
    }

    /// Refuse a batch before anything is sent: a read-only connection
    /// never writes, and only SQLite can suspend foreign keys.
    pub fn precheck(&self, read_only: bool) -> Result<(), DriverError> {
        if read_only {
            return Err(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard));
        }
        self.foreign_keys.require_enforced()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::unsupported_feature::UnsupportedFeature;

    fn batch(foreign_keys: ForeignKeyMode) -> WriteBatch {
        WriteBatch::new(
            WriteKind::RowChanges,
            TableRef::new(None, "t"),
            Vec::new(),
            foreign_keys,
        )
    }

    #[test]
    fn a_read_only_connection_and_suspended_foreign_keys_are_refused() {
        assert_eq!(batch(ForeignKeyMode::Enforced).precheck(false), Ok(()));
        assert_eq!(
            batch(ForeignKeyMode::Enforced).precheck(true),
            Err(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard))
        );
        assert_eq!(
            batch(ForeignKeyMode::SuspendedThenVerified { checks: Vec::new() }).precheck(false),
            Err(DriverError::Unsupported {
                feature: UnsupportedFeature::ForeignKeySuspension,
            })
        );
    }
}
