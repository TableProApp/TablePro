use crate::foreign_key_mode::ForeignKeyMode;
use crate::meta::TableRef;
use crate::statement::{GuardedStatement, Statement, StatementBuilder};
use crate::write_batch::{WriteBatch, WriteKind};

/// The statements a structure change runs, in order, and whether foreign
/// keys stay on while they do.
#[derive(Debug, Clone, PartialEq)]
pub struct DdlPlan {
    pub statements: Vec<Statement>,
    pub foreign_keys: ForeignKeyMode,
}

impl DdlPlan {
    /// SQL the engine's DDL dialect wrote, with every name quoted by it
    /// and nothing to bind.
    pub fn from_sql(statements: impl IntoIterator<Item = String>) -> Self {
        Self {
            statements: statements
                .into_iter()
                .map(|sql| {
                    let mut builder = StatementBuilder::new();
                    builder.push_sql(&sql);
                    builder.finish()
                })
                .collect(),
            foreign_keys: ForeignKeyMode::Enforced,
        }
    }

    pub fn is_empty(&self) -> bool {
        self.statements.is_empty()
    }

    pub fn len(&self) -> usize {
        self.statements.len()
    }

    pub fn sql(&self) -> Vec<&str> {
        self.statements.iter().map(Statement::sql).collect()
    }

    /// The plan as the user reads it before Save: each statement ended
    /// and set apart.
    pub fn preview(&self) -> String {
        self.statements
            .iter()
            .map(|statement| format!("{};", statement.sql()))
            .collect::<Vec<_>>()
            .join("\n\n")
    }

    /// Schema statements have no row count to prove.
    pub fn into_steps(self) -> Vec<GuardedStatement> {
        self.statements.into_iter().map(GuardedStatement::unguarded).collect()
    }

    /// `table` is the table as it is named before the plan runs.
    pub fn into_write_batch(self, table: TableRef) -> WriteBatch {
        let foreign_keys = self.foreign_keys.clone();
        WriteBatch::new(WriteKind::SchemaChanges, table, self.into_steps(), foreign_keys)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_plan_becomes_an_unguarded_schema_write() {
        let plan = DdlPlan::from_sql(["ALTER TABLE t ADD COLUMN a text".to_owned(), "DROP INDEX i".to_owned()]);

        assert_eq!(plan.preview(), "ALTER TABLE t ADD COLUMN a text;\n\nDROP INDEX i;");
        let batch = plan.into_write_batch(TableRef::unqualified("t"));

        assert_eq!(batch.kind, WriteKind::SchemaChanges);
        assert!(batch.foreign_keys.is_enforced());
        assert!(batch.steps.iter().all(|step| step.statement.params().is_empty()));
        assert_eq!(batch.steps[1].statement.sql(), "DROP INDEX i");
    }
}
