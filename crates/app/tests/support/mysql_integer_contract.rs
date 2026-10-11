use super::parse_input_for_driver;
use tablepro_core::{ColumnInfo, Value};

fn col(data_type: &str, primary_key: bool) -> ColumnInfo {
    ColumnInfo {
        name: "value".into(),
        data_type: data_type.into(),
        nullable: true,
        primary_key,
        is_auto_increment: false,
        is_generated: false,
        default_value: None,
        comment: None,
        collation: None,
        enum_type: None,
        domain_type: None,
    }
}

#[test]
fn value_contract_mysql_integer_parser_enforces_signed_and_unsigned_widths() {
    for (data_type, input, expected) in [
        ("tinyint", "-128", Some(Value::Int(-128))),
        ("tinyint", "127", Some(Value::Int(127))),
        ("tinyint unsigned", "255", Some(Value::Int(255))),
        ("tinyint(3) unsigned", "255", Some(Value::Int(255))),
        ("smallint", "-32768", Some(Value::Int(-32768))),
        ("smallint unsigned", "65535", Some(Value::Int(65535))),
        ("mediumint", "-8388608", Some(Value::Int(-8_388_608))),
        ("mediumint unsigned", "16777215", Some(Value::Int(16_777_215))),
        ("int", "-2147483648", Some(Value::Int(i64::from(i32::MIN)))),
        ("int", "2147483647", Some(Value::Int(i64::from(i32::MAX)))),
        ("int unsigned", "4294967295", Some(Value::Int(4_294_967_295))),
        ("bigint", "-9223372036854775808", Some(Value::Int(i64::MIN))),
        ("bigint", "9223372036854775807", Some(Value::Int(i64::MAX))),
        (
            "bigint unsigned",
            "18446744073709551615",
            Some(Value::Text("18446744073709551615".into())),
        ),
    ] {
        let column = col(data_type, false);
        assert_eq!(
            parse_input_for_driver(input, Some(&column), "mysql"),
            Ok(expected.unwrap()),
            "{input} in {data_type}"
        );
    }

    for (data_type, input) in [
        ("tinyint", "-129"),
        ("tinyint", "128"),
        ("tinyint unsigned", "-1"),
        ("tinyint unsigned", "256"),
        ("smallint", "32768"),
        ("smallint unsigned", "65536"),
        ("mediumint", "8388608"),
        ("mediumint unsigned", "16777216"),
        ("int", "-2147483649"),
        ("int", "2147483648"),
        ("int unsigned", "4294967296"),
        ("bigint", "9223372036854775808"),
        ("bigint unsigned", "18446744073709551616"),
        ("bigint unsigned", "-1"),
    ] {
        let column = col(data_type, false);
        assert!(
            parse_input_for_driver(input, Some(&column), "mysql").is_err(),
            "{input} must be refused for {data_type}"
        );
    }

    assert_eq!(
        parse_input_for_driver("true", Some(&col("tinyint(1)", false)), "mysql"),
        Ok(Value::Bool(true)),
        "MySQL tinyint(1) boolean semantics remain intact"
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_mysql_unsigned_integer_grid_edits_refuse_coercion_and_preserve_u64() {
    use tablepro_core::{ConnectOptions, DatabaseDriver, OperationControl};
    use testcontainers::ImageExt;
    use testcontainers::runners::AsyncRunner;
    use testcontainers_modules::mysql::Mysql;

    let container = Mysql::default()
        .with_env_var("MYSQL_ROOT_PASSWORD", "tablepro_test")
        .with_cmd(["--default-authentication-plugin=mysql_native_password"])
        .start()
        .await
        .unwrap();
    let connection = drivers_mysql::MysqlDriver
        .connect(ConnectOptions {
            host: container.get_host().await.unwrap().to_string(),
            port: container.get_host_port_ipv4(3306).await.unwrap(),
            database: "test".into(),
            username: "root".into(),
            password: secrecy::SecretString::new("tablepro_test".to_string().into()),
            tls: tablepro_core::TlsConfig::disabled(),
            ..Default::default()
        })
        .await
        .unwrap();
    let control = OperationControl::with_timeout(std::time::Duration::from_secs(30));
    let mut permissive_session = connection.open_session().await.unwrap();
    for sql in [
        "SET SESSION sql_mode = ''",
        "CREATE TABLE permissive_probe (value TINYINT UNSIGNED)",
        "INSERT INTO permissive_probe VALUES (256)",
    ] {
        permissive_session
            .query_params_controlled(sql, &[], &control)
            .await
            .unwrap();
    }
    assert_eq!(
        permissive_session
            .query_params_controlled("SELECT value FROM permissive_probe", &[], &control)
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Int(255)]],
        "the independent server oracle demonstrates permissive-mode clamping"
    );
    permissive_session.close().await.unwrap();

    connection
        .execute("CREATE TABLE mysql_integer_edit (id INT PRIMARY KEY, tiny TINYINT UNSIGNED, wide BIGINT UNSIGNED)")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO mysql_integer_edit VALUES (1, 0, 0), (2, 7, 9)")
        .await
        .unwrap();
    let columns = connection.fetch_columns(None, "mysql_integer_edit").await.unwrap();
    let tiny_index = columns.iter().position(|column| column.name == "tiny").unwrap();
    let wide_index = columns.iter().position(|column| column.name == "wide").unwrap();
    assert!(parse_input_for_driver("256", Some(&columns[tiny_index]), "mysql").is_err());
    let mut strict_session = connection.open_session().await.unwrap();
    strict_session
        .query_params_controlled("SET SESSION sql_mode = 'STRICT_TRANS_TABLES'", &[], &control)
        .await
        .unwrap();
    let strict_mode = strict_session
        .query_params_controlled("SELECT @@SESSION.sql_mode", &[], &control)
        .await
        .unwrap();
    assert!(matches!(&strict_mode.rows[0][0], Value::Text(mode) if mode.contains("STRICT_TRANS_TABLES")));
    assert!(
        parse_input_for_driver("256", Some(&columns[tiny_index]), "mysql").is_err(),
        "the parser must refuse the same out-of-range edit under strict mode"
    );
    assert!(
        strict_session
            .query_params_controlled("INSERT INTO permissive_probe VALUES (256)", &[], &control)
            .await
            .is_err(),
        "the native strict-mode oracle must reject the value instead of clamping"
    );
    assert_eq!(
        strict_session
            .query_params_controlled("SELECT CAST(value AS CHAR) FROM permissive_probe", &[], &control)
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Text("255".into())]],
        "the strict-mode refusal must leave the earlier permissive row unchanged"
    );

    let tiny = parse_input_for_driver("255", Some(&columns[tiny_index]), "mysql").unwrap();
    let wide = parse_input_for_driver("18446744073709551615", Some(&columns[wide_index]), "mysql").unwrap();
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "mysql",
        None,
        "mysql_integer_edit",
        &columns,
        &[(tiny_index, tiny), (wide_index, wide)],
        &[Value::Int(1)],
    )
    .unwrap();
    strict_session
        .query_params_controlled(&update.0, &update.1, &control)
        .await
        .unwrap();

    let after = strict_session
        .query_params_controlled(
            "SELECT id, CAST(tiny AS CHAR), CAST(wide AS CHAR) \
             FROM mysql_integer_edit ORDER BY id",
            &[],
            &control,
        )
        .await
        .unwrap();
    assert_eq!(
        after.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("255".into()),
                Value::Text("18446744073709551615".into()),
            ],
            vec![Value::Int(2), Value::Text("7".into()), Value::Text("9".into())],
        ],
        "typed grid updates must preserve the exact unsigned value and other row identity"
    );
    strict_session.close().await.unwrap();
}
