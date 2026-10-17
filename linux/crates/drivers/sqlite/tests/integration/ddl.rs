//! Structure changes the SQLite dialect plans, run against a database
//! file: native ALTER TABLE where SQLite has one, and the table rebuild
//! where it does not.

use tablepro_core::column::ColumnDefault;
use tablepro_core::ddl::{
    BuildDdlError, DdlOperation, DraftColumn, DraftType, DropTableOptions, ReferentialAction, RefusalReason,
    SchemaObjectKind, TableDefinition, TableDraft, diff_table,
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

/// A row that already broke one key still makes the save fail when the
/// save swaps that key for another one the row breaks.
#[tokio::test]
async fn replacing_a_violated_key_with_another_the_row_breaks_rolls_back() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE parents (id INTEGER PRIMARY KEY)",
            "CREATE TABLE children (id INTEGER PRIMARY KEY, a INTEGER, b INTEGER, FOREIGN KEY (a) REFERENCES \
             parents (id))",
            "INSERT INTO parents VALUES (1)",
        ],
    )
    .await
    .unwrap();
    unchecked(connection.as_ref(), &["INSERT INTO children VALUES (1, 99, 98)"]).await;
    let before = read(connection.as_ref(), &named("children")).await;

    let outcome = save(connection.as_ref(), &named("children"), |draft| {
        draft.foreign_keys = vec![ForeignKeyInfo {
            name: "children_b".to_owned(),
            columns: vec!["b".to_owned()],
            ref_schema: None,
            ref_table: "parents".to_owned(),
            ref_columns: vec!["id".to_owned()],
            on_delete: None,
            on_update: None,
        }];
    })
    .await;

    let Err(DriverError::RolledBack { source, .. }) = &outcome else {
        panic!("a key the save added was let through broken: {outcome:?}");
    };
    assert!(source.to_string().contains("1 rows of children"), "{source}");
    assert_eq!(read(connection.as_ref(), &named("children")).await, before);
    connection.close().await.unwrap();
}

/// A key column renamed in a rebuild is still the key it was, so the
/// rows that broke it before are the file's, on either side of the key.
#[tokio::test]
async fn a_renamed_key_column_keeps_the_violations_it_had() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE parents (id INTEGER PRIMARY KEY, label TEXT)",
            "CREATE TABLE children (id INTEGER PRIMARY KEY, parent INTEGER REFERENCES parents (id), note TEXT)",
            "INSERT INTO parents VALUES (1, 'one')",
        ],
    )
    .await
    .unwrap();
    unchecked(connection.as_ref(), &["INSERT INTO children VALUES (1, 99, 'x')"]).await;

    let children = save(connection.as_ref(), &named("children"), |draft| {
        column(draft, "parent").name = "parent_id".to_owned();
        retype(draft, "note", "BLOB");
    })
    .await;
    let parents = save(connection.as_ref(), &named("parents"), |draft| {
        column(draft, "id").name = "key".to_owned();
        retype(draft, "label", "BLOB");
    })
    .await;

    assert!(children.is_ok(), "{children:?}");
    assert!(parents.is_ok(), "{parents:?}");
    let keys = read(connection.as_ref(), &named("children")).await.foreign_keys;
    assert_eq!(keys[0].columns, ["parent_id"]);
    assert_eq!(keys[0].ref_columns, ["key"]);
    let orphans = query(connection.as_ref(), "SELECT count(*) FROM pragma_foreign_key_check").await;
    assert_eq!(orphans.rows[0][0], Value::Int(1));
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

fn drop_code(draft: &mut TableDraft) {
    draft.columns.retain(|column| column.name != "code");
}

const CODES_SCHEMA: [&str; 3] = [
    "CREATE TABLE kept (id INTEGER PRIMARY KEY, code TEXT UNIQUE, note TEXT)",
    "CREATE TABLE audit (note TEXT)",
    "INSERT INTO kept VALUES (1, 'x', 'a')",
];

