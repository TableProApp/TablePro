use std::collections::{BTreeMap, HashSet};

use super::table_changes::{check_actions, check_new_indexes, require};
use super::{BuildDdlError, DdlDialect, DdlOperation, DraftColumn, DraftProblem, TableDefinition};
use crate::foreign_key_info::ForeignKeyInfo;
use crate::meta::{IndexInfo, TableRef};

/// A table as the user is editing it: a new one, or an existing one
/// started from its definition.
#[derive(Debug, Clone, PartialEq)]
pub struct TableDraft {
    pub table: TableRef,
    pub columns: Vec<DraftColumn>,
    /// The primary key's own index included: it follows the columns'
    /// primary-key flags, and no plan restates it.
    pub indexes: Vec<IndexInfo>,
    pub foreign_keys: Vec<ForeignKeyInfo>,
}

impl TableDraft {
    pub fn new(table: TableRef) -> Self {
        Self {
            table,
            columns: Vec::new(),
            indexes: Vec::new(),
            foreign_keys: Vec::new(),
        }
    }

    pub fn from_definition(definition: &TableDefinition) -> Self {
        Self {
            table: definition.table.clone(),
            columns: definition
                .columns
                .iter()
                .cloned()
                .map(DraftColumn::from_definition)
                .collect(),
            indexes: definition.indexes.clone(),
            foreign_keys: definition.foreign_keys.clone(),
        }
    }

    pub fn column(&self, name: &str) -> Option<&DraftColumn> {
        self.columns.iter().find(|column| column.name == name)
    }

    /// The primary key's columns, in column order.
    pub fn primary_key(&self) -> Vec<&str> {
        self.columns
            .iter()
            .filter(|column| column.primary_key)
            .map(|column| column.name.as_str())
            .collect()
    }

    /// The first reason the draft cannot be saved.
    pub fn validate(&self) -> Result<(), DraftProblem> {
        if self.table.name.trim().is_empty() {
            return Err(DraftProblem::EmptyTableName);
        }
        if self.columns.is_empty() {
            return Err(DraftProblem::NoColumns);
        }
        let mut seen: HashSet<&str> = HashSet::new();
        for column in &self.columns {
            if column.name.trim().is_empty() {
                return Err(DraftProblem::EmptyColumnName);
            }
            if !seen.insert(column.name.as_str()) {
                return Err(DraftProblem::DuplicateColumnName(column.name.clone()));
            }
            if column.column_type.text().is_empty() {
                return Err(DraftProblem::EmptyColumnType(column.name.clone()));
            }
            if column.primary_key && column.nullable {
                return Err(DraftProblem::NullablePrimaryKey(column.name.clone()));
            }
        }
        for index in self.indexes.iter().filter(|index| !index.primary) {
            if index.name.trim().is_empty() {
                return Err(DraftProblem::EmptyIndexName);
            }
            if index.keys.is_empty() {
                return Err(DraftProblem::IndexWithoutKeys(index.name.clone()));
            }
        }
        for key in &self.foreign_keys {
            if key.name.trim().is_empty() {
                return Err(DraftProblem::EmptyForeignKeyName);
            }
            if key.columns.is_empty() || key.columns.len() != key.ref_columns.len() {
                return Err(DraftProblem::ForeignKeyColumnMismatch(key.name.clone()));
            }
        }
        self.columns_in_use()
    }

    /// Refuse a draft the dialect cannot create, before any SQL is
    /// written. Foreign keys are declared inside CREATE TABLE, so an
    /// engine that cannot add one to an existing table still takes them.
    pub fn check_create(&self, ddl: &dyn DdlDialect) -> Result<(), BuildDdlError> {
        let capabilities = ddl.capabilities();
        require(capabilities.create_table, DdlOperation::CreateTable)?;
        self.validate()?;
        if self.columns.iter().any(|column| column.comment_text().is_some()) {
            require(capabilities.column_comments, DdlOperation::SetColumnComment)?;
        }
        check_new_indexes(ddl, &self.indexes)?;
        check_actions(ddl, &self.foreign_keys)
    }

    /// A kept index or foreign key may name a column by the name it had
    /// when it was read, since a rename carries it along.
    fn columns_in_use(&self) -> Result<(), DraftProblem> {
        let known: HashSet<&str> = self
            .columns
            .iter()
            .flat_map(|column| std::iter::once(column.name.as_str()).chain(column.original_name()))
            .collect();
        let mut missing: BTreeMap<&str, Vec<String>> = BTreeMap::new();
        let index_columns = self.indexes.iter().filter(|index| !index.primary).flat_map(|index| {
            index
                .keys
                .iter()
                .filter_map(|key| key.column_name())
                .map(|c| (c, &index.name))
        });
        let key_columns = self
            .foreign_keys
            .iter()
            .flat_map(|key| key.columns.iter().map(|c| (c.as_str(), &key.name)));
        for (column, user) in index_columns.chain(key_columns) {
            if !known.contains(column) {
                let users = missing.entry(column).or_default();
                if !users.contains(user) {
                    users.push(user.clone());
                }
            }
        }
        match missing.into_iter().next() {
            Some((column, used_by)) => Err(DraftProblem::ColumnInUse {
                column: column.to_owned(),
                used_by,
            }),
            None => Ok(()),
        }
    }
}
