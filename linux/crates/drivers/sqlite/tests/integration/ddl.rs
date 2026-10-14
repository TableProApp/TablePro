//! Structure changes the SQLite dialect plans, run against a database
//! file: native ALTER TABLE where SQLite has one, and the table rebuild
//! where it does not.

use tablepro_core::column::ColumnDefault;
use tablepro_core::ddl::{
    BuildDdlError, DdlOperation, DraftColumn, DraftType, ReferentialAction, RefusalReason, SchemaObjectKind,
    TableDefinition, TableDraft, diff_table,
};
use tablepro_core::meta::{IndexKey, TableRef};
use tablepro_core::statement::GuardedStatement;
use tablepro_core::{
    Connection, DriverError, ForeignKeyInfo, ForeignKeyMode, ServerCode, Value, WriteBatch, WriteKind, WriteReport,
};

use crate::support::{TestFile, apply, call, query, statement};

fn kept() -> TableRef {
    TableRef::unqualified("kept")
}

fn named(name: &str) -> TableRef {
    TableRef::unqualified(name)
}

async fn read(connection: &dyn Connection, table: &TableRef) -> TableDefinition {
    connection.fetch_table_definition(table, call()).await.unwrap()
}

fn plan(
    connection: &dyn Connection,
    before: &TableDefinition,
    edit: impl FnOnce(&mut TableDraft),
) -> Result<tablepro_core::ddl::DdlPlan, BuildDdlError> {
    let mut draft = TableDraft::from_definition(before);
    edit(&mut draft);
    let dialect = connection.dialect();
    dialect
        .ddl()
        .unwrap()
        .plan_alter_table(before, &diff_table(before, &draft))
}

/// Plan the edit against the table as read and run it as the structure
/// tab saves.
async fn save(
    connection: &dyn Connection,
    table: &TableRef,
    edit: impl FnOnce(&mut TableDraft),
) -> Result<WriteReport, DriverError> {
    let before = read(connection, table).await;
    let plan = plan(connection, &before, edit).unwrap();
    connection
        .write_batch(&plan.into_write_batch(table.clone()), call())
        .await
}

/// Edit each column of `kept`, save, and read the table again.
async fn change(connection: &dyn Connection, edit: impl Fn(&mut DraftColumn)) -> TableDefinition {
    save(connection, &kept(), |draft| draft.columns.iter_mut().for_each(edit))
        .await
        .unwrap();
    read(connection, &kept()).await
}

fn column<'d>(draft: &'d mut TableDraft, name: &str) -> &'d mut DraftColumn {
    draft
        .columns
        .iter_mut()
        .find(|column| column.name == name)
        .unwrap_or_else(|| panic!("no column {name}"))
}

fn retype(draft: &mut TableDraft, name: &str, declaration: &str) {
    column(draft, name).column_type = DraftType::Typed(declaration.to_owned());
}

/// The stored statement with its quotes taken out: SQLite writes a
/// renamed name the way the rename spelled it.
fn dependent(definition: &TableDefinition, kind: SchemaObjectKind) -> String {
    definition
        .source
        .as_ref()
        .and_then(|source| source.dependents.iter().find(|object| object.kind == kind))
        .map(|object| object.sql.replace('"', ""))
        .unwrap_or_default()
}

fn dependent_names(definition: &TableDefinition) -> Vec<String> {
    definition
        .source
        .as_ref()
        .map(|source| source.dependents.iter().map(|object| object.name.clone()).collect())
        .unwrap_or_default()
}

fn create_statement(definition: &TableDefinition) -> String {
    definition
        .source
        .as_ref()
        .map(|source| source.create_statement.clone())
        .unwrap_or_default()
}

fn names(definition: &TableDefinition) -> Vec<String> {
    definition
        .columns
        .iter()
        .map(|column| column.name().to_owned())
        .collect()
}

fn text(value: &str) -> Value {
    Value::Text(value.to_owned())
}

