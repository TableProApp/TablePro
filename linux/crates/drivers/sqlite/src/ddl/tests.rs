use tablepro_core::column::{ColumnInfo, SqlExpression};
use tablepro_core::ddl::{
    ColumnAttributes, ColumnDefinition, DdlOperation, DraftType, GeneratedColumn, IdentityStyle, InboundForeignKey,
    Permission, PrimaryKeyConstraint, ReferentialAction, RefusalReason, SchemaObjectSource, TableSource, diff_table,
};
use tablepro_core::meta::IndexKey;
use tablepro_core::value::Value;
use tablepro_core::{ForeignKeyCheck, ForeignKeyMode};

use super::*;
use crate::catalog::SqliteVersion;

fn dialect() -> SqliteDialect {
    SqliteDialect::new(SqliteVersion::new(3, 46, 0))
}

fn typed(name: &str, declaration: &str) -> DraftColumn {
    DraftColumn::new(name, DraftType::Typed(declaration.to_owned()))
}

fn column(name: &str, declaration: &str, primary_key: bool) -> ColumnDefinition {
    ColumnDefinition::new(
        ColumnInfo {
            name: name.to_owned(),
            column_type: dialect().parse_type(declaration).expect("a SQLite type"),
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

/// `INTEGER PRIMARY KEY`, the rowid itself, as the catalogue reads it.
fn rowid_alias(name: &str) -> ColumnDefinition {
    let mut column = column(name, "INTEGER", true);
    column.info.nullable = true;
    column.info.is_auto_increment = true;
    column.attributes.identity = IdentityStyle::SqliteRowidAlias;
    column
}

fn not_null(mut column: ColumnDefinition) -> ColumnDefinition {
    column.info.nullable = false;
    column
}

fn table(name: &str, columns: Vec<ColumnDefinition>, create: &str) -> TableDefinition {
    let key: Vec<String> = columns
        .iter()
        .filter(|column| column.info.primary_key)
        .map(|column| column.name().to_owned())
        .collect();
    TableDefinition {
        table: TableRef::unqualified(name),
        columns,
        primary_key: (!key.is_empty()).then_some(PrimaryKeyConstraint {
            name: None,
            columns: key,
        }),
        indexes: Vec::new(),
        foreign_keys: Vec::new(),
        inbound_foreign_keys: Vec::new(),
        source: Some(TableSource {
            create_statement: create.to_owned(),
            dependents: Vec::new(),
        }),
    }
}

fn object(kind: SchemaObjectKind, name: &str, owner: &str, sql: &str) -> SchemaObjectSource {
    SchemaObjectSource {
        kind,
        name: name.to_owned(),
        table: owner.to_owned(),
        sql: sql.to_owned(),
    }
}

fn index(name: &str, column: &str) -> IndexInfo {
    IndexInfo {
        name: name.to_owned(),
        keys: vec![IndexKey::Column {
            name: column.to_owned(),
            descending: false,
        }],
        unique: false,
        primary: false,
        predicate: None,
    }
}

fn foreign_key(name: &str, column: &str, parent: &str, parent_column: &str) -> ForeignKeyInfo {
    ForeignKeyInfo {
        name: name.to_owned(),
        columns: vec![column.to_owned()],
        ref_schema: None,
        ref_table: parent.to_owned(),
        ref_columns: vec![parent_column.to_owned()],
        on_delete: Some(ReferentialAction::NoAction),
        on_update: Some(ReferentialAction::NoAction),
    }
}

fn inbound(name: &str, child: &str, column: &str, parent_column: &str) -> InboundForeignKey {
    InboundForeignKey {
        name: name.to_owned(),
        table: TableRef::unqualified(child),
        columns: vec![column.to_owned()],
        referenced_columns: vec![parent_column.to_owned()],
    }
}

fn users() -> TableDefinition {
    TableDefinition {
        source: None,
        ..table(
            "users",
            vec![column("id", "INTEGER", true), column("email", "TEXT", false)],
            "",
        )
    }
}

/// A table with each kind of dependent: its own index and trigger, a
/// view on it, a trigger on another table that writes to it, and a
/// table whose foreign key points at it.
fn orders() -> TableDefinition {
    let mut total = column("total", "REAL", false);
    total.info.default = ColumnDefault::Literal(Value::Int(0));
    let mut orders = table(
        "orders",
        vec![
            rowid_alias("id"),
            not_null(column("customer", "INTEGER", false)),
            total,
            column("note", "TEXT", false),
        ],
        "CREATE TABLE orders (\n  id INTEGER PRIMARY KEY,\n  customer INTEGER NOT NULL REFERENCES customers (id),\n  \
         total REAL DEFAULT 0 CHECK (total >= 0),\n  note TEXT COLLATE NOCASE\n)",
    );
    orders.indexes = vec![index("orders_by_customer", "customer")];
    orders.foreign_keys = vec![foreign_key("fk_orders_0", "customer", "customers", "id")];
    orders.inbound_foreign_keys = vec![inbound("fk_lines_0", "lines", "order_id", "id")];
    if let Some(source) = orders.source.as_mut() {
        source.dependents = vec![
            object(
                SchemaObjectKind::Index,
                "orders_by_customer",
                "orders",
                "CREATE INDEX orders_by_customer ON orders (customer)",
            ),
            object(
                SchemaObjectKind::Trigger,
                "orders_stamp",
                "orders",
                "CREATE TRIGGER orders_stamp AFTER INSERT ON orders BEGIN UPDATE orders SET note = 'new' WHERE id = \
                 new.id; END",
            ),
            object(
                SchemaObjectKind::View,
                "big_orders",
                "big_orders",
                "CREATE VIEW big_orders AS SELECT id, total FROM orders WHERE total > 100",
            ),
            object(
                SchemaObjectKind::Trigger,
                "customers_cleanup",
                "customers",
                "CREATE TRIGGER customers_cleanup AFTER DELETE ON customers BEGIN DELETE FROM orders WHERE customer = \
                 old.id; END",
            ),
        ];
    }
    orders
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

fn checks(plan: &Result<DdlPlan, BuildDdlError>) -> Vec<ForeignKeyCheck> {
    match plan.as_ref().map(|plan| &plan.foreign_keys) {
        Ok(ForeignKeyMode::SuspendedThenVerified { checks }) => checks.clone(),
        other => panic!("not a rebuild: {other:?}"),
    }
}

fn retype(draft: &mut TableDraft, name: &str, declaration: &str) {
    if let Some(column) = draft.columns.iter_mut().find(|column| column.name == name) {
        column.column_type = DraftType::Typed(declaration.to_owned());
    }
}

fn refusal(plan: &Result<DdlPlan, BuildDdlError>) -> Option<(&str, DdlOperation, &RefusalReason)> {
    match plan {
        Err(BuildDdlError::Refused {
            column,
            operation,
            reason,
        }) => Some((column.as_str(), *operation, reason)),
        _ => None,
    }
}

#[test]
fn plan_create_table_simple() {
    let mut draft = TableDraft::new(TableRef::unqualified("notes"));
    let mut id = typed("id", "INTEGER");
    id.primary_key = true;
    id.nullable = false;
    id.auto_increment = true;
    let mut body = typed("body", "TEXT");
    body.nullable = false;
    body.default = ColumnDefault::Literal(Value::Text("it's".to_owned()));
    let mut created = typed("created_at", "TEXT");
    created.default = ColumnDefault::Expression(SqlExpression::from_catalog_text("CURRENT_TIMESTAMP"));
    let mut token = typed("token", "TEXT");
    token.default = ColumnDefault::Expression(SqlExpression::from_catalog_text("lower(hex(randomblob(4)))"));
    draft.columns = vec![id, body, created, token];

    assert_eq!(
        sql(dialect().plan_create_table(&draft)),
        [
            "CREATE TABLE \"notes\" (\n  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,\n  \"body\" TEXT NOT \
             NULL DEFAULT 'it''s',\n  \"created_at\" TEXT DEFAULT CURRENT_TIMESTAMP,\n  \"token\" TEXT DEFAULT \
             (lower(hex(randomblob(4))))\n)"
        ]
    );
}

#[test]
fn plan_create_table_composite_key_index_and_foreign_key() {
    let mut draft = TableDraft::new(TableRef::new(Some("main".to_owned()), "lines"));
    let mut order = typed("order_id", "INTEGER");
    order.primary_key = true;
    order.nullable = false;
    let mut line = typed("line", "INTEGER");
    line.primary_key = true;
    line.nullable = false;
    draft.columns = vec![order, line, typed("sku", "TEXT")];
    draft.indexes = vec![IndexInfo {
        name: "by_sku".to_owned(),
        keys: vec![IndexKey::Column {
            name: "sku".to_owned(),
            descending: false,
        }],
        unique: true,
        primary: false,
        predicate: Some("sku IS NOT NULL".to_owned()),
    }];
    draft.foreign_keys = vec![ForeignKeyInfo {
        on_delete: Some(ReferentialAction::Cascade),
        on_update: None,
        ..foreign_key("lines_order_fk", "order_id", "orders", "id")
    }];

    assert_eq!(
        sql(dialect().plan_create_table(&draft)),
        [
            "CREATE TABLE \"main\".\"lines\" (\n  \"order_id\" INTEGER NOT NULL,\n  \"line\" INTEGER NOT NULL,\n  \
             \"sku\" TEXT,\n  PRIMARY KEY (\"order_id\", \"line\"),\n  CONSTRAINT \"lines_order_fk\" FOREIGN KEY \
             (\"order_id\") REFERENCES \"orders\" (\"id\") ON DELETE CASCADE\n)",
            "CREATE UNIQUE INDEX \"main\".\"by_sku\" ON \"lines\" (\"sku\") WHERE sku IS NOT NULL",
        ]
    );
}

#[test]
fn create_table_inlines_foreign_keys_without_pragma() {
    let mut draft = TableDraft::new(TableRef::new(Some("main".to_owned()), "lines"));
    draft.columns = vec![typed("order_id", "INTEGER")];
    draft.foreign_keys = vec![ForeignKeyInfo {
        ref_schema: Some("main".to_owned()),
        on_delete: Some(ReferentialAction::SetNull),
        ..foreign_key("lines_order", "order_id", "orders", "id")
    }];

    let plan = dialect().plan_create_table(&draft).expect("the table plans");

    assert_eq!(
        plan.sql(),
        [
            "CREATE TABLE \"main\".\"lines\" (\n  \"order_id\" INTEGER,\n  CONSTRAINT \"lines_order\" FOREIGN KEY \
          (\"order_id\") REFERENCES \"orders\" (\"id\") ON DELETE SET NULL\n)"
        ]
    );
    assert!(plan.foreign_keys.is_enforced());
    assert!(plan.sql().iter().all(|statement| !statement.contains("PRAGMA")));
}

#[test]
fn native_rename_and_add_column_skip_rebuild() {
    let notes = table(
        "notes",
        vec![column("title", "TEXT", false), column("body", "TEXT", false)],
        "CREATE TABLE notes (title TEXT, body TEXT)",
    );

    let plan = alter(&notes, |draft| {
        draft.table.name = "memos".to_owned();
        draft.columns[1].name = "content".to_owned();
        let mut tag = typed("tag", "TEXT");
        tag.nullable = false;
        tag.default = ColumnDefault::Literal(Value::Text("none".to_owned()));
        draft.columns.push(tag);
    });

    assert!(plan.as_ref().is_ok_and(|plan| plan.foreign_keys.is_enforced()));
    assert_eq!(
        sql(plan),
        [
            "ALTER TABLE \"notes\" RENAME TO \"memos\"",
            "ALTER TABLE \"memos\" RENAME COLUMN \"body\" TO \"content\"",
            "ALTER TABLE \"memos\" ADD COLUMN \"tag\" TEXT NOT NULL DEFAULT 'none'",
        ]
    );
}

#[test]
fn type_change_builds_rebuild_with_rowid_copy() {
    let notes = table(
        "notes",
        vec![column("title", "TEXT", false), column("body", "TEXT", false)],
        "CREATE TABLE notes (title TEXT, body TEXT)",
    );

    let plan = alter(&notes, |draft| retype(draft, "body", "BLOB"));

    assert_eq!(
        checks(&plan),
        [ForeignKeyCheck::same_table(TableRef::unqualified("notes"))]
    );
    assert_eq!(
        sql(plan),
        [
            "CREATE TABLE \"_tablepro_rebuild_notes\" (title TEXT, body BLOB)",
            "INSERT INTO \"_tablepro_rebuild_notes\" (rowid, \"title\", \"body\") SELECT rowid, \"title\", \"body\" \
             FROM \"notes\"",
            "DROP TABLE \"notes\"",
            "ALTER TABLE \"_tablepro_rebuild_notes\" RENAME TO \"notes\"",
        ]
    );
}

#[test]
fn plan_alter_table_rebuilds_for_nullability_type_and_default() {
    let notes = table(
        "notes",
        vec![column("title", "TEXT", false), not_null(column("body", "TEXT", false))],
        "CREATE TABLE notes (title TEXT DEFAULT 'x' NOT NULL, body TEXT NOT NULL ON CONFLICT REPLACE)",
    );
    let mut notes = notes;
    notes.columns[0].info.default = ColumnDefault::Literal(Value::Text("x".to_owned()));
    notes.columns[0].info.nullable = false;

    let plan = alter(&notes, |draft| {
        draft.columns[0].default = ColumnDefault::Expression(SqlExpression::from_catalog_text("upper('y')"));
        draft.columns[0].nullable = true;
        draft.columns[1].nullable = true;
        retype(draft, "body", "VARCHAR(20)");
    });

    assert_eq!(
        sql(plan)[0],
        "CREATE TABLE \"_tablepro_rebuild_notes\" (title TEXT DEFAULT (upper('y')), body VARCHAR(20))"
    );
}

#[test]
fn rebuild_preserves_dependents_and_checks_children() {
    let orders = orders();

    let plan = alter(&orders, |draft| retype(draft, "total", "NUMERIC"));

    assert_eq!(
        checks(&plan),
        [
            ForeignKeyCheck::same_table(TableRef::unqualified("orders")),
            ForeignKeyCheck::same_table(TableRef::unqualified("lines")),
        ]
    );
    assert_eq!(
        sql(plan),
        [
            "DROP TRIGGER \"customers_cleanup\"",
            "DROP VIEW \"big_orders\"",
            "CREATE TABLE \"_tablepro_rebuild_orders\" (\n  id INTEGER PRIMARY KEY,\n  customer INTEGER NOT NULL \
             REFERENCES customers (id),\n  total NUMERIC DEFAULT 0 CHECK (total >= 0),\n  note TEXT COLLATE \
             NOCASE\n)",
            "INSERT INTO \"_tablepro_rebuild_orders\" (\"id\", \"customer\", \"total\", \"note\") SELECT \"id\", \
             \"customer\", \"total\", \"note\" FROM \"orders\"",
            "DROP TABLE \"orders\"",
            "ALTER TABLE \"_tablepro_rebuild_orders\" RENAME TO \"orders\"",
            "CREATE INDEX orders_by_customer ON orders (customer)",
            "CREATE TRIGGER orders_stamp AFTER INSERT ON orders BEGIN UPDATE orders SET note = 'new' WHERE id = new.id; \
             END",
            "CREATE VIEW big_orders AS SELECT id, total FROM orders WHERE total > 100",
            "CREATE TRIGGER customers_cleanup AFTER DELETE ON customers BEGIN DELETE FROM orders WHERE customer = \
             old.id; END",
        ]
    );
}

#[test]
fn rebuild_checks_cover_table_and_inbound_children() {
    let mut orders = orders();
    orders.inbound_foreign_keys = vec![
        inbound("fk_lines_0", "lines", "order_id", "id"),
        inbound("fk_lines_1", "Lines", "first_order_id", "id"),
        inbound("fk_refunds_0", "refunds", "order_id", "id"),
        inbound("fk_orders_1", "orders", "parent_id", "id"),
    ];

    let plan = alter(&orders, |draft| {
        draft.table.name = "purchases".to_owned();
        retype(draft, "total", "NUMERIC");
    });

    assert_eq!(
        checks(&plan),
        [
            ForeignKeyCheck::new(
                Some(TableRef::unqualified("orders")),
                TableRef::unqualified("purchases")
            ),
            ForeignKeyCheck::same_table(TableRef::unqualified("lines")),
            ForeignKeyCheck::same_table(TableRef::unqualified("refunds")),
        ]
    );
}

#[test]
fn rebuild_keeps_check_collate_generated_verbatim() {
    let mut generated = column("c", "INT", false);
    generated.info.is_generated = true;
    generated.attributes.generated = Some(GeneratedColumn {
        expression: SqlExpression::from_catalog_text("a * 2"),
        storage: GeneratedStorage::Stored,
    });
    let table = table(
        "m",
        vec![
            column("a", "INT", false),
            not_null(column("b", "TEXT", false)),
            generated,
        ],
        "CREATE TABLE m (a INT CHECK (a > 0) COLLATE BINARY, b TEXT COLLATE NOCASE NOT NULL, c INT GENERATED ALWAYS \
         AS (a * 2) STORED, CHECK (b <> ''))",
    );
    let permissions = dialect().column_capabilities(&table, &table.columns[2]);

    let plan = alter(&table, |draft| {
        retype(draft, "a", "BIGINT");
        draft.columns[1].nullable = true;
        retype(draft, "c", "REAL");
    });

    assert!(permissions.alter_type.is_allowed() && permissions.alter_nullability.is_allowed());
    assert_eq!(
        permissions.alter_default,
        Permission::Refused(RefusalReason::GeneratedColumn)
    );
    assert_eq!(
        sql(plan)[..2],
        [
            "CREATE TABLE \"_tablepro_rebuild_m\" (a BIGINT CHECK (a > 0) COLLATE BINARY, b TEXT COLLATE NOCASE, c \
             REAL GENERATED ALWAYS AS (a * 2) STORED, CHECK (b <> ''))",
            "INSERT INTO \"_tablepro_rebuild_m\" (rowid, \"a\", \"b\") SELECT rowid, \"a\", \"b\" FROM \"m\"",
        ]
    );
}

#[test]
fn rebuild_orders_views_before_renames() {
    let orders = orders();

    let statements = sql(alter(&orders, |draft| {
        draft.table.name = "purchases".to_owned();
        draft.columns[3].name = "remark".to_owned();
        retype(draft, "total", "NUMERIC");
        draft.indexes.push(index("purchases_by_remark", "remark"));
    }));

    let position = |prefix: &str| {
        statements
            .iter()
            .position(|statement| statement.starts_with(prefix))
            .unwrap_or_else(|| panic!("no {prefix} in {statements:#?}"))
    };
    assert!(position("CREATE VIEW big_orders") < position("ALTER TABLE \"orders\" RENAME COLUMN"));
    assert_eq!(
        statements[position("ALTER TABLE \"orders\" RENAME COLUMN")..],
        [
            "ALTER TABLE \"orders\" RENAME COLUMN \"note\" TO \"remark\"",
            "ALTER TABLE \"orders\" RENAME TO \"purchases\"",
            "CREATE INDEX \"purchases_by_remark\" ON \"purchases\" (\"remark\")",
        ]
    );
}

#[test]
fn rebuild_renames_use_temporary_names_on_collision() {
    let people = table(
        "people",
        vec![
            rowid_alias("id"),
            column("email", "TEXT", false),
            column("name", "TEXT", false),
        ],
        "CREATE TABLE people (id INTEGER PRIMARY KEY, email TEXT, name TEXT)",
    );

    let added = sql(alter(&people, |draft| {
        draft.columns[1].name = "mail".to_owned();
        retype(draft, "mail", "BLOB");
        draft.columns.push(typed("email", "TEXT"));
    }));
    let swapped = sql(alter(&people, |draft| {
        draft.columns[1].name = "name".to_owned();
        draft.columns[2].name = "email".to_owned();
        retype(draft, "name", "BLOB");
    }));

    assert_eq!(
        added[0],
        "CREATE TABLE \"_tablepro_rebuild_people\" (id INTEGER PRIMARY KEY, email BLOB, name TEXT, \
         \"__tablepro_added_1\" TEXT)"
    );
    assert_eq!(
        added[4..],
        [
            "ALTER TABLE \"people\" RENAME COLUMN \"email\" TO \"mail\"",
            "ALTER TABLE \"people\" RENAME COLUMN \"__tablepro_added_1\" TO \"email\"",
        ]
    );
    assert_eq!(
        swapped[4..],
        [
            "ALTER TABLE \"people\" RENAME COLUMN \"email\" TO \"__tablepro_rename_1\"",
            "ALTER TABLE \"people\" RENAME COLUMN \"name\" TO \"email\"",
            "ALTER TABLE \"people\" RENAME COLUMN \"__tablepro_rename_1\" TO \"name\"",
        ]
    );
}

#[test]
fn dropping_a_foreign_key_removes_it_from_the_text() {
    let mut lines = table(
        "lines",
        vec![
            not_null(column("order_id", "INTEGER", false)),
            column("sku", "TEXT", false),
        ],
        "CREATE TABLE lines (order_id INTEGER CONSTRAINT to_order REFERENCES orders (id) ON DELETE CASCADE NOT NULL, \
         sku TEXT, FOREIGN KEY (sku) REFERENCES products (sku))",
    );
    // The catalogue numbers keys from the last one declared.
    lines.foreign_keys = vec![
        foreign_key("fk_lines_0", "sku", "products", "sku"),
        ForeignKeyInfo {
            on_delete: Some(ReferentialAction::Cascade),
            ..foreign_key("fk_lines_1", "order_id", "orders", "id")
        },
    ];

    let inline = sql(alter(&lines, |draft| {
        draft.foreign_keys.remove(1);
    }));
    let constraint = sql(alter(&lines, |draft| {
        draft.foreign_keys.remove(0);
    }));

    assert_eq!(
        inline[0],
        "CREATE TABLE \"_tablepro_rebuild_lines\" (order_id INTEGER NOT NULL, sku TEXT, FOREIGN KEY (sku) REFERENCES \
         products (sku))"
    );
    assert_eq!(
        constraint[0],
        "CREATE TABLE \"_tablepro_rebuild_lines\" (order_id INTEGER CONSTRAINT to_order REFERENCES orders (id) ON \
         DELETE CASCADE NOT NULL, sku TEXT)"
    );
}

#[test]
fn adding_a_foreign_key_appends_a_table_constraint() {
    let lines = table(
        "lines",
        vec![column("order_id", "INTEGER", false), column("sku", "TEXT", false)],
        "CREATE TABLE lines (\n  order_id INTEGER,\n  sku TEXT\n)",
    );

    let plan = alter(&lines, |draft| {
        draft.foreign_keys.push(ForeignKeyInfo {
            on_update: Some(ReferentialAction::Cascade),
            ..foreign_key("lines_order", "order_id", "orders", "id")
        });
    });

    assert_eq!(
        sql(plan)[0],
        "CREATE TABLE \"_tablepro_rebuild_lines\" (\n  order_id INTEGER,\n  sku TEXT,\n  CONSTRAINT \"lines_order\" \
         FOREIGN KEY (\"order_id\") REFERENCES \"orders\" (\"id\") ON UPDATE CASCADE\n)"
    );
}

#[test]
fn primary_key_change_writes_the_key_again() {
    let tags = table(
        "tags",
        vec![column("id", "INTEGER", false), not_null(column("name", "TEXT", false))],
        "CREATE TABLE tags (id INTEGER, name TEXT NOT NULL)",
    );

    let numbered = sql(alter(&tags, |draft| {
        draft.columns[0].primary_key = true;
        draft.columns[0].nullable = false;
        draft.columns[0].auto_increment = true;
    }));
    let composite = sql(alter(&tags, |draft| {
        for column in &mut draft.columns {
            column.primary_key = true;
            column.nullable = false;
        }
    }));
    let text_key = alter(&tags, |draft| {
        draft.columns[1].primary_key = true;
        draft.columns[1].auto_increment = true;
    });

    assert_eq!(
        numbered[..2],
        [
            "CREATE TABLE \"_tablepro_rebuild_tags\" (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, name TEXT NOT \
             NULL)",
            "INSERT INTO \"_tablepro_rebuild_tags\" (\"id\", \"name\") SELECT \"id\", \"name\" FROM \"tags\"",
        ]
    );
    assert_eq!(
        composite[0],
        "CREATE TABLE \"_tablepro_rebuild_tags\" (id INTEGER NOT NULL, name TEXT NOT NULL, PRIMARY KEY (\"id\", \
         \"name\"))"
    );
    assert_eq!(
        refusal(&text_key),
        Some(("name", DdlOperation::AlterAutoIncrement, &RefusalReason::NotAnInteger))
    );
}

#[test]
fn autoincrement_carries_the_sequence_through_the_rebuild() {
    let mut id = rowid_alias("id");
    id.info.nullable = true;
    let counters = table(
        "counters",
        vec![id, column("n", "INT", false)],
        "CREATE TABLE counters (id INTEGER PRIMARY KEY AUTOINCREMENT, n INT)",
    );

    let statements = sql(alter(&counters, |draft| retype(draft, "n", "TEXT")));

    assert_eq!(
        statements[2..4],
        [
            "DELETE FROM \"sqlite_sequence\" WHERE name = '_tablepro_rebuild_counters'",
            "INSERT INTO \"sqlite_sequence\" (name, seq) SELECT '_tablepro_rebuild_counters', seq FROM \
             \"sqlite_sequence\" WHERE name = 'counters' COLLATE NOCASE",
        ]
    );
}

#[test]
fn dropping_a_column_a_view_uses_is_refused_in_a_rebuild() {
    let orders = orders();

    let plan = alter(&orders, |draft| {
        draft.columns.retain(|column| column.name != "total");
        retype(draft, "note", "BLOB");
    });

    assert_eq!(
        refusal(&plan),
        Some((
            "total",
            DdlOperation::DropColumn,
            &RefusalReason::ColumnInUse(vec!["big_orders".to_owned()])
        ))
    );
}

#[test]
fn a_unique_column_drops_with_its_constraint() {
    let codes = table(
        "codes",
        vec![
            column("id", "INTEGER", false),
            column("code", "TEXT", false),
            column("label", "TEXT", false),
        ],
        "CREATE TABLE codes (id INTEGER, code TEXT UNIQUE, label TEXT, UNIQUE (label))",
    );

    let own = sql(alter(&codes, |draft| {
        draft.columns.retain(|column| column.name != "code")
    }));
    let alone = sql(alter(&codes, |draft| {
        draft.columns.retain(|column| column.name != "label")
    }));
    let plain = sql(alter(&codes, |draft| {
        draft.columns.retain(|column| column.name != "id")
    }));

    assert_eq!(
        own[0],
        "CREATE TABLE \"_tablepro_rebuild_codes\" (id INTEGER, label TEXT, UNIQUE (label))"
    );
    assert_eq!(
        alone[0],
        "CREATE TABLE \"_tablepro_rebuild_codes\" (id INTEGER, code TEXT UNIQUE)"
    );
    assert_eq!(plain, ["ALTER TABLE \"codes\" DROP COLUMN \"id\""]);
}

#[test]
fn a_required_column_without_a_default_rebuilds() {
    let notes = table(
        "notes",
        vec![column("title", "TEXT", false)],
        "CREATE TABLE notes (title TEXT)",
    );
    let add = |draft: &mut TableDraft| {
        let mut required = typed("nickname", "TEXT");
        required.nullable = false;
        draft.columns.push(required);
    };

    let rebuilt = sql(alter(&notes, add));
    let unread = alter(&users(), add);

    assert_eq!(
        rebuilt[0],
        "CREATE TABLE \"_tablepro_rebuild_notes\" (title TEXT, \"nickname\" TEXT NOT NULL)"
    );
    assert_eq!(
        refusal(&unread),
        Some((
            "nickname",
            DdlOperation::AddColumn,
            &RefusalReason::UnreadableDefinition
        ))
    );
}

#[test]
fn unreadable_source_refuses_rebuild_only_operations() {
    let virtual_table = table(
        "docs",
        vec![column("body", "TEXT", false)],
        "CREATE VIRTUAL TABLE docs USING fts5(body)",
    );
    let unreadable = Permission::Refused(RefusalReason::UnreadableDefinition);

    for table in [users(), virtual_table] {
        let permissions = dialect().column_capabilities(&table, &table.columns[table.columns.len() - 1]);
        assert_eq!(permissions.alter_type, unreadable, "{}", table.table.name);
        assert_eq!(permissions.alter_nullability, unreadable);
        assert_eq!(permissions.alter_default, unreadable);
        assert_eq!(permissions.alter_primary_key, unreadable);
        assert!(permissions.rename.is_allowed() && permissions.drop.is_allowed());
    }
    let plan = alter(&users(), |draft| retype(draft, "email", "BLOB"));
    assert_eq!(
        refusal(&plan),
        Some((
            "email",
            DdlOperation::AlterColumnType,
            &RefusalReason::UnreadableDefinition
        ))
    );
    let renamed = alter(&users(), |draft| draft.columns[1].name = "mail".to_owned());
    assert_eq!(
        sql(renamed),
        ["ALTER TABLE \"users\" RENAME COLUMN \"email\" TO \"mail\""]
    );
}

#[test]
fn a_dependent_carrying_a_second_statement_is_not_replayed() {
    let mut orders = orders();
    if let Some(view) = orders
        .source
        .as_mut()
        .and_then(|source| source.dependents.iter_mut().find(|object| object.name == "big_orders"))
    {
        view.sql = "CREATE VIEW big_orders AS SELECT id FROM orders; DELETE FROM orders".to_owned();
    }

    let plan = alter(&orders, |draft| retype(draft, "total", "NUMERIC"));

    assert_eq!(
        refusal(&plan),
        Some((
            "big_orders",
            DdlOperation::AlterTable,
            &RefusalReason::UnreadableDefinition
        ))
    );
}

#[test]
fn an_attached_schema_rebuilds_in_place() {
    let mut orders = orders();
    orders.table = TableRef::new(Some("aux".to_owned()), "orders");
    orders.inbound_foreign_keys.clear();

    let statements = sql(alter(&orders, |draft| retype(draft, "total", "NUMERIC")));

    assert_eq!(statements[0], "DROP TRIGGER \"aux\".\"customers_cleanup\"");
    assert_eq!(
        statements[2].split(" (").next(),
        Some("CREATE TABLE \"aux\".\"_tablepro_rebuild_orders\"")
    );
    assert_eq!(
        statements[4..7],
        [
            "DROP TABLE \"aux\".\"orders\"",
            "ALTER TABLE \"aux\".\"_tablepro_rebuild_orders\" RENAME TO \"orders\"",
            "CREATE INDEX \"aux\".orders_by_customer ON orders (customer)",
        ]
    );
    assert_eq!(
        statements[8],
        "CREATE VIEW \"aux\".big_orders AS SELECT id, total FROM orders WHERE total > 100"
    );
}

#[test]
fn a_swap_steps_aside_through_a_temporary_name() {
    let mut table = users();
    table.columns.push(column("name", "TEXT", false));

    let plan = alter(&table, |draft| {
        draft.columns[1].name = "Name".to_owned();
        draft.columns[2].name = "email".to_owned();
    });

    assert_eq!(
        sql(plan),
        [
            "ALTER TABLE \"users\" RENAME COLUMN \"email\" TO \"__tablepro_rename_1\"",
            "ALTER TABLE \"users\" RENAME COLUMN \"name\" TO \"email\"",
            "ALTER TABLE \"users\" RENAME COLUMN \"__tablepro_rename_1\" TO \"Name\"",
        ]
    );
}

#[test]
fn an_indexed_column_drop_drops_the_index_first() {
    let mut table = users();
    table.indexes = vec![index("by_email", "email")];

    let plan = alter(&table, |draft| {
        draft.indexes.clear();
        draft.columns.retain(|column| column.name != "email");
    });

    assert_eq!(
        sql(plan),
        ["DROP INDEX \"by_email\"", "ALTER TABLE \"users\" DROP COLUMN \"email\""]
    );
}

#[test]
fn primary_key_referenced_by_foreign_key_is_refused() {
    let mut table = users();
    // SQLite reports a reference to the primary key with a NULL
    // target, which the catalogue resolves to the key's columns.
    table.inbound_foreign_keys = vec![inbound("fk_orders_0", "orders", "user_id", "id")];

    let permissions = dialect().column_capabilities(&table, &table.columns[1]);
    let id = dialect().column_capabilities(&table, &table.columns[0]);

    assert_eq!(
        permissions.alter_primary_key,
        Permission::Refused(RefusalReason::ReferencedByForeignKeys(vec!["fk_orders_0".to_owned()]))
    );
    assert_eq!(
        id.drop,
        Permission::Refused(RefusalReason::ReferencedByForeignKeys(vec!["fk_orders_0".to_owned()]))
    );
}

#[test]
fn drop_of_referenced_column_is_refused() {
    let mut table = users();
    table.inbound_foreign_keys = vec![inbound("fk_orders_0", "orders", "user_email", "email")];

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
fn the_script_replays_the_stored_table_and_its_own_dependents() {
    let mut table = users();
    table.source = Some(TableSource {
        create_statement: "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT)".to_owned(),
        dependents: vec![
            object(
                SchemaObjectKind::Index,
                "by_email",
                "Users",
                "CREATE INDEX by_email ON users (email)",
            ),
            object(
                SchemaObjectKind::Index,
                "by_total",
                "orders",
                "CREATE INDEX by_total ON orders (total)",
            ),
            object(
                SchemaObjectKind::Trigger,
                "stamp",
                "users",
                "CREATE TRIGGER stamp AFTER INSERT ON users BEGIN SELECT 1; END",
            ),
            object(SchemaObjectKind::View, "v", "v", "CREATE VIEW v AS SELECT * FROM users"),
        ],
    });

    assert_eq!(
        sql(dialect().create_table_script(&table)),
        [
            "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT)",
            "CREATE INDEX by_email ON users (email)",
            "CREATE TRIGGER stamp AFTER INSERT ON users BEGIN SELECT 1; END",
        ]
    );
}

#[test]
fn foreign_keys_rebuild_and_comments_stay_refused() {
    let dialect = dialect();
    let capabilities = DdlDialect::capabilities(&dialect);

    assert!(capabilities.add_foreign_key && capabilities.drop_foreign_key);
    assert!(capabilities.alter_column_type && capabilities.alter_primary_key);
    assert!(!capabilities.column_comments);
    assert!(capabilities.partial_indexes && capabilities.expression_index_keys);
}

#[test]
fn every_type_suggestion_parses() {
    let dialect = dialect();

    for suggestion in dialect.type_suggestions() {
        assert!(dialect.parse_type(suggestion).is_ok(), "{suggestion}");
    }
    assert!(dialect.parse_type(dialect.default_column_type()).is_ok());
}
