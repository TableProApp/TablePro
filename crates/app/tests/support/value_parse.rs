use super::{
    TypeKind, classify_type, normalize_single_line_input, parse_decimal_value, parse_input_for_column,
    parse_input_for_driver, parse_input_for_grid_cell,
};
use tablepro_core::{ColumnInfo, Value, import::column_kind};

#[path = "postgres_numeric_csv.rs"]
mod postgres_numeric_csv;

#[path = "postgres_temporal.rs"]
mod postgres_temporal;

#[tokio::test]
async fn sqlite_numeric_grid_edit_keeps_parser_and_affinity_behavior() {
    use tablepro_core::{ConnectOptions, DatabaseDriver};

    let connection = drivers_sqlite::SqliteDriver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    let control = crate::services::operation_control::bounded(0);
    connection
        .execute_controlled(
            "CREATE TABLE flexible (id INTEGER PRIMARY KEY, amount NUMERIC)",
            &control,
        )
        .await
        .unwrap();
    connection
        .execute_controlled("INSERT INTO flexible VALUES (1, 0)", &control)
        .await
        .unwrap();

    let columns = connection
        .fetch_columns_controlled(None, "flexible", &control)
        .await
        .unwrap();
    let amount_index = columns.iter().position(|column| column.name == "amount").unwrap();
    let edit = parse_input_for_column("42.50", Some(&columns[amount_index])).unwrap();
    assert_eq!(edit, Value::Decimal("42.50".parse().unwrap()));
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "sqlite",
        None,
        "flexible",
        &columns,
        &[(amount_index, edit)],
        &[Value::Int(1)],
    )
    .unwrap();
    connection
        .execute_in_transaction_controlled(&[update], &control)
        .await
        .unwrap();

    let saved = connection
        .query_controlled("SELECT typeof(amount), amount FROM flexible WHERE id = 1", &control)
        .await
        .unwrap();
    assert_eq!(saved.rows, vec![vec![Value::Text("real".into()), Value::Float(42.5)]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_mongodb_date_grid_edit_preserves_millisecond_instant() {
    use mongodb::bson::{DateTime, doc, oid::ObjectId};
    use tablepro_core::{ConnectOptions, DatabaseDriver};
    use testcontainers::ImageExt;
    use testcontainers_modules::mongo::Mongo;
    use testcontainers_modules::testcontainers::runners::AsyncRunner;

    let container = Mongo::default().with_tag("7").start().await.unwrap();
    let host = container.get_host().await.unwrap().to_string();
    let port = container.get_host_port_ipv4(27017).await.unwrap();
    let native = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .unwrap();
    let collection = native
        .database("appdb")
        .collection::<mongodb::bson::Document>("date_edits");
    let row_id = ObjectId::parse_str("0123456789abcdef01234567").unwrap();
    let initial = DateTime::from_millis(1_780_000_000_123);
    collection
        .insert_one(doc! { "_id": row_id, "event_at": initial })
        .await
        .unwrap();

    let connection = drivers_mongodb::MongodbDriver
        .connect(ConnectOptions {
            host,
            port,
            database: "appdb".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    let before = connection.query("db.date_edits.find({})").await.unwrap();
    let id_index = before.columns.iter().position(|column| column.name == "_id").unwrap();
    let date_index = before
        .columns
        .iter()
        .position(|column| column.name == "event_at")
        .unwrap();
    assert_eq!(before.columns[date_index].data_type, "date");
    let Value::Text(displayed) = &before.rows[0][date_index] else {
        panic!(
            "MongoDB date must remain readable RFC3339 text: {:?}",
            before.rows[0][date_index]
        );
    };
    assert_eq!(
        parse_input_for_driver(displayed, Some(&before.columns[date_index]), "mongodb").unwrap(),
        Value::TimestampTz(
            chrono::DateTime::from_timestamp_millis(initial.timestamp_millis())
                .unwrap()
                .to_utc()
        ),
        "the displayed MongoDB date must parse to the same millisecond instant"
    );

    let rejected = parse_input_for_driver(
        "2026-09-29T18:04:56.789001+05:30",
        Some(&before.columns[date_index]),
        "mongodb",
    )
    .unwrap_err();
    assert_eq!(rejected, "MongoDB BSON dates support millisecond precision only");
    let unchanged = collection.find_one(doc! { "_id": row_id }).await.unwrap().unwrap();
    assert_eq!(
        unchanged.get_datetime("event_at").unwrap().timestamp_millis(),
        initial.timestamp_millis()
    );

    let input = "2026-09-29T18:04:56.789+05:30";
    let edited = parse_input_for_driver(input, Some(&before.columns[date_index]), "mongodb").unwrap();
    let expected_millis = chrono::DateTime::parse_from_rfc3339(input).unwrap().timestamp_millis();
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "mongodb",
        Some("appdb"),
        "date_edits",
        &before.columns,
        &[(date_index, edited)],
        &[before.rows[0][id_index].clone()],
    )
    .unwrap();
    connection.execute_in_transaction(&[update]).await.unwrap();

    let after = connection.query("db.date_edits.find({})").await.unwrap();
    assert_eq!(
        after.rows[0][id_index], before.rows[0][id_index],
        "row identity changed"
    );
    let Value::Text(saved_text) = &after.rows[0][date_index] else {
        panic!(
            "MongoDB date must remain RFC3339 text after edit: {:?}",
            after.rows[0][date_index]
        );
    };
    assert_eq!(
        parse_input_for_driver(saved_text, Some(&after.columns[date_index]), "mongodb").unwrap(),
        Value::TimestampTz(
            chrono::DateTime::from_timestamp_millis(expected_millis)
                .unwrap()
                .to_utc()
        )
    );
    let persisted = collection.find_one(doc! { "_id": row_id }).await.unwrap().unwrap();
    assert_eq!(persisted.get("_id"), Some(&mongodb::bson::Bson::ObjectId(row_id)));
    assert_eq!(
        persisted.get_datetime("event_at").unwrap().timestamp_millis(),
        expected_millis,
        "the server must store the edited UTC instant at BSON millisecond precision"
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_mongodb_decimal128_grid_edit_preserves_wide_precision() {
    use mongodb::bson::{Decimal128, doc, oid::ObjectId};
    use tablepro_core::{ConnectOptions, DatabaseDriver};
    use testcontainers::ImageExt;
    use testcontainers_modules::mongo::Mongo;
    use testcontainers_modules::testcontainers::runners::AsyncRunner;

    let container = Mongo::default().with_tag("7").start().await.unwrap();
    let host = container.get_host().await.unwrap().to_string();
    let port = container.get_host_port_ipv4(27017).await.unwrap();
    let native = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .unwrap();
    let collection = native
        .database("appdb")
        .collection::<mongodb::bson::Document>("decimal128_grid_edits");
    let row_id = ObjectId::parse_str("0123456789abcdef01234567").unwrap();
    let wide = "1234567890123456789012345678901234";
    let initial = "9.9900".parse::<Decimal128>().unwrap();
    let expected = wide.parse::<Decimal128>().unwrap();
    collection
        .insert_one(doc! { "_id": row_id, "amount": initial })
        .await
        .unwrap();

    let connection = drivers_mongodb::MongodbDriver
        .connect(ConnectOptions {
            host,
            port,
            database: "appdb".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    let before = connection.query("db.decimal128_grid_edits.find({})").await.unwrap();
    let id_index = before.columns.iter().position(|column| column.name == "_id").unwrap();
    let amount_index = before
        .columns
        .iter()
        .position(|column| column.name == "amount")
        .unwrap();
    assert_eq!(before.columns[amount_index].data_type, "decimal");
    assert_eq!(before.rows[0][amount_index], Value::Text(initial.to_string()));

    let edited = parse_input_for_driver(wide, Some(&before.columns[amount_index]), "mongodb").unwrap();
    assert_eq!(edited, Value::Json(serde_json::json!({"$numberDecimal": wide})));
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "mongodb",
        Some("appdb"),
        "decimal128_grid_edits",
        &before.columns,
        &[(amount_index, edited)],
        &[before.rows[0][id_index].clone()],
    )
    .unwrap();
    connection.execute_in_transaction(&[update]).await.unwrap();

    let after = connection.query("db.decimal128_grid_edits.find({})").await.unwrap();
    assert_eq!(
        after.rows[0][id_index], before.rows[0][id_index],
        "row identity changed"
    );
    assert_eq!(after.rows[0][amount_index], Value::Text(wide.into()));
    let persisted = collection.find_one(doc! { "_id": row_id }).await.unwrap().unwrap();
    assert_eq!(persisted.get("_id"), Some(&mongodb::bson::Bson::ObjectId(row_id)));
    assert_eq!(
        persisted.get("amount"),
        Some(&mongodb::bson::Bson::Decimal128(expected))
    );

    let cleared = parse_input_for_driver("", Some(&after.columns[amount_index]), "mongodb").unwrap();
    assert_eq!(cleared, Value::Null);
    let clear = tablepro_core::sql_dialect::build_keyed_update(
        "mongodb",
        Some("appdb"),
        "decimal128_grid_edits",
        &after.columns,
        &[(amount_index, cleared)],
        &[after.rows[0][id_index].clone()],
    )
    .unwrap();
    connection.execute_in_transaction(&[clear]).await.unwrap();
    let persisted = collection.find_one(doc! { "_id": row_id }).await.unwrap().unwrap();
    assert_eq!(persisted.get("amount"), Some(&mongodb::bson::Bson::Null));
}

#[cfg(feature = "duckdb")]
#[tokio::test]
async fn value_contract_duckdb_interval_grid_edit_preserves_native_components() {
    use tablepro_core::{ConnectOptions, DatabaseDriver};

    let connection = drivers_duckdb::DuckdbDriver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    connection
        .execute("CREATE TABLE interval_grid (id INTEGER PRIMARY KEY, span INTERVAL)")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO interval_grid VALUES (1, INTERVAL '1 month 2 days 3 microseconds')")
        .await
        .unwrap();

    let columns = connection.fetch_columns(None, "interval_grid").await.unwrap();
    let id_index = columns.iter().position(|column| column.name == "id").unwrap();
    assert!(
        columns[id_index].primary_key,
        "DuckDB must expose its primary key for keyed grid edits"
    );
    let span_index = columns.iter().position(|column| column.name == "span").unwrap();
    let edit = parse_input_for_column("-2 months 4 days -5 microseconds", Some(&columns[span_index])).unwrap();
    assert_eq!(edit, Value::Text("-2 months 4 days -5 microseconds".into()));

    let update = tablepro_core::sql_dialect::build_keyed_update(
        "duckdb",
        None,
        "interval_grid",
        &columns,
        &[(span_index, edit)],
        &[Value::Int(1)],
    )
    .unwrap();
    connection.execute_params(&update.0, &update.1).await.unwrap();

    let saved = connection
        .query(
            "SELECT typeof(span), date_part('month', span)::INTEGER, \
                        date_part('day', span)::INTEGER, date_part('microsecond', span)::BIGINT \
                 FROM interval_grid WHERE id = 1",
        )
        .await
        .unwrap();
    assert_eq!(
        saved.rows,
        vec![vec![
            Value::Text("INTERVAL".into()),
            Value::Int(-2),
            Value::Int(4),
            Value::Int(-5),
        ]]
    );
}

#[cfg(feature = "duckdb")]
#[tokio::test]
async fn value_contract_duckdb_timestamptz_grid_edit_refuses_submicro_rounding() {
    use tablepro_core::{ConnectOptions, DatabaseDriver};

    let connection = drivers_duckdb::DuckdbDriver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    connection
        .execute("CREATE TABLE tz_grid (id INTEGER PRIMARY KEY, event_at TIMESTAMPTZ)")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO tz_grid VALUES (1, TIMESTAMPTZ '2026-09-29 12:34:56.123456+00')")
        .await
        .unwrap();

    let columns = connection.fetch_columns(None, "tz_grid").await.unwrap();
    let id_index = columns.iter().position(|column| column.name == "id").unwrap();
    let event_index = columns.iter().position(|column| column.name == "event_at").unwrap();
    assert!(columns[id_index].primary_key);
    let original = connection
        .query("SELECT epoch_us(event_at) FROM tz_grid WHERE id = 1")
        .await
        .unwrap();

    let submicro_instant = chrono::DateTime::parse_from_rfc3339("2026-09-29T12:34:56.123456789+00:00")
        .unwrap()
        .to_utc();
    let submicro = Value::TimestampTz(submicro_instant);
    let implicit_cast = connection
        .query_params(
            "SELECT typeof(CAST(? AS TIMESTAMPTZ)), epoch_us(CAST(? AS TIMESTAMPTZ))",
            &[submicro.clone(), submicro.clone()],
        )
        .await
        .unwrap();
    assert_eq!(
        implicit_cast.rows,
        vec![vec![
            Value::Text("TIMESTAMP WITH TIME ZONE".into()),
            Value::Int(submicro_instant.timestamp_micros()),
        ]],
        "DuckDB's native TIMESTAMPTZ cast drops sub-microsecond digits"
    );

    let rejected = parse_input_for_driver(
        "2026-09-29T12:34:56.123456789+00:00",
        Some(&columns[event_index]),
        "duckdb",
    )
    .unwrap_err();
    assert_eq!(rejected, "DuckDB TIMESTAMPTZ supports microsecond precision only");
    assert_eq!(
        connection
            .query("SELECT epoch_us(event_at) FROM tz_grid WHERE id = 1")
            .await
            .unwrap()
            .rows,
        original.rows,
        "a rejected sub-microsecond edit must leave the stored instant unchanged"
    );

    let accepted = parse_input_for_driver(
        "2026-09-29T18:04:56.654321000+05:30",
        Some(&columns[event_index]),
        "duckdb",
    )
    .unwrap();
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "duckdb",
        None,
        "tz_grid",
        &columns,
        &[(event_index, accepted)],
        &[Value::Int(1)],
    )
    .unwrap();
    connection.execute_params(&update.0, &update.1).await.unwrap();
    let saved = connection
        .query("SELECT typeof(event_at), epoch_us(event_at) FROM tz_grid WHERE id = 1")
        .await
        .unwrap();
    let expected = chrono::DateTime::parse_from_rfc3339("2026-09-29T18:04:56.654321000+05:30")
        .unwrap()
        .timestamp_micros();
    assert_eq!(
        saved.rows,
        vec![vec![
            Value::Text("TIMESTAMP WITH TIME ZONE".into()),
            Value::Int(expected)
        ]]
    );
}

#[test]
fn value_contract_parser_preserves_boundaries_and_rejects_rounding() {
    super::parser_contract::assert_numeric_parsers(
        |text| super::parse_int_value(text).ok(),
        |text| super::parse_decimal_value(text).ok(),
        |text| super::parse_float_value(text).ok(),
    );
}

#[test]
fn decimal_preservation_rejects_an_edit_that_would_round() {
    assert!(super::parse_decimal_value("0.123456789012345678901234567891").is_err());
    for text in [
        "79228162514264337593543950335",
        "-79228162514264337593543950335",
        "0.0000000000000000000000000001",
        "12.3400",
    ] {
        assert!(matches!(
            super::parse_decimal_value(text),
            Ok(Value::Decimal(value)) if value.to_string() == text
        ));
    }
    for text in [
        "79228162514264337593543950336",
        "-79228162514264337593543950336",
        "0.00000000000000000000000000001",
    ] {
        assert!(super::parse_decimal_value(text).is_err(), "{text}");
    }
}

#[test]
fn postgres_numeric_specials_remain_exact_text_only_for_postgres() {
    let column = col("numeric", false);
    for input in ["NaN", "Infinity", "-Infinity"] {
        assert_eq!(
            parse_input_for_driver(input, Some(&column), "postgres"),
            Ok(Value::Text(input.into()))
        );
        assert!(parse_input_for_driver(input, Some(&column), "mysql").is_err());
    }
    assert_eq!(
        parse_input_for_driver("12.50", Some(&column), "postgres"),
        Ok(Value::Decimal("12.50".parse().unwrap()))
    );
}

#[test]
fn postgres_wide_numeric_edits_stay_exact_text_when_decimal_cannot_represent_them() {
    let column = col("numeric(80,40)", false);
    let wide = "1234567890123456789012345678901234567890.1234567890123456789012345678901234567890";
    assert!(parse_decimal_value(wide).is_err());
    let parsed = parse_input_for_driver(wide, Some(&column), "postgres").unwrap();
    assert_eq!(parsed, Value::Text(wide.into()));
    let mut columns = vec![col("id", false), column.clone()];
    columns[0].primary_key = true;
    let (sql, params) = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "wide_numeric",
        &columns,
        &[(1, parsed)],
        &[Value::Int(1)],
    )
    .unwrap();
    assert!(sql.contains("$1::text::pg_catalog.numeric"));
    assert_eq!(params[0], Value::Text(wide.into()));
    let max_precision = format!("0.{}", "1234567890".repeat(100));
    assert!(parse_decimal_value(&max_precision).is_err());
    assert_eq!(
        parse_input_for_driver(&max_precision, Some(&col("numeric(1000,1000)", false)), "postgres"),
        Ok(Value::Text(max_precision.clone()))
    );
    assert!(parse_input_for_driver(wide, Some(&column), "mysql").is_err());
    for malformed in ["", ".", "+", "--1", "1e", "1e+", "1.2.3", "1x", "1; DROP TABLE t"] {
        assert!(
            parse_input_for_driver(malformed, Some(&column), "postgres").is_err(),
            "accepted malformed PostgreSQL numeric literal {malformed:?}"
        );
    }
    assert!(parse_input_for_driver(wide, Some(&col("money", false)), "postgres").is_err());
}

#[test]
fn postgres_numeric_fallback_covers_integer_fraction_and_exponent_grammar() {
    let column = col("numeric", false);
    let wide_integer = "9".repeat(100);
    let wide_fraction = format!(".{}", "1".repeat(100));
    let wide_exponent = format!("{}e+2", "9".repeat(40));

    for value in [&wide_integer, &wide_fraction, &wide_exponent] {
        assert!(
            parse_decimal_value(value).is_err(),
            "{value:?} must use the text fallback"
        );
        assert_eq!(
            parse_input_for_driver(value, Some(&column), "postgres"),
            Ok(Value::Text(value.clone())),
            "valid PostgreSQL numeric literal {value:?} must remain exact"
        );
    }
}

#[test]
fn value_contract_mysql_bit_parser_enforces_declared_width_and_safe_range() {
    for (data_type, input, expected) in [
        ("bit(1)", "0", Value::Bool(false)),
        ("bit(1)", "1", Value::Bool(true)),
        ("bit(2)", "3", Value::Int(3)),
        ("bit(8)", "170", Value::Int(170)),
        ("bit(8)", "255", Value::Int(255)),
        ("bit(63)", "9223372036854775807", Value::Int(i64::MAX)),
        ("bit(64)", "9223372036854775807", Value::Int(i64::MAX)),
    ] {
        assert_eq!(
            parse_input_for_driver(input, Some(&col(data_type, false)), "mysql"),
            Ok(expected),
            "{input:?} as {data_type}"
        );
    }

    for (data_type, input) in [
        ("bit(1)", "2"),
        ("bit(2)", "4"),
        ("bit(8)", "256"),
        ("bit(8)", "-1"),
        ("bit(64)", "9223372036854775808"),
    ] {
        assert!(
            parse_input_for_driver(input, Some(&col(data_type, false)), "mysql").is_err(),
            "out-of-range {input:?} must be refused for {data_type}"
        );
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_mysql_bit_parser_edits_preserve_native_values() {
    use tablepro_core::{ConnectOptions, DatabaseDriver, TlsConfig};
    use testcontainers::ImageExt;
    use testcontainers::runners::AsyncRunner;
    use testcontainers_modules::mysql::Mysql;

    let container = Mysql::default()
        .with_env_var("MYSQL_ROOT_PASSWORD", "tablepro_test")
        .with_cmd(["--default-authentication-plugin=mysql_native_password"])
        .start()
        .await
        .unwrap();
    let options = ConnectOptions {
        host: container.get_host().await.unwrap().to_string(),
        port: container.get_host_port_ipv4(3306).await.unwrap(),
        database: "test".into(),
        username: "root".into(),
        password: secrecy::SecretString::new("tablepro_test".to_string().into()),
        tls: TlsConfig::disabled(),
        ..Default::default()
    };
    let connection = drivers_mysql::MysqlDriver.connect(options).await.unwrap();
    connection
        .execute(
            "CREATE TABLE bit_edit_contract (
                    id INT PRIMARY KEY,
                    one_bit BIT(1),
                    eight_bit BIT(8),
                    sixty_three_bit BIT(63),
                    sixty_four_bit BIT(64)
                )",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO bit_edit_contract VALUES
                 (1, b'1', b'00000000', b'00000000', x'8000000000000000')",
        )
        .await
        .unwrap();

    let columns = connection.fetch_columns(None, "bit_edit_contract").await.unwrap();
    let column_index = |name: &str| columns.iter().position(|column| column.name == name).unwrap();
    let id = column_index("id");
    let one_bit = column_index("one_bit");
    let eight_bit = column_index("eight_bit");
    let sixty_three_bit = column_index("sixty_three_bit");
    let sixty_four_bit = column_index("sixty_four_bit");
    assert!(columns[id].primary_key);
    assert_eq!(columns[one_bit].data_type, "bit(1)");
    assert_eq!(columns[eight_bit].data_type, "bit(8)");
    assert_eq!(columns[sixty_three_bit].data_type, "bit(63)");
    assert_eq!(columns[sixty_four_bit].data_type, "bit(64)");

    let bit_one = parse_input_for_driver("0", Some(&columns[one_bit]), "mysql").unwrap();
    let bit_eight = parse_input_for_driver("170", Some(&columns[eight_bit]), "mysql").unwrap();
    let bit_sixty_three =
        parse_input_for_driver("9223372036854775807", Some(&columns[sixty_three_bit]), "mysql").unwrap();
    assert_eq!(bit_one, Value::Bool(false));
    assert_eq!(bit_eight, Value::Int(170));
    assert_eq!(bit_sixty_three, Value::Int(i64::MAX));
    assert!(parse_input_for_driver("9223372036854775808", Some(&columns[sixty_four_bit]), "mysql").is_err());

    let update = tablepro_core::sql_dialect::build_keyed_update(
        "mysql",
        None,
        "bit_edit_contract",
        &columns,
        &[
            (one_bit, bit_one),
            (eight_bit, bit_eight),
            (sixty_three_bit, bit_sixty_three),
        ],
        &[Value::Int(1)],
    )
    .unwrap();
    assert_eq!(connection.execute_in_transaction(&[update]).await.unwrap(), vec![1]);

    let saved = connection
        .query(
            "SELECT one_bit, eight_bit, sixty_three_bit, sixty_four_bit,
                        HEX(one_bit), HEX(eight_bit), HEX(sixty_three_bit), HEX(sixty_four_bit)
                 FROM bit_edit_contract WHERE id = 1",
        )
        .await
        .unwrap();
    assert_eq!(
        saved.rows,
        vec![vec![
            Value::Int(0),
            Value::Int(170),
            Value::Int(i64::MAX),
            Value::Bytes(vec![0x80, 0, 0, 0, 0, 0, 0, 0]),
            Value::Text("0".into()),
            Value::Text("AA".into()),
            Value::Text("7FFFFFFFFFFFFFFF".into()),
            Value::Text("8000000000000000".into()),
        ]]
    );
}

#[test]
fn postgres_text_array_grid_literal_stays_text_for_the_shared_cast() {
    let literal = r#"{"plain",NULL,"quote \" slash \\, comma"}"#;
    let mut columns = vec![col("id", false), col("text[]", false)];
    columns[0].primary_key = true;
    let parsed = parse_input_for_driver(literal, Some(&columns[1]), "postgres").unwrap();
    assert_eq!(parsed, Value::Text(literal.into()));
    let (sql, params) = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "text_array_grid",
        &columns,
        &[(1, parsed)],
        &[Value::Int(1)],
    )
    .unwrap();
    assert!(sql.contains("$1::text::pg_catalog.text[]"));
    assert_eq!(params[0], Value::Text(literal.into()));
}

#[test]
fn postgres_numeric_array_grid_literal_stays_text_for_the_shared_cast() {
    let literal =
        r#"{1234567890123456789012345678901234567890.12345678901234567890,1.2300,NaN,Infinity,-Infinity,NULL}"#;
    let mut columns = vec![col("id", false), col("numeric[]", false)];
    columns[0].primary_key = true;
    let parsed = parse_input_for_driver(literal, Some(&columns[1]), "postgres").unwrap();
    assert_eq!(parsed, Value::Text(literal.into()));
    let (sql, params) = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "numeric_array_grid",
        &columns,
        &[(1, parsed)],
        &[Value::Int(1)],
    )
    .unwrap();
    assert!(sql.contains("$1::text::pg_catalog.numeric[]"));
    assert_eq!(params[0], Value::Text(literal.into()));
}

#[test]
fn normalize_single_line_leaves_plain_text_untouched() {
    assert_eq!(normalize_single_line_input("hello world"), "hello world");
}

#[test]
fn normalize_single_line_collapses_a_multiline_paste_into_one_line() {
    assert_eq!(
        normalize_single_line_input("first\nsecond\r\nthird"),
        "first second  third"
    );
}

#[test]
fn normalize_single_line_preserves_other_whitespace_and_array_literals() {
    let text = "  padded  CHAR  ";
    assert_eq!(normalize_single_line_input(text), text);

    let literal = r#"{"a  b", " c "}"#;
    let normalized = normalize_single_line_input(literal);
    assert_eq!(normalized, literal);
    let column = col("text[]", true);
    let parsed = parse_input_for_driver(&normalized, Some(&column), "postgres").unwrap();
    assert_eq!(parsed, Value::Text(literal.into()));
    let mut columns = vec![col("integer", false), column];
    columns[0].primary_key = true;
    let (sql, params) = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "whitespace_contract",
        &columns,
        &[(1, parsed)],
        &[Value::Int(1)],
    )
    .unwrap();
    assert!(sql.contains("$1::text::pg_catalog.text[]"));
    assert_eq!(params[0], Value::Text(literal.into()));
}

fn col(data_type: &str, nullable: bool) -> ColumnInfo {
    ColumnInfo {
        name: "x".into(),
        data_type: data_type.into(),
        nullable,
        primary_key: false,
        is_auto_increment: false,
        default_value: None,
        is_generated: false,
        comment: None,
        collation: None,
        enum_type: None,
        domain_type: None,
    }
}

#[test]
fn value_contract_mongodb_date_parser_preserves_milliseconds_and_refuses_rounding() {
    let column = col("date", false);
    let input = "2026-09-29T18:04:56.789+05:30";
    assert_eq!(
        parse_input_for_driver(input, Some(&column), "mongodb").unwrap(),
        Value::TimestampTz(chrono::DateTime::parse_from_rfc3339(input).unwrap().to_utc()),
        "MongoDB date edit input must retain the displayed UTC instant and millisecond"
    );
    assert_eq!(
        parse_input_for_driver("2026-09-29T18:04:56.789000+05:30", Some(&column), "mongodb").unwrap(),
        Value::TimestampTz(
            chrono::DateTime::parse_from_rfc3339("2026-09-29T18:04:56.789000+05:30")
                .unwrap()
                .to_utc()
        ),
        "precision beyond milliseconds is safe only when all extra digits are zero"
    );
    assert_eq!(
        parse_input_for_driver("2026-09-29T18:04:56.789001+05:30", Some(&column), "mongodb").unwrap_err(),
        "MongoDB BSON dates support millisecond precision only"
    );
    assert!(
        parse_input_for_driver(input, Some(&column), "sqlite").is_err(),
        "the MongoDB date spelling must not change another driver's date contract"
    );
    assert!(matches!(
        parse_input_for_driver("2026-09-29", Some(&column), "mongodb").unwrap(),
        Value::Date(_)
    ));
}

#[test]
fn mongodb_binary_subtype_edits_parse_as_extended_json() {
    let data_type = "binData-subtype-04";
    let column = col(data_type, false);
    let input = r#"{"$binary":{"base64":"AP9B","subType":"04"}}"#;
    let expected = serde_json::json!({"$binary": {"base64": "AP9B", "subType": "04"}});
    assert_eq!(classify_type(&data_type.to_ascii_lowercase()), TypeKind::Json);
    assert_eq!(column_kind(data_type), tablepro_core::import::ColumnKind::Json);
    let generic_kind = column_kind("binData-subtype-00");
    assert_eq!(generic_kind, tablepro_core::import::ColumnKind::Bytes);
    assert_eq!(
        tablepro_core::import::parse_cell("\\x00ff", generic_kind),
        Ok(Value::Bytes(vec![0, 255]))
    );
    assert_eq!(
        parse_input_for_driver(input, Some(&column), "mongodb").unwrap(),
        Value::Json(expected)
    );
}

#[test]
fn value_contract_mongodb_decimal128_parser_preserves_wide_precision() {
    let column = col("decimal", false);
    let wide_integer = "1234567890123456789012345678901234";
    assert!(parse_decimal_value(wide_integer).is_err());
    assert_eq!(
        parse_input_for_driver(wide_integer, Some(&column), "mongodb").unwrap(),
        Value::Json(serde_json::json!({"$numberDecimal": wide_integer})),
        "34-digit Decimal128 values must not be rejected by rust_decimal's narrower range"
    );

    let wide_fraction = "0.1234567890123456789012345678901234";
    assert_eq!(
        parse_input_for_driver(wide_fraction, Some(&column), "mongodb").unwrap(),
        Value::Json(serde_json::json!({"$numberDecimal": wide_fraction}))
    );
    let over_precision = "12345678901234567890123456789012345";
    assert!(
        parse_input_for_driver(over_precision, Some(&column), "mongodb").is_err(),
        "input beyond Decimal128 precision must be refused rather than rounded"
    );
    assert!(
        parse_input_for_driver(wide_integer, Some(&column), "mysql").is_err(),
        "MongoDB Decimal128 fallback must not change another driver's decimal contract"
    );
}

fn col_with_default(data_type: &str, default: &str) -> ColumnInfo {
    let mut c = col(data_type, false);
    c.default_value = Some(default.into());
    c
}

#[test]
fn classify_disambiguates_overlapping_types() {
    assert_eq!(classify_type("tinyint(1)"), TypeKind::Bool);
    assert_eq!(classify_type("bit(1)"), TypeKind::Bool);
    assert_eq!(classify_type("bit(8)"), TypeKind::Int);
    assert_eq!(classify_type("bit(64)"), TypeKind::Int);
    assert_eq!(classify_type("tinyint"), TypeKind::Int);
    assert_eq!(classify_type("uuid"), TypeKind::Uuid);
    assert_eq!(classify_type("jsonb"), TypeKind::Json);
    assert_eq!(classify_type("object"), TypeKind::Json);
    assert_eq!(classify_type("array"), TypeKind::Json);
    assert_eq!(classify_type("objectid"), TypeKind::Json);
    for mongo_special in [
        "bsontimestamp",
        "regex",
        "javascript",
        "javascriptwithscope",
        "symbol",
        "undefined",
        "dbpointer",
        "minkey",
        "maxkey",
    ] {
        assert_eq!(classify_type(mongo_special), TypeKind::Json, "{mongo_special}");
    }
    assert_eq!(classify_type("timestamptz"), TypeKind::TimestampTz);
    assert_eq!(classify_type("timestamp with time zone"), TypeKind::TimestampTz);
    assert_eq!(classify_type("timestamp without time zone"), TypeKind::DateTime);
    assert_eq!(classify_type("timestamp"), TypeKind::DateTime);
    assert_eq!(classify_type("datetime"), TypeKind::DateTime);
    assert_eq!(classify_type("date"), TypeKind::Date);
    assert_eq!(classify_type("time"), TypeKind::Time);
    assert_eq!(classify_type("integer"), TypeKind::Int);
    assert_eq!(classify_type("int4"), TypeKind::Int);
    assert_eq!(classify_type("bigint"), TypeKind::Int);
    assert_eq!(classify_type("decimal(10,2)"), TypeKind::Decimal);
    assert_eq!(classify_type("numeric"), TypeKind::Decimal);
    assert_eq!(classify_type("double precision"), TypeKind::Float);
    assert_eq!(classify_type("real"), TypeKind::Float);
    assert_eq!(classify_type("text"), TypeKind::Text);
    assert_eq!(classify_type("varchar(255)"), TypeKind::Text);
    // "interval" must NOT be classified as Int even though it
    // contains "int".
    assert_eq!(classify_type("interval"), TypeKind::Text);
}

#[test]
fn mssql_datetimeoffset_parser_preserves_text_and_refuses_lossy_input() {
    let column = col("datetimeoffset(3)", false);
    let valid = "2024-01-02 03:04:05.123 +05:30";
    assert_eq!(
        parse_input_for_driver(valid, Some(&column), "mssql"),
        Ok(Value::Text(valid.into()))
    );
    assert_eq!(
        parse_input_for_driver(
            "0001-01-01 00:00:00 -14:00",
            Some(&col("datetimeoffset(0)", false)),
            "mssql"
        ),
        Ok(Value::Text("0001-01-01 00:00:00 -14:00".into()))
    );
    for invalid in [
        "2024-01-02 03:04:05.1234 +05:30",
        "2024-01-02 03:04:05.123 +14:01",
        "0001-01-01 00:00:00 +14:00",
        "9999-12-31 23:59:59 -14:00",
        "2024-01-02T03:04:05.123+05:30",
        "2024-01-02 03:04:05.123",
    ] {
        assert!(
            parse_input_for_driver(invalid, Some(&column), "mssql").is_err(),
            "must refuse {invalid}"
        );
    }
    assert!(parse_input_for_driver(valid, Some(&column), "postgres").is_err());
}

#[test]
fn empty_on_nullable_yields_null() {
    let r = parse_input_for_column("", Some(&col("text", true))).unwrap();
    assert!(matches!(r, Value::Null));
}

#[test]
fn empty_on_not_null_with_default_yields_null() {
    let r = parse_input_for_column("", Some(&col_with_default("timestamp", "now()"))).unwrap();
    assert!(matches!(r, Value::Null));
}

#[test]
fn empty_on_not_null_no_default_is_rejected() {
    let r = parse_input_for_column("", Some(&col("text", false)));
    assert!(r.is_err());
    assert!(r.unwrap_err().contains("required"));
}

#[test]
fn empty_driver_input_obeys_shared_nullable_and_required_rules() {
    for (driver, data_type) in [
        ("mysql", "int"),
        ("mongodb", "decimal"),
        ("postgres", "numeric"),
        ("duckdb", "timestamp"),
    ] {
        assert!(matches!(
            parse_input_for_driver("", Some(&col(data_type, true)), driver).unwrap(),
            Value::Null
        ));
        assert!(matches!(
            parse_input_for_driver("", Some(&col_with_default(data_type, "default")), driver).unwrap(),
            Value::Null
        ));
        assert!(
            parse_input_for_driver("", Some(&col(data_type, false)), driver)
                .unwrap_err()
                .contains("required")
        );
    }
}

#[test]
fn parses_int_decimal_float_bool() {
    assert!(matches!(
        parse_input_for_column("42", Some(&col("integer", false))).unwrap(),
        Value::Int(42)
    ));
    assert!(matches!(
        parse_input_for_column("3.14", Some(&col("real", false))).unwrap(),
        Value::Float(_)
    ));
    assert!(matches!(
        parse_input_for_column("99.99", Some(&col("decimal(10,2)", false))).unwrap(),
        Value::Decimal(_)
    ));
    assert!(matches!(
        parse_input_for_column("yes", Some(&col("boolean", false))).unwrap(),
        Value::Bool(true)
    ));
    assert!(matches!(
        parse_input_for_column("0", Some(&col("tinyint(1)", false))).unwrap(),
        Value::Bool(false)
    ));
    assert_eq!(
        parse_input_for_column("1", Some(&col("bit(1)", false))).unwrap(),
        Value::Bool(true)
    );
    assert_eq!(
        parse_input_for_column("0", Some(&col("bit(1)", false))).unwrap(),
        Value::Bool(false)
    );
    assert_eq!(
        parse_input_for_column("170", Some(&col("bit(8)", false))).unwrap(),
        Value::Int(170)
    );
    assert!(parse_input_for_column("256", Some(&col("bit(8)", false))).is_err());
    assert!(parse_input_for_column("-1", Some(&col("bit(8)", false))).is_err());
    assert_eq!(
        parse_input_for_column("9223372036854775807", Some(&col("bit(64)", false))).unwrap(),
        Value::Int(i64::MAX)
    );
    assert!(parse_input_for_column("9223372036854775808", Some(&col("bit(64)", false))).is_err());
}

#[test]
fn parses_uuid_json_date_time_datetime_timestamptz() {
    let uuid = parse_input_for_column("550e8400-e29b-41d4-a716-446655440000", Some(&col("uuid", false))).unwrap();
    assert!(matches!(uuid, Value::Uuid(_)));

    let json = parse_input_for_column(r#"{"a":1}"#, Some(&col("jsonb", false))).unwrap();
    assert!(matches!(json, Value::Json(_)));

    let mongo_object = parse_input_for_column(
        r#"{"amount":{"$numberDecimal":"12.3400"}}"#,
        Some(&col("object", false)),
    )
    .unwrap();
    assert_eq!(
        mongo_object,
        Value::Json(serde_json::json!({"amount": {"$numberDecimal": "12.3400"}}))
    );
    assert_eq!(
        parse_input_for_column(r#"{"$oid":"507f1f77bcf86cd799439011"}"#, Some(&col("ObjectId", false))).unwrap(),
        Value::Json(serde_json::json!({"$oid": "507f1f77bcf86cd799439011"}))
    );
    assert_eq!(
        parse_input_for_column(r#"[{"ordinal":{"$numberLong":"7"}}]"#, Some(&col("array", false))).unwrap(),
        Value::Json(serde_json::json!([{"ordinal": {"$numberLong": "7"}}]))
    );

    let date = parse_input_for_column("2024-01-15", Some(&col("date", false))).unwrap();
    assert!(matches!(date, Value::Date(_)));

    let time = parse_input_for_column("14:30:00", Some(&col("time", false))).unwrap();
    assert!(matches!(time, Value::Time(_)));
    let time_short = parse_input_for_column("14:30", Some(&col("time", false))).unwrap();
    assert!(matches!(time_short, Value::Time(_)));

    let datetime = parse_input_for_column("2024-01-15 14:30:00", Some(&col("timestamp", false))).unwrap();
    assert!(matches!(datetime, Value::DateTime(_)));
    let datetime_t = parse_input_for_column("2024-01-15T14:30:00", Some(&col("datetime", false))).unwrap();
    assert!(matches!(datetime_t, Value::DateTime(_)));

    let ts = parse_input_for_column("2024-01-15T14:30:00Z", Some(&col("timestamptz", false))).unwrap();
    assert!(matches!(ts, Value::TimestampTz(_)));
}

#[test]
fn rejects_invalid_type_specific_input() {
    assert!(parse_input_for_column("not-a-number", Some(&col("integer", false))).is_err());
    assert!(parse_input_for_column("not-a-uuid", Some(&col("uuid", false))).is_err());
    assert!(parse_input_for_column("{not json", Some(&col("jsonb", false))).is_err());
    assert!(parse_input_for_column("2024/01/15", Some(&col("date", false))).is_err());
    assert!(parse_input_for_column("1000000-01-01", Some(&col("date", false))).is_err());
    assert!(parse_input_for_column("294276-12-31 23:59:59.999999", Some(&col("timestamp", false))).is_err());
    assert_eq!(
        parse_input_for_driver("1000000-02-29", Some(&col("date", false)), "postgres").unwrap(),
        Value::Text("1000000-02-29".into())
    );
    assert_eq!(
        parse_input_for_driver(
            "294276-12-31 23:59:59.999999",
            Some(&col("timestamp", false)),
            "postgres"
        )
        .unwrap(),
        Value::Text("294276-12-31 23:59:59.999999".into())
    );
    assert!(parse_input_for_driver("1000001-02-29", Some(&col("date", false)), "postgres").is_err());
    assert!(
        parse_input_for_driver(
            "294276-12-31 23:59:59.999999001",
            Some(&col("timestamp", false)),
            "postgres"
        )
        .is_err()
    );
    assert!(parse_input_for_column("13:00:99", Some(&col("time", false))).is_err());
    assert!(parse_input_for_column("not-a-date", Some(&col("timestamp", false))).is_err());
    assert!(parse_input_for_column("maybe", Some(&col("boolean", false))).is_err());
}

#[test]
fn unknown_type_falls_through_to_text() {
    let r = parse_input_for_column("anything goes here", Some(&col("varchar(255)", false))).unwrap();
    assert!(matches!(r, Value::Text(_)));

    let mut enum_column = col("value_contract_enum_schema.value_contract_grid_enum", false);
    enum_column.enum_type = Some(tablepro_core::QualifiedTypeName {
        schema: "value_contract_enum_schema".into(),
        name: "value_contract_grid_enum".into(),
    });
    assert_eq!(
        parse_input_for_driver("paused", Some(&enum_column), "postgres").unwrap(),
        Value::Text("paused".into())
    );
    assert_eq!(
        parse_input_for_driver("NULL", Some(&enum_column), "postgres").unwrap(),
        Value::Text("NULL".into())
    );

    let mut enum_domain_column = col("value_contract_enum_schema.value_contract_grid_domain", false);
    enum_domain_column.enum_type = enum_column.enum_type;
    assert_eq!(
        parse_input_for_driver("paused", Some(&enum_domain_column), "postgres").unwrap(),
        Value::Text("paused".into())
    );
}

#[test]
fn clickhouse_enum_grid_accepts_quoted_empty_and_literal_null_labels() {
    let enum_column = col("Enum8('' = 1, 'NULL' = 2, 'O''Brien' = 3)", false);
    assert_eq!(
        parse_input_for_grid_cell("''", Some(&enum_column), "clickhouse", None).unwrap(),
        Value::Text(String::new())
    );
    assert_eq!(
        parse_input_for_grid_cell("'NULL'", Some(&enum_column), "clickhouse", None).unwrap(),
        Value::Text("NULL".into())
    );
    assert_eq!(
        parse_input_for_grid_cell("'O''Brien'", Some(&enum_column), "clickhouse", None).unwrap(),
        Value::Text("O'Brien".into())
    );
    let nullable_enum_column = col("Nullable(Enum16('' = 1, 'NULL' = 2))", true);
    assert_eq!(
        parse_input_for_grid_cell("", Some(&nullable_enum_column), "clickhouse", None).unwrap(),
        Value::Null
    );
}

#[test]
fn null_sentinel_typed_literally_is_text() {
    let r = parse_input_for_column("<NULL>", Some(&col("text", true))).unwrap();
    match r {
        Value::Text(s) => assert_eq!(s, "<NULL>"),
        other => panic!("expected Text(\"<NULL>\") got {other:?}"),
    }
}

#[path = "duckdb_temporal_edit_contract.rs"]
mod duckdb_temporal_edit_contract;

#[path = "sqlite_numeric_affinity.rs"]
mod sqlite_numeric_affinity;
