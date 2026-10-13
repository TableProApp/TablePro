use super::*;
use crate::column::{
    CatalogType, ColumnDefault, ColumnInfo, ColumnKind, ColumnType, IntegerKind, IntegerWidth, ReadForm, SqlExpression,
    SqlTypeExpr, TextLength,
};
use crate::dialect::{SqlDialect, TestDialect};
use crate::foreign_key_info::ForeignKeyInfo;
use crate::meta::{IndexInfo, IndexKey, TableRef};
use crate::value::Value;

fn catalog_type(declaration: &str, kind: ColumnKind) -> ColumnType {
    ColumnType {
        name: declaration.to_owned(),
        kind,
        catalog: Some(CatalogType {
            declaration: SqlTypeExpr::from_catalog_text(declaration),
            cast_target: SqlTypeExpr::from_catalog_text(declaration),
        }),
        dynamic_storage: false,
        read_form: ReadForm::Native,
    }
}

fn integer() -> ColumnType {
    catalog_type(
        "integer",
        ColumnKind::Integer(IntegerKind {
            width: IntegerWidth::W32,
            signed: true,
        }),
    )
}

fn text() -> ColumnType {
    catalog_type(
        "text",
        ColumnKind::Text {
            length: TextLength::Unbounded,
        },
    )
}

