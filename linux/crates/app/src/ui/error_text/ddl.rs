//! DDL refusals and problems in the user's words, for the Structure tab
//! and for a save refused before it starts.

use tablepro_core::ddl::{BuildDdlError, DdlOperation, DraftProblem, RefusalReason};

use crate::services::pending_structure::SaveBlocker;

/// Why a control is off, for its tooltip.
pub fn refusal_text(reason: &RefusalReason) -> String {
    match reason {
        RefusalReason::EngineUnsupported => crate::i18n::gettext("This database can't make this change."),
        RefusalReason::KeyColumn => crate::i18n::gettext(
            "This column is part of the table's sorting or partition key, which only rebuilding the table can change.",
        ),
        RefusalReason::GeneratedColumn => crate::i18n::gettext("The database computes this column."),
        RefusalReason::IdentityColumn => {
            crate::i18n::gettext("The database numbers this column, so it has no default.")
        }
        RefusalReason::NotAnInteger => crate::i18n::gettext("Only an integer column can number itself."),
        RefusalReason::UnmodeledAttribute(attribute) => crate::i18n::gettext_f(
            "This column has an attribute TablePro can't restate: {attribute}",
            &[("attribute", attribute)],
        ),
        RefusalReason::ColumnInUse(users) => {
            crate::i18n::gettext_f("Still used by {users}.", &[("users", &users.join(", "))])
        }
        RefusalReason::ReferencedByForeignKeys(keys) => crate::i18n::gettext_f(
            "Foreign keys on other tables depend on it: {keys}",
            &[("keys", &keys.join(", "))],
        ),
        RefusalReason::UnreadableDefinition => {
            crate::i18n::gettext("The database didn't report this column's full definition.")
        }
        RefusalReason::ConflictingAttribute(attribute) => crate::i18n::gettext_f(
            "This column's {attribute} doesn't allow this change.",
            &[("attribute", attribute)],
        ),
        RefusalReason::NamesRenamedColumn(column) => crate::i18n::gettext_f(
            "Its definition names column {column}, which this save renames. Save the rename on its own first.",
            &[("column", column)],
        ),
    }
}

/// The first thing to fix before Save.
fn draft_problem_text(problem: &DraftProblem) -> String {
    match problem {
        DraftProblem::EmptyTableName => crate::i18n::gettext("Table name is required."),
        DraftProblem::NoColumns => crate::i18n::gettext("At least one column is required."),
        DraftProblem::EmptyColumnName => crate::i18n::gettext("Every column needs a name."),
        DraftProblem::DuplicateColumnName(name) => {
            crate::i18n::gettext_f("Duplicate column name: {name}", &[("name", name)])
        }
        DraftProblem::EmptyColumnType(name) => crate::i18n::gettext_f("Column {name} needs a type.", &[("name", name)]),
        DraftProblem::NullablePrimaryKey(name) => {
            crate::i18n::gettext_f("Primary key columns must be NOT NULL: {name}", &[("name", name)])
        }
        DraftProblem::ColumnInUse { column, used_by } => crate::i18n::gettext_f(
            "Column {column} is removed but {users} still use it. Remove them first.",
            &[("column", column), ("users", &used_by.join(", "))],
        ),
        DraftProblem::EmptyIndexName => crate::i18n::gettext("Index name is required."),
        DraftProblem::IndexWithoutKeys(name) => {
            crate::i18n::gettext_f("Index {name} has no columns.", &[("name", name)])
        }
        DraftProblem::EmptyForeignKeyName => crate::i18n::gettext("Foreign key name is required."),
        DraftProblem::ForeignKeyColumnMismatch(name) => crate::i18n::gettext_f(
            "Foreign key {name} needs as many referenced columns as source columns.",
            &[("name", name)],
        ),
    }
}

/// Why Save, from the tab or from a close prompt, refused.
pub fn save_blocker_text(blocker: &SaveBlocker) -> String {
    match blocker {
        SaveBlocker::Draft(problem) => draft_problem_text(problem),
        SaveBlocker::UnparsedDefault(_) => crate::i18n::gettext("Fix the highlighted fields first."),
    }
}

/// Why the change could not be written as SQL.
pub fn build_error_text(error: &BuildDdlError) -> String {
    match error {
        BuildDdlError::Draft(problem) => draft_problem_text(problem),
        BuildDdlError::Refused { column, reason, .. } => crate::i18n::gettext_f(
            "Column {column} can't be changed this way. {reason}",
            &[("column", column), ("reason", &refusal_text(reason))],
        ),
        BuildDdlError::Unsupported(DdlOperation::AddRequiredColumnWithoutDefault) => crate::i18n::gettext(
            "A NOT NULL column needs a default here, since the rows already in the table need a value.",
        ),
        BuildDdlError::Unsupported(_) => crate::i18n::gettext("This database can't make this change."),
        BuildDdlError::InvalidType { column, error } => crate::i18n::gettext_f(
            "Column {column} has a type this database doesn't accept: {error}",
            &[("column", column), ("error", &error.to_string())],
        ),
        BuildDdlError::Literal { column, error } => crate::i18n::gettext_f(
            "The default of column {column} can't be written as SQL: {error}",
            &[("column", column), ("error", &error.to_string())],
        ),
        BuildDdlError::MissingCatalogDeclaration(column) => crate::i18n::gettext_f(
            "The database didn't report the type of column {column}.",
            &[("column", column)],
        ),
        BuildDdlError::ReferentialAction(action) => crate::i18n::gettext_f(
            "This database doesn't take {action} on a foreign key.",
            &[("action", action.as_sql())],
        ),
        BuildDdlError::NoTableSource => crate::i18n::gettext("The database gave no CREATE statement for this table."),
    }
}
