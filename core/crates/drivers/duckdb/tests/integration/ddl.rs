//! Structure changes DuckDB takes and refuses, beyond the conformance
//! suite: what something depending on a table holds in place.

use tablepro_core::ddl::{
    self as catalog, BuildDdlError, DatabaseDraft, DdlOperation, DraftColumn, DraftType, DropDatabaseOptions,
    DropSchemaOptions, RefusalReason, SchemaDraft, TableDraft, TruncateTableOptions, diff_table,
};
use tablepro_core::meta::TableRef;
use tablepro_core::{Connection, DriverError, Value};
use tablepro_driver_duckdb::DuckDbDialect;

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

/// DuckDB drops a column's collation with its old type unless the change
/// names it again, so a new type keeps the collation the column had.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_new_type_keeps_the_columns_collation() {
    let file = TestFile::new();
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &["CREATE TABLE t (code VARCHAR COLLATE nocase.noaccent, n INTEGER)"],
    )
    .await
    .unwrap();
    let dialect = connection.dialect();
    let ddl = dialect.ddl().unwrap();
    let original = definition(connection.as_ref(), "t").await;
    let mut retyped = TableDraft::from_definition(&original);
    retyped.columns[0].column_type = DraftType::Typed("TEXT".to_owned());

    let plan = ddl
        .plan_alter_table(&original, &diff_table(&original, &retyped))
        .unwrap();
    connection
        .write_batch(&plan.into_write_batch(TableRef::unqualified("t")), call())
        .await
        .unwrap();
    let stored = query(
        connection.as_ref(),
        "SELECT sql FROM duckdb_tables() WHERE table_name = 't'",
    )
    .await;

    assert_eq!(
        original.columns[0]
            .attributes
            .collation
            .as_ref()
            .map(|collation| collation.name.as_str()),
        Some("nocase.noaccent")
    );
    assert!(
        matches!(&stored.rows[0][0], Value::Text(sql) if sql.contains("code VARCHAR COLLATE nocase.noaccent")),
        "{:?}",
        stored.rows
    );
    connection.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_index_statement_makes_the_index_again_on_its_own_table() {
    let file = TestFile::new();
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE t (a INTEGER, b VARCHAR)",
            "CREATE UNIQUE INDEX t_b ON t ((lower(b)))",
            "CREATE SCHEMA s",
            "CREATE TABLE s.t (a INTEGER)",
            "CREATE INDEX \"s a\" ON s.t (a)",
        ],
    )
    .await
    .unwrap();
    let nested = TableRef::new(Some("s".to_owned()), "t");
    let read = |table: TableRef| {
        let connection = connection.as_ref();
        async move { connection.fetch_table_definition(&table, call()).await.unwrap().indexes }
    };
    let main = read(TableRef::unqualified("t")).await;
    let catalog = file.path.file_stem().unwrap().to_string_lossy().into_owned();

    assert_eq!(
        main[0].definition,
        Some(format!(
            "CREATE UNIQUE INDEX t_b ON \"{catalog}\".\"main\".\"t\"((lower(b)))"
        ))
    );
    for (table, drop, indexes) in [
        (TableRef::unqualified("t"), "DROP INDEX t_b", main),
        (nested.clone(), "DROP INDEX s.\"s a\"", read(nested).await),
    ] {
        let statement = indexes[0].definition.clone().expect("a statement");
        apply(connection.as_ref(), &[drop, statement.as_str()]).await.unwrap();
        assert_eq!(read(table).await, indexes, "{statement}");
    }
}

/// A truncate names the table with its file's catalogue; a schema is
/// named alone, so it lands in the file the connection opened.
#[test]
fn the_catalog_plans_take_only_what_duckdb_has() {
    let dialect = DuckDbDialect::for_catalog("shop");
    let table = TableRef::new(Some("sa\"les".to_owned()), "orders");
    let schema = SchemaDraft {
        name: "sa\"les".to_owned(),
        owner: None,
    };

    let truncated = catalog::plan_truncate_table(&dialect, &table, &TruncateTableOptions::default()).unwrap();
    let created = catalog::plan_create_schema(&dialect, &schema).unwrap();
    let dropped = catalog::plan_drop_schema(&dialect, "sales", DropSchemaOptions { cascade: true }).unwrap();
    let restricted = catalog::plan_drop_schema(&dialect, "sales", DropSchemaOptions::default()).unwrap();

    assert_eq!(truncated.sql(), ["TRUNCATE TABLE \"shop\".\"sa\"\"les\".\"orders\""]);
    assert_eq!(created.sql(), ["CREATE SCHEMA \"sa\"\"les\""]);
    assert_eq!(dropped.sql(), ["DROP SCHEMA \"sales\" CASCADE"]);
    assert_eq!(restricted.sql(), ["DROP SCHEMA \"sales\""]);
    let owned = SchemaDraft {
        owner: Some("ann".to_owned()),
        ..schema
    };
    assert_eq!(
        catalog::plan_create_schema(&dialect, &owned),
        Err(BuildDdlError::Unsupported(DdlOperation::CatalogOwner))
    );
    let restart = TruncateTableOptions {
        restart_identity: true,
        ..TruncateTableOptions::default()
    };
    assert_eq!(
        catalog::plan_truncate_table(&dialect, &table, &restart),
        Err(BuildDdlError::Unsupported(DdlOperation::TruncateRestartIdentity))
    );
    let cascade = TruncateTableOptions {
        cascade: true,
        ..TruncateTableOptions::default()
    };
    assert_eq!(
        catalog::plan_truncate_table(&dialect, &table, &cascade),
        Err(BuildDdlError::Unsupported(DdlOperation::TruncateTableCascade))
    );
    assert_eq!(
        catalog::plan_create_database(&dialect, &DatabaseDraft::named("other")),
        Err(BuildDdlError::Unsupported(DdlOperation::CreateDatabase))
    );
    assert_eq!(
        catalog::plan_drop_database(&dialect, "other", &DropDatabaseOptions::default()),
        Err(BuildDdlError::Unsupported(DdlOperation::DropDatabase))
    );
}

