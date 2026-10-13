use tablepro_core::column::{ColumnDefault, ColumnKind};
use tablepro_core::ddl::ddl_sql::{column_list, create_index_sql, default_sql, foreign_key_sql, parenthesized};
use tablepro_core::ddl::{
    BuildDdlError, ColumnAttributes, ColumnCapabilities, ColumnDefinition, DdlCapabilities, DdlDialect, DdlOperation,
    DdlPlan, DraftColumn, DraftType, GeneratedStorage, IdentityStyle, Permission, ReferentialAction, RefusalReason,
    ResolvedType, TableChanges, TableDefinition, TableDraft,
};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::TableRef;

use crate::catalog::SqlServerType;
use crate::dialect::{MssqlDialect, national_literal};

static CAPABILITIES: DdlCapabilities = DdlCapabilities {
    create_table: true,
    rename_table: true,
    add_column: true,
    drop_column: true,
    rename_column: true,
    alter_column_type: true,
    alter_column_nullability: true,
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
    column_comments: true,
    drop_table_cascade: false,
};

/// T-SQL has no RESTRICT; the engine spells that behaviour NO ACTION.
const REFERENTIAL_ACTIONS: &[ReferentialAction] = &[
    ReferentialAction::NoAction,
    ReferentialAction::Cascade,
    ReferentialAction::SetNull,
    ReferentialAction::SetDefault,
];

const TYPE_SUGGESTIONS: &[&str] = &[
    "int",
    "bigint",
    "smallint",
    "tinyint",
    "bit",
    "nvarchar(255)",
    "nvarchar(max)",
    "varchar(255)",
    "decimal(18, 2)",
    "float",
    "real",
    "money",
    "date",
    "time",
    "datetime2",
    "datetimeoffset",
    "uniqueidentifier",
    "varbinary(max)",
];

/// SQL Server changes a table one statement at a time, inside the
/// write's transaction. A default is a constraint with a name of its
/// own, so a column whose default changes or goes away has that
/// constraint dropped by name first.
impl DdlDialect for MssqlDialect {
    fn capabilities(&self) -> &DdlCapabilities {
        &CAPABILITIES
    }

    fn sql_dialect(&self) -> &dyn SqlDialect {
        self
    }

    /// ALTER COLUMN restates the type with the collation and the
    /// nullability, so a column whose type the catalogue did not spell, or
    /// whose collation is not a name T-SQL takes bare, cannot take one. A
    /// SPARSE column is always nullable and takes no default (errors 1731
    /// and 1791), so either change can only be one the server refuses.
    fn column_capabilities(&self, table: &TableDefinition, column: &ColumnDefinition) -> ColumnCapabilities {
        let mut permissions = ColumnCapabilities::standard(&CAPABILITIES, table, column);
        let collation = || collation_permission(&column.attributes);
        permissions.alter_type = permissions.alter_type.and(collation);
        permissions.alter_nullability = permissions.alter_nullability.and(collation);
        if column.info.column_type.catalog.is_none() {
            permissions.alter_nullability = permissions
                .alter_nullability
                .and(|| Permission::Refused(RefusalReason::UnreadableDefinition));
        }
        if column.attributes.sparse {
            let sparse = || Permission::Refused(RefusalReason::ConflictingAttribute("SPARSE".to_owned()));
            permissions.alter_nullability = permissions.alter_nullability.and(sparse);
            permissions.alter_default = permissions.alter_default.and(sparse);
        }
        permissions
    }

