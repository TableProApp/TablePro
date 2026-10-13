use super::*;

#[tokio::test]
async fn open_session_is_refused() {
    let client = Client::open("redis://127.0.0.1:6379/0").unwrap();
    let manager =
        ConnectionManager::new_lazy_with_config(client.clone(), redis::aio::ConnectionManagerConfig::default())
            .unwrap();
    let conn = RedisConnection {
        conn: Mutex::new(manager),
        db_count: 16,
        browse_client: client,
    };

    match conn.open_session().await {
        Err(DriverError::Unsupported(_)) => {}
        Ok(_) => panic!("redis must refuse open_session"),
        Err(other) => panic!("expected Unsupported, got {other:?}"),
    }
}

#[test]
fn a_tunneled_connection_verifies_tls_against_the_service_hostname() {
    let opts = ConnectOptions {
        host: "127.0.0.1".into(),
        port: 6380,
        service_endpoint: Some(("cache.internal.example".into(), 6379)),
        tls: tablepro_core::TlsConfig {
            mode: tablepro_core::TlsMode::VerifyFull,
            ..Default::default()
        },
        ..Default::default()
    };

    let certificates = tls_certificates_for(&opts, true).expect("build TLS certificates");

    assert_eq!(certificates.verify_host.as_deref(), Some("cache.internal.example"));
}

#[test]
fn an_encrypt_only_connection_does_not_verify_a_hostname() {
    let opts = ConnectOptions {
        host: "127.0.0.1".into(),
        port: 6380,
        service_endpoint: Some(("cache.internal.example".into(), 6379)),
        tls: tablepro_core::TlsConfig {
            mode: tablepro_core::TlsMode::Require,
            ..Default::default()
        },
        ..Default::default()
    };

    let certificates = tls_certificates_for(&opts, false).expect("build TLS certificates");

    assert_eq!(certificates.verify_host, None);
}

