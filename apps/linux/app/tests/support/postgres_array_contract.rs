use super::parse_input_for_driver;

#[test]
fn value_contract_postgres_scalar_named_array_types_stay_text_in_the_grid_parser() {
    for (data_type, literal) in [
        ("uuid[]", "{550e8400-e29b-41d4-a716-446655440000,NULL}"),
        ("date[]", "{2026-09-30,NULL}"),
        ("time[]", "{12:34:56.123456,NULL}"),
        ("numeric[]", "{1.2300,NULL}"),
        ("boolean[]", "{true,NULL}"),
        ("timestamp with time zone[]", "{2026-09-30 12:34:56+00,NULL}"),
        ("interval[]", r#"{"1 year 2 mons 3 days 04:05:06.123456",NULL}"#),
    ] {
        let column = ColumnInfo {
            name: "value".into(),
            data_type: data_type.into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        };
        let parsed = parse_input_for_driver(literal, Some(&column), "postgres")
            .unwrap_or_else(|error| panic!("{data_type}: {error}"));
        assert_eq!(parsed, Value::Text(literal.into()), "{data_type}");
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_postgres_temporal_array_grid_edits_preserve_boundaries_and_siblings() {
    use tablepro_core::{ConnectOptions, DatabaseDriver, OperationControl};
    use testcontainers::ImageExt;
    use testcontainers::runners::AsyncRunner;
    use testcontainers_modules::postgres::Postgres;

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

    let cases = [
        (
            "date_array_grid",
            "date",
            r#"{"0002-12-31 BC","10000-01-01","infinity","-infinity",NULL}"#,
            "ARRAY['2000-01-01'::date]",
        ),
        (
            "time_array_grid",
            "time",
            r#"{"00:00:00","12:34:56.123456","23:59:59.999999","24:00:00",NULL}"#,
            "ARRAY['12:00:00'::time]",
        ),
        (
            "timestamp_array_grid",
            "timestamp",
            r#"{"0002-12-31 23:59:59.999999 BC","10000-01-01 00:00:00","294276-12-31 23:59:59.999999","infinity","-infinity",NULL}"#,
            "ARRAY['2000-01-01 12:00:00'::timestamp]",
        ),
        (
            "timetz_array_grid",
            "timetz",
            r#"{"00:00:00+15:59:59","23:59:59.999999-15:59:59","12:34:56.123456+05:30",NULL}"#,
            "ARRAY['12:00:00+00'::timetz]",
        ),
        (
            "interval_array_grid",
            "interval",
            r#"{"1 year 2 mons 3 days 04:05:06.123456","-1 year +2 mons -3 days -04:05:06.654321","0 seconds","00:00:00",NULL}"#,
            "ARRAY['2 months'::interval, NULL]::interval[]",
        ),
    ];
    let mut date_row_after_edit = None;
    let mut date_sibling_after_edit = None;

    for (table, data_type, literal, sibling) in cases {
        connection
            .execute_controlled(
                &format!("CREATE TABLE {table} (id integer PRIMARY KEY, value pg_catalog.{data_type}[])"),
                &control,
            )
            .await
            .unwrap();
        connection
            .execute_controlled(
                &format!(
                    "INSERT INTO {table} VALUES \
                     (1, ARRAY[NULL]::pg_catalog.{data_type}[]), (2, {sibling})"
                ),
                &control,
            )
            .await
            .unwrap();
        let columns = connection
            .fetch_columns_controlled(None, table, &control)
            .await
            .unwrap();
        let id_index = columns.iter().position(|column| column.name == "id").unwrap();
        let value_index = columns.iter().position(|column| column.name == "value").unwrap();
        let before = connection
            .query_controlled(
                &format!(
                    "SELECT id, pg_typeof(value)::text, value::text, array_to_json(value)::text, \
                     encode(array_send(value), 'hex') FROM {table} ORDER BY id"
                ),
                &control,
            )
            .await
            .unwrap();
        let sibling_before = before.rows[1].clone();

        let parsed = parse_input_for_driver(literal, Some(&columns[value_index]), "postgres")
            .unwrap_or_else(|error| panic!("{data_type}[] parser: {error}"));
        assert_eq!(parsed, Value::Text(literal.into()), "{data_type}[] remains exact text");
        let update = tablepro_core::sql_dialect::build_keyed_update(
            "postgres",
            None,
            table,
            &columns,
            &[(value_index, parsed)],
            &[Value::Int(1)],
        )
        .unwrap();
        assert!(
            update.0.contains("::text::pg_catalog."),
            "{}[] cast: {}",
            data_type,
            update.0
        );
        assert_eq!(update.1[0], Value::Text(literal.into()));
        assert_eq!(
            connection
                .execute_in_transaction_controlled(&[update], &control)
                .await
                .unwrap(),
            vec![1],
            "{data_type}[] keyed edit row count"
        );

        let after = connection
            .query_controlled(
                &format!(
                    "SELECT id, pg_typeof(value)::text, value::text, array_to_json(value)::text, \
                     encode(array_send(value), 'hex') FROM {table} ORDER BY id"
                ),
                &control,
            )
            .await
            .unwrap();
        let native = connection
            .query_controlled(
                &format!(
                    "SELECT pg_typeof('{literal}'::pg_catalog.{data_type}[])::text, \
                     ('{literal}'::pg_catalog.{data_type}[])::text, \
                     array_to_json('{literal}'::pg_catalog.{data_type}[])::text, \
                     encode(array_send('{literal}'::pg_catalog.{data_type}[]), 'hex')"
                ),
                &control,
            )
            .await
            .unwrap();
        assert_eq!(after.rows[0][1..], native.rows[0][..], "{data_type}[] native oracle");
        assert_eq!(after.rows[1], sibling_before, "{data_type}[] changed its sibling row");
        assert_eq!(after.rows[0][0], Value::Int(1));
        let Value::Text(native_type) = &after.rows[0][1] else {
            panic!("unexpected {data_type}[] type result: {:?}", after.rows[0][1]);
        };
        assert!(native_type.ends_with("[]"), "unexpected array type {native_type}");
        if table == "date_array_grid" {
            date_row_after_edit = Some(after.rows[0].clone());
            date_sibling_after_edit = Some(after.rows[1].clone());
        }
        assert_eq!(id_index, 0, "primary key position in {table}");
    }

    let columns = connection
        .fetch_columns_controlled(None, "date_array_grid", &control)
        .await
        .unwrap();
    let value_index = columns.iter().position(|column| column.name == "value").unwrap();
    let invalid = parse_input_for_driver("{not-a-date}", Some(&columns[value_index]), "postgres").unwrap();
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "date_array_grid",
        &columns,
        &[(value_index, invalid)],
        &[Value::Int(1)],
    )
    .unwrap();
    let error = connection
        .execute_in_transaction_controlled(&[update], &control)
        .await
        .expect_err("invalid date[] edit must be rejected by PostgreSQL");
    assert!(
        matches!(
            &error,
            tablepro_core::DriverError::Transaction { source, .. }
                if matches!(source.as_ref(), tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "22007")
        ),
        "invalid date[] should retain PostgreSQL's invalid datetime SQLSTATE: {error:?}"
    );
    let saved = connection
        .query_controlled(
            "SELECT id, pg_typeof(value)::text, value::text, array_to_json(value)::text, \
             encode(array_send(value), 'hex') FROM date_array_grid ORDER BY id",
            &control,
        )
        .await
        .unwrap();
    assert_eq!(saved.rows[0], date_row_after_edit.unwrap());
    assert_eq!(saved.rows[1], date_sibling_after_edit.unwrap());
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_postgres_float4_array_grid_edit_preserves_extreme_values_and_sibling() {
    use tablepro_core::{ConnectOptions, DatabaseDriver, OperationControl, Value};
    use testcontainers::ImageExt;
    use testcontainers::runners::AsyncRunner;
    use testcontainers_modules::postgres::Postgres;

    const ARRAY: &str = "{0.10000000149011612,1.0000001192092896,-0,1.401298464324817e-45,NaN,Infinity,-Infinity,NULL}";
    const ORACLE: &str = "ARRAY[0.10000000149011612::float4, 1.0000001192092896::float4, \
        '-0'::float4, '1.401298464324817e-45'::float4, 'NaN'::float4, \
        'Infinity'::float4, '-Infinity'::float4, NULL]::float4[]";

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
            "CREATE TABLE float4_array_grid (id integer PRIMARY KEY, value float4[])",
            &control,
        )
        .await
        .unwrap();
    connection
        .execute_controlled(
            "INSERT INTO float4_array_grid VALUES (1, ARRAY[0]::float4[]), (2, ARRAY[77]::float4[])",
            &control,
        )
        .await
        .unwrap();

    let columns = connection
        .fetch_columns_controlled(None, "float4_array_grid", &control)
        .await
        .unwrap();
    let value_index = columns.iter().position(|column| column.name == "value").unwrap();
    let before = connection
        .query_controlled(
            "SELECT id, pg_typeof(value)::text, array_to_json(value)::text, \
             encode(array_send(value), 'hex') FROM float4_array_grid ORDER BY id",
            &control,
        )
        .await
        .unwrap();
    let sibling_before = before.rows[1].clone();

    let parsed = parse_input_for_driver(ARRAY, Some(&columns[value_index]), "postgres")
        .expect("float4[] array text should pass through app grid parsing");
    assert_eq!(parsed, Value::Text(ARRAY.into()));
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "float4_array_grid",
        &columns,
        &[(value_index, parsed)],
        &[Value::Int(1)],
    )
    .unwrap();
    assert!(update.0.contains("::text::pg_catalog.float4[]"), "{}", update.0);
    assert_eq!(update.1[0], Value::Text(ARRAY.into()));
    assert_eq!(
        connection
            .execute_in_transaction_controlled(&[update], &control)
            .await
            .unwrap(),
        vec![1]
    );

    let after = connection
        .query_controlled(
            "SELECT id, pg_typeof(value)::text, array_to_json(value)::text, \
             encode(array_send(value), 'hex') FROM float4_array_grid ORDER BY id",
            &control,
        )
        .await
        .unwrap();
    let native = connection
        .query_controlled(
            &format!(
                "SELECT pg_typeof({ORACLE})::text, array_to_json({ORACLE})::text, \
                 encode(array_send({ORACLE}), 'hex')"
            ),
            &control,
        )
        .await
        .unwrap();
    assert_eq!(after.rows[0][1..], native.rows[0][..]);
    assert_eq!(after.rows[1], sibling_before);

    let invalid = parse_input_for_driver("{0.1,not-a-float}", Some(&columns[value_index]), "postgres")
        .expect("malformed float4[] remains text for server validation");
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "float4_array_grid",
        &columns,
        &[(value_index, invalid)],
        &[Value::Int(1)],
    )
    .unwrap();
    let error = connection
        .execute_in_transaction_controlled(&[update], &control)
        .await
        .expect_err("invalid float4[] element must be rejected by PostgreSQL");
    assert!(
        matches!(
            &error,
            tablepro_core::DriverError::Transaction { source, .. }
                if matches!(source.as_ref(), tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "22P02")
        ),
        "invalid float4[] should retain PostgreSQL's invalid-text SQLSTATE: {error:?}"
    );
    let unchanged = connection
        .query_controlled(
            "SELECT id, pg_typeof(value)::text, array_to_json(value)::text, \
             encode(array_send(value), 'hex') FROM float4_array_grid ORDER BY id",
            &control,
        )
        .await
        .unwrap();
    assert_eq!(unchanged.rows, after.rows, "refused edit changed target or sibling");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_postgres_integer_array_grid_edits_preserve_width_and_siblings() {
    use tablepro_core::{ConnectOptions, DatabaseDriver, OperationControl};
    use testcontainers::ImageExt;
    use testcontainers::runners::AsyncRunner;
    use testcontainers_modules::postgres::Postgres;

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

    let mut smallint_target_after_edit = None;
    let mut smallint_sibling_after_edit = None;
    for (table, data_type, literal, sibling) in [
        ("smallint_array_grid", "int2", "[-1:1]={-32768,32767,NULL}", "ARRAY[42]"),
        (
            "integer_array_grid",
            "int4",
            "[2:4]={-2147483648,2147483647,NULL}",
            "ARRAY[42]",
        ),
        (
            "bigint_array_grid",
            "int8",
            "[0:3]={-9223372036854775808,9007199254740993,9223372036854775807,NULL}",
            "ARRAY[42]",
        ),
    ] {
        connection
            .execute_controlled(
                &format!("CREATE TABLE {table} (id integer PRIMARY KEY, value pg_catalog.{data_type}[])"),
                &control,
            )
            .await
            .unwrap();
        connection
            .execute_controlled(
                &format!(
                    "INSERT INTO {table} VALUES \
                     (1, ARRAY[0]::pg_catalog.{data_type}[]), (2, {sibling}::pg_catalog.{data_type}[])"
                ),
                &control,
            )
            .await
            .unwrap();
        let columns = connection
            .fetch_columns_controlled(None, table, &control)
            .await
            .unwrap();
        let value_index = columns.iter().position(|column| column.name == "value").unwrap();
        let before = connection
            .query_controlled(
                &format!(
                    "SELECT id, pg_typeof(value)::text, value::text, array_to_json(value)::text, \
                     encode(array_send(value), 'hex') FROM {table} ORDER BY id"
                ),
                &control,
            )
            .await
            .unwrap();
        let sibling_before = before.rows[1].clone();

        let parsed = parse_input_for_driver(literal, Some(&columns[value_index]), "postgres").unwrap();
        assert_eq!(parsed, Value::Text(literal.into()), "{data_type}[] input text");
        let update = tablepro_core::sql_dialect::build_keyed_update(
            "postgres",
            None,
            table,
            &columns,
            &[(value_index, parsed)],
            &[Value::Int(1)],
        )
        .unwrap();
        assert!(
            update.0.contains("::text::pg_catalog."),
            "{}[] cast: {}",
            data_type,
            update.0
        );
        assert_eq!(update.1[0], Value::Text(literal.into()));
        assert_eq!(
            connection
                .execute_in_transaction_controlled(&[update], &control)
                .await
                .unwrap(),
            vec![1]
        );

        let after = connection
            .query_controlled(
                &format!(
                    "SELECT id, pg_typeof(value)::text, value::text, array_to_json(value)::text, \
                     encode(array_send(value), 'hex') FROM {table} ORDER BY id"
                ),
                &control,
            )
            .await
            .unwrap();
        let native = connection
            .query_controlled(
                &format!(
                    "SELECT pg_typeof('{literal}'::pg_catalog.{data_type}[])::text, \
                     ('{literal}'::pg_catalog.{data_type}[])::text, \
                     array_to_json('{literal}'::pg_catalog.{data_type}[])::text, \
                     encode(array_send('{literal}'::pg_catalog.{data_type}[]), 'hex')"
                ),
                &control,
            )
            .await
            .unwrap();
        assert_eq!(after.rows[0][1..], native.rows[0][..], "{data_type}[] native oracle");
        assert_eq!(after.rows[1], sibling_before, "{data_type}[] sibling changed");
        if table == "smallint_array_grid" {
            smallint_target_after_edit = Some(after.rows[0].clone());
            smallint_sibling_after_edit = Some(after.rows[1].clone());
        }
    }

    let columns = connection
        .fetch_columns_controlled(None, "smallint_array_grid", &control)
        .await
        .unwrap();
    let value_index = columns.iter().position(|column| column.name == "value").unwrap();
    let invalid = parse_input_for_driver("{32768}", Some(&columns[value_index]), "postgres").unwrap();
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "smallint_array_grid",
        &columns,
        &[(value_index, invalid)],
        &[Value::Int(1)],
    )
    .unwrap();
    let error = connection
        .execute_in_transaction_controlled(&[update], &control)
        .await
        .expect_err("smallint[] overflow must be refused by PostgreSQL");
    assert!(
        matches!(
            &error,
            tablepro_core::DriverError::Transaction { source, .. }
                if matches!(source.as_ref(), tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "22003")
        ),
        "smallint[] overflow should retain PostgreSQL's numeric-range SQLSTATE: {error:?}"
    );
    let saved = connection
        .query_controlled(
            "SELECT id, pg_typeof(value)::text, value::text, array_to_json(value)::text, \
             encode(array_send(value), 'hex') FROM smallint_array_grid ORDER BY id",
            &control,
        )
        .await
        .unwrap();
    assert_eq!(saved.rows[0], smallint_target_after_edit.unwrap());
    assert_eq!(saved.rows[1], smallint_sibling_after_edit.unwrap());
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_postgres_text_array_grid_edit_preserves_escaped_values_and_siblings() {
    use tablepro_core::{ConnectOptions, DatabaseDriver, OperationControl};
    use testcontainers::ImageExt;
    use testcontainers::runners::AsyncRunner;
    use testcontainers_modules::postgres::Postgres;

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
    let literal = r#"[0:8]={NULL,"NULL","","a,b","a\"b","a\\b","東京","<tag>&","=1+1"}"#;
    connection
        .execute_controlled(
            "CREATE TABLE text_array_grid_contract (id integer PRIMARY KEY, value text[])",
            &control,
        )
        .await
        .unwrap();
    connection
        .execute_controlled(
            "INSERT INTO text_array_grid_contract VALUES \
             (1, ARRAY['before']::text[]), (2, ARRAY['sibling',NULL]::text[])",
            &control,
        )
        .await
        .unwrap();
    let columns = connection
        .fetch_columns_controlled(None, "text_array_grid_contract", &control)
        .await
        .unwrap();
    let value_index = columns.iter().position(|column| column.name == "value").unwrap();
    let before = connection
        .query_controlled(
            "SELECT id, pg_typeof(value)::text, value::text, array_to_json(value)::text, \
             encode(array_send(value), 'hex') FROM text_array_grid_contract ORDER BY id",
            &control,
        )
        .await
        .unwrap();
    let sibling_before = before.rows[1].clone();

    let parsed = parse_input_for_driver(literal, Some(&columns[value_index]), "postgres").unwrap();
    assert_eq!(parsed, Value::Text(literal.into()));
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "text_array_grid_contract",
        &columns,
        &[(value_index, parsed)],
        &[Value::Int(1)],
    )
    .unwrap();
    assert!(update.0.contains("$1::text::pg_catalog.text[]"));
    assert_eq!(update.1[0], Value::Text(literal.into()));
    assert_eq!(
        connection
            .execute_in_transaction_controlled(&[update], &control)
            .await
            .unwrap(),
        vec![1]
    );

    let after = connection
        .query_controlled(
            "SELECT id, pg_typeof(value)::text, value::text, array_to_json(value)::text, \
             encode(array_send(value), 'hex') FROM text_array_grid_contract ORDER BY id",
            &control,
        )
        .await
        .unwrap();
    let native = connection
        .query_controlled(
            &format!(
                "SELECT pg_typeof('{literal}'::text[])::text, ('{literal}'::text[])::text, \
                 array_to_json('{literal}'::text[])::text, encode(array_send('{literal}'::text[]), 'hex')"
            ),
            &control,
        )
        .await
        .unwrap();
    assert_eq!(after.rows[0][1..], native.rows[0][..]);
    assert_eq!(after.rows[1], sibling_before);
    let tablepro_core::Value::Text(json_text) = &after.rows[0][3] else {
        panic!("text[] JSON oracle was not text: {:?}", after.rows[0][3]);
    };
    let json: serde_json::Value = serde_json::from_str(json_text).unwrap();
    assert_eq!(
        json,
        serde_json::json!([null, "NULL", "", "a,b", "a\"b", "a\\b", "東京", "<tag>&", "=1+1"])
    );

    let invalid = parse_input_for_driver("{\"unterminated}", Some(&columns[value_index]), "postgres").unwrap();
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "text_array_grid_contract",
        &columns,
        &[(value_index, invalid)],
        &[Value::Int(1)],
    )
    .unwrap();
    let error = connection
        .execute_in_transaction_controlled(&[update], &control)
        .await
        .expect_err("malformed text[] input must be rejected by PostgreSQL");
    assert!(
        matches!(
            &error,
            tablepro_core::DriverError::Transaction { source, .. }
                if matches!(source.as_ref(), tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "22P02")
        ),
        "malformed text[] should retain PostgreSQL's input SQLSTATE: {error:?}"
    );
    let saved = connection
        .query_controlled(
            "SELECT id, pg_typeof(value)::text, value::text, array_to_json(value)::text, \
             encode(array_send(value), 'hex') FROM text_array_grid_contract ORDER BY id",
            &control,
        )
        .await
        .unwrap();
    assert_eq!(saved.rows, after.rows);
}
use tablepro_core::{ColumnInfo, Value};

