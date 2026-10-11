use super::native_connection;
use tablepro_core::Value;

#[tokio::test]
async fn value_contract_nested_ubigint_struct_refuses_lossy_consumers() {
    let connection = native_connection().await;
    let expression = "STRUCT_PACK(wide := 9223372036854775808::UBIGINT, max_value := 18446744073709551615::UBIGINT, missing := NULL::UBIGINT)";
    let oracle = connection
        .query(&format!(
            "SELECT typeof(value), CAST(value AS VARCHAR) FROM (SELECT {expression} AS value) source"
        ))
        .await
        .unwrap();
    assert_eq!(
        oracle.rows,
        vec![vec![
            Value::Text("STRUCT(wide UBIGINT, max_value UBIGINT, missing UBIGINT)".into()),
            Value::Text("{'wide': 9223372036854775808, 'max_value': 18446744073709551615, 'missing': NULL}".into()),
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
