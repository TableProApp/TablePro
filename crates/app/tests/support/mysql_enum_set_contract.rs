use super::parse_input_for_driver;
use tablepro_core::{ColumnInfo, Value};

fn operation_control() -> tablepro_core::OperationControl {
    tablepro_core::OperationControl::with_timeout(std::time::Duration::from_secs(30))
}

#[test]
fn value_contract_mysql_enum_and_set_parser_preserves_labels() {
    let column = |name: &str, data_type: &str| ColumnInfo {
        name: name.into(),
        data_type: data_type.into(),
        nullable: false,
        primary_key: false,
        is_auto_increment: false,
        default_value: None,
        is_generated: false,
        comment: None,
        collation: None,
        enum_type: None,
        domain_type: None,
    };
    for (data_type, input) in [
        ("enum('happy','it''s ok','back\\\\slash')", "it's ok"),
        ("set('read','write','slash\\\\path')", "write,slash\\path"),
    ] {
        assert_eq!(
            parse_input_for_driver(input, Some(&column("value", data_type)), "mysql"),
            Ok(Value::Text(input.into()))
        );
    }
    assert!(parse_input_for_driver("unknown", Some(&column("value", "enum('known')")), "mysql").is_err());
    assert!(parse_input_for_driver("read,unknown", Some(&column("value", "set('read','write')")), "mysql").is_err());
    assert_eq!(
        parse_input_for_driver("happy", Some(&column("value", "enum('happy','it\\'s ok')")), "mysql"),
        Ok(Value::Text("happy".into()))
    );
    assert_eq!(
        parse_input_for_driver("NULL", Some(&column("value", "enum('NULL','known')")), "mysql"),
        Ok(Value::Text("NULL".into()))
    );
    let mut nullable_enum = column("value", "enum('happy','')");
    nullable_enum.nullable = true;
    assert_eq!(
        parse_input_for_driver("", Some(&nullable_enum), "mysql"),
        Ok(Value::Null)
    );
    assert_eq!(
        parse_input_for_driver("''", Some(&nullable_enum), "mysql"),
        Ok(Value::Text(String::new()))
    );
    assert!(parse_input_for_driver("", Some(&column("value", "enum('happy','')")), "mysql").is_err());
    assert_eq!(
        parse_input_for_driver("''", Some(&column("value", "set('read','write')")), "mysql"),
        Ok(Value::Text(String::new()))
    );
}

#[test]
fn value_contract_mysql_enum_and_set_parser_refuses_malformed_metadata() {
    let column = |data_type: &str| ColumnInfo {
        name: "value".into(),
        data_type: data_type.into(),
        nullable: false,
        primary_key: false,
        is_auto_increment: false,
        default_value: None,
        is_generated: false,
        comment: None,
        collation: None,
        enum_type: None,
        domain_type: None,
    };

    for data_type in [
        "enumx('known')",
        "enum('known',)",
        "enum('unterminated)",
        "set('read','write') trailing",
        "set('read','write',)",
    ] {
        assert!(
            parse_input_for_driver("known", Some(&column(data_type)), "mysql").is_err(),
            "malformed MySQL type metadata must refuse edits: {data_type}"
        );
    }
}