#[test]
fn value_contract_postgres_float8_array_grid_literal_keeps_subnormal_and_signed_zero_text() {
    let literal = "{1.0000000000000002,-0,5e-324,NaN,Infinity,-Infinity,NULL}";
    let columns = vec![
        ColumnInfo {
            name: "id".into(),
            data_type: "integer".into(),
            nullable: false,
            primary_key: true,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        },
        ColumnInfo {
            name: "value".into(),
            data_type: "float8[]".into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        },
    ];
    let parsed = parse_input_for_driver(literal, Some(&columns[1]), "postgres").unwrap();
    assert_eq!(parsed, Value::Text(literal.into()));
    let (sql, params) = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "float8_array_grid",
        &columns,
        &[(1, parsed)],
        &[Value::Int(1)],
    )
    .unwrap();
    assert!(sql.contains("$1::text::pg_catalog.float8[]"));
    assert_eq!(params[0], Value::Text(literal.into()));
}

#[test]
fn value_contract_postgres_boolean_array_grid_literal_stays_text_through_the_keyed_update_builder() {
    let literal = "{true,false,NULL}";
    let columns = vec![
        ColumnInfo {
            name: "id".into(),
            data_type: "integer".into(),
            nullable: false,
            primary_key: true,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        },
        ColumnInfo {
            name: "value".into(),
            data_type: "boolean[]".into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        },
    ];
    let parsed = parse_input_for_driver(literal, Some(&columns[1]), "postgres").unwrap();
    assert_eq!(parsed, Value::Text(literal.into()));
    let (sql, params) = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "bool_array_grid",
        &columns,
        &[(1, parsed)],
        &[Value::Int(1)],
    )
    .unwrap();
    assert!(sql.contains("$1::text::pg_catalog.bool[]"));
    assert_eq!(params[0], Value::Text(literal.into()));
}