/// SQLite resolves the views and triggers the rebuild makes again, and
/// its error names the one that reads the dropped column.
#[tokio::test]
async fn a_dropped_column_something_reads_rolls_the_rebuild_back() {
    let readers = [
        (
            "CREATE VIEW codes AS SELECT code FROM kept",
            "error in view codes: no such column: code",
        ),
        (
            "CREATE TRIGGER kept_audit AFTER INSERT ON kept BEGIN INSERT INTO audit VALUES (new.code); END",
            "error in trigger kept_audit: no such column: new.code",
        ),
        (
            "CREATE TRIGGER audit_match AFTER INSERT ON audit BEGIN DELETE FROM kept WHERE code = new.note; END",
            "error in trigger audit_match: no such column: code",
        ),
    ];
    for (sql, error) in readers {
        let file = TestFile::new().await;
        let connection = file.open().await;
        apply(connection.as_ref(), &CODES_SCHEMA).await.unwrap();
        apply(connection.as_ref(), &[sql]).await.unwrap();
        let before = read(connection.as_ref(), &kept()).await;
        let rows_sql = "SELECT id, code, note FROM kept";
        let rows = query(connection.as_ref(), rows_sql).await.rows;

        let outcome = save(connection.as_ref(), &kept(), drop_code).await;

        let Err(DriverError::RolledBack { source, .. }) = &outcome else {
            panic!("{sql}: {outcome:?}");
        };
        assert!(source.to_string().contains(error), "{sql}: {source}");
        assert_eq!(read(connection.as_ref(), &kept()).await, before, "{sql}");
        assert_eq!(query(connection.as_ref(), rows_sql).await.rows, rows, "{sql}");
        assert_eq!(rebuild_tables_left(connection.as_ref()).await, Value::Int(0), "{sql}");
        connection.close().await.unwrap();
    }
}

/// SQLite never resolves a trigger's UPDATE OF list, an INSERT's columns
/// or the columns an UPDATE sets, so its DROP COLUMN, like a rebuild,
/// would keep the trigger to fail when it fires.
#[tokio::test]
async fn a_trigger_listing_a_dropped_column_refuses_the_drop_before_save() {
    let listers = [
        "CREATE TRIGGER lists_code AFTER INSERT ON audit BEGIN UPDATE kept SET code = new.note; END",
        "CREATE TRIGGER lists_code AFTER INSERT ON audit BEGIN INSERT INTO kept (code) VALUES (new.note); END",
        "CREATE TRIGGER lists_code AFTER UPDATE OF code ON kept BEGIN INSERT INTO audit VALUES (new.note); END",
    ];
    // UNIQUE has the drop rebuild the table; without it SQLite drops it.
    let tables = [
        "CREATE TABLE kept (id INTEGER PRIMARY KEY, code TEXT UNIQUE, note TEXT)",
        "CREATE TABLE kept (id INTEGER PRIMARY KEY, code TEXT, note TEXT)",
    ];
    for (table, sql) in tables.into_iter().flat_map(|table| listers.map(|sql| (table, sql))) {
        let file = TestFile::new().await;
        let connection = file.open().await;
        apply(connection.as_ref(), &[table]).await.unwrap();
        apply(connection.as_ref(), &CODES_SCHEMA[1..]).await.unwrap();
        apply(connection.as_ref(), &[sql]).await.unwrap();
        let before = read(connection.as_ref(), &kept()).await;

        let refused = plan(connection.as_ref(), &before, drop_code);

        assert_eq!(
            refused,
            Err(BuildDdlError::Refused {
                column: "code".to_owned(),
                operation: DdlOperation::DropColumn,
                reason: RefusalReason::ColumnInUse(vec!["lists_code".to_owned()]),
            }),
            "{table}: {sql}"
        );
        connection.close().await.unwrap();
    }
}