    fn type_suggestions(&self) -> &'static [&'static str] {
        TYPE_SUGGESTIONS
    }

    fn default_column_type(&self) -> &'static str {
        "nvarchar(255)"
    }

    fn referential_actions(&self) -> &'static [ReferentialAction] {
        REFERENTIAL_ACTIONS
    }

    fn plan_create_table(&self, draft: &TableDraft) -> Result<DdlPlan, BuildDdlError> {
        draft.check_create(self)?;
        let table = TableRef::new(draft.table.schema.clone(), draft.table.name.trim());
        let mut definitions = draft
            .columns
            .iter()
            .map(|column| self.column_definition(column))
            .collect::<Result<Vec<_>, _>>()?;
        let key: Vec<String> = draft.primary_key().into_iter().map(str::to_owned).collect();
        if !key.is_empty() {
            definitions.push(format!("PRIMARY KEY ({})", column_list(self, &key)));
        }
        definitions.extend(draft.foreign_keys.iter().map(|key| foreign_key_sql(self, &table, key)));
        let mut statements = vec![format!(
            "CREATE TABLE {} (\n  {}\n)",
            self.qualify(&table),
            definitions.join(",\n  ")
        )];
        statements.extend(
            draft
                .indexes
                .iter()
                .filter(|index| !index.primary)
                .map(|index| create_index_sql(self, &table, index)),
        );
        for column in &draft.columns {
            if let Some(comment) = column.comment_text() {
                statements.push(column_comment(&table, &column.name, false, Some(comment)));
            }
        }
        Ok(DdlPlan::from_sql(statements))
    }

    fn plan_alter_table(&self, original: &TableDefinition, changes: &TableChanges) -> Result<DdlPlan, BuildDdlError> {
        changes.check(self, original)?;
        let mut statements = Vec::new();
        if let Some(name) = &changes.renamed_table {
            statements.push(format!(
                "EXEC sp_rename {}, {}",
                national_literal(&self.qualify(&original.table)),
                national_literal(name)
            ));
        }
        let table = changes.target(&original.table);
        let qualified = self.qualify(&table);
        let alter = |action: String| format!("ALTER TABLE {qualified} {action}");

        for key in &changes.dropped_foreign_keys {
            statements.push(alter(format!("DROP CONSTRAINT {}", self.quote_identifier(&key.name))));
        }
        for index in &changes.dropped_indexes {
            statements.push(format!(
                "DROP INDEX {} ON {qualified}",
                self.quote_identifier(&index.name)
            ));
        }
        let old_key = changes.dropped_primary_key_name()?;
        if let Some(name) = old_key {
            statements.push(alter(format!("DROP CONSTRAINT {}", self.quote_identifier(name))));
        }
        for column in &changes.dropped_columns {
            statements.extend(self.drop_default(&table, column));
            statements.push(alter(format!("DROP COLUMN {}", self.quote_identifier(column.name()))));
        }
        for rename in changes.ordered_renames(original) {
            let object = format!("{}.{}", qualified, self.quote_identifier(&rename.from));
            statements.push(format!(
                "EXEC sp_rename {}, {}, N'COLUMN'",
                national_literal(&object),
                national_literal(&rename.to)
            ));
        }
        for alteration in &changes.altered_columns {
            let draft = &alteration.draft;
            let name = self.quote_identifier(&draft.name);
            let changed = alteration.changed;
            // A column bound to a default cannot change type, so the
            // drop comes first.
            if changed.default {
                statements.extend(self.drop_default(&table, &alteration.original));
            }
            // ALTER COLUMN carries nothing forward: an omitted collation is
            // the database's, an omitted SPARSE is gone, and an omitted
            // NULL or NOT NULL is NULL. So every one is restated.
            if changed.column_type || changed.nullability {
                let resolved = draft.column_type.resolve(self, &draft.name)?;
                let attributes = &alteration.original.attributes;
                let operation = match changed.column_type {
                    true => DdlOperation::AlterColumnType,
                    false => DdlOperation::AlterColumnNullability,
                };
                if changed.column_type {
                    kept_on_new_type(&resolved, attributes).map_err(|attribute| BuildDdlError::Refused {
                        column: alteration.original.name().to_owned(),
                        operation,
                        reason: RefusalReason::ConflictingAttribute(attribute),
                    })?;
                }
                let mut parts = vec![format!("ALTER COLUMN {name}"), resolved.sql.clone()];
                parts.extend(collate_clause(draft, &resolved, attributes, operation)?);
                if attributes.sparse {
                    parts.push("SPARSE".to_owned());
                }
                parts.push(if draft.nullable { "NULL" } else { "NOT NULL" }.to_owned());
                statements.push(alter(parts.join(" ")));
                // ALTER COLUMN takes a mask only in a statement of its own.
                if let Some(function) = &attributes.masking_function {
                    statements.push(alter(format!("ALTER COLUMN {name} ADD {}", masked_with(function))));
                }
            }
            if changed.default {
                let column_type = draft.column_type.column_type(self, &draft.name)?;
                if let Some(default) = default_sql(self, &draft.name, &draft.default, &column_type)? {
                    statements.push(alter(format!(
                        "ADD DEFAULT {} FOR {name}",
                        default_clause(&draft.default, &default)
                    )));
                }
            }
            if changed.comment {
                let had_comment = alteration
                    .original
                    .info
                    .comment
                    .as_deref()
                    .is_some_and(|text| !text.is_empty());
                statements.push(column_comment(&table, &draft.name, had_comment, draft.comment_text()));
            }
        }
        for column in &changes.added_columns {
            statements.push(alter(format!("ADD {}", self.column_definition(column)?)));
            if let Some(comment) = column.comment_text() {
                statements.push(column_comment(&table, &column.name, false, Some(comment)));
            }
        }
        if let Some(change) = changes.primary_key.as_ref().filter(|change| !change.to.is_empty()) {
            let constraint = old_key
                .map(|name| format!("CONSTRAINT {} ", self.quote_identifier(name)))
                .unwrap_or_default();
            statements.push(alter(format!(
                "ADD {constraint}PRIMARY KEY ({})",
                column_list(self, &change.to)
            )));
        }
        statements.extend(
            changes
                .added_indexes
                .iter()
                .map(|index| create_index_sql(self, &table, index)),
        );
        for key in &changes.added_foreign_keys {
            statements.push(alter(format!("ADD {}", foreign_key_sql(self, &table, key))));
        }
        DdlPlan::for_changes(changes, statements)
    }
}

