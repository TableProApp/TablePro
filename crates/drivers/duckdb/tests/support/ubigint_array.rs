use super::native_connection;
use tablepro_core::Value;

#[tokio::test]
async fn value_contract_nested_ubigint_array_refuses_lossy_consumers() {
    let connection = native_connection().await;
    let expression = "[9223372036854775808::UBIGINT, 18446744073709551615::UBIGINT, NULL::UBIGINT]";
    let oracle = connection
        .query(&format!(
            "SELECT typeof(value), CAST(value AS VARCHAR) FROM (SELECT {expression} AS value) source"
        ))
        .await
        .unwrap();
    assert_eq!(
        oracle.rows,
        vec![vec![
            Value::Text("UBIGINT[]".into()),
            Value::Text("[9223372036854775808, 18446744073709551615, NULL]".into()),
        ]]
    );

    let result = connection.query(&format!("SELECT {expression}")).await.unwrap();
    let value = &result.rows[0][0];
    assert!(matches!(value, Value::Undecodable(_)), "{value:?}");
    assert!(tablepro_core::sql_literal::render_sql_literal("duckdb", value).is_err());
    assert!(
        connection
            .query_params("SELECT ?", std::slice::from_ref(value))
            .await
            .is_err()
    );
}
