#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use std::sync::Arc;
use std::time::Duration;

use drivers_sqlite::SqliteDriver;
use tablepro_core::{ConnectOptions, Connection, DatabaseDriver, DriverError, OperationControl, Value};
use tempfile::TempDir;
use tokio_util::sync::CancellationToken;

fn options_for(path: &str) -> ConnectOptions {
    ConnectOptions {
        database: path.to_string(),
        ..Default::default()
    }
}

async fn connect_file(directory: &TempDir) -> Arc<dyn Connection> {
    let path = directory.path().join("cancel.db");
    let path = path.to_string_lossy().to_string();
    SqliteDriver
        .connect(options_for(&path))
        .await
        .expect("connect to the sqlite file")
        .into()
}

/// A recursive CTE counting to a large bound is pure computation, so it
/// runs long enough to be interrupted and reports `SQLITE_INTERRUPT`
/// when it is.
const LONG_QUERY: &str = "WITH RECURSIVE counter(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM counter WHERE x < 400000000) \
     SELECT count(*) FROM counter";

#[tokio::test]
async fn nullable_blob_columns_distinguish_null_empty_and_binary_values() {
    let directory = TempDir::new().expect("temp dir");
    let connection = connect_file(&directory).await;
    connection
        .execute("CREATE TABLE blobs (id INTEGER PRIMARY KEY, payload BLOB)")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO blobs VALUES (1, NULL), (2, X''), (3, X'00ff41')")
        .await
        .unwrap();
    let expected = vec![
        vec![Value::Null],
        vec![Value::Bytes(vec![])],
        vec![Value::Bytes(vec![0, 255, 65])],
    ];
    let query = connection.query("SELECT payload FROM blobs ORDER BY id").await.unwrap();
    assert_eq!(query.rows, expected);
    let control = OperationControl::with_timeout(Duration::from_secs(5));
    let bound = connection
        .query_params_controlled(
            "SELECT payload FROM blobs WHERE id > ? ORDER BY id",
            &[Value::Int(0)],
            &control,
        )
        .await
        .unwrap();
    assert_eq!(bound.rows, expected);
}