/// A function, a type, a collation or a keyword spelled like a column is
/// not the column, in a rebuild or in SQLite's own DROP COLUMN.
#[tokio::test]
async fn a_word_in_the_tables_own_expressions_does_not_hold_a_column() {
    for unique in ["UNIQUE", ""] {
        let file = TestFile::new().await;
        let connection = file.open().await;
        apply(
            connection.as_ref(),
            &[
                &format!(
                    "CREATE TABLE kept (id INTEGER PRIMARY KEY, date TEXT {unique}, \"end\" TEXT {unique}, text TEXT \
                     {unique}, nocase TEXT {unique}, note TEXT CHECK (CAST(note AS text) <> '' COLLATE nocase), \
                     CHECK (date(note) IS NOT NULL), CHECK (CASE WHEN note IS NULL THEN 0 ELSE 1 END))"
                ),
                "CREATE INDEX kept_day ON kept (date(note) DESC) WHERE CASE WHEN note > '' THEN 1 END",
                "INSERT INTO kept VALUES (1, 'd', 'e', 't', 'n', '2026-10-16')",
            ],
        )
        .await
        .unwrap();

        let saved = save(connection.as_ref(), &kept(), |draft| {
            draft
                .columns
                .retain(|column| !["date", "end", "text", "nocase"].contains(&column.name.as_str()));
        })
        .await;

        assert!(saved.is_ok(), "{unique}: {saved:?}");
        let after = read(connection.as_ref(), &kept()).await;
        assert_eq!(names(&after), ["id", "note"], "{unique}");
        assert_eq!(dependent_names(&after), ["kept_day"], "{unique}");
        let rows = query(connection.as_ref(), "SELECT id, note FROM kept").await;
        assert_eq!(rows.rows, [vec![Value::Int(1), text("2026-10-16")]], "{unique}");
        connection.close().await.unwrap();
    }
}

/// What SQLite refuses only as "no such column", without naming the
/// constraint or index, is refused before Save by name. SQLite's own
/// DROP COLUMN names an index, so there it refuses the drop itself.
#[tokio::test]
async fn the_tables_own_expressions_using_a_dropped_column_hold_it() {
    let uses = [
        ("CHECK (code <> note)", None, "CHECK (code <> note)"),
        ("CONSTRAINT coded CHECK (\"code\" IS NOT NULL)", None, "coded"),
        ("UNIQUE (code, note)", None, "UNIQUE (code, note)"),
        ("label TEXT CHECK (length(code) > 0)", None, "label"),
        ("label TEXT AS (upper(code))", None, "label"),
        (
            "label TEXT",
            Some("CREATE INDEX kept_lower ON kept (lower(code))"),
            "kept_lower",
        ),
        (
            "label TEXT",
            Some("CREATE INDEX kept_lower ON kept (note) WHERE code IS NOT NULL"),
            "kept_lower",
        ),
    ];
    for unique in ["UNIQUE", ""] {
        for (element, index, user) in uses {
            let file = TestFile::new().await;
            let connection = file.open().await;
            apply(
                connection.as_ref(),
                &[&format!(
                    "CREATE TABLE kept (id INTEGER PRIMARY KEY, code TEXT {unique}, note TEXT, {element})"
                )],
            )
            .await
            .unwrap();
            if let Some(index) = index {
                apply(connection.as_ref(), &[index]).await.unwrap();
            }
            let before = read(connection.as_ref(), &kept()).await;

            let planned = plan(connection.as_ref(), &before, drop_code);

            if index.is_some() && unique.is_empty() {
                let outcome = save(connection.as_ref(), &kept(), drop_code).await;
                let Err(DriverError::RolledBack { source, .. }) = &outcome else {
                    panic!("{element}: {outcome:?}");
                };
                assert!(
                    source
                        .to_string()
                        .contains("error in index kept_lower after drop column: no such column: code"),
                    "{source}"
                );
                assert_eq!(read(connection.as_ref(), &kept()).await, before);
            } else {
                assert_eq!(
                    planned,
                    Err(BuildDdlError::Refused {
                        column: "code".to_owned(),
                        operation: DdlOperation::DropColumn,
                        reason: RefusalReason::ColumnInUse(vec![user.to_owned()]),
                    }),
                    "{unique}: {element} {index:?}"
                );
            }
            connection.close().await.unwrap();
        }
    }
}

