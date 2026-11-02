//! What the catalogue reads report for a DuckDB file.

use tablepro_core::column::ColumnDefault;
use tablepro_core::meta::{IndexKey, ObjectKind, ObjectScope, RowCountEstimate, RowIdentity, TableRef};
use tablepro_core::{RunEnd, Value};

use crate::support::{TestFile, apply, call, query, run, session};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn schemas_and_objects_are_the_files_own() {
    let file = TestFile::new();
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE SCHEMA sales",
            "CREATE TABLE sales.orders (id INTEGER)",
            "CREATE TABLE people (id INTEGER)",
            "CREATE VIEW people_view AS SELECT * FROM people",
        ],
    )
    .await
    .unwrap();
    let editor = session(connection.as_ref()).await;
    let other = file.path.with_file_name("other.duckdb");
    let (attached, _) = run(
        editor.as_ref(),
        &format!(
            "ATTACH '{}' AS other; CREATE TABLE other.elsewhere (a INTEGER)",
            other.display()
        ),
    )
    .await;
    assert_eq!(attached.end, RunEnd::Completed);

    let schemas = connection.list_schemas(call()).await.unwrap();
    let names: Vec<(&str, bool)> = schemas
        .iter()
        .map(|schema| (schema.name.as_str(), schema.is_default))
        .collect();
    let main = connection
        .list_objects(&ObjectScope::DefaultSchema, call())
        .await
        .unwrap();
    let all = connection.list_objects(&ObjectScope::AllSchemas, call()).await.unwrap();

    assert_eq!(names, [("main", true), ("sales", false)]);
    let listed: Vec<(&str, ObjectKind)> = main.iter().map(|object| (object.name.as_str(), object.kind)).collect();
    assert_eq!(
        listed,
        [("people", ObjectKind::Table), ("people_view", ObjectKind::View)]
    );
    assert!(
        all.iter()
            .any(|object| object.name == "orders" && object.schema.as_deref() == Some("sales"))
    );
    assert!(
        !all.iter().any(|object| object.name == "elsewhere"),
        "an attached database listed as this file's"
    );
    editor.close().await;
    connection.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn columns_carry_their_key_defaults_and_generated_expression() {
    let file = TestFile::new();
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE SEQUENCE numbers",
            "CREATE TABLE t (id BIGINT DEFAULT nextval('numbers') PRIMARY KEY, label VARCHAR NOT NULL DEFAULT 'it''s', \
             made TIMESTAMP DEFAULT current_timestamp, doubled BIGINT GENERATED ALWAYS AS (id * 2) VIRTUAL)",
            "COMMENT ON COLUMN t.label IS 'what it is'",
        ],
    )
    .await
    .unwrap();

    let columns = connection
        .fetch_columns(&TableRef::unqualified("t"), call())
        .await
        .unwrap();

    let id = &columns[0];
    assert!(id.primary_key && id.is_auto_increment && !id.nullable);
    let label = &columns[1];
    assert_eq!(label.default, ColumnDefault::Literal(Value::Text("it's".to_owned())));
    assert_eq!(label.comment.as_deref(), Some("what it is"));
    assert!(!label.nullable);
    assert!(
        matches!(&columns[2].default, ColumnDefault::Expression(expression) if expression.as_sql() == "current_timestamp")
    );
    let doubled = &columns[3];
    assert!(
        doubled.is_generated && doubled.default == ColumnDefault::None,
        "{doubled:?}"
    );
    connection.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn keys_and_indexes_are_listed_with_the_keys_that_point_here() {
    let file = TestFile::new();
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE parent (id INTEGER PRIMARY KEY, code VARCHAR UNIQUE, note VARCHAR)",
            "CREATE TABLE child (id INTEGER, parent_id INTEGER REFERENCES parent (id))",
            "CREATE INDEX parent_note ON parent (note)",
            "CREATE INDEX parent_lower ON parent ((lower(note)))",
        ],
    )
    .await
    .unwrap();
    let parent = TableRef::unqualified("parent");

    let indexes = connection.fetch_indexes(&parent, call()).await.unwrap();
    let keys = connection
        .fetch_foreign_keys(&TableRef::unqualified("child"), call())
        .await
        .unwrap();
    let definition = connection.fetch_table_definition(&parent, call()).await.unwrap();

    let primary = indexes.iter().find(|index| index.primary).unwrap();
    assert_eq!(primary.key_columns(), ["id"]);
    assert!(
        indexes
            .iter()
            .any(|index| index.unique && !index.primary && index.key_columns() == ["code"])
    );
    assert!(indexes.iter().any(|index| index.name == "parent_note" && !index.unique));
    let expression = indexes.iter().find(|index| index.name == "parent_lower").unwrap();
    assert!(
        matches!(&expression.keys[0], IndexKey::Expression { .. }),
        "{expression:?}"
    );
    assert_eq!(keys.len(), 1);
    assert_eq!(
        (keys[0].ref_table.as_str(), keys[0].columns.clone()),
        ("parent", vec!["parent_id".to_owned()])
    );
    assert_eq!(definition.inbound_foreign_keys.len(), 1);
    assert_eq!(definition.inbound_foreign_keys[0].table.name, "child");
    let source = definition.source.unwrap();
    assert!(source.create_statement.starts_with("CREATE TABLE parent"));
    assert_eq!(source.dependents.len(), 2, "{:?}", source.dependents);
    connection.close().await.unwrap();
}

