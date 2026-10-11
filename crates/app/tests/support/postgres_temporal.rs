use super::*;

#[tokio::test]
#[ignore = "requires docker"]
async fn postgres_extended_temporal_grid_edits_preserve_native_values() {
    use tablepro_core::{ConnectOptions, DatabaseDriver};
    use testcontainers::ImageExt;
    use testcontainers::runners::AsyncRunner;
    use testcontainers_modules::postgres::Postgres;

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
    for (table, data_type, text, send) in [
        ("extended_date", "date", "1000000-02-29", "date_send"),
        (
            "extended_timestamp",
            "timestamp",
            "294276-12-31 23:59:59.999999",
            "timestamp_send",
        ),
        (
            "extended_timestamptz",
            "timestamptz",
            "294276-12-31 23:59:59.999999+00",
            "timestamptz_send",
        ),
    ] {
        connection
            .execute_controlled(
                &format!("CREATE TABLE {table} (id integer PRIMARY KEY, value {data_type})"),
                &control,
            )
            .await
            .unwrap();
        connection
            .execute_controlled(
                &format!("INSERT INTO {table} VALUES (1, '2000-01-01'::{data_type})"),
                &control,
            )
            .await
            .unwrap();
        connection
            .execute_controlled(
                &format!("INSERT INTO {table} VALUES (2, '2001-01-01'::{data_type})"),
                &control,
            )
            .await
            .unwrap();
        let sibling_before = connection
            .query_controlled(
                &format!("SELECT encode({send}(value), 'hex') FROM {table} WHERE id = 2"),
                &control,
            )
            .await
            .unwrap();
        let columns = connection
            .fetch_columns_controlled(None, table, &control)
            .await
            .unwrap();
        let value_index = columns.iter().position(|column| column.name == "value").unwrap();
        let parsed = parse_input_for_driver(text, Some(&columns[value_index]), "postgres").unwrap();
        assert_eq!(parsed, Value::Text(text.into()));
        let update = tablepro_core::sql_dialect::build_keyed_update(
            "postgres",
            None,
            table,
            &columns,
            &[(value_index, parsed)],
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
                &format!("SELECT encode({send}(value), 'hex') FROM {table} WHERE id = 1"),
                &control,
            )
            .await
            .unwrap();
        let oracle = connection
            .query_controlled(
                &format!("SELECT encode({send}('{text}'::{data_type}), 'hex')"),
                &control,
            )
            .await
            .unwrap();
        assert_eq!(saved.rows, oracle.rows, "{data_type}");
        let sibling_after = connection
            .query_controlled(
                &format!("SELECT encode({send}(value), 'hex') FROM {table} WHERE id = 2"),
                &control,
            )
            .await
            .unwrap();
        assert_eq!(sibling_after.rows, sibling_before.rows, "{data_type} sibling changed");
    }
}
