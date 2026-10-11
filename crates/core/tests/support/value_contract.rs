#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::{Connection, Value};

pub async fn assert_scalar_contract(connection: &dyn Connection, driver: &str) {
    let corpus: serde_json::Value =
        serde_json::from_str(include_str!("../../../../testdata/value-contract.json")).unwrap();
    for text in corpus["integers"].as_array().unwrap() {
        assert_scalar(
            connection,
            driver,
            "integer",
            Value::Int(text.as_str().unwrap().parse().unwrap()),
        )
        .await;
    }
    for text in corpus["floats"].as_array().unwrap() {
        assert_scalar(
            connection,
            driver,
            "float",
            Value::Float(text.as_str().unwrap().parse().unwrap()),
        )
        .await;
    }
    for text in corpus["texts"].as_array().unwrap() {
        assert_scalar(connection, driver, "text", Value::Text(text.as_str().unwrap().into())).await;
    }
    if matches!(driver, "postgres" | "mssql" | "clickhouse" | "duckdb") {
        let uuid = "12345678-9abc-def0-1122-334455667788";
        assert_scalar(connection, driver, "uuid", Value::Uuid(uuid.parse().unwrap())).await;
        assert_scalar(connection, driver, "text", Value::Text(uuid.into())).await;
        assert_scalar(connection, driver, "uuid", Value::Null).await;
    }
    assert_named_parameter_order(connection, driver).await;
    assert_long_text(connection, driver, corpus["long_text_bytes"].as_u64().unwrap() as usize).await;
    assert_scalar(connection, driver, "integer", Value::Null).await;
    assert_scalar(connection, driver, "text", Value::Null).await;
    if driver != "sqlite" {
        for text in corpus["decimals"].as_array().unwrap() {
            assert_scalar(
                connection,
                driver,
                "decimal",
                Value::Decimal(text.as_str().unwrap().parse().unwrap()),
            )
            .await;
        }
    }
}

async fn assert_long_text(connection: &dyn Connection, driver: &str, length: usize) {
    let expected = Value::Text("x".repeat(length));
    if driver != "clickhouse" {
        assert_scalar(connection, driver, "text", expected).await;
        return;
    }
    let result = connection
        .query(&format!("SELECT repeat('x', {length}) AS value"))
        .await
        .unwrap();
    assert_eq!(result.rows, vec![vec![expected.clone()]]);
    let bound = connection
        .query_params("SELECT CAST(? AS Nullable(String))", std::slice::from_ref(&expected))
        .await;
    assert!(
        matches!(bound, Err(tablepro_core::DriverError::Query { message, .. }) if message.contains("Max query size exceeded"))
    );
    let literal = tablepro_core::sql_literal::render_sql_literal(driver, &expected).unwrap();
    let exported = connection.query(&format!("SELECT {literal}")).await;
    assert!(
        matches!(exported, Err(tablepro_core::DriverError::Query { message, .. }) if message.contains("Max query size exceeded"))
    );
}

async fn assert_scalar(connection: &dyn Connection, driver: &str, kind: &str, expected: Value) {
    let placeholder = match driver {
        "postgres" => "$1",
        "mssql" => "@P1",
        _ => "?",
    };
    let sql_type = scalar_type(driver, kind);
    let sql = format!("SELECT CAST({placeholder} AS {sql_type}) AS value");
    let bound = connection
        .query_params(&sql, std::slice::from_ref(&expected))
        .await
        .unwrap();
    assert_eq!(bound.rows.len(), 1, "{driver} bound {kind}");
    assert_eq!(bound.rows[0].len(), 1, "{driver} bound {kind}");
    assert_value(&bound.rows[0][0], &expected, driver, &format!("bound {kind}"));
    let literal = tablepro_core::sql_literal::render_sql_literal(driver, &expected).unwrap();
    let exported = connection
        .query(&format!("SELECT CAST({literal} AS {sql_type}) AS value"))
        .await
        .unwrap();
    assert_eq!(exported.rows.len(), 1, "{driver} exported {kind}");
    assert_eq!(exported.rows[0].len(), 1, "{driver} exported {kind}");
    assert_value(&exported.rows[0][0], &expected, driver, &format!("exported {kind}"));
}

