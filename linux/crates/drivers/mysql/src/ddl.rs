use tablepro_core::column::ColumnDefault;
use tablepro_core::ddl::ddl_sql::{
    column_list, create_index_sql, default_sql, foreign_key_sql, index_keys_sql, parenthesized,
};
use tablepro_core::ddl::{
    BuildDdlError, ColumnCapabilities, ColumnDefinition, DdlCapabilities, DdlDialect, DdlPlan, DraftColumn, Permission,
    ReferentialAction, RefusalReason, TableChanges, TableDefinition, TableDraft,
};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::TableRef;

use crate::dialect::MySqlDialect;

const fn capabilities(expression_index_keys: bool) -> DdlCapabilities {
    DdlCapabilities {
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
        alter_auto_increment: true,
        create_index: true,
        drop_index: true,
        expression_index_keys,
        partial_indexes: false,
        add_foreign_key: true,
        drop_foreign_key: true,
        column_comments: true,
        // MySQL parses CASCADE on DROP TABLE and does nothing with it.
        drop_table_cascade: false,
    }
}

static FUNCTIONAL_KEYS: DdlCapabilities = capabilities(true);
static COLUMN_KEYS: DdlCapabilities = capabilities(false);

/// InnoDB parses SET DEFAULT and then refuses the table that uses it.
const REFERENTIAL_ACTIONS: &[ReferentialAction] = &[
    ReferentialAction::NoAction,
    ReferentialAction::Restrict,
    ReferentialAction::Cascade,
    ReferentialAction::SetNull,
];

const TYPE_SUGGESTIONS: &[&str] = &[
    "INT",
    "BIGINT",
    "SMALLINT",
    "TINYINT",
    "VARCHAR(255)",
    "TEXT",
    "BOOLEAN",
    "DATETIME",
    "TIMESTAMP",
    "DATE",
    "TIME",
    "DECIMAL(10, 2)",
    "FLOAT",
    "DOUBLE",
    "JSON",
    "BLOB",
    "CHAR(36)",
];

/// MySQL restates a column whole, so every changed column is one
/// MODIFY or CHANGE carrying its full definition, and the column changes
/// share one ALTER TABLE. A foreign key is dropped in a statement before
/// it and added in one after it: MySQL refuses to drop and add a key of
/// the same name in one statement. MySQL commits each DDL statement on
/// its own, so a failure leaves the statements before it applied.
impl DdlDialect for MySqlDialect {
    fn capabilities(&self) -> &DdlCapabilities {
        match self.has_functional_key_parts() {
            true => &FUNCTIONAL_KEYS,
            false => &COLUMN_KEYS,
        }
    }

    fn sql_dialect(&self) -> &dyn SqlDialect {
        self
    }

    /// A MODIFY restates the type, so a column whose type the catalogue
    /// did not spell cannot take one.
    fn column_capabilities(&self, table: &TableDefinition, column: &ColumnDefinition) -> ColumnCapabilities {
        let mut permissions = ColumnCapabilities::standard(DdlDialect::capabilities(self), table, column);
        if column.info.column_type.catalog.is_none() {
            let unreadable = || Permission::Refused(RefusalReason::UnreadableDefinition);
            permissions.alter_nullability = permissions.alter_nullability.and(unreadable);
            permissions.alter_default = permissions.alter_default.and(unreadable);
            permissions.alter_auto_increment = permissions.alter_auto_increment.and(unreadable);
        }
        permissions
    }