/// Rows written with foreign keys off, which SQLite never checks.
async fn unchecked(connection: &dyn Connection, statements: &[&str]) {
    let batch = WriteBatch::new(
        WriteKind::SchemaChanges,
        named("unchecked"),
        statements
            .iter()
            .map(|sql| GuardedStatement::unguarded(statement(sql)))
            .collect(),
        ForeignKeyMode::SuspendedThenVerified { checks: Vec::new() },
    );
    connection.write_batch(&batch, call()).await.unwrap();
}

async fn rebuild_tables_left(connection: &dyn Connection) -> Value {
    query(
        connection,
        "SELECT count(*) FROM sqlite_schema WHERE name LIKE '!_tablepro!_%' ESCAPE '!'",
    )
    .await
    .rows[0][0]
        .clone()
}

/// SQLite rewrites the indexes and triggers that name a column as it
/// renames it, and a swap goes through a temporary name.
#[tokio::test]
async fn rename_column_updates_index_and_trigger() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE kept (id INTEGER PRIMARY KEY, email TEXT, name TEXT)",
            "CREATE TABLE audit (note TEXT)",
            "CREATE INDEX kept_by_email ON kept (email)",
            "CREATE TRIGGER kept_audit AFTER INSERT ON kept BEGIN INSERT INTO audit VALUES (new.email); END",
            "INSERT INTO kept VALUES (1, 'a@x', 'Ann')",
        ],
    )
    .await
    .unwrap();

    let renamed = change(connection.as_ref(), |column| {
        if column.name == "email" {
            column.name = "mail".to_owned();
        }
    })
    .await;
    let swapped = change(connection.as_ref(), |column| {
        column.name = match column.name.as_str() {
            "mail" => "name",
            "name" => "mail",
            other => other,
        }
        .to_owned();
    })
    .await;
    apply(
        connection.as_ref(),
        &["INSERT INTO kept (id, name, mail) VALUES (2, 'b@x', 'Bo')"],
    )
    .await
    .unwrap();

    assert_eq!(names(&renamed), ["id", "mail", "name"]);
    assert!(dependent(&renamed, SchemaObjectKind::Index).contains("(mail)"));
    assert!(dependent(&renamed, SchemaObjectKind::Trigger).contains("new.mail"));
    assert_eq!(names(&swapped), ["id", "name", "mail"]);
    assert!(dependent(&swapped, SchemaObjectKind::Index).contains("(name)"));
    assert!(dependent(&swapped, SchemaObjectKind::Trigger).contains("new.name"));
    let audit = query(connection.as_ref(), "SELECT note FROM audit ORDER BY rowid").await;
    assert_eq!(audit.rows, [vec![text("a@x")], vec![text("b@x")]]);
    let kept = query(connection.as_ref(), "SELECT name, mail FROM kept WHERE id = 1").await;
    assert_eq!(kept.rows, [vec![text("a@x"), text("Ann")]]);
    connection.close().await.unwrap();
}

#[tokio::test]
async fn create_table_with_foreign_key_succeeds() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE parents (id INTEGER PRIMARY KEY)",
            "INSERT INTO parents VALUES (1)",
        ],
    )
    .await
    .unwrap();
    let mut draft = TableDraft::new(named("children"));
    let mut id = DraftColumn::new("id", DraftType::Typed("INTEGER".to_owned()));
    id.primary_key = true;
    id.nullable = false;
    let parent = DraftColumn::new("parent_id", DraftType::Typed("INTEGER".to_owned()));
    draft.columns = vec![id, parent];
    draft.foreign_keys = vec![ForeignKeyInfo {
        name: "children_parent".to_owned(),
        columns: vec!["parent_id".to_owned()],
        ref_schema: None,
        ref_table: "parents".to_owned(),
        ref_columns: vec!["id".to_owned()],
        on_delete: Some(ReferentialAction::Cascade),
        on_update: None,
    }];
    let plan = connection.dialect().ddl().unwrap().plan_create_table(&draft).unwrap();

    connection
        .write_batch(&plan.into_write_batch(named("children")), call())
        .await
        .unwrap();

    let children = read(connection.as_ref(), &named("children")).await;
    assert_eq!(children.foreign_keys.len(), 1);
    let key = &children.foreign_keys[0];
    assert_eq!(
        (key.columns.as_slice(), key.ref_table.as_str(), key.on_delete),
        (
            &["parent_id".to_owned()][..],
            "parents",
            Some(ReferentialAction::Cascade)
        )
    );
    apply(connection.as_ref(), &["INSERT INTO children VALUES (1, 1)"])
        .await
        .unwrap();
    let orphan = apply(connection.as_ref(), &["INSERT INTO children VALUES (2, 99)"]).await;
    assert!(orphan.is_err(), "{orphan:?}");
    apply(connection.as_ref(), &["DELETE FROM parents WHERE id = 1"])
        .await
        .unwrap();
    let left = query(connection.as_ref(), "SELECT count(*) FROM children").await;
    assert_eq!(left.rows[0][0], Value::Int(0));
    connection.close().await.unwrap();
}