fn assert_value(actual: &Value, expected: &Value, driver: &str, kind: &str) {
    match (actual, expected) {
        (Value::Float(actual), Value::Float(expected)) => {
            assert_eq!(actual.to_bits(), expected.to_bits(), "{driver} {kind}")
        }
        (Value::Decimal(actual), Value::Decimal(expected)) => {
            assert_eq!(actual.to_string(), expected.to_string(), "{driver} {kind} scale")
        }
        _ => assert_eq!(actual, expected, "{driver} {kind}"),
    }
}

fn scalar_type(driver: &str, kind: &str) -> &'static str {
    match (driver, kind) {
        ("clickhouse", "integer") => "Nullable(Int64)",
        ("mysql", "integer") => "SIGNED",
        (_, "integer") => "BIGINT",
        ("clickhouse", "float") => "Float64",
        ("postgres", "float") => "DOUBLE PRECISION",
        ("mssql", "float") => "FLOAT",
        (_, "float") => "DOUBLE",
        ("clickhouse", "text") => "Nullable(String)",
        ("mysql", "text") => "CHAR CHARACTER SET utf8mb4",
        ("mssql", "text") => "NVARCHAR(MAX)",
        (_, "text") => "TEXT",
        ("postgres" | "duckdb", "uuid") => "UUID",
        ("clickhouse", "uuid") => "Nullable(UUID)",
        ("mssql", "uuid") => "UNIQUEIDENTIFIER",
        (_, "decimal") => "DECIMAL(28,8)",
        _ => panic!("unknown value contract kind"),
    }
}

async fn assert_named_parameter_order(connection: &dyn Connection, driver: &str) {
    use tablepro_core::{ParameterKind, extract_named_parameters, parse_parameter_value};
    let integer = scalar_type(driver, "integer");
    let text = scalar_type(driver, "text");
    let source = format!(
        "SELECT CAST(:large AS {integer}), CAST(:text AS {text}), CAST(:small AS {integer}), \
         CAST(:text AS {text}), CAST(:empty AS {text}), CAST(:nothing AS {text}), \
         ':not_a_parameter' /* :also_not_a_parameter */"
    );
    let parsed = extract_named_parameters(&source, driver);
    assert_eq!(parsed.names, ["large", "text", "small", "empty", "nothing"]);
    assert_eq!(parsed.bindings, ["large", "text", "small", "text", "empty", "nothing"]);
    for payload in ["x'); SELECT 999; --", "\\' :large ? $1 @P1", "  東京 😀\r\n\t  "] {
        let expected = vec![
            Value::Int(i64::MAX),
            Value::Text(payload.into()),
            Value::Int(i64::MIN),
            Value::Text(payload.into()),
            Value::Text(String::new()),
            Value::Null,
            Value::Text(":not_a_parameter".into()),
        ];
        let bindings: Vec<_> = parsed
            .bindings
            .iter()
            .map(|name| match name.as_str() {
                "large" => parse_parameter_value(ParameterKind::Integer, "9223372036854775807").unwrap(),
                "small" => parse_parameter_value(ParameterKind::Integer, "-9223372036854775808").unwrap(),
                "text" => parse_parameter_value(ParameterKind::Text, payload).unwrap(),
                "empty" => parse_parameter_value(ParameterKind::Text, "").unwrap(),
                "nothing" => parse_parameter_value(ParameterKind::Null, "ignored").unwrap(),
                _ => panic!("unexpected parameter"),
            })
            .collect();
        let result = connection.query_params(&parsed.sql, &bindings).await.unwrap();
        assert_eq!(
            result.rows,
            vec![expected],
            "{driver}: mixed repeated bindings {payload:?}"
        );
    }
}