    fn type_suggestions(&self) -> &'static [&'static str] {
        TYPE_SUGGESTIONS
    }

    fn default_column_type(&self) -> &'static str {
        "VARCHAR(255)"
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
        Ok(DdlPlan::from_sql(statements))
    }

    fn plan_alter_table(&self, original: &TableDefinition, changes: &TableChanges) -> Result<DdlPlan, BuildDdlError> {
        changes.check(self, original)?;
        let mut statements = Vec::new();
        let table = changes.target(&original.table);
        // The new name is qualified too: a bare one resolves against the
        // session's default database and would move the table there.
        if changes.renamed_table.is_some() {
            statements.push(format!(
                "RENAME TABLE {} TO {}",
                self.qualify(&original.table),
                self.qualify(&table)
            ));
        }
        let qualified = self.qualify(&table);
        if !changes.dropped_foreign_keys.is_empty() {
            let drops: Vec<String> = changes
                .dropped_foreign_keys
                .iter()
                .map(|key| format!("DROP FOREIGN KEY {}", self.quote_identifier(&key.name)))
                .collect();
            statements.push(format!("ALTER TABLE {qualified} {}", drops.join(", ")));
        }

        let mut actions = Vec::new();
        for index in &changes.dropped_indexes {
            actions.push(format!("DROP INDEX {}", self.quote_identifier(&index.name)));
        }
        if changes.primary_key.as_ref().is_some_and(|change| change.from.is_some()) {
            actions.push("DROP PRIMARY KEY".to_owned());
        }
        for column in &changes.dropped_columns {
            actions.push(format!("DROP COLUMN {}", self.quote_identifier(column.name())));
        }
        let restated = |from: &str| {
            changes
                .altered_columns
                .iter()
                .find(|alteration| alteration.original.name() == from && restates(alteration.changed))
        };
        // A renamed column that also changed goes through CHANGE, which
        // renames and restates at once; one that only changed its name
        // keeps every attribute through RENAME COLUMN.
        for rename in &changes.renamed_columns {
            match restated(&rename.from) {
                Some(alteration) => actions.push(format!(
                    "CHANGE COLUMN {} {}",
                    self.quote_identifier(&rename.from),
                    self.column_definition(&alteration.draft)?
                )),
                None => actions.push(format!(
                    "RENAME COLUMN {} TO {}",
                    self.quote_identifier(&rename.from),
                    self.quote_identifier(&rename.to)
                )),
            }
        }
        for alteration in &changes.altered_columns {
            let renamed = alteration.original.name() != alteration.draft.name;
            if !renamed && restates(alteration.changed) {
                actions.push(format!("MODIFY COLUMN {}", self.column_definition(&alteration.draft)?));
            }
        }
        for column in &changes.added_columns {
            actions.push(format!("ADD COLUMN {}", self.column_definition(column)?));
        }
        if let Some(change) = changes.primary_key.as_ref().filter(|change| !change.to.is_empty()) {
            actions.push(format!("ADD PRIMARY KEY ({})", column_list(self, &change.to)));
        }
        for index in &changes.added_indexes {
            let unique = if index.unique { "UNIQUE " } else { "" };
            actions.push(format!(
                "ADD {unique}INDEX {} ({})",
                self.quote_identifier(&index.name),
                index_keys_sql(self, index)
            ));
        }
        if !actions.is_empty() {
            statements.push(format!("ALTER TABLE {qualified} {}", actions.join(", ")));
        }
        if !changes.added_foreign_keys.is_empty() {
            let adds: Vec<String> = changes
                .added_foreign_keys
                .iter()
                .map(|key| format!("ADD {}", foreign_key_sql(self, &table, key)))
                .collect();
            statements.push(format!("ALTER TABLE {qualified} {}", adds.join(", ")));
        }
        Ok(DdlPlan::from_sql(statements))
    }

    /// The server's own SHOW CREATE TABLE, which carries the engine,
    /// charset and every option the definition does not model.
    fn create_table_script(&self, definition: &TableDefinition) -> Result<DdlPlan, BuildDdlError> {
        match &definition.source {
            Some(source) => Ok(DdlPlan::from_sql([source.create_statement.clone()])),
            None => self.plan_create_table(&TableDraft::from_definition(definition)),
        }
    }
}

/// Whether an alteration needs the column's definition restated. A
/// primary-key flag alone is the table's key clause.
fn restates(changed: tablepro_core::ddl::ChangedAttributes) -> bool {
    changed.column_type || changed.nullability || changed.default || changed.auto_increment || changed.comment
}

impl MySqlDialect {
    /// `name type NULL|NOT NULL [DEFAULT ..] [AUTO_INCREMENT] [COMMENT ..]`,
    /// the whole definition MODIFY replaces the old one with.
    fn column_definition(&self, column: &DraftColumn) -> Result<String, BuildDdlError> {
        let resolved = column.column_type.resolve(self, &column.name)?;
        let mut parts = vec![self.quote_identifier(&column.name), resolved.sql.clone()];
        parts.push(if column.nullable { "NULL" } else { "NOT NULL" }.to_owned());
        if !column.auto_increment
            && let Some(default) = default_sql(self, &column.name, &column.default, &resolved.column_type)?
        {
            parts.push(format!(
                "DEFAULT {}",
                default_clause(&column.default, &default, &resolved.sql)
            ));
        }
        if column.auto_increment {
            parts.push("AUTO_INCREMENT".to_owned());
        }
        if let Some(comment) = column.comment_text() {
            parts.push(format!("COMMENT {}", comment_literal(comment)));
        }
        Ok(parts.join(" "))
    }
}

