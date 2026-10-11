async fn assert_deep_enum_expression_parameters(
    connection: &dyn tablepro_core::Connection,
    schema: &str,
    levels: usize,
) {
    for (parameter, expected) in [
        (
            Value::Text("paused".into()),
            [Some("ready"), Some("paused"), Some("ready")],
        ),
        (Value::Null, [Some("ready"), None, Some("ready")]),
    ] {
        let result = connection
            .query_params(
                &format!(
                    "SELECT id, COALESCE(status, $1)::text, pg_typeof($1)::text, \
                     pg_typeof(COALESCE(status, $1))::text FROM {schema}.rows ORDER BY id"
                ),
                std::slice::from_ref(&parameter),
            )
            .await
            .unwrap_or_else(|error| panic!("COALESCE, depth {levels}: {error:?}"));
        assert_eq!(
            result.rows,
            expected
                .into_iter()
                .enumerate()
                .map(|(index, value)| vec![
                    Value::Int(index as i64 + 1),
                    value.map_or(Value::Null, |value| Value::Text(value.into())),
                    Value::Text(format!("{schema}.state")),
                    Value::Text(format!("{schema}.state")),
                ])
                .collect::<Vec<_>>(),
            "COALESCE parameter {parameter:?}, depth {levels}"
        );
    }
    assert_deep_enum_case_parameters(connection, schema, levels).await;
    assert_deep_enum_greatest_least_parameters(connection, schema, levels).await;
    assert_deep_enum_nullif_refused(connection, schema, levels).await;
    assert_deep_enum_array_expression_refused(connection, schema, levels).await;
}

async fn assert_deep_enum_array_scalar_parameters(
    connection: &dyn tablepro_core::Connection,
    schema: &str,
    levels: usize,
) {
    if levels == 63 {
        assert_deep_enum_array_remove_supported(connection, schema).await;
        assert_deep_enum_array_prepend_supported(connection, schema).await;
    } else {
        assert_deep_enum_array_remove_refused(connection, schema, levels).await;
        assert_deep_enum_array_prepend_refused(connection, schema, levels).await;
    }
    assert_deep_enum_array_position_supported(connection, schema, levels).await;
}

async fn assert_deep_enum_array_remove_supported(
    connection: &dyn tablepro_core::Connection,
    schema: &str,
) {
    for parameter in [Value::Text("paused".into()), Value::Null] {
        let result = connection
            .query_params(
                &format!(
                    "SELECT id, array_remove(ARRAY[status], $1)::text, \
                     pg_typeof($1)::text, pg_typeof(array_remove(ARRAY[status], $1))::text \
                     FROM {schema}.rows WHERE id <= 2 ORDER BY id"
                ),
                std::slice::from_ref(&parameter),
            )
            .await
            .unwrap_or_else(|error| panic!("array_remove at 63 domains: {error:?}"));
        assert_eq!(
            result.rows,
            vec![
                vec![
                    Value::Int(1),
                    Value::Text("{ready}".into()),
                    Value::Text(format!("{schema}.state")),
                    Value::Text(format!("{schema}.state[]")),
                ],
                vec![
                    Value::Int(2),
                    Value::Text(if parameter == Value::Null { "{}" } else { "{NULL}" }.into()),
                    Value::Text(format!("{schema}.state")),
                    Value::Text(format!("{schema}.state[]")),
                ],
            ],
            "array_remove parameter {parameter:?} at 63 domains"
        );
    }
}

async fn assert_deep_enum_array_remove_refused(
    connection: &dyn tablepro_core::Connection,
    schema: &str,
    levels: usize,
) {
    for parameter in [Value::Text("paused".into()), Value::Null] {
        let error = connection
            .query_params(
                &format!("SELECT array_remove(ARRAY[status], $1) FROM {schema}.rows WHERE id = 1"),
                std::slice::from_ref(&parameter),
            )
            .await
            .expect_err("deep enum array scalar parameters must be refused");
        assert!(
            matches!(&error, tablepro_core::DriverError::Unsupported(message)
                if message.contains("resolvable depth")),
            "array_remove parameter {parameter:?}, depth {levels}: {error:?}"
        );
    }
}

