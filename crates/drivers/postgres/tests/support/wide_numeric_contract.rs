#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::{Connection, Value};

pub async fn assert_grid_edit(connection: &dyn Connection) {
    const VALUE: &str = "1234567890123456789012345678901234567890.1234567890123456789012345678901234567890";

    connection
        .execute("CREATE TABLE wide_numeric_grid (id integer PRIMARY KEY, amount numeric(80, 40))")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO wide_numeric_grid VALUES (1, 0)")
        .await
        .unwrap();
    let mut row = connection.query("SELECT * FROM wide_numeric_grid").await.unwrap();
    row.columns[0].primary_key = true;
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "wide_numeric_grid",
        &row.columns,
        &[(1, Value::Text(VALUE.into()))],
        &[Value::Int(1)],
    )
    .unwrap();
    assert_eq!(connection.execute_in_transaction(&[update]).await.unwrap(), vec![1]);

    let result = connection
        .query("SELECT amount::text FROM wide_numeric_grid WHERE id = 1")
        .await
        .unwrap();
    assert_eq!(result.rows, vec![vec![Value::Text(VALUE.into())]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_numeric_domain_preserves_wide_value_across_consumers() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    const VALUE: &str = "1234567890123456789012345678901234567890.12345678901234567890";
    connection
        .execute("CREATE DOMAIN value_contract_numeric_domain AS numeric")
        .await
        .unwrap();

    let result = connection
        .query(&format!(
            "SELECT '{VALUE}'::value_contract_numeric_domain AS domain_value, \
             ('{VALUE}'::value_contract_numeric_domain)::numeric::text AS numeric_text"
        ))
        .await
        .unwrap();
    assert_eq!(
        result.rows,
        vec![vec![Value::Text(VALUE.into()), Value::Text(VALUE.into())]]
    );

    let literal = tablepro_core::sql_literal::render_sql_literal("postgres", &result.rows[0][0]).unwrap();
    let literal_result = connection
        .query(&format!(
            "SELECT {literal}::value_contract_numeric_domain::numeric::text"
        ))
        .await
        .unwrap();
    assert_eq!(literal_result.rows, vec![vec![Value::Text(VALUE.into())]]);
    let bound_result = connection
        .query_params(
            "SELECT $1::value_contract_numeric_domain::numeric::text",
            &[Value::Text(VALUE.into())],
        )
        .await
        .unwrap();
    assert_eq!(bound_result.rows, vec![vec![Value::Text(VALUE.into())]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_rust_decimal_capacity_edges_round_trip_through_postgres() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    for text in [
        "79228162514264337593543950335",
        "-79228162514264337593543950335",
        "0.0000000000000000000000000001",
    ] {
        let decimal: rust_decimal::Decimal = text.parse().unwrap();
        let value = Value::Decimal(decimal);
        assert_eq!(decimal.to_string(), text);
        let bound = connection
            .query_params(
                "SELECT $1::numeric::text, pg_catalog.pg_typeof($1::numeric)::text",
                std::slice::from_ref(&value),
            )
            .await
            .unwrap();
        assert_eq!(
            bound.rows,
            vec![vec![Value::Text(text.into()), Value::Text("numeric".into())]],
            "bound decimal {text}"
        );

        let literal = tablepro_core::sql_literal::render_sql_literal("postgres", &value).unwrap();
        let restored = connection
            .query(&format!("SELECT ({literal})::numeric::text"))
            .await
            .unwrap();
        assert_eq!(
            restored.rows,
            vec![vec![Value::Text(text.into())]],
            "literal decimal {text}"
        );
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_wide_numeric_grid_edit_preserves_exact_value() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    assert_grid_edit(connection.as_ref()).await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_max_precision_numeric_grid_edit_preserves_exact_value() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    let fraction = "1234567890".repeat(100);
    let value = format!("0.{fraction}");

    connection
        .execute("CREATE TABLE max_numeric_grid (id integer PRIMARY KEY, amount numeric(1000, 1000))")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO max_numeric_grid VALUES (1, 0)")
        .await
        .unwrap();
    let mut row = connection.query("SELECT * FROM max_numeric_grid").await.unwrap();
    row.columns[0].primary_key = true;
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "max_numeric_grid",
        &row.columns,
        &[(1, Value::Text(value.clone()))],
        &[Value::Int(1)],
    )
    .unwrap();
    assert_eq!(connection.execute_in_transaction(&[update]).await.unwrap(), vec![1]);

    let result = connection
        .query("SELECT amount::text FROM max_numeric_grid WHERE id = 1")
        .await
        .unwrap();
    assert_eq!(result.rows, vec![vec![Value::Text(value)]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_numeric_special_grid_edits_match_server_text() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    connection
        .execute("CREATE TABLE numeric_special_grid (id integer PRIMARY KEY, amount numeric)")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO numeric_special_grid VALUES (1, 0)")
        .await
        .unwrap();

    for value in ["NaN", "Infinity", "-Infinity"] {
        let mut row = connection
            .query("SELECT * FROM numeric_special_grid WHERE id = 1")
            .await
            .unwrap();
        let id_index = row.columns.iter().position(|column| column.name == "id").unwrap();
        let amount_index = row.columns.iter().position(|column| column.name == "amount").unwrap();
        row.columns[id_index].primary_key = true;
        let update = tablepro_core::sql_dialect::build_keyed_update(
            "postgres",
            None,
            "numeric_special_grid",
            &row.columns,
            &[(amount_index, Value::Text(value.into()))],
            &[Value::Int(1)],
        )
        .unwrap();
        assert_eq!(connection.execute_in_transaction(&[update]).await.unwrap(), vec![1]);

        let result = connection
            .query("SELECT amount, amount::text FROM numeric_special_grid WHERE id = 1")
            .await
            .unwrap();
        assert_eq!(result.rows[0][0], result.rows[0][1], "{value}");
        assert_eq!(result.rows[0][1], Value::Text(value.into()), "{value}");
    }
}