#[tokio::test]
async fn direct_query_columns_recover_declared_strict_any_metadata() {
    let connection = SqliteDriver.connect(options_for(":memory:")).await.unwrap();
    connection
        .execute("CREATE TABLE flexible (id INTEGER PRIMARY KEY, value ANY) STRICT")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO flexible VALUES (1, 42), (2, NULL), (3, 'ready')")
        .await
        .unwrap();

    let typed = connection
        .query("SELECT value AS result FROM flexible WHERE id = 1")
        .await
        .unwrap();
    assert_eq!(typed.columns[0].data_type, "ANY");
    assert_eq!(typed.rows, vec![vec![Value::Int(42)]]);
    let empty = connection
        .query("SELECT value AS result FROM flexible WHERE id = 99")
        .await
        .unwrap();
    assert_eq!(empty.columns[0].name, "result");
    assert_eq!(empty.columns[0].data_type, "ANY");
    assert!(empty.rows.is_empty());
    let nullable = connection
        .query_params("SELECT value AS result FROM flexible WHERE id = ?", &[Value::Int(2)])
        .await
        .unwrap();
    assert_eq!(nullable.columns[0].data_type, "ANY");
    assert_eq!(nullable.rows, vec![vec![Value::Null]]);
    let empty_bound = connection
        .query_params("SELECT value AS result FROM flexible WHERE id = ?", &[Value::Int(99)])
        .await
        .unwrap();
    assert_eq!(empty_bound.columns[0].data_type, "ANY");
    assert!(empty_bound.rows.is_empty());

    let expression = connection
        .query("SELECT value + 1 AS result FROM flexible WHERE id = 1")
        .await
        .unwrap();
    assert_ne!(expression.columns[0].data_type, "ANY");
    assert_eq!(expression.rows, vec![vec![Value::Int(43)]]);

    let mixed_expression = connection
        .query(
            "SELECT CASE WHEN id = 1 THEN value WHEN id = 2 THEN NULL ELSE 'ready' END AS result, \
                    typeof(CASE WHEN id = 1 THEN value WHEN id = 2 THEN NULL ELSE 'ready' END) AS storage_class \
             FROM flexible ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(mixed_expression.columns[0].data_type, "NULL");
    assert_eq!(
        mixed_expression.rows,
        vec![
            vec![Value::Int(42), Value::Text("integer".into())],
            vec![Value::Null, Value::Text("null".into())],
            vec![Value::Text("ready".into()), Value::Text("text".into())]
        ]
    );

    let empty_expression = connection
        .query("SELECT value + 1 AS result FROM flexible WHERE id = 99")
        .await
        .unwrap();
    assert_eq!(empty_expression.columns[0].data_type, "NULL");
    assert!(empty_expression.rows.is_empty());

    let bound_expression = connection
        .query_params(
            "SELECT CASE WHEN id = 1 THEN value WHEN id = 2 THEN NULL ELSE 'ready' END AS result, \
                    typeof(CASE WHEN id = 1 THEN value WHEN id = 2 THEN NULL ELSE 'ready' END) AS storage_class \
             FROM flexible WHERE id > ? ORDER BY id",
            &[Value::Int(0)],
        )
        .await
        .unwrap();
    assert_eq!(bound_expression.columns[0].data_type, "NULL");
    assert_eq!(bound_expression.rows, mixed_expression.rows);

    let mut transaction = connection.begin().await.unwrap();
    let result = transaction
        .query("SELECT value AS result FROM flexible WHERE id = 1")
        .await
        .unwrap();
    assert_eq!(result.columns[0].data_type, "ANY");
    assert_eq!(result.rows, vec![vec![Value::Int(42)]]);
    let empty = transaction
        .query("SELECT value AS result FROM flexible WHERE id = 99")
        .await
        .unwrap();
    assert_eq!(empty.columns[0].data_type, "ANY");
    assert!(empty.rows.is_empty());
    let expression = transaction
        .query("SELECT value + 1 AS result FROM flexible WHERE id = 99")
        .await
        .unwrap();
    assert_eq!(expression.columns[0].data_type, "NULL");
    assert!(expression.rows.is_empty());
    transaction.rollback().await.unwrap();
}

#[tokio::test]
async fn transaction_query_obeys_result_budget_and_remains_usable() {
    let connection = SqliteDriver.connect(options_for(":memory:")).await.unwrap();
    let mut transaction = connection.begin().await.unwrap();
    let payload = format!("{:>4096}", "x");
    let result = transaction
        .query(
            "WITH RECURSIVE rows(id) AS (\
                 SELECT 1 UNION ALL SELECT id + 1 FROM rows WHERE id < 20000\
             ) SELECT id, printf('%4096s', 'x') AS payload FROM rows ORDER BY id",
        )
        .await
        .unwrap();

    assert!(result.truncated, "omitted rows must be reported");
    assert!(!result.rows.is_empty());
    assert!(result.rows.len() < 20_000);
    assert!(result.rows.len() * payload.len() <= tablepro_core::MAX_QUERY_RESULT_BYTES);
    assert!(result.rows.iter().enumerate().all(|(index, row)| {
        row.first() == Some(&Value::Int(index as i64 + 1))
            && matches!(row.get(1), Some(Value::Text(value)) if value == &payload)
    }));

    let next = transaction.query("SELECT 42 AS usable").await.unwrap();
    assert_eq!(next.rows, vec![vec![Value::Int(42)]]);
    transaction.rollback().await.unwrap();
}

#[tokio::test]
async fn computed_coalesce_over_strict_any_keeps_fallback_metadata_and_storage_classes() {
    let connection = SqliteDriver.connect(options_for(":memory:")).await.unwrap();
    connection
        .execute("CREATE TABLE flexible (id INTEGER PRIMARY KEY, value ANY) STRICT")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO flexible VALUES (1, 42), (2, NULL), (3, 'ready')")
        .await
        .unwrap();

    let sql = "SELECT coalesce(value, 'fallback') AS result, \
                      typeof(coalesce(value, 'fallback')) AS storage_class \
               FROM flexible ORDER BY id";
    let expected = vec![
        vec![Value::Int(42), Value::Text("integer".into())],
        vec![Value::Text("fallback".into()), Value::Text("text".into())],
        vec![Value::Text("ready".into()), Value::Text("text".into())],
    ];

    let result = connection.query(sql).await.unwrap();
    assert_eq!(result.columns[0].data_type, "NULL");
    assert_eq!(result.rows, expected);

    let bound = connection
        .query_params(
            "SELECT coalesce(value, 'fallback') AS result, \
                    typeof(coalesce(value, 'fallback')) AS storage_class \
             FROM flexible WHERE id > ? ORDER BY id",
            &[Value::Int(0)],
        )
        .await
        .unwrap();
    assert_eq!(bound.columns[0].data_type, "NULL");
    assert_eq!(bound.rows, expected);
}

#[tokio::test]
async fn compound_union_over_strict_any_keeps_fallback_metadata_and_storage_classes() {
    let connection = SqliteDriver.connect(options_for(":memory:")).await.unwrap();
    connection
        .execute("CREATE TABLE flexible (id INTEGER PRIMARY KEY, value ANY) STRICT")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO flexible VALUES (1, 42), (2, NULL), (3, 'ready')")
        .await
        .unwrap();

    let expected = vec![
        vec![Value::Int(1), Value::Int(42), Value::Text("integer".into())],
        vec![Value::Int(2), Value::Text("branch".into()), Value::Text("text".into())],
        vec![Value::Int(3), Value::Null, Value::Text("null".into())],
    ];
    for sql in [
        "SELECT 1 AS position, value AS result, typeof(value) AS storage_class \
         FROM flexible WHERE id = 1 \
         UNION ALL SELECT 2, 'branch', typeof('branch') \
         UNION ALL SELECT 3, value, typeof(value) FROM flexible WHERE id = 2 \
         ORDER BY position",
        "WITH combined AS ( \
             SELECT 1 AS position, value AS result, typeof(value) AS storage_class \
             FROM flexible WHERE id = 1 \
             UNION ALL SELECT 2, 'branch', typeof('branch') \
             UNION ALL SELECT 3, value, typeof(value) FROM flexible WHERE id = 2 \
         ) SELECT position, result, storage_class FROM combined ORDER BY position",
        "SELECT position, result, storage_class FROM ( \
             SELECT 1 AS position, value AS result, typeof(value) AS storage_class \
             FROM flexible WHERE id = 1 \
             UNION ALL SELECT 2, 'branch', typeof('branch') \
             UNION ALL SELECT 3, value, typeof(value) FROM flexible WHERE id = 2 \
         ) AS combined ORDER BY position",
    ] {
        let result = connection.query(sql).await.unwrap();
        assert_eq!(result.columns[1].data_type, "NULL", "{sql}");
        assert_eq!(result.rows, expected, "{sql}");
    }

    let direct = connection
        .query("SELECT value FROM flexible WHERE id IN (SELECT 1 UNION ALL SELECT 99)")
        .await
        .unwrap();
    assert_eq!(direct.columns[0].data_type, "ANY");
    assert_eq!(direct.rows, vec![vec![Value::Int(42)]]);

    let bound = connection
        .query_params(
            "SELECT 1 AS position, value AS result, typeof(value) AS storage_class \
             FROM flexible WHERE id = ? \
             UNION ALL SELECT 2, 'branch', typeof('branch') \
             UNION ALL SELECT 3, value, typeof(value) FROM flexible WHERE id = 2 \
             ORDER BY position",
            &[Value::Int(1)],
        )
        .await
        .unwrap();
    assert_eq!(bound.columns[1].data_type, "NULL");
    assert_eq!(bound.rows, expected);

    let mut transaction = connection.begin().await.unwrap();
    let transactional = transaction
        .query(
            "SELECT 1 AS position, value AS result, typeof(value) AS storage_class \
             FROM flexible WHERE id = 1 \
             UNION ALL SELECT 2, 'branch', typeof('branch') \
             UNION ALL SELECT 3, value, typeof(value) FROM flexible WHERE id = 2 \
             ORDER BY position",
        )
        .await
        .unwrap();
    assert_eq!(transactional.columns[1].data_type, "NULL");
    assert_eq!(transactional.rows, expected);
    transaction.rollback().await.unwrap();
}

#[tokio::test]
async fn direct_query_columns_resolve_unambiguous_attached_any_origins() {
    let connection = SqliteDriver.connect(options_for(":memory:")).await.unwrap();
    let mut transaction = connection.begin().await.unwrap();
    transaction.execute("ATTACH DATABASE ':memory:' AS aux").await.unwrap();
    transaction
        .execute("CREATE TABLE aux.flexible (value ANY) STRICT")
        .await
        .unwrap();
    transaction
        .execute("INSERT INTO aux.flexible VALUES ('attached')")
        .await
        .unwrap();

    let attached = transaction.query("SELECT value FROM aux.flexible").await.unwrap();
    assert_eq!(attached.columns[0].data_type, "ANY");
    assert_eq!(attached.rows, vec![vec![Value::Text("attached".into())]]);

    transaction
        .execute("CREATE TABLE \"aux.flexible\" (value ANY) STRICT")
        .await
        .unwrap();
    transaction
        .execute("INSERT INTO \"aux.flexible\" VALUES (42)")
        .await
        .unwrap();
    let ambiguous_attached = transaction.query("SELECT value FROM aux.flexible").await.unwrap();
    assert_eq!(ambiguous_attached.columns[0].data_type, "NULL");
    assert_eq!(ambiguous_attached.rows, vec![vec![Value::Text("attached".into())]]);

    let ambiguous_main = transaction.query("SELECT value FROM \"aux.flexible\"").await.unwrap();
    assert_eq!(ambiguous_main.columns[0].data_type, "NULL");
    assert_eq!(ambiguous_main.rows, vec![vec![Value::Int(42)]]);
    transaction.rollback().await.unwrap();
}

#[tokio::test]
async fn declared_types_preserve_nulls_and_binary_affinity_mismatches() {
    let directory = TempDir::new().expect("temp dir");
    let connection = connect_file(&directory).await;
    connection
        .execute("CREATE TABLE typed (i INTEGER, r REAL, b BOOLEAN, d DATE, t TIME, dt DATETIME, payload BLOB)")
        .await
        .unwrap();
    connection.execute("INSERT INTO typed DEFAULT VALUES").await.unwrap();
    connection.execute("UPDATE typed SET r = X'00ff41'").await.unwrap();
    connection
        .execute(
            "INSERT INTO typed VALUES \
             ('not-an-integer', X'00ff41', X'0102', 'not-a-date', \
              'not-a-time', 'not-a-datetime', 'text-in-blob')",
        )
        .await
        .unwrap();
    connection
        .execute("INSERT INTO typed (payload) VALUES (42), (2.5)")
        .await
        .unwrap();
    let result = connection.query("SELECT * FROM typed ORDER BY rowid").await.unwrap();
    assert_eq!(
        result.rows,
        vec![
            vec![
                Value::Null,
                Value::Bytes(vec![0, 255, 65]),
                Value::Null,
                Value::Null,
                Value::Null,
                Value::Null,
                Value::Null,
            ],
            vec![
                Value::Text("not-an-integer".into()),
                Value::Bytes(vec![0, 255, 65]),
                Value::Bytes(vec![1, 2]),
                Value::Text("not-a-date".into()),
                Value::Text("not-a-time".into()),
                Value::Text("not-a-datetime".into()),
                Value::Text("text-in-blob".into()),
            ],
            vec![
                Value::Null,
                Value::Null,
                Value::Null,
                Value::Null,
                Value::Null,
                Value::Null,
                Value::Int(42)
            ],
            vec![
                Value::Null,
                Value::Null,
                Value::Null,
                Value::Null,
                Value::Null,
                Value::Null,
                Value::Float(2.5),
            ],
        ]
    );
    let runtime_classes = connection
        .query(
            "SELECT typeof(i), typeof(r), typeof(b), typeof(d), typeof(t), \
             typeof(dt), typeof(payload) FROM typed ORDER BY rowid",
        )
        .await
        .unwrap();
    assert_eq!(
        runtime_classes.rows,
        vec![
            ["null", "blob", "null", "null", "null", "null", "null"]
                .map(|kind| Value::Text(kind.into()))
                .to_vec(),
            ["text", "blob", "blob", "text", "text", "text", "text"]
                .map(|kind| Value::Text(kind.into()))
                .to_vec(),
            ["null", "null", "null", "null", "null", "null", "integer"]
                .map(|kind| Value::Text(kind.into()))
                .to_vec(),
            ["null", "null", "null", "null", "null", "null", "real"]
                .map(|kind| Value::Text(kind.into()))
                .to_vec(),
        ]
    );
}

#[tokio::test]
async fn sqlite_numeric_affinity_transitions_survive_bound_edits_and_sql_reimport() {
    let directory = TempDir::new().expect("temp dir");
    let connection = connect_file(&directory).await;
    connection
        .execute("CREATE TABLE flexible (id INTEGER PRIMARY KEY, value NUMERIC)")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO flexible VALUES (1, 'not-a-number'), (2, X'00ff41'), (3, NULL)")
        .await
        .unwrap();

    let initial = connection
        .query("SELECT typeof(value), value FROM flexible ORDER BY id")
        .await
        .unwrap();
    assert_eq!(
        initial.rows,
        vec![
            vec![Value::Text("text".into()), Value::Text("not-a-number".into())],
            vec![Value::Text("blob".into()), Value::Bytes(vec![0, 255, 65])],
            vec![Value::Text("null".into()), Value::Null],
        ]
    );

    connection
        .execute_params(
            "UPDATE flexible SET value = ? WHERE id = ?",
            &[Value::Text("42.50".into()), Value::Int(1)],
        )
        .await
        .unwrap();
    let numeric = connection
        .query("SELECT typeof(value), value FROM flexible WHERE id = 1")
        .await
        .unwrap();
    assert_eq!(numeric.rows, vec![vec![Value::Text("real".into()), Value::Float(42.5)]]);

    for (id, value) in [
        (1, Value::Bytes(vec![0, 255, 65])),
        (2, Value::Text("still-not-a-number".into())),
        (3, Value::Text("17".into())),
    ] {
        connection
            .execute_params("UPDATE flexible SET value = ? WHERE id = ?", &[value, Value::Int(id)])
            .await
            .unwrap();
    }
    let expected = vec![
        vec![Value::Text("blob".into()), Value::Bytes(vec![0, 255, 65])],
        vec![Value::Text("text".into()), Value::Text("still-not-a-number".into())],
        vec![Value::Text("integer".into()), Value::Int(17)],
    ];
    let edited = connection
        .query("SELECT typeof(value), value FROM flexible ORDER BY id")
        .await
        .unwrap();
    assert_eq!(edited.rows, expected);

    connection
        .execute("CREATE TABLE flexible_copy (id INTEGER PRIMARY KEY, value NUMERIC)")
        .await
        .unwrap();
    let columns = connection.fetch_columns(None, "flexible_copy").await.unwrap();
    for row in &connection
        .query("SELECT id, value FROM flexible ORDER BY id")
        .await
        .unwrap()
        .rows
    {
        let statement =
            tablepro_core::sql_literal::build_insert_literal("sqlite", None, "flexible_copy", &columns, row).unwrap();
        connection.execute(&statement).await.unwrap();
    }
    let imported = connection
        .query("SELECT typeof(value), value FROM flexible_copy ORDER BY id")
        .await
        .unwrap();
    assert_eq!(
        imported.rows, expected,
        "SQL export/re-import must preserve SQLite storage classes"
    );
}

#[tokio::test]
async fn undecodable_parameter_is_rejected_without_writing_null() {
    let directory = TempDir::new().expect("temp dir");
    let connection = connect_file(&directory).await;
    connection
        .execute("CREATE TABLE values_to_keep (value INTEGER)")
        .await
        .unwrap();

    let error = connection
        .execute_params(
            "INSERT INTO values_to_keep VALUES (?)",
            &[Value::Undecodable("NUMERIC".into())],
        )
        .await
        .expect_err("an undecodable result cell cannot be written as NULL");
    assert!(matches!(error, DriverError::Unsupported(_)));

    let statements = vec![
        ("INSERT INTO values_to_keep VALUES (?)".into(), vec![Value::Int(7)]),
        (
            "INSERT INTO values_to_keep VALUES (?)".into(),
            vec![Value::Undecodable("NUMERIC".into())],
        ),
    ];
    let error = connection
        .execute_in_transaction(&statements)
        .await
        .expect_err("the transaction must reject the undecodable value");
    assert!(matches!(
        error,
        DriverError::Transaction {
            statement_index: 1,
            source,
        } if matches!(*source, DriverError::Unsupported(_))
    ));
    let rows = connection.query("SELECT count(*) FROM values_to_keep").await.unwrap();
    assert_eq!(rows.rows, vec![vec![Value::Int(0)]]);
}

#[tokio::test(flavor = "multi_thread")]
async fn the_driver_declares_server_side_cancellation() {
    let directory = TempDir::new().expect("temp dir");
    let connection = connect_file(&directory).await;
    assert!(connection.supports_server_cancellation());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_cancelled_query_is_interrupted_and_the_pool_stays_usable() {
    let directory = TempDir::new().expect("temp dir");
    let connection = connect_file(&directory).await;

    let token = CancellationToken::new();
    let control = OperationControl::new(token.clone(), None);
    let operation_connection = connection.clone();
    let task = tokio::spawn(async move { operation_connection.query_controlled(LONG_QUERY, &control).await });

    tokio::time::sleep(Duration::from_millis(300)).await;
    token.cancel();
    let error = task
        .await
        .expect("query task")
        .expect_err("the query must be cancelled");
    assert!(matches!(error, DriverError::Cancelled), "unexpected error: {error:?}");

    let result = connection.query("SELECT 1").await.expect("the pool remains usable");
    assert_eq!(result.rows, vec![vec![Value::Int(1)]]);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_timed_out_write_is_interrupted_and_reports_a_timeout() {
    let directory = TempDir::new().expect("temp dir");
    let connection = connect_file(&directory).await;
    connection
        .execute("CREATE TABLE sink (total integer)")
        .await
        .expect("create the sink table");

    let deadline = tokio::time::Instant::now() + Duration::from_millis(400);
    let control = OperationControl::new(CancellationToken::new(), Some(deadline));
    let sql = format!("INSERT INTO sink (total) {LONG_QUERY}");
    let operation_connection = connection.clone();
    let task = tokio::spawn(async move { operation_connection.execute_controlled(&sql, &control).await });

    let error = task.await.expect("execute task").expect_err("the write must time out");
    assert!(matches!(error, DriverError::TimedOut), "unexpected error: {error:?}");

    let rows = connection
        .query("SELECT count(*) FROM sink")
        .await
        .expect("the pool remains usable");
    assert_eq!(
        rows.rows,
        vec![vec![Value::Int(0)]],
        "the aborted insert must not commit"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_completed_query_is_unaffected_by_the_control() {
    let directory = TempDir::new().expect("temp dir");
    let connection = connect_file(&directory).await;
    let control = OperationControl::new(CancellationToken::new(), None);

    let result = connection
        .query_controlled("SELECT 7", &control)
        .await
        .expect("an uninterrupted query returns its rows");
    assert_eq!(result.rows, vec![vec![Value::Int(7)]]);
}

#[tokio::test(flavor = "multi_thread")]
async fn an_already_cancelled_control_never_reaches_the_database() {
    let directory = TempDir::new().expect("temp dir");
    let connection = connect_file(&directory).await;
    let token = CancellationToken::new();
    token.cancel();
    let control = OperationControl::new(token, None);

    let error = connection
        .query_controlled("SELECT 1", &control)
        .await
        .expect_err("a cancelled control must refuse before dispatch");
    assert!(matches!(error, DriverError::Cancelled), "unexpected error: {error:?}");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_declared_structure_capability_returns_real_catalog_rows() {
    let directory = TempDir::new().expect("temp dir");
    let connection = connect_file(&directory).await;
    connection
        .execute("CREATE TABLE parent (id INTEGER PRIMARY KEY)")
        .await
        .expect("create the referenced table");
    connection
        .execute("CREATE TABLE child (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES parent(id))")
        .await
        .expect("create the referencing table");
    connection
        .execute("CREATE UNIQUE INDEX child_parent_idx ON child(parent_id)")
        .await
        .expect("create the index");

    assert!(SqliteDriver.supports_index_metadata());
    let indexes = connection.fetch_indexes(None, "child").await.expect("fetch indexes");
    assert!(
        indexes.iter().any(|index| index.name == "child_parent_idx"),
        "a driver that declares index support must return the index it created: {indexes:?}"
    );

    assert!(SqliteDriver.supports_foreign_key_metadata());
    let foreign_keys = connection
        .fetch_foreign_keys(None, "child")
        .await
        .expect("fetch foreign keys");
    assert!(
        foreign_keys
            .iter()
            .any(|key| key.ref_table == "parent" && key.columns == vec!["parent_id".to_string()]),
        "a driver that declares foreign-key support must return the constraint it created: {foreign_keys:?}"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_foreign_key_read_right_after_its_table_is_created_is_listed() {
    for _ in 0..5 {
        let directory = TempDir::new().expect("temp dir");
        let connection = connect_file(&directory).await;
        connection
            .execute("CREATE TABLE parent (a INTEGER, b TEXT, PRIMARY KEY (b, a))")
            .await
            .expect("create the referenced table");
        connection
            .execute("CREATE TABLE child (id INTEGER PRIMARY KEY, pa INTEGER, pb TEXT, FOREIGN KEY (pb, pa) REFERENCES parent(b, a))")
            .await
            .expect("create the referencing table");

        let foreign_keys = connection
            .fetch_foreign_keys(None, "child")
            .await
            .expect("fetch foreign keys");

        assert_eq!(foreign_keys.len(), 1, "{foreign_keys:?}");
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn a_foreign_key_to_the_implicit_parent_key_names_the_primary_key_columns() {
    let directory = TempDir::new().expect("temp dir");
    let connection = connect_file(&directory).await;
    connection
        .execute("CREATE TABLE parent (a INTEGER, b TEXT, note TEXT, PRIMARY KEY (b, a))")
        .await
        .expect("create the referenced table");
    connection
        .execute(
            "CREATE TABLE child (id INTEGER PRIMARY KEY, pa INTEGER, pb TEXT, FOREIGN KEY (pb, pa) REFERENCES parent)",
        )
        .await
        .expect("create the referencing table");

    let foreign_keys = connection
        .fetch_foreign_keys(None, "child")
        .await
        .expect("fetch foreign keys");

    assert_eq!(foreign_keys.len(), 1, "{foreign_keys:?}");
    assert_eq!(foreign_keys[0].columns, vec!["pb".to_string(), "pa".to_string()]);
    assert_eq!(foreign_keys[0].ref_columns, vec!["b".to_string(), "a".to_string()]);
}

#[tokio::test]
async fn sqlite_columns_report_no_comment() {
    let directory = TempDir::new().expect("temp dir");
    let connection = connect_file(&directory).await;
    connection
        .execute("CREATE TABLE comment_demo (id INTEGER PRIMARY KEY, label TEXT)")
        .await
        .unwrap();
    let columns = connection.fetch_columns(None, "comment_demo").await.unwrap();
    assert!(!columns.is_empty());
    assert!(columns.iter().all(|c| c.comment.is_none()));
}

async fn session_value(session: &mut Box<dyn tablepro_core::Session>, sql: &str) -> Value {
    let control = OperationControl::with_timeout(Duration::from_secs(30));
    session.query_params_controlled(sql, &[], &control).await.unwrap().rows[0][0].clone()
}

#[tokio::test(flavor = "multi_thread")]
async fn a_session_keeps_temp_tables_and_its_transaction_between_statements() {
    let directory = TempDir::new().expect("temp dir");
    let connection = connect_file(&directory).await;
    connection.execute("CREATE TABLE ledger (id int)").await.unwrap();
    let mut session = connection.open_session().await.unwrap();
    let control = OperationControl::with_timeout(Duration::from_secs(30));

    for sql in ["CREATE TEMP TABLE scratch (n int)", "INSERT INTO scratch VALUES (7)"] {
        session.query_params_controlled(sql, &[], &control).await.unwrap();
    }
    assert_eq!(
        session_value(&mut session, "SELECT n FROM scratch").await,
        Value::Int(7)
    );
    for sql in ["BEGIN", "INSERT INTO ledger VALUES (1)", "ROLLBACK"] {
        session.query_params_controlled(sql, &[], &control).await.unwrap();
    }
    assert_eq!(
        session_value(&mut session, "SELECT count(*) FROM ledger").await,
        Value::Int(0)
    );
    session.close().await.unwrap();

    let temp = connection
        .query("SELECT count(*) FROM sqlite_temp_master")
        .await
        .unwrap();
    assert_eq!(temp.rows, vec![vec![Value::Int(0)]]);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_cancelled_session_statement_is_interrupted_and_the_session_stays_usable() {
    let directory = TempDir::new().expect("temp dir");
    let connection = connect_file(&directory).await;
    let mut session = connection.open_session().await.unwrap();
    let token = CancellationToken::new();
    let control = OperationControl::new(token.clone(), None);
    let canceller = tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(200)).await;
        token.cancel();
    });

    let error = session
        .query_params_controlled(LONG_QUERY, &[], &control)
        .await
        .unwrap_err();
    canceller.await.unwrap();

    assert!(matches!(error, DriverError::Cancelled), "{error:?}");
    assert!(session.is_usable());
    assert_eq!(session_value(&mut session, "SELECT 1").await, Value::Int(1));
}

#[tokio::test]
async fn an_in_memory_database_refuses_a_session() {
    let connection = SqliteDriver.connect(options_for(":memory:")).await.unwrap();

    let error = connection
        .open_session()
        .await
        .err()
        .expect("an in-memory session is refused");

    assert!(matches!(error, DriverError::Unsupported(_)), "{error:?}");
}

#[tokio::test]
async fn fetched_defaults_keep_no_default_null_empty_and_literal_apart_and_reapply_exactly() {
    let directory = TempDir::new().expect("temp dir");
    let connection = connect_file(&directory).await;
    connection
        .execute(
            "CREATE TABLE defaults_kept (id INTEGER PRIMARY KEY, bare TEXT, explicit_null TEXT DEFAULT NULL, \
             blank TEXT DEFAULT '', word TEXT DEFAULT 'it''s', amount INTEGER DEFAULT 0)",
        )
        .await
        .unwrap();
    let columns = connection.fetch_columns(None, "defaults_kept").await.unwrap();
    let defaults: Vec<(&str, Option<&str>)> = columns
        .iter()
        .map(|c| (c.name.as_str(), c.default_value.as_deref()))
        .collect();
    assert_eq!(
        defaults,
        vec![
            ("id", None),
            ("bare", None),
            ("explicit_null", Some("NULL")),
            ("blank", Some("''")),
            ("word", Some("'it''s'")),
            ("amount", Some("0")),
        ]
    );

    for info in columns.into_iter().filter(|c| c.name != "id") {
        let mut copy = tablepro_core::sql_ddl::DraftColumn::from_info(info.clone());
        copy.original = None;
        copy.name = format!("{}_copy", info.name);
        for statement in tablepro_core::sql_ddl::build_add_column("sqlite", None, "defaults_kept", &copy).unwrap() {
            connection.execute(&statement).await.unwrap();
        }
    }
    connection
        .execute("INSERT INTO defaults_kept (id) VALUES (1)")
        .await
        .unwrap();
    let same = connection
        .query(
            "SELECT bare IS bare_copy, explicit_null IS explicit_null_copy, blank IS blank_copy, \
             word IS word_copy, amount IS amount_copy, blank_copy = '' FROM defaults_kept WHERE id = 1",
        )
        .await
        .unwrap();
    assert_eq!(same.rows[0], vec![Value::Int(1); 6]);
}

async fn notes_in(conn: &dyn Connection, table: &str) -> Vec<String> {
    let rows = conn.query(&format!("SELECT note FROM {table}")).await.unwrap();
    let mut notes: Vec<String> = rows
        .rows
        .iter()
        .map(|row| match &row[0] {
            Value::Text(text) => text.clone(),
            other => panic!("note must be text, got {other:?}"),
        })
        .collect();
    notes.sort();
    notes
}

async fn grid_edits_and_deletes_only_the_keyed_row(conn: &dyn Connection, driver_id: &str, table: &str) {
    let columns = conn.fetch_columns(None, table).await.unwrap();
    let note = columns.iter().position(|c| c.name == "note").unwrap();
    let rows = conn.fetch_rows(None, table, 0, 10).await.unwrap();
    let target = rows
        .rows
        .iter()
        .find(|row| row[note] == Value::Text("target".into()))
        .unwrap();
    let pk_values: Vec<Value> = columns
        .iter()
        .zip(target)
        .filter(|(column, _)| column.primary_key)
        .map(|(_, value)| value.clone())
        .collect();
    assert!(!pk_values.is_empty(), "{table} must report its primary key");
    let before = notes_in(conn, table).await;
    let others: Vec<String> = before.iter().filter(|n| *n != "target").cloned().collect();

    let update = tablepro_core::sql_dialect::build_keyed_update(
        driver_id,
        None,
        table,
        &columns,
        &[(note, Value::Text("edited".into()))],
        &pk_values,
    )
    .unwrap();
    assert_eq!(
        conn.execute_in_transaction(&[update]).await.unwrap(),
        vec![1],
        "{table} update"
    );
    let mut expected = others.clone();
    expected.insert(0, "edited".to_string());
    assert_eq!(
        notes_in(conn, table).await,
        expected,
        "{table} update touched only the keyed row"
    );

    let delete = tablepro_core::sql_dialect::build_keyed_delete(driver_id, None, table, &columns, &pk_values).unwrap();
    assert_eq!(
        conn.execute_in_transaction(&[delete]).await.unwrap(),
        vec![1],
        "{table} delete"
    );
    assert_eq!(
        notes_in(conn, table).await,
        others,
        "{table} delete removed only the keyed row"
    );
}

#[tokio::test]
async fn grid_row_edits_find_rows_by_uuid_composite_and_wide_bigint_keys() {
    let directory = TempDir::new().expect("temp dir");
    let conn = connect_file(&directory).await;
    for sql in [
        "CREATE TABLE keyed_uuid (id TEXT PRIMARY KEY, note TEXT)",
        "INSERT INTO keyed_uuid VALUES ('6f1c2a8e-3b4d-4e5f-8a9b-0c1d2e3f4a5b', 'target'), \
         ('6f1c2a8e-3b4d-4e5f-8a9b-0c1d2e3f4a5c', 'other')",
        "CREATE TABLE keyed_uuid_blob (id BLOB PRIMARY KEY, note TEXT)",
        "INSERT INTO keyed_uuid_blob VALUES (X'6f1c2a8e3b4d4e5f8a9b0c1d2e3f4a5b', 'target'), \
         (X'6f1c2a8e3b4d4e5f8a9b0c1d2e3f4a5c', 'other')",
        "CREATE TABLE keyed_composite (tenant INTEGER, code TEXT, note TEXT, PRIMARY KEY (tenant, code))",
        "INSERT INTO keyed_composite VALUES (1, 'a', 'target'), (1, 'b', 'other'), (2, 'a', 'other')",
        "CREATE TABLE keyed_bigint (id INTEGER PRIMARY KEY, note TEXT)",
        "INSERT INTO keyed_bigint VALUES (9007199254740993, 'target'), (9007199254740992, 'other')",
    ] {
        conn.execute(sql).await.unwrap();
    }
    for table in ["keyed_uuid", "keyed_uuid_blob", "keyed_composite", "keyed_bigint"] {
        grid_edits_and_deletes_only_the_keyed_row(conn.as_ref(), "sqlite", table).await;
    }
}

#[tokio::test]
async fn binary_sql_exports_round_trip_null_empty_and_every_byte() {
    let directory = TempDir::new().unwrap();
    let conn = connect_file(&directory).await;
    conn.execute("CREATE TABLE binary_exports (id INTEGER, payload BLOB)")
        .await
        .unwrap();
    let columns = conn.fetch_columns(None, "binary_exports").await.unwrap();
    let values = [Value::Null, Value::Bytes(vec![]), Value::Bytes((0u8..=255).collect())];
    for (id, value) in values.iter().enumerate() {
        let statement = tablepro_core::sql_literal::build_insert_literal(
            "sqlite",
            None,
            "binary_exports",
            &columns,
            &[Value::Int(id as i64), value.clone()],
        )
        .unwrap();
        conn.execute(&statement).await.unwrap();
    }
    let result = conn
        .query("SELECT payload FROM binary_exports ORDER BY id")
        .await
        .unwrap();
    assert_eq!(
        result.rows,
        values.into_iter().map(|value| vec![value]).collect::<Vec<_>>()
    );
}

#[path = "../../../core/tests/support/value_contract.rs"]
mod value_contract;

#[tokio::test]
async fn value_contract_preserves_scalar_boundaries_through_parameters_and_exports() {
    let directory = TempDir::new().unwrap();
    let connection = connect_file(&directory).await;
    value_contract::assert_scalar_contract(connection.as_ref(), "sqlite").await;
}

#[tokio::test]
async fn an_auto_decimal_parameter_binds_as_real_unless_only_text_keeps_its_digits() {
    let connection = SqliteDriver.connect(options_for(":memory:")).await.unwrap();
    let cases = [
        ("2.5", "real", Value::Float(2.5)),
        ("0.1", "real", Value::Float(0.1)),
        ("-1e3", "real", Value::Float(-1000.0)),
        (
            "1234567890123456789.123456789",
            "text",
            Value::Text("1234567890123456789.123456789".into()),
        ),
    ];
    for (input, storage_class, expected) in cases {
        let parameter = tablepro_core::parse_parameter_value(tablepro_core::ParameterKind::Auto, input).unwrap();
        let result = connection
            .query_params("SELECT typeof(?1), ?1, ?1 > 10", &[parameter])
            .await
            .unwrap();
        let row = &result.rows[0];
        assert_eq!(row[0], Value::Text(storage_class.into()), "{input}");
        assert_eq!(row[1], expected, "{input}");
        assert_eq!(row[2], Value::Int(i64::from(storage_class == "text")), "{input}");
    }
}

#[tokio::test]
async fn sqlite_real_storage_preserves_float_edge_bits() {
    let connection = SqliteDriver.connect(options_for(":memory:")).await.unwrap();
    connection
        .execute("CREATE TABLE float_edges (id INTEGER PRIMARY KEY, value REAL)")
        .await
        .unwrap();
    let values = [f64::from_bits(1), f64::MAX, f64::INFINITY, f64::NEG_INFINITY];
    for (index, value) in values.into_iter().enumerate() {
        connection
            .execute_params(
                "INSERT INTO float_edges VALUES (?1, ?2)",
                &[Value::Int(index as i64 + 1), Value::Float(value)],
            )
            .await
            .unwrap();
    }

    let stored = connection
        .query("SELECT typeof(value), value FROM float_edges ORDER BY id")
        .await
        .unwrap();
    assert_eq!(stored.rows.len(), values.len());
    for (row, expected) in stored.rows.iter().zip(values) {
        assert_eq!(row[0], Value::Text("real".into()));
        let Value::Float(actual) = row[1] else {
            panic!("SQLite REAL storage must decode as a float: {:?}", row[1]);
        };
        assert_eq!(actual.to_bits(), expected.to_bits());
    }
}

#[tokio::test]
async fn sqlite_real_binding_refuses_negative_zero_and_nan() {
    let connection = SqliteDriver.connect(options_for(":memory:")).await.unwrap();
    connection
        .execute("CREATE TABLE float_edges (id INTEGER PRIMARY KEY, value REAL)")
        .await
        .unwrap();

    for (id, value, boundary) in [(2, f64::NAN, "NaN"), (1, -0.0, "negative zero")] {
        let error = connection
            .execute_params(
                "INSERT INTO float_edges VALUES (?1, ?2)",
                &[Value::Int(id), Value::Float(value)],
            )
            .await
            .expect_err(boundary);
        assert!(
            matches!(error, tablepro_core::DriverError::Unsupported(_)),
            "{boundary}: {error:?}"
        );
    }

    let columns = connection.fetch_columns(None, "float_edges").await.unwrap();
    let literal_error = tablepro_core::sql_literal::build_insert_literal(
        "sqlite",
        None,
        "float_edges",
        &columns,
        &[Value::Int(3), Value::Float(-0.0)],
    )
    .expect_err("SQLite SQL export must not erase negative zero");
    assert!(matches!(
        literal_error,
        tablepro_core::sql_dialect::BuildSqlError::UnrepresentableValue { column } if column == "value"
    ));

    let after_refusal = connection.query("SELECT count(*) FROM float_edges").await.unwrap();
    assert_eq!(after_refusal.rows, vec![vec![Value::Int(0)]]);
}
