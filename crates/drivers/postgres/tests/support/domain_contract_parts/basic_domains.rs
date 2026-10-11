#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_domain_over_enum_projection_preserves_labels_and_null() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE TYPE value_contract_domain_enum AS ENUM ('NULL', '東京')")
        .await
        .unwrap();
    connection
        .execute("CREATE DOMAIN value_contract_domain_enum_label AS value_contract_domain_enum")
        .await
        .unwrap();

    let result = connection
        .query(
            "SELECT label, pg_typeof(label)::text AS native_type FROM (VALUES \
             ('NULL'::value_contract_domain_enum_label), \
             ('東京'::value_contract_domain_enum_label), \
             (NULL::value_contract_domain_enum_label)) AS labels(label)",
        )
        .await
        .unwrap();

    assert_eq!(
        result.rows,
        vec![
            vec![
                Value::Text("NULL".into()),
                Value::Text("value_contract_domain_enum_label".into())
            ],
            vec![
                Value::Text("東京".into()),
                Value::Text("value_contract_domain_enum_label".into())
            ],
            vec![Value::Null, Value::Text("value_contract_domain_enum_label".into())],
        ]
    );

    let expected_json = serde_json::json!([
        {"label": "NULL", "native_type": "value_contract_domain_enum_label"},
        {"label": "東京", "native_type": "value_contract_domain_enum_label"},
        {"label": null, "native_type": "value_contract_domain_enum_label"}
    ]);
    let rendered = tablepro_core::export::render_json(&result.columns, &result.rows);
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&rendered).unwrap(),
        expected_json
    );

    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("domain-enum.json");
    tablepro_core::export::write_result_file(
        &path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Json,
            csv: &tablepro_core::export::CsvOptions::default(),
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap();
    let file_json: serde_json::Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(file_json, expected_json);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_domain_over_enum_array_preserves_labels_and_null() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE TYPE value_contract_domain_array_enum AS ENUM ('NULL', '', '東京', 'a,b', 'forbidden')")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE DOMAIN value_contract_domain_array_label AS value_contract_domain_array_enum \
             CHECK (VALUE <> 'forbidden'::value_contract_domain_array_enum)",
        )
        .await
        .unwrap();

    let result = connection
        .query(
            "SELECT labels, array_to_json(labels)::text AS native_values, pg_typeof(labels)::text AS native_type \
             FROM (VALUES (ARRAY['NULL'::value_contract_domain_array_label, \
             ''::value_contract_domain_array_label, '東京'::value_contract_domain_array_label, \
             'a,b'::value_contract_domain_array_label, NULL::value_contract_domain_array_label])) \
             AS arrays(labels)",
        )
        .await
        .unwrap();

    assert_eq!(
        result.rows,
        vec![vec![
            Value::Text("{\"NULL\",\"\",\"東京\",\"a,b\",NULL}".into()),
            Value::Text("[\"NULL\",\"\",\"東京\",\"a,b\",null]".into()),
            Value::Text("value_contract_domain_array_label[]".into()),
        ]]
    );

    let bound_array = connection
        .query_params(
            "SELECT $1::value_contract_domain_array_label[] AS labels, \
             array_to_json($1::value_contract_domain_array_label[])::text, \
             pg_typeof($1::value_contract_domain_array_label[])::text, \
             array_send($1::value_contract_domain_array_label[])",
            &[Value::Text(r#"{"NULL","","東京","a,b",NULL}"#.into())],
        )
        .await
        .unwrap();
    let native_array = connection
        .query(
            "SELECT labels, array_to_json(labels)::text, pg_typeof(labels)::text, array_send(labels) \
             FROM (SELECT ARRAY[\
                 'NULL'::value_contract_domain_array_label, \
                 ''::value_contract_domain_array_label, \
                 '東京'::value_contract_domain_array_label, \
                 'a,b'::value_contract_domain_array_label, \
                 NULL::value_contract_domain_array_label\
             ] AS labels) AS native",
        )
        .await
        .unwrap();
    assert_eq!(bound_array.rows, native_array.rows);

    let bounded_array = connection
        .query_params(
            "SELECT $1::value_contract_domain_array_label[] AS labels, \
             array_dims($1::value_contract_domain_array_label[])::text, \
             array_to_json($1::value_contract_domain_array_label[])::text, \
             pg_typeof($1::value_contract_domain_array_label[])::text, \
             array_lower($1::value_contract_domain_array_label[], 1), \
             array_upper($1::value_contract_domain_array_label[], 1), \
             array_lower($1::value_contract_domain_array_label[], 2), \
             array_upper($1::value_contract_domain_array_label[], 2)",
            &[Value::Text(r#"[0:1][3:4]={{"NULL",""},{"東京",NULL}}"#.into())],
        )
        .await
        .unwrap();
    assert_eq!(
        bounded_array.rows,
        vec![vec![
            Value::Text("[0:1][3:4]={{\"NULL\",\"\"},{\"東京\",NULL}}".into()),
            Value::Text("[0:1][3:4]".into()),
            Value::Text("[[\"NULL\",\"\"],[\"東京\",null]]".into()),
            Value::Text("value_contract_domain_array_label[]".into()),
            Value::Int(0),
            Value::Int(1),
            Value::Int(3),
            Value::Int(4),
        ]]
    );

    connection
        .execute(
            "CREATE TABLE value_contract_domain_array_import \
             (id integer PRIMARY KEY, labels value_contract_domain_array_label[])",
        )
        .await
        .unwrap();
    let source = connection
        .query(
            "SELECT 1 AS id, ARRAY[\
                 'NULL'::value_contract_domain_array_label, \
                 ''::value_contract_domain_array_label, \
                 '東京'::value_contract_domain_array_label, \
                 'a,b'::value_contract_domain_array_label, \
                 NULL::value_contract_domain_array_label\
             ] AS labels",
        )
        .await
        .unwrap();
    let csv_options = tablepro_core::export::CsvOptions::default();
    let csv = tablepro_core::export::render_csv(&source.columns, &source.rows, &csv_options);
    let import_options = tablepro_core::import::CsvImportOptions::default();
    let sheet = tablepro_core::import::read_csv(csv.as_bytes(), &import_options, None).unwrap();
    let columns = connection
        .fetch_columns(None, "value_contract_domain_array_import")
        .await
        .unwrap();
    assert_eq!(
        columns[1].enum_type,
        Some(tablepro_core::QualifiedTypeName {
            schema: "public".into(),
            name: "value_contract_domain_array_label".into(),
        })
    );
    let mapping = [Some(0), Some(1)];
    let plan = tablepro_core::import::build_insert_plan(
        &tablepro_core::import::ImportTarget {
            driver_id: "postgres",
            schema: None,
            table: "value_contract_domain_array_import",
            columns: &columns,
            mapping: &mapping,
        },
        &sheet,
        &import_options,
    )
    .unwrap();
    assert!(
        plan.statement
            .contains("$2::text::\"public\".\"value_contract_domain_array_label\"[]")
    );
    connection.execute_params(&plan.statement, &plan.rows[0]).await.unwrap();
    let imported = connection
        .query(
            "SELECT pg_typeof(labels)::text, array_to_json(labels)::text, \
                    encode(array_send(labels), 'hex') \
             FROM value_contract_domain_array_import",
        )
        .await
        .unwrap();
    let native = connection
        .query(
            "SELECT pg_typeof(labels)::text, array_to_json(labels)::text, \
                    encode(array_send(labels), 'hex') \
             FROM (SELECT ARRAY[\
                 'NULL'::value_contract_domain_array_label, \
                 ''::value_contract_domain_array_label, \
                 '東京'::value_contract_domain_array_label, \
                 'a,b'::value_contract_domain_array_label, \
                 NULL::value_contract_domain_array_label\
             ] AS labels) AS source",
        )
        .await
        .unwrap();
    assert_eq!(imported.rows, native.rows);

    let edited = r#"{"NULL","",東京,NULL}"#;
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "value_contract_domain_array_import",
        &columns,
        &[(1, Value::Text(edited.into()))],
        &[Value::Int(1)],
    )
    .unwrap();
    assert!(
        update
            .0
            .contains("$1::text::\"public\".\"value_contract_domain_array_label\"[]")
    );
    connection.execute_in_transaction(&[update]).await.unwrap();
    let grid_native = connection
        .query(
            "SELECT pg_typeof(labels)::text, array_to_json(labels)::text, \
                    encode(array_send(labels), 'hex') \
             FROM (SELECT ARRAY[\
                 'NULL'::value_contract_domain_array_label, \
                 ''::value_contract_domain_array_label, \
                 '東京'::value_contract_domain_array_label, \
                 NULL::value_contract_domain_array_label\
             ] AS labels) AS source",
        )
        .await
        .unwrap();
    let saved_grid = connection
        .query(
            "SELECT pg_typeof(labels)::text, array_to_json(labels)::text, \
                    encode(array_send(labels), 'hex') \
             FROM value_contract_domain_array_import",
        )
        .await
        .unwrap();
    assert_eq!(saved_grid.rows, grid_native.rows);

    let filters = FilterSet {
        rules: vec![FilterRule {
            column: "labels".into(),
            op: FilterOp::Eq,
            value: Some(FilterValue::Single(edited.into())),
        }],
        ..Default::default()
    };
    let (predicate, params) = tablepro_core::filter::build_filter_where("postgres", &columns, &filters)
        .unwrap()
        .unwrap();
    assert!(predicate.contains("$1::\"public\".\"value_contract_domain_array_label\"[]"));
    let filtered = connection
        .query_params(
            &format!(
                "SELECT id, pg_typeof(labels)::text, array_to_json(labels)::text, \
                        encode(array_send(labels), 'hex') \
                 FROM value_contract_domain_array_import WHERE {predicate}"
            ),
            &params,
        )
        .await
        .unwrap();
    assert_eq!(
        filtered.rows,
        vec![vec![
            Value::Int(1),
            grid_native.rows[0][0].clone(),
            grid_native.rows[0][1].clone(),
            grid_native.rows[0][2].clone()
        ]]
    );

    let invalid_grid = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "value_contract_domain_array_import",
        &columns,
        &[(1, Value::Text("{forbidden}".into()))],
        &[Value::Int(1)],
    )
    .unwrap();
    let error = connection.execute_in_transaction(&[invalid_grid]).await.unwrap_err();
    let cause = match &error {
        tablepro_core::DriverError::Transaction { source, .. }
        | tablepro_core::DriverError::TransactionRollbackFailed { source, .. } => source.as_ref(),
        other => other,
    };
    assert!(
        matches!(
            cause,
            tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "23514"
        ),
        "unexpected invalid grid edit error: {error:?}"
    );
    assert_eq!(
        connection
            .query(
                "SELECT pg_typeof(labels)::text, array_to_json(labels)::text, \
                        encode(array_send(labels), 'hex') \
                 FROM value_contract_domain_array_import",
            )
            .await
            .unwrap()
            .rows,
        grid_native.rows
    );

    let invalid_domain = tablepro_core::sql_dialect::build_insert_from_draft(
        "postgres",
        None,
        "value_contract_domain_array_import",
        &columns,
        &[Value::Int(2), Value::Text("{forbidden}".into())],
    )
    .unwrap();
    let error = connection
        .execute_params(&invalid_domain.0, &invalid_domain.1)
        .await
        .unwrap_err();
    assert!(matches!(
        error,
        tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "23514"
    ));
    assert_eq!(
        connection
            .query("SELECT count(*)::bigint FROM value_contract_domain_array_import")
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Int(1)]]
    );

    let invalid_array = connection
        .query_params(
            "SELECT $1::value_contract_domain_array_label[]",
            &[Value::Text(r#"{"NULL","not-a-label"}"#.into())],
        )
        .await
        .unwrap_err();
    assert!(matches!(
        invalid_array,
        tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "22P02"
    ));
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_domain_enum_array_csv_import_uses_target_type_under_shadowed_search_path() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection.execute("CREATE SCHEMA domain_array_shadow_a").await.unwrap();
    connection.execute("CREATE SCHEMA domain_array_shadow_b").await.unwrap();
    connection
        .execute("CREATE TYPE domain_array_shadow_a.status AS ENUM ('shadow')")
        .await
        .unwrap();
    connection
        .execute("CREATE TYPE domain_array_shadow_b.status AS ENUM ('target', 'sibling')")
        .await
        .unwrap();
    connection
        .execute("CREATE DOMAIN domain_array_shadow_a.label AS domain_array_shadow_a.status")
        .await
        .unwrap();
    connection
        .execute("CREATE DOMAIN domain_array_shadow_b.label AS domain_array_shadow_b.status")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE domain_array_shadow_b.target \
             (id integer PRIMARY KEY, labels domain_array_shadow_b.label[])",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO domain_array_shadow_b.target VALUES \
             (2, ARRAY['sibling'::domain_array_shadow_b.label])",
        )
        .await
        .unwrap();

    let source = connection
        .query("SELECT 1 AS id, ARRAY['target'::domain_array_shadow_b.label] AS labels")
        .await
        .unwrap();
    let csv = tablepro_core::export::render_csv(
        &source.columns,
        &source.rows,
        &tablepro_core::export::CsvOptions::default(),
    );
    let import_options = tablepro_core::import::CsvImportOptions::default();
    let sheet = tablepro_core::import::read_csv(csv.as_bytes(), &import_options, None).unwrap();
    let columns = connection
        .fetch_columns(Some("domain_array_shadow_b"), "target")
        .await
        .unwrap();
    assert_eq!(
        columns[1].enum_type,
        Some(tablepro_core::QualifiedTypeName {
            schema: "domain_array_shadow_b".into(),
            name: "label".into(),
        })
    );
    let mapping = [Some(0), Some(1)];
    let plan = tablepro_core::import::build_insert_plan(
        &tablepro_core::import::ImportTarget {
            driver_id: "postgres",
            schema: Some("domain_array_shadow_b"),
            table: "target",
            columns: &columns,
            mapping: &mapping,
        },
        &sheet,
        &import_options,
    )
    .unwrap();
    assert!(
        plan.statement
            .contains("$2::text::\"domain_array_shadow_b\".\"label\"[]")
    );

    let mut transaction = connection.begin().await.unwrap();
    transaction
        .execute("SET LOCAL search_path TO domain_array_shadow_a, public")
        .await
        .unwrap();
    assert_eq!(
        transaction.query("SELECT current_schema()::text").await.unwrap().rows,
        vec![vec![Value::Text("domain_array_shadow_a".into())]]
    );
    transaction
        .execute_params(&plan.statement, &plan.rows[0])
        .await
        .unwrap();
    let restored = transaction
        .query(
            "SELECT id, pg_typeof(labels)::text, labels::text, array_to_json(labels)::text, \
                    encode(array_send(labels), 'hex') \
             FROM domain_array_shadow_b.target ORDER BY id",
        )
        .await
        .unwrap();
    let native = transaction
        .query(
            "SELECT 1, pg_typeof(labels)::text, labels::text, array_to_json(labels)::text, \
                    encode(array_send(labels), 'hex') \
             FROM (SELECT ARRAY['target'::domain_array_shadow_b.label] AS labels) AS source \
             UNION ALL \
             SELECT 2, pg_typeof(labels)::text, labels::text, array_to_json(labels)::text, \
                    encode(array_send(labels), 'hex') \
             FROM (SELECT ARRAY['sibling'::domain_array_shadow_b.label] AS labels) AS source \
             ORDER BY 1",
        )
        .await
        .unwrap();
    assert_eq!(restored.rows, native.rows);
    transaction.commit().await.unwrap();
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_domain_over_enum_parameters_preserve_native_type() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE TYPE value_contract_domain_param_enum AS ENUM ('NULL', '東京', 'ready')")
        .await
        .unwrap();
    connection
        .execute("CREATE DOMAIN value_contract_domain_param_label AS value_contract_domain_param_enum")
        .await
        .unwrap();
    connection
        .execute("CREATE TABLE value_contract_domain_param_rows (id INT PRIMARY KEY, label value_contract_domain_param_label)")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO value_contract_domain_param_rows VALUES (1, 'NULL'), (2, NULL), (3, '東京')")
        .await
        .unwrap();

    let matched = connection
        .query_params(
            "SELECT $1::value_contract_domain_param_label::text, \
             pg_typeof($1::value_contract_domain_param_label)::text",
            &[Value::Text("NULL".into())],
        )
        .await
        .unwrap();
    assert_eq!(
        matched.rows,
        vec![vec![
            Value::Text("NULL".into()),
            Value::Text("value_contract_domain_param_label".into()),
        ]]
    );

    let bound_null = connection
        .query_params(
            "SELECT $1::value_contract_domain_param_label, \
             pg_typeof($1::value_contract_domain_param_label)::text",
            &[Value::Null],
        )
        .await
        .unwrap();
    assert_eq!(
        bound_null.rows,
        vec![vec![
            Value::Null,
            Value::Text("value_contract_domain_param_label".into())
        ]]
    );

    let updated = connection
        .execute_params(
            "UPDATE value_contract_domain_param_rows SET label = $1::value_contract_domain_param_label WHERE id = 3",
            &[Value::Text("ready".into())],
        )
        .await
        .unwrap();
    assert_eq!(updated.rows_affected, 1);
    let stored = connection
        .query("SELECT label::text, pg_typeof(label)::text FROM value_contract_domain_param_rows WHERE id = 3")
        .await
        .unwrap();
    assert_eq!(
        stored.rows,
        vec![vec![
            Value::Text("ready".into()),
            Value::Text("value_contract_domain_param_label".into()),
        ]]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_domain_over_enum_assignment_infers_parameter_type() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE SCHEMA value_contract_domain_infer")
        .await
        .unwrap();
    connection
        .execute("CREATE TYPE value_contract_domain_infer.state AS ENUM ('NULL', '東京', 'ready')")
        .await
        .unwrap();
    connection
        .execute("CREATE DOMAIN value_contract_domain_infer.state_domain AS value_contract_domain_infer.state")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE value_contract_domain_infer.rows \
             (id INT PRIMARY KEY, status value_contract_domain_infer.state_domain)",
        )
        .await
        .unwrap();
    connection
        .execute("INSERT INTO value_contract_domain_infer.rows VALUES (1, 'NULL'), (2, '東京')")
        .await
        .unwrap();

    let updated = connection
        .execute_params(
            "UPDATE value_contract_domain_infer.rows SET status = $1 WHERE id = 2",
            &[Value::Text("ready".into())],
        )
        .await
        .unwrap();
    assert_eq!(updated.rows_affected, 1);
    let stored = connection
        .query(
            "SELECT id, status::text, pg_typeof(status)::text \
             FROM value_contract_domain_infer.rows WHERE id = 2",
        )
        .await
        .unwrap();
    assert_eq!(
        stored.rows,
        vec![vec![
            Value::Int(2),
            Value::Text("ready".into()),
            Value::Text("value_contract_domain_infer.state_domain".into()),
        ]]
    );

    let nulled = connection
        .execute_params(
            "UPDATE value_contract_domain_infer.rows SET status = $1 WHERE id = 2",
            &[Value::Null],
        )
        .await
        .unwrap();
    assert_eq!(nulled.rows_affected, 1);
    let stored_null = connection
        .query(
            "SELECT id, status::text, pg_typeof(status)::text \
             FROM value_contract_domain_infer.rows WHERE id = 2",
        )
        .await
        .unwrap();
    assert_eq!(
        stored_null.rows,
        vec![vec![
            Value::Int(2),
            Value::Null,
            Value::Text("value_contract_domain_infer.state_domain".into()),
        ]]
    );
    let sibling = connection
        .query(
            "SELECT id, status::text, pg_typeof(status)::text \
             FROM value_contract_domain_infer.rows WHERE id = 1",
        )
        .await
        .unwrap();
    assert_eq!(
        sibling.rows,
        vec![vec![
            Value::Int(1),
            Value::Text("NULL".into()),
            Value::Text("value_contract_domain_infer.state_domain".into()),
        ]]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_domain_over_enum_nullif_infers_parameter_type() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE SCHEMA value_contract_domain_nullif")
        .await
        .unwrap();
    connection
        .execute("CREATE SCHEMA value_contract_domain_nullif_shadow")
        .await
        .unwrap();
    connection
        .execute("CREATE TYPE value_contract_domain_nullif.state AS ENUM ('ready', 'paused', 'NULL')")
        .await
        .unwrap();
    connection
        .execute("CREATE TYPE value_contract_domain_nullif_shadow.state AS ENUM ('shadow')")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE DOMAIN value_contract_domain_nullif.state_domain \
             AS value_contract_domain_nullif.state",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE value_contract_domain_nullif.rows \
             (id INT PRIMARY KEY, status value_contract_domain_nullif.state_domain)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO value_contract_domain_nullif.rows VALUES \
             (1, 'ready'), (2, 'paused'), (3, NULL)",
        )
        .await
        .unwrap();
    connection
        .execute("SET search_path TO value_contract_domain_nullif_shadow, public")
        .await
        .unwrap();

    let enum_type = "value_contract_domain_nullif.state";
    let domain_type = "value_contract_domain_nullif.state_domain";
    let raw_domain_parameter = connection
        .query_params(
            "SELECT NULLIF(status, $1) FROM value_contract_domain_nullif.rows WHERE id = 1",
            &[Value::Text("ready".into())],
        )
        .await
        .expect_err("raw domain-to-unknown NULLIF must retain PostgreSQL's refusal");
    assert!(
        matches!(&raw_domain_parameter, tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "42883"),
        "expected native domain operator SQLSTATE 42883, got {raw_domain_parameter:?}"
    );

    for (parameter, expected) in [
        (
            Value::Text("ready".into()),
            [Value::Null, Value::Text("paused".into()), Value::Null],
        ),
        (
            Value::Text("NULL".into()),
            [Value::Text("ready".into()), Value::Text("paused".into()), Value::Null],
        ),
        (
            Value::Null,
            [Value::Text("ready".into()), Value::Text("paused".into()), Value::Null],
        ),
    ] {
        let result = connection
            .query_params(
                "SELECT id, NULLIF(status::value_contract_domain_nullif.state, $1)::text, \
                        pg_typeof(NULLIF(status::value_contract_domain_nullif.state, $1))::text, \
                        pg_typeof($1)::text, \
                        pg_typeof(status)::text \
                 FROM value_contract_domain_nullif.rows ORDER BY id",
                std::slice::from_ref(&parameter),
            )
            .await
            .unwrap();
        assert_eq!(
            result.rows,
            expected
                .into_iter()
                .enumerate()
                .map(|(index, value)| vec![
                    Value::Int(index as i64 + 1),
                    value,
                    Value::Text(enum_type.into()),
                    Value::Text(enum_type.into()),
                    Value::Text(domain_type.into()),
                ])
                .collect::<Vec<_>>(),
            "NULLIF parameter {parameter:?}"
        );
    }

    let invalid = connection
        .query_params(
            "SELECT NULLIF(status::value_contract_domain_nullif.state, $1) \
             FROM value_contract_domain_nullif.rows WHERE id = 1",
            &[Value::Text("not-a-label".into())],
        )
        .await
        .expect_err("invalid enum label must reach PostgreSQL validation");
    assert!(
        matches!(&invalid, tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "22P02"),
        "expected native enum SQLSTATE 22P02, got {invalid:?}"
    );

    let unchanged = connection
        .query(
            "SELECT id, status::text, pg_typeof(status)::text \
             FROM value_contract_domain_nullif.rows ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(
        unchanged.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("ready".into()),
                Value::Text(domain_type.into())
            ],
            vec![
                Value::Int(2),
                Value::Text("paused".into()),
                Value::Text(domain_type.into())
            ],
            vec![Value::Int(3), Value::Null, Value::Text(domain_type.into())],
        ]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_domain_over_enum_query_comparison_infers_parameter_type() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE SCHEMA value_contract_domain_query")
        .await
        .unwrap();
    connection
        .execute("CREATE TYPE value_contract_domain_query.state AS ENUM ('ready', 'paused')")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE DOMAIN value_contract_domain_query.state_domain \
             AS value_contract_domain_query.state",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE value_contract_domain_query.rows \
             (id INT PRIMARY KEY, status value_contract_domain_query.state_domain)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO value_contract_domain_query.rows VALUES \
             (1, 'ready'), (2, 'paused'), (3, NULL)",
        )
        .await
        .unwrap();

    let uncast = connection
        .query_params(
            "SELECT id, status = $1, pg_typeof($1)::text, pg_typeof(status)::text \
             FROM value_contract_domain_query.rows ORDER BY id",
            &[Value::Text("ready".into())],
        )
        .await
        .expect_err("raw domain equality has no domain-to-unknown operator");
    assert!(matches!(
        uncast,
        tablepro_core::DriverError::Query {
            sqlstate: Some(code), ..
        } if code == "42883"
    ));

    let result = connection
        .query_params(
            "SELECT id, status::value_contract_domain_query.state = $1, \
             pg_typeof($1)::text, pg_typeof(status)::text \
             FROM value_contract_domain_query.rows ORDER BY id",
            &[Value::Text("ready".into())],
        )
        .await
        .unwrap();
    assert_eq!(
        result.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Bool(true),
                Value::Text("value_contract_domain_query.state".into()),
                Value::Text("value_contract_domain_query.state_domain".into()),
            ],
            vec![
                Value::Int(2),
                Value::Bool(false),
                Value::Text("value_contract_domain_query.state".into()),
                Value::Text("value_contract_domain_query.state_domain".into()),
            ],
            vec![
                Value::Int(3),
                Value::Null,
                Value::Text("value_contract_domain_query.state".into()),
                Value::Text("value_contract_domain_query.state_domain".into()),
            ],
        ]
    );

    let not_equal = connection
        .query_params(
            "SELECT id, status::value_contract_domain_query.state <> $1, \
             pg_typeof($1)::text, pg_typeof(status)::text \
             FROM value_contract_domain_query.rows ORDER BY id",
            &[Value::Text("paused".into())],
        )
        .await
        .unwrap();
    assert_eq!(
        not_equal.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Bool(true),
                Value::Text("value_contract_domain_query.state".into()),
                Value::Text("value_contract_domain_query.state_domain".into()),
            ],
            vec![
                Value::Int(2),
                Value::Bool(false),
                Value::Text("value_contract_domain_query.state".into()),
                Value::Text("value_contract_domain_query.state_domain".into()),
            ],
            vec![
                Value::Int(3),
                Value::Null,
                Value::Text("value_contract_domain_query.state".into()),
                Value::Text("value_contract_domain_query.state_domain".into()),
            ],
        ]
    );

    for (operator, parameter, expected) in [
        (
            "IS DISTINCT FROM",
            Value::Text("ready".into()),
            [Some(false), Some(true), Some(true)],
        ),
        (
            "IS NOT DISTINCT FROM",
            Value::Text("ready".into()),
            [Some(true), Some(false), Some(false)],
        ),
        ("IS DISTINCT FROM", Value::Null, [Some(true), Some(true), Some(false)]),
        (
            "IS NOT DISTINCT FROM",
            Value::Null,
            [Some(false), Some(false), Some(true)],
        ),
    ] {
        let result = connection
            .query_params(
                &format!(
                    "SELECT id, status::value_contract_domain_query.state {operator} $1, \
                     pg_typeof($1)::text, pg_typeof(status)::text \
                     FROM value_contract_domain_query.rows ORDER BY id"
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
                    Value::Bool(comparison.unwrap()),
                    Value::Text("value_contract_domain_query.state".into()),
                    Value::Text("value_contract_domain_query.state_domain".into()),
                ]
            })
            .collect::<Vec<_>>();
        assert_eq!(result.rows, expected, "operator {operator}, parameter {parameter:?}");
    }

    for (operator, parameter, expected) in [
        ("<", "paused", [Some(true), Some(false), None]),
        ("<=", "paused", [Some(true), Some(true), None]),
        (">", "ready", [Some(false), Some(true), None]),
        (">=", "ready", [Some(true), Some(true), None]),
    ] {
        let result = connection
            .query_params(
                &format!(
                    "SELECT id, status::value_contract_domain_query.state {operator} $1, \
                     pg_typeof($1)::text, pg_typeof(status)::text \
                     FROM value_contract_domain_query.rows ORDER BY id"
                ),
                &[Value::Text(parameter.into())],
            )
            .await
            .unwrap();
        let expected = expected
            .into_iter()
            .enumerate()
            .map(|(index, comparison)| {
                vec![
                    Value::Int(index as i64 + 1),
                    comparison.map_or(Value::Null, Value::Bool),
                    Value::Text("value_contract_domain_query.state".into()),
                    Value::Text("value_contract_domain_query.state_domain".into()),
                ]
            })
            .collect::<Vec<_>>();
        assert_eq!(result.rows, expected, "operator {operator}");
    }

    for (operator, expected) in [
        ("IN", [Some(true), Some(true), None]),
        ("NOT IN", [Some(false), Some(false), None]),
    ] {
        let result = connection
            .query_params(
                &format!(
                    "SELECT id, status::value_contract_domain_query.state {operator} ($1, $2), \
                     pg_typeof($1)::text, pg_typeof($2)::text, pg_typeof(status)::text \
                     FROM value_contract_domain_query.rows ORDER BY id"
                ),
                &[Value::Text("ready".into()), Value::Text("paused".into())],
            )
            .await
            .unwrap();
        let expected = expected
            .into_iter()
            .enumerate()
            .map(|(index, comparison)| {
                vec![
                    Value::Int(index as i64 + 1),
                    comparison.map_or(Value::Null, Value::Bool),
                    Value::Text("value_contract_domain_query.state".into()),
                    Value::Text("value_contract_domain_query.state".into()),
                    Value::Text("value_contract_domain_query.state_domain".into()),
                ]
            })
            .collect::<Vec<_>>();
        assert_eq!(result.rows, expected, "operator {operator}");
    }

    let between = connection
        .query_params(
            "SELECT id, status::value_contract_domain_query.state BETWEEN $1 AND $2, \
             pg_typeof($1)::text, pg_typeof($2)::text, pg_typeof(status)::text \
             FROM value_contract_domain_query.rows ORDER BY id",
            &[Value::Text("ready".into()), Value::Text("paused".into())],
        )
        .await
        .unwrap();
    assert_eq!(
        between.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Bool(true),
                Value::Text("value_contract_domain_query.state".into()),
                Value::Text("value_contract_domain_query.state".into()),
                Value::Text("value_contract_domain_query.state_domain".into()),
            ],
            vec![
                Value::Int(2),
                Value::Bool(true),
                Value::Text("value_contract_domain_query.state".into()),
                Value::Text("value_contract_domain_query.state".into()),
                Value::Text("value_contract_domain_query.state_domain".into()),
            ],
            vec![
                Value::Int(3),
                Value::Null,
                Value::Text("value_contract_domain_query.state".into()),
                Value::Text("value_contract_domain_query.state".into()),
                Value::Text("value_contract_domain_query.state_domain".into()),
            ],
        ]
    );

    let null_result = connection
        .query_params(
            "SELECT status::value_contract_domain_query.state = $1, \
             pg_typeof($1)::text, pg_typeof(status)::text \
             FROM value_contract_domain_query.rows WHERE id = 1",
            &[Value::Null],
        )
        .await
        .unwrap();
    assert_eq!(
        null_result.rows,
        vec![vec![
            Value::Null,
            Value::Text("value_contract_domain_query.state".into()),
            Value::Text("value_contract_domain_query.state_domain".into()),
        ]]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_domain_over_enum_coalesce_infers_parameter_type() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection.execute("CREATE SCHEMA value_contract_domain_coalesce").await.unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_domain_coalesce.state \
             AS ENUM ('ready', 'paused', 'NULL', '')",
        )
        .await
        .unwrap();
    connection.execute("CREATE SCHEMA value_contract_domain_coalesce_shadow").await.unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_domain_coalesce_shadow.state \
             AS ENUM ('ready', 'shadow-only')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE DOMAIN value_contract_domain_coalesce.state_domain \
             AS value_contract_domain_coalesce.state",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE value_contract_domain_coalesce.rows \
             (id INT PRIMARY KEY, status value_contract_domain_coalesce.state_domain)",
        )
        .await
        .unwrap();
    connection
        .execute("INSERT INTO value_contract_domain_coalesce.rows VALUES (1, 'ready'), (2, 'paused'), (3, NULL)")
        .await
        .unwrap();

    for (expression, text_values, null_values) in [
        (
            "COALESCE(status, $1)",
            ["ready", "paused", "paused"],
            [Some("ready"), Some("paused"), None],
        ),
        (
            "COALESCE($1, status)",
            ["paused", "paused", "paused"],
            [Some("ready"), Some("paused"), None],
        ),
    ] {
        for (parameter, expected) in [
            (
                Value::Text("paused".into()),
                text_values.map(|value| Some(value.to_owned())),
            ),
            (Value::Null, null_values.map(|value| value.map(str::to_owned))),
        ] {
            let result = connection
                .query_params(
                    &format!(
                        "SELECT id, {expression}::text, pg_typeof($1)::text, \
                         pg_typeof({expression})::text, pg_typeof(status)::text \
                         FROM value_contract_domain_coalesce.rows ORDER BY id"
                    ),
                    std::slice::from_ref(&parameter),
                )
                .await
                .unwrap();
            assert_eq!(
                result.rows,
                expected
                    .into_iter()
                    .enumerate()
                    .map(|(index, value)| vec![
                        Value::Int(index as i64 + 1),
                        value.map_or(Value::Null, Value::Text),
                        Value::Text("value_contract_domain_coalesce.state".into()),
                        Value::Text("value_contract_domain_coalesce.state".into()),
                        Value::Text("value_contract_domain_coalesce.state_domain".into()),
                    ])
                    .collect::<Vec<_>>(),
                "{expression} with parameter {parameter:?}"
            );
        }
    }

    let mut transaction = connection.begin().await.unwrap();
    transaction
        .execute("SET LOCAL search_path TO value_contract_domain_coalesce_shadow, public")
        .await
        .unwrap();
    for (parameter, native_parameter) in [
        (Value::Text("NULL".into()), "'NULL'"),
        (Value::Text(String::new()), "''"),
        (Value::Null, "NULL"),
    ] {
        let native = transaction
            .query(&format!(
                "SELECT id, \
                 CASE WHEN id = 1 THEN {native_parameter}::value_contract_domain_coalesce.state \
                      ELSE status END::text, \
                 pg_typeof(CASE WHEN id = 1 THEN {native_parameter}::value_contract_domain_coalesce.state \
                                ELSE status END)::text, \
                 CASE WHEN id = 1 THEN status \
                      ELSE {native_parameter}::value_contract_domain_coalesce.state END::text, \
                 pg_typeof(CASE WHEN id = 1 THEN status \
                                ELSE {native_parameter}::value_contract_domain_coalesce.state END)::text, \
                 pg_typeof(status)::text \
                 FROM value_contract_domain_coalesce.rows ORDER BY id"
            ))
            .await
            .unwrap();
        let inferred = transaction
            .query_params(
                "SELECT id, \
                 CASE WHEN id = 1 THEN $1 ELSE status END::text, \
                 pg_typeof($1)::text, \
                 pg_typeof(CASE WHEN id = 1 THEN $1 ELSE status END)::text, \
                 CASE WHEN id = 1 THEN status ELSE $1 END::text, \
                 pg_typeof(CASE WHEN id = 1 THEN status ELSE $1 END)::text, \
                 pg_typeof(status)::text \
                 FROM value_contract_domain_coalesce.rows ORDER BY id",
                std::slice::from_ref(&parameter),
            )
            .await
            .unwrap();
        let expected = native
            .rows
            .into_iter()
            .map(|row| {
                vec![
                    row[0].clone(),
                    row[1].clone(),
                    Value::Text("value_contract_domain_coalesce.state".into()),
                    row[2].clone(),
                    row[3].clone(),
                    row[4].clone(),
                    row[5].clone(),
                ]
            })
            .collect::<Vec<_>>();
        assert_eq!(inferred.rows, expected, "domain CASE with {parameter:?}");

        for (native_expression, inferred_expression) in [
            (
                format!(
                    "COALESCE(status, {native_parameter}::value_contract_domain_coalesce.state)"
                ),
                "COALESCE(status, $1)",
            ),
            (
                format!(
                    "COALESCE({native_parameter}::value_contract_domain_coalesce.state, status)"
                ),
                "COALESCE($1, status)",
            ),
        ] {
            let native = transaction
                .query(&format!(
                    "SELECT id, {native_expression}::text, \
                     pg_typeof({native_expression})::text, pg_typeof(status)::text \
                     FROM value_contract_domain_coalesce.rows ORDER BY id"
                ))
                .await
                .unwrap();
            let inferred = transaction
                .query_params(
                    &format!(
                        "SELECT id, {inferred_expression}::text, pg_typeof($1)::text, \
                         pg_typeof({inferred_expression})::text, pg_typeof(status)::text \
                         FROM value_contract_domain_coalesce.rows ORDER BY id"
                    ),
                    std::slice::from_ref(&parameter),
                )
                .await
                .unwrap();
            let expected = native
                .rows
                .into_iter()
                .map(|row| {
                    vec![
                        row[0].clone(),
                        row[1].clone(),
                        Value::Text("value_contract_domain_coalesce.state".into()),
                        row[2].clone(),
                        row[3].clone(),
                    ]
                })
                .collect::<Vec<_>>();
            assert_eq!(
                inferred.rows, expected,
                "domain {inferred_expression} with {parameter:?}"
            );
        }
    }

    for expression in [
        "CASE WHEN id = 1 THEN $1 ELSE status END",
        "CASE WHEN id = 1 THEN status ELSE $1 END",
        "COALESCE(status, $1)",
        "COALESCE($1, status)",
    ] {
        transaction.execute("SAVEPOINT invalid_domain_case").await.unwrap();
        let invalid = transaction
            .query_params(
                &format!(
                    "SELECT {expression} FROM value_contract_domain_coalesce.rows ORDER BY id"
                ),
                &[Value::Text("shadow-only".into())],
            )
            .await
            .expect_err("parameter must resolve against the target enum, not its shadow");
        assert!(
            matches!(&invalid, tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "22P02"),
            "expected target enum invalid-label SQLSTATE 22P02, got {invalid:?}"
        );
        transaction.execute("ROLLBACK TO SAVEPOINT invalid_domain_case").await.unwrap();
    }
    let unchanged = transaction
        .query(
            "SELECT id, status::text, pg_typeof(status)::text \
             FROM value_contract_domain_coalesce.rows ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(
        unchanged.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("ready".into()),
                Value::Text("value_contract_domain_coalesce.state_domain".into()),
            ],
            vec![
                Value::Int(2),
                Value::Text("paused".into()),
                Value::Text("value_contract_domain_coalesce.state_domain".into()),
            ],
            vec![
                Value::Int(3),
                Value::Null,
                Value::Text("value_contract_domain_coalesce.state_domain".into()),
            ],
        ]
    );
}
