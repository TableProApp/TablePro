//! Structure changes DuckDB takes and refuses, beyond the conformance
//! suite: what something depending on a table holds in place.

use tablepro_core::ddl::{BuildDdlError, DdlOperation, DraftColumn, DraftType, RefusalReason, TableDraft, diff_table};
use tablepro_core::meta::TableRef;
use tablepro_core::{Connection, DriverError, Value};

use crate::support::{TestFile, apply, call, query};

async fn definition(connection: &dyn Connection, name: &str) -> tablepro_core::ddl::TableDefinition {
    connection
        .fetch_table_definition(&TableRef::unqualified(name), call())
        .await
        .unwrap()
}

/// A table an index is made on takes no rename and no change to a
/// column but its default, and the plan says why before DuckDB would.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_index_holds_its_table_in_place() {
    let file = TestFile::new();
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &["CREATE TABLE t (a INTEGER, b VARCHAR)", "CREATE INDEX t_b ON t (b)"],
    )
    .await
    .unwrap();
    let dialect = connection.dialect();
    let ddl = dialect.ddl().unwrap();
    let original = definition(connection.as_ref(), "t").await;

    let mut renamed = TableDraft::from_definition(&original);
    renamed.columns[0].name = "aa".to_owned();
    let refused = ddl.plan_alter_table(&original, &diff_table(&original, &renamed));
    let direct = apply(connection.as_ref(), &["ALTER TABLE t RENAME COLUMN a TO aa"]).await;

    assert!(
        matches!(
            &refused,
            Err(BuildDdlError::Refused {
                operation: DdlOperation::RenameColumn,
                reason: RefusalReason::ColumnInUse(users),
                ..
            }) if users == &["t_b".to_owned()]
        ),
        "{refused:?}"
    );
    assert!(
        matches!(direct, Err(DriverError::RolledBack { .. })),
        "DuckDB took the rename the plan refuses: {direct:?}"
    );
    assert!(!ddl.table_capabilities(&original).rename_table);

    let mut defaulted = TableDraft::from_definition(&original);
    defaulted.columns[0].default = tablepro_core::column::ColumnDefault::Literal(Value::Int(3));
    let plan = ddl
        .plan_alter_table(&original, &diff_table(&original, &defaulted))
        .unwrap();
    connection
        .write_batch(&plan.into_write_batch(TableRef::unqualified("t")), call())
        .await
        .unwrap();
    connection.close().await.unwrap();
}

/// DuckDB adds no column with a constraint, so a NOT NULL column is
/// added and then made NOT NULL.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_required_column_is_added_then_made_required() {
    let file = TestFile::new();
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &["CREATE TABLE t (a INTEGER)", "INSERT INTO t VALUES (1)"],
    )
    .await
    .unwrap();
    let dialect = connection.dialect();
    let ddl = dialect.ddl().unwrap();
    let original = definition(connection.as_ref(), "t").await;
    let mut draft = TableDraft::from_definition(&original);
    let mut column = DraftColumn::new("b", DraftType::Typed("INTEGER".to_owned()));
    column.nullable = false;
    column.default = tablepro_core::column::ColumnDefault::Literal(Value::Int(5));
    draft.columns.push(column);

    let plan = ddl.plan_alter_table(&original, &diff_table(&original, &draft)).unwrap();
    connection
        .write_batch(&plan.into_write_batch(TableRef::unqualified("t")), call())
        .await
        .unwrap();

    let after = definition(connection.as_ref(), "t").await;
    let added = after.column("b").unwrap();
    assert!(!added.info.nullable);
    assert_eq!(
        query(connection.as_ref(), "SELECT b FROM t").await.rows,
        vec![vec![Value::Int(5)]]
    );
    connection.close().await.unwrap();
}