impl MssqlDialect {
    /// `name type [COLLATE c] [SPARSE] [MASKED WITH (..)] [IDENTITY(1,1)]
    /// NULL|NOT NULL [DEFAULT (..)]`, or a computed column read from the
    /// catalogue as `name AS (..)`.
    fn column_definition(&self, column: &DraftColumn) -> Result<String, BuildDdlError> {
        let name = self.quote_identifier(&column.name);
        let attributes = column.original.as_ref().map(|original| &original.attributes);
        if let Some(generated) = attributes.and_then(|attributes| attributes.generated.as_ref()) {
            let persisted = match generated.storage {
                GeneratedStorage::Stored => " PERSISTED",
                GeneratedStorage::Virtual => "",
            };
            return Ok(format!(
                "{name} AS {}{persisted}",
                parenthesized(generated.expression.as_sql())
            ));
        }
        let resolved = column.column_type.resolve(self, &column.name)?;
        let mut parts = vec![name, resolved.sql.clone()];
        if let Some(attributes) = attributes {
            parts.extend(collate_clause(
                column,
                &resolved,
                attributes,
                DdlOperation::CreateTable,
            )?);
            if attributes.sparse {
                parts.push("SPARSE".to_owned());
            }
            parts.extend(attributes.masking_function.as_deref().map(masked_with));
        }
        let identity = column.auto_increment
            || attributes.is_some_and(|attributes| attributes.identity == IdentityStyle::MssqlIdentity);
        if identity {
            parts.push("IDENTITY(1,1)".to_owned());
        }
        parts.push(if column.nullable { "NULL" } else { "NOT NULL" }.to_owned());
        // An identity column cannot carry a default.
        if !identity && let Some(default) = default_sql(self, &column.name, &column.default, &resolved.column_type)? {
            parts.push(format!("DEFAULT {}", default_clause(&column.default, &default)));
        }
        Ok(parts.join(" "))
    }

    /// The name comes from the catalogue and is spliced as a bracketed
    /// identifier, never through dynamic SQL, so a name holding `]` or a
    /// quote is just a name. `None` where the column has no default
    /// constraint.
    fn drop_default(&self, table: &TableRef, original: &ColumnDefinition) -> Option<String> {
        let name = original.attributes.default_constraint_name.as_deref()?;
        Some(format!(
            "ALTER TABLE {} DROP CONSTRAINT {}",
            self.qualify(table),
            self.quote_identifier(name)
        ))
    }
}

/// The column's own collation, kept where its type still holds text. The
/// catalogue reports one only where it differs from the database's.
fn collate_clause(
    column: &DraftColumn,
    resolved: &ResolvedType,
    attributes: &ColumnAttributes,
    operation: DdlOperation,
) -> Result<Option<String>, BuildDdlError> {
    let textual = matches!(column.column_type, DraftType::Catalog(_))
        || matches!(resolved.column_type.kind, ColumnKind::Text { .. });
    let Some(collation) = attributes.collation.as_ref().filter(|_| textual) else {
        return Ok(None);
    };
    match collation_permission(attributes) {
        Permission::Allowed => Ok(Some(format!("COLLATE {}", collation.name))),
        Permission::Refused(reason) => Err(BuildDdlError::Refused {
            column: column.name.clone(),
            operation,
            reason,
        }),
    }
}