/// An inbound key pairs its columns in declared order, and is read alone
/// as the definition lists it. DuckDB matches a key byte for byte, so a
/// column on either side declared with a collation finds other rows with
/// `=` than the key matches.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn inbound_keys_pair_their_columns_and_say_how_they_compare() {
    let file = TestFile::new();
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE customers (id INTEGER, region VARCHAR, code VARCHAR COLLATE NOCASE UNIQUE, \
             PRIMARY KEY (region, id))",
            "CREATE TABLE orders (id INTEGER PRIMARY KEY, buyer INTEGER, buyer_region VARCHAR, \
             FOREIGN KEY (buyer_region, buyer) REFERENCES customers (region, id))",
            "CREATE TABLE by_code (code VARCHAR REFERENCES customers (code))",
            "CREATE TABLE by_region (id INTEGER, \"Region\" VARCHAR COLLATE NOCASE, \
             FOREIGN KEY (\"Region\", id) REFERENCES customers (region, id))",
            "INSERT INTO customers VALUES (1, 'eu', 'ABC'), (1, 'EU', 'abc')",
            "INSERT INTO by_code VALUES ('abc')",
            "INSERT INTO by_region VALUES (1, 'EU')",
        ],
    )
    .await
    .unwrap();
    let customers = TableRef::unqualified("customers");

    let inbound = connection.fetch_inbound_foreign_keys(&customers, call()).await.unwrap();
    let definition = connection.fetch_table_definition(&customers, call()).await.unwrap();
    let by_region = query(
        connection.as_ref(),
        "SELECT count(*) FROM by_region WHERE \"Region\" = 'eu'",
    )
    .await;
    let by_code = query(connection.as_ref(), "SELECT count(*) FROM by_code WHERE code = 'ABC'").await;

    let keys: Vec<(String, Vec<String>, Vec<String>, bool)> = inbound
        .iter()
        .map(|key| {
            (
                key.table.name.clone(),
                key.columns.clone(),
                key.referenced_columns.clone(),
                key.child_compares_alike,
            )
        })
        .collect();
    let key = |table: &str, columns: &[&str], referenced: &[&str], alike: bool| {
        let owned = |names: &[&str]| names.iter().map(|name| (*name).to_owned()).collect::<Vec<_>>();
        (table.to_owned(), owned(columns), owned(referenced), alike)
    };
    assert_eq!(
        keys,
        [
            key("by_code", &["code"], &["code"], true),
            key("by_region", &["Region", "id"], &["region", "id"], false),
            key("orders", &["buyer_region", "buyer"], &["region", "id"], true),
        ]
    );
    assert_eq!(inbound[0].table.schema.as_deref(), Some("main"));
    assert_eq!(definition.inbound_foreign_keys, inbound);
    assert_eq!(
        by_region.rows,
        vec![vec![Value::Int(1)]],
        "the collated column finds a row the key does not point at"
    );
    assert_eq!(
        by_code.rows,
        vec![vec![Value::Int(0)]],
        "the plain column finds only the rows the key points at"
    );
    let mut outbound = Vec::new();
    for table in ["by_code", "by_region", "orders"] {
        let keys = connection
            .fetch_outbound_foreign_keys(&TableRef::unqualified(table), call())
            .await
            .unwrap();
        outbound.extend(keys.into_iter().map(|key| (table, key.parent_compares_alike)));
    }
    assert_eq!(
        outbound,
        [("by_code", false), ("by_region", true), ("orders", true)],
        "a key to a collated column finds other rows with `=` there than it matches"
    );
    for refused in [
        "INSERT INTO by_code VALUES ('aBc')",
        "CREATE TABLE by_wide_id (id BIGINT, region VARCHAR, FOREIGN KEY (region, id) REFERENCES customers (region, id))",
    ] {
        assert!(apply(connection.as_ref(), &[refused]).await.is_err(), "{refused}");
    }
    connection.close().await.unwrap();
}