#[test]
fn value_contract_mysql_enum_metadata_unescapes_mysql_literals() {
    let column = ColumnInfo {
        name: "value".into(),
        data_type:
            r"enum('nul\0','backspace\b','line\nfeed','carriage\rreturn','tab\t','eof\Z','percent\\%','under\\_score')"
                .into(),
        nullable: false,
        primary_key: false,
        is_auto_increment: false,
        default_value: None,
        is_generated: false,
        comment: None,
        collation: None,
        enum_type: None,
        domain_type: None,
    };

    for label in [
        "nul\0",
        "backspace\u{0008}",
        "line\nfeed",
        "carriage\rreturn",
        "tab\t",
        "eof\u{001a}",
        "percent\\%",
        "under\\_score",
    ] {
        assert_eq!(
            parse_input_for_driver(label, Some(&column), "mysql"),
            Ok(Value::Text(label.into()))
        );
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_mysql_enum_set_keyed_edits_preserve_native_values_across_sql_modes() {
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
    let connection = drivers_mysql::MysqlDriver
        .connect(ConnectOptions {
            host: container.get_host().await.unwrap().to_string(),
            port: container.get_host_port_ipv4(3306).await.unwrap(),
            database: "test".into(),
            username: "root".into(),
            password: secrecy::SecretString::new("tablepro_test".to_string().into()),
            tls: TlsConfig::disabled(),
            ..Default::default()
        })
        .await
        .unwrap();
    let mut session = connection.open_session().await.unwrap();
    session
        .query_params_controlled(
            "CREATE TABLE enum_set_grid (
                id INT PRIMARY KEY,
                mood ENUM('happy', 'it''s ok', 'back\\\\slash', 'NULL', '', '<tag>&',
                    'nul\\0', 'backspace\\b', 'line\\nfeed', 'carriage\\rreturn', 'tab\\t', 'eof\\Z', 'percent\\%', 'under\\_score'),
                perms SET('read', 'write', 'slash\\\\path', 'NULL', '<member>')
            )",
            &[],
            &operation_control(),
        )
        .await
        .unwrap();
    session
        .query_params_controlled(
            "INSERT INTO enum_set_grid VALUES
                (1, 'happy', 'read'), (2, '<tag>&', '<member>'), (3, NULL, NULL)",
            &[],
            &operation_control(),
        )
        .await
        .unwrap();
    let columns = connection.fetch_columns(None, "enum_set_grid").await.unwrap();
    let mood = columns.iter().position(|column| column.name == "mood").unwrap();
    let perms = columns.iter().position(|column| column.name == "perms").unwrap();
    let escaped_labels = [
        "nul\0",
        "backspace\u{0008}",
        "line\nfeed",
        "carriage\rreturn",
        "tab\t",
        "eof\u{001a}",
        "percent\\%",
        "under\\_score",
    ];
    let siblings = session
        .query_params_controlled(
            "SELECT id, CAST(mood + 0 AS CHAR), HEX(mood), CAST(perms + 0 AS CHAR), HEX(perms)
             FROM enum_set_grid WHERE id = 2",
            &[],
            &operation_control(),
        )
        .await
        .unwrap()
        .rows;
    let modes = [
        "",
        "NO_BACKSLASH_ESCAPES",
        "ANSI_QUOTES",
        "ANSI_QUOTES,NO_BACKSLASH_ESCAPES",
        "STRICT_TRANS_TABLES",
        "STRICT_TRANS_TABLES,NO_BACKSLASH_ESCAPES",
        "STRICT_TRANS_TABLES,ANSI_QUOTES",
        "STRICT_TRANS_TABLES,ANSI_QUOTES,NO_BACKSLASH_ESCAPES",
        "STRICT_ALL_TABLES",
        "STRICT_ALL_TABLES,NO_BACKSLASH_ESCAPES",
        "STRICT_ALL_TABLES,ANSI_QUOTES",
        "STRICT_ALL_TABLES,ANSI_QUOTES,NO_BACKSLASH_ESCAPES",
    ];
    for mode in modes {
        session
            .query_params_controlled(&format!("SET SESSION sql_mode = '{mode}'"), &[], &operation_control())
            .await
            .unwrap();
        let active = session
            .query_params_controlled("SELECT @@SESSION.sql_mode", &[], &operation_control())
            .await
            .unwrap();
        let Value::Text(active) = &active.rows[0][0] else {
            panic!("unexpected sql_mode: {:?}", active.rows[0][0]);
        };
        assert_eq!(
            active.split(',').any(|value| value == "NO_BACKSLASH_ESCAPES"),
            mode.contains("NO_BACKSLASH_ESCAPES")
        );
        assert_eq!(
            active.split(',').any(|value| value == "ANSI_QUOTES"),
            mode.contains("ANSI_QUOTES")
        );
        assert_eq!(
            active.split(',').any(|value| value == "STRICT_TRANS_TABLES"),
            mode.contains("STRICT_TRANS_TABLES")
        );
        assert_eq!(
            active.split(',').any(|value| value == "STRICT_ALL_TABLES"),
            mode.contains("STRICT_ALL_TABLES")
        );
        assert!(
            parse_input_for_driver("unknown", Some(&columns[mood]), "mysql").is_err(),
            "unknown ENUM labels must be rejected in mode {mode:?}"
        );
        assert!(
            parse_input_for_driver("read,unknown", Some(&columns[perms]), "mysql").is_err(),
            "unknown SET members must be rejected in mode {mode:?}"
        );
        for (index, label) in escaped_labels.iter().enumerate() {
            let value = parse_input_for_driver(label, Some(&columns[mood]), "mysql").unwrap_or_else(|error| {
                panic!(
                    "server metadata {:?} must expose the declared label {label:?} in mode {mode:?}: {error}",
                    columns[mood].data_type
                )
            });
            let update = tablepro_core::sql_dialect::build_keyed_update(
                "mysql",
                None,
                "enum_set_grid",
                &columns,
                &[(mood, value)],
                &[Value::Int(1)],
            )
            .unwrap();
            session
                .query_params_controlled(&update.0, &update.1, &operation_control())
                .await
                .unwrap();
            let native = session
                .query_params_controlled(
                    "SELECT CAST(mood + 0 AS CHAR), HEX(mood) FROM enum_set_grid WHERE id = 1",
                    &[],
                    &operation_control(),
                )
                .await
                .unwrap();
            let expected_hex = label.bytes().map(|byte| format!("{byte:02X}")).collect::<String>();
            assert_eq!(
                native.rows[0],
                vec![Value::Text((index + 7).to_string()), Value::Text(expected_hex)],
                "mode {mode:?}, label {label:?}"
            );
        }

        if mode.is_empty() {
            session
                .query_params_controlled("START TRANSACTION", &[], &operation_control())
                .await
                .unwrap();
            for (column, invalid) in [("mood", "unknown"), ("perms", "read,unknown")] {
                session
                    .query_params_controlled(
                        &format!("UPDATE enum_set_grid SET {column} = ? WHERE id = 1"),
                        &[Value::Text(invalid.into())],
                        &operation_control(),
                    )
                    .await
                    .unwrap();
                let coerced = session
                    .query_params_controlled(
                        &format!("SELECT CAST({column} + 0 AS CHAR), HEX({column}) FROM enum_set_grid WHERE id = 1"),
                        &[],
                        &operation_control(),
                    )
                    .await
                    .unwrap();
                if column == "mood" {
                    assert_eq!(
                        coerced.rows[0],
                        vec![Value::Text("0".into()), Value::Text(String::new())]
                    );
                } else {
                    assert_eq!(
                        coerced.rows[0],
                        vec![Value::Text("1".into()), Value::Text("72656164".into())]
                    );
                }
            }
            session
                .query_params_controlled("ROLLBACK", &[], &operation_control())
                .await
                .unwrap();
        }

        if mode.is_empty() {
            let blank_mood = parse_input_for_driver("", Some(&columns[mood]), "mysql").unwrap();
            let blank_perms = parse_input_for_driver("", Some(&columns[perms]), "mysql").unwrap();
            assert_eq!(blank_mood, Value::Null);
            assert_eq!(blank_perms, Value::Null);
            let blank_update = tablepro_core::sql_dialect::build_keyed_update(
                "mysql",
                None,
                "enum_set_grid",
                &columns,
                &[(mood, blank_mood), (perms, blank_perms)],
                &[Value::Int(1)],
            )
            .unwrap();
            session
                .query_params_controlled(&blank_update.0, &blank_update.1, &operation_control())
                .await
                .unwrap();
            let blank_state = session
                .query_params_controlled(
                    "SELECT IF(mood IS NULL, 'null', 'value'), IF(perms IS NULL, 'null', 'value')
                     FROM enum_set_grid WHERE id = 1",
                    &[],
                    &operation_control(),
                )
                .await
                .unwrap();
            assert_eq!(
                blank_state.rows[0],
                vec![Value::Text("null".into()), Value::Text("null".into())]
            );

            let empty_mood = parse_input_for_driver("''", Some(&columns[mood]), "mysql").unwrap();
            let empty_perms = parse_input_for_driver("''", Some(&columns[perms]), "mysql").unwrap();
            assert_eq!(empty_mood, Value::Text(String::new()));
            assert_eq!(empty_perms, Value::Text(String::new()));
            let empty_update = tablepro_core::sql_dialect::build_keyed_update(
                "mysql",
                None,
                "enum_set_grid",
                &columns,
                &[(mood, empty_mood), (perms, empty_perms)],
                &[Value::Int(1)],
            )
            .unwrap();
            session
                .query_params_controlled(&empty_update.0, &empty_update.1, &operation_control())
                .await
                .unwrap();
            let empty_state = session
                .query_params_controlled(
                    "SELECT IF(mood IS NULL, 'null', 'value'), CAST(mood + 0 AS CHAR), HEX(mood),
                            IF(perms IS NULL, 'null', 'value'), CAST(perms + 0 AS CHAR), HEX(perms)
                     FROM enum_set_grid WHERE id = 1",
                    &[],
                    &operation_control(),
                )
                .await
                .unwrap();
            assert_eq!(
                empty_state.rows[0],
                vec![
                    Value::Text("value".into()),
                    Value::Text("5".into()),
                    Value::Text(String::new()),
                    Value::Text("value".into()),
                    Value::Text("0".into()),
                    Value::Text(String::new()),
                ]
            );
        }

        let literal_null = parse_input_for_driver("NULL", Some(&columns[mood]), "mysql").unwrap();
        let literal_null_update = tablepro_core::sql_dialect::build_keyed_update(
            "mysql",
            None,
            "enum_set_grid",
            &columns,
            &[(mood, literal_null)],
            &[Value::Int(1)],
        )
        .unwrap();
        session
            .query_params_controlled(&literal_null_update.0, &literal_null_update.1, &operation_control())
            .await
            .unwrap();
        let literal_null_state = session
            .query_params_controlled(
                "SELECT IF(mood IS NULL, 'null', 'value'), CAST(mood + 0 AS CHAR), HEX(mood)
                 FROM enum_set_grid WHERE id = 1",
                &[],
                &operation_control(),
            )
            .await
            .unwrap();
        assert_eq!(
            literal_null_state.rows[0],
            vec![
                Value::Text("value".into()),
                Value::Text("4".into()),
                Value::Text("4E554C4C".into())
            ]
        );

        let mood_value = parse_input_for_driver("it's ok", Some(&columns[mood]), "mysql").unwrap();
        let perms_value = parse_input_for_driver("write,slash\\path", Some(&columns[perms]), "mysql").unwrap();
        assert_eq!(mood_value, Value::Text("it's ok".into()));
        assert_eq!(perms_value, Value::Text("write,slash\\path".into()));
        let update = tablepro_core::sql_dialect::build_keyed_update(
            "mysql",
            None,
            "enum_set_grid",
            &columns,
            &[(mood, mood_value), (perms, perms_value)],
            &[Value::Int(1)],
        )
        .unwrap();
        session
            .query_params_controlled(&update.0, &update.1, &operation_control())
            .await
            .unwrap();

        let rows = session
            .query_params_controlled(
                "SELECT id, CAST(mood + 0 AS CHAR), HEX(mood), CAST(perms + 0 AS CHAR), HEX(perms)
                 FROM enum_set_grid ORDER BY id",
                &[],
                &operation_control(),
            )
            .await
            .unwrap()
            .rows;
        assert_eq!(
            rows[0],
            vec![
                Value::Int(1),
                Value::Text("2".into()),
                Value::Text("69742773206F6B".into()),
                Value::Text("6".into()),
                Value::Text("77726974652C736C6173685C70617468".into()),
            ],
            "mode {mode:?}"
        );
        assert_eq!(rows[1], siblings[0], "sibling changed in mode {mode:?}");
        assert_eq!(
            rows[2],
            vec![Value::Int(3), Value::Null, Value::Null, Value::Null, Value::Null],
            "SQL NULL row changed in mode {mode:?}"
        );
    }
    session.close().await.unwrap();
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_mariadb_enum_set_grid_edit_preserves_values_across_sql_modes() {
    use tablepro_core::{ConnectOptions, DatabaseDriver, TlsConfig};
    use testcontainers::core::{IntoContainerPort, WaitFor};
    use testcontainers::runners::AsyncRunner;
    use testcontainers::{GenericImage, ImageExt};

    let container = GenericImage::new("mariadb", "11")
        .with_exposed_port(3306.tcp())
        .with_wait_for(WaitFor::message_on_stderr("port: 3306"))
        .with_env_var("MARIADB_ROOT_PASSWORD", "tablepro_test")
        .with_env_var("MARIADB_DATABASE", "test")
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
            tls: TlsConfig::disabled(),
            ..Default::default()
        })
        .await
        .unwrap();
    let mut session = connection.open_session().await.unwrap();
    session
        .query_params_controlled(
            "CREATE TABLE maria_enum_set_grid (
                id INT PRIMARY KEY,
                mood ENUM('happy', 'it''s ok', 'back\\\\slash', 'NULL', ''),
                perms SET('read', 'write', 'slash\\\\path')
            )",
            &[],
            &operation_control(),
        )
        .await
        .unwrap();
    session
        .query_params_controlled(
            "INSERT INTO maria_enum_set_grid VALUES
                (1, 'happy', 'read'), (2, 'happy', 'write'), (3, NULL, NULL)",
            &[],
            &operation_control(),
        )
        .await
        .unwrap();
    let columns = connection.fetch_columns(None, "maria_enum_set_grid").await.unwrap();
    let mood = columns.iter().position(|column| column.name == "mood").unwrap();
    let perms = columns.iter().position(|column| column.name == "perms").unwrap();
    let modes = [
        "",
        "NO_BACKSLASH_ESCAPES",
        "ANSI_QUOTES",
        "ANSI_QUOTES,NO_BACKSLASH_ESCAPES",
        "STRICT_TRANS_TABLES",
        "STRICT_TRANS_TABLES,NO_BACKSLASH_ESCAPES",
        "STRICT_TRANS_TABLES,ANSI_QUOTES",
        "STRICT_TRANS_TABLES,ANSI_QUOTES,NO_BACKSLASH_ESCAPES",
        "STRICT_ALL_TABLES",
        "STRICT_ALL_TABLES,NO_BACKSLASH_ESCAPES",
        "STRICT_ALL_TABLES,ANSI_QUOTES",
        "STRICT_ALL_TABLES,ANSI_QUOTES,NO_BACKSLASH_ESCAPES",
        "EMPTY_STRING_IS_NULL",
        "EMPTY_STRING_IS_NULL,STRICT_TRANS_TABLES,ANSI_QUOTES,NO_BACKSLASH_ESCAPES",
    ];
    for mode in modes {
        session
            .query_params_controlled(&format!("SET SESSION sql_mode = '{mode}'"), &[], &operation_control())
            .await
            .unwrap();
        let active = session
            .query_params_controlled("SELECT @@SESSION.sql_mode", &[], &operation_control())
            .await
            .unwrap();
        let Value::Text(active) = &active.rows[0][0] else {
            panic!("unexpected sql_mode: {:?}", active.rows[0][0]);
        };
        assert_eq!(
            active.split(',').any(|value| value == "NO_BACKSLASH_ESCAPES"),
            mode.contains("NO_BACKSLASH_ESCAPES")
        );
        assert_eq!(
            active.split(',').any(|value| value == "ANSI_QUOTES"),
            mode.contains("ANSI_QUOTES")
        );
        assert_eq!(
            active.split(',').any(|value| value == "STRICT_TRANS_TABLES"),
            mode.contains("STRICT_TRANS_TABLES")
        );
        assert_eq!(
            active.split(',').any(|value| value == "STRICT_ALL_TABLES"),
            mode.contains("STRICT_ALL_TABLES")
        );
        assert_eq!(
            active.split(',').any(|value| value.trim() == "EMPTY_STRING_IS_NULL"),
            mode.contains("EMPTY_STRING_IS_NULL")
        );
        assert!(parse_input_for_driver("unknown", Some(&columns[mood]), "mysql").is_err());
        assert!(parse_input_for_driver("read,unknown", Some(&columns[perms]), "mysql").is_err());
        if mode.is_empty() || mode.contains("EMPTY_STRING_IS_NULL") {
            let blank_mood = parse_input_for_driver("", Some(&columns[mood]), "mysql").unwrap();
            let blank_perms = parse_input_for_driver("", Some(&columns[perms]), "mysql").unwrap();
            assert_eq!(blank_mood, Value::Null);
            assert_eq!(blank_perms, Value::Null);
            let blank_update = tablepro_core::sql_dialect::build_keyed_update(
                "mysql",
                None,
                "maria_enum_set_grid",
                &columns,
                &[(mood, blank_mood), (perms, blank_perms)],
                &[Value::Int(1)],
            )
            .unwrap();
            session
                .query_params_controlled(&blank_update.0, &blank_update.1, &operation_control())
                .await
                .unwrap();
            let blank_state = session
                .query_params_controlled(
                    "SELECT IF(mood IS NULL, 'null', 'value'), IF(perms IS NULL, 'null', 'value')
                     FROM maria_enum_set_grid WHERE id = 1",
                    &[],
                    &operation_control(),
                )
                .await
                .unwrap();
            assert_eq!(
                blank_state.rows[0],
                vec![Value::Text("null".into()), Value::Text("null".into())]
            );

            let empty_mood = parse_input_for_driver("''", Some(&columns[mood]), "mysql").unwrap();
            let empty_perms = parse_input_for_driver("''", Some(&columns[perms]), "mysql").unwrap();
            assert_eq!(empty_mood, Value::Text(String::new()));
            assert_eq!(empty_perms, Value::Text(String::new()));
            let empty_update = tablepro_core::sql_dialect::build_keyed_update(
                "mysql",
                None,
                "maria_enum_set_grid",
                &columns,
                &[(mood, empty_mood), (perms, empty_perms)],
                &[Value::Int(1)],
            )
            .unwrap();
            session
                .query_params_controlled(&empty_update.0, &empty_update.1, &operation_control())
                .await
                .unwrap();
            let empty_state = session
                .query_params_controlled(
                    "SELECT IF(mood IS NULL, 'null', 'value'), CAST(mood + 0 AS CHAR), HEX(mood),
                            IF(perms IS NULL, 'null', 'value'), CAST(perms + 0 AS CHAR), HEX(perms)
                     FROM maria_enum_set_grid WHERE id = 1",
                    &[],
                    &operation_control(),
                )
                .await
                .unwrap();
            assert_eq!(
                empty_state.rows[0],
                vec![
                    Value::Text("value".into()),
                    Value::Text("5".into()),
                    Value::Text(String::new()),
                    Value::Text("value".into()),
                    Value::Text("0".into()),
                    Value::Text(String::new()),
                ]
            );
        }
        let literal_null = parse_input_for_driver("NULL", Some(&columns[mood]), "mysql").unwrap();
        let literal_null_update = tablepro_core::sql_dialect::build_keyed_update(
            "mysql",
            None,
            "maria_enum_set_grid",
            &columns,
            &[(mood, literal_null)],
            &[Value::Int(1)],
        )
        .unwrap();
        session
            .query_params_controlled(&literal_null_update.0, &literal_null_update.1, &operation_control())
            .await
            .unwrap();
        let literal_null_state = session
            .query_params_controlled(
                "SELECT IF(mood IS NULL, 'null', 'value'), CAST(mood + 0 AS CHAR), HEX(mood)
                 FROM maria_enum_set_grid WHERE id = 1",
                &[],
                &operation_control(),
            )
            .await
            .unwrap();
        assert_eq!(
            literal_null_state.rows[0],
            vec![
                Value::Text("value".into()),
                Value::Text("4".into()),
                Value::Text("4E554C4C".into())
            ]
        );

        let mood_value = parse_input_for_driver("it's ok", Some(&columns[mood]), "mysql").unwrap();
        let perms_value = parse_input_for_driver("read,slash\\path", Some(&columns[perms]), "mysql").unwrap();
        let update = tablepro_core::sql_dialect::build_keyed_update(
            "mysql",
            None,
            "maria_enum_set_grid",
            &columns,
            &[(mood, mood_value), (perms, perms_value)],
            &[Value::Int(1)],
        )
        .unwrap();
        session
            .query_params_controlled(&update.0, &update.1, &operation_control())
            .await
            .unwrap();
        let rows = session
            .query_params_controlled(
                "SELECT id, CAST(mood + 0 AS CHAR), HEX(mood), CAST(perms + 0 AS CHAR), HEX(perms)
                 FROM maria_enum_set_grid ORDER BY id",
                &[],
                &operation_control(),
            )
            .await
            .unwrap()
            .rows;
        assert_eq!(
            rows[0],
            vec![
                Value::Int(1),
                Value::Text("2".into()),
                Value::Text("69742773206F6B".into()),
                Value::Text("5".into()),
                Value::Text("726561642C736C6173685C70617468".into()),
            ],
            "mode {mode:?}"
        );
        assert_eq!(
            rows[1],
            vec![
                Value::Int(2),
                Value::Text("1".into()),
                Value::Text("6861707079".into()),
                Value::Text("2".into()),
                Value::Text("7772697465".into()),
            ],
            "sibling changed in mode {mode:?}"
        );
        assert_eq!(
            rows[2],
            vec![Value::Int(3), Value::Null, Value::Null, Value::Null, Value::Null],
            "SQL NULL row changed in mode {mode:?}"
        );
    }
    session.close().await.unwrap();
}