/// T-SQL takes a collation name bare, never bracketed, so only a name of
/// letters, digits and underscores, which every collation has, can be
/// restated.
fn collation_permission(attributes: &ColumnAttributes) -> Permission {
    match &attributes.collation {
        Some(collation) if !plain_name(&collation.name) => {
            Permission::Refused(RefusalReason::UnmodeledAttribute(format!("COLLATE {}", collation.name)))
        }
        _ => Permission::Allowed,
    }
}

fn masked_with(function: &str) -> String {
    format!("MASKED WITH (FUNCTION = {})", national_literal(function))
}

/// SPARSE and a data mask go back on after a type change, so the new type
/// has to take them. `Err` names the one it does not take.
fn kept_on_new_type(resolved: &ResolvedType, attributes: &ColumnAttributes) -> Result<(), String> {
    if attributes.sparse && !SqlServerType::parse(&resolved.sql).takes_sparse() {
        return Err("SPARSE".to_owned());
    }
    match &attributes.masking_function {
        Some(function) if !mask_takes(function, &resolved.column_type.kind) => Err(masked_with(function)),
        _ => Ok(()),
    }
}

/// The types each mask function takes; SQL Server refuses the others
/// with error 16003. default() takes any.
fn mask_takes(function: &str, kind: &ColumnKind) -> bool {
    let name = function
        .split('(')
        .next()
        .unwrap_or_default()
        .trim()
        .to_ascii_lowercase();
    match name.as_str() {
        "default" => true,
        "email" | "partial" => matches!(kind, ColumnKind::Text { .. }),
        "random" => matches!(
            kind,
            ColumnKind::Integer(_)
                | ColumnKind::Decimal { .. }
                | ColumnKind::Float(_)
                | ColumnKind::Money { .. }
                | ColumnKind::Bool(_)
        ),
        "datetime" => matches!(
            kind,
            ColumnKind::Date | ColumnKind::Time { .. } | ColumnKind::Timestamp { .. }
        ),
        _ => false,
    }
}

fn plain_name(name: &str) -> bool {
    !name.is_empty()
        && name
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || character == '_')
}

fn default_clause(default: &ColumnDefault, sql: &str) -> String {
    match default {
        ColumnDefault::Expression(_) => parenthesized(sql),
        _ => format!("({sql})"),
    }
}

