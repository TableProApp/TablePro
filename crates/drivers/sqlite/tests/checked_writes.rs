#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use std::sync::Arc;

use drivers_sqlite::SqliteDriver;
use tablepro_core::{ConnectOptions, Connection, DatabaseDriver, DriverError, Value};
use tempfile::TempDir;

async fn connect(directory: &TempDir) -> Arc<dyn Connection> {
    let path = directory.path().join("checked.db").to_string_lossy().to_string();
    let options = ConnectOptions {
        database: path,
        ..Default::default()
    };
    SqliteDriver.connect(options).await.expect("connect").into()
}

fn update(id: i64, value: &str, expected_old: &str) -> (String, Vec<Value>) {
    (
        "UPDATE t SET v = ?1 WHERE id = ?2 AND v IS ?3".to_string(),
        vec![
            Value::Text(value.into()),
            Value::Int(id),
            Value::Text(expected_old.into()),
        ],
    )
}

async fn seeded(directory: &TempDir) -> Arc<dyn Connection> {
    let connection = connect(directory).await;
    connection
        .execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO t VALUES (1, 'a'), (2, 'b')")
        .await
        .unwrap();
    connection
}

async fn values(connection: &dyn Connection) -> Vec<Value> {
    connection
        .query("SELECT v FROM t ORDER BY id")
        .await
        .unwrap()
        .rows
        .into_iter()
        .map(|mut row| row.remove(0))
        .collect()
}

#[tokio::test]
async fn a_checked_batch_commits_when_every_guarded_statement_changes_one_row() {
    let directory = TempDir::new().unwrap();
    let connection = seeded(&directory).await;

    let affected = connection
        .execute_in_transaction_checked(&[update(1, "a2", "a"), update(2, "b2", "b")], &[0, 1])
        .await
        .unwrap();

    assert_eq!(affected, vec![1, 1]);
    assert_eq!(
        values(connection.as_ref()).await,
        vec![Value::Text("a2".into()), Value::Text("b2".into())]
    );
}

#[tokio::test]
async fn a_checked_batch_rolls_back_everything_when_a_row_changed_since_it_was_loaded() {
    let directory = TempDir::new().unwrap();
    let connection = seeded(&directory).await;

    let outcome = connection
        .execute_in_transaction_checked(&[update(1, "a2", "a"), update(2, "b2", "stale")], &[0, 1])
        .await;

    match outcome {
        Err(DriverError::Transaction {
            statement_index,
            source,
        }) => {
            assert_eq!(statement_index, 1);
            assert!(matches!(*source, DriverError::ConcurrentModification), "{source:?}");
        }
        other => panic!("expected a concurrent modification at statement 1, got {other:?}"),
    }
    assert_eq!(
        values(connection.as_ref()).await,
        vec![Value::Text("a".into()), Value::Text("b".into())],
        "the first statement was rolled back with the failed one"
    );
}

#[tokio::test]
async fn statements_outside_the_checked_list_may_change_any_number_of_rows() {
    let directory = TempDir::new().unwrap();
    let connection = seeded(&directory).await;

    let affected = connection
        .execute_in_transaction_checked(
            &[
                ("UPDATE t SET v = 'all'".to_string(), Vec::new()),
                update(1, "a3", "all"),
            ],
            &[1],
        )
        .await
        .unwrap();

    assert_eq!(affected, vec![2, 1]);
}

#[tokio::test]
async fn a_failing_statement_reports_its_index_and_rolls_the_batch_back() {
    let directory = TempDir::new().unwrap();
    let connection = seeded(&directory).await;

    let outcome = connection
        .execute_in_transaction_checked(
            &[
                update(1, "a2", "a"),
                ("UPDATE missing SET v = 1".to_string(), Vec::new()),
            ],
            &[0],
        )
        .await;

    assert!(
        matches!(outcome, Err(DriverError::Transaction { statement_index: 1, .. })),
        "{outcome:?}"
    );
    assert_eq!(values(connection.as_ref()).await[0], Value::Text("a".into()));
}

#[tokio::test]
async fn browse_filter_contains_matches_literal_percent_and_underscore() {
    use tablepro_core::{ColumnInfo, FilterOp, FilterRule, FilterSet, FilterValue, build_filter_where};

    let directory = TempDir::new().unwrap();
    let connection = connect(&directory).await;
    connection.execute("CREATE TABLE t (v TEXT)").await.unwrap();
    connection
        .execute("INSERT INTO t VALUES ('50% off'), ('500 off'), ('a_b'), ('aXb'), ('a\\Xb')")
        .await
        .unwrap();
    let column = ColumnInfo {
        name: "v".into(),
        data_type: "TEXT".into(),
        nullable: true,
        primary_key: false,
        is_auto_increment: false,
        default_value: None,
        is_generated: false,
        comment: None,
        collation: None,
        enum_type: None,
        domain_type: None,
    };
    for (needle, expected) in [("50%", "50% off"), ("a_b", "a_b")] {
        let set = FilterSet {
            rules: vec![FilterRule {
                column: "v".into(),
                op: FilterOp::Contains,
                value: Some(FilterValue::Single(needle.into())),
            }],
            ..Default::default()
        };
        let (clause, params) = build_filter_where("sqlite", std::slice::from_ref(&column), &set)
            .unwrap()
            .unwrap();
        let rows = connection
            .query_params(&format!("SELECT v FROM t WHERE {clause}"), &params)
            .await
            .unwrap()
            .rows;
        assert_eq!(rows, vec![vec![Value::Text(expected.into())]], "{needle}");
    }
}