/// MySQL takes an expression default only in parentheses, apart from the
/// CURRENT_TIMESTAMP family, and takes a literal on a BLOB, TEXT, JSON or
/// spatial column only as an expression.
fn default_clause(default: &ColumnDefault, sql: &str, declaration: &str) -> String {
    match default {
        ColumnDefault::Expression(_) if is_current_timestamp(sql) => sql.to_owned(),
        ColumnDefault::Expression(_) => parenthesized(sql),
        ColumnDefault::Literal(_) if needs_expression_default(declaration) => format!("({sql})"),
        _ => sql.to_owned(),
    }
}

fn is_current_timestamp(sql: &str) -> bool {
    let compact: String = sql
        .chars()
        .filter(|character| !character.is_whitespace())
        .collect::<String>()
        .to_ascii_lowercase();
    let name = compact.split('(').next().unwrap_or_default();
    let arguments = compact.get(name.len()..).unwrap_or_default();
    let precision_only = arguments.is_empty()
        || (arguments.starts_with('(')
            && arguments.ends_with(')')
            && arguments
                .get(1..arguments.len() - 1)
                .is_some_and(|digits| digits.chars().all(|character| character.is_ascii_digit())));
    matches!(name, "current_timestamp" | "now" | "localtime" | "localtimestamp") && precision_only
}

fn needs_expression_default(declaration: &str) -> bool {
    let name = declaration
        .trim()
        .split(|character: char| character == '(' || character.is_whitespace())
        .next()
        .unwrap_or_default()
        .to_ascii_lowercase();
    matches!(
        name.as_str(),
        "tinytext"
            | "text"
            | "mediumtext"
            | "longtext"
            | "tinyblob"
            | "blob"
            | "mediumblob"
            | "longblob"
            | "json"
            | "geometry"
            | "point"
            | "linestring"
            | "polygon"
            | "multipoint"
            | "multilinestring"
            | "multipolygon"
            | "geometrycollection"
    )
}

/// COMMENT takes a plain string only, with no introducer or hex form.
/// Workspace sessions run with backslash escapes on, so doubling both the
/// quote and the backslash reads back as the text.
fn comment_literal(text: &str) -> String {
    format!("'{}'", text.replace('\\', "\\\\").replace('\'', "''"))
}

#[cfg(test)]
mod tests {
    use tablepro_core::ForeignKeyInfo;
    use tablepro_core::ServerInfo;
    use tablepro_core::column::{ColumnInfo, SqlExpression};
    use tablepro_core::ddl::{
        ColumnAttributes, DdlOperation, DraftType, DropTableOptions, InboundForeignKey, PrimaryKeyConstraint,
        diff_table,
    };
    use tablepro_core::meta::{IndexInfo, IndexKey};
    use tablepro_core::value::Value;

    use super::*;
    use crate::flavour::MySqlFlavour;

    fn dialect() -> MySqlDialect {
        MySqlDialect::new(MySqlFlavour::MySql, &ServerInfo::new("MySQL", "8.4.3", 8, 4, 3))
    }

    fn column(name: &str, declaration: &str, primary_key: bool) -> ColumnDefinition {
        ColumnDefinition::new(
            ColumnInfo {
                name: name.to_owned(),
                column_type: dialect().parse_type(declaration).expect("a MySQL type"),
                nullable: !primary_key,
                primary_key,
                is_auto_increment: false,
                is_generated: false,
                default: ColumnDefault::None,
                comment: None,
            },
            ColumnAttributes::default(),
        )
    }

    fn users() -> TableDefinition {
        TableDefinition {
            table: TableRef::new(Some("app".to_owned()), "users"),
            columns: vec![
                column("id", "int", true),
                column("email", "varchar(255)", false),
                column("account_id", "int", false),
            ],
            primary_key: Some(PrimaryKeyConstraint {
                name: Some("PRIMARY".to_owned()),
                columns: vec!["id".to_owned()],
            }),
            indexes: Vec::new(),
            foreign_keys: vec![foreign_key("users_account_fk")],
            inbound_foreign_keys: Vec::new(),
            source: None,
        }
    }

