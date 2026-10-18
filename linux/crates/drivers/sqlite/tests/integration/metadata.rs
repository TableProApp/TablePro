//! The catalogue as the sidebar, the grid and the structure tab read it.

use tablepro_core::ddl::{IdentityStyle, ReferentialAction};
use tablepro_core::meta::{
    EngineRowId, IndexInfo, IndexKey, ObjectKind, ObjectScope, RowCountEstimate, RowIdentity, TableRef,
};
use tablepro_core::{Connection, RowLimit, Value};

use crate::support::{TestFile, apply, call, create_database, query, statement};

fn table(name: &str) -> TableRef {
    TableRef::unqualified(name)
}

async fn index(connection: &dyn Connection, table_name: &str, name: &str) -> IndexInfo {
    connection
        .fetch_indexes(&table(table_name), call())
        .await
        .unwrap()
        .into_iter()
        .find(|index| index.name == name)
        .unwrap()
}

#[tokio::test]
async fn expression_desc_partial_index_keys() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE t (a TEXT, \"b,c\" INTEGER)",
            "CREATE INDEX i ON t (substr(a, 1, 3), \"b,c\" DESC) WHERE a <> 'x,y'",
        ],
    )
    .await
    .unwrap();

    let index = index(connection.as_ref(), "t", "i").await;

    assert_eq!(
        index.keys,
        [
            IndexKey::Expression {
                sql: "substr(a, 1, 3)".to_owned(),
                descending: false
            },
            IndexKey::Column {
                name: "b,c".to_owned(),
                descending: true
            },
        ]
    );
    assert_eq!(index.predicate.as_deref(), Some("a <> 'x,y'"));
    assert!(!index.unique && !index.primary);
    connection.close().await.unwrap();
}

#[tokio::test]
async fn views_listed_and_attached_schema_listed() {
    let file = TestFile::new().await;
    let other = file.directory().join("other.sqlite3");
    create_database(&other).await.unwrap();
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE people (id INTEGER PRIMARY KEY)",
            "CREATE VIEW everyone AS SELECT * FROM people",
        ],
    )
    .await
    .unwrap();
    let attach = format!("ATTACH DATABASE '{}' AS archive", other.display());
    connection
        .query_bound(&statement(&attach), RowLimit::EDITOR_DEFAULT, call())
        .await
        .unwrap();
    query(connection.as_ref(), "CREATE TABLE archive.old_people (id INTEGER)").await;

    let schemas = connection.list_schemas(call()).await.unwrap();
    let main_objects = connection
        .list_objects(&ObjectScope::DefaultSchema, call())
        .await
        .unwrap();
    let archived = connection
        .list_objects(&ObjectScope::Schema("archive".to_owned()), call())
        .await
        .unwrap();

    let names: Vec<(&str, bool)> = schemas
        .iter()
        .map(|schema| (schema.name.as_str(), schema.is_default))
        .collect();
    assert_eq!(names, [("main", true), ("archive", false)]);
    let listed: Vec<(&str, ObjectKind)> = main_objects
        .iter()
        .map(|object| (object.name.as_str(), object.kind))
        .collect();
    assert_eq!(listed, [("everyone", ObjectKind::View), ("people", ObjectKind::Table)]);
    assert!(main_objects.iter().all(|object| object.schema.is_none()));
    assert_eq!(archived.len(), 1);
    assert_eq!(archived[0].schema.as_deref(), Some("archive"));
    let archived_columns = connection
        .fetch_columns(&TableRef::new(Some("archive".to_owned()), "old_people"), call())
        .await
        .unwrap();
    assert_eq!(archived_columns.len(), 1);
    connection.close().await.unwrap();
}

