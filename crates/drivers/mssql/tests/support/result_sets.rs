#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use super::*;

#[tokio::test]
#[ignore = "requires docker"]
async fn an_error_raised_after_the_first_result_set_is_reported() {
    let (_container, opts) = start_mssql().await;
    let conn = connect(opts).await;

    let err = conn
        .query("SELECT 1 AS a; SELECT 2 AS b; SELECT 1/0 AS c")
        .await
        .unwrap_err();
    assert!(format!("{err}").to_lowercase().contains("divide by zero"), "got: {err}");

    let first = conn.query("SELECT 1 AS a; SELECT 'x' AS b, 'y' AS c").await.unwrap();
    let names: Vec<&str> = first.columns.iter().map(|c| c.name.as_str()).collect();
    assert_eq!(names, vec!["a"]);
    assert_eq!(first.rows, vec![vec![Value::Int(1)]]);

    let after_late_error = conn.query("SELECT 3 AS usable").await.unwrap();
    assert_eq!(
        after_late_error.rows,
        vec![vec![Value::Int(3)]],
        "draining later result sets leaves the connection usable"
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn all_result_sets_keep_order_and_metadata_when_the_first_is_empty() {
    let (_container, opts) = start_mssql().await;
    let conn = connect(opts).await;

    let result = conn
        .query_result_sets_controlled(
            "SELECT CAST('first' AS nvarchar(10)) AS first_set WHERE 1 = 0; SELECT 2 AS later_set",
            &[],
            &OperationControl::with_timeout(std::time::Duration::from_secs(30)),
        )
        .await
        .unwrap();
    assert_eq!(result.result_sets.len(), 2);
    assert!(result.result_sets[0].rows.is_empty());
    assert_eq!(result.result_sets[0].columns.len(), 1);
    assert_eq!(result.result_sets[0].columns[0].name, "first_set");
    assert_eq!(result.result_sets[0].columns[0].data_type, "nvarchar");
    assert_eq!(result.result_sets[1].columns[0].name, "later_set");
    assert_eq!(result.result_sets[1].rows, vec![vec![Value::Int(2)]]);
    assert!(!result.truncated);
    assert_eq!(
        conn.query("SELECT 3 AS usable").await.unwrap().rows,
        vec![vec![Value::Int(3)]]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn one_result_budget_is_shared_across_later_sql_server_sets() {
    let (_container, opts) = start_mssql().await;
    let conn = connect(opts).await;
    let payload_bytes = tablepro_core::MAX_QUERY_RESULT_BYTES / 2;
    let sql = format!(
        "SELECT REPLICATE(CAST('x' AS varchar(max)), {payload_bytes}) AS first_set; \
         SELECT REPLICATE(CAST('y' AS varchar(max)), {payload_bytes}) AS second_set"
    );
    let result = conn
        .query_result_sets_controlled(
            &sql,
            &[],
            &OperationControl::with_timeout(std::time::Duration::from_secs(90)),
        )
        .await
        .unwrap();

    assert_eq!(result.result_sets.len(), 2);
    assert_eq!(result.result_sets[0].rows.len(), 1);
    assert!(result.result_sets[1].rows.is_empty());
    assert!(result.result_sets[1].truncated);
    assert!(result.truncated);
    assert_eq!(
        conn.query("SELECT 3 AS usable").await.unwrap().rows,
        vec![vec![Value::Int(3)]],
        "draining a capped batch must leave the connection usable"
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_result_cut_at_the_memory_budget_reports_truncation_and_drains_the_batch() {
    let (_container, opts) = start_mssql().await;
    let conn = connect(opts).await;
    let rows = 70;
    let bytes_per_row = tablepro_core::MAX_QUERY_RESULT_BYTES / 64 + 1;
    let result = conn
        .query(&format!(
            "SELECT TOP ({rows}) REPLICATE(CAST('x' AS varchar(max)), {bytes_per_row}) AS payload FROM sys.all_objects a CROSS JOIN sys.all_objects b"
        ))
        .await
        .unwrap();

    assert!(result.truncated);
    assert!(!result.rows.is_empty());
    assert!(result.rows.len() < rows);
    assert_eq!(result.rows[0][0], Value::Text("x".repeat(bytes_per_row)));
    assert_eq!(
        conn.query("SELECT 4 AS usable").await.unwrap().rows,
        vec![vec![Value::Int(4)]]
    );
}
