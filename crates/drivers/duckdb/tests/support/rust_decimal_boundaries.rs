use super::native_connection;
use tablepro_core::Value;

#[tokio::test]
async fn value_contract_rust_decimal_capacity_edges_round_trip_through_duckdb() {
    let connection = native_connection().await;
    for text in [
        "79228162514264337593543950335",
        "-79228162514264337593543950335",
        "0.0000000000000000000000000001",
    ] {
        let value = Value::Decimal(text.parse().unwrap());
        let bound = connection
            .query_params("SELECT ?", std::slice::from_ref(&value))
            .await
            .unwrap();
        assert!(
            bound.rows.len() == 1
                && matches!(bound.rows[0].as_slice(), [Value::Decimal(actual)] if actual.to_string() == text),
            "bound value changed: {text}"
        );

        let literal = tablepro_core::sql_literal::render_sql_literal("duckdb", &value).unwrap();
        let restored = connection.query(&format!("SELECT {literal}")).await.unwrap();
        assert!(
            restored.rows.len() == 1
                && matches!(restored.rows[0].as_slice(), [Value::Decimal(actual)] if actual.to_string() == text),
            "SQL literal value changed: {text}: {:?}",
            restored.rows
        );
    }
}
