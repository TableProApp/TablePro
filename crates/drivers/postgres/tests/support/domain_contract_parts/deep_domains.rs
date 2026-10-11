#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_three_level_domain_over_enum_infers_parameters_and_decodes() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE SCHEMA value_contract_nested_domain")
        .await
        .unwrap();
    connection
        .execute("CREATE TYPE value_contract_nested_domain.state AS ENUM ('NULL', '', '東京', 'ready')")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE DOMAIN value_contract_nested_domain.state_inner \
             AS value_contract_nested_domain.state",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE DOMAIN value_contract_nested_domain.state_middle \
             AS value_contract_nested_domain.state_inner",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE DOMAIN value_contract_nested_domain.state_outer \
             AS value_contract_nested_domain.state_middle",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE value_contract_nested_domain.rows \
             (id INT PRIMARY KEY, status value_contract_nested_domain.state_outer)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO value_contract_nested_domain.rows VALUES \
             (1, 'NULL'), (2, '東京'), (3, '東京')",
        )
        .await
        .unwrap();

    let columns = connection
        .fetch_columns(Some("value_contract_nested_domain"), "rows")
        .await
        .unwrap();
    assert_eq!(
        columns[1].enum_type,
        Some(tablepro_core::QualifiedTypeName {
            schema: "value_contract_nested_domain".into(),
            name: "state".into(),
        })
    );

    let projected = connection
        .query(
            "SELECT id, status::text, pg_typeof(status)::text \
             FROM value_contract_nested_domain.rows ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(
        projected.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("NULL".into()),
                Value::Text("value_contract_nested_domain.state_outer".into()),
            ],
            vec![
                Value::Int(2),
                Value::Text("東京".into()),
                Value::Text("value_contract_nested_domain.state_outer".into()),
            ],
            vec![
                Value::Int(3),
                Value::Text("東京".into()),
                Value::Text("value_contract_nested_domain.state_outer".into()),
            ],
        ]
    );

    let uncast_comparison = connection
        .query_params(
            "SELECT id, status::text, pg_typeof(status)::text \
             FROM value_contract_nested_domain.rows WHERE status = $1",
            &[Value::Text("NULL".into())],
        )
        .await
        .expect_err("PostgreSQL cannot resolve domain = unknown without an explicit cast");
    assert!(matches!(
        uncast_comparison,
        tablepro_core::DriverError::Query {
            sqlstate: Some(code), ..
        } if code == "42883"
    ));
    let typed_comparison = connection
        .query_params(
            "SELECT id, status::text, pg_typeof(status)::text \
             FROM value_contract_nested_domain.rows \
             WHERE status::value_contract_nested_domain.state = \
                   $1::value_contract_nested_domain.state",
            &[Value::Text("NULL".into())],
        )
        .await
        .unwrap();
    assert_eq!(
        typed_comparison.rows,
        vec![vec![
            Value::Int(1),
            Value::Text("NULL".into()),
            Value::Text("value_contract_nested_domain.state_outer".into()),
        ]]
    );

    let updated = connection
        .execute_params(
            "UPDATE value_contract_nested_domain.rows SET status = $1 WHERE id = 2",
            &[Value::Text("ready".into())],
        )
        .await
        .unwrap();
    assert_eq!(updated.rows_affected, 1);
    let invalid = connection
        .execute_params(
            "UPDATE value_contract_nested_domain.rows SET status = $1 WHERE id = 2",
            &[Value::Text("not a label".into())],
        )
        .await
        .expect_err("invalid nested-domain enum labels must be refused by PostgreSQL");
    assert!(matches!(
        invalid,
        tablepro_core::DriverError::Query {
            sqlstate: Some(code), ..
        } if code == "22P02"
    ));
    let after_invalid = connection
        .query(
            "SELECT status::text, pg_typeof(status)::text \
             FROM value_contract_nested_domain.rows WHERE id = 2",
        )
        .await
        .unwrap();
    assert_eq!(
        after_invalid.rows,
        vec![vec![
            Value::Text("ready".into()),
            Value::Text("value_contract_nested_domain.state_outer".into()),
        ]]
    );

    let literal_null_filter = FilterSet {
        rules: vec![FilterRule {
            column: "status".into(),
            op: FilterOp::Eq,
            value: Some(tablepro_core::FilterValue::Single("NULL".into())),
        }],
        ..Default::default()
    };
    let (where_sql, params) = tablepro_core::build_filter_where("postgres", &columns, &literal_null_filter)
        .unwrap()
        .unwrap();
    let filtered = connection
        .query_params(
            &format!(
                "SELECT id, status::text, pg_typeof(status)::text \
                 FROM value_contract_nested_domain.rows WHERE {where_sql}"
            ),
            &params,
        )
        .await
        .unwrap();
    assert_eq!(
        filtered.rows,
        vec![vec![
            Value::Int(1),
            Value::Text("NULL".into()),
            Value::Text("value_contract_nested_domain.state_outer".into()),
        ]]
    );

    let (update_sql, update_params) = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        Some("value_contract_nested_domain"),
        "rows",
        &columns,
        &[(1, Value::Text("東京".into()))],
        &[Value::Int(2)],
    )
    .unwrap();
    connection.execute_params(&update_sql, &update_params).await.unwrap();
    let (insert_sql, insert_params) = tablepro_core::sql_dialect::build_insert_from_draft(
        "postgres",
        Some("value_contract_nested_domain"),
        "rows",
        &columns,
        &[Value::Int(4), Value::Text("NULL".into())],
    )
    .unwrap();
    connection.execute_params(&insert_sql, &insert_params).await.unwrap();

    let transaction = connection
        .execute_in_transaction(&[
            (
                "UPDATE value_contract_nested_domain.rows SET status = $1 WHERE id = 1".into(),
                vec![Value::Text(String::new())],
            ),
            (
                "UPDATE value_contract_nested_domain.rows SET status = $1 WHERE id = 3".into(),
                vec![Value::Null],
            ),
        ])
        .await
        .unwrap();
    assert_eq!(transaction, vec![1, 1]);

    for (operator, parameter, expected) in [
        (
            "IS DISTINCT FROM",
            Value::Text("東京".into()),
            [true, false, true, true],
        ),
        (
            "IS NOT DISTINCT FROM",
            Value::Text("東京".into()),
            [false, true, false, false],
        ),
        ("IS DISTINCT FROM", Value::Null, [true, true, false, true]),
        ("IS NOT DISTINCT FROM", Value::Null, [false, false, true, false]),
    ] {
        let result = connection
            .query_params(
                &format!(
                    "SELECT id, status::value_contract_nested_domain.state {operator} $1, \
                     pg_typeof($1)::text, pg_typeof(status)::text \
                     FROM value_contract_nested_domain.rows ORDER BY id"
                ),
                std::slice::from_ref(&parameter),
            )
            .await
            .unwrap();
        let expected = expected
            .into_iter()
            .enumerate()
            .map(|(index, comparison)| {
                vec![
                    Value::Int(index as i64 + 1),
                    Value::Bool(comparison),
                    Value::Text("value_contract_nested_domain.state".into()),
                    Value::Text("value_contract_nested_domain.state_outer".into()),
                ]
            })
            .collect::<Vec<_>>();
        assert_eq!(result.rows, expected, "operator {operator}, parameter {parameter:?}");
    }

    let typed_null = connection
        .query_params(
            "SELECT id, status::text, pg_typeof(status)::text \
             FROM value_contract_nested_domain.rows \
             WHERE status::value_contract_nested_domain.state \
                   IS NOT DISTINCT FROM $1::value_contract_nested_domain.state",
            &[Value::Null],
        )
        .await
        .unwrap();
    assert_eq!(
        typed_null.rows,
        vec![vec![
            Value::Int(3),
            Value::Null,
            Value::Text("value_contract_nested_domain.state_outer".into()),
        ]]
    );
    let stored = connection
        .query(
            "SELECT id, status::text, pg_typeof(status)::text \
             FROM value_contract_nested_domain.rows ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(
        stored.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text(String::new()),
                Value::Text("value_contract_nested_domain.state_outer".into()),
            ],
            vec![
                Value::Int(2),
                Value::Text("東京".into()),
                Value::Text("value_contract_nested_domain.state_outer".into()),
            ],
            vec![
                Value::Int(3),
                Value::Null,
                Value::Text("value_contract_nested_domain.state_outer".into()),
            ],
            vec![
                Value::Int(4),
                Value::Text("NULL".into()),
                Value::Text("value_contract_nested_domain.state_outer".into()),
            ],
        ]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_four_domain_levels_over_enum_preserve_metadata_and_keyed_values() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE SCHEMA value_contract_four_domains")
        .await
        .unwrap();
    connection
        .execute("CREATE TYPE value_contract_four_domains.state AS ENUM ('ready', 'paused')")
        .await
        .unwrap();

    let mut base_type = "state".to_owned();
    for level in 1..=4 {
        let domain = format!("state_domain_{level}");
        connection
            .execute(&format!(
                "CREATE DOMAIN value_contract_four_domains.{domain} \
                 AS value_contract_four_domains.{base_type}"
            ))
            .await
            .unwrap();
        base_type = domain;
    }
    connection
        .execute(&format!(
            "CREATE TABLE value_contract_four_domains.rows \
             (id INT PRIMARY KEY, status value_contract_four_domains.{base_type})"
        ))
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO value_contract_four_domains.rows VALUES \
             (1, 'ready'), (2, NULL), (3, 'ready')",
        )
        .await
        .unwrap();

    let columns = connection
        .fetch_columns(Some("value_contract_four_domains"), "rows")
        .await
        .unwrap();
    assert_eq!(
        columns[1].enum_type,
        Some(tablepro_core::QualifiedTypeName {
            schema: "value_contract_four_domains".into(),
            name: "state".into(),
        })
    );

    let (update_sql, update_params) = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        Some("value_contract_four_domains"),
        "rows",
        &columns,
        &[(1, Value::Text("paused".into()))],
        &[Value::Int(1)],
    )
    .unwrap();
    connection.execute_params(&update_sql, &update_params).await.unwrap();

    let inferred_query = connection
        .query_params(
            "SELECT id, status::text, pg_typeof(status)::text \
             FROM value_contract_four_domains.rows \
             WHERE status::value_contract_four_domains.state = $1 ORDER BY id",
            &[Value::Text("paused".into())],
        )
        .await
        .unwrap();
    assert_eq!(
        inferred_query.rows,
        vec![vec![
            Value::Int(1),
            Value::Text("paused".into()),
            Value::Text("value_contract_four_domains.state_domain_4".into()),
        ]]
    );

    let ambiguous_parameter = connection
        .execute(
            "PREPARE four_domain_ambiguous_parameter AS \
             SELECT pg_typeof($1)::text FROM value_contract_four_domains.rows \
             WHERE status::value_contract_four_domains.state = $1",
        )
        .await
        .expect_err("pg_typeof leaves this enum comparison parameter ambiguous");
    assert!(matches!(
        ambiguous_parameter,
        tablepro_core::DriverError::Query {
            sqlstate: Some(code), ..
        } if code == "42P08"
    ));

    let explicitly_typed = connection
        .query_params(
            "SELECT id, pg_typeof($1::value_contract_four_domains.state)::text, \
             pg_typeof(status)::text \
             FROM value_contract_four_domains.rows \
             WHERE status::value_contract_four_domains.state = \
                   $1::value_contract_four_domains.state ORDER BY id",
            &[Value::Text("paused".into())],
        )
        .await
        .unwrap();
    assert_eq!(
        explicitly_typed.rows,
        vec![vec![
            Value::Int(1),
            Value::Text("value_contract_four_domains.state".into()),
            Value::Text("value_contract_four_domains.state_domain_4".into()),
        ]]
    );

    let inferred_update = connection
        .execute_params(
            "UPDATE value_contract_four_domains.rows SET status = $1 WHERE id = 3",
            &[Value::Text("paused".into())],
        )
        .await
        .unwrap();
    assert_eq!(inferred_update.rows_affected, 1);

    let filters = FilterSet {
        rules: vec![FilterRule {
            column: "status".into(),
            op: FilterOp::Eq,
            value: Some(FilterValue::Single("paused".into())),
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
                 FROM value_contract_four_domains.rows WHERE {where_sql} ORDER BY id"
            ),
            &params,
        )
        .await
        .unwrap();
    assert_eq!(
        filtered.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("paused".into()),
                Value::Text("value_contract_four_domains.state_domain_4".into()),
            ],
            vec![
                Value::Int(3),
                Value::Text("paused".into()),
                Value::Text("value_contract_four_domains.state_domain_4".into()),
            ],
        ]
    );

    let stored = connection
        .query(
            "SELECT id, status::text, pg_typeof(status)::text \
             FROM value_contract_four_domains.rows ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(
        stored.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("paused".into()),
                Value::Text("value_contract_four_domains.state_domain_4".into()),
            ],
            vec![
                Value::Int(2),
                Value::Null,
                Value::Text("value_contract_four_domains.state_domain_4".into()),
            ],
            vec![
                Value::Int(3),
                Value::Text("paused".into()),
                Value::Text("value_contract_four_domains.state_domain_4".into()),
            ],
        ]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_five_domain_levels_over_enum_preserve_metadata_and_values() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE SCHEMA value_contract_five_domains")
        .await
        .unwrap();
    connection
        .execute("CREATE TYPE value_contract_five_domains.state AS ENUM ('ready', 'paused')")
        .await
        .unwrap();

    let mut base_type = "state".to_owned();
    for level in 1..=5 {
        let domain = format!("state_domain_{level}");
        connection
            .execute(&format!(
                "CREATE DOMAIN value_contract_five_domains.{domain} \
                 AS value_contract_five_domains.{base_type}"
            ))
            .await
            .unwrap();
        base_type = domain;
    }
    connection
        .execute(&format!(
            "CREATE TABLE value_contract_five_domains.rows \
             (id INT PRIMARY KEY, status value_contract_five_domains.{base_type})"
        ))
        .await
        .unwrap();
    connection
        .execute("INSERT INTO value_contract_five_domains.rows VALUES (1, 'ready'), (2, NULL), (3, 'ready')")
        .await
        .unwrap();

    let columns = connection
        .fetch_columns(Some("value_contract_five_domains"), "rows")
        .await
        .unwrap();
    assert_eq!(
        columns[1].enum_type,
        Some(tablepro_core::QualifiedTypeName {
            schema: "value_contract_five_domains".into(),
            name: "state".into(),
        })
    );

    let (update_sql, update_params) = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        Some("value_contract_five_domains"),
        "rows",
        &columns,
        &[(1, Value::Text("paused".into()))],
        &[Value::Int(1)],
    )
    .unwrap();
    connection.execute_params(&update_sql, &update_params).await.unwrap();

    let inferred = connection
        .query_params(
            "SELECT id, status::text, pg_typeof(status)::text \
             FROM value_contract_five_domains.rows \
             WHERE status::value_contract_five_domains.state = $1 ORDER BY id",
            &[Value::Text("paused".into())],
        )
        .await
        .unwrap();
    assert_eq!(
        inferred.rows,
        vec![vec![
            Value::Int(1),
            Value::Text("paused".into()),
            Value::Text("value_contract_five_domains.state_domain_5".into()),
        ]]
    );

    let inferred_update = connection
        .execute_params(
            "UPDATE value_contract_five_domains.rows SET status = $1 WHERE id = 3",
            &[Value::Text("paused".into())],
        )
        .await
        .unwrap();
    assert_eq!(inferred_update.rows_affected, 1);
    let invalid = connection
        .execute_params(
            "UPDATE value_contract_five_domains.rows SET status = $1 WHERE id = 3",
            &[Value::Text("not a label".into())],
        )
        .await
        .expect_err("invalid enum label must be refused through five domain layers");
    assert!(matches!(
        invalid,
        tablepro_core::DriverError::Query {
            sqlstate: Some(code), ..
        } if code == "22P02"
    ));

    let filtered = FilterSet {
        rules: vec![FilterRule {
            column: "status".into(),
            op: FilterOp::Eq,
            value: Some(FilterValue::Single("paused".into())),
        }],
        ..Default::default()
    };
    let (where_sql, params) = tablepro_core::build_filter_where("postgres", &columns, &filtered)
        .unwrap()
        .unwrap();
    let result = connection
        .query_params(
            &format!(
                "SELECT id, status::text, pg_typeof(status)::text \
                 FROM value_contract_five_domains.rows WHERE {where_sql} ORDER BY id"
            ),
            &params,
        )
        .await
        .unwrap();
    let outer_domain = Value::Text("value_contract_five_domains.state_domain_5".into());
    assert_eq!(
        result.rows,
        vec![
            vec![Value::Int(1), Value::Text("paused".into()), outer_domain.clone()],
            vec![Value::Int(3), Value::Text("paused".into()), outer_domain.clone()],
        ]
    );

    let stored = connection
        .query(
            "SELECT id, status::text, pg_typeof(status)::text \
             FROM value_contract_five_domains.rows ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(
        stored.rows,
        vec![
            vec![Value::Int(1), Value::Text("paused".into()), outer_domain.clone()],
            vec![Value::Int(2), Value::Null, outer_domain.clone()],
            vec![Value::Int(3), Value::Text("paused".into()), outer_domain],
        ]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_deep_domain_levels_over_enum_ignore_shadowed_search_path() {
    let (_container, opts) = start_pg().await;
    assert_domain_level_contract(opts.clone(), 6).await;
    assert_domain_level_contract(opts.clone(), 7).await;
    assert_domain_level_contract(opts.clone(), 8).await;
    assert_domain_level_contract(opts.clone(), 9).await;
    assert_domain_level_contract(opts.clone(), 10).await;
    assert_domain_level_contract(opts.clone(), 63).await;
    assert_domain_level_contract(opts.clone(), 64).await;
    assert_domain_level_contract(opts.clone(), 65).await;
    assert_domain_level_contract(opts.clone(), 128).await;
    assert_domain_level_contract(opts.clone(), 129).await;
    assert_domain_level_contract(opts.clone(), 256).await;
    assert_domain_level_contract(opts.clone(), 260).await;
    assert_domain_level_contract(opts.clone(), 300).await;
    assert_domain_level_contract(opts.clone(), 301).await;
    assert_domain_level_contract(opts.clone(), 302).await;
    assert_domain_level_contract(opts.clone(), 512).await;
    assert_domain_level_contract(opts.clone(), 513).await;
    assert_domain_level_contract(opts.clone(), 1024).await;
    assert_domain_level_contract(opts.clone(), 1025).await;
    assert_domain_level_contract(opts.clone(), 2048).await;
    assert_domain_level_contract(opts, 4096).await;
}

async fn assert_domain_level_contract(opts: tablepro_core::ConnectOptions, levels: usize) {
    let schema = format!("value_contract_{levels}_domains");
    let shadow_schema = format!("value_contract_{levels}_shadow");
    let setup = connect(opts.clone()).await;
    setup.execute(&format!("CREATE SCHEMA {schema}")).await.unwrap();
    setup
        .execute(&format!("CREATE TYPE {schema}.state AS ENUM ('ready', 'paused')"))
        .await
        .unwrap();

    let mut base_type = "state".to_owned();
    for level in 1..=levels {
        let domain = format!("state_domain_{level}");
        setup
            .execute(&format!(
                "CREATE DOMAIN {schema}.{domain} \
                 AS {schema}.{base_type}"
            ))
            .await
            .unwrap();
        base_type = domain;
    }
    setup
        .execute(&format!(
            "CREATE TABLE {schema}.rows \
             (id INT PRIMARY KEY, status {schema}.{base_type})"
        ))
        .await
        .unwrap();
    setup
        .execute(&format!(
            "INSERT INTO {schema}.rows VALUES (1, 'ready'), (2, NULL), (3, 'ready')"
        ))
        .await
        .unwrap();

    setup.execute(&format!("CREATE SCHEMA {shadow_schema}")).await.unwrap();
    setup
        .execute(&format!("CREATE TYPE {shadow_schema}.state AS ENUM ('ready')"))
        .await
        .unwrap();
    setup
        .execute(&format!("ALTER ROLE postgres SET search_path TO {shadow_schema}"))
        .await
        .unwrap();
    drop(setup);

    let connection = connect(opts).await;
    assert_eq!(
        connection.query("SELECT current_schema()::text").await.unwrap().rows,
        vec![vec![Value::Text(shadow_schema.clone())]]
    );
    if levels >= 1024 {
        assert_deep_enum_array_parameter_contract(connection.as_ref(), &schema, &base_type, levels).await;
    }
    if matches!(levels, 63 | 64) {
        assert_enum_array_parameter_depth_boundary(connection.as_ref(), &schema, &base_type, levels).await;
    }
    if levels >= 63 {
        assert_deep_enum_array_scalar_parameters(connection.as_ref(), &schema, levels).await;
    }
    if levels >= 64 {
        assert_deep_enum_expression_parameters(connection.as_ref(), &schema, levels).await;
    }

    let columns = connection.fetch_columns(Some(&schema), "rows").await.unwrap();
    assert_eq!(
        columns[1].enum_type,
        Some(tablepro_core::QualifiedTypeName {
            schema: schema.clone(),
            name: "state".into(),
        })
    );
    let projected = connection
        .query(&format!(
            "SELECT status, pg_typeof(status)::text \
             FROM {schema}.rows WHERE id = 1"
        ))
        .await
        .unwrap();
    let outer_domain = format!("{schema}.state_domain_{levels}");
    assert_eq!(projected.columns[0].data_type, outer_domain);
    assert_eq!(
        projected.rows,
        vec![vec![
            Value::Text("ready".into()),
            Value::Text(format!("{schema}.state_domain_{levels}")),
        ]]
    );
    if levels >= 302 {
        assert_domain_array_result_contract(connection.as_ref(), &schema, &base_type, levels).await;
    }
    let (update_sql, update_params) = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        Some(&schema),
        "rows",
        &columns,
        &[(1, Value::Text("paused".into()))],
        &[Value::Int(1)],
    )
    .unwrap();
    connection.execute_params(&update_sql, &update_params).await.unwrap();

    let (insert_sql, insert_params) = tablepro_core::sql_dialect::build_insert_from_draft(
        "postgres",
        Some(&schema),
        "rows",
        &columns,
        &[Value::Int(4), Value::Text("paused".into())],
    )
    .unwrap();
    connection.execute_params(&insert_sql, &insert_params).await.unwrap();
    let (insert_null_sql, insert_null_params) = tablepro_core::sql_dialect::build_insert_from_draft(
        "postgres",
        Some(&schema),
        "rows",
        &columns,
        &[Value::Int(5), Value::Null],
    )
    .unwrap();
    connection
        .execute_params(&insert_null_sql, &insert_null_params)
        .await
        .unwrap();

    let invalid = connection
        .execute_params(
            &format!("UPDATE {schema}.rows SET status = $1 WHERE id = 3"),
            &[Value::Text("not a label".into())],
        )
        .await
        .expect_err(&format!(
            "invalid enum label must be refused through {levels} domain layers"
        ));
    if levels >= 64 {
        assert!(
            matches!(&invalid, tablepro_core::DriverError::Unsupported(message)
                if message.contains("resolvable depth")),
            "depth {levels}: {invalid:?}"
        );
        let null_inference = connection
            .execute_params(
                &format!("UPDATE {schema}.rows SET status = $1 WHERE id = 3"),
                &[Value::Null],
            )
            .await
            .expect_err(&format!("raw inferred SQL NULL must be refused at depth {levels}"));
        assert!(
            matches!(&null_inference, tablepro_core::DriverError::Unsupported(message)
                if message.contains("resolvable depth")),
            "depth {levels}: {null_inference:?}"
        );
    } else {
        assert!(
            matches!(
                &invalid,
                tablepro_core::DriverError::Query {
                    sqlstate: Some(code), ..
                } if code == "22P02"
            ),
            "depth {levels}: {invalid:?}"
        );

        let null_update = connection
            .execute_params(
                &format!("UPDATE {schema}.rows SET status = $1 WHERE id = 3"),
                &[Value::Null],
            )
            .await
            .unwrap();
        assert_eq!(null_update.rows_affected, 1);
        let null_row = connection
            .query(&format!(
                "SELECT status IS NULL, pg_typeof(status)::text \
                 FROM {schema}.rows WHERE id = 3"
            ))
            .await
            .unwrap();
        assert_eq!(
            null_row.rows,
            vec![vec![
                Value::Bool(true),
                Value::Text(format!("{schema}.state_domain_{levels}")),
            ]]
        );
        let restore = connection
            .execute_params(
                &format!("UPDATE {schema}.rows SET status = $1 WHERE id = 3"),
                &[Value::Text("ready".into())],
            )
            .await
            .unwrap();
        assert_eq!(restore.rows_affected, 1);
    }

    let filtered = FilterSet {
        rules: vec![FilterRule {
            column: "status".into(),
            op: FilterOp::Eq,
            value: Some(FilterValue::Single("paused".into())),
        }],
        ..Default::default()
    };
    let (where_sql, params) = tablepro_core::build_filter_where("postgres", &columns, &filtered)
        .unwrap()
        .unwrap();
    let result = connection
        .query_params(
            &format!(
                "SELECT id, status::text, pg_typeof(status)::text \
                 FROM {schema}.rows WHERE {where_sql} ORDER BY id"
            ),
            &params,
        )
        .await
        .unwrap();
    assert_eq!(
        result.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("paused".into()),
                Value::Text(format!("{schema}.state_domain_{levels}")),
            ],
            vec![
                Value::Int(4),
                Value::Text("paused".into()),
                Value::Text(format!("{schema}.state_domain_{levels}")),
            ],
        ]
    );

    let stored = connection
        .query(&format!(
            "SELECT id, status::text, pg_typeof(status)::text FROM {schema}.rows ORDER BY id"
        ))
        .await
        .unwrap();
    let outer_domain = Value::Text(format!("{schema}.state_domain_{levels}"));
    assert_eq!(
        stored.rows,
        vec![
            vec![Value::Int(1), Value::Text("paused".into()), outer_domain.clone()],
            vec![Value::Int(2), Value::Null, outer_domain.clone()],
            vec![Value::Int(3), Value::Text("ready".into()), outer_domain],
            vec![
                Value::Int(4),
                Value::Text("paused".into()),
                Value::Text(format!("{schema}.state_domain_{levels}")),
            ],
            vec![
                Value::Int(5),
                Value::Null,
                Value::Text(format!("{schema}.state_domain_{levels}")),
            ],
        ]
    );

    let mut transaction = connection.begin().await.unwrap();
    transaction
        .execute(&format!("SET search_path TO {schema}, {shadow_schema}"))
        .await
        .unwrap();
    assert_eq!(
        transaction.query("SELECT current_schema()::text").await.unwrap().rows,
        vec![vec![Value::Text(schema.clone())]]
    );
    transaction
        .execute(&format!("SET search_path TO {shadow_schema}"))
        .await
        .unwrap();
    assert_eq!(
        transaction.query("SELECT current_schema()::text").await.unwrap().rows,
        vec![vec![Value::Text(shadow_schema.clone())]]
    );

    let (session_update, session_params) = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        Some(&schema),
        "rows",
        &columns,
        &[(1, Value::Text("paused".into()))],
        &[Value::Int(3)],
    )
    .unwrap();
    transaction
        .execute_params(&session_update, &session_params)
        .await
        .unwrap();
    let (session_insert, session_insert_params) = tablepro_core::sql_dialect::build_insert_from_draft(
        "postgres",
        Some(&schema),
        "rows",
        &columns,
        &[Value::Int(6), Value::Text("paused".into())],
    )
    .unwrap();
    transaction
        .execute_params(&session_insert, &session_insert_params)
        .await
        .unwrap();
    let (session_null_insert, session_null_params) = tablepro_core::sql_dialect::build_insert_from_draft(
        "postgres",
        Some(&schema),
        "rows",
        &columns,
        &[Value::Int(7), Value::Null],
    )
    .unwrap();
    transaction
        .execute_params(&session_null_insert, &session_null_params)
        .await
        .unwrap();

    let session_rows = transaction
        .query_params(
            &format!(
                "SELECT id, status::text, pg_typeof(status)::text \
                 FROM {schema}.rows WHERE {where_sql} ORDER BY id"
            ),
            &params,
        )
        .await
        .unwrap();
    let typed_paused = Value::Text(format!("{schema}.state_domain_{levels}"));
    assert_eq!(
        session_rows.rows,
        vec![
            vec![Value::Int(1), Value::Text("paused".into()), typed_paused.clone()],
            vec![Value::Int(3), Value::Text("paused".into()), typed_paused.clone()],
            vec![Value::Int(4), Value::Text("paused".into()), typed_paused.clone()],
            vec![Value::Int(6), Value::Text("paused".into()), typed_paused],
        ]
    );
    let session_null = transaction
        .query(&format!(
            "SELECT id, status IS NULL, pg_typeof(status)::text \
             FROM {schema}.rows WHERE id = 7"
        ))
        .await
        .unwrap();
    assert_eq!(
        session_null.rows,
        vec![vec![
            Value::Int(7),
            Value::Bool(true),
            Value::Text(format!("{schema}.state_domain_{levels}")),
        ]]
    );

    if levels >= 64 {
        let valid_raw = transaction
            .execute_params(
                &format!("UPDATE {schema}.rows SET status = $1 WHERE id = 3"),
                &[Value::Text("ready".into())],
            )
            .await
            .expect_err(&format!("raw inferred enum text must be refused at depth {levels}"));
        assert!(
            matches!(&valid_raw, tablepro_core::DriverError::Unsupported(message)
                if message.contains("resolvable depth")),
            "depth {levels}: {valid_raw:?}"
        );
    }

    let invalid = transaction
        .execute_params(
            &format!("UPDATE {schema}.rows SET status = $1 WHERE id = 3"),
            &[Value::Text("not a label".into())],
        )
        .await
        .expect_err(&format!(
            "{levels}-level target domain rejects invalid labels under shadowed search_path"
        ));
    if levels >= 64 {
        assert!(
            matches!(&invalid, tablepro_core::DriverError::Unsupported(message)
                if message.contains("resolvable depth")),
            "depth {levels}: {invalid:?}"
        );
    } else {
        assert!(
            matches!(
                &invalid,
                tablepro_core::DriverError::Query {
                    sqlstate: Some(code), ..
                } if code == "22P02"
            ),
            "depth {levels}: {invalid:?}"
        );
    }
    transaction.rollback().await.unwrap();

    let after_rollback = connection
        .query(&format!(
            "SELECT id, status::text, pg_typeof(status)::text FROM {schema}.rows ORDER BY id"
        ))
        .await
        .unwrap();
    assert_eq!(after_rollback.rows, stored.rows);
}