    fn foreign_key(name: &str) -> ForeignKeyInfo {
        ForeignKeyInfo {
            name: name.to_owned(),
            columns: vec!["account_id".to_owned()],
            ref_schema: Some("app".to_owned()),
            ref_table: "accounts".to_owned(),
            ref_columns: vec!["id".to_owned()],
            on_delete: Some(ReferentialAction::Cascade),
            on_update: None,
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
        let mut draft = TableDraft::new(TableRef::new(Some("app".to_owned()), "notes"));
        let mut id = typed("id", "BIGINT");
        id.primary_key = true;
        id.nullable = false;
        id.auto_increment = true;
        let mut body = typed("body", "TEXT");
        body.default = ColumnDefault::Literal(Value::Text("it's".to_owned()));
        body.comment = Some("a \\ note".to_owned());
        let mut created = typed("created_at", "TIMESTAMP");
        created.default = ColumnDefault::Expression(SqlExpression::from_catalog_text("CURRENT_TIMESTAMP"));
        let mut token = typed("token", "CHAR(36)");
        token.default = ColumnDefault::Expression(SqlExpression::from_catalog_text("uuid()"));
        draft.columns = vec![id, body, created, token];

        assert_eq!(
            sql(dialect().plan_create_table(&draft)),
            [
                "CREATE TABLE `app`.`notes` (\n  `id` BIGINT NOT NULL AUTO_INCREMENT,\n  `body` TEXT NULL DEFAULT \
              ('it''s') COMMENT 'a \\\\ note',\n  `created_at` TIMESTAMP NULL DEFAULT CURRENT_TIMESTAMP,\n  `token` \
              CHAR(36) NULL DEFAULT (uuid()),\n  PRIMARY KEY (`id`)\n)"
            ]
        );
    }

    #[test]
    fn plan_create_table_composite_key_index_and_foreign_key() {
        let mut draft = TableDraft::new(TableRef::unqualified("lines"));
        let mut order = typed("order_id", "INT");
        order.primary_key = true;
        order.nullable = false;
        let mut line = typed("line", "INT");
        line.primary_key = true;
        line.nullable = false;
        draft.columns = vec![order, line, typed("sku", "VARCHAR(40)")];
        draft.indexes = vec![IndexInfo {
            name: "by_sku".to_owned(),
            keys: vec![IndexKey::Column {
                name: "sku".to_owned(),
                descending: false,
            }],
            unique: false,
            primary: false,
            predicate: None,
        }];
        draft.foreign_keys = vec![ForeignKeyInfo {
            ref_schema: None,
            columns: vec!["order_id".to_owned()],
            ..foreign_key("lines_order_fk")
        }];

        assert_eq!(
            sql(dialect().plan_create_table(&draft)),
            [
                "CREATE TABLE `lines` (\n  `order_id` INT NOT NULL,\n  `line` INT NOT NULL,\n  `sku` VARCHAR(40) \
                 NULL,\n  PRIMARY KEY (`order_id`, `line`),\n  CONSTRAINT `lines_order_fk` FOREIGN KEY (`order_id`) \
                 REFERENCES `accounts` (`id`) ON DELETE CASCADE\n)",
                "CREATE INDEX `by_sku` ON `lines` (`sku`)",
            ]
        );
    }

    #[test]
    fn plan_alter_table_nullability_type_and_default() {
        let plan = alter(&users(), |draft| {
            let email = &mut draft.columns[1];
            email.column_type = DraftType::Typed("varchar(320)".to_owned());
            email.nullable = false;
            email.default = ColumnDefault::Literal(Value::Text(String::new()));
        });

        assert_eq!(
            sql(plan),
            ["ALTER TABLE `app`.`users` MODIFY COLUMN `email` varchar(320) NOT NULL DEFAULT ''"]
        );
    }

    #[test]
    fn mysql_drop_fk_precedes_combined_alter() {
        let plan = alter(&users(), |draft| {
            draft.foreign_keys = vec![ForeignKeyInfo {
                on_delete: Some(ReferentialAction::SetNull),
                ..foreign_key("users_account_fk")
            }];
            draft.columns[2].nullable = false;
            draft.columns.push(typed("nickname", "varchar(40)"));
        });

        assert_eq!(
            sql(plan),
            [
                "ALTER TABLE `app`.`users` DROP FOREIGN KEY `users_account_fk`",
                "ALTER TABLE `app`.`users` MODIFY COLUMN `account_id` int NOT NULL, ADD COLUMN `nickname` \
                 varchar(40) NULL",
                "ALTER TABLE `app`.`users` ADD CONSTRAINT `users_account_fk` FOREIGN KEY (`account_id`) REFERENCES \
                 `app`.`accounts` (`id`) ON DELETE SET NULL",
            ]
        );
    }

    #[test]
    fn mysql_rename_keeps_the_table_in_its_database() {
        let plan = alter(&users(), |draft| draft.table.name = "members".to_owned());

        assert_eq!(sql(plan), ["RENAME TABLE `app`.`users` TO `app`.`members`"]);
    }

    #[test]
    fn a_rename_alone_keeps_the_definition_and_one_with_changes_restates_it() {
        let only_renamed = alter(&users(), |draft| draft.columns[1].name = "mail".to_owned());
        let renamed_and_changed = alter(&users(), |draft| {
            draft.columns[1].name = "mail".to_owned();
            draft.columns[1].nullable = false;
        });

        assert_eq!(
            sql(only_renamed),
            ["ALTER TABLE `app`.`users` RENAME COLUMN `email` TO `mail`"]
        );
        assert_eq!(
            sql(renamed_and_changed),
            ["ALTER TABLE `app`.`users` CHANGE COLUMN `email` `mail` varchar(255) NOT NULL"]
        );
    }

    #[test]
    fn a_primary_key_change_is_one_statement() {
        let plan = alter(&users(), |draft| {
            draft.columns[1].primary_key = true;
            draft.columns[1].nullable = false;
        });

        assert_eq!(
            sql(plan),
            [
                "ALTER TABLE `app`.`users` DROP PRIMARY KEY, MODIFY COLUMN `email` varchar(255) NOT NULL, ADD PRIMARY \
              KEY (`id`, `email`)"
            ]
        );
    }

    fn referenced(table: &mut TableDefinition, column: &str) {
        table.inbound_foreign_keys = vec![InboundForeignKey {
            name: "orders_user_fk".to_owned(),
            table: TableRef::new(Some("app".to_owned()), "orders"),
            columns: vec!["user_id".to_owned()],
            referenced_columns: vec![column.to_owned()],
        }];
    }

    #[test]
    fn primary_key_referenced_by_foreign_key_is_refused() {
        let mut table = users();
        referenced(&mut table, "id");

        let permissions = dialect().column_capabilities(&table, &table.columns[1]);

        assert_eq!(
            permissions.alter_primary_key,
            Permission::Refused(RefusalReason::ReferencedByForeignKeys(vec![
                "orders_user_fk".to_owned()
            ]))
        );
    }

    #[test]
    fn drop_of_referenced_column_is_refused() {
        let mut table = users();
        referenced(&mut table, "email");

        let plan = alter(&table, |draft| draft.columns.retain(|column| column.name != "email"));

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
    fn set_default_is_not_offered_and_is_refused() {
        let plan = alter(&users(), |draft| {
            draft.foreign_keys[0].on_delete = Some(ReferentialAction::SetDefault);
        });

        assert!(!dialect().referential_actions().contains(&ReferentialAction::SetDefault));
        assert_eq!(
            plan,
            Err(BuildDdlError::ReferentialAction(ReferentialAction::SetDefault))
        );
    }

    #[test]
    fn the_script_is_the_servers_own_text() {
        let mut table = users();
        table.source = Some(tablepro_core::ddl::TableSource {
            create_statement: "CREATE TABLE `users` (\n  `id` int NOT NULL\n) ENGINE=InnoDB".to_owned(),
            dependents: Vec::new(),
        });

        assert_eq!(
            sql(dialect().create_table_script(&table)),
            ["CREATE TABLE `users` (\n  `id` int NOT NULL\n) ENGINE=InnoDB"]
        );
        assert_eq!(
            sql(dialect().plan_drop_table(&table.table, DropTableOptions::default())),
            ["DROP TABLE `app`.`users`"]
        );
    }

    #[test]
    fn only_the_current_timestamp_family_goes_bare() {
        assert!(is_current_timestamp("CURRENT_TIMESTAMP"));
        assert!(is_current_timestamp("current_timestamp(6)"));
        assert!(is_current_timestamp("now()"));
        assert!(!is_current_timestamp("now() + interval 1 day"));
        assert!(!is_current_timestamp("uuid()"));
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
