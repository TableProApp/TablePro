use super::parse_input_for_driver;

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_postgres_citext_array_grid_edit_preserves_case_nulls_and_sibling() {
    use tablepro_core::{ConnectOptions, DatabaseDriver, OperationControl, Value};
    use testcontainers::ImageExt;
    use testcontainers::runners::AsyncRunner;
    use testcontainers_modules::postgres::Postgres;

    const EDITED: &str = r#"[0:1][3:5]={{"Foo","foo","NULL"},{"","a\"b",NULL}}"#;

    let container = Postgres::default().with_tag("16-alpine").start().await.unwrap();
    let connection = drivers_postgres::PgDriver
        .connect(ConnectOptions {
            host: container.get_host().await.unwrap().to_string(),
            port: container.get_host_port_ipv4(5432).await.unwrap(),
            database: "postgres".into(),
            username: "postgres".into(),
            password: secrecy::SecretString::new("postgres".to_string().into()),
            ..Default::default()
        })
        .await
        .unwrap();
    let control = OperationControl::with_timeout(std::time::Duration::from_secs(30));
    connection
        .execute_controlled("CREATE EXTENSION citext", &control)
        .await
        .unwrap();
    connection
        .execute_controlled(
            "CREATE TABLE citext_array_grid (id integer PRIMARY KEY, labels citext[])",
            &control,
        )
        .await
        .unwrap();
    connection
        .execute_controlled(
            "INSERT INTO citext_array_grid VALUES \
             (1, ARRAY['before']::citext[]), (2, ARRAY['keep','sibling']::citext[])",
            &control,
        )
        .await
        .unwrap();

    let columns = connection
        .fetch_columns_controlled(None, "citext_array_grid", &control)
        .await
        .unwrap();
    let labels_index = columns.iter().position(|column| column.name == "labels").unwrap();
    let before = connection
        .query_controlled(
            "SELECT id, pg_typeof(labels)::text, labels::text, array_to_json(labels)::text, \
             encode(array_send(labels), 'hex') FROM citext_array_grid ORDER BY id",
            &control,
        )
        .await
        .unwrap();
    let sibling = before.rows[1].clone();

    let edited = parse_input_for_driver(EDITED, Some(&columns[labels_index]), "postgres").unwrap();
    assert_eq!(edited, Value::Text(EDITED.into()));
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "citext_array_grid",
        &columns,
        &[(labels_index, edited)],
        &[Value::Int(1)],
    )
    .unwrap();
    assert!(update.0.contains("SET \"labels\" = $1"), "{}", update.0);
    assert_eq!(
        connection
            .execute_in_transaction_controlled(&[update], &control)
            .await
            .unwrap(),
        vec![1]
    );

    let after = connection
        .query_controlled(
            "SELECT id, pg_typeof(labels)::text, labels::text, array_to_json(labels)::text, \
             encode(array_send(labels), 'hex') FROM citext_array_grid ORDER BY id",
            &control,
        )
        .await
        .unwrap();
    let native = connection
        .query_controlled(
            &format!(
                "SELECT 1, pg_typeof('{EDITED}'::citext[])::text, \
                 ('{EDITED}'::citext[])::text, array_to_json('{EDITED}'::citext[])::text, \
                 encode(array_send('{EDITED}'::citext[]), 'hex')"
            ),
            &control,
        )
        .await
        .unwrap();
    assert_eq!(after.rows[0], native.rows[0]);
    assert_eq!(after.rows[1], sibling);
    assert_eq!(
        after.rows[0][3],
        Value::Text(r#"[["Foo","foo","NULL"],["","a\"b",null]]"#.into())
    );
    assert_eq!(
        connection
            .query_controlled(
                "SELECT labels[0][3] = labels[0][4] FROM citext_array_grid WHERE id = 1",
                &control,
            )
            .await
            .unwrap()
            .rows[0][0],
        Value::Bool(true)
    );

    let invalid = parse_input_for_driver(r#"{"unterminated}"#, Some(&columns[labels_index]), "postgres").unwrap();
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "citext_array_grid",
        &columns,
        &[(labels_index, invalid)],
        &[Value::Int(1)],
    )
    .unwrap();
    assert!(
        connection
            .execute_in_transaction_controlled(&[update], &control)
            .await
            .is_err()
    );
    let unchanged = connection
        .query_controlled(
            "SELECT id, pg_typeof(labels)::text, labels::text, array_to_json(labels)::text, \
             encode(array_send(labels), 'hex') FROM citext_array_grid ORDER BY id",
            &control,
        )
        .await
        .unwrap();
    assert_eq!(unchanged.rows, after.rows);
}
