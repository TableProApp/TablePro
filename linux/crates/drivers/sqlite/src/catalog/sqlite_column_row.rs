use sqlx::Row;
use sqlx::sqlite::SqliteRow;
use tablepro_core::DriverError;
use tablepro_core::column::{ColumnDefault, ColumnInfo};
use tablepro_core::ddl::{ColumnAttributes, GeneratedStorage, IdentityStyle};

use super::{classify_default, declared_column_type};
use crate::errors::map_error;

/// One row of `pragma_table_xinfo`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct SqliteColumnRow {
    pub name: String,
    pub declared_type: String,
    pub not_null: bool,
    pub default: Option<String>,
    /// The column's position in the primary key, from 1, or 0.
    pub pk: i64,
    /// 0 for an ordinary column, 1 for a hidden column of a virtual
    /// table, 2 for a VIRTUAL generated column and 3 for a STORED one.
    pub hidden: i64,
}

/// What the columns of one table need to know about the table itself.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct TableFacts {
    pub strict: bool,
    pub without_rowid: bool,
    /// The table was declared with AUTOINCREMENT, which SQLite records
    /// as a row in `sqlite_sequence`.
    pub autoincrement: bool,
    /// Exactly one column is in the primary key.
    pub single_column_key: bool,
    /// The CREATE TABLE text declares the key column `PRIMARY KEY DESC`
    /// on the column itself, which SQLite reads as an ordinary column
    /// rather than the rowid (lang_createtable.html#rowid).
    pub descending_key: bool,
}

impl SqliteColumnRow {
    pub(crate) fn from_row(row: &SqliteRow) -> Result<Self, DriverError> {
        Ok(Self {
            name: row.try_get("name").map_err(map_error)?,
            declared_type: row.try_get("type").map_err(map_error)?,
            not_null: row.try_get::<i64, _>("notnull").map_err(map_error)? != 0,
            default: row.try_get("dflt_value").map_err(map_error)?,
            pk: row.try_get("pk").map_err(map_error)?,
            hidden: row.try_get("hidden").map_err(map_error)?,
        })
    }

    /// A virtual table's hidden columns are not part of `SELECT *`, so
    /// the grid never shows them.
    pub(crate) fn is_visible(&self) -> bool {
        self.hidden != 1
    }

    pub(crate) fn generated_storage(&self) -> Option<GeneratedStorage> {
        match self.hidden {
            2 => Some(GeneratedStorage::Virtual),
            3 => Some(GeneratedStorage::Stored),
            _ => None,
        }
    }

    /// `INTEGER PRIMARY KEY`, spelled exactly so, names the rowid
    /// rather than adding a column, and only on a table that has one.
    pub(crate) fn is_rowid_alias(&self, table: &TableFacts) -> bool {
        self.is_rowid_candidate(table) && !table.descending_key
    }

    /// The rowid as `pragma_table_xinfo` alone shows it. `PRIMARY KEY
    /// DESC` on the column still makes it an ordinary column, which the
    /// table's CREATE TABLE text tells.
    pub(crate) fn is_rowid_candidate(&self, table: &TableFacts) -> bool {
        self.pk > 0
            && table.single_column_key
            && !table.without_rowid
            && self.declared_type.trim().eq_ignore_ascii_case("INTEGER")
    }

    pub(crate) fn column_info(&self, table: &TableFacts) -> ColumnInfo {
        let is_generated = self.generated_storage().is_some();
        // The rowid fills itself in unless a default says otherwise.
        // AUTOINCREMENT adds only the promise never to reuse a number.
        let is_auto_increment = self.is_rowid_alias(table) && (table.autoincrement || self.default.is_none());
        let default = match (is_generated, self.default.as_deref()) {
            (false, Some(text)) => classify_default(text),
            _ => ColumnDefault::None,
        };
        ColumnInfo {
            name: self.name.clone(),
            column_type: declared_column_type(&self.declared_type, table.strict),
            nullable: !self.not_null,
            primary_key: self.pk > 0,
            is_auto_increment,
            is_generated,
            default,
            // SQLite keeps no column descriptions. A comment in the
            // CREATE TABLE text is dropped by its parser.
            comment: None,
        }
    }

    pub(crate) fn attributes(&self, table: &TableFacts) -> ColumnAttributes {
        let identity = match self.is_rowid_alias(table) {
            true => IdentityStyle::SqliteRowidAlias,
            false => IdentityStyle::None,
        };
        ColumnAttributes {
            identity,
            ..ColumnAttributes::default()
        }
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::{ColumnKind, IntegerKind, IntegerWidth};
    use tablepro_core::value::Value;

    use super::*;

    fn row(name: &str, declared: &str, pk: i64, default: Option<&str>) -> SqliteColumnRow {
        SqliteColumnRow {
            name: name.to_owned(),
            declared_type: declared.to_owned(),
            not_null: false,
            default: default.map(str::to_owned),
            pk,
            hidden: 0,
        }
    }

    fn facts(single_column_key: bool) -> TableFacts {
        TableFacts {
            strict: false,
            without_rowid: false,
            autoincrement: false,
            single_column_key,
            descending_key: false,
        }
    }

    #[test]
    fn only_a_lone_integer_primary_key_fills_itself_in() {
        assert!(
            row("id", "INTEGER", 1, None)
                .column_info(&facts(true))
                .is_auto_increment
        );
        assert!(
            !row("id", "INT", 1, None).column_info(&facts(true)).is_auto_increment,
            "INT PRIMARY KEY is an ordinary column, not the rowid"
        );
        assert!(
            !row("a", "INTEGER", 1, None)
                .column_info(&facts(false))
                .is_auto_increment
        );
        assert!(
            !row("id", "INTEGER", 1, Some("0"))
                .column_info(&facts(true))
                .is_auto_increment
        );
        let without_rowid = TableFacts {
            without_rowid: true,
            ..facts(true)
        };
        assert!(
            !row("id", "INTEGER", 1, None)
                .column_info(&without_rowid)
                .is_auto_increment
        );
        let descending = TableFacts {
            descending_key: true,
            ..facts(true)
        };
        let column = row("id", "INTEGER", 1, None);
        assert!(
            !column.column_info(&descending).is_auto_increment,
            "INTEGER PRIMARY KEY DESC is an ordinary column, not the rowid"
        );
        assert_eq!(column.attributes(&descending).identity, IdentityStyle::None);
    }

    #[test]
    fn a_default_keeps_the_value_it_names() {
        let info = row("status", "TEXT", 0, Some("'it''s'")).column_info(&facts(false));

        assert_eq!(info.default, ColumnDefault::Literal(Value::Text("it's".to_owned())));
        assert_eq!(
            info.column_type.kind,
            ColumnKind::Text {
                length: tablepro_core::column::TextLength::Unbounded
            }
        );
    }

    #[test]
    fn a_generated_column_reports_its_storage_and_no_default() {
        let mut stored = row("total", "INTEGER", 0, None);
        stored.hidden = 3;
        let mut virtual_column = row("half", "REAL", 0, None);
        virtual_column.hidden = 2;

        assert_eq!(stored.generated_storage(), Some(GeneratedStorage::Stored));
        assert_eq!(virtual_column.generated_storage(), Some(GeneratedStorage::Virtual));
        let info = stored.column_info(&facts(false));
        assert!(info.is_generated);
        assert_eq!(
            info.column_type.kind,
            ColumnKind::Integer(IntegerKind {
                width: IntegerWidth::W64,
                signed: true
            })
        );
    }
}
