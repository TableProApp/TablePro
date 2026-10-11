use super::*;

#[tokio::test]
#[ignore = "requires docker"]
async fn postgres_numeric_parser_outputs_round_trip_through_server() {
    use tablepro_core::{ConnectOptions, DatabaseDriver};
    use testcontainers::ImageExt;
    use testcontainers::runners::AsyncRunner;
    use testcontainers_modules::postgres::Postgres;

    const VALUE: &str = "1234567890123456789012345678901234567890.1234567890123456789012345678901234567890";
    let container = Postgres::default().with_tag("16-alpine").start().await.unwrap();
    let options = ConnectOptions {
        host: container.get_host().await.unwrap().to_string(),
        port: container.get_host_port_ipv4(5432).await.unwrap(),
        database: "postgres".into(),
        username: "postgres".into(),
        password: secrecy::SecretString::new("postgres".to_string().into()),
        ..Default::default()
    };
    let connection = drivers_postgres::PgDriver.connect(options).await.unwrap();
    let control = crate::services::operation_control::bounded(0);
    for (table, data_type) in [
        ("parser_numeric", "numeric(80, 40)"),
        ("parser_unconstrained_numeric", "numeric"),
    ] {
        connection
            .execute_controlled(
                &format!("CREATE TABLE {table} (id integer PRIMARY KEY, amount {data_type})"),
                &control,
            )
            .await
            .unwrap();
        connection
            .execute_controlled(&format!("INSERT INTO {table} VALUES (1, 0)"), &control)
            .await
            .unwrap();
        let columns = connection
            .fetch_columns_controlled(None, table, &control)
            .await
            .unwrap();
        let amount = columns.iter().position(|column| column.name == "amount").unwrap();
        let id = columns.iter().position(|column| column.name == "id").unwrap();
        assert!(columns[id].primary_key);
        if data_type == "numeric" {
            assert_eq!(columns[amount].data_type, "numeric");
        }
        let parsed = parse_input_for_driver(VALUE, Some(&columns[amount]), "postgres").unwrap();
        assert_eq!(parsed, Value::Text(VALUE.into()));
        let update = tablepro_core::sql_dialect::build_keyed_update(
            "postgres",
            None,
            table,
            &columns,
            &[(amount, parsed)],
            &[Value::Int(1)],
        )
        .unwrap();
        assert_eq!(
            connection
                .execute_in_transaction_controlled(&[update], &control)
                .await
                .unwrap(),
            vec![1]
        );

        let saved = connection
            .query_controlled(&format!("SELECT amount::text FROM {table} WHERE id = 1"), &control)
            .await
            .unwrap();
        assert_eq!(saved.rows, vec![vec![Value::Text(VALUE.into())]], "{data_type}");

        if data_type == "numeric" {
            for special in ["NaN", "Infinity", "-Infinity"] {
                let parsed = parse_input_for_driver(special, Some(&columns[amount]), "postgres").unwrap();
                assert_eq!(parsed, Value::Text(special.into()));
                let update = tablepro_core::sql_dialect::build_keyed_update(
                    "postgres",
                    None,
                    table,
                    &columns,
                    &[(amount, parsed)],
                    &[Value::Int(1)],
                )
                .unwrap();
                assert_eq!(
                    connection
                        .execute_in_transaction_controlled(&[update], &control)
                        .await
                        .unwrap(),
                    vec![1]
                );
                let saved = connection
                    .query_controlled(
                        &format!("SELECT amount, amount::text FROM {table} WHERE id = 1"),
                        &control,
                    )
                    .await
                    .unwrap();
                assert_eq!(
                    saved.rows,
                    vec![vec![Value::Text(special.into()), Value::Text(special.into())]]
                );
            }
        }
    }

    connection
        .execute_controlled(
            "CREATE TABLE parser_text_array_edit (id integer PRIMARY KEY, value text[] NOT NULL)",
            &control,
        )
        .await
        .unwrap();
    connection
        .execute_controlled(
            "INSERT INTO parser_text_array_edit VALUES (1, ARRAY['initial']), (2, ARRAY['sibling'])",
            &control,
        )
        .await
        .unwrap();
    let columns = connection
        .fetch_columns_controlled(None, "parser_text_array_edit", &control)
        .await
        .unwrap();
    let value = columns.iter().position(|column| column.name == "value").unwrap();
    let literal = r#"{"a  b"," c "}"#;
    let normalized = normalize_single_line_input(literal);
    let parsed = parse_input_for_driver(&normalized, Some(&columns[value]), "postgres").unwrap();
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "parser_text_array_edit",
        &columns,
        &[(value, parsed)],
        &[Value::Int(1)],
    )
    .unwrap();
    assert_eq!(
        connection
            .execute_in_transaction_controlled(&[update], &control)
            .await
            .unwrap(),
        vec![1]
    );
    let saved = connection
        .query_controlled(
            "SELECT id, value::text FROM parser_text_array_edit ORDER BY id",
            &control,
        )
        .await
        .unwrap();
    assert_eq!(
        saved.rows,
        vec![
            vec![Value::Int(1), Value::Text(literal.into())],
            vec![Value::Int(2), Value::Text("{sibling}".into())],
        ]
    );

    let fraction = format!("{}123", "1234567890".repeat(1638));
    assert_eq!(fraction.len(), 16_383);
    let maximum_scale_value = format!("0.{fraction}");
    connection
        .execute_controlled(
            "CREATE TABLE parser_numeric_max_scale (id integer PRIMARY KEY, amount numeric)",
            &control,
        )
        .await
        .unwrap();
    connection
        .execute_controlled("INSERT INTO parser_numeric_max_scale VALUES (1, 0)", &control)
        .await
        .unwrap();
    let columns = connection
        .fetch_columns_controlled(None, "parser_numeric_max_scale", &control)
        .await
        .unwrap();
    let amount = columns.iter().position(|column| column.name == "amount").unwrap();
    let parsed = parse_input_for_driver(&maximum_scale_value, Some(&columns[amount]), "postgres").unwrap();
    assert_eq!(parsed, Value::Text(maximum_scale_value.clone()));
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "parser_numeric_max_scale",
        &columns,
        &[(amount, parsed)],
        &[Value::Int(1)],
    )
    .unwrap();
    assert_eq!(
        connection
            .execute_in_transaction_controlled(&[update], &control)
            .await
            .unwrap(),
        vec![1]
    );
    let saved = connection
        .query_controlled(
            "SELECT amount::text, scale(amount) FROM parser_numeric_max_scale WHERE id = 1",
            &control,
        )
        .await
        .unwrap();
    assert_eq!(
        saved.rows,
        vec![vec![Value::Text(maximum_scale_value), Value::Int(16_383)]]
    );

    let maximum_integer_value = "9".repeat(131_072);
    connection
        .execute_controlled(
            "CREATE TABLE parser_numeric_max_integer (id integer PRIMARY KEY, amount numeric)",
            &control,
        )
        .await
        .unwrap();
    connection
        .execute_controlled("INSERT INTO parser_numeric_max_integer VALUES (1, 0)", &control)
        .await
        .unwrap();
    let columns = connection
        .fetch_columns_controlled(None, "parser_numeric_max_integer", &control)
        .await
        .unwrap();
    let amount = columns.iter().position(|column| column.name == "amount").unwrap();
    let parsed = parse_input_for_driver(&maximum_integer_value, Some(&columns[amount]), "postgres").unwrap();
    assert_eq!(parsed, Value::Text(maximum_integer_value.clone()));
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "parser_numeric_max_integer",
        &columns,
        &[(amount, parsed)],
        &[Value::Int(1)],
    )
    .unwrap();
    assert_eq!(
        connection
            .execute_in_transaction_controlled(&[update], &control)
            .await
            .unwrap(),
        vec![1]
    );
    let saved = connection
        .query_controlled(
            "SELECT amount::text, length(amount::text) FROM parser_numeric_max_integer WHERE id = 1",
            &control,
        )
        .await
        .unwrap();
    assert_eq!(
        saved.rows,
        vec![vec![Value::Text(maximum_integer_value), Value::Int(131_072)]]
    );
}
