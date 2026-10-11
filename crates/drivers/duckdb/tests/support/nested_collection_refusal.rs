use super::*;

#[tokio::test]
async fn value_contract_nested_collection_combinations_refuse_lossy_consumers() {
    let connection = native_connection().await;
    let wide = "18446744073709551616";
    for (expression, expected_type, expected_json, refusal) in [
        (
            format!("STRUCT_PACK(amounts := [{wide}::UHUGEINT, NULL::UHUGEINT])"),
            "STRUCT(amounts UHUGEINT[])",
            format!(r#"{{"amounts":[{wide},null]}}"#),
            "STRUCT",
        ),
        (
            format!(
                "MAP(['wide', 'missing'], [STRUCT_PACK(amount := {wide}::UHUGEINT), NULL::STRUCT(amount UHUGEINT)])"
            ),
            "MAP(VARCHAR, STRUCT(amount UHUGEINT))",
            format!(r#"{{"wide":{{"amount":{wide}}},"missing":null}}"#),
            "MAP",
        ),
    ] {
        let oracle = connection
            .query(&format!(
                "SELECT typeof(value), to_json(value)::VARCHAR FROM (SELECT {expression} AS value) source"
            ))
            .await
            .unwrap();
        assert_eq!(
            oracle.rows,
            vec![vec![Value::Text(expected_type.into()), Value::Text(expected_json),]],
            "native oracle for {expression}"
        );

        let result = connection.query(&format!("SELECT {expression}")).await.unwrap();
        let value = &result.rows[0][0];
        assert_eq!(value, &Value::Undecodable(refusal.into()), "{expression}");
        assert!(tablepro_core::sql_literal::render_sql_literal("duckdb", value).is_err());
        assert!(
            connection
                .query_params("SELECT ?", std::slice::from_ref(value))
                .await
                .is_err()
        );
    }
}
