use std::cell::RefCell;

use tablepro_core::ddl::TableDefinition;

use super::create_table_source::CreateTableSource;
use super::source_read_error::SourceReadError;

/// What a CREATE TABLE text declares that the catalogue can confirm: the
/// table's name, its columns in order, and how many foreign keys it has.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct DeclaredShape {
    pub table: String,
    pub columns: Vec<String>,
    pub foreign_keys: usize,
}

impl DeclaredShape {
    /// Whether the text describes the table the catalogue read. Columns
    /// pair by position, which `pragma_table_xinfo` keeps in declaration
    /// order.
    pub(crate) fn check(&self, definition: &TableDefinition) -> Result<(), SourceReadError> {
        if !self.table.eq_ignore_ascii_case(&definition.table.name) {
            return Err(SourceReadError::TableName {
                expected: definition.table.name.clone(),
                found: self.table.clone(),
            });
        }
        if self.columns.len() != definition.columns.len() {
            return Err(SourceReadError::ColumnCount {
                expected: definition.columns.len(),
                found: self.columns.len(),
            });
        }
        for (position, (column, defined)) in self.columns.iter().zip(&definition.columns).enumerate() {
            if !column.eq_ignore_ascii_case(defined.name()) {
                return Err(SourceReadError::ColumnName {
                    position,
                    expected: defined.name().to_owned(),
                    found: column.clone(),
                });
            }
        }
        if self.foreign_keys != definition.foreign_keys.len() {
            return Err(SourceReadError::ForeignKeyCount {
                expected: definition.foreign_keys.len(),
                found: self.foreign_keys,
            });
        }
        Ok(())
    }
}

thread_local! {
    /// The last CREATE TABLE text read for capabilities. The structure
    /// tab asks once per column of the same table, and reading the text
    /// costs as much as the text is long.
    static LAST_READ: RefCell<Option<(String, Option<DeclaredShape>)>> = const { RefCell::new(None) };
}

/// Whether a rebuild could read `definition`'s CREATE TABLE.
pub(crate) fn readable(definition: &TableDefinition) -> bool {
    let Some(sql) = definition
        .source
        .as_ref()
        .map(|source| source.create_statement.as_str())
    else {
        return false;
    };
    LAST_READ.with_borrow_mut(|last| {
        if last.as_ref().is_none_or(|(read, _)| read != sql) {
            let shape = CreateTableSource::read(sql).ok().map(|source| source.shape());
            *last = Some((sql.to_owned(), shape));
        }
        last.as_ref()
            .and_then(|(_, shape)| shape.as_ref())
            .is_some_and(|shape| shape.check(definition).is_ok())
    })
}