/// A key goes on a table that has none; one already there stays.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_key_is_added_but_never_moved() {
    let file = TestFile::new();
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE loose (a INTEGER NOT NULL)",
            "CREATE TABLE keyed (a INTEGER PRIMARY KEY, b INTEGER)",
        ],
    )
    .await
    .unwrap();
    let dialect = connection.dialect();
    let ddl = dialect.ddl().unwrap();

    let loose = definition(connection.as_ref(), "loose").await;
    let mut keyed_draft = TableDraft::from_definition(&loose);
    keyed_draft.columns[0].primary_key = true;
    let plan = ddl.plan_alter_table(&loose, &diff_table(&loose, &keyed_draft)).unwrap();
    connection
        .write_batch(&plan.into_write_batch(TableRef::unqualified("loose")), call())
        .await
        .unwrap();
    assert!(definition(connection.as_ref(), "loose").await.primary_key.is_some());

    let keyed = definition(connection.as_ref(), "keyed").await;
    let mut moved = TableDraft::from_definition(&keyed);
    moved.columns[0].primary_key = false;
    moved.columns[1].primary_key = true;
    assert!(ddl.plan_alter_table(&keyed, &diff_table(&keyed, &moved)).is_err());
    assert!(!ddl.table_capabilities(&keyed).alter_primary_key);
    connection.close().await.unwrap();
}

/// A UNIQUE key's index is listed with the table's indexes, and only an
/// index made with CREATE INDEX can be dropped: DuckDB drops no
/// constraint.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_unique_key_index_is_not_dropped_on_its_own() {
    let file = TestFile::new();
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE t (a INTEGER UNIQUE, b INTEGER)",
            "CREATE INDEX t_b ON t (b)",
        ],
    )
    .await
    .unwrap();
    let dialect = connection.dialect();
    let ddl = dialect.ddl().unwrap();
    let original = definition(connection.as_ref(), "t").await;
    let unique = original.indexes.iter().find(|index| index.unique).unwrap().clone();
    let created = original
        .indexes
        .iter()
        .find(|index| index.name == "t_b")
        .unwrap()
        .clone();

    let mut without_key = TableDraft::from_definition(&original);
    without_key.indexes.retain(|index| index.name != unique.name);
    let refused = ddl.plan_alter_table(&original, &diff_table(&original, &without_key));
    let direct = apply(connection.as_ref(), &[&format!("DROP INDEX \"{}\"", unique.name)]).await;

    assert!(!ddl.index_removal(&original, &unique).is_allowed());
    assert!(ddl.index_removal(&original, &created).is_allowed());
    assert_eq!(refused.err(), Some(BuildDdlError::Unsupported(DdlOperation::DropIndex)));
    assert!(direct.is_err(), "DuckDB dropped the index of a UNIQUE key");
    connection.close().await.unwrap();
}

/// DuckDB refuses a new type for any column a CHECK names, the CHECK
/// over two columns included.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_check_over_two_columns_holds_both_types() {
    let file = TestFile::new();
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &["CREATE TABLE t (a INTEGER, b INTEGER, c INTEGER, CHECK (a < b))"],
    )
    .await
    .unwrap();
    let dialect = connection.dialect();
    let ddl = dialect.ddl().unwrap();
    let original = definition(connection.as_ref(), "t").await;

    let allowed = |name: &str| {
        ddl.column_capabilities(&original, original.column(name).unwrap())
            .alter_type
            .is_allowed()
    };
    let direct = apply(connection.as_ref(), &["ALTER TABLE t ALTER b TYPE BIGINT"]).await;

    assert!(!allowed("a") && !allowed("b"));
    assert!(allowed("c"));
    assert!(direct.is_err(), "DuckDB changed the type of a column a CHECK names");
    connection.close().await.unwrap();
}

/// A CHECK on one column goes with it when it is dropped. DuckDB drops
/// no column a CHECK shares with another.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_column_a_check_shares_is_not_dropped() {
    let file = TestFile::new();
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &["CREATE TABLE t (a INTEGER, b INTEGER, c INTEGER CHECK (c > 0), CHECK (a < b))"],
    )
    .await
    .unwrap();
    let dialect = connection.dialect();
    let ddl = dialect.ddl().unwrap();
    let original = definition(connection.as_ref(), "t").await;

    let droppable = |name: &str| {
        ddl.column_capabilities(&original, original.column(name).unwrap())
            .drop
            .is_allowed()
    };
    let shared = apply(connection.as_ref(), &["ALTER TABLE t DROP COLUMN a"]).await;
    let alone = apply(connection.as_ref(), &["ALTER TABLE t DROP COLUMN c"]).await;

    assert!(!droppable("a") && !droppable("b"));
    assert!(droppable("c"));
    assert!(shared.is_err(), "DuckDB dropped a column a CHECK shares");
    assert!(alone.is_ok(), "{alone:?}");
    connection.close().await.unwrap();
}