async fn assert_deep_enum_array_prepend_supported(
    connection: &dyn tablepro_core::Connection,
    schema: &str,
) {
    for (parameter, values) in [
        (Value::Text("paused".into()), ["{paused,ready}", "{paused,NULL}"]),
        (Value::Null, ["{NULL,ready}", "{NULL,NULL}"]),
    ] {
        let result = connection
            .query_params(
                &format!(
                    "SELECT id, array_prepend($1, ARRAY[status])::text, \
                     pg_typeof($1)::text, pg_typeof(array_prepend($1, ARRAY[status]))::text \
                     FROM {schema}.rows WHERE id <= 2 ORDER BY id"
                ),
                std::slice::from_ref(&parameter),
            )
            .await
            .unwrap_or_else(|error| panic!("array_prepend at 63 domains: {error:?}"));
        assert_eq!(
            result.rows,
            values
                .into_iter()
                .enumerate()
                .map(|(index, value)| vec![
                    Value::Int(index as i64 + 1),
                    Value::Text(value.into()),
                    Value::Text(format!("{schema}.state")),
                    Value::Text(format!("{schema}.state[]")),
                ])
                .collect::<Vec<_>>(),
            "array_prepend parameter {parameter:?} at 63 domains"
        );
    }
}

async fn assert_deep_enum_array_prepend_refused(
    connection: &dyn tablepro_core::Connection,
    schema: &str,
    levels: usize,
) {
    for parameter in [Value::Text("paused".into()), Value::Null] {
        let error = connection
            .query_params(
                &format!("SELECT array_prepend($1, ARRAY[status]) FROM {schema}.rows WHERE id = 1"),
                std::slice::from_ref(&parameter),
            )
            .await
            .expect_err("deep enum array_prepend parameter must be refused");
        assert!(
            matches!(&error, tablepro_core::DriverError::Unsupported(message)
                if message.contains("resolvable depth")),
            "array_prepend parameter {parameter:?}, depth {levels}: {error:?}"
        );
    }
}

async fn assert_deep_enum_array_position_supported(
    connection: &dyn tablepro_core::Connection,
    schema: &str,
    levels: usize,
) {
    for (parameter, positions) in [
        (Value::Text("paused".into()), [None, None]),
        (Value::Null, [Some(2), Some(1)]),
    ] {
        let result = connection
            .query_params(
                &format!(
                    "SELECT id, array_position(ARRAY[status, NULL], $1), \
                     pg_typeof($1)::text, pg_typeof(array_position(ARRAY[status, NULL], $1))::text \
                     FROM {schema}.rows WHERE id <= 2 ORDER BY id"
                ),
                std::slice::from_ref(&parameter),
            )
            .await
            .unwrap_or_else(|error| panic!("array_position at {levels} domains: {error:?}"));
        assert_eq!(
            result.rows,
            positions
                .into_iter()
                .enumerate()
                .map(|(index, position)| vec![
                    Value::Int(index as i64 + 1),
                    position.map_or(Value::Null, |value| Value::Int(value.into())),
                    Value::Text(format!("{schema}.state")),
                    Value::Text("integer".into()),
                ])
                .collect::<Vec<_>>(),
            "array_position parameter {parameter:?}, depth {levels}"
        );
    }
    assert_deep_enum_array_positions_supported(connection, schema, levels).await;
}

async fn assert_deep_enum_array_positions_supported(
    connection: &dyn tablepro_core::Connection,
    schema: &str,
    levels: usize,
) {
    for (parameter, positions) in [
        (Value::Text("paused".into()), ["[]", "[]"]),
        (Value::Null, ["[2]", "[1,2]"]),
    ] {
        let result = connection
            .query_params(
                &format!(
                    "SELECT id, array_to_json(array_positions(ARRAY[status, NULL], $1))::text, \
                     pg_typeof($1)::text, \
                     pg_typeof(array_positions(ARRAY[status, NULL], $1))::text \
                     FROM {schema}.rows WHERE id <= 2 ORDER BY id"
                ),
                std::slice::from_ref(&parameter),
            )
            .await
            .unwrap_or_else(|error| panic!("array_positions at {levels} domains: {error:?}"));
        assert_eq!(
            result.rows,
            positions
                .into_iter()
                .enumerate()
                .map(|(index, positions)| vec![
                    Value::Int(index as i64 + 1),
                    Value::Text(positions.into()),
                    Value::Text(format!("{schema}.state")),
                    Value::Text("integer[]".into()),
                ])
                .collect::<Vec<_>>(),
            "array_positions parameter {parameter:?}, depth {levels}"
        );
    }
}