async fn assert_domain_array_result_contract(connection: &dyn Connection, schema: &str, base_type: &str, levels: usize) {
    let domain_array = format!("{schema}.{base_type}[]");
    let sql = format!(
        "SELECT ARRAY[status, NULL]::{domain_array}, \
         pg_typeof(ARRAY[status, NULL]::{domain_array})::text \
         FROM {schema}.rows WHERE id = 1"
    );
    if levels <= 1024 {
        let projected = connection
            .query(&sql)
            .await
            .unwrap_or_else(|error| panic!("domain array projection failed at {levels} layers: {error:?}"));
        assert_eq!(projected.columns[0].data_type, domain_array);
        assert_eq!(
            projected.rows,
            vec![vec![
                Value::Text("{\"ready\",NULL}".into()),
                Value::Text(domain_array.clone()),
            ]]
        );
    } else {
        let error = connection
            .query(&sql)
            .await
            .expect_err(&format!("{levels}-layer enum array decoding must refuse explicitly"));
        assert!(
            matches!(&error, tablepro_core::DriverError::Unsupported(message) if message.contains("resolvable depth")),
            "unexpected {levels}-layer array outcome: {error:?}"
        );
    }
    let oracle = connection
        .query(&format!(
            "SELECT stored::text, expected::text, encode(array_send(stored), 'hex'), \
             encode(array_send(expected), 'hex'), pg_typeof(stored)::text \
             FROM (SELECT ARRAY[status, NULL]::{domain_array} AS stored, \
             ARRAY['ready', NULL]::{domain_array} AS expected \
             FROM {schema}.rows WHERE id = 1) AS arrays"
        ))
        .await
        .unwrap();
    assert_eq!(oracle.rows[0][0], Value::Text("{ready,NULL}".into()));
    assert_eq!(oracle.rows[0][0], oracle.rows[0][1]);
    assert_eq!(oracle.rows[0][2], oracle.rows[0][3]);
    assert_eq!(oracle.rows[0][4], Value::Text(domain_array));
}