fn column(name: &str, column_type: ColumnType, primary_key: bool) -> ColumnDefinition {
    ColumnDefinition::new(
        ColumnInfo {
            name: name.to_owned(),
            column_type,
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

fn index(name: &str, columns: &[&str]) -> IndexInfo {
    IndexInfo {
        name: name.to_owned(),
        keys: columns
            .iter()
            .map(|column| IndexKey::Column {
                name: (*column).to_owned(),
                descending: false,
            })
            .collect(),
        unique: false,
        primary: false,
        predicate: None,
    }
}

fn foreign_key(name: &str, column: &str) -> ForeignKeyInfo {
    ForeignKeyInfo {
        name: name.to_owned(),
        columns: vec![column.to_owned()],
        ref_schema: None,
        ref_table: "accounts".to_owned(),
        ref_columns: vec!["id".to_owned()],
        on_delete: Some(ReferentialAction::Cascade),
        on_update: None,
    }
}

fn users() -> TableDefinition {
    TableDefinition {
        table: TableRef::new(Some("app".to_owned()), "users"),
        columns: vec![
            column("id", integer(), true),
            column("email", text(), false),
            column("account_id", integer(), false),
            column("legacy", text(), false),
        ],
        primary_key: Some(PrimaryKeyConstraint {
            name: Some("users_pkey".to_owned()),
            columns: vec!["id".to_owned()],
        }),
        indexes: vec![
            IndexInfo {
                primary: true,
                unique: true,
                ..index("users_pkey", &["id"])
            },
            index("by_email", &["email"]),
            index("by_legacy", &["legacy"]),
        ],
        foreign_keys: vec![foreign_key("users_account_fk", "account_id")],
        inbound_foreign_keys: Vec::new(),
        source: None,
    }
}

fn draft_column<'a>(draft: &'a mut TableDraft, name: &str) -> &'a mut DraftColumn {
    draft
        .columns
        .iter_mut()
        .find(|column| column.name == name)
        .expect("the column is in the draft")
}

#[test]
fn diff_table_detects_each_change_kind() {
    let original = users();
    let mut draft = TableDraft::from_definition(&original);
    draft.table.name = "members".to_owned();
    draft.columns.retain(|column| column.name != "legacy");
    draft.indexes.retain(|index| index.name != "by_legacy");
    draft.foreign_keys.clear();
    draft_column(&mut draft, "email").name = "mail".to_owned();
    draft_column(&mut draft, "account_id").nullable = false;
    let mut added = DraftColumn::new("nickname", DraftType::Typed("varchar(40)".to_owned()));
    added.default = ColumnDefault::Literal(Value::Text("it's".to_owned()));
    draft.columns.push(added);
    draft.indexes.push(index("by_nickname", &["nickname"]));
    draft.foreign_keys.push(foreign_key("users_account_fk2", "account_id"));

    let changes = diff_table(&original, &draft);

    assert_eq!(changes.renamed_table.as_deref(), Some("members"));
    assert_eq!(
        changes
            .dropped_columns
            .iter()
            .map(ColumnDefinition::name)
            .collect::<Vec<_>>(),
        ["legacy"]
    );
    assert_eq!(
        changes.renamed_columns,
        [ColumnRename {
            from: "email".to_owned(),
            to: "mail".to_owned()
        }]
    );
    assert_eq!(changes.altered_columns.len(), 1);
    let alteration = &changes.altered_columns[0];
    assert_eq!(alteration.original.name(), "account_id");
    assert!(alteration.changed.nullability && !alteration.changed.column_type && !alteration.changed.default);
    assert_eq!(
        changes
            .added_columns
            .iter()
            .map(|c| c.name.as_str())
            .collect::<Vec<_>>(),
        ["nickname"]
    );
    assert_eq!(
        changes
            .dropped_indexes
            .iter()
            .map(|i| i.name.as_str())
            .collect::<Vec<_>>(),
        ["by_legacy"]
    );
    assert_eq!(
        changes
            .added_indexes
            .iter()
            .map(|i| i.name.as_str())
            .collect::<Vec<_>>(),
        ["by_nickname"]
    );
    assert_eq!(changes.dropped_foreign_keys[0].name, "users_account_fk");
    assert_eq!(changes.added_foreign_keys[0].name, "users_account_fk2");
    assert_eq!(changes.primary_key, None, "the key did not move");
    assert_eq!(
        changes.target(&original.table),
        TableRef::new(Some("app".to_owned()), "members")
    );
}

#[test]
fn an_unedited_draft_changes_nothing() {
    let original = users();
    let mut draft = TableDraft::from_definition(&original);
    // Retyping the declaration is the same type.
    draft_column(&mut draft, "email").column_type = DraftType::Typed(" text ".to_owned());
    // An empty comment is no comment.
    draft_column(&mut draft, "legacy").comment = Some(String::new());

    let changes = diff_table(&original, &draft);

    assert!(changes.is_empty(), "{changes:?}");
    assert_eq!(changes.change_count(), 0);
}

#[test]
fn a_rename_alone_is_one_change_and_alters_nothing() {
    let original = users();
    let mut draft = TableDraft::from_definition(&original);
    draft_column(&mut draft, "email").name = "mail".to_owned();

    let changes = diff_table(&original, &draft);

    assert_eq!(changes.change_count(), 1);
    assert!(changes.altered_columns.is_empty());
}

#[test]
fn change_count_matches_user_visible_edits() {
    let original = users();
    let mut draft = TableDraft::from_definition(&original);
    // A column renamed and retyped is two edits.
    let email = draft_column(&mut draft, "email");
    email.name = "mail".to_owned();
    email.column_type = DraftType::Typed("varchar(320)".to_owned());
    // Three attributes of one column are one edit.
    let legacy = draft_column(&mut draft, "legacy");
    legacy.nullable = false;
    legacy.default = ColumnDefault::Expression(SqlExpression::from_catalog_text("now()"));
    legacy.comment = Some("kept for the import".to_owned());
    draft.indexes.retain(|index| index.name != "by_email");
    draft
        .columns
        .push(DraftColumn::new("nickname", DraftType::Typed("text".to_owned())));

    let changes = diff_table(&original, &draft);

    assert_eq!(changes.change_count(), 5, "{changes:#?}");
}

#[test]
fn moving_the_primary_key_is_a_key_change_under_the_new_names() {
    let original = users();
    let mut draft = TableDraft::from_definition(&original);
    let id = draft_column(&mut draft, "id");
    id.name = "user_id".to_owned();
    let unchanged = diff_table(&original, &draft);
    assert_eq!(unchanged.primary_key, None, "a renamed key column is the same key");

    let account = draft_column(&mut draft, "account_id");
    account.primary_key = true;
    account.nullable = false;
    let changes = diff_table(&original, &draft);

    let change = changes.primary_key.expect("the key moved");
    assert_eq!(change.to, ["user_id", "account_id"]);
    assert_eq!(change.from.and_then(|key| key.name).as_deref(), Some("users_pkey"));
}

#[test]
fn table_draft_validate_reports_column_in_use() {
    let original = users();
    let mut draft = TableDraft::from_definition(&original);
    draft
        .columns
        .retain(|column| column.name != "email" && column.name != "account_id");

    assert_eq!(
        draft.validate(),
        Err(DraftProblem::ColumnInUse {
            column: "account_id".to_owned(),
            used_by: vec!["users_account_fk".to_owned()],
        })
    );

    draft.foreign_keys.clear();
    assert_eq!(
        draft.validate(),
        Err(DraftProblem::ColumnInUse {
            column: "email".to_owned(),
            used_by: vec!["by_email".to_owned()],
        })
    );

    // A rename carries the index along, so the old name still counts.
    let mut renamed = TableDraft::from_definition(&original);
    draft_column(&mut renamed, "email").name = "mail".to_owned();
    assert_eq!(renamed.validate(), Ok(()));
}

#[test]
fn table_draft_validate_reports_the_first_problem() {
    let mut draft = TableDraft::new(TableRef::unqualified(" "));
    assert_eq!(draft.validate(), Err(DraftProblem::EmptyTableName));
    draft.table.name = "t".to_owned();
    assert_eq!(draft.validate(), Err(DraftProblem::NoColumns));

    draft.columns = vec![
        DraftColumn::new("a", DraftType::Typed("int".to_owned())),
        DraftColumn::new("a", DraftType::Typed("int".to_owned())),
    ];
    assert_eq!(draft.validate(), Err(DraftProblem::DuplicateColumnName("a".to_owned())));

    draft.columns[1].name = String::new();
    assert_eq!(draft.validate(), Err(DraftProblem::EmptyColumnName));

    draft.columns[1].name = "b".to_owned();
    draft.columns[1].column_type = DraftType::Typed("  ".to_owned());
    assert_eq!(draft.validate(), Err(DraftProblem::EmptyColumnType("b".to_owned())));

    draft.columns[1].column_type = DraftType::Typed("int".to_owned());
    draft.columns[0].primary_key = true;
    assert_eq!(draft.validate(), Err(DraftProblem::NullablePrimaryKey("a".to_owned())));

    draft.columns[0].nullable = false;
    assert_eq!(draft.validate(), Ok(()));
}

#[test]
fn a_nullable_key_read_back_as_it_is_saves() {
    let mut table = users();
    // How SQLite reports an INTEGER PRIMARY KEY.
    table.columns[0].info.nullable = true;
    let mut draft = TableDraft::from_definition(&table);

    assert_eq!(draft.validate(), Ok(()));

    draft_column(&mut draft, "email").primary_key = true;
    assert_eq!(
        draft.validate(),
        Err(DraftProblem::NullablePrimaryKey("email".to_owned()))
    );
}

fn inbound(name: &str, referenced: &str) -> InboundForeignKey {
    InboundForeignKey {
        name: name.to_owned(),
        table: TableRef::new(Some("app".to_owned()), "orders"),
        columns: vec!["user_id".to_owned()],
        referenced_columns: vec![referenced.to_owned()],
    }
}

fn every_change() -> DdlCapabilities {
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
        create_index: true,
        drop_index: true,
        expression_index_keys: true,
        partial_indexes: true,
        add_foreign_key: true,
        drop_foreign_key: true,
        column_comments: true,
        drop_table_cascade: true,
    }
}