#[tokio::test]
async fn rowid_identity_for_keyless_table() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE loose (a TEXT, b TEXT)",
            "CREATE VIEW loose_view AS SELECT * FROM loose",
            "CREATE TABLE shadowed (rowid TEXT, b TEXT)",
        ],
    )
    .await
    .unwrap();

    let identity = connection.row_identity(&table("loose"), call()).await.unwrap();
    let view = connection.row_identity(&table("loose_view"), call()).await.unwrap();
    let shadowed = connection.row_identity(&table("shadowed"), call()).await.unwrap();

    assert_eq!(identity, RowIdentity::EngineRowId(EngineRowId::SqliteRowid));
    assert_eq!(view, RowIdentity::Unordered, "a view has no rowid");
    assert_eq!(shadowed, RowIdentity::Unordered, "a column named rowid hides the rowid");
    connection.close().await.unwrap();
}

#[tokio::test]
async fn a_unique_index_over_not_null_columns_identifies_rows() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE codes (code TEXT NOT NULL, region TEXT NOT NULL, note TEXT)",
            "CREATE UNIQUE INDEX codes_partial ON codes (note) WHERE note IS NOT NULL",
            "CREATE UNIQUE INDEX codes_key ON codes (region, code)",
        ],
    )
    .await
    .unwrap();

    let identity = connection.row_identity(&table("codes"), call()).await.unwrap();

    assert_eq!(
        identity,
        RowIdentity::UniqueKey {
            columns: vec!["region".to_owned(), "code".to_owned()]
        }
    );
    connection.close().await.unwrap();
}

#[tokio::test]
async fn autoincrement_detected_via_sqlite_sequence() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)",
            "INSERT INTO t (name) VALUES ('a')",
        ],
    )
    .await
    .unwrap();

    let columns = connection.fetch_columns(&table("t"), call()).await.unwrap();

    assert!(columns[0].is_auto_increment, "the AUTOINCREMENT id was not flagged");
    assert!(!columns[1].is_auto_increment);
    connection.close().await.unwrap();
}

#[tokio::test]
async fn integer_primary_key_no_autoincrement_is_rowid_alias() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &["CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"],
    )
    .await
    .unwrap();

    let columns = connection.fetch_columns(&table("t"), call()).await.unwrap();
    let indexes = connection.fetch_indexes(&table("t"), call()).await.unwrap();

    assert!(columns[0].is_auto_increment);
    assert!(columns[0].primary_key);
    let primary: Vec<&IndexInfo> = indexes.iter().filter(|index| index.primary).collect();
    assert_eq!(primary.len(), 1, "the rowid key has no index, so one is shown for it");
    assert_eq!(primary[0].key_columns(), ["id"]);
    connection.close().await.unwrap();
}

#[tokio::test]
async fn integer_primary_key_with_default_is_not_auto_increment() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &["CREATE TABLE t (id INTEGER PRIMARY KEY DEFAULT 0, name TEXT)"],
    )
    .await
    .unwrap();

    let columns = connection.fetch_columns(&table("t"), call()).await.unwrap();

    assert!(!columns[0].is_auto_increment);
    connection.close().await.unwrap();
}

/// SQLite stores NULL in a key it does not number, which shows the
/// column is not the rowid. DESC in a table PRIMARY KEY keeps the alias.
#[tokio::test]
async fn integer_primary_key_desc_on_the_column_is_not_the_rowid() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE t (id INTEGER PRIMARY KEY DESC, name TEXT)",
            "CREATE TABLE u (id INTEGER, name TEXT, PRIMARY KEY (id DESC))",
            "INSERT INTO t (name) VALUES ('a')",
            "INSERT INTO u (name) VALUES ('a')",
        ],
    )
    .await
    .unwrap();

    let descending = connection.fetch_table_definition(&table("t"), call()).await.unwrap();
    let table_key = connection.fetch_table_definition(&table("u"), call()).await.unwrap();
    let stored = query(connection.as_ref(), "SELECT (SELECT id FROM t), (SELECT id FROM u)").await;

    assert_eq!(stored.rows[0], [Value::Null, Value::Int(1)]);
    let id = &descending.columns[0];
    assert!(
        !id.info.is_auto_increment,
        "PRIMARY KEY DESC was read as numbering itself"
    );
    assert_eq!(id.attributes.identity, IdentityStyle::None);
    assert!(id.info.primary_key);
    let alias = &table_key.columns[0];
    assert!(alias.info.is_auto_increment);
    assert_eq!(alias.attributes.identity, IdentityStyle::SqliteRowidAlias);
    connection.close().await.unwrap();
}