/// A row is named by its key, or by a UNIQUE key over NOT NULL columns.
/// Without one the grid is read-only: DuckDB's rowid names no row, and
/// neither does a key over a collated column, which DuckDB keeps unique
/// byte for byte while `=` compares under the collation.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_row_is_named_by_a_key_and_never_by_rowid() {
    let file = TestFile::new();
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE keyed (id INTEGER PRIMARY KEY)",
            "CREATE TABLE coded (code VARCHAR NOT NULL UNIQUE, other VARCHAR UNIQUE)",
            "CREATE TABLE loose (a INTEGER UNIQUE)",
            "CREATE TABLE folded (code VARCHAR COLLATE NOCASE PRIMARY KEY, id INTEGER NOT NULL UNIQUE)",
            "CREATE TABLE folded_only (\"Code\" VARCHAR COLLATE NOCASE PRIMARY KEY)",
            "INSERT INTO folded_only VALUES ('ABC'), ('abc')",
        ],
    )
    .await
    .unwrap();
    let both = query(
        connection.as_ref(),
        "SELECT count(*) FROM folded_only WHERE \"Code\" = 'abc'",
    )
    .await;
    let mut identities = Vec::new();
    for name in ["keyed", "coded", "loose", "folded", "folded_only"] {
        identities.push(
            connection
                .row_identity(&TableRef::unqualified(name), call())
                .await
                .unwrap(),
        );
    }

    assert_eq!(
        identities,
        [
            RowIdentity::UniqueKey {
                columns: vec!["id".to_owned()]
            },
            RowIdentity::UniqueKey {
                columns: vec!["code".to_owned()]
            },
            RowIdentity::Unordered,
            RowIdentity::UniqueKey {
                columns: vec!["id".to_owned()]
            },
            RowIdentity::Unordered,
        ]
    );
    assert_eq!(both.rows, vec![vec![Value::Int(2)]]);
    connection.close().await.unwrap();
}

