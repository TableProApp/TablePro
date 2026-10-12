use tablepro_core::ddl::{ColumnDefinition, DdlCapabilities, DdlDialect};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::TableRef;

use crate::dialect::national_literal;

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

    /// `sp_rename` takes the names as string literals, not identifiers.
    /// They are national literals, so a name outside the server's code
    /// page survives.
    fn rename_table(&self, dialect: &dyn SqlDialect, table: &TableRef, new_name: &str) -> String {
        format!(
            "EXEC sp_rename {}, {}",
            national_literal(&dialect.qualify(table)),
            national_literal(new_name)
        )
    }

    /// The column is named through its bracketed table, because
    /// `sp_rename` splits the first argument on every unquoted `.`.
    fn rename_column(&self, dialect: &dyn SqlDialect, table: &TableRef, column: &str, new_name: &str) -> String {
        let object = format!("{}.{}", dialect.qualify(table), dialect.quote_identifier(column));
        format!(
            "EXEC sp_rename {}, {}, N'COLUMN'",
            national_literal(&object),
            national_literal(new_name)
        )
    }

    /// A default here is a constraint with a name of its own, which the
    /// catalogue gave. The name is spliced as a bracketed identifier,
    /// never through dynamic SQL, so a name holding `]` or a quote is
    /// just a name. `None` where the column has no default constraint.
    fn drop_column_default(
        &self,
        dialect: &dyn SqlDialect,
        table: &TableRef,
        _column: &str,
        original: &ColumnDefinition,
    ) -> Option<String> {
        let name = original.attributes.default_constraint_name.as_deref()?;
        Some(format!(
            "ALTER TABLE {} DROP CONSTRAINT {}",
            dialect.qualify(table),
            dialect.quote_identifier(name)
        ))
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::{ColumnDefault, ColumnInfo, SqlExpression};
    use tablepro_core::ddl::ColumnAttributes;
    use tablepro_core::sql_ddl::{
        DraftColumn, StructureOp, build_alter_column, build_rename_column, build_rename_table, materialize_ops,
    };

    use super::*;
    use crate::catalog::SqlServerType;
    use crate::dialect::MssqlDialect;

    fn dialect() -> MssqlDialect {
        MssqlDialect::new(16)
    }

    fn column(name: &str, declared: &str, default_constraint_name: Option<&str>) -> ColumnDefinition {
        let default = match default_constraint_name {
            Some(_) => ColumnDefault::Expression(SqlExpression::from_catalog_text("((0))")),
            None => ColumnDefault::None,
        };
        ColumnDefinition::new(
            ColumnInfo {
                name: name.to_owned(),
                column_type: SqlServerType::parse(declared).column_type().0,
                nullable: true,
                primary_key: false,
                is_auto_increment: false,
                is_generated: false,
                default,
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

    fn alter(draft: &DraftColumn) -> Vec<String> {
        build_alter_column("mssql", &dialect(), Some("dbo"), "orders", draft).expect("an alter")
    }

    #[test]
    fn mssql_default_drop_is_static_and_bracket_escaped() {
        let dialect = dialect();

        let drop = MSSQL_DDL
            .drop_column_default(&dialect, &table(), "status", &column("status", "int", Some("DF]x")))
            .unwrap();

        assert_eq!(drop, "ALTER TABLE [dbo].[orders] DROP CONSTRAINT [DF]]x]");
        assert!(!drop.contains("DECLARE"));
        assert!(!drop.contains("EXEC("));
    }

    #[test]
    fn mssql_default_drop_absent_without_constraint() {
        assert_eq!(
            MSSQL_DDL.drop_column_default(&dialect(), &table(), "status", &column("status", "int", None)),
            None
        );
    }

    #[test]
    fn mssql_sp_rename_uses_national_literals() {
        let dialect = dialect();

        assert_eq!(
            build_rename_table("mssql", &dialect, Some("dbo"), "orders", "đơn hàng").unwrap(),
            "EXEC sp_rename N'[dbo].[orders]', N'đơn hàng'"
        );
        assert_eq!(
            build_rename_column("mssql", &dialect, Some("dbo"), "orders", "o'brien", "new'name").unwrap(),
            "EXEC sp_rename N'[dbo].[orders].[o''brien]', N'new''name', N'COLUMN'"
        );
    }

    #[test]
    fn sp_rename_quotes_parts() {
        assert_eq!(
            MSSQL_DDL.rename_column(&dialect(), &table(), "a.b]c", "d"),
            "EXEC sp_rename N'[dbo].[orders].[a.b]]c]', N'd', N'COLUMN'"
        );
    }

    #[test]
    fn a_default_change_drops_the_named_constraint_then_adds_the_new_default() {
        let mut draft = DraftColumn::from_definition(column("status", "int", Some("DF_status")));
        draft.default_value = Some("1".to_owned());

        assert_eq!(
            alter(&draft),
            vec![
                "ALTER TABLE [dbo].[orders] DROP CONSTRAINT [DF_status]".to_owned(),
                "ALTER TABLE [dbo].[orders] ADD DEFAULT (1) FOR [status]".to_owned(),
            ]
        );
    }

    #[test]
    fn clearing_a_default_only_drops() {
        let mut draft = DraftColumn::from_definition(column("status", "int", Some("DF_status")));
        draft.default_value = None;

        assert_eq!(
            alter(&draft),
            vec!["ALTER TABLE [dbo].[orders] DROP CONSTRAINT [DF_status]".to_owned()]
        );
    }

    #[test]
    fn a_new_default_without_a_constraint_is_only_added() {
        let mut draft = DraftColumn::from_definition(column("status", "int", None));
        draft.default_value = Some("0".to_owned());

        assert_eq!(
            alter(&draft),
            vec!["ALTER TABLE [dbo].[orders] ADD DEFAULT (0) FOR [status]".to_owned()]
        );
    }

    #[test]
    fn the_default_drop_comes_before_a_type_change() {
        let mut draft = DraftColumn::from_definition(column("status", "int", Some("DF_status")));
        draft.data_type = "bigint".to_owned();
        draft.default_value = Some("1".to_owned());

        assert_eq!(
            alter(&draft),
            vec![
                "ALTER TABLE [dbo].[orders] DROP CONSTRAINT [DF_status]".to_owned(),
                "ALTER TABLE [dbo].[orders] ALTER COLUMN [status] bigint NULL".to_owned(),
                "ALTER TABLE [dbo].[orders] ADD DEFAULT (1) FOR [status]".to_owned(),
            ]
        );
    }

    #[test]
    fn a_saved_rename_and_default_change_use_sp_rename_and_the_static_drop() {
        let mut draft = DraftColumn::from_definition(column("x", "nvarchar(20)", Some("DF_x")));
        draft.default_value = Some("N'x'".to_owned());
        let ops = vec![
            StructureOp::RenameTable {
                schema: Some("dbo".to_owned()),
                old_name: "old_t".to_owned(),
                new_name: "new_t".to_owned(),
            },
            StructureOp::AlterColumn {
                schema: Some("dbo".to_owned()),
                table: "new_t".to_owned(),
                column: draft,
            },
        ];

        let statements = materialize_ops(&ops, "mssql", &dialect()).expect("the change builds");

        assert_eq!(
            statements,
            vec![
                "EXEC sp_rename N'[dbo].[old_t]', N'new_t'".to_owned(),
                "ALTER TABLE [dbo].[new_t] DROP CONSTRAINT [DF_x]".to_owned(),
                "ALTER TABLE [dbo].[new_t] ADD DEFAULT (N'x') FOR [x]".to_owned(),
            ]
        );
        assert!(
            statements
                .iter()
                .all(|sql| !sql.contains("DECLARE") && !sql.contains("EXEC("))
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