/// A rebuild keeps every row under its rowid, the indexes and the
/// constraints written into the table, its own trigger, a view on it, a
/// trigger elsewhere that writes to it, and the keys that point at it.
#[tokio::test]
async fn rebuild_preserves_data_rowids_and_dependents() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT)",
            "CREATE TABLE orders (\n  code TEXT NOT NULL UNIQUE, -- the order's code\n  customer INTEGER REFERENCES \
             customers (id),\n  total REAL DEFAULT 0 CHECK (total >= 0),\n  note TEXT COLLATE NOCASE\n)",
            "CREATE TABLE lines (order_code TEXT REFERENCES orders (code), qty INTEGER)",
            "CREATE TABLE audit (note TEXT)",
            "CREATE INDEX orders_by_customer ON orders (customer)",
            "CREATE TRIGGER orders_audit AFTER INSERT ON orders BEGIN INSERT INTO audit VALUES ('order ' || \
             new.code); END",
            "CREATE VIEW big_orders AS SELECT code, total FROM orders WHERE total > 10",
            "CREATE TRIGGER customers_cleanup AFTER DELETE ON customers BEGIN DELETE FROM orders WHERE customer = \
             old.id; END",
            "INSERT INTO customers VALUES (1, 'Ann'), (2, 'Bo')",
            "INSERT INTO orders (rowid, code, customer, total, note) VALUES (5, 'a', 1, 20, 'X'), (9, 'b', 2, 5, \
             'y'), (12, 'c', 1, 50, NULL)",
            "INSERT INTO lines VALUES ('a', 1), ('c', 2)",
        ],
    )
    .await
    .unwrap();
    let rows_sql = "SELECT rowid, code, customer, total, note FROM orders ORDER BY rowid";
    let before_rows = query(connection.as_ref(), rows_sql).await.rows;
    let before = read(connection.as_ref(), &named("orders")).await;

    save(connection.as_ref(), &named("orders"), |draft| {
        retype(draft, "total", "DOUBLE PRECISION");
        column(draft, "note").default = ColumnDefault::Literal(text("none"));
    })
    .await
    .unwrap();

    let after = read(connection.as_ref(), &named("orders")).await;
    assert_eq!(query(connection.as_ref(), rows_sql).await.rows, before_rows);
    assert_eq!(dependent_names(&after), dependent_names(&before));
    assert_eq!(after.indexes, before.indexes);
    assert_eq!(after.foreign_keys, before.foreign_keys);
    assert_eq!(after.inbound_foreign_keys, before.inbound_foreign_keys);
    let create = create_statement(&after);
    for kept in [
        "-- the order's code",
        "CHECK (total >= 0)",
        "COLLATE NOCASE",
        "total DOUBLE PRECISION",
        "DEFAULT 'none'",
    ] {
        assert!(create.contains(kept), "{kept} is not in {create}");
    }
    assert_eq!(rebuild_tables_left(connection.as_ref()).await, Value::Int(0));

    let view = query(connection.as_ref(), "SELECT code FROM big_orders ORDER BY code").await;
    assert_eq!(view.rows, [vec![text("a")], vec![text("c")]]);
    apply(
        connection.as_ref(),
        &["INSERT INTO orders (code, customer) VALUES ('d', 1)"],
    )
    .await
    .unwrap();
    let audit = query(connection.as_ref(), "SELECT note FROM audit ORDER BY rowid").await;
    assert_eq!(audit.rows.last(), Some(&vec![text("order d")]));
    assert_eq!(audit.rows.len(), 4, "the copy fired no trigger");
    apply(connection.as_ref(), &["DELETE FROM customers WHERE id = 2"])
        .await
        .unwrap();
    let codes = query(connection.as_ref(), "SELECT code FROM orders ORDER BY code").await;
    assert_eq!(codes.rows, [vec![text("a")], vec![text("c")], vec![text("d")]]);
    let dangling = apply(connection.as_ref(), &["INSERT INTO lines VALUES ('zzz', 1)"]).await;
    assert!(dangling.is_err(), "foreign keys are back on: {dangling:?}");
    connection.close().await.unwrap();
}