async fn assert_deep_enum_array_parameter_contract(
    connection: &dyn Connection,
    schema: &str,
    base_type: &str,
    levels: usize,
) {
    let array_type = format!("{schema}.{base_type}[]");
    let stored = connection
        .query(&format!(
            "SELECT status::text, pg_typeof(status)::text, \
             encode(array_send(ARRAY[status, NULL]::{array_type}), 'hex') \
             FROM {schema}.rows WHERE id = 1"
        ))
        .await
        .unwrap();
    for parameter in [Value::Text(r#"{"ready","paused"}"#.into()), Value::Null] {
        let error = connection
            .query_params(
                &format!(
                    "SELECT pg_typeof(array_cat($1, ARRAY[status]))::text, \
                     encode(array_send(array_cat($1, ARRAY[status])), 'hex') \
                     FROM {schema}.rows WHERE id = 1"
                ),
                &[parameter],
            )
            .await
            .expect_err("deep inferred enum-array parameters must be refused explicitly");
        assert!(
            matches!(&error, tablepro_core::DriverError::Unsupported(message)
                if message.contains("resolvable depth")),
            "unexpected {levels}-level domain array outcome: {error:?}"
        );
    }
    let after = connection
        .query(&format!(
            "SELECT status::text, pg_typeof(status)::text, \
             encode(array_send(ARRAY[status, NULL]::{array_type}), 'hex') \
             FROM {schema}.rows WHERE id = 1"
        ))
        .await
        .unwrap();
    assert_eq!(after.rows, stored.rows, "{levels}-level stored value changed");
}