/// An INSERT without a column list takes one value per column that is
/// not generated, so adding or dropping one breaks it, natively or in a
/// rebuild, while dropping a generated column or renaming one does not.
#[tokio::test]
async fn a_trigger_inserting_by_position_holds_the_tables_columns() {
    let refused = |column: &str, operation| {
        Err(BuildDdlError::Refused {
            column: column.to_owned(),
            operation,
            reason: RefusalReason::InsertedByPosition(vec!["audit_copy".to_owned()]),
        })
    };
    for unique in ["UNIQUE", ""] {
        let file = TestFile::new().await;
        let connection = file.open().await;
        apply(
            connection.as_ref(),
            &[
                &format!(
                    "CREATE TABLE kept (id INTEGER PRIMARY KEY, code TEXT {unique}, note TEXT, next INTEGER AS (id + 1))"
                ),
                "CREATE TABLE audit (note TEXT)",
                "CREATE TRIGGER audit_copy AFTER INSERT ON audit BEGIN INSERT INTO kept VALUES (NULL, new.note, 'x'); \
                 END",
            ],
        )
        .await
        .unwrap();
        let before = read(connection.as_ref(), &kept()).await;

        let dropped = plan(connection.as_ref(), &before, drop_code);
        let added = plan(connection.as_ref(), &before, |draft| {
            draft
                .columns
                .push(DraftColumn::new("extra", DraftType::Typed("TEXT".to_owned())));
        });
        let generated = save(connection.as_ref(), &kept(), |draft| {
            draft.columns.retain(|column| column.name != "next");
        })
        .await;
        let renamed = save(connection.as_ref(), &kept(), |draft| {
            column(draft, "note").name = "body".to_owned()
        })
        .await;

        assert_eq!(dropped, refused("code", DdlOperation::DropColumn), "{unique}");
        assert_eq!(added, refused("extra", DdlOperation::AddColumn), "{unique}");
        assert!(generated.is_ok(), "{unique}: {generated:?}");
        assert!(renamed.is_ok(), "{unique}: {renamed:?}");
        apply(connection.as_ref(), &["INSERT INTO audit VALUES ('a')"])
            .await
            .unwrap();
        let rows = query(connection.as_ref(), "SELECT code, body FROM kept").await;
        assert_eq!(rows.rows, [vec![text("a"), text("x")]], "{unique}");
        connection.close().await.unwrap();
    }
}

/// The END that closes a trigger body or a CASE is a keyword, not the
/// column `end`.
#[tokio::test]
async fn a_column_named_end_drops_past_a_trigger() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE kept (id INTEGER PRIMARY KEY, \"end\" TEXT UNIQUE, note TEXT)",
            "CREATE TABLE audit (note TEXT)",
            "CREATE TRIGGER kept_audit AFTER INSERT ON kept BEGIN INSERT INTO audit VALUES (CASE WHEN new.note \
             IS NULL THEN 'none' ELSE new.note END); END",
            "INSERT INTO kept VALUES (1, 'x', 'a')",
        ],
    )
    .await
    .unwrap();

    let saved = save(connection.as_ref(), &kept(), |draft| {
        draft.columns.retain(|column| column.name != "end");
    })
    .await;

    assert!(saved.is_ok(), "{saved:?}");
    let after = read(connection.as_ref(), &kept()).await;
    assert_eq!(names(&after), ["id", "note"]);
    assert_eq!(dependent_names(&after), ["kept_audit"]);
    apply(connection.as_ref(), &["INSERT INTO kept (note) VALUES (NULL)"])
        .await
        .unwrap();
    let audit = query(connection.as_ref(), "SELECT note FROM audit ORDER BY rowid").await;
    assert_eq!(audit.rows, [vec![text("a")], vec![text("none")]]);
    assert_eq!(rebuild_tables_left(connection.as_ref()).await, Value::Int(0));
    connection.close().await.unwrap();
}