async fn assert_deep_enum_case_parameters(
    connection: &dyn tablepro_core::Connection,
    schema: &str,
    levels: usize,
) {
    for (parameter, cases) in [
        (
            Value::Text("paused".into()),
            [
                ("CASE WHEN id = 1 THEN $1 ELSE status END", [Some("paused"), None, Some("ready")]),
                ("CASE WHEN id = 1 THEN status ELSE $1 END", [Some("ready"), Some("paused"), Some("paused")]),
            ],
        ),
        (
            Value::Null,
            [
                ("CASE WHEN id = 1 THEN $1 ELSE status END", [None, None, Some("ready")]),
                ("CASE WHEN id = 1 THEN status ELSE $1 END", [Some("ready"), None, None]),
            ],
        ),
    ] {
        for (expression, expected) in cases {
            let result = connection
                .query_params(
                    &format!(
                        "SELECT id, ({expression})::text, pg_typeof($1)::text, \
                         pg_typeof({expression})::text FROM {schema}.rows ORDER BY id"
                    ),
                    std::slice::from_ref(&parameter),
                )
                .await
                .unwrap_or_else(|error| panic!("{expression}, depth {levels}: {error:?}"));
            assert_eq!(
                result.rows,
                expected
                    .into_iter()
                    .enumerate()
                    .map(|(index, value)| vec![
                        Value::Int(index as i64 + 1),
                        value.map_or(Value::Null, |value| Value::Text(value.into())),
                        Value::Text(format!("{schema}.state")),
                        Value::Text(format!("{schema}.state")),
                    ])
                    .collect::<Vec<_>>(),
                "{expression}, parameter {parameter:?}, depth {levels}"
            );
        }
    }
}

async fn assert_deep_enum_array_expression_refused(
    connection: &dyn tablepro_core::Connection,
    schema: &str,
    levels: usize,
) {
    for parameter in [Value::Text("paused".into()), Value::Null] {
        let error = connection
            .query_params(
                &format!(
                    "SELECT array_append(ARRAY[status], $1) \
                     FROM {schema}.rows WHERE id = 1"
                ),
                std::slice::from_ref(&parameter),
            )
            .await
            .expect_err("deep enum array parameter must be refused");
        assert!(
            matches!(&error, tablepro_core::DriverError::Unsupported(message)
                if message.contains("resolvable depth")),
            "array_append parameter {parameter:?}, depth {levels}: {error:?}"
        );
    }
}

async fn assert_deep_enum_greatest_least_parameters(
    connection: &dyn tablepro_core::Connection,
    schema: &str,
    levels: usize,
) {
    for (parameter, expressions) in [
        (
            Value::Text("paused".into()),
            [
                ("GREATEST(status, $1)", [Some("paused"), Some("paused"), Some("paused")]),
                ("GREATEST($1, status)", [Some("paused"), Some("paused"), Some("paused")]),
                ("LEAST(status, $1)", [Some("ready"), Some("paused"), Some("ready")]),
                ("LEAST($1, status)", [Some("ready"), Some("paused"), Some("ready")]),
            ],
        ),
        (
            Value::Null,
            [
                ("GREATEST(status, $1)", [Some("ready"), None, Some("ready")]),
                ("GREATEST($1, status)", [Some("ready"), None, Some("ready")]),
                ("LEAST(status, $1)", [Some("ready"), None, Some("ready")]),
                ("LEAST($1, status)", [Some("ready"), None, Some("ready")]),
            ],
        ),
    ] {
        for (expression, expected) in expressions {
            let result = connection
                .query_params(
                    &format!(
                        "SELECT id, {expression}::text, pg_typeof($1)::text, \
                         pg_typeof({expression})::text FROM {schema}.rows ORDER BY id"
                    ),
                    std::slice::from_ref(&parameter),
                )
                .await
                .unwrap_or_else(|error| panic!("{expression}, depth {levels}: {error:?}"));
            assert_eq!(
                result.rows,
                expected
                    .into_iter()
                    .enumerate()
                    .map(|(index, value)| vec![
                        Value::Int(index as i64 + 1),
                        value.map_or(Value::Null, |value| Value::Text(value.into())),
                        Value::Text(format!("{schema}.state")),
                        Value::Text(format!("{schema}.state")),
                    ])
                    .collect::<Vec<_>>(),
                "{expression}, parameter {parameter:?}, depth {levels}"
            );
        }
    }
}

async fn assert_deep_enum_nullif_refused(
    connection: &dyn tablepro_core::Connection,
    schema: &str,
    levels: usize,
) {
    for parameter in [Value::Text("paused".into()), Value::Null] {
        let error = connection
            .query_params(
                &format!("SELECT NULLIF(status, $1) FROM {schema}.rows WHERE id = 1"),
                std::slice::from_ref(&parameter),
            )
            .await
            .expect_err("raw domain NULLIF parameter must retain PostgreSQL refusal");
        assert!(
            matches!(&error, tablepro_core::DriverError::Query { sqlstate: Some(code), .. }
                if code == "42883"),
            "NULLIF parameter {parameter:?}, depth {levels}: {error:?}"
        );
    }
}