/// Violations written while foreign keys were off, in the rebuilt
/// table's children and in a table the save does not touch, are not
/// the save's.
#[tokio::test]
async fn rebuild_succeeds_with_preexisting_unrelated_violation() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE parents (id INTEGER PRIMARY KEY, label TEXT)",
            "CREATE TABLE children (id INTEGER PRIMARY KEY, parent INTEGER REFERENCES parents (id))",
            "CREATE TABLE others (id INTEGER PRIMARY KEY, parent INTEGER REFERENCES parents (id))",
            "INSERT INTO parents VALUES (1, 'one')",
        ],
    )
    .await
    .unwrap();
    unchecked(
        connection.as_ref(),
        &[
            "INSERT INTO children VALUES (1, 1), (2, 99)",
            "INSERT INTO others VALUES (1, 98)",
        ],
    )
    .await;

    let parents = save(connection.as_ref(), &named("parents"), |draft| {
        retype(draft, "label", "BLOB");
    })
    .await;
    let children = save(connection.as_ref(), &named("children"), |draft| {
        column(draft, "parent").default = ColumnDefault::Literal(Value::Int(1));
    })
    .await;

    assert!(parents.is_ok(), "{parents:?}");
    assert!(children.is_ok(), "{children:?}");
    let orphans = query(connection.as_ref(), "SELECT count(*) FROM pragma_foreign_key_check").await;
    assert_eq!(orphans.rows[0][0], Value::Int(2));
    connection.close().await.unwrap();
}

#[tokio::test]
async fn not_null_change_with_existing_nulls_rolls_back_schema_unchanged() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE kept (id INTEGER PRIMARY KEY, nickname TEXT)",
            "CREATE INDEX kept_by_nickname ON kept (nickname)",
            "INSERT INTO kept VALUES (1, 'a'), (2, NULL)",
        ],
    )
    .await
    .unwrap();
    let before = read(connection.as_ref(), &kept()).await;

    let outcome = save(connection.as_ref(), &kept(), |draft| {
        column(draft, "nickname").nullable = false;
    })
    .await;

    let Err(DriverError::RolledBack { source, .. }) = &outcome else {
        panic!("{outcome:?}");
    };
    assert!(source.to_string().contains("NOT NULL"), "{source}");
    let after = read(connection.as_ref(), &kept()).await;
    assert_eq!(after, before);
    let rows = query(connection.as_ref(), "SELECT id, nickname FROM kept ORDER BY id").await;
    assert_eq!(
        rows.rows,
        [vec![Value::Int(1), text("a")], vec![Value::Int(2), Value::Null]]
    );
    assert_eq!(rebuild_tables_left(connection.as_ref()).await, Value::Int(0));
    connection.close().await.unwrap();
}