#[tokio::test]
async fn a_name_in_a_string_or_comment_does_not_hold_a_column() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE kept (id INTEGER PRIMARY KEY, code TEXT UNIQUE, note TEXT)",
            "INSERT INTO kept VALUES (1, 'x', 'a')",
            "CREATE VIEW notes AS SELECT id, note, 'code' AS kind FROM kept -- not code",
            "CREATE TRIGGER kept_stamp AFTER INSERT ON kept BEGIN /* code */ UPDATE kept SET note = 'code' WHERE \
             id = new.id; END",
        ],
    )
    .await
    .unwrap();

    let saved = save(connection.as_ref(), &kept(), drop_code).await;

    assert!(saved.is_ok(), "{saved:?}");
    let after = read(connection.as_ref(), &kept()).await;
    assert_eq!(names(&after), ["id", "note"]);
    assert_eq!(dependent_names(&after), ["notes", "kept_stamp"]);
    apply(connection.as_ref(), &["INSERT INTO kept (id) VALUES (2)"])
        .await
        .unwrap();
    let notes = query(connection.as_ref(), "SELECT note, kind FROM notes ORDER BY id").await;
    assert_eq!(
        notes.rows,
        [vec![text("a"), text("code")], vec![text("code"), text("code")]]
    );
    connection.close().await.unwrap();
}

/// A name SQLite resolves to another table's column is that table's,
/// however it is spelled.
#[tokio::test]
async fn another_tables_column_of_the_same_name_does_not_hold_a_column() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE kept (id INTEGER PRIMARY KEY, note TEXT UNIQUE)",
            "CREATE TABLE audit (id INTEGER, note TEXT)",
            "CREATE TRIGGER kept_audit AFTER INSERT ON kept BEGIN INSERT INTO audit (id, note) VALUES (new.id, \
             'added'); UPDATE audit SET note = 'seen' WHERE note IS NULL; END",
            "CREATE VIEW audited AS SELECT kept.id, audit.note FROM kept JOIN audit USING (id)",
            "INSERT INTO kept VALUES (1, 'a')",
        ],
    )
    .await
    .unwrap();

    let saved = save(connection.as_ref(), &kept(), |draft| {
        draft.columns.retain(|column| column.name != "note");
    })
    .await;

    assert!(saved.is_ok(), "{saved:?}");
    assert_eq!(names(&read(connection.as_ref(), &kept()).await), ["id"]);
    apply(connection.as_ref(), &["INSERT INTO kept (id) VALUES (2)"])
        .await
        .unwrap();
    let audited = query(connection.as_ref(), "SELECT id, note FROM audited ORDER BY id").await;
    assert_eq!(
        audited.rows,
        [vec![Value::Int(1), text("added")], vec![Value::Int(2), text("added")]]
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

/// The copy runs as INSERT OR ABORT, so a conflict clause the table
/// declares cannot quietly drop a row the new type makes a duplicate.
#[tokio::test]
async fn a_conflict_clause_in_the_table_cannot_drop_rows_in_the_copy() {
    for create in [
        "CREATE TABLE kept (code TEXT UNIQUE ON CONFLICT IGNORE, note TEXT)",
        "CREATE TABLE kept (code TEXT PRIMARY KEY ON CONFLICT REPLACE, note TEXT)",
    ] {
        let file = TestFile::new().await;
        let connection = file.open().await;
        apply(
            connection.as_ref(),
            &[create, "INSERT INTO kept VALUES ('1', 'one'), ('01', 'zero one')"],
        )
        .await
        .unwrap();
        let before = read(connection.as_ref(), &kept()).await;

        let outcome = save(connection.as_ref(), &kept(), |draft| retype(draft, "code", "INTEGER")).await;

        let Err(DriverError::RolledBack { source, .. }) = &outcome else {
            panic!("{create}: {outcome:?}");
        };
        assert!(source.to_string().contains("UNIQUE"), "{create}: {source}");
        assert_eq!(read(connection.as_ref(), &kept()).await, before, "{create}");
        let count = query(connection.as_ref(), "SELECT count(*) FROM kept").await;
        assert_eq!(count.rows[0][0], Value::Int(2), "{create}");
        connection.close().await.unwrap();
    }
}

#[tokio::test]
async fn a_default_written_after_a_line_comment_reads_back() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE kept (id INTEGER PRIMARY KEY, a TEXT -- note\n NOT NULL, b TEXT)",
            "INSERT INTO kept VALUES (1, 'x', 'y')",
        ],
    )
    .await
    .unwrap();

    save(connection.as_ref(), &kept(), |draft| {
        let a = column(draft, "a");
        a.nullable = true;
        a.default = ColumnDefault::Literal(text("dflt"));
    })
    .await
    .unwrap();
    apply(connection.as_ref(), &["INSERT INTO kept (id) VALUES (2)"])
        .await
        .unwrap();

    let after = read(connection.as_ref(), &kept()).await;
    assert!(after.columns[1].info.nullable);
    assert_eq!(after.columns[1].info.default, ColumnDefault::Literal(text("dflt")));
    assert!(
        create_statement(&after).contains("-- note\n"),
        "{}",
        create_statement(&after)
    );
    let rows = query(connection.as_ref(), "SELECT a, b FROM kept ORDER BY id").await;
    assert_eq!(rows.rows, [vec![text("x"), text("y")], vec![text("dflt"), Value::Null]]);
    connection.close().await.unwrap();
}