#[tokio::test]
async fn composite_primary_key_no_auto_increment() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &["CREATE TABLE t (a INTEGER, b TEXT, PRIMARY KEY (a, b))"],
    )
    .await
    .unwrap();

    let columns = connection.fetch_columns(&table("t"), call()).await.unwrap();
    let identity = connection.row_identity(&table("t"), call()).await.unwrap();

    assert!(!columns[0].is_auto_increment);
    assert!(!columns[1].is_auto_increment);
    assert_eq!(
        identity,
        RowIdentity::UniqueKey {
            columns: vec!["a".to_owned(), "b".to_owned()]
        }
    );
    connection.close().await.unwrap();
}

#[tokio::test]
async fn column_named_autoincrement_substring_is_not_flagged() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &["CREATE TABLE t (id INTEGER PRIMARY KEY, autoincrementflag INTEGER)"],
    )
    .await
    .unwrap();

    let columns = connection.fetch_columns(&table("t"), call()).await.unwrap();

    assert!(columns[0].is_auto_increment, "id is INTEGER PRIMARY KEY, the rowid");
    assert!(!columns[1].is_auto_increment);
    connection.close().await.unwrap();
}

#[tokio::test]
async fn a_table_with_an_embedded_quote_in_its_name_reads() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE \"weird\"\"name\" (i INTEGER)",
            "INSERT INTO \"weird\"\"name\" VALUES (1), (2)",
        ],
    )
    .await
    .unwrap();

    let columns = connection.fetch_columns(&table("weird\"name"), call()).await.unwrap();
    let dialect = connection.dialect();
    let rows = query(
        connection.as_ref(),
        &format!("SELECT * FROM {}", dialect.qualify(&table("weird\"name"))),
    )
    .await;

    assert_eq!(columns.len(), 1);
    assert_eq!(rows.rows.len(), 2);
    connection.close().await.unwrap();
}

#[tokio::test]
async fn foreign_keys_read_with_their_actions_and_implied_parent_key() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE people (id INTEGER PRIMARY KEY)",
            "CREATE TABLE orders (id INTEGER PRIMARY KEY, person INTEGER REFERENCES people ON DELETE CASCADE)",
        ],
    )
    .await
    .unwrap();

    let keys = connection.fetch_foreign_keys(&table("orders"), call()).await.unwrap();

    assert_eq!(keys.len(), 1);
    assert_eq!(keys[0].ref_table, "people");
    assert_eq!(keys[0].columns, ["person"]);
    assert_eq!(
        keys[0].ref_columns,
        ["id"],
        "a key naming no column points at the primary key"
    );
    assert_eq!(keys[0].on_delete, Some(ReferentialAction::Cascade));
    assert_eq!(keys[0].on_update, Some(ReferentialAction::NoAction));
    connection.close().await.unwrap();
}

#[tokio::test]
async fn table_estimate_reads_sqlite_stat1() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE t (a INTEGER)",
            "CREATE INDEX t_a ON t (a)",
            "INSERT INTO t SELECT value FROM json_each('[1,2,3,4,5]')",
        ],
    )
    .await
    .unwrap();
    let before = connection.table_estimate(&table("t"), call()).await.unwrap();
    apply(connection.as_ref(), &["ANALYZE"]).await.unwrap();

    let after = connection.table_estimate(&table("t"), call()).await.unwrap();

    assert_eq!(before.rows, RowCountEstimate::Unknown);
    assert_eq!(after.rows, RowCountEstimate::Approximate(5));
    connection.close().await.unwrap();
}

#[tokio::test]
async fn a_missing_table_is_an_error_not_an_empty_list() {
    let file = TestFile::new().await;
    let connection = file.open().await;

    let columns = connection.fetch_columns(&table("nowhere"), call()).await;

    assert!(columns.is_err(), "{columns:?}");
    let count = query(connection.as_ref(), "SELECT count(*) FROM sqlite_schema").await;
    assert_eq!(count.rows[0][0], Value::Int(0));
    connection.close().await.unwrap();
}