#[test]
fn value_contract_postgres_bytea_array_grid_literal_keeps_escaped_bytes_through_the_builder() {
    let literal = r#"{"\\x00ff","\\x5c5c","",NULL}"#;
    let columns = vec![
        ColumnInfo {
            name: "id".into(),
            data_type: "integer".into(),
            nullable: false,
            primary_key: true,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        },
        ColumnInfo {
            name: "value".into(),
            data_type: "bytea[]".into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        },
    ];
    let parsed = parse_input_for_driver(literal, Some(&columns[1]), "postgres").unwrap();
    assert_eq!(parsed, Value::Text(literal.into()));
    let (sql, params) = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "bytea_array_grid",
        &columns,
        &[(1, parsed)],
        &[Value::Int(1)],
    )
    .unwrap();
    assert!(sql.contains("$1::text::pg_catalog.bytea[]"));
    assert_eq!(params[0], Value::Text(literal.into()));
}

#[test]
fn value_contract_postgres_uuid_array_grid_literal_stays_text_through_the_keyed_update_builder() {
    let literal = "{550e8400-e29b-41d4-a716-446655440000,6ba7b810-9dad-11d1-80b4-00c04fd430c8,NULL}";
    let columns = vec![
        ColumnInfo {
            name: "id".into(),
            data_type: "integer".into(),
            nullable: false,
            primary_key: true,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        },
        ColumnInfo {
            name: "value".into(),
            data_type: "uuid[]".into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        },
    ];
    let parsed = parse_input_for_driver(literal, Some(&columns[1]), "postgres").unwrap();
    assert_eq!(parsed, Value::Text(literal.into()));
    let (sql, params) = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "uuid_array_grid",
        &columns,
        &[(1, parsed)],
        &[Value::Int(1)],
    )
    .unwrap();
    assert!(sql.contains("$1::text::pg_catalog.uuid[]"));
    assert_eq!(params[0], Value::Text(literal.into()));
}

