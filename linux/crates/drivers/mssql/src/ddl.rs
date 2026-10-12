use tablepro_core::ddl::{ColumnDefinition, DdlCapabilities, DdlDialect};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::TableRef;

use crate::dialect::MssqlDialect;

/// What the structure tab can change on SQL Server, and the parts of
/// its DDL only SQL Server needs.
#[derive(Debug)]
pub struct MssqlDdl {
    capabilities: DdlCapabilities,
}

pub(crate) static MSSQL_DDL: MssqlDdl = MssqlDdl {
    capabilities: DdlCapabilities {
        create_table: true,
        rename_table: true,
        add_column: true,
        drop_column: true,
        rename_column: true,
        alter_column_type: true,
        alter_column_nullability: true,
        nullability_switch: true,
        alter_column_default: true,
        alter_primary_key: true,
        // IDENTITY cannot be added to or taken from an existing column.
        alter_auto_increment: false,
        create_index: true,
        drop_index: true,
        // An index key is a column; an expression needs a computed one.
        expression_index_keys: false,
        partial_indexes: true,
        add_foreign_key: true,
        drop_foreign_key: true,
        drop_table_cascade: false,
    },
};

impl DdlDialect for MssqlDdl {
    fn capabilities(&self) -> &DdlCapabilities {
        &self.capabilities
    }
}

impl MssqlDdl {
    /// Drop the constraint that holds a column's default, by the name the
    /// catalogue gave it.
    ///
    /// The name is spliced as a bracketed identifier, never through
    /// dynamic SQL, so a name holding `]` or a quote is just a name.
    /// `None` where the column has no default constraint to drop.
    pub fn drop_default_constraint(
        dialect: &MssqlDialect,
        table: &TableRef,
        original: &ColumnDefinition,
    ) -> Option<String> {
        let name = original.attributes.default_constraint_name.as_deref()?;
        Some(format!(
            "ALTER TABLE {} DROP CONSTRAINT {}",
            dialect.qualify(table),
            dialect.quote_identifier(name)
        ))
    }

    /// `sp_rename` for a table. The arguments are national literals, so a
    /// name outside the server's code page survives.
    pub fn rename_table(dialect: &MssqlDialect, table: &TableRef, new_name: &str) -> String {
        format!(
            "EXEC sp_rename {}, {}",
            national(&dialect.qualify(table)),
            national(new_name)
        )
    }

    /// `sp_rename` for a column, named through its bracketed table.
    pub fn rename_column(dialect: &MssqlDialect, table: &TableRef, column: &str, new_name: &str) -> String {
        let object = format!("{}.{}", dialect.qualify(table), dialect.quote_identifier(column));
        format!(
            "EXEC sp_rename {}, {}, N'COLUMN'",
            national(&object),
            national(new_name)
        )
    }
}

fn national(text: &str) -> String {
    format!("N'{}'", text.replace('\'', "''"))
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::{ColumnDefault, ColumnInfo};
    use tablepro_core::ddl::ColumnAttributes;

    use super::*;
    use crate::catalog::SqlServerType;

    fn column(default_constraint_name: Option<&str>) -> ColumnDefinition {
        ColumnDefinition::new(
            ColumnInfo {
                name: "status".to_owned(),
                column_type: SqlServerType::parse("int").column_type().0,
                nullable: true,
                primary_key: false,
                is_auto_increment: false,
                is_generated: false,
                default: ColumnDefault::None,
                comment: None,
            },
            ColumnAttributes {
                default_constraint_name: default_constraint_name.map(str::to_owned),
                ..ColumnAttributes::default()
            },
        )
    }

    fn table() -> TableRef {
        TableRef::new(Some("dbo".to_owned()), "orders")
    }

    #[test]
    fn mssql_default_drop_is_static_and_bracket_escaped() {
        let drop = MssqlDdl::drop_default_constraint(&MssqlDialect::new(16), &table(), &column(Some("DF]x"))).unwrap();

        assert_eq!(drop, "ALTER TABLE [dbo].[orders] DROP CONSTRAINT [DF]]x]");
        assert!(!drop.contains("DECLARE"));
        assert!(!drop.contains("EXEC("));
    }

    #[test]
    fn mssql_default_drop_absent_without_constraint() {
        assert_eq!(
            MssqlDdl::drop_default_constraint(&MssqlDialect::new(16), &table(), &column(None)),
            None
        );
    }

    #[test]
    fn mssql_sp_rename_uses_national_literals() {
        let dialect = MssqlDialect::new(16);

        assert_eq!(
            MssqlDdl::rename_table(&dialect, &table(), "đơn hàng"),
            "EXEC sp_rename N'[dbo].[orders]', N'đơn hàng'"
        );
        assert_eq!(
            MssqlDdl::rename_column(&dialect, &table(), "o'brien", "new'name"),
            "EXEC sp_rename N'[dbo].[orders].[o''brien]', N'new''name', N'COLUMN'"
        );
    }

    #[test]
    fn the_structure_tab_offers_what_sql_server_can_alter() {
        let capabilities = MSSQL_DDL.capabilities();

        assert!(capabilities.alter_column_type && capabilities.alter_column_default);
        assert!(!capabilities.alter_auto_increment);
        assert!(!capabilities.expression_index_keys);
        assert!(capabilities.partial_indexes);
    }
}