#[test]
fn a_referenced_primary_key_cannot_move_from_any_column() {
    let mut table = users();
    table.inbound_foreign_keys = vec![inbound("orders_user_fk", "id")];

    for column in &table.columns {
        let permissions = ColumnCapabilities::standard(&every_change(), &table, column);
        assert_eq!(
            permissions.alter_primary_key,
            Permission::Refused(RefusalReason::ReferencedByForeignKeys(vec![
                "orders_user_fk".to_owned()
            ])),
            "{}",
            column.name()
        );
    }
    let free = ColumnCapabilities::standard(&every_change(), &users(), &users().columns[0]);
    assert_eq!(free.alter_primary_key, Permission::Allowed);
}

#[test]
fn a_referenced_column_cannot_be_dropped() {
    let mut table = users();
    table.inbound_foreign_keys = vec![inbound("orders_mail_fk", "email"), inbound("audit_mail_fk", "email")];

    let email = ColumnCapabilities::standard(&every_change(), &table, &table.columns[1]);
    let legacy = ColumnCapabilities::standard(&every_change(), &table, &table.columns[3]);

    assert_eq!(
        email.drop,
        Permission::Refused(RefusalReason::ReferencedByForeignKeys(vec![
            "orders_mail_fk".to_owned(),
            "audit_mail_fk".to_owned()
        ]))
    );
    assert_eq!(email.rename, Permission::Allowed);
    assert_eq!(legacy.drop, Permission::Allowed);
}