#[tokio::test]
async fn adding_violating_foreign_key_rolls_back_with_diagnostics() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE parents (id INTEGER PRIMARY KEY)",
            "CREATE TABLE children (id INTEGER PRIMARY KEY, parent INTEGER)",
            "INSERT INTO parents VALUES (1)",
            "INSERT INTO children VALUES (1, 1), (2, 7)",
        ],
    )
    .await
    .unwrap();
    let before = read(connection.as_ref(), &named("children")).await;

    let outcome = save(connection.as_ref(), &named("children"), |draft| {
        draft.foreign_keys.push(ForeignKeyInfo {
            name: "children_parent".to_owned(),
            columns: vec!["parent".to_owned()],
            ref_schema: None,
            ref_table: "parents".to_owned(),
            ref_columns: vec!["id".to_owned()],
            on_delete: None,
            on_update: None,
        });
    })
    .await;

    let Err(DriverError::RolledBack { source, .. }) = &outcome else {
        panic!("{outcome:?}");
    };
    let DriverError::Server(diagnostics) = source.as_ref() else {
        panic!("{source:?}");
    };
    assert_eq!(
        diagnostics.code,
        Some(ServerCode::Sqlite {
            primary: 19,
            extended: 787
        })
    );
    assert!(
        diagnostics.message.contains("1 rows of children") && diagnostics.message.contains("parents"),
        "{}",
        diagnostics.message
    );
    assert_eq!(read(connection.as_ref(), &named("children")).await, before);
    connection.close().await.unwrap();
}

/// Two columns trade names while one of them changes type, so the
/// renames after the rebuild step aside through a temporary name.
#[tokio::test]
async fn swap_rename_with_type_change_applies() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE kept (id INTEGER PRIMARY KEY, a TEXT, b TEXT)",
            "CREATE TABLE audit (note TEXT)",
            "CREATE INDEX kept_by_a ON kept (a)",
            "CREATE TRIGGER kept_audit AFTER INSERT ON kept BEGIN INSERT INTO audit VALUES (new.b); END",
            "INSERT INTO kept VALUES (1, 'first a', 'first b')",
        ],
    )
    .await
    .unwrap();

    save(connection.as_ref(), &kept(), |draft| {
        column(draft, "a").name = "b".to_owned();
        draft.columns[2].name = "a".to_owned();
        draft.columns[1].column_type = DraftType::Typed("BLOB".to_owned());
    })
    .await
    .unwrap();

    let after = read(connection.as_ref(), &kept()).await;
    assert_eq!(names(&after), ["id", "b", "a"]);
    let declared: Vec<String> = after
        .columns
        .iter()
        .map(|column| column.info.column_type.name.clone())
        .collect();
    assert_eq!(declared, ["INTEGER", "BLOB", "TEXT"]);
    let rows = query(connection.as_ref(), "SELECT b, a FROM kept").await;
    assert_eq!(rows.rows, [vec![text("first a"), text("first b")]]);
    assert!(dependent(&after, SchemaObjectKind::Index).contains("(b)"));
    assert!(dependent(&after, SchemaObjectKind::Trigger).contains("new.a"));
    assert_eq!(
        after
            .indexes
            .iter()
            .find(|index| index.name == "kept_by_a")
            .map(|index| index.keys.clone()),
        Some(vec![IndexKey::Column {
            name: "b".to_owned(),
            descending: false
        }])
    );
    connection.close().await.unwrap();
}

#[tokio::test]
async fn autoincrement_high_water_mark_survives_rebuild() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE kept (id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT)",
            "INSERT INTO kept (v) VALUES ('a'), ('b'), ('c')",
            "DELETE FROM kept WHERE id = 3",
        ],
    )
    .await
    .unwrap();

    save(connection.as_ref(), &kept(), |draft| retype(draft, "v", "BLOB"))
        .await
        .unwrap();
    apply(connection.as_ref(), &["INSERT INTO kept (v) VALUES ('d')"])
        .await
        .unwrap();

    let ids = query(connection.as_ref(), "SELECT id FROM kept ORDER BY id").await;
    assert_eq!(
        ids.rows,
        [vec![Value::Int(1)], vec![Value::Int(2)], vec![Value::Int(4)]]
    );
    let sequence = query(
        connection.as_ref(),
        "SELECT name, seq FROM sqlite_sequence ORDER BY name",
    )
    .await;
    assert_eq!(sequence.rows, [vec![text("kept"), Value::Int(4)]]);
    assert!(create_statement(&read(connection.as_ref(), &kept()).await).contains("AUTOINCREMENT"));
    connection.close().await.unwrap();
}

