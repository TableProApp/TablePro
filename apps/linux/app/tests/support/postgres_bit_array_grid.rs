use super::parse_input_for_driver;

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_postgres_bit_array_grid_edit_preserves_wire_values_and_sibling() {
    use tablepro_core::{ConnectOptions, DatabaseDriver, OperationControl, Value};
    use testcontainers::ImageExt;
    use testcontainers::runners::AsyncRunner;
    use testcontainers_modules::postgres::Postgres;

    const FIXED: &str = "[0:2]={10101,00000,NULL}";
    const VARIABLE: &str = "[0:3]={1,1101010101010101,\"\",NULL}";

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
        .execute_controlled(
            "CREATE TABLE bit_array_grid (id integer PRIMARY KEY, fixed bit(5)[], variable bit varying[])",
            &control,
        )
        .await
        .unwrap();
    connection
        .execute_controlled(
            "INSERT INTO bit_array_grid VALUES \
             (1, ARRAY[B'00000']::bit(5)[], ARRAY[B'0']::bit varying[]), \
             (2, ARRAY[B'11111']::bit(5)[], ARRAY[B'11']::bit varying[])",
            &control,
        )
        .await
        .unwrap();

    let columns = connection
        .fetch_columns_controlled(None, "bit_array_grid", &control)
        .await
        .unwrap();
    let fixed_index = columns.iter().position(|column| column.name == "fixed").unwrap();
    let variable_index = columns.iter().position(|column| column.name == "variable").unwrap();
    let before = connection
        .query_controlled(
            "SELECT id, pg_typeof(fixed)::text, encode(array_send(fixed), 'hex'), \
             pg_typeof(variable)::text, encode(array_send(variable), 'hex') \
             FROM bit_array_grid ORDER BY id",
            &control,
        )
        .await
        .unwrap();
    let sibling_before = before.rows[1].clone();

    let fixed = parse_input_for_driver(FIXED, Some(&columns[fixed_index]), "postgres").unwrap();
    let variable = parse_input_for_driver(VARIABLE, Some(&columns[variable_index]), "postgres").unwrap();
    assert_eq!(fixed, Value::Text(FIXED.into()));
    assert_eq!(variable, Value::Text(VARIABLE.into()));
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "bit_array_grid",
        &columns,
        &[(fixed_index, fixed), (variable_index, variable)],
        &[Value::Int(1)],
    )
    .unwrap();
    assert!(update.0.contains("::text::pg_catalog.bit[]"), "{}", update.0);
    assert!(update.0.contains("::text::pg_catalog.varbit[]"), "{}", update.0);
    assert_eq!(
        connection
            .execute_in_transaction_controlled(&[update], &control)
            .await
            .unwrap(),
        vec![1]
    );

    let after = connection
        .query_controlled(
            "SELECT id, pg_typeof(fixed)::text, encode(array_send(fixed), 'hex'), \
             pg_typeof(variable)::text, encode(array_send(variable), 'hex') \
             FROM bit_array_grid ORDER BY id",
            &control,
        )
        .await
        .unwrap();
    let native = connection
        .query_controlled(
            &format!(
                "SELECT 1, pg_typeof('{FIXED}'::bit(5)[])::text, \
                 encode(array_send('{FIXED}'::bit(5)[]), 'hex'), \
                 pg_typeof('{VARIABLE}'::bit varying[])::text, \
                 encode(array_send('{VARIABLE}'::bit varying[]), 'hex')"
            ),
            &control,
        )
        .await
        .unwrap();
    assert_eq!(after.rows[0], native.rows[0]);
    assert_eq!(after.rows[1], sibling_before);

    let invalid = parse_input_for_driver("{1,not-a-bit}", Some(&columns[variable_index]), "postgres").unwrap();
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "bit_array_grid",
        &columns,
        &[(variable_index, invalid)],
        &[Value::Int(1)],
    )
    .unwrap();
    let error = connection
        .execute_in_transaction_controlled(&[update], &control)
        .await
        .expect_err("invalid varbit element must be rejected by PostgreSQL");
    assert!(
        matches!(
            &error,
            tablepro_core::DriverError::Transaction { source, .. }
                if matches!(source.as_ref(), tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "22P02")
        ),
        "invalid varbit[] should retain PostgreSQL's invalid-text SQLSTATE: {error:?}"
    );
    let unchanged = connection
        .query_controlled(
            "SELECT id, pg_typeof(fixed)::text, encode(array_send(fixed), 'hex'), \
             pg_typeof(variable)::text, encode(array_send(variable), 'hex') \
             FROM bit_array_grid ORDER BY id",
            &control,
        )
        .await
        .unwrap();
    assert_eq!(unchanged.rows, after.rows, "invalid edit changed target or sibling");
}