#[test]
fn value_contract_empty_quoted_arguments_are_not_dropped() {
    assert_eq!(split_redis_cli(r#"SET key """#), vec!["SET", "key", ""]);
    assert_eq!(
        split_redis_cli(r#"MSET "" "" key "" "#),
        vec!["MSET", "", "", "key", ""]
    );
}

#[test]
fn structure_metadata_is_not_declared_without_a_fetch() {
    let d = RedisDriver;
    let source = include_str!("lib.rs");
    assert!(!d.supports_index_metadata());
    assert!(!d.supports_foreign_key_metadata());
    assert!(!source.contains(&["async fn ", "fetch_indexes("].concat()));
    assert!(!source.contains(&["async fn ", "fetch_foreign_keys("].concat()));
}

#[test]
fn an_empty_database_defaults_to_zero() {
    assert_eq!(parse_db_index("").unwrap(), 0);
    assert_eq!(parse_db_index("   ").unwrap(), 0);
}

#[test]
fn a_valid_index_is_used_even_with_surrounding_whitespace() {
    assert_eq!(parse_db_index("12").unwrap(), 12);
    assert_eq!(parse_db_index(" 12 ").unwrap(), 12);
}

/// A typo or stray text must refuse the connection, not silently land
/// on db 0 -- usually the production database.
#[test]
fn a_malformed_database_index_is_refused_instead_of_defaulting_to_zero() {
    for bad in ["db3", "16abc", "-1", "1.5"] {
        assert!(parse_db_index(bad).is_err(), "{bad}");
    }
}

#[test]
fn driver_metadata() {
    let d = RedisDriver;
    assert_eq!(d.id(), "redis");
    assert_eq!(d.display_name(), "Redis");
    assert_eq!(d.default_port(), 6379);
    assert_eq!(d.default_database(), "0");
    assert_eq!(d.default_username(), "default");
}

#[test]
fn split_redis_cli_handles_quotes() {
    assert_eq!(split_redis_cli("GET foo"), vec!["GET", "foo"]);
    assert_eq!(
        split_redis_cli(r#"SET key "hello world""#),
        vec!["SET", "key", "hello world"]
    );
    assert_eq!(split_redis_cli(r#"SET k "a\"b""#), vec!["SET", "k", "a\"b"]);
}

#[test]
fn split_redis_cli_keeps_a_backslash_literal_outside_quotes() {
    assert_eq!(split_redis_cli(r"SET k a\b"), vec!["SET", "k", r"a\b"]);
}

#[test]
fn parse_db_name_accepts_db_n() {
    assert_eq!(parse_db_name("db0").unwrap(), 0);
    assert_eq!(parse_db_name("db15").unwrap(), 15);
    assert!(parse_db_name("users").is_err());
}

#[test]
fn urlencoding_lite_keeps_unreserved_characters_and_encodes_everything_else() {
    assert_eq!(urlencoding_lite("Az09-_.~"), "Az09-_.~");
    assert_eq!(urlencoding_lite("a b"), "a%20b");
    assert_eq!(urlencoding_lite("p@ss/w:rd"), "p%40ss%2Fw%3Ard");
}

#[test]
fn map_redis_error_classifies_connection_refusal_during_operation_as_disconnected() {
    let err = RedisError::from(std::io::Error::from(std::io::ErrorKind::ConnectionRefused));
    assert!(matches!(map_redis_error(err), DriverError::Disconnected));
}

#[test]
fn a_non_timeout_io_error_during_an_operation_is_disconnected() {
    let err = RedisError::from(std::io::Error::new(
        std::io::ErrorKind::PermissionDenied,
        "socket transport failed",
    ));
    assert!(matches!(map_redis_error(err), DriverError::Disconnected));
}

#[test]
fn a_plain_connection_refused_stays_connection_refused_when_verifying() {
    let err = RedisError::from(std::io::Error::from(std::io::ErrorKind::ConnectionRefused));
    assert!(matches!(
        map_redis_connect_error(err, true),
        DriverError::ConnectionRefused
    ));
}

#[test]
fn setup_time_socket_reset_and_broken_pipe_are_connection_refused() {
    for kind in [std::io::ErrorKind::ConnectionReset, std::io::ErrorKind::BrokenPipe] {
        let err = RedisError::from(std::io::Error::from(kind));
        assert!(
            matches!(map_redis_connect_error(err, false), DriverError::ConnectionRefused),
            "setup-time {kind:?} must stay distinct from established disconnection"
        );
    }
}

#[test]
fn a_certificate_name_mismatch_io_error_maps_to_tls() {
    let err = RedisError::from(std::io::Error::other(
        "invalid peer certificate: certificate not valid for name \"127.0.0.1\"",
    ));
    assert!(matches!(map_redis_error(err), DriverError::Tls(detail) if detail.contains("certificate")));
}

#[test]
fn a_connection_refused_carrying_a_name_mismatch_maps_to_tls() {
    let err = RedisError::from(std::io::Error::new(
        std::io::ErrorKind::ConnectionRefused,
        "invalid peer certificate: certificate not valid for name \"127.0.0.1\"",
    ));
    let mapped = map_redis_connect_error(err, true);
    assert!(matches!(mapped, DriverError::Tls(detail) if detail.contains("certificate")));
}

#[test]
fn verifying_connect_does_not_report_a_hostname_mismatch_as_a_refusal() {
    let err = RedisError::from(std::io::Error::new(
        std::io::ErrorKind::ConnectionRefused,
        "invalid peer certificate: NotValidForName",
    ));
    let mapped = map_redis_connect_error(err, true);
    assert!(matches!(
        mapped,
        DriverError::Tls(detail)
            if detail.to_ascii_lowercase().contains("certificate")
                || detail.to_ascii_lowercase().contains("notvalidforname")
    ));
}

#[test]
fn rustls_invalid_data_name_mismatch_maps_to_tls() {
    let err = RedisError::from(std::io::Error::new(
        std::io::ErrorKind::InvalidData,
        "invalid peer certificate: NotValidForName",
    ));
    let mapped = map_redis_connect_error(err, true);
    assert!(matches!(
        mapped,
        DriverError::Tls(detail) if detail.to_ascii_lowercase().contains("notvalidforname")
    ));
}

#[test]
fn verifying_connect_maps_a_dropped_handshake_without_tls_text() {
    let err = RedisError::from(std::io::Error::from(std::io::ErrorKind::ConnectionReset));
    assert!(matches!(map_redis_error(err.clone()), DriverError::Disconnected));
    let mapped = map_redis_connect_error(err, true);
    assert!(
        matches!(mapped, DriverError::Tls(detail) if detail.contains("certificate") && detail.contains("hostname"))
    );
}

#[test]
fn looks_like_tls_failure_reads_rustls_identity_text() {
    assert!(looks_like_tls_failure(
        "invalid peer certificate: certificate not valid for name \"127.0.0.1\""
    ));
    assert!(looks_like_tls_failure("invalid peer certificate: NotValidForName"));
    assert!(!looks_like_tls_failure("Connection refused"));
}

#[test]
fn map_redis_error_recognizes_noauth_and_wrongpass_as_auth_failures() {
    let noauth = RedisError::from((
        redis::ErrorKind::AuthenticationFailed,
        "authentication required",
        "NOAUTH Authentication required.".to_string(),
    ));
    assert!(matches!(map_redis_error(noauth), DriverError::AuthFailed));

    let wrongpass = RedisError::from((
        redis::ErrorKind::AuthenticationFailed,
        "authentication failed",
        "WRONGPASS invalid username-password pair".to_string(),
    ));
    assert!(matches!(map_redis_error(wrongpass), DriverError::AuthFailed));
}

#[test]
fn map_redis_error_falls_back_to_a_query_error() {
    let err = RedisError::from((redis::ErrorKind::UnexpectedReturnType, "unexpected type"));
    assert!(matches!(map_redis_error(err), DriverError::Query { .. }));
}

#[test]
fn redis_value_to_result_maps_nil_okay_and_scalars() {
    assert_eq!(redis_value_to_result(RedisValue::Nil).rows, vec![vec![Value::Null]]);
    assert_eq!(
        redis_value_to_result(RedisValue::Okay).rows,
        vec![vec![Value::Text("OK".into())]]
    );
    assert_eq!(
        redis_value_to_result(RedisValue::Int(42)).rows,
        vec![vec![Value::Int(42)]]
    );
    assert_eq!(
        redis_value_to_result(RedisValue::Boolean(true)).rows,
        vec![vec![Value::Bool(true)]]
    );
}

#[test]
fn redis_value_to_result_decodes_valid_utf8_binary_as_text() {
    let result = redis_value_to_result(RedisValue::BulkString(b"hello".to_vec()));
    assert_eq!(result.rows, vec![vec![Value::Text("hello".into())]]);
}

#[test]
fn redis_value_to_result_preserves_invalid_utf8_binary() {
    let result = redis_value_to_result(RedisValue::BulkString(vec![0xFF, 0xFE]));
    assert_eq!(result.rows, vec![vec![Value::Bytes(vec![0xFF, 0xFE])]]);
}

#[test]
fn redis_value_to_result_maps_an_array_to_one_row_per_item() {
    let result = redis_value_to_result(RedisValue::Array(vec![
        RedisValue::Int(1),
        RedisValue::SimpleString("two".into()),
    ]));
    assert_eq!(result.rows, vec![vec![Value::Int(1)], vec![Value::Text("two".into())]]);
    assert!(!result.truncated);
}

#[test]
fn redis_value_to_result_truncates_an_array_at_a_shared_budget() {
    let items = (0..MAX_QUERY_ROWS + 1).map(|i| RedisValue::Int(i as i64)).collect();
    let result = redis_value_to_result(RedisValue::Array(items));
    assert!(!result.rows.is_empty());
    assert!(result.rows.len() < MAX_QUERY_ROWS);
    assert!(result.truncated);
}

#[test]
fn redis_value_to_result_maps_a_map_to_key_value_rows() {
    let result = redis_value_to_result(RedisValue::Map(vec![(
        RedisValue::SimpleString("field".into()),
        RedisValue::Int(7),
    )]));
    assert_eq!(result.rows, vec![vec![Value::Text("field".into()), Value::Int(7)]]);
}

#[test]
fn redis_value_to_result_marks_a_truncated_map() {
    let pairs = (0..=MAX_QUERY_ROWS)
        .map(|index| {
            (
                RedisValue::SimpleString(index.to_string()),
                RedisValue::Int(index as i64),
            )
        })
        .collect();
    let result = redis_value_to_result(RedisValue::Map(pairs));
    assert!(!result.rows.is_empty());
    assert!(result.rows.len() < MAX_QUERY_ROWS);
    assert!(result.truncated, "a cut-off Redis map must never look complete");
}

#[test]
fn redis_scalar_maps_nil_and_primitives() {
    assert_eq!(redis_scalar(RedisValue::Nil), Value::Null);
    assert_eq!(redis_scalar(RedisValue::Int(9)), Value::Int(9));
    assert_eq!(redis_scalar(RedisValue::Boolean(false)), Value::Bool(false));
    assert_eq!(redis_scalar(RedisValue::Okay), Value::Text("OK".into()));
}

#[test]
fn redis_scalar_preserves_binary_that_is_not_utf8() {
    assert_eq!(
        redis_scalar(RedisValue::BulkString(b"abc".to_vec())),
        Value::Text("abc".into())
    );
    assert_eq!(
        redis_scalar(RedisValue::BulkString(vec![0xFF])),
        Value::Bytes(vec![0xFF])
    );
}

#[test]
fn redis_nested_replies_keep_structure_and_binary_bytes() {
    let result = redis_value_to_result(RedisValue::Array(vec![
        RedisValue::Array(vec![RedisValue::BulkString(vec![0xFF, 0x00])]),
        RedisValue::Map(vec![(RedisValue::SimpleString("score".into()), RedisValue::Int(9))]),
        RedisValue::Set(vec![RedisValue::SimpleString("member".into())]),
        RedisValue::Array(vec![RedisValue::BigNumber("18446744073709551616".parse().unwrap())]),
    ]));

    assert_eq!(
        result.rows,
        vec![
            vec![Value::Json(serde_json::json!([{"$redisBytes": "ff00"}]))],
            vec![Value::Json(serde_json::json!({"$redisMap": [["score", 9]]}))],
            vec![Value::Json(serde_json::json!({"$redisSet": ["member"]}))],
            vec![Value::Json(
                serde_json::json!([{"$redisBigNumber": "18446744073709551616"}])
            )],
        ]
    );
    assert_eq!(
        redis_scalar(RedisValue::BigNumber("18446744073709551616".parse().unwrap())),
        Value::Text("18446744073709551616".into())
    );
}

#[test]
fn scalar_replies_keep_their_native_type_and_column_type() {
    let cases = [
        (RedisValue::Int(7), "integer", Value::Int(7)),
        (RedisValue::Double(1.5), "double", Value::Float(1.5)),
        (RedisValue::Boolean(true), "boolean", Value::Bool(true)),
    ];
    for (reply, data_type, expected) in cases {
        let result = redis_value_to_result(reply);
        assert_eq!(result.columns[0].data_type, data_type);
        assert_eq!(result.rows, vec![vec![expected]]);
    }
}

#[test]
fn redis_resp3_attribute_and_push_keep_their_protocol_markers() {
    let attribute = redis_scalar(RedisValue::Attribute {
        data: Box::new(RedisValue::SimpleString("payload".into())),
        attributes: vec![(RedisValue::SimpleString("ttl".into()), RedisValue::Int(3))],
    });
    assert_eq!(
        attribute,
        Value::Json(serde_json::json!({
            "$redisAttribute": {
                "data": "payload",
                "attributes": [["ttl", 3]]
            }
        }))
    );

    let push = redis_scalar(RedisValue::Push {
        kind: redis::PushKind::Message,
        data: vec![
            RedisValue::SimpleString("updates".into()),
            RedisValue::BulkString(vec![0xFF]),
        ],
    });
    assert_eq!(
        push,
        Value::Json(serde_json::json!({
            "$redisPush": {
                "kind": "Message",
                "data": ["updates", {"$redisBytes": "ff"}]
            }
        }))
    );
}

#[test]
fn redis_stream_commands_are_refused() {
    for command in [
        vec!["subscribe", "updates"],
        vec!["PSubscribe", "updates.*"],
        vec!["SSUBSCRIBE", "updates"],
        vec!["UNSUBSCRIBE", "updates"],
        vec!["punsubscribe", "updates.*"],
        vec!["sunsubscribe", "updates"],
        vec!["monitor"],
        vec!["CLIENT", "TRACKING", "ON"],
        vec!["client", "tracking", "on", "bcast"],
    ] {
        let args = command.into_iter().map(str::to_owned).collect::<Vec<_>>();
        assert!(is_redis_stream_command(&args), "{args:?}");
    }
    for command in [
        vec!["PING"],
        vec!["PUBLISH", "updates", "value"],
        vec!["PUBSUB", "CHANNELS"],
        vec!["GET", "key"],
        vec!["CLIENT", "TRACKING", "OFF"],
        vec!["CLIENT", "LIST"],
        vec![],
    ] {
        let args = command.into_iter().map(str::to_owned).collect::<Vec<_>>();
        assert!(!is_redis_stream_command(&args), "{args:?}");
    }
}