#[test]
fn main_and_the_catalogue_view_schemas_are_protected() {
    let dialect = DuckDbDialect::for_catalog("shop");

    for name in ["main", "MAIN", "information_schema", "pg_catalog"] {
        assert!(catalog::protects_schema(&dialect, name), "{name}");
    }
    assert!(!catalog::protects_schema(&dialect, "sales"));
    assert!(!catalog::protects_database(&dialect, "shop"));
}

/// The sidebar offers what the capabilities say, so each one has to
/// plan, with every option it offers, and nothing else may.
#[test]
fn every_offered_catalog_operation_plans() {
    let dialect = DuckDbDialect::for_catalog("shop");
    let offered = catalog::catalog_capabilities(&dialect);
    let table = TableRef::new(Some("main".to_owned()), "orders");
    let truncate = TruncateTableOptions {
        cascade: offered.truncate_cascade,
        restart_identity: offered.truncate_restart_identity,
        cluster: None,
    };
    let schema = SchemaDraft {
        name: "sales".to_owned(),
        owner: offered.schema_owner.then(|| "ann".to_owned()),
    };
    let drop_schema = DropSchemaOptions {
        cascade: offered.drop_schema_cascade,
    };

    assert!(offered.truncate_table && offered.create_schema && offered.drop_schema && offered.drop_schema_cascade);
    assert!(!offered.create_database && !offered.drop_database && !offered.schema_owner);
    assert!(!offered.truncate_refused_when_referenced && offered.name_limit.is_none());
    assert!(catalog::plan_truncate_table(&dialect, &table, &truncate).is_ok());
    assert!(catalog::plan_create_schema(&dialect, &schema).is_ok());
    assert!(catalog::plan_drop_schema(&dialect, "sales", drop_schema).is_ok());
}

/// The linked DuckDB parses TRUNCATE as DELETE without a WHERE: the
/// table stays and its rows go, and a row another table's key still
/// points at holds the whole statement back.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_truncate_empties_the_table_unless_a_key_points_at_a_row() {
    let file = TestFile::new();
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE parent (id INTEGER PRIMARY KEY)",
            "CREATE TABLE child (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES parent (id))",
            "INSERT INTO parent VALUES (1), (2)",
            "INSERT INTO child VALUES (10, 1)",
        ],
    )
    .await
    .unwrap();
    let dialect = connection.dialect();
    let truncate = |name: &str| {
        let table = TableRef::new(Some("main".to_owned()), name);
        catalog::plan_truncate_table(dialect.as_ref(), &table, &TruncateTableOptions::default())
            .unwrap()
            .into_write_batch(table)
    };

    let held = connection.write_batch(&truncate("parent"), call()).await;
    let parents_held = query(connection.as_ref(), "SELECT count(*) FROM parent").await;
    connection.write_batch(&truncate("child"), call()).await.unwrap();
    connection.write_batch(&truncate("parent"), call()).await.unwrap();

    assert!(matches!(held, Err(DriverError::RolledBack { .. })), "{held:?}");
    assert_eq!(parents_held.rows, vec![vec![Value::Int(2)]]);
    let left = query(
        connection.as_ref(),
        "SELECT (SELECT count(*) FROM parent), (SELECT count(*) FROM child), \
         (SELECT count(*) FROM duckdb_tables() WHERE table_name IN ('parent', 'child'))",
    )
    .await;
    assert_eq!(left.rows, vec![vec![Value::Int(0), Value::Int(0), Value::Int(2)]]);
    connection.close().await.unwrap();
}

/// A schema that holds a table drops only with CASCADE, and DuckDB
/// refuses to drop `main` at all, which is why it is never offered.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_schema_is_made_and_dropped_with_what_it_holds() {
    let file = TestFile::new();
    let connection = file.open().await;
    let dialect = connection.dialect();
    let sales = TableRef::new(Some("sales".to_owned()), "");
    let draft = SchemaDraft {
        name: "sales".to_owned(),
        owner: None,
    };
    let drop_plan = |cascade| {
        catalog::plan_drop_schema(dialect.as_ref(), "sales", DropSchemaOptions { cascade })
            .unwrap()
            .into_write_batch(sales.clone())
    };
    let created = catalog::plan_create_schema(dialect.as_ref(), &draft).unwrap();

    connection
        .write_batch(&created.into_write_batch(sales.clone()), call())
        .await
        .unwrap();
    apply(connection.as_ref(), &["CREATE TABLE sales.orders (id INTEGER)"])
        .await
        .unwrap();
    let listed = connection.list_schemas(call()).await.unwrap();
    let restricted = connection.write_batch(&drop_plan(false), call()).await;
    connection.write_batch(&drop_plan(true), call()).await.unwrap();
    let main = apply(connection.as_ref(), &["DROP SCHEMA main CASCADE"]).await;

    assert!(listed.iter().any(|schema| schema.name == "sales"), "{listed:?}");
    assert!(
        matches!(restricted, Err(DriverError::RolledBack { .. })),
        "{restricted:?}"
    );
    let after = connection.list_schemas(call()).await.unwrap();
    assert!(!after.iter().any(|schema| schema.name == "sales"), "{after:?}");
    assert!(main.is_err(), "DuckDB dropped main");
    connection.close().await.unwrap();
}