#[tokio::test]
async fn primary_key_change_via_rebuild_applies() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE kept (code TEXT, n INTEGER)",
            "INSERT INTO kept VALUES ('x', 1), ('y', 2)",
        ],
    )
    .await
    .unwrap();

    save(connection.as_ref(), &kept(), |draft| {
        let code = column(draft, "code");
        code.primary_key = true;
        code.nullable = false;
    })
    .await
    .unwrap();

    let after = read(connection.as_ref(), &kept()).await;
    assert_eq!(after.primary_key.map(|key| key.columns), Some(vec!["code".to_owned()]));
    let rows = query(connection.as_ref(), "SELECT rowid, code, n FROM kept ORDER BY rowid").await;
    assert_eq!(
        rows.rows,
        [
            vec![Value::Int(1), text("x"), Value::Int(1)],
            vec![Value::Int(2), text("y"), Value::Int(2)]
        ]
    );
    let duplicate = apply(connection.as_ref(), &["INSERT INTO kept VALUES ('x', 3)"]).await;
    assert!(duplicate.is_err(), "{duplicate:?}");
    connection.close().await.unwrap();
}

#[tokio::test]
async fn without_rowid_table_rebuild_applies() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE kept (k TEXT PRIMARY KEY, v INTEGER) WITHOUT ROWID",
            "INSERT INTO kept VALUES ('a', 1), ('b', 2)",
        ],
    )
    .await
    .unwrap();

    save(connection.as_ref(), &kept(), |draft| {
        retype(draft, "v", "TEXT");
        column(draft, "v").nullable = false;
    })
    .await
    .unwrap();

    let after = read(connection.as_ref(), &kept()).await;
    assert!(
        create_statement(&after).ends_with("WITHOUT ROWID"),
        "{}",
        create_statement(&after)
    );
    assert!(!after.columns[1].info.nullable);
    let rows = query(connection.as_ref(), "SELECT k, v FROM kept ORDER BY k").await;
    assert_eq!(rows.rows, [vec![text("a"), text("1")], vec![text("b"), text("2")]]);
    connection.close().await.unwrap();
}

/// The catalogue numbers a table's foreign keys from the last one
/// declared, and the rebuild removes the one the user picked.
#[tokio::test]
async fn dropping_one_of_several_foreign_keys_keeps_the_others() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE parents (id INTEGER PRIMARY KEY)",
            "CREATE TABLE products (sku TEXT PRIMARY KEY)",
            "CREATE TABLE lines (parent INTEGER CONSTRAINT to_parent REFERENCES parents (id), sku TEXT, qty \
             INTEGER, FOREIGN KEY (sku) REFERENCES products (sku) ON DELETE CASCADE)",
        ],
    )
    .await
    .unwrap();

    save(connection.as_ref(), &named("lines"), |draft| {
        draft.foreign_keys.retain(|key| key.ref_table != "parents");
    })
    .await
    .unwrap();

    let after = read(connection.as_ref(), &named("lines")).await;
    let parents: Vec<&str> = after.foreign_keys.iter().map(|key| key.ref_table.as_str()).collect();
    assert_eq!(parents, ["products"]);
    assert!(!create_statement(&after).contains("to_parent"));
    apply(connection.as_ref(), &["INSERT INTO lines VALUES (42, NULL, 1)"])
        .await
        .unwrap();
    connection.close().await.unwrap();
}