/// SQLite numbers an INTEGER PRIMARY KEY however it is declared, so
/// numbering turns off only with the type or the key, and then reads
/// back off.
#[tokio::test]
async fn numbering_turns_off_only_where_it_reads_back_off() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE kept (id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT)",
            "INSERT INTO kept (v) VALUES ('a'), ('b')",
        ],
    )
    .await
    .unwrap();
    let before = read(connection.as_ref(), &kept()).await;
    assert!(before.columns[0].info.is_auto_increment);

    let off = plan(connection.as_ref(), &before, |draft| {
        column(draft, "id").auto_increment = false;
    });
    save(connection.as_ref(), &kept(), |draft| {
        retype(draft, "id", "BIGINT");
        column(draft, "id").auto_increment = false;
    })
    .await
    .unwrap();

    assert!(
        matches!(
            off,
            Err(BuildDdlError::Refused {
                reason: RefusalReason::AlwaysNumbered,
                ..
            })
        ),
        "{off:?}"
    );
    let after = read(connection.as_ref(), &kept()).await;
    assert!(!after.columns[0].info.is_auto_increment);
    assert_eq!(after.columns[0].info.column_type.name, "BIGINT");
    assert_eq!(after.primary_key.map(|key| key.columns), Some(vec!["id".to_owned()]));
    let rows = query(connection.as_ref(), "SELECT rowid, id, v FROM kept ORDER BY id").await;
    assert_eq!(
        rows.rows,
        [
            vec![Value::Int(1), Value::Int(1), text("a")],
            vec![Value::Int(2), Value::Int(2), text("b")]
        ]
    );
    let sequence = query(
        connection.as_ref(),
        "SELECT count(*) FROM sqlite_sequence WHERE name = 'kept'",
    )
    .await;
    assert_eq!(sequence.rows[0][0], Value::Int(0));
    connection.close().await.unwrap();
}

/// A column that becomes the INTEGER PRIMARY KEY gives its rows its own
/// values as rowids, so an orphan already there keeps no rowid to be
/// recognised by. It is still the file's, not the save's.
#[tokio::test]
async fn a_new_rowid_key_keeps_an_orphan_the_save_did_not_make() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE parents (id INTEGER PRIMARY KEY)",
            "CREATE TABLE kept (id INTEGER NOT NULL, parent INTEGER REFERENCES parents (id))",
            "CREATE TABLE loose (id INTEGER NOT NULL, parent INTEGER)",
            "INSERT INTO parents VALUES (1)",
            "INSERT INTO loose VALUES (10, 99)",
        ],
    )
    .await
    .unwrap();
    unchecked(connection.as_ref(), &["INSERT INTO kept VALUES (10, 1), (20, 99)"]).await;

    let kept_outcome = save(connection.as_ref(), &kept(), |draft| {
        column(draft, "id").primary_key = true;
    })
    .await;
    let loose_outcome = save(connection.as_ref(), &named("loose"), |draft| {
        column(draft, "id").primary_key = true;
        draft.foreign_keys.push(ForeignKeyInfo {
            name: "loose_parent".to_owned(),
            columns: vec!["parent".to_owned()],
            ref_schema: None,
            ref_table: "parents".to_owned(),
            ref_columns: vec!["id".to_owned()],
            on_delete: None,
            on_update: None,
        });
    })
    .await;

    assert!(kept_outcome.is_ok(), "{kept_outcome:?}");
    let rows = query(connection.as_ref(), "SELECT rowid, id, parent FROM kept ORDER BY id").await;
    assert_eq!(
        rows.rows,
        [
            vec![Value::Int(10), Value::Int(10), Value::Int(1)],
            vec![Value::Int(20), Value::Int(20), Value::Int(99)]
        ]
    );
    let Err(DriverError::RolledBack { source, .. }) = &loose_outcome else {
        panic!("a violation the save made was let through: {loose_outcome:?}");
    };
    assert!(source.to_string().contains("1 rows of loose"), "{source}");
    connection.close().await.unwrap();
}