#[test]
fn generated_numbered_and_unmodeled_columns_refuse_a_restatement() {
    let table = users();
    let mut generated = column("total", integer(), false);
    generated.attributes.generated = Some(GeneratedColumn {
        expression: SqlExpression::from_catalog_text("a + b"),
        storage: GeneratedStorage::Stored,
    });
    let mut numbered = column("seq", integer(), false);
    numbered.attributes.identity = IdentityStyle::GeneratedByDefault;
    let mut versioned = column("note", text(), false);
    versioned.attributes.unmodeled = vec![UnmodeledAttribute::new("WITHOUT SYSTEM VERSIONING")];
    let mut capabilities = every_change();
    capabilities.alter_column_type = false;

    let generated = ColumnCapabilities::standard(&every_change(), &table, &generated);
    let numbered = ColumnCapabilities::standard(&every_change(), &table, &numbered);
    let versioned = ColumnCapabilities::standard(&every_change(), &table, &versioned);
    let unsupported = ColumnCapabilities::standard(&capabilities, &table, &table.columns[1]);

    assert_eq!(
        generated.alter_type,
        Permission::Refused(RefusalReason::GeneratedColumn)
    );
    assert_eq!(generated.rename, Permission::Allowed);
    assert_eq!(generated.alter_comment, Permission::Allowed);
    assert_eq!(
        numbered.alter_default,
        Permission::Refused(RefusalReason::IdentityColumn)
    );
    assert_eq!(numbered.alter_type, Permission::Allowed);
    assert_eq!(
        versioned.alter_nullability,
        Permission::Refused(RefusalReason::UnmodeledAttribute(
            "WITHOUT SYSTEM VERSIONING".to_owned()
        ))
    );
    assert_eq!(
        unsupported.alter_type,
        Permission::Refused(RefusalReason::EngineUnsupported)
    );
}

/// A dialect whose plans only report that they were reached, for the
/// checks every plan runs first.
#[derive(Debug)]
struct CheckingDdl {
    capabilities: DdlCapabilities,
    sql: TestDialect,
}

impl DdlDialect for CheckingDdl {
    fn capabilities(&self) -> &DdlCapabilities {
        &self.capabilities
    }

    fn sql_dialect(&self) -> &dyn SqlDialect {
        &self.sql
    }

    fn type_suggestions(&self) -> &'static [&'static str] {
        &["integer"]
    }

    fn default_column_type(&self) -> &'static str {
        "text"
    }

    fn referential_actions(&self) -> &'static [ReferentialAction] {
        &[ReferentialAction::NoAction, ReferentialAction::SetNull]
    }

    fn plan_create_table(&self, draft: &TableDraft) -> Result<DdlPlan, BuildDdlError> {
        draft.check_create(self)?;
        Ok(DdlPlan::from_sql(Vec::new()))
    }

    fn plan_alter_table(&self, original: &TableDefinition, changes: &TableChanges) -> Result<DdlPlan, BuildDdlError> {
        changes.check(self, original)?;
        Ok(DdlPlan::from_sql(Vec::new()))
    }
}

fn checking(capabilities: DdlCapabilities) -> CheckingDdl {
    CheckingDdl {
        capabilities,
        sql: TestDialect::exact(),
    }
}

#[test]
fn a_plan_refuses_what_the_capabilities_refuse() {
    let mut table = users();
    table.inbound_foreign_keys = vec![inbound("orders_user_fk", "id")];
    let mut draft = TableDraft::from_definition(&table);
    draft.columns.retain(|column| column.name != "id");
    let mut no_drop = every_change();
    no_drop.drop_column = false;

    let refused = checking(every_change()).plan_alter_table(&table, &diff_table(&table, &draft));
    let unsupported = checking(no_drop).plan_alter_table(&table, &diff_table(&table, &draft));

    assert!(
        matches!(
            &refused,
            Err(BuildDdlError::Refused {
                column,
                operation: DdlOperation::DropColumn,
                reason: RefusalReason::ReferencedByForeignKeys(_),
            }) if column == "id"
        ),
        "{refused:?}"
    );
    assert_eq!(
        unsupported,
        Err(BuildDdlError::Refused {
            column: "id".to_owned(),
            operation: DdlOperation::DropColumn,
            reason: RefusalReason::EngineUnsupported,
        })
    );
}

