#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use super::{connect, start_mssql};
use tablepro_core::{OperationControl, Value};

#[tokio::test]
#[ignore = "requires docker"]
async fn sql_variant_values_are_undecodable_and_keep_connections_usable() {
    let (_container, options) = start_mssql().await;
    let conn = connect(options).await;
    let oracle = conn
        .query(
            "SELECT CONVERT(varchar(20), SQL_VARIANT_PROPERTY(value, 'BaseType')) AS base_type, \
             CONVERT(varchar(40), value) AS exact_text \
             FROM (VALUES (CONVERT(sql_variant, CONVERT(bigint, 9007199254740993)))) \
             AS source(value)",
        )
        .await
        .unwrap();
    assert_eq!(
        oracle.rows,
        vec![vec![
            Value::Text("bigint".into()),
            Value::Text("9007199254740993".into())
        ]],
        "the native SQL Server oracle must preserve the value beyond binary64 precision"
    );

    let result = conn
        .query("SELECT CONVERT(sql_variant, CONVERT(bigint, 9007199254740993)) AS value")
        .await
        .expect("sql_variant result metadata should be readable");
    assert_eq!(result.columns[0].data_type, "sql_variant");
    assert_eq!(
        result.rows,
        vec![vec![Value::Undecodable("sql_variant".into())]],
        "the heterogeneous base type must not be mislabeled as an ordinary bigint"
    );
    assert!(tablepro_core::sql_literal::render_sql_literal("mssql", &result.rows[0][0]).is_err());
    assert!(
        conn.query_params("SELECT @P1", &[result.rows[0][0].clone()])
            .await
            .is_err()
    );
    assert!(conn.query("SELECT 1").await.is_ok());

    let mut session = conn.open_session().await.unwrap();
    let control = OperationControl::new(tokio_util::sync::CancellationToken::new(), None);
    let session_result = session
        .query_params_controlled(
            "SELECT CONVERT(sql_variant, CONVERT(bigint, 9007199254740993)) AS value",
            &[],
            &control,
        )
        .await
        .expect("session sql_variant result should be readable");
    assert_eq!(session_result.columns[0].data_type, "sql_variant");
    assert_eq!(
        session_result.rows,
        vec![vec![Value::Undecodable("sql_variant".into())]]
    );
    assert!(session.is_usable());
    assert_eq!(
        session
            .query_params_controlled("SELECT 1", &[], &control)
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Int(1)]]
    );
}
