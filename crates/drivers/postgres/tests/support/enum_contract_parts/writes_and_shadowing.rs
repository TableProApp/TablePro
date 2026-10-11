#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_custom_enum_sql_file_export_restores_labels_and_native_type() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute(
            "CREATE TYPE value_contract_sql_file_enum AS ENUM \
             ('NULL', '', '東京', 'x''; DROP TABLE value_contract_sql_file_restore; --')",
        )
        .await
        .unwrap();
    connection
        .execute("CREATE TABLE value_contract_sql_file_source (id INT PRIMARY KEY, label value_contract_sql_file_enum)")
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO value_contract_sql_file_source VALUES \
             (1, 'NULL'), (2, ''), (3, '東京'), \
             (4, 'x''; DROP TABLE value_contract_sql_file_restore; --'), (5, NULL)",
        )
        .await
        .unwrap();

    let result = connection
        .query("SELECT id, label FROM value_contract_sql_file_source ORDER BY id")
        .await
        .unwrap();
    assert_eq!(
        result.rows,
        vec![
            vec![Value::Int(1), Value::Text("NULL".into())],
            vec![Value::Int(2), Value::Text(String::new())],
            vec![Value::Int(3), Value::Text("東京".into())],
            vec![
                Value::Int(4),
                Value::Text("x'; DROP TABLE value_contract_sql_file_restore; --".into()),
            ],
            vec![Value::Int(5), Value::Null],
        ]
    );

    let directory = tempfile::tempdir().unwrap();
    let sql_path = directory.path().join("enum.sql");
    let csv_options = tablepro_core::export::CsvOptions::default();
    tablepro_core::export::write_result_file(
        &sql_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Sql,
            csv: &csv_options,
            sql: Some(tablepro_core::export::SqlTarget {
                driver_id: "postgres",
                schema: None,
                table: "value_contract_sql_file_restore",
            }),
        },
        || false,
        |_| {},
    )
    .unwrap();
    let sql = std::fs::read_to_string(&sql_path).unwrap();
    assert_eq!(sql.lines().count(), result.rows.len());
    assert!(sql.contains("x''; DROP TABLE value_contract_sql_file_restore; --"));

    connection
        .execute(
            "CREATE TABLE value_contract_sql_file_restore (id INT PRIMARY KEY, label value_contract_sql_file_enum)",
        )
        .await
        .unwrap();
    for statement in sql.lines() {
        connection.execute(statement).await.unwrap();
    }
    let restored = connection
        .query(
            "SELECT id, label, pg_typeof(label)::text AS native_type \
             FROM value_contract_sql_file_restore ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(
        restored.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("NULL".into()),
                Value::Text("value_contract_sql_file_enum".into()),
            ],
            vec![
                Value::Int(2),
                Value::Text(String::new()),
                Value::Text("value_contract_sql_file_enum".into()),
            ],
            vec![
                Value::Int(3),
                Value::Text("東京".into()),
                Value::Text("value_contract_sql_file_enum".into()),
            ],
            vec![
                Value::Int(4),
                Value::Text("x'; DROP TABLE value_contract_sql_file_restore; --".into()),
                Value::Text("value_contract_sql_file_enum".into()),
            ],
            vec![
                Value::Int(5),
                Value::Null,
                Value::Text("value_contract_sql_file_enum".into()),
            ],
        ]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_custom_enum_sql_file_replay_preserves_backslash_across_string_modes() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    let label = r"back\nslash'quote";
    let literal = tablepro_core::sql_literal::render_sql_literal("postgres", &Value::Text(label.into())).unwrap();
    connection
        .execute(&format!(
            "CREATE TYPE value_contract_enum_string_mode AS ENUM ({literal})"
        ))
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE value_contract_enum_string_source \
             (id INT PRIMARY KEY, label value_contract_enum_string_mode)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE value_contract_enum_string_restore \
             (id INT PRIMARY KEY, label value_contract_enum_string_mode)",
        )
        .await
        .unwrap();
    connection
        .execute_params(
            "INSERT INTO value_contract_enum_string_source VALUES (1, $1::value_contract_enum_string_mode)",
            &[Value::Text(label.into())],
        )
        .await
        .unwrap();

    let result = connection
        .query("SELECT id, label FROM value_contract_enum_string_source ORDER BY id")
        .await
        .unwrap();
    let directory = tempfile::tempdir().unwrap();
    let sql_path = directory.path().join("enum-string-mode.sql");
    tablepro_core::export::write_result_file(
        &sql_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Sql,
            csv: &tablepro_core::export::CsvOptions::default(),
            sql: Some(tablepro_core::export::SqlTarget {
                driver_id: "postgres",
                schema: None,
                table: "value_contract_enum_string_restore",
            }),
        },
        || false,
        |_| {},
    )
    .unwrap();
    let sql = std::fs::read_to_string(&sql_path).unwrap();
    assert!(
        sql.contains(r#"E'back\\nslash''quote'"#),
        "backslashes must use a mode-independent SQL literal: {sql}"
    );

    for (standard_conforming_strings, backslash_quote) in [
        ("on", "safe_encoding"),
        ("on", "off"),
        ("off", "off"),
        ("off", "on"),
    ] {
        let mut transaction = connection.begin().await.unwrap();
        transaction
            .execute(&format!(
                "SET LOCAL standard_conforming_strings = {standard_conforming_strings}"
            ))
            .await
            .unwrap();
        transaction
            .execute(&format!("SET LOCAL backslash_quote = {backslash_quote}"))
            .await
            .unwrap();
        assert_eq!(
            transaction
                .query("SELECT current_setting('standard_conforming_strings'), current_setting('backslash_quote')")
                .await
                .unwrap()
                .rows,
            vec![vec![
                Value::Text(standard_conforming_strings.into()),
                Value::Text(backslash_quote.into()),
            ]]
        );
        for statement in sql.lines() {
            transaction.execute(statement).await.unwrap();
        }
        let restored = transaction
            .query(
                "SELECT id, label::text, pg_typeof(label)::text \
                 FROM value_contract_enum_string_restore ORDER BY id",
            )
            .await
            .unwrap();
        assert_eq!(
            restored.rows,
            vec![vec![
                Value::Int(1),
                Value::Text(label.into()),
                Value::Text("value_contract_enum_string_mode".into()),
            ]],
            "standard_conforming_strings={standard_conforming_strings}, backslash_quote={backslash_quote}"
        );
        transaction.rollback().await.unwrap();
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_custom_enum_parameters_infer_native_type_for_query_and_write() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE SCHEMA value_contract_enum_bind")
        .await
        .unwrap();
    connection
        .execute("CREATE TYPE value_contract_enum_bind.state AS ENUM ('NULL', '東京', 'ready')")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE value_contract_enum_bind.rows (id INT PRIMARY KEY, status value_contract_enum_bind.state)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO value_contract_enum_bind.rows VALUES \
             (1, 'NULL'), (2, NULL), (3, '東京')",
        )
        .await
        .unwrap();

    let literal_null = connection
        .query_params(
            "SELECT id, status::text, pg_typeof(status)::text FROM value_contract_enum_bind.rows \
             WHERE status = $1 ORDER BY id",
            &[Value::Text("NULL".into())],
        )
        .await
        .unwrap();
    assert_eq!(
        literal_null.rows,
        vec![vec![
            Value::Int(1),
            Value::Text("NULL".into()),
            Value::Text("value_contract_enum_bind.state".into())
        ]]
    );

    let sql_null = connection
        .query_params(
            "SELECT id, pg_typeof(status)::text FROM value_contract_enum_bind.rows \
             WHERE status IS NOT DISTINCT FROM $1 ORDER BY id",
            &[Value::Null],
        )
        .await
        .unwrap();
    assert_eq!(
        sql_null.rows,
        vec![vec![
            Value::Int(2),
            Value::Text("value_contract_enum_bind.state".into())
        ]]
    );

    let updated = connection
        .execute_params(
            "UPDATE value_contract_enum_bind.rows SET status = $1 WHERE id = 3",
            &[Value::Text("ready".into())],
        )
        .await
        .unwrap();
    assert_eq!(updated.rows_affected, 1);
    let stored = connection
        .query(
            "SELECT status::text, pg_typeof(status)::text FROM value_contract_enum_bind.rows \
             WHERE id = 3",
        )
        .await
        .unwrap();
    assert_eq!(
        stored.rows,
        vec![vec![
            Value::Text("ready".into()),
            Value::Text("value_contract_enum_bind.state".into())
        ]]
    );

    let direct_null = connection
        .execute_params(
            "UPDATE value_contract_enum_bind.rows SET status = $1 WHERE id = 3",
            &[Value::Null],
        )
        .await
        .unwrap();
    assert_eq!(direct_null.rows_affected, 1);
    let direct_null_value = connection
        .query(
            "SELECT status::text, pg_typeof(status)::text FROM value_contract_enum_bind.rows \
             WHERE id = 3",
        )
        .await
        .unwrap();
    assert_eq!(
        direct_null_value.rows,
        vec![vec![Value::Null, Value::Text("value_contract_enum_bind.state".into())]]
    );

    let transaction_results = connection
        .execute_in_transaction(&[
            (
                "UPDATE value_contract_enum_bind.rows SET status = $1 WHERE id = 1".into(),
                vec![Value::Text("東京".into())],
            ),
            (
                "UPDATE value_contract_enum_bind.rows SET status = $1 WHERE id = 3".into(),
                vec![Value::Null],
            ),
        ])
        .await
        .unwrap();
    assert_eq!(transaction_results, vec![1, 1]);
    let transaction_values = connection
        .query(
            "SELECT id, status::text, pg_typeof(status)::text FROM value_contract_enum_bind.rows \
             WHERE id IN (1, 3) ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(
        transaction_values.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("東京".into()),
                Value::Text("value_contract_enum_bind.state".into())
            ],
            vec![
                Value::Int(3),
                Value::Null,
                Value::Text("value_contract_enum_bind.state".into())
            ],
        ]
    );

    let invalid = connection
        .query_params(
            "SELECT id FROM value_contract_enum_bind.rows WHERE status = $1",
            &[Value::Text("missing".into())],
        )
        .await
        .unwrap_err();
    assert!(matches!(
        invalid,
        tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "22P02"
    ));

    let plain_text = connection
        .query_params("SELECT $1, pg_typeof($1)::text", &[Value::Text("plain text".into())])
        .await
        .unwrap();
    assert_eq!(
        plain_text.rows,
        vec![vec![Value::Text("plain text".into()), Value::Text("text".into())]]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_custom_enum_keyed_edit_preserves_label_and_siblings() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE SCHEMA value_contract_enum_schema")
        .await
        .unwrap();
    connection
        .execute("CREATE TYPE value_contract_enum_schema.value_contract_grid_enum AS ENUM ('ready', 'paused', 'NULL')")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE value_contract_enum_edits (id INT PRIMARY KEY, \
             status value_contract_enum_schema.value_contract_grid_enum, sibling TEXT NOT NULL)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO value_contract_enum_edits VALUES \
             (1, 'ready', 'left'), (2, 'ready', 'right')",
        )
        .await
        .unwrap();

    let columns = connection
        .fetch_columns(None, "value_contract_enum_edits")
        .await
        .unwrap();
    assert_eq!(
        columns[1].enum_type,
        Some(tablepro_core::QualifiedTypeName {
            schema: "value_contract_enum_schema".into(),
            name: "value_contract_grid_enum".into(),
        })
    );
    let (sql, params) = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "value_contract_enum_edits",
        &columns,
        &[(1, Value::Text("paused".into()))],
        &[Value::Int(1)],
    )
    .unwrap();
    connection.execute_params(&sql, &params).await.unwrap();
    let insert_columns = [columns[0].clone(), columns[1].clone(), columns[2].clone()];
    let (sql, params) = tablepro_core::sql_dialect::build_insert_from_draft(
        "postgres",
        None,
        "value_contract_enum_edits",
        &insert_columns,
        &[
            Value::Int(3),
            Value::Text("NULL".into()),
            Value::Text("inserted".into()),
        ],
    )
    .unwrap();
    connection.execute_params(&sql, &params).await.unwrap();
    let (sql, params) = tablepro_core::sql_dialect::build_insert_from_draft(
        "postgres",
        None,
        "value_contract_enum_edits",
        &insert_columns,
        &[Value::Int(4), Value::Null, Value::Text("inserted-null".into())],
    )
    .unwrap();
    connection.execute_params(&sql, &params).await.unwrap();
    let (sql, params) = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "value_contract_enum_edits",
        &columns,
        &[(1, Value::Null)],
        &[Value::Int(2)],
    )
    .unwrap();
    connection.execute_params(&sql, &params).await.unwrap();

    let result = connection
        .query(
            "SELECT id, status::text, pg_typeof(status)::text AS native_type, sibling \
             FROM value_contract_enum_edits ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(
        result.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("paused".into()),
                Value::Text("value_contract_enum_schema.value_contract_grid_enum".into()),
                Value::Text("left".into()),
            ],
            vec![
                Value::Int(2),
                Value::Null,
                Value::Text("value_contract_enum_schema.value_contract_grid_enum".into()),
                Value::Text("right".into()),
            ],
            vec![
                Value::Int(3),
                Value::Text("NULL".into()),
                Value::Text("value_contract_enum_schema.value_contract_grid_enum".into()),
                Value::Text("inserted".into()),
            ],
            vec![
                Value::Int(4),
                Value::Null,
                Value::Text("value_contract_enum_schema.value_contract_grid_enum".into()),
                Value::Text("inserted-null".into()),
            ],
        ]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_custom_enum_keyed_edit_resolves_shadowed_type_name_by_schema() {
    let (_container, opts) = start_pg().await;
    let setup = connect(opts.clone()).await;
    setup.execute("CREATE SCHEMA enum_shadow_a").await.unwrap();
    setup.execute("CREATE SCHEMA enum_shadow_b").await.unwrap();
    setup
        .execute("CREATE TYPE enum_shadow_a.status_kind AS ENUM ('ready', 'paused')")
        .await
        .unwrap();
    setup
        .execute("CREATE TYPE enum_shadow_b.status_kind AS ENUM ('ready', 'paused')")
        .await
        .unwrap();
    setup
        .execute(
            "CREATE TABLE enum_shadow_a.items (id INT PRIMARY KEY, status enum_shadow_a.status_kind, sibling TEXT NOT NULL)",
        )
        .await
        .unwrap();
    setup
        .execute(
            "CREATE TABLE enum_shadow_b.items (id INT PRIMARY KEY, status enum_shadow_b.status_kind, sibling TEXT NOT NULL)",
        )
        .await
        .unwrap();
    setup
        .execute("INSERT INTO enum_shadow_a.items VALUES (1, 'ready', 'shadow')")
        .await
        .unwrap();
    setup
        .execute("INSERT INTO enum_shadow_b.items VALUES (1, 'ready', 'target')")
        .await
        .unwrap();
    setup
        .execute("ALTER ROLE postgres SET search_path TO enum_shadow_a")
        .await
        .unwrap();
    drop(setup);

    let connection = connect(opts).await;
    assert_eq!(
        connection.query("SELECT current_schema()::text").await.unwrap().rows,
        vec![vec![Value::Text("enum_shadow_a".into())]]
    );

    let columns = connection.fetch_columns(Some("enum_shadow_b"), "items").await.unwrap();
    assert_eq!(
        columns[1].enum_type,
        Some(tablepro_core::QualifiedTypeName {
            schema: "enum_shadow_b".into(),
            name: "status_kind".into(),
        })
    );
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        Some("enum_shadow_b"),
        "items",
        &columns,
        &[(1, Value::Text("paused".into()))],
        &[Value::Int(1)],
    )
    .unwrap();
    connection.execute_params(&update.0, &update.1).await.unwrap();

    let target = connection
        .query("SELECT id, status::text, pg_typeof(status)::text, sibling FROM enum_shadow_b.items")
        .await
        .unwrap();
    let shadow = connection
        .query("SELECT id, status::text, pg_typeof(status)::text, sibling FROM enum_shadow_a.items")
        .await
        .unwrap();
    assert_eq!(
        target.rows,
        vec![vec![
            Value::Int(1),
            Value::Text("paused".into()),
            Value::Text("enum_shadow_b.status_kind".into()),
            Value::Text("target".into()),
        ]]
    );
    assert_eq!(
        shadow.rows,
        vec![vec![
            Value::Int(1),
            Value::Text("ready".into()),
            Value::Text("status_kind".into()),
            Value::Text("shadow".into()),
        ]]
    );

    let filters = tablepro_core::FilterSet {
        rules: vec![tablepro_core::FilterRule {
            column: "status".into(),
            op: tablepro_core::FilterOp::Eq,
            value: Some(tablepro_core::FilterValue::Single("paused".into())),
        }],
        ..Default::default()
    };
    let (where_sql, params) = tablepro_core::build_filter_where("postgres", &columns, &filters)
        .unwrap()
        .unwrap();
    let filtered = connection
        .query_params(
            &format!(
                "SELECT id, status::text, pg_typeof(status)::text \
                 FROM enum_shadow_b.items WHERE {where_sql} ORDER BY id"
            ),
            &params,
        )
        .await
        .unwrap();
    assert_eq!(
        filtered.rows,
        vec![vec![
            Value::Int(1),
            Value::Text("paused".into()),
            Value::Text("enum_shadow_b.status_kind".into()),
        ]]
    );

    for (operator, value) in [
        (
            tablepro_core::FilterOp::In,
            tablepro_core::FilterValue::List(vec!["ready".into(), "paused".into()]),
        ),
        (
            tablepro_core::FilterOp::Between,
            tablepro_core::FilterValue::Pair("ready".into(), "paused".into()),
        ),
    ] {
        let filters = tablepro_core::FilterSet {
            rules: vec![tablepro_core::FilterRule {
                column: "status".into(),
                op: operator,
                value: Some(value),
            }],
            ..Default::default()
        };
        let (where_sql, params) = tablepro_core::build_filter_where("postgres", &columns, &filters)
            .unwrap()
            .unwrap();
        let filtered = connection
            .query_params(
                &format!(
                    "SELECT id, status::text, pg_typeof(status)::text \
                     FROM enum_shadow_b.items WHERE {where_sql} ORDER BY id"
                ),
                &params,
            )
            .await
            .unwrap();
        assert_eq!(
            filtered.rows,
            vec![vec![
                Value::Int(1),
                Value::Text("paused".into()),
                Value::Text("enum_shadow_b.status_kind".into()),
            ]],
            "operator {operator:?} under shadowed search_path"
        );
    }

    for (operator, placeholders, params) in [
        ("=", "$1", vec![Value::Text("paused".into())]),
        (
            "IN",
            "($1, $2)",
            vec![Value::Text("ready".into()), Value::Text("paused".into())],
        ),
        (
            "BETWEEN",
            "$1 AND $2",
            vec![Value::Text("paused".into()), Value::Text("paused".into())],
        ),
    ] {
        let parameterized = connection
            .query_params(
                &format!(
                    "SELECT id, status::text, pg_typeof(status)::text \
                     FROM enum_shadow_b.items \
                     WHERE status::enum_shadow_b.status_kind {operator} {placeholders} ORDER BY id"
                ),
                &params,
            )
            .await
            .unwrap();
        assert_eq!(
            parameterized.rows,
            vec![vec![
                Value::Int(1),
                Value::Text("paused".into()),
                Value::Text("enum_shadow_b.status_kind".into()),
            ]],
            "direct {operator} parameters under shadowed search_path"
        );
    }

    let mut transaction = connection.begin().await.unwrap();
    transaction
        .execute("SET search_path TO enum_shadow_b, enum_shadow_a")
        .await
        .unwrap();
    assert_eq!(
        transaction.query("SELECT current_schema()::text").await.unwrap().rows,
        vec![vec![Value::Text("enum_shadow_b".into())]]
    );
    transaction.execute("SET search_path TO enum_shadow_a").await.unwrap();
    assert_eq!(
        transaction.query("SELECT current_schema()::text").await.unwrap().rows,
        vec![vec![Value::Text("enum_shadow_a".into())]]
    );
    let session_inferred = transaction
        .query_params(
            "SELECT id, status::text, pg_typeof(status)::text \
             FROM enum_shadow_b.items WHERE status = $1 ORDER BY id",
            &[Value::Text("paused".into())],
        )
        .await
        .unwrap();
    assert_eq!(
        session_inferred.rows,
        vec![vec![
            Value::Int(1),
            Value::Text("paused".into()),
            Value::Text("enum_shadow_b.status_kind".into()),
        ]]
    );

    let session_update = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        Some("enum_shadow_b"),
        "items",
        &columns,
        &[(1, Value::Text("ready".into()))],
        &[Value::Int(1)],
    )
    .unwrap();
    transaction
        .execute_params(&session_update.0, &session_update.1)
        .await
        .unwrap();
    assert_eq!(
        transaction
            .query("SELECT status::text, pg_typeof(status)::text FROM enum_shadow_b.items WHERE id = 1")
            .await
            .unwrap()
            .rows,
        vec![vec![
            Value::Text("ready".into()),
            Value::Text("enum_shadow_b.status_kind".into()),
        ]]
    );
    transaction.rollback().await.unwrap();

    let ambiguous_native = connection
        .execute(
            "PREPARE enum_shadow_ambiguous_parameter AS \
             SELECT pg_typeof($1)::text FROM enum_shadow_b.items \
             WHERE status::enum_shadow_b.status_kind = $1",
        )
        .await
        .expect_err("PostgreSQL cannot infer a type shared only with pg_typeof");
    assert!(matches!(
        ambiguous_native,
        tablepro_core::DriverError::Query {
            sqlstate: Some(code), ..
        } if code == "42P08"
    ));

    let ambiguous_driver = connection
        .query_params(
            "SELECT id, pg_typeof($1)::text FROM enum_shadow_b.items \
             WHERE status::enum_shadow_b.status_kind = $1",
            &[Value::Text("paused".into())],
        )
        .await
        .expect_err("ambiguous parameter type must remain a query error");
    assert!(matches!(
        ambiguous_driver,
        tablepro_core::DriverError::Query {
            sqlstate: Some(code), ..
        } if code == "42P08"
    ));

    let explicitly_typed = connection
        .query_params(
            "SELECT id, pg_typeof($1::enum_shadow_b.status_kind)::text, \
             pg_typeof(status)::text FROM enum_shadow_b.items \
             WHERE status::enum_shadow_b.status_kind = $1::enum_shadow_b.status_kind",
            &[Value::Text("paused".into())],
        )
        .await
        .unwrap();
    assert_eq!(
        explicitly_typed.rows,
        vec![vec![
            Value::Int(1),
            Value::Text("enum_shadow_b.status_kind".into()),
            Value::Text("enum_shadow_b.status_kind".into()),
        ]]
    );

    let shadow_after = connection
        .query("SELECT id, status::text, sibling FROM enum_shadow_a.items")
        .await
        .unwrap();
    assert_eq!(
        shadow_after.rows,
        vec![vec![
            Value::Int(1),
            Value::Text("ready".into()),
            Value::Text("shadow".into()),
        ]]
    );
}