/// SQL Server keeps a column description in an extended property named
/// `MS_Description`, which is added, updated and dropped by three
/// procedures, and which one applies depends on whether the column had
/// a description. The schema goes through a variable because a procedure
/// argument cannot be a function call.
fn column_comment(table: &TableRef, column: &str, had_comment: bool, comment: Option<&str>) -> String {
    let schema = match table.schema.as_deref().filter(|name| !name.is_empty()) {
        Some(name) => national_literal(name),
        None => "SCHEMA_NAME()".to_owned(),
    };
    let levels = format!(
        "@level0type = N'SCHEMA', @level0name = @comment_schema, @level1type = N'TABLE', @level1name = {}, \
         @level2type = N'COLUMN', @level2name = {}",
        national_literal(&table.name),
        national_literal(column)
    );
    let head = format!("DECLARE @comment_schema sysname = {schema}; ");
    match (comment, had_comment) {
        (Some(text), had_comment) => {
            let procedure = if had_comment {
                "sp_updateextendedproperty"
            } else {
                "sp_addextendedproperty"
            };
            format!(
                "{head}EXEC {procedure} @name = N'MS_Description', @value = {}, {levels}",
                national_literal(text)
            )
        }
        (None, _) => format!("{head}EXEC sp_dropextendedproperty @name = N'MS_Description', {levels}"),
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::{ColumnInfo, SqlExpression};
    use tablepro_core::ddl::{CollationName, DropTableOptions, InboundForeignKey, PrimaryKeyConstraint, diff_table};
    use tablepro_core::value::Value;

    use super::*;
    use crate::catalog::SqlServerType;

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

    fn orders() -> TableDefinition {
        let mut id = column("id", "int", None);
        id.info.primary_key = true;
        id.info.nullable = false;
        TableDefinition {
            table: TableRef::new(Some("dbo".to_owned()), "orders"),
            columns: vec![
                id,
                column("status", "int", Some("DF]x")),
                column("note", "nvarchar(20)", None),
            ],
            primary_key: Some(PrimaryKeyConstraint {
                name: Some("PK_orders".to_owned()),
                columns: vec!["id".to_owned()],
            }),
            indexes: Vec::new(),
            foreign_keys: Vec::new(),
            inbound_foreign_keys: Vec::new(),
            source: None,
        }
    }

    fn alter(original: &TableDefinition, edit: impl FnOnce(&mut TableDraft)) -> Result<DdlPlan, BuildDdlError> {
        let mut draft = TableDraft::from_definition(original);
        edit(&mut draft);
        dialect().plan_alter_table(original, &diff_table(original, &draft))
    }

    fn sql(plan: Result<DdlPlan, BuildDdlError>) -> Vec<String> {
        plan.expect("the change plans")
            .sql()
            .into_iter()
            .map(str::to_owned)
            .collect()
    }

    fn typed(name: &str, declaration: &str) -> DraftColumn {
        DraftColumn::new(name, DraftType::Typed(declaration.to_owned()))
    }

    #[test]
    fn plan_create_table_simple() {
        let mut draft = TableDraft::new(TableRef::new(Some("dbo".to_owned()), "notes"));
        let mut id = typed("id", "bigint");
        id.primary_key = true;
        id.nullable = false;
        id.auto_increment = true;
        let mut body = typed("body", "nvarchar(255)");
        body.nullable = false;
        body.default = ColumnDefault::Literal(Value::Text("it's".to_owned()));
        let mut created = typed("created_at", "datetime2");
        created.default = ColumnDefault::Expression(SqlExpression::from_catalog_text("getdate()"));
        draft.columns = vec![id, body, created];

        assert_eq!(
            sql(dialect().plan_create_table(&draft)),
            [
                "CREATE TABLE [dbo].[notes] (\n  [id] bigint IDENTITY(1,1) NOT NULL,\n  [body] nvarchar(255) NOT NULL \
              DEFAULT (N'it''s'),\n  [created_at] datetime2 NULL DEFAULT (getdate()),\n  PRIMARY KEY ([id])\n)"
            ]
        );
    }

    #[test]
    fn plan_create_table_composite_key_index_and_foreign_key() {
        let mut draft = TableDraft::new(TableRef::new(Some("dbo".to_owned()), "lines"));
        let mut order = typed("order_id", "int");
        order.primary_key = true;
        order.nullable = false;
        let mut line = typed("line", "int");
        line.primary_key = true;
        line.nullable = false;
        let mut sku = typed("sku", "nvarchar(40)");
        sku.comment = Some("stock unit".to_owned());
        draft.columns = vec![order, line, sku];
        draft.indexes = vec![tablepro_core::meta::IndexInfo {
            name: "by_sku".to_owned(),
            keys: vec![tablepro_core::meta::IndexKey::Column {
                name: "sku".to_owned(),
                descending: false,
            }],
            unique: false,
            primary: false,
            predicate: Some("([sku] IS NOT NULL)".to_owned()),
        }];
        draft.foreign_keys = vec![tablepro_core::ForeignKeyInfo {
            name: "lines_order_fk".to_owned(),
            columns: vec!["order_id".to_owned()],
            ref_schema: None,
            ref_table: "orders".to_owned(),
            ref_columns: vec!["id".to_owned()],
            on_delete: Some(ReferentialAction::Cascade),
            on_update: None,
        }];

        assert_eq!(
            sql(dialect().plan_create_table(&draft)),
            [
                "CREATE TABLE [dbo].[lines] (\n  [order_id] int NOT NULL,\n  [line] int NOT NULL,\n  [sku] \
                 nvarchar(40) NULL,\n  PRIMARY KEY ([order_id], [line]),\n  CONSTRAINT [lines_order_fk] FOREIGN KEY \
                 ([order_id]) REFERENCES [dbo].[orders] ([id]) ON DELETE CASCADE\n)",
                "CREATE INDEX [by_sku] ON [dbo].[lines] ([sku]) WHERE ([sku] IS NOT NULL)",
                "DECLARE @comment_schema sysname = N'dbo'; EXEC sp_addextendedproperty @name = N'MS_Description', \
                 @value = N'stock unit', @level0type = N'SCHEMA', @level0name = @comment_schema, @level1type = \
                 N'TABLE', @level1name = N'lines', @level2type = N'COLUMN', @level2name = N'sku'",
            ]
        );
    }

    #[test]
    fn plan_alter_table_nullability_type_and_default() {
        let plan = alter(&orders(), |draft| {
            let status = &mut draft.columns[1];
            status.column_type = DraftType::Typed("bigint".to_owned());
            status.nullable = false;
            status.default = ColumnDefault::Literal(Value::Int(1));
        });

        assert_eq!(
            sql(plan),
            [
                "ALTER TABLE [dbo].[orders] DROP CONSTRAINT [DF]]x]",
                "ALTER TABLE [dbo].[orders] ALTER COLUMN [status] bigint NOT NULL",
                "ALTER TABLE [dbo].[orders] ADD DEFAULT (1) FOR [status]",
            ]
        );
    }

    #[test]
    fn mssql_nullability_change_restates_collation_and_sparse() {
        let mut original = orders();
        original.columns[2].attributes.collation = Some(CollationName::new(None, "Latin1_General_100_CS_AS"));
        let mut weight = column("weight", "int", None);
        weight.attributes.sparse = true;
        original.columns.push(weight);
        let mut code = column("code", "varchar(10)", None);
        code.attributes.collation = Some(CollationName::new(None, "Latin1_General_BIN"));
        code.attributes.masking_function = Some("partial(1,\"X's\",0)".to_owned());
        original.columns.push(code);

        let plan = alter(&original, |draft| {
            draft.columns[2].nullable = false;
            draft.columns[3].column_type = DraftType::Typed("bigint".to_owned());
            draft.columns[4].column_type = DraftType::Typed("varchar(40)".to_owned());
        });

        assert_eq!(
            sql(plan),
            [
                "ALTER TABLE [dbo].[orders] ALTER COLUMN [note] nvarchar(20) COLLATE Latin1_General_100_CS_AS NOT NULL",
                "ALTER TABLE [dbo].[orders] ALTER COLUMN [weight] bigint SPARSE NULL",
                "ALTER TABLE [dbo].[orders] ALTER COLUMN [code] varchar(40) COLLATE Latin1_General_BIN NULL",
                "ALTER TABLE [dbo].[orders] ALTER COLUMN [code] ADD MASKED WITH (FUNCTION = N'partial(1,\"X''s\",0)')",
            ]
        );
        assert_eq!(
            sql(dialect().create_table_script(&original))[0],
            "CREATE TABLE [dbo].[orders] (\n  [id] int NOT NULL,\n  [status] int NULL DEFAULT ((0)),\n  [note] \
             nvarchar(20) COLLATE Latin1_General_100_CS_AS NULL,\n  [weight] int SPARSE NULL,\n  [code] varchar(10) \
             COLLATE Latin1_General_BIN MASKED WITH (FUNCTION = N'partial(1,\"X''s\",0)') NULL,\n  PRIMARY KEY \
             ([id])\n)"
        );
    }

    #[test]
    fn a_type_that_cannot_keep_the_mask_or_sparse_is_refused() {
        let mut original = orders();
        let mut weight = column("weight", "int", None);
        weight.attributes.sparse = true;
        original.columns.push(weight);
        let mut code = column("code", "varchar(10)", None);
        code.attributes.masking_function = Some("partial(1,\"X\",0)".to_owned());
        original.columns.push(code);
        let mut amount = column("amount", "int", None);
        amount.attributes.masking_function = Some("random(1, 9)".to_owned());
        original.columns.push(amount);
        let retyped = |column: usize, declared: &str| {
            alter(&original, |draft| {
                draft.columns[column].column_type = DraftType::Typed(declared.to_owned())
            })
        };
        let conflict = |attribute: &str| {
            Err(BuildDdlError::Refused {
                column: original.columns[3].name().to_owned(),
                operation: DdlOperation::AlterColumnType,
                reason: RefusalReason::ConflictingAttribute(attribute.to_owned()),
            })
        };

        assert_eq!(retyped(3, "text"), conflict("SPARSE"));
        assert_eq!(retyped(3, "geometry"), conflict("SPARSE"));
        assert!(retyped(3, "nvarchar(40)").is_ok());
        assert!(matches!(
            retyped(4, "int"),
            Err(BuildDdlError::Refused { reason: RefusalReason::ConflictingAttribute(mask), .. })
                if mask == "MASKED WITH (FUNCTION = N'partial(1,\"X\",0)')"
        ));
        assert!(retyped(4, "nchar(10)").is_ok());
        assert!(matches!(
            retyped(5, "varchar(10)"),
            Err(BuildDdlError::Refused {
                reason: RefusalReason::ConflictingAttribute(_),
                ..
            })
        ));
        assert!(retyped(5, "money").is_ok());
        assert!(mask_takes("default()", &ColumnKind::Uuid));
        assert!(mask_takes("datetime(\"Y\")", &ColumnKind::Date));
        assert!(!mask_takes("email()", &ColumnKind::Date));
    }

    #[test]
    fn a_sparse_column_takes_neither_not_null_nor_a_default() {
        let mut original = orders();
        let mut weight = column("weight", "int", None);
        weight.attributes.sparse = true;
        original.columns.push(weight);
        let sparse = Permission::Refused(RefusalReason::ConflictingAttribute("SPARSE".to_owned()));

        let permissions = dialect().column_capabilities(&original, &original.columns[3]);
        let not_null = alter(&original, |draft| draft.columns[3].nullable = false);

        assert_eq!(permissions.alter_nullability, sparse);
        assert_eq!(permissions.alter_default, sparse);
        assert_eq!(permissions.alter_type, Permission::Allowed);
        assert!(matches!(
            not_null,
            Err(BuildDdlError::Refused {
                operation: DdlOperation::AlterColumnNullability,
                ..
            })
        ));
    }

    #[test]
    fn a_collation_tsql_cannot_name_bare_refuses_a_restatement() {
        let mut original = orders();
        original.columns[2].attributes.collation = Some(CollationName::new(None, "odd]name"));

        let permissions = dialect().column_capabilities(&original, &original.columns[2]);

        let odd = Permission::Refused(RefusalReason::UnmodeledAttribute("COLLATE odd]name".to_owned()));
        assert_eq!(permissions.alter_type, odd);
        assert_eq!(permissions.alter_nullability, odd);
        assert_eq!(permissions.alter_comment, Permission::Allowed);
        assert!(matches!(
            dialect().create_table_script(&original),
            Err(BuildDdlError::Refused {
                operation: DdlOperation::CreateTable,
                ..
            })
        ));
    }

    #[test]
    fn mssql_default_drop_uses_catalog_name_with_bracket_escaping() {
        let cleared = alter(&orders(), |draft| draft.columns[1].default = ColumnDefault::None);
        let added = alter(&orders(), |draft| {
            draft.columns[2].default = ColumnDefault::Literal(Value::Text("x".to_owned()));
        });

        let cleared = sql(cleared);
        assert_eq!(cleared, ["ALTER TABLE [dbo].[orders] DROP CONSTRAINT [DF]]x]"]);
        assert!(
            cleared
                .iter()
                .all(|sql| !sql.contains("DECLARE") && !sql.contains("EXEC("))
        );
        assert_eq!(sql(added), ["ALTER TABLE [dbo].[orders] ADD DEFAULT (N'x') FOR [note]"]);
    }

    #[test]
    fn a_swap_steps_aside_through_a_temporary_name() {
        let plan = alter(&orders(), |draft| {
            draft.columns[1].name = "note".to_owned();
            draft.columns[2].name = "status".to_owned();
        });

        assert_eq!(
            sql(plan),
            [
                "EXEC sp_rename N'[dbo].[orders].[status]', N'__tablepro_rename_1', N'COLUMN'",
                "EXEC sp_rename N'[dbo].[orders].[note]', N'status', N'COLUMN'",
                "EXEC sp_rename N'[dbo].[orders].[__tablepro_rename_1]', N'note', N'COLUMN'",
            ]
        );
    }

    #[test]
    fn a_dropped_column_loses_its_default_constraint_first() {
        let plan = alter(&orders(), |draft| {
            draft.columns.retain(|column| column.name != "status")
        });

        assert_eq!(
            sql(plan),
            [
                "ALTER TABLE [dbo].[orders] DROP CONSTRAINT [DF]]x]",
                "ALTER TABLE [dbo].[orders] DROP COLUMN [status]",
            ]
        );
    }

    #[test]
    fn sp_rename_quotes_parts() {
        let plan = alter(&orders(), |draft| {
            draft.table.name = "đơn hàng".to_owned();
            draft.columns[2].name = "o'brien".to_owned();
        });

        assert_eq!(
            sql(plan),
            [
                "EXEC sp_rename N'[dbo].[orders]', N'đơn hàng'",
                "EXEC sp_rename N'[dbo].[đơn hàng].[note]', N'o''brien', N'COLUMN'",
            ]
        );
        let dotted = alter(&orders(), |draft| draft.columns[2].name = "d".to_owned());
        let mut table = orders();
        table.columns[2].info.name = "a.b]c".to_owned();
        let bracketed = alter(&table, |draft| draft.columns[2].name = "d".to_owned());
        assert_eq!(
            sql(dotted),
            ["EXEC sp_rename N'[dbo].[orders].[note]', N'd', N'COLUMN'"]
        );
        assert_eq!(
            sql(bracketed),
            ["EXEC sp_rename N'[dbo].[orders].[a.b]]c]', N'd', N'COLUMN'"]
        );
    }

    #[test]
    fn a_comment_change_picks_the_procedure_for_what_was_there() {
        let mut table = orders();
        table.columns[2].info.comment = Some("old".to_owned());

        let updated = alter(&table, |draft| draft.columns[2].comment = Some("new".to_owned()));
        let dropped = alter(&table, |draft| draft.columns[2].comment = None);

        assert!(sql(updated)[0].contains("EXEC sp_updateextendedproperty @name = N'MS_Description', @value = N'new'"));
        assert!(sql(dropped)[0].contains("EXEC sp_dropextendedproperty @name = N'MS_Description'"));
    }

    #[test]
    fn pk_change_order_and_name_reuse() {
        let plan = alter(&orders(), |draft| {
            draft.columns[2].primary_key = true;
            draft.columns[2].nullable = false;
        });

        assert_eq!(
            sql(plan),
            [
                "ALTER TABLE [dbo].[orders] DROP CONSTRAINT [PK_orders]",
                "ALTER TABLE [dbo].[orders] ALTER COLUMN [note] nvarchar(20) NOT NULL",
                "ALTER TABLE [dbo].[orders] ADD CONSTRAINT [PK_orders] PRIMARY KEY ([id], [note])",
            ]
        );
    }

    fn referenced(table: &mut TableDefinition, column: &str) {
        table.inbound_foreign_keys = vec![InboundForeignKey {
            name: "lines_order_fk".to_owned(),
            table: TableRef::new(Some("dbo".to_owned()), "lines"),
            columns: vec!["order_id".to_owned()],
            referenced_columns: vec![column.to_owned()],
        }];
    }

    #[test]
    fn primary_key_referenced_by_foreign_key_is_refused() {
        let mut table = orders();
        referenced(&mut table, "id");

        let permissions = dialect().column_capabilities(&table, &table.columns[2]);

        assert_eq!(
            permissions.alter_primary_key,
            Permission::Refused(RefusalReason::ReferencedByForeignKeys(vec![
                "lines_order_fk".to_owned()
            ]))
        );
    }

    #[test]
    fn drop_of_referenced_column_is_refused() {
        let mut table = orders();
        referenced(&mut table, "note");

        let plan = alter(&table, |draft| draft.columns.retain(|column| column.name != "note"));

        assert!(
            matches!(
                plan,
                Err(BuildDdlError::Refused {
                    operation: DdlOperation::DropColumn,
                    reason: RefusalReason::ReferencedByForeignKeys(_),
                    ..
                })
            ),
            "{plan:?}"
        );
    }

    #[test]
    fn restrict_is_not_an_action_sql_server_takes() {
        assert!(!dialect().referential_actions().contains(&ReferentialAction::Restrict));
        assert!(DdlDialect::capabilities(&dialect()).partial_indexes);
        assert!(!DdlDialect::capabilities(&dialect()).expression_index_keys);
        assert_eq!(
            sql(dialect().plan_drop_table(
                &TableRef::new(Some("dbo".to_owned()), "orders"),
                DropTableOptions {
                    if_exists: true,
                    cascade: false
                }
            )),
            ["DROP TABLE IF EXISTS [dbo].[orders]"]
        );
    }

    #[test]
    fn every_type_suggestion_parses() {
        let dialect = dialect();

        for suggestion in dialect.type_suggestions() {
            assert!(dialect.parse_type(suggestion).is_ok(), "{suggestion}");
        }
        assert!(dialect.parse_type(dialect.default_column_type()).is_ok());
    }
}