/// Why a table without a key is read-only: a checkpoint that compacts
/// row groups hands the rows new rowids.
/// `SET default_collation` in a tab reaches every connection to the
/// database, but the grid's reads keep comparing a key byte for byte, so
/// `'ABC'` and `'abc'` stay two rows to them.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_tabs_default_collation_leaves_the_grids_keys_alone() {
    let file = TestFile::new();
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE k (code VARCHAR PRIMARY KEY)",
            "INSERT INTO k VALUES ('ABC'), ('abc')",
        ],
    )
    .await
    .unwrap();
    let editor = session(connection.as_ref()).await;

    run(editor.as_ref(), "SET default_collation = 'nocase'").await;
    let (_, in_tab) = run(editor.as_ref(), "SELECT count(*) FROM k WHERE code = 'abc'").await;
    let in_grid = query(connection.as_ref(), "SELECT count(*) FROM k WHERE code = 'abc'").await;

    assert_eq!(in_tab.rows(), vec![vec![Value::Int(2)]], "the setting took");
    assert_eq!(in_grid.rows, vec![vec![Value::Int(1)]]);
    editor.close().await;
    connection.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_rowid_moves_when_a_checkpoint_compacts_the_table() {
    let file = TestFile::new();
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE k (a INTEGER)",
            "INSERT INTO k SELECT range FROM range(400000)",
        ],
    )
    .await
    .unwrap();
    let editor = session(connection.as_ref()).await;
    run(editor.as_ref(), "CHECKPOINT").await;
    let before = query(connection.as_ref(), "SELECT rowid FROM k WHERE a = 390000").await;

    // Enough deletes that a checkpoint compacts the table in both storage
    // formats: DuckDB 2.0's own leaves a lighter delete where it was.
    run(
        editor.as_ref(),
        "DELETE FROM k WHERE a < 390000 AND a % 1000 <> 0; CHECKPOINT",
    )
    .await;
    let after = query(connection.as_ref(), "SELECT rowid FROM k WHERE a = 390000").await;

    assert_eq!(before.rows, vec![vec![Value::Int(390_000)]]);
    assert_ne!(
        after.rows, before.rows,
        "the rowid stayed, so it may name a row after all"
    );
    editor.close().await;
    connection.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_estimate_is_the_storage_count() {
    let file = TestFile::new();
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE t (a INTEGER)",
            "INSERT INTO t SELECT range FROM range(1234)",
        ],
    )
    .await
    .unwrap();

    let estimate = connection
        .table_estimate(&TableRef::unqualified("t"), call())
        .await
        .unwrap();

    assert_eq!(estimate.rows, RowCountEstimate::Approximate(1234));
    connection.close().await.unwrap();
}

/// A schema can share its name with the file's catalogue, and DuckDB
/// refuses `"test"."t"` as ambiguous then, so the app names a table with
/// the catalogue as well, and its structure changes run.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_schema_named_like_the_file_is_read_and_changed() {
    let file = TestFile::new();
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE SCHEMA test",
            "CREATE TABLE test.test.t (id INTEGER PRIMARY KEY, a INTEGER)",
            "INSERT INTO test.test.t VALUES (1, 2)",
        ],
    )
    .await
    .unwrap();
    let dialect = connection.dialect();
    let table = TableRef::new(Some("test".to_owned()), "t");
    let original = connection.fetch_table_definition(&table, call()).await.unwrap();
    let mut changed = tablepro_core::ddl::TableDraft::from_definition(&original);
    changed.columns.push(tablepro_core::ddl::DraftColumn::new(
        "b",
        tablepro_core::ddl::DraftType::Typed("INTEGER".to_owned()),
    ));

    let read = query(
        connection.as_ref(),
        &format!("SELECT a FROM {}", dialect.qualify(&table)),
    )
    .await;
    let plan = dialect
        .ddl()
        .unwrap()
        .plan_alter_table(&original, &tablepro_core::ddl::diff_table(&original, &changed))
        .unwrap();
    connection
        .write_batch(&plan.into_write_batch(table.clone()), call())
        .await
        .unwrap();
    let columns = connection.fetch_columns(&table, call()).await.unwrap();

    assert_eq!(read.rows, vec![vec![Value::Int(2)]]);
    assert_eq!(columns.len(), 3);
    assert_eq!(dialect.portable_name(&table), "\"test\".\"t\"");
    connection.close().await.unwrap();
}
