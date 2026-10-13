use super::{
    BuildDdlError, ColumnAlteration, ColumnDefinition, ColumnRename, DdlDialect, DdlOperation, DraftColumn, Permission,
    PrimaryKeyChange, TableDefinition, primary_key_permission,
};
use crate::foreign_key_info::ForeignKeyInfo;
use crate::meta::{IndexInfo, IndexKey, TableRef};

/// Everything an edit changed about an existing table, which a DDL
/// dialect turns into its own statements in its own order.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct TableChanges {
    pub renamed_table: Option<String>,
    pub dropped_foreign_keys: Vec<ForeignKeyInfo>,
    pub dropped_indexes: Vec<IndexInfo>,
    pub dropped_columns: Vec<ColumnDefinition>,
    pub renamed_columns: Vec<ColumnRename>,
    pub altered_columns: Vec<ColumnAlteration>,
    pub added_columns: Vec<DraftColumn>,
    /// Follows from the columns' primary-key flags, so it is not a change
    /// of its own in `change_count`.
    pub primary_key: Option<PrimaryKeyChange>,
    pub added_indexes: Vec<IndexInfo>,
    pub added_foreign_keys: Vec<ForeignKeyInfo>,
}

impl TableChanges {
    pub fn is_empty(&self) -> bool {
        self.change_count() == 0 && self.primary_key.is_none()
    }

    /// One per edit the user made: a column renamed and retyped is two.
    pub fn change_count(&self) -> usize {
        usize::from(self.renamed_table.is_some())
            + self.dropped_foreign_keys.len()
            + self.dropped_indexes.len()
            + self.dropped_columns.len()
            + self.renamed_columns.len()
            + self.altered_columns.len()
            + self.added_columns.len()
            + self.added_indexes.len()
            + self.added_foreign_keys.len()
    }

    /// The table as it is named once the changes have run.
    pub fn target(&self, original: &TableRef) -> TableRef {
        match &self.renamed_table {
            Some(name) => TableRef::new(original.schema.clone(), name.clone()),
            None => original.clone(),
        }
    }

    /// Refuse a change the dialect says it cannot make, before any SQL
    /// is written. The structure tab gates its controls on the same
    /// answers, so this only fires for a caller that skipped them.
    pub fn check(&self, ddl: &dyn DdlDialect, original: &TableDefinition) -> Result<(), BuildDdlError> {
        let capabilities = ddl.capabilities();
        if self.renamed_table.is_some() {
            require(capabilities.rename_table, DdlOperation::RenameTable)?;
        }
        if !self.dropped_foreign_keys.is_empty() {
            require(capabilities.drop_foreign_key, DdlOperation::DropForeignKey)?;
        }
        if !self.dropped_indexes.is_empty() {
            require(capabilities.drop_index, DdlOperation::DropIndex)?;
        }
        for column in &self.dropped_columns {
            let permission = ddl.column_capabilities(original, column).drop;
            permit(permission, column.name(), DdlOperation::DropColumn)?;
        }
        for rename in &self.renamed_columns {
            if let Some(column) = original.column(&rename.from) {
                let permission = ddl.column_capabilities(original, column).rename;
                permit(permission, &rename.from, DdlOperation::RenameColumn)?;
            }
        }
        for alteration in &self.altered_columns {
            let permissions = ddl.column_capabilities(original, &alteration.original);
            let name = alteration.original.name();
            let changed = alteration.changed;
            let checks = [
                (
                    changed.column_type,
                    permissions.alter_type,
                    DdlOperation::AlterColumnType,
                ),
                (
                    changed.nullability,
                    permissions.alter_nullability,
                    DdlOperation::AlterColumnNullability,
                ),
                (
                    changed.default,
                    permissions.alter_default,
                    DdlOperation::AlterColumnDefault,
                ),
                (
                    changed.auto_increment,
                    permissions.alter_auto_increment,
                    DdlOperation::AlterAutoIncrement,
                ),
            ];
            for (changed, permission, operation) in checks {
                if changed {
                    permit(permission, name, operation)?;
                }
            }
            if changed.comment {
                require(capabilities.column_comments, DdlOperation::SetColumnComment)?;
            }
        }
        for column in &self.added_columns {
            require(capabilities.add_column, DdlOperation::AddColumn)?;
            if column.comment_text().is_some() {
                require(capabilities.column_comments, DdlOperation::SetColumnComment)?;
            }
        }
        if let Some(change) = &self.primary_key {
            let column = change
                .to
                .first()
                .or_else(|| change.from.as_ref().and_then(|key| key.columns.first()))
                .map_or("", String::as_str);
            permit(
                primary_key_permission(capabilities, original),
                column,
                DdlOperation::AlterPrimaryKey,
            )?;
        }
        check_new_indexes(ddl, &self.added_indexes)?;
        if !self.added_foreign_keys.is_empty() {
            require(capabilities.add_foreign_key, DdlOperation::AddForeignKey)?;
        }
        check_actions(ddl, &self.added_foreign_keys)
    }
}

pub(super) fn require(allowed: bool, operation: DdlOperation) -> Result<(), BuildDdlError> {
    match allowed {
        true => Ok(()),
        false => Err(BuildDdlError::Unsupported(operation)),
    }
}

fn permit(permission: Permission, column: &str, operation: DdlOperation) -> Result<(), BuildDdlError> {
    match permission {
        Permission::Allowed => Ok(()),
        Permission::Refused(reason) => Err(BuildDdlError::Refused {
            column: column.to_owned(),
            operation,
            reason,
        }),
    }
}

pub(super) fn check_new_indexes(ddl: &dyn DdlDialect, indexes: &[IndexInfo]) -> Result<(), BuildDdlError> {
    let capabilities = ddl.capabilities();
    for index in indexes.iter().filter(|index| !index.primary) {
        require(capabilities.create_index, DdlOperation::CreateIndex)?;
        if index.keys.iter().any(|key| matches!(key, IndexKey::Expression { .. })) {
            require(capabilities.expression_index_keys, DdlOperation::IndexExpressionKey)?;
        }
        if index.predicate.is_some() {
            require(capabilities.partial_indexes, DdlOperation::PartialIndex)?;
        }
    }
    Ok(())
}

pub(super) fn check_actions(ddl: &dyn DdlDialect, keys: &[ForeignKeyInfo]) -> Result<(), BuildDdlError> {
    let accepted = ddl.referential_actions();
    keys.iter()
        .flat_map(|key| [key.on_delete, key.on_update])
        .flatten()
        .find(|action| !accepted.contains(action))
        .map_or(Ok(()), |action| Err(BuildDdlError::ReferentialAction(action)))
}
