use super::{DdlPlan, DestructiveChange, DraftType, TableChanges};
use crate::write_ledger::WriteAtomicity;

/// What a structure save runs and what it loses, for the user to read
/// before it runs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChangeReview {
    /// The edits the user made, counted as the action bar counts them.
    pub operations: usize,
    pub statements: Vec<String>,
    /// The rebuild first, then the drops and type changes.
    pub destructive: Vec<DestructiveChange>,
}

impl ChangeReview {
    /// `plan` is the one the engine wrote for `changes`, which may drop
    /// more than the changes name: a rebuild drops the whole table.
    pub fn review(changes: &TableChanges, plan: &DdlPlan) -> Self {
        let mut destructive: Vec<DestructiveChange> = plan
            .rebuild
            .iter()
            .cloned()
            .map(DestructiveChange::RebuildTable)
            .collect();
        destructive.extend(
            changes
                .dropped_columns
                .iter()
                .map(|column| DestructiveChange::DropColumn {
                    column: column.name().to_owned(),
                }),
        );
        destructive.extend(
            changes
                .altered_columns
                .iter()
                .filter(|alteration| alteration.changed.column_type)
                .map(|alteration| {
                    let before = &alteration.original.info.column_type;
                    let from = match DraftType::Catalog(before.clone()).text() {
                        "" => before.name.clone(),
                        declaration => declaration.to_owned(),
                    };
                    DestructiveChange::ChangeColumnType {
                        column: alteration.original.name().to_owned(),
                        from,
                        to: alteration.draft.column_type.text().to_owned(),
                    }
                }),
        );
        destructive.extend(
            changes
                .dropped_indexes
                .iter()
                .map(|index| DestructiveChange::DropIndex {
                    index: index.name.clone(),
                }),
        );
        destructive.extend(
            changes
                .dropped_foreign_keys
                .iter()
                .map(|key| DestructiveChange::DropForeignKey { key: key.name.clone() }),
        );
        Self {
            operations: changes.change_count(),
            statements: statements(plan),
            destructive,
        }
    }

    /// A new table: one edit, and nothing there yet to lose.
    pub fn create(plan: &DdlPlan) -> Self {
        Self {
            operations: 1,
            statements: statements(plan),
            destructive: Vec::new(),
        }
    }

    /// Whether the user has to agree first: when something is lost, or
    /// when a statement that fails leaves the ones before it applied.
    pub fn requires_confirmation(&self, ddl_writes: WriteAtomicity) -> bool {
        !self.destructive.is_empty()
            || (ddl_writes == WriteAtomicity::StatementByStatement && self.statements.len() > 1)
    }

    /// Whether `plan` runs exactly the statements reviewed.
    pub fn matches(&self, plan: &DdlPlan) -> bool {
        plan.sql().into_iter().eq(self.statements.iter().map(String::as_str))
    }

    /// The statements as the review shows them, each ended and set apart.
    pub fn sql(&self) -> String {
        self.statements
            .iter()
            .map(|statement| format!("{statement};"))
            .collect::<Vec<_>>()
            .join("\n\n")
    }
}

fn statements(plan: &DdlPlan) -> Vec<String> {
    plan.sql().into_iter().map(str::to_owned).collect()
}