#[test]
fn value_contract_postgres_timestamptz_array_grid_literal_stays_text_through_the_keyed_update_builder() {
    let literal = r#"{"2026-09-30 12:34:56.123456+05:30","1999-12-31 23:59:59.000001-07:00",NULL}"#;
    let columns = vec![
        ColumnInfo {
            name: "id".into(),
            data_type: "integer".into(),
            nullable: false,
            primary_key: true,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        },
        ColumnInfo {
            name: "value".into(),
            data_type: "timestamp with time zone[]".into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        },
    ];
    let parsed = parse_input_for_driver(literal, Some(&columns[1]), "postgres").unwrap();
    assert_eq!(parsed, Value::Text(literal.into()));
    let (sql, params) = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "timestamptz_array_grid",
        &columns,
        &[(1, parsed)],
        &[Value::Int(1)],
    )
    .unwrap();
    assert!(sql.contains("$1::text::pg_catalog.timestamptz[]"));
    assert_eq!(params[0], Value::Text(literal.into()));
}

#[test]
fn value_contract_postgres_custom_enum_array_grid_literal_stays_text_with_a_qualified_cast() {
    let literal = r#"{"NULL","",東京,"a,b",NULL}"#;
    let column = ColumnInfo {
        name: "labels".into(),
        data_type: "enum_array_schema.label[]".into(),
        nullable: true,
        primary_key: false,
        is_auto_increment: false,
        default_value: None,
        is_generated: false,
        comment: None,
        collation: None,
        enum_type: Some(tablepro_core::QualifiedTypeName {
            schema: "enum_array_schema".into(),
            name: "label".into(),
        }),
        domain_type: None,
    };
    let parsed = parse_input_for_driver(literal, Some(&column), "postgres").unwrap();
    assert_eq!(parsed, Value::Text(literal.into()));
    assert_eq!(
        parse_input_for_driver("", Some(&column), "postgres").unwrap(),
        Value::Null
    );
    assert_eq!(
        parse_input_for_driver("{}", Some(&column), "postgres").unwrap(),
        Value::Text("{}".into())
    );
    let columns = vec![
        ColumnInfo {
            name: "id".into(),
            data_type: "integer".into(),
            nullable: false,
            primary_key: true,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        },
        column,
    ];
    let (sql, params) = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        Some("enum_array_schema"),
        "items",
        &columns,
        &[(1, parsed)],
        &[Value::Int(2)],
    )
    .unwrap();
    assert!(sql.contains("$1::text::\"enum_array_schema\".\"label\"[]"));
    assert_eq!(params, vec![Value::Text(literal.into()), Value::Int(2)]);
}