#[test]
fn a_plan_refuses_an_action_the_engine_does_not_take() {
    let table = users();
    let mut draft = TableDraft::from_definition(&table);
    draft.foreign_keys[0].on_delete = Some(ReferentialAction::Restrict);

    let outcome = checking(every_change()).plan_alter_table(&table, &diff_table(&table, &draft));

    assert_eq!(
        outcome,
        Err(BuildDdlError::ReferentialAction(ReferentialAction::Restrict))
    );
}

#[test]
fn a_create_needs_the_capability_and_a_valid_draft() {
    let mut no_create = every_change();
    no_create.create_table = false;
    let mut draft = TableDraft::new(TableRef::unqualified("t"));

    assert_eq!(
        checking(no_create).plan_create_table(&draft),
        Err(BuildDdlError::Unsupported(DdlOperation::CreateTable))
    );
    assert_eq!(
        checking(every_change()).plan_create_table(&draft),
        Err(BuildDdlError::Draft(DraftProblem::NoColumns))
    );
    draft
        .columns
        .push(DraftColumn::new("a", DraftType::Typed("int".to_owned())));
    assert!(checking(every_change()).plan_create_table(&draft).is_ok());
}

#[test]
fn a_default_drop_takes_the_dialect_default() {
    let plan = checking(every_change())
        .plan_drop_table(
            &TableRef::new(Some("app".to_owned()), "or\"ders"),
            DropTableOptions {
                if_exists: true,
                cascade: true,
            },
        )
        .expect("the drop plans");
    let mut no_cascade = every_change();
    no_cascade.drop_table_cascade = false;

    assert_eq!(plan.sql(), ["DROP TABLE IF EXISTS \"app\".\"or\"\"ders\" CASCADE"]);
    assert_eq!(
        checking(no_cascade).plan_drop_table(
            &TableRef::unqualified("t"),
            DropTableOptions {
                if_exists: false,
                cascade: true
            }
        ),
        Err(BuildDdlError::Unsupported(DdlOperation::DropTableCascade))
    );
}

#[test]
fn a_typed_type_is_parsed_and_spliced_as_typed() {
    let dialect = TestDialect::exact();

    let resolved = DraftType::Typed(" varchar(20) ".to_owned()).resolve(&dialect, "name");
    let refused = DraftType::Typed("int; DROP TABLE t".to_owned()).resolve(&dialect, "name");
    let missing = DraftType::Catalog(ColumnType::unknown()).resolve(&dialect, "name");

    assert_eq!(resolved.map(|resolved| resolved.sql), Ok("varchar(20)".to_owned()));
    assert!(matches!(refused, Err(BuildDdlError::InvalidType { column, .. }) if column == "name"));
    assert_eq!(
        missing,
        Err(BuildDdlError::MissingCatalogDeclaration("name".to_owned()))
    );
}

#[test]
fn a_typed_default_becomes_a_value_or_an_expression() {
    let dialect = TestDialect::exact();

    assert_eq!(
        parse_default(&dialect, "'it''s'", &text()),
        Ok(ColumnDefault::Literal(Value::Text("it's".to_owned())))
    );
    assert_eq!(
        parse_default(&dialect, "42", &integer()),
        Ok(ColumnDefault::Literal(Value::Int(42)))
    );
    assert!(matches!(
        parse_default(&dialect, "now()", &text()),
        Ok(ColumnDefault::Expression(expression)) if expression.as_sql() == "now()"
    ));
    assert_eq!(parse_default(&dialect, "  ", &text()), Ok(ColumnDefault::None));
    assert!(parse_default(&dialect, "1; DROP TABLE t", &integer()).is_err());
    assert_eq!(
        default_text(
            &dialect,
            &ColumnDefault::Literal(Value::Text("it's".to_owned())),
            &text()
        ),
        "'it''s'"
    );
}
