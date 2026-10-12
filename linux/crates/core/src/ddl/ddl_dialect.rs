use super::{ColumnDefinition, DdlCapabilities};
use crate::dialect::SqlDialect;
use crate::meta::TableRef;

/// How one engine spells structure changes.
///
/// Reached through `SqlDialect::ddl`, which is `None` for an engine
/// whose structure the app does not edit. The planning methods land
/// with the per-engine DDL plans; the capabilities are here first so
/// the UI can gate on them through the same accessor.
///
/// The statement methods take the `SqlDialect` this came from, which
/// quotes the names. Their bodies are the standard spelling, and an
/// engine overrides one only where its grammar differs.
pub trait DdlDialect: Send + Sync + std::fmt::Debug {
    fn capabilities(&self) -> &DdlCapabilities;

    fn rename_table(&self, dialect: &dyn SqlDialect, table: &TableRef, new_name: &str) -> String {
        format!(
            "ALTER TABLE {} RENAME TO {}",
            dialect.qualify(table),
            dialect.quote_identifier(new_name)
        )
    }

    fn rename_column(&self, dialect: &dyn SqlDialect, table: &TableRef, column: &str, new_name: &str) -> String {
        format!(
            "ALTER TABLE {} RENAME COLUMN {} TO {}",
            dialect.qualify(table),
            dialect.quote_identifier(column),
            dialect.quote_identifier(new_name)
        )
    }

    /// The statement that removes a column's default, or `None` where
    /// there is nothing to remove. The standard spelling needs only the
    /// column's name; an engine that keeps the default as a named object
    /// finds that name in the catalogue's definition.
    ///
    /// `column` is the name the column has when the statement runs,
    /// which a rename earlier in the same change makes differ from the
    /// catalogue's.
    fn drop_column_default(
        &self,
        dialect: &dyn SqlDialect,
        table: &TableRef,
        column: &str,
        _original: &ColumnDefinition,
    ) -> Option<String> {
        Some(format!(
            "ALTER TABLE {} ALTER COLUMN {} DROP DEFAULT",
            dialect.qualify(table),
            dialect.quote_identifier(column)
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::column::{ColumnDefault, ColumnInfo, ColumnKind, ColumnType, ReadForm, TextLength};
    use crate::ddl::ColumnAttributes;
    use crate::dialect::TestDialect;

    fn column(name: &str) -> ColumnDefinition {
        ColumnDefinition::new(
            ColumnInfo {
                name: name.to_owned(),
                column_type: ColumnType {
                    name: "text".to_owned(),
                    kind: ColumnKind::Text {
                        length: TextLength::Unbounded,
                    },
                    catalog: None,
                    dynamic_storage: false,
                    read_form: ReadForm::Native,
                },
                nullable: true,
                primary_key: false,
                is_auto_increment: false,
                is_generated: false,
                default: ColumnDefault::None,
                comment: None,
            },
            ColumnAttributes::default(),
        )
    }

    #[test]
    fn the_standard_spelling_quotes_through_the_dialect() {
        let dialect = TestDialect::exact();
        let Some(ddl) = dialect.ddl() else {
            panic!("the test dialect has no DDL");
        };
        let table = TableRef::new(Some("app".to_owned()), "or\"ders");

        assert_eq!(
            ddl.rename_table(&dialect, &table, "new"),
            "ALTER TABLE \"app\".\"or\"\"ders\" RENAME TO \"new\""
        );
        assert_eq!(
            ddl.rename_column(&dialect, &table, "a", "b\"c"),
            "ALTER TABLE \"app\".\"or\"\"ders\" RENAME COLUMN \"a\" TO \"b\"\"c\""
        );
        assert_eq!(
            ddl.drop_column_default(&dialect, &table, "renamed", &column("original")),
            Some("ALTER TABLE \"app\".\"or\"\"ders\" ALTER COLUMN \"renamed\" DROP DEFAULT".to_owned()),
            "the drop names the column as it is now"
        );
    }
}