#[test]
fn value_contract_postgres_domain_enum_array_grid_literal_stays_text_with_domain_cast() {
    let literal = r#"{"NULL","",東京,NULL}"#;
    let column = ColumnInfo {
        name: "labels".into(),
        data_type: "value_contract_domain_array_label[]".into(),
        nullable: true,
        primary_key: false,
        is_auto_increment: false,
        default_value: None,
        is_generated: false,
        comment: None,
        collation: None,
        enum_type: Some(tablepro_core::QualifiedTypeName {
            schema: "public".into(),
            name: "value_contract_domain_array_label".into(),
        }),
        domain_type: None,
    };
    let parsed = parse_input_for_driver(literal, Some(&column), "postgres").unwrap();
    assert_eq!(parsed, Value::Text(literal.into()));
    let columns = vec![
        ColumnInfo {
            name: "id".into(),
            data_type: "integer".into(),
            nullable: false,
            primary_key: true,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        },
        column,
    ];
    let (sql, params) = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "items",
        &columns,
        &[(1, parsed)],
        &[Value::Int(1)],
    )
    .unwrap();
    assert!(sql.contains("$1::text::\"public\".\"value_contract_domain_array_label\"[]"));
    assert_eq!(params, vec![Value::Text(literal.into()), Value::Int(1)]);
}