/// `INTEGER PRIMARY KEY DESC` on the column is not the rowid, so the
/// rebuild carries the rowids across on their own.
#[tokio::test]
async fn a_descending_integer_key_keeps_its_rowids_through_a_rebuild() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE kept (id INTEGER PRIMARY KEY DESC, v TEXT)",
            "INSERT INTO kept (rowid, id, v) VALUES (5, 1, 'a'), (9, 2, 'b')",
        ],
    )
    .await
    .unwrap();

    save(connection.as_ref(), &kept(), |draft| retype(draft, "v", "BLOB"))
        .await
        .unwrap();

    let rows = query(connection.as_ref(), "SELECT rowid, id, v FROM kept ORDER BY rowid").await;
    assert_eq!(
        rows.rows,
        [
            vec![Value::Int(5), Value::Int(1), text("a")],
            vec![Value::Int(9), Value::Int(2), text("b")]
        ]
    );
    connection.close().await.unwrap();
}

/// Drop Table as the workspace plans and runs it.
async fn drop_table(connection: &dyn Connection, table: &TableRef) -> Result<WriteReport, DriverError> {
    let options = DropTableOptions {
        if_exists: true,
        cascade: false,
    };
    let plan = connection
        .dialect()
        .ddl()
        .unwrap()
        .plan_drop_table(table, options)
        .unwrap();
    connection
        .write_batch(&plan.into_write_batch(table.clone()), call())
        .await
}

/// SQLite's implicit DELETE before a drop would run these keys' ON
/// DELETE actions, deleting the order and clearing the note's key.
#[tokio::test]
async fn a_table_another_tables_key_points_at_is_not_dropped() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE customers (id INTEGER PRIMARY KEY)",
            "CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES Customers ON DELETE CASCADE)",
            "CREATE TABLE notes (id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES customers ON DELETE SET NULL)",
            "INSERT INTO customers VALUES (1)",
            "INSERT INTO orders VALUES (10, 1)",
            "INSERT INTO notes VALUES (20, 1)",
        ],
    )
    .await
    .unwrap();

    let outcome = drop_table(connection.as_ref(), &named("customers")).await;

    assert_eq!(
        outcome,
        Err(DriverError::RowGuardFailed {
            statement_index: 0,
            expected: 0,
            actual: 2
        })
    );
    let left = query(
        connection.as_ref(),
        "SELECT (SELECT count(*) FROM customers), (SELECT customer_id FROM orders), (SELECT customer_id FROM notes)",
    )
    .await;
    assert_eq!(left.rows, [vec![Value::Int(1), Value::Int(1), Value::Int(1)]]);
    connection.close().await.unwrap();
}

#[tokio::test]
async fn a_table_only_its_own_key_points_at_is_dropped() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE tree (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES Tree ON DELETE CASCADE)",
            "CREATE TABLE other (id INTEGER PRIMARY KEY, kept_id INTEGER REFERENCES kept)",
            "INSERT INTO tree VALUES (1, NULL), (2, 1)",
        ],
    )
    .await
    .unwrap();

    drop_table(connection.as_ref(), &named("tree")).await.unwrap();

    let tables = query(
        connection.as_ref(),
        "SELECT name FROM sqlite_schema WHERE type = 'table' ORDER BY name",
    )
    .await;
    assert_eq!(tables.rows, [vec![text("other")]]);
    connection.close().await.unwrap();
}
