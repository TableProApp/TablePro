mod mysql_column_definition;

use tablepro_core::column::ColumnDefault;
use tablepro_core::ddl::ddl_sql::{column_list, create_index_sql, foreign_key_sql, index_keys_sql};
use tablepro_core::ddl::{
    BuildDdlError, ChangedAttributes, ColumnAlteration, ColumnCapabilities, ColumnDefinition, DdlCapabilities,
    DdlDialect, DdlOperation, DdlPlan, Permission, ReferentialAction, RefusalReason, TableChanges, TableDefinition,
    TableDraft,
};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::TableRef;

use crate::catalog::printed_names;
use crate::dialect::MySqlDialect;
use mysql_column_definition::{nullability_permission, render, restatement};

const fn capabilities(expression_index_keys: bool) -> DdlCapabilities {
    DdlCapabilities {
        create_table: true,
        rename_table: true,
        add_column: true,
        drop_column: true,
        rename_column: true,
        alter_column_type: true,
        alter_column_nullability: true,
        alter_column_default: true,
        alter_primary_key: true,
        alter_auto_increment: true,
        // An AUTO_INCREMENT column has to be a key.
        auto_increment_outside_primary_key: false,
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
/// share one ALTER TABLE. Each clause of it names columns as the table
/// had them, so renames that swap names, or take the name of a column
/// the same statement drops, need no order. A foreign key is dropped in
/// a statement before it and added in one after it: MySQL refuses to
/// drop and add a key of the same name in one statement. MySQL commits
/// each DDL statement on its own, so a failure leaves the statements
/// before it applied.
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

    /// Every change but a rename writes the column again whole, its
    /// comment included, so each takes what the restatement takes. A
    /// generated column is restated with its expression, but takes no
    /// default and no AUTO_INCREMENT. A MODIFY restates the type too, so a
    /// column whose type the catalogue did not spell cannot take one.
    fn column_capabilities(&self, table: &TableDefinition, column: &ColumnDefinition) -> ColumnCapabilities {
        let capabilities = DdlDialect::capabilities(self);
        let engine = |allowed: bool| Permission::unless(allowed, RefusalReason::EngineUnsupported);
        let restated = || restatement(column);
        let mut permissions = ColumnCapabilities::standard(capabilities, table, column);
        permissions.alter_type = engine(capabilities.alter_column_type).and(restated);
        permissions.alter_nullability = engine(capabilities.alter_column_nullability)
            .and(restated)
            .and(|| nullability_permission(self, column));
        permissions.alter_default = permissions.alter_default.and(restated);
        permissions.alter_auto_increment = permissions.alter_auto_increment.and(restated);
        permissions.alter_comment = engine(capabilities.column_comments).and(restated);
        if column.info.column_type.catalog.is_none() {
            let unreadable = || Permission::Refused(RefusalReason::UnreadableDefinition);
            permissions.alter_nullability = permissions.alter_nullability.and(unreadable);
            permissions.alter_default = permissions.alter_default.and(unreadable);
            permissions.alter_auto_increment = permissions.alter_auto_increment.and(unreadable);
            permissions.alter_comment = permissions.alter_comment.and(unreadable);
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
            .map(|column| render(self, column))
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
        for alteration in changes
            .altered_columns
            .iter()
            .filter(|alteration| restates(alteration.changed))
        {
            refuse_renamed_names(alteration, changes)?;
        }
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
                    render(self, &alteration.draft)?
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
                actions.push(format!("MODIFY COLUMN {}", render(self, &alteration.draft)?));
            }
        }
        for column in &changes.added_columns {
            actions.push(format!("ADD COLUMN {}", render(self, column)?));
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
        DdlPlan::for_changes(changes, statements)
    }

    /// The server's own SHOW CREATE TABLE, which carries the engine,
    /// charset and every option the definition does not model, and
    /// spells a comment for whatever sql_mode runs it.
    fn create_table_script(&self, definition: &TableDefinition) -> Result<DdlPlan, BuildDdlError> {
        definition
            .source
            .as_ref()
            .map(|source| DdlPlan::from_sql([source.create_statement.clone()]))
            .ok_or(BuildDdlError::NoTableSource)
    }
}

/// Whether an alteration needs the column's definition restated. A
/// primary-key flag alone is the table's key clause.
fn restates(changed: ChangedAttributes) -> bool {
    changed.column_type || changed.nullability || changed.default || changed.auto_increment || changed.comment
}

/// The server reads a restated column against the names the same ALTER
/// gives, while the expressions it splices were printed with the names
/// before it. MariaDB's own CHECK on a column names the column, and any
/// other expression is searched for a renamed column's old name.
fn refuse_renamed_names(alteration: &ColumnAlteration, changes: &TableChanges) -> Result<(), BuildDdlError> {
    let original = &alteration.original;
    let attributes = &original.attributes;
    let refuse = |renamed: &str| BuildDdlError::Refused {
        column: original.name().to_owned(),
        operation: DdlOperation::RenameColumn,
        reason: RefusalReason::NamesRenamedColumn(renamed.to_owned()),
    };
    if attributes.check.is_some() && original.name() != alteration.draft.name {
        return Err(refuse(original.name()));
    }
    let default = match &alteration.draft.default {
        ColumnDefault::Expression(expression) => Some(expression),
        _ => None,
    };
    let expressions = [
        attributes.check.as_ref(),
        attributes.generated.as_ref().map(|generated| &generated.expression),
        default,
    ];
    let named = |name: &str| {
        let printed = printed_names(name);
        expressions.iter().flatten().any(|expression| {
            printed
                .iter()
                .any(|printed| expression.as_sql().contains(printed.as_str()))
        })
    };
    match changes.renamed_columns.iter().find(|rename| named(&rename.from)) {
        Some(rename) => Err(refuse(&rename.from)),
        None => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::ForeignKeyInfo;
    use tablepro_core::ServerInfo;
    use tablepro_core::column::{ColumnDefault, ColumnInfo, SqlExpression};
    use tablepro_core::ddl::{
        CollationName, ColumnAttributes, ColumnVisibility, DdlOperation, DraftColumn, DraftType, DropTableOptions,
        GeneratedColumn, GeneratedStorage, InboundForeignKey, PrimaryKeyConstraint, UnmodeledAttribute, diff_table,
    };
    use tablepro_core::meta::{IndexInfo, IndexKey};
    use tablepro_core::value::Value;

    use super::*;
    use crate::flavour::MySqlFlavour;

    fn dialect() -> MySqlDialect {
        MySqlDialect::new(MySqlFlavour::MySql, &ServerInfo::new("MySQL", "8.4.3", 8, 4, 3))
    }

    fn mariadb() -> MySqlDialect {
        MySqlDialect::new(MySqlFlavour::MariaDb, &ServerInfo::new("MariaDB", "11.4.5", 11, 4, 5))
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
        alter_on(&dialect(), original, edit)
    }

    fn alter_on(
        dialect: &MySqlDialect,
        original: &TableDefinition,
        edit: impl FnOnce(&mut TableDraft),
    ) -> Result<DdlPlan, BuildDdlError> {
        let mut draft = TableDraft::from_definition(original);
        edit(&mut draft);
        dialect.plan_alter_table(original, &diff_table(original, &draft))
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
    fn pk_change_single_statement() {
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

    #[test]
    fn a_swap_is_one_statement_against_the_original_names() {
        let plan = alter(&users(), |draft| {
            draft.columns[1].name = "account_id".to_owned();
            draft.columns[2].name = "email".to_owned();
            draft.columns[2].nullable = false;
        });

        assert_eq!(
            sql(plan),
            [
                "ALTER TABLE `app`.`users` RENAME COLUMN `email` TO `account_id`, CHANGE COLUMN `account_id` `email` \
                 int NOT NULL"
            ]
        );
    }

    #[test]
    fn auto_increment_goes_through_the_definition() {
        let mut table = users();
        table.columns[0].info.is_auto_increment = true;

        let off = alter(&table, |draft| draft.columns[0].auto_increment = false);
        let on = alter(&users(), |draft| draft.columns[0].auto_increment = true);

        assert_eq!(sql(off), ["ALTER TABLE `app`.`users` MODIFY COLUMN `id` int NOT NULL"]);
        assert_eq!(
            sql(on),
            ["ALTER TABLE `app`.`users` MODIFY COLUMN `id` int NOT NULL AUTO_INCREMENT"]
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
        assert_eq!(
            dialect().create_table_script(&users()),
            Err(BuildDdlError::NoTableSource)
        );
    }

    fn with_attributes(name: &str, declaration: &str, edit: impl FnOnce(&mut ColumnAttributes)) -> ColumnDefinition {
        let mut column = column(name, declaration, false);
        edit(&mut column.attributes);
        column
    }

    fn attributed() -> TableDefinition {
        let mut table = users();
        table.columns.extend([
            with_attributes("code", "varchar(20)", |attributes| {
                attributes.character_set = Some("utf8mb4".to_owned());
                attributes.collation = Some(CollationName::new(None, "utf8mb4_bin"));
            }),
            with_attributes("stamp", "timestamp", |attributes| {
                attributes.on_update = Some(SqlExpression::from_catalog_text("CURRENT_TIMESTAMP"));
                attributes.visibility = ColumnVisibility::Invisible;
            }),
            with_attributes("shape", "point", |attributes| attributes.spatial_reference = Some(4326)),
        ]);
        table
    }

    fn edit_column(draft: &mut TableDraft, name: &str, edit: impl FnOnce(&mut DraftColumn)) {
        edit(
            draft
                .columns
                .iter_mut()
                .find(|column| column.name == name)
                .expect("the column"),
        );
    }

    fn refused(plan: &Result<DdlPlan, BuildDdlError>, operation: DdlOperation, reason: &RefusalReason) -> bool {
        matches!(plan, Err(BuildDdlError::Refused { operation: refused, reason: why, .. }) if *refused == operation && why == reason)
    }

    #[test]
    fn mysql_render_restates_comment_charset_collation_on_update_invisible_srid() {
        let mut table = attributed();
        table.columns[3].info.comment = Some("kept \\ note".to_owned());

        let plan = alter(&table, |draft| {
            edit_column(draft, "code", |column| column.nullable = false);
            edit_column(draft, "stamp", |column| column.comment = Some("it's \\ x".to_owned()));
            edit_column(draft, "shape", |column| column.nullable = false);
        });

        assert_eq!(
            sql(plan),
            [
                "ALTER TABLE `app`.`users` MODIFY COLUMN `code` varchar(20) CHARACTER SET `utf8mb4` COLLATE \
                 `utf8mb4_bin` NOT NULL COMMENT 'kept \\\\ note', MODIFY COLUMN `stamp` timestamp NULL ON UPDATE \
                 CURRENT_TIMESTAMP INVISIBLE COMMENT 'it''s \\\\ x', MODIFY COLUMN `shape` point NOT NULL SRID 4326"
            ]
        );
    }

    #[test]
    fn mysql_type_change_to_int_drops_charset_and_collation() {
        let plan = alter(&attributed(), |draft| {
            edit_column(draft, "code", |column| {
                column.column_type = DraftType::Typed("int".to_owned())
            });
            edit_column(draft, "stamp", |column| {
                column.column_type = DraftType::Typed("date".to_owned())
            });
            edit_column(draft, "shape", |column| {
                column.column_type = DraftType::Typed("polygon".to_owned())
            });
        });

        assert_eq!(
            sql(plan),
            [
                "ALTER TABLE `app`.`users` MODIFY COLUMN `code` int NULL, MODIFY COLUMN `stamp` date NULL INVISIBLE, \
                 MODIFY COLUMN `shape` polygon NULL SRID 4326"
            ]
        );
        // A character set typed with the type would clash with the one
        // kept from the catalogue, so the type parser has to refuse it.
        assert!(dialect().parse_type("varchar(20) character set latin1").is_err());
        assert!(dialect().parse_type("varchar(20) collate latin1_bin").is_err());
    }

    #[test]
    fn mysql_unmodeled_attribute_refuses_alteration() {
        let mut table = users();
        table.columns.extend([
            with_attributes("note", "varchar(20)", |attributes| {
                attributes.unmodeled = vec![UnmodeledAttribute::new("WITHOUT SYSTEM VERSIONING")];
            }),
            with_attributes("label", "varchar(20)", |attributes| {
                attributes.collation = Some(CollationName::new(None, "odd-name"));
            }),
        ]);
        let unmodeled = RefusalReason::UnmodeledAttribute("WITHOUT SYSTEM VERSIONING".to_owned());
        let odd = RefusalReason::UnmodeledAttribute("COLLATE odd-name".to_owned());

        for (column, reason) in [(&table.columns[3], &unmodeled), (&table.columns[4], &odd)] {
            let permissions = dialect().column_capabilities(&table, column);
            for permission in [
                &permissions.alter_type,
                &permissions.alter_nullability,
                &permissions.alter_default,
                &permissions.alter_auto_increment,
                &permissions.alter_comment,
            ] {
                assert_eq!(permission, &Permission::Refused(reason.clone()), "{}", column.name());
            }
            assert_eq!(permissions.rename, Permission::Allowed);
        }
        let renamed_and_commented = alter(&table, |draft| {
            edit_column(draft, "note", |column| {
                column.name = "remark".to_owned();
                column.comment = Some("x".to_owned());
            });
        });
        let renamed = alter(&table, |draft| {
            edit_column(draft, "label", |column| column.name = "tag".to_owned())
        });

        assert!(
            refused(&renamed_and_commented, DdlOperation::SetColumnComment, &unmodeled),
            "{renamed_and_commented:?}"
        );
        assert_eq!(
            sql(renamed),
            ["ALTER TABLE `app`.`users` RENAME COLUMN `label` TO `tag`"]
        );
    }

    fn generated(table: &mut TableDefinition, name: &str, expression: Option<&str>) {
        let mut column = with_attributes(name, "int", |attributes| {
            attributes.generated = expression.map(|expression| GeneratedColumn {
                expression: SqlExpression::from_catalog_text(expression),
                storage: GeneratedStorage::Stored,
            });
        });
        column.info.is_generated = true;
        table.columns.push(column);
    }

    #[test]
    fn a_generated_column_is_restated_with_its_expression() {
        let mut table = users();
        generated(&mut table, "total", Some("(`id` * 2)"));
        generated(&mut table, "unread", None);

        let total = dialect().column_capabilities(&table, &table.columns[3]);
        let unread = dialect().column_capabilities(&table, &table.columns[4]);
        let plan = alter(&table, |draft| {
            edit_column(draft, "total", |column| {
                column.column_type = DraftType::Typed("bigint".to_owned());
                column.nullable = false;
                column.comment = Some("doubled".to_owned());
            });
        });

        assert_eq!(total.alter_type, Permission::Allowed);
        assert_eq!(total.alter_nullability, Permission::Allowed);
        assert_eq!(total.alter_comment, Permission::Allowed);
        assert_eq!(total.alter_default, Permission::Refused(RefusalReason::GeneratedColumn));
        assert_eq!(
            total.alter_auto_increment,
            Permission::Refused(RefusalReason::GeneratedColumn)
        );
        assert_eq!(
            unread.alter_comment,
            Permission::Refused(RefusalReason::GeneratedColumn)
        );
        assert_eq!(
            sql(plan),
            [
                "ALTER TABLE `app`.`users` MODIFY COLUMN `total` bigint GENERATED ALWAYS AS (`id` * 2) STORED NOT NULL \
                 COMMENT 'doubled'"
            ]
        );
    }

    #[test]
    fn an_expression_default_is_restated_in_parentheses() {
        let mut table = users();
        table.columns.push(with_attributes("token", "char(36)", |_| {}));
        table.columns[3].info.default = ColumnDefault::Expression(SqlExpression::from_catalog_text("uuid()"));

        let plan = alter(&table, |draft| {
            edit_column(draft, "token", |column| column.nullable = false)
        });

        assert_eq!(
            sql(plan),
            ["ALTER TABLE `app`.`users` MODIFY COLUMN `token` char(36) NOT NULL DEFAULT (uuid())"]
        );
    }

    #[test]
    fn mariadb_restates_its_srid_column_check_and_generated_columns() {
        let mut table = users();
        table.columns.extend([
            with_attributes("shape", "point", |attributes| attributes.spatial_reference = Some(4326)),
            with_attributes("doc", "longtext", |attributes| {
                attributes.character_set = Some("utf8mb4".to_owned());
                attributes.collation = Some(CollationName::new(None, "utf8mb4_bin"));
                attributes.check = Some(SqlExpression::from_catalog_text("json_valid(`doc`)"));
                attributes.visibility = ColumnVisibility::Invisible;
            }),
        ]);
        generated(&mut table, "total", Some("`id` * 2"));
        table.columns[5].attributes.visibility = ColumnVisibility::Invisible;

        let total = mariadb().column_capabilities(&table, &table.columns[5]);
        let plan = alter_on(&mariadb(), &table, |draft| {
            edit_column(draft, "shape", |column| column.nullable = false);
            edit_column(draft, "doc", |column| column.comment = Some("x".to_owned()));
            edit_column(draft, "total", |column| column.comment = Some("y".to_owned()));
        });

        assert_eq!(
            total.alter_nullability,
            Permission::Refused(RefusalReason::GeneratedColumn)
        );
        assert_eq!(total.alter_comment, Permission::Allowed);
        assert_eq!(
            sql(plan),
            [
                "ALTER TABLE `app`.`users` MODIFY COLUMN `shape` point REF_SYSTEM_ID=4326 NOT NULL, MODIFY COLUMN \
                 `doc` longtext CHARACTER SET `utf8mb4` COLLATE `utf8mb4_bin` NULL INVISIBLE COMMENT 'x' CHECK \
                 (json_valid(`doc`)), MODIFY COLUMN `total` int GENERATED ALWAYS AS (`id` * 2) STORED INVISIBLE \
                 COMMENT 'y'"
            ]
        );
    }

    #[test]
    fn a_restatement_that_names_a_column_the_same_save_renames_is_refused() {
        let mut table = users();
        table.columns.extend([
            with_attributes("doc", "longtext", |attributes| {
                attributes.check = Some(SqlExpression::from_catalog_text("json_valid(`doc`)"));
            }),
            with_attributes("base", "int", |_| {}),
            with_attributes("bounded", "int", |attributes| {
                attributes.check = Some(SqlExpression::from_catalog_text("`bounded` > `base`"));
            }),
        ]);
        generated(&mut table, "total", Some("`base` * 2"));
        let names = |name: &str| RefusalReason::NamesRenamedColumn(name.to_owned());

        let own = alter_on(&mariadb(), &table, |draft| {
            edit_column(draft, "doc", |column| {
                column.name = "body".to_owned();
                column.comment = Some("x".to_owned());
            });
        });
        let checked = alter_on(&mariadb(), &table, |draft| {
            edit_column(draft, "base", |column| column.name = "floor".to_owned());
            edit_column(draft, "bounded", |column| column.nullable = false);
        });
        let computed = alter_on(&mariadb(), &table, |draft| {
            edit_column(draft, "base", |column| column.name = "floor".to_owned());
            edit_column(draft, "total", |column| column.comment = Some("y".to_owned()));
        });
        let apart = alter_on(&mariadb(), &table, |draft| {
            edit_column(draft, "doc", |column| column.name = "body".to_owned());
            edit_column(draft, "bounded", |column| column.nullable = false);
        });

        assert!(refused(&own, DdlOperation::RenameColumn, &names("doc")), "{own:?}");
        assert!(
            refused(&checked, DdlOperation::RenameColumn, &names("base")),
            "{checked:?}"
        );
        assert!(
            refused(&computed, DdlOperation::RenameColumn, &names("base")),
            "{computed:?}"
        );
        assert_eq!(
            sql(apart),
            [
                "ALTER TABLE `app`.`users` RENAME COLUMN `doc` TO `body`, MODIFY COLUMN `bounded` int NOT NULL CHECK \
                 (`bounded` > `base`)"
            ]
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