/// A rename of the table in the same save as a rebuild runs last, and
/// SQLite carries it into the keys of the tables that point at it.
#[tokio::test]
async fn rename_with_rebuild_moves_the_children_keys() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE kept (id INTEGER PRIMARY KEY, label TEXT)",
            "CREATE TABLE children (kept_id INTEGER REFERENCES kept (id))",
            "INSERT INTO kept VALUES (1, 'one')",
            "INSERT INTO children VALUES (1)",
        ],
    )
    .await
    .unwrap();

    save(connection.as_ref(), &kept(), |draft| {
        draft.table.name = "renamed".to_owned();
        retype(draft, "label", "BLOB");
    })
    .await
    .unwrap();

    let children = read(connection.as_ref(), &named("children")).await;
    assert_eq!(children.foreign_keys[0].ref_table, "renamed");
    let rows = query(connection.as_ref(), "SELECT id, label FROM renamed").await;
    assert_eq!(rows.rows, [vec![Value::Int(1), text("one")]]);
    connection.close().await.unwrap();
}

#[tokio::test]
async fn dropping_a_column_a_view_needs_is_refused_before_anything_runs() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE kept (id INTEGER PRIMARY KEY, code TEXT UNIQUE, note TEXT)",
            "CREATE VIEW codes AS SELECT code FROM kept",
        ],
    )
    .await
    .unwrap();
    let before = read(connection.as_ref(), &kept()).await;
    let mut draft = TableDraft::from_definition(&before);
    draft.columns.retain(|column| column.name != "code");

    let plan = connection
        .dialect()
        .ddl()
        .unwrap()
        .plan_alter_table(&before, &diff_table(&before, &draft));

    assert_eq!(
        plan,
        Err(BuildDdlError::Refused {
            column: "code".to_owned(),
            operation: DdlOperation::DropColumn,
            reason: RefusalReason::ColumnInUse(vec!["codes".to_owned()]),
        })
    );
    connection.close().await.unwrap();
}

/// The tab plans against the table as it read it. Whatever changed the
/// table, its dependents or the keys pointing at it since then, the
/// rebuild refuses before it runs a statement, rather than writing the
/// table again without it.
#[tokio::test]
async fn a_rebuild_planned_before_another_change_is_refused() {
    let changes: [&[&str]; 4] = [
        &[
            "ALTER TABLE kept ADD COLUMN important TEXT",
            "UPDATE kept SET important = 'keep me'",
            "CREATE INDEX kept_by_important ON kept (important)",
        ],
        &["CREATE INDEX kept_by_v ON kept (v)"],
        &[
            "DROP VIEW kept_values",
            "CREATE VIEW kept_values AS SELECT id, v FROM kept",
        ],
        &["CREATE TABLE children (kept_id INTEGER REFERENCES kept (id))"],
    ];
    for change in changes {
        let file = TestFile::new().await;
        let connection = file.open().await;
        apply(
            connection.as_ref(),
            &[
                "CREATE TABLE kept (id INTEGER PRIMARY KEY, v TEXT)",
                "CREATE VIEW kept_values AS SELECT v FROM kept",
                "INSERT INTO kept VALUES (1, 'a')",
            ],
        )
        .await
        .unwrap();
        let before = read(connection.as_ref(), &kept()).await;
        let stale = plan(connection.as_ref(), &before, |draft| retype(draft, "v", "BLOB")).unwrap();
        apply(connection.as_ref(), change).await.unwrap();
        let changed = read(connection.as_ref(), &kept()).await;
        let rows_sql = "SELECT * FROM kept ORDER BY id";
        let rows = query(connection.as_ref(), rows_sql).await.rows;

        let outcome = connection.write_batch(&stale.into_write_batch(kept()), call()).await;

        assert!(
            matches!(
                outcome,
                Err(DriverError::RowGuardFailed {
                    statement_index: 0,
                    expected: 0,
                    ..
                })
            ),
            "{change:?}: {outcome:?}"
        );
        assert_eq!(read(connection.as_ref(), &kept()).await, changed, "{change:?}");
        assert_eq!(query(connection.as_ref(), rows_sql).await.rows, rows, "{change:?}");
        let fresh = save(connection.as_ref(), &kept(), |draft| retype(draft, "v", "BLOB")).await;
        assert!(
            fresh.is_ok(),
            "{change:?}: a plan read after the change was refused: {fresh:?}"
        );
        connection.close().await.unwrap();
    }
}
