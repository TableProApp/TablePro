#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_scalar_enum_labels_preserve_exact_text() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE TYPE value_contract_label AS ENUM ('NULL', '東京', 'o''brien')")
        .await
        .unwrap();

    let result = connection
        .query(
            "SELECT label::text AS enum_value, pg_typeof(label)::text AS native_type \
             FROM (VALUES \
             ('NULL'::value_contract_label), \
             ('東京'::value_contract_label), ('o''brien'::value_contract_label)) AS labels(label)",
        )
        .await
        .unwrap();
    let expected = ["NULL", "東京", "o'brien"];
    assert_eq!(
        result.rows.len(),
        expected.len(),
        "the enum text query must return every source row"
    );
    for (row, expected) in result.rows.iter().zip(expected) {
        assert_eq!(
            row,
            &[Value::Text(expected.into()), Value::Text("value_contract_label".into())]
        );
    }
    let null = connection
        .query("SELECT NULL::value_contract_label::text AS label, NULL::text AS oracle")
        .await
        .unwrap();
    assert_eq!(null.rows, vec![vec![Value::Null, Value::Null]]);

    let direct_projection = connection
        .query(
            "SELECT label, pg_typeof(label)::text AS native_type FROM (VALUES \
             ('NULL'::value_contract_label), ('東京'::value_contract_label), \
             ('o''brien'::value_contract_label), (NULL::value_contract_label)) AS labels(label)",
        )
        .await
        .unwrap();
    assert_eq!(
        direct_projection.rows,
        vec![
            vec![Value::Text("NULL".into()), Value::Text("value_contract_label".into())],
            vec![Value::Text("東京".into()), Value::Text("value_contract_label".into())],
            vec![
                Value::Text("o'brien".into()),
                Value::Text("value_contract_label".into())
            ],
            vec![Value::Null, Value::Text("value_contract_label".into())],
        ]
    );

    connection
        .execute("CREATE TABLE value_contract_enum_null_write (id INT PRIMARY KEY, label value_contract_label)")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO value_contract_enum_null_write VALUES (1, '東京')")
        .await
        .unwrap();
    connection
        .execute("CREATE TABLE value_contract_enum_null_write_effects (id INT NOT NULL)")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE FUNCTION value_contract_enum_null_write_effect() RETURNS trigger \
             LANGUAGE plpgsql AS $$ BEGIN INSERT INTO value_contract_enum_null_write_effects VALUES (NEW.id); \
             RETURN NEW; END $$",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TRIGGER value_contract_enum_null_write_trigger BEFORE UPDATE \
             ON value_contract_enum_null_write FOR EACH ROW \
             EXECUTE FUNCTION value_contract_enum_null_write_effect()",
        )
        .await
        .unwrap();
    let update_returning = connection
        .query("UPDATE value_contract_enum_null_write SET label = 'NULL' WHERE id = 1 RETURNING label")
        .await
        .unwrap();
    assert_eq!(update_returning.rows, vec![vec![Value::Text("NULL".into())]]);
    let stored = connection
        .query("SELECT label::text, pg_typeof(label)::text FROM value_contract_enum_null_write WHERE id = 1")
        .await
        .unwrap();
    assert_eq!(
        stored.rows,
        vec![vec![
            Value::Text("NULL".into()),
            Value::Text("value_contract_label".into()),
        ]]
    );
    let effects = connection
        .query("SELECT count(*)::bigint FROM value_contract_enum_null_write_effects")
        .await
        .unwrap();
    assert_eq!(effects.rows, vec![vec![Value::Int(1)]]);

    for value in ["NULL", "東京", "o'brien"] {
        let input = Value::Text(value.into());
        let literal = tablepro_core::sql_literal::render_sql_literal("postgres", &input).unwrap();
        let literal_result = connection
            .query(&format!("SELECT {literal}::value_contract_label::text"))
            .await
            .unwrap();
        assert_eq!(literal_result.rows, vec![vec![Value::Text(value.into())]]);

        let bound_result = connection
            .query_params(
                "SELECT $1::value_contract_label AS label, \
                 pg_typeof($1::value_contract_label)::text AS native_type",
                std::slice::from_ref(&input),
            )
            .await
            .unwrap();
        assert_eq!(
            bound_result.rows,
            vec![vec![
                Value::Text(value.into()),
                Value::Text("value_contract_label".into())
            ]]
        );
    }
    let bound_null = connection
        .query_params(
            "SELECT $1::value_contract_label AS label, \
             pg_typeof($1::value_contract_label)::text AS native_type",
            &[Value::Null],
        )
        .await
        .unwrap();
    assert_eq!(
        bound_null.rows,
        vec![vec![Value::Null, Value::Text("value_contract_label".into())]]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_custom_enum_preserves_maximum_multibyte_label_bytes() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    let labels = ["x".repeat(63), "界".repeat(21)];
    let literals = labels
        .iter()
        .map(|label| tablepro_core::sql_literal::render_sql_literal("postgres", &Value::Text(label.clone())).unwrap())
        .collect::<Vec<_>>();
    connection
        .execute(&format!(
            "CREATE TYPE value_contract_enum_byte_boundary AS ENUM ({})",
            literals.join(", ")
        ))
        .await
        .unwrap();

    let catalog = connection
        .query(
            "SELECT enumlabel::text, octet_length(enumlabel::text) \
             FROM pg_enum \
             WHERE enumtypid = 'value_contract_enum_byte_boundary'::regtype \
             ORDER BY enumsortorder",
        )
        .await
        .unwrap();
    assert_eq!(
        catalog.rows,
        labels
            .iter()
            .map(|label| vec![Value::Text(label.clone()), Value::Int(63)])
            .collect::<Vec<_>>()
    );

    let result = connection
        .query(
            "SELECT value, pg_typeof(value)::text \
             FROM unnest(enum_range(NULL::value_contract_enum_byte_boundary)) \
             WITH ORDINALITY AS labels(value, ordinal) \
             ORDER BY ordinal",
        )
        .await
        .unwrap();
    assert_eq!(result.columns[0].data_type, "value_contract_enum_byte_boundary");
    assert_eq!(
        result.rows,
        labels
            .iter()
            .map(|label| vec![
                Value::Text(label.clone()),
                Value::Text("value_contract_enum_byte_boundary".into())
            ])
            .collect::<Vec<_>>()
    );

    let expression = format!("ARRAY[{}::value_contract_enum_byte_boundary, NULL]", literals[1]);
    let array_result = connection
        .query(&format!("SELECT {expression} AS value"))
        .await
        .unwrap();
    let array_oracle = connection
        .query(&format!(
            "SELECT {expression}::text, pg_typeof({expression})::text, \
                    array_to_json({expression})::text, encode(array_send({expression}), 'hex')"
        ))
        .await
        .unwrap();
    assert_eq!(array_result.columns[0].data_type, "value_contract_enum_byte_boundary[]");
    assert_eq!(
        array_result.rows[0][0],
        Value::Text(format!("{{\"{}\",NULL}}", labels[1]))
    );
    assert_eq!(array_oracle.rows[0][0], Value::Text(format!("{{{},NULL}}", labels[1])));
    assert_eq!(
        array_oracle.rows[0][1],
        Value::Text("value_contract_enum_byte_boundary[]".into())
    );
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(match &array_oracle.rows[0][2] {
            Value::Text(json) => json,
            other => panic!("native array_to_json result: {other:?}"),
        })
        .unwrap(),
        serde_json::json!([labels[1], null])
    );
    let array_round_trip = connection
        .query_params(
            "SELECT encode(array_send($1::text::value_contract_enum_byte_boundary[]), 'hex')",
            std::slice::from_ref(&array_result.rows[0][0]),
        )
        .await
        .unwrap();
    assert_eq!(array_round_trip.rows[0][0], array_oracle.rows[0][3]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_custom_enum_refuses_labels_over_byte_limit() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    let label = "x".repeat(64);
    let literal = tablepro_core::sql_literal::render_sql_literal("postgres", &Value::Text(label)).unwrap();
    let error = connection
        .execute(&format!(
            "CREATE TYPE value_contract_enum_overlength AS ENUM ({literal})"
        ))
        .await
        .expect_err("PostgreSQL must refuse an enum label over the byte limit");
    assert!(
        matches!(&error, tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "42602"),
        "{error:?}"
    );
    let type_absent = connection
        .query("SELECT to_regtype('value_contract_enum_overlength') IS NULL")
        .await
        .unwrap();
    assert_eq!(type_absent.rows, vec![vec![Value::Bool(true)]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_custom_enum_order_uses_declared_catalog_order() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE TYPE value_contract_enum_order AS ENUM ('zulu', 'alpha', 'middle')")
        .await
        .unwrap();
    let catalog = connection
        .query(
            "SELECT enumlabel::text FROM pg_enum \
             WHERE enumtypid = 'value_contract_enum_order'::regtype \
             ORDER BY enumsortorder",
        )
        .await
        .unwrap();
    assert_eq!(
        catalog.rows,
        ["zulu", "alpha", "middle"].map(|label| vec![Value::Text(label.into())])
    );

    let result = connection
        .query(
            "SELECT label, pg_typeof(label)::text FROM (VALUES \
             ('middle'::value_contract_enum_order), \
             ('zulu'::value_contract_enum_order), \
             (NULL::value_contract_enum_order), \
             ('alpha'::value_contract_enum_order), \
             ('zulu'::value_contract_enum_order)) AS rows(label) \
             ORDER BY label NULLS LAST",
        )
        .await
        .unwrap();
    assert_eq!(result.columns[0].data_type, "value_contract_enum_order");
    assert_eq!(
        result.rows,
        ["zulu", "zulu", "alpha", "middle"]
            .map(|label| vec![
                Value::Text(label.into()),
                Value::Text("value_contract_enum_order".into())
            ])
            .into_iter()
            .chain([vec![Value::Null, Value::Text("value_contract_enum_order".into()),]])
            .collect::<Vec<_>>()
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_custom_enum_filters_preserve_labels_and_sql_null() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE SCHEMA value_contract_enum_filter")
        .await
        .unwrap();
    connection
        .execute("CREATE TYPE value_contract_enum_filter.status AS ENUM ('NULL', 'ready', 'paused', '東京')")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE value_contract_enum_filter.rows (id INT PRIMARY KEY, status value_contract_enum_filter.status)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO value_contract_enum_filter.rows VALUES \
             (1, 'NULL'), (2, 'ready'), (3, 'paused'), (4, '東京'), (5, NULL)",
        )
        .await
        .unwrap();

    let columns = connection
        .fetch_columns(Some("value_contract_enum_filter"), "rows")
        .await
        .unwrap();
    assert_eq!(
        columns[1].enum_type,
        Some(tablepro_core::QualifiedTypeName {
            schema: "value_contract_enum_filter".into(),
            name: "status".into(),
        })
    );

    let cases = [
        (FilterOp::Eq, FilterValue::Single("NULL".into()), vec![(1, "NULL")]),
        (
            FilterOp::NotEq,
            FilterValue::Single("NULL".into()),
            vec![(2, "ready"), (3, "paused"), (4, "東京")],
        ),
        (
            FilterOp::Lt,
            FilterValue::Single("paused".into()),
            vec![(1, "NULL"), (2, "ready")],
        ),
        (
            FilterOp::LtEq,
            FilterValue::Single("paused".into()),
            vec![(1, "NULL"), (2, "ready"), (3, "paused")],
        ),
        (
            FilterOp::Gt,
            FilterValue::Single("ready".into()),
            vec![(3, "paused"), (4, "東京")],
        ),
        (
            FilterOp::GtEq,
            FilterValue::Single("ready".into()),
            vec![(2, "ready"), (3, "paused"), (4, "東京")],
        ),
        (
            FilterOp::Contains,
            FilterValue::Single("aus".into()),
            vec![(3, "paused")],
        ),
        (
            FilterOp::StartsWith,
            FilterValue::Single("rea".into()),
            vec![(2, "ready")],
        ),
        (FilterOp::EndsWith, FilterValue::Single("dy".into()), vec![(2, "ready")]),
        (FilterOp::Like, FilterValue::Single("pau%".into()), vec![(3, "paused")]),
        (
            FilterOp::NotLike,
            FilterValue::Single("p%".into()),
            vec![(1, "NULL"), (2, "ready"), (4, "東京")],
        ),
        (
            FilterOp::Ilike,
            FilterValue::Single("%READY%".into()),
            vec![(2, "ready")],
        ),
        (
            FilterOp::In,
            FilterValue::List(vec!["NULL".into(), "東京".into()]),
            vec![(1, "NULL"), (4, "東京")],
        ),
        (
            FilterOp::NotIn,
            FilterValue::List(vec!["NULL".into(), "東京".into()]),
            vec![(2, "ready"), (3, "paused")],
        ),
        (
            FilterOp::Between,
            FilterValue::Pair("ready".into(), "paused".into()),
            vec![(2, "ready"), (3, "paused")],
        ),
    ];
    for (op, value, expected_rows) in cases {
        let filter = FilterSet {
            rules: vec![FilterRule {
                column: "status".into(),
                op,
                value: Some(value),
            }],
            ..Default::default()
        };
        let (where_sql, params) = tablepro_core::build_filter_where("postgres", &columns, &filter)
            .unwrap()
            .unwrap();
        let result = connection
            .query_params(
                &format!(
                    "SELECT id, status::text, pg_typeof(status)::text \
                     FROM value_contract_enum_filter.rows WHERE {where_sql} ORDER BY id"
                ),
                &params,
            )
            .await
            .unwrap();
        assert_eq!(result.rows.len(), expected_rows.len());
        for (row, (id, label)) in result.rows.iter().zip(expected_rows) {
            assert_eq!(row[0], Value::Int(id));
            assert_eq!(row[1], Value::Text(label.into()));
            assert_eq!(row[2], Value::Text("value_contract_enum_filter.status".into()));
        }
    }

    let null_filter = FilterSet {
        rules: vec![FilterRule {
            column: "status".into(),
            op: FilterOp::IsNull,
            value: None,
        }],
        ..Default::default()
    };
    let (where_sql, params) = tablepro_core::build_filter_where("postgres", &columns, &null_filter)
        .unwrap()
        .unwrap();
    let result = connection
        .query_params(
            &format!(
                "SELECT id, status::text, pg_typeof(status)::text \
                 FROM value_contract_enum_filter.rows WHERE {where_sql}"
            ),
            &params,
        )
        .await
        .unwrap();
    assert_eq!(
        result.rows,
        vec![vec![
            Value::Int(5),
            Value::Null,
            Value::Text("value_contract_enum_filter.status".into()),
        ]]
    );

    let not_null_filter = FilterSet {
        rules: vec![FilterRule {
            column: "status".into(),
            op: FilterOp::IsNotNull,
            value: None,
        }],
        ..Default::default()
    };
    let (where_sql, params) = tablepro_core::build_filter_where("postgres", &columns, &not_null_filter)
        .unwrap()
        .unwrap();
    let result = connection
        .query_params(
            &format!(
                "SELECT id, status::text, pg_typeof(status)::text \
                 FROM value_contract_enum_filter.rows WHERE {where_sql} ORDER BY id"
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
                Value::Text("NULL".into()),
                Value::Text("value_contract_enum_filter.status".into())
            ],
            vec![
                Value::Int(2),
                Value::Text("ready".into()),
                Value::Text("value_contract_enum_filter.status".into())
            ],
            vec![
                Value::Int(3),
                Value::Text("paused".into()),
                Value::Text("value_contract_enum_filter.status".into())
            ],
            vec![
                Value::Int(4),
                Value::Text("東京".into()),
                Value::Text("value_contract_enum_filter.status".into())
            ],
        ]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_custom_enum_csv_import_uses_target_schema_under_shadowed_search_path() {
    let (_container, opts) = start_pg().await;
    let setup = connect(opts.clone()).await;
    setup.execute("CREATE SCHEMA enum_csv_shadow_a").await.unwrap();
    setup.execute("CREATE SCHEMA enum_csv_shadow_b").await.unwrap();
    setup.execute("CREATE SCHEMA enum_csv_shadow_c").await.unwrap();
    setup
        .execute("CREATE TYPE enum_csv_shadow_a.state AS ENUM ('ready', 'shadow-only', 'NULL', '')")
        .await
        .unwrap();
    setup
        .execute("CREATE TYPE enum_csv_shadow_b.state AS ENUM ('ready', 'target-only', 'NULL', '')")
        .await
        .unwrap();
    setup
        .execute("CREATE TYPE enum_csv_shadow_c.state AS ENUM ('ready', 'decoy-only')")
        .await
        .unwrap();
    setup
        .execute(
            "CREATE TABLE enum_csv_shadow_b.source_rows \
             (id integer PRIMARY KEY, state enum_csv_shadow_b.state)",
        )
        .await
        .unwrap();
    setup
        .execute(
            "INSERT INTO enum_csv_shadow_b.source_rows VALUES \
             (1, 'target-only'), (2, 'NULL'), (3, ''), (4, NULL)",
        )
        .await
        .unwrap();
    setup
        .execute(
            "CREATE TABLE enum_csv_shadow_b.target_rows \
             (id integer PRIMARY KEY, state enum_csv_shadow_b.state)",
        )
        .await
        .unwrap();
    setup
        .execute("INSERT INTO enum_csv_shadow_b.target_rows VALUES (99, 'ready')")
        .await
        .unwrap();
    setup
        .execute("CREATE TABLE enum_csv_shadow_a.target_rows (id integer PRIMARY KEY, state text)")
        .await
        .unwrap();
    setup.execute("ALTER ROLE postgres SET search_path TO enum_csv_shadow_a, public").await.unwrap();
    drop(setup);

    let connection = connect(opts.clone()).await;
    assert_eq!(
        connection.query("SELECT current_schema()::text").await.unwrap().rows,
        vec![vec![Value::Text("enum_csv_shadow_a".into())]]
    );
    let source = connection
        .query("SELECT id, state FROM enum_csv_shadow_b.source_rows ORDER BY id")
        .await
        .unwrap();
    let null_marker = tablepro_core::export::unique_csv_null_marker(&source.rows);
    let csv_options = tablepro_core::export::CsvOptions {
        null_to_empty: false,
        null_marker: Some(null_marker.clone()),
        ..Default::default()
    };
    let csv = tablepro_core::export::render_csv(&source.columns, &source.rows, &csv_options);
    let import_options = tablepro_core::import::CsvImportOptions {
        null_marker,
        ..Default::default()
    };
    let sheet = tablepro_core::import::read_csv(csv.as_bytes(), &import_options, None).unwrap();
    let columns = connection
        .fetch_columns(Some("enum_csv_shadow_b"), "target_rows")
        .await
        .unwrap();
    assert_eq!(
        columns[1].enum_type,
        Some(tablepro_core::QualifiedTypeName {
            schema: "enum_csv_shadow_b".into(),
            name: "state".into(),
        })
    );
    let plan = tablepro_core::import::build_insert_plan(
        &tablepro_core::import::ImportTarget {
            driver_id: "postgres",
            schema: Some("enum_csv_shadow_b"),
            table: "target_rows",
            columns: &columns,
            mapping: &[Some(0), Some(1)],
        },
        &sheet,
        &import_options,
    )
    .unwrap();
    assert!(
        plan.statement
            .contains("$2::text::\"enum_csv_shadow_b\".\"state\""),
        "CSV import must cast to the destination enum despite search_path: {}",
        plan.statement
    );
    let statements = plan
        .rows
        .iter()
        .map(|row| (plan.statement.clone(), row.clone()))
        .collect::<Vec<_>>();

    let setup = connect(opts.clone()).await;
    setup
        .execute("ALTER ROLE postgres SET search_path TO enum_csv_shadow_c, enum_csv_shadow_a, public")
        .await
        .unwrap();
    setup.close().await.unwrap();
    connection.close().await.unwrap();

    let connection = connect(opts).await;
    assert_eq!(
        connection.query("SELECT current_schema()::text").await.unwrap().rows,
        vec![vec![Value::Text("enum_csv_shadow_c".into())]],
        "execution must use the changed search_path with a different same-named enum first"
    );
    connection.execute_in_transaction(&statements).await.unwrap();

    let target = connection
        .query(
            "SELECT id, state::text, pg_typeof(state)::text, \
             encode(convert_to(state::text, 'UTF8'), 'hex') \
             FROM enum_csv_shadow_b.target_rows ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(
        target.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("target-only".into()),
                Value::Text("enum_csv_shadow_b.state".into()),
                Value::Text("7461726765742d6f6e6c79".into()),
            ],
            vec![
                Value::Int(2),
                Value::Text("NULL".into()),
                Value::Text("enum_csv_shadow_b.state".into()),
                Value::Text("4e554c4c".into()),
            ],
            vec![
                Value::Int(3),
                Value::Text(String::new()),
                Value::Text("enum_csv_shadow_b.state".into()),
                Value::Text(String::new()),
            ],
            vec![
                Value::Int(4),
                Value::Null,
                Value::Text("enum_csv_shadow_b.state".into()),
                Value::Null,
            ],
            vec![
                Value::Int(99),
                Value::Text("ready".into()),
                Value::Text("enum_csv_shadow_b.state".into()),
                Value::Text("7265616479".into()),
            ],
        ]
    );
    let shadow = connection
        .query("SELECT count(*)::bigint FROM enum_csv_shadow_a.target_rows")
        .await
        .unwrap();
    assert_eq!(shadow.rows, vec![vec![Value::Int(0)]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_custom_enum_csv_round_trip_preserves_quotes_lines_and_backslashes() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    let schema = "value_contract_enum_csv_edges";
    let enum_type = "value_contract_enum_csv_edges.status";
    connection.execute(&format!("CREATE SCHEMA {schema}")).await.unwrap();

    let labels = ["double \" quote", "line one\nline two", "back\\slash", "=1+1"];
    let literals = labels
        .iter()
        .map(|label| tablepro_core::sql_literal::render_sql_literal("postgres", &Value::Text((*label).into())).unwrap())
        .collect::<Vec<_>>();
    connection
        .execute(&format!("CREATE TYPE {enum_type} AS ENUM ({})", literals.join(", ")))
        .await
        .unwrap();
    for table in ["source_rows", "target_rows"] {
        connection
            .execute(&format!(
                "CREATE TABLE {schema}.{table} (id INT PRIMARY KEY, status {enum_type})"
            ))
            .await
            .unwrap();
    }

    for (id, status) in labels
        .iter()
        .map(|label| Value::Text((*label).into()))
        .chain(std::iter::once(Value::Null))
        .enumerate()
    {
        connection
            .execute_params(
                &format!("INSERT INTO {schema}.source_rows VALUES ($1, $2::{enum_type})"),
                &[Value::Int(id as i64 + 1), status],
            )
            .await
            .unwrap();
    }

    let source = connection
        .query(&format!("SELECT id, status FROM {schema}.source_rows ORDER BY id"))
        .await
        .unwrap();
    let null_marker = tablepro_core::export::unique_csv_null_marker(&source.rows);
    let columns = connection.fetch_columns(Some(schema), "target_rows").await.unwrap();
    let target = tablepro_core::import::ImportTarget {
        driver_id: "postgres",
        schema: Some(schema),
        table: "target_rows",
        columns: &columns,
        mapping: &[Some(0), Some(1)],
    };
    let expected = labels
        .iter()
        .map(|label| Some(*label))
        .chain(std::iter::once(None))
        .enumerate()
        .map(|(index, status)| {
            let value = status.map_or(Value::Null, |text| Value::Text(text.into()));
            let bytes = status.map_or(Value::Null, |text| {
                Value::Text(text.as_bytes().iter().map(|byte| format!("{byte:02x}")).collect())
            });
            vec![
                Value::Int(index as i64 + 1),
                value,
                Value::Text(enum_type.into()),
                bytes,
            ]
        })
        .collect::<Vec<_>>();

    for delimiter in tablepro_core::export::CsvDelimiter::ALL {
        for line_break in tablepro_core::export::CsvLineBreak::ALL {
            let csv_options = tablepro_core::export::CsvOptions {
                null_to_empty: false,
                null_marker: Some(null_marker.clone()),
                sanitize_formulas: false,
                delimiter,
                line_break,
                ..Default::default()
            };
            let csv = tablepro_core::export::render_csv(&source.columns, &source.rows, &csv_options);
            assert!(csv.contains("\"double \"\" quote\""));
            assert!(csv.contains("\"line one\nline two\""));
            assert!(csv.contains("=1+1"), "raw text must retain formula-shaped enum labels");

            let detected = tablepro_core::import::detect_format(csv.as_bytes());
            assert_eq!(
                detected,
                tablepro_core::import::CsvFormat {
                    delimiter,
                    has_header: true,
                },
                "{delimiter:?}/{line_break:?}"
            );
            let detected_options: tablepro_core::import::CsvImportOptions = detected.into();
            let import_options = tablepro_core::import::CsvImportOptions {
                null_marker: null_marker.clone(),
                ..detected_options
            };
            let sheet = tablepro_core::import::read_csv(csv.as_bytes(), &import_options, None).unwrap();
            assert_eq!(sheet.rows.len(), expected.len(), "{delimiter:?}/{line_break:?}");

            connection
                .execute(&format!("TRUNCATE TABLE {schema}.target_rows"))
                .await
                .unwrap();
            let plan = tablepro_core::import::build_insert_plan(&target, &sheet, &import_options).unwrap();
            assert!(
                plan.statement
                    .contains("$2::text::\"value_contract_enum_csv_edges\".\"status\"")
            );
            for row in &plan.rows {
                connection.execute_params(&plan.statement, row).await.unwrap();
            }

            let restored = connection
                .query(&format!(
                    "SELECT id, status::text, pg_typeof(status)::text, \
                     encode(convert_to(status::text, 'UTF8'), 'hex') \
                     FROM {schema}.target_rows ORDER BY id"
                ))
                .await
                .unwrap();
            assert_eq!(restored.rows, expected, "{delimiter:?}/{line_break:?}");
        }
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_enum_null_label_and_sql_null_write_as_distinct_values() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE TYPE value_contract_null_write_enum AS ENUM ('ready', 'NULL')")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE value_contract_null_enum_edits (id INT PRIMARY KEY, \
             status value_contract_null_write_enum, sibling TEXT NOT NULL)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO value_contract_null_enum_edits VALUES \
             (1, 'ready', 'left'), (2, 'ready', 'right')",
        )
        .await
        .unwrap();

    let columns = connection
        .fetch_columns(None, "value_contract_null_enum_edits")
        .await
        .unwrap();
    let (sql, params) = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "value_contract_null_enum_edits",
        &columns,
        &[(1, Value::Text("NULL".into()))],
        &[Value::Int(1)],
    )
    .unwrap();
    connection.execute_params(&sql, &params).await.unwrap();
    let (sql, params) = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "value_contract_null_enum_edits",
        &columns,
        &[(1, Value::Null)],
        &[Value::Int(2)],
    )
    .unwrap();
    connection.execute_params(&sql, &params).await.unwrap();

    let result = connection
        .query(
            "SELECT id, status::text, pg_typeof(status)::text AS native_type, sibling \
             FROM value_contract_null_enum_edits ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(
        result.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("NULL".into()),
                Value::Text("value_contract_null_write_enum".into()),
                Value::Text("left".into()),
            ],
            vec![
                Value::Int(2),
                Value::Null,
                Value::Text("value_contract_null_write_enum".into()),
                Value::Text("right".into()),
            ],
        ]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_custom_enum_projection_preserves_labels_and_null() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE TYPE value_contract_plain_enum AS ENUM ('ready', 'paused')")
        .await
        .unwrap();

    let result = connection
        .query(
            "SELECT label, pg_typeof(label)::text AS native_type \
             FROM (VALUES ('ready'::value_contract_plain_enum), \
             ('paused'::value_contract_plain_enum), \
             (NULL::value_contract_plain_enum)) AS labels(label)",
        )
        .await
        .unwrap();

    assert_eq!(
        result.rows,
        vec![
            vec![
                Value::Text("ready".into()),
                Value::Text("value_contract_plain_enum".into())
            ],
            vec![
                Value::Text("paused".into()),
                Value::Text("value_contract_plain_enum".into())
            ],
            vec![Value::Null, Value::Text("value_contract_plain_enum".into())],
        ]
    );

    let array = connection
        .query(
            "SELECT labels, pg_typeof(labels)::text AS native_type \
             FROM (SELECT ARRAY['ready'::value_contract_plain_enum, \
             'paused'::value_contract_plain_enum, NULL::value_contract_plain_enum] AS labels) source",
        )
        .await
        .unwrap();
    assert_eq!(
        array.rows,
        vec![vec![
            Value::Text(r#"{"ready","paused",NULL}"#.into()),
            Value::Text("value_contract_plain_enum[]".into()),
        ]]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_custom_enum_json_and_file_exports_preserve_empty_literal_null_and_sql_null() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE TYPE value_contract_json_enum AS ENUM ('NULL', '', '東京')")
        .await
        .unwrap();

    let result = connection
        .query(
            "SELECT label, pg_typeof(label)::text AS native_type FROM (VALUES \
             ('NULL'::value_contract_json_enum), (''::value_contract_json_enum), \
             ('東京'::value_contract_json_enum), (NULL::value_contract_json_enum)) AS labels(label)",
        )
        .await
        .unwrap();
    assert_eq!(result.rows.len(), 4, "the JSON input must retain all enum rows");
    assert_eq!(
        result.rows,
        vec![
            vec![
                Value::Text("NULL".into()),
                Value::Text("value_contract_json_enum".into())
            ],
            vec![
                Value::Text(String::new()),
                Value::Text("value_contract_json_enum".into())
            ],
            vec![
                Value::Text("東京".into()),
                Value::Text("value_contract_json_enum".into())
            ],
            vec![Value::Null, Value::Text("value_contract_json_enum".into())],
        ]
    );

    let exported = tablepro_core::export::render_json(&result.columns, &result.rows);
    let json: serde_json::Value = serde_json::from_str(&exported).unwrap();
    assert_eq!(
        json,
        serde_json::json!([
            {"label": "NULL", "native_type": "value_contract_json_enum"},
            {"label": "", "native_type": "value_contract_json_enum"},
            {"label": "東京", "native_type": "value_contract_json_enum"},
            {"label": null, "native_type": "value_contract_json_enum"}
        ])
    );

    let directory = tempfile::tempdir().unwrap();
    let json_path = directory.path().join("enum.json");
    let csv_path = directory.path().join("enum.csv");
    let csv_options = tablepro_core::export::CsvOptions::default();
    for (path, format) in [
        (&json_path, tablepro_core::export::ResultFormat::Json),
        (&csv_path, tablepro_core::export::ResultFormat::Csv),
    ] {
        tablepro_core::export::write_result_file(
            path,
            &result,
            &tablepro_core::export::ResultExport {
                format,
                csv: &csv_options,
                sql: None,
            },
            || false,
            |_| {},
        )
        .unwrap();
    }

    let file_json: serde_json::Value = serde_json::from_slice(&std::fs::read(&json_path).unwrap()).unwrap();
    assert_eq!(file_json, json);
    assert_eq!(
        std::fs::read_to_string(&csv_path).unwrap(),
        "label,native_type\nNULL,value_contract_json_enum\n\"\",value_contract_json_enum\n東京,value_contract_json_enum\n,value_contract_json_enum\n"
    );

    let previous = std::fs::read(&json_path).unwrap();
    let cancelled = std::cell::Cell::new(false);
    let error = tablepro_core::export::write_result_file(
        &json_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Json,
            csv: &csv_options,
            sql: None,
        },
        || cancelled.get(),
        |_| cancelled.set(true),
    )
    .unwrap_err();
    assert!(error.is_cancelled(), "{error:?}");
    assert_eq!(std::fs::read(&json_path).unwrap(), previous);
    assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 2);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_custom_enum_unicode_csv_import_preserves_native_type_and_nulls() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    let schema = "value_contract_enum_csv_東京";
    let type_name = "状態";
    let quoted_schema = format!("\"{schema}\"");
    let quoted_type = format!("\"{type_name}\"");
    connection
        .execute(&format!("CREATE SCHEMA {quoted_schema}"))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "CREATE TYPE {quoted_schema}.{quoted_type} AS ENUM ('ready', '東京', 'NULL', '')"
        ))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "CREATE TABLE {quoted_schema}.source_rows \
             (id INT PRIMARY KEY, state {quoted_schema}.{quoted_type}, note TEXT NOT NULL)"
        ))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "INSERT INTO {quoted_schema}.source_rows VALUES \
             (1, 'NULL', 'literal NULL'), (2, '東京', 'unicode'), \
             (3, '', 'empty label'), (4, NULL, 'sql NULL')"
        ))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "CREATE TABLE {quoted_schema}.target_rows \
             (id INT PRIMARY KEY, state {quoted_schema}.{quoted_type}, note TEXT NOT NULL)"
        ))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "INSERT INTO {quoted_schema}.target_rows VALUES (99, 'ready', 'sibling')"
        ))
        .await
        .unwrap();

    let source = connection
        .query(&format!(
            "SELECT id, state, note FROM {quoted_schema}.source_rows ORDER BY id"
        ))
        .await
        .unwrap();
    let null_marker = tablepro_core::export::unique_csv_null_marker(&source.rows);
    let csv_options = tablepro_core::export::CsvOptions {
        null_to_empty: false,
        null_marker: Some(null_marker.clone()),
        ..Default::default()
    };
    let csv = tablepro_core::export::render_csv(&source.columns, &source.rows, &csv_options);
    let import_options = tablepro_core::import::CsvImportOptions {
        null_marker,
        ..Default::default()
    };
    let sheet = tablepro_core::import::read_csv(csv.as_bytes(), &import_options, None).unwrap();
    let columns = connection
        .fetch_columns(Some(schema), "target_rows")
        .await
        .unwrap();
    assert_eq!(
        columns[1].enum_type,
        Some(tablepro_core::QualifiedTypeName {
            schema: schema.into(),
            name: type_name.into(),
        })
    );
    let plan = tablepro_core::import::build_insert_plan(
        &tablepro_core::import::ImportTarget {
            driver_id: "postgres",
            schema: Some(schema),
            table: "target_rows",
            columns: &columns,
            mapping: &[Some(0), Some(1), Some(2)],
        },
        &sheet,
        &import_options,
    )
    .unwrap();
    assert!(
        plan.statement
            .contains(&format!("$2::text::{quoted_schema}.{quoted_type}")),
        "CSV import must use the Unicode target enum: {}",
        plan.statement
    );
    let statements = plan
        .rows
        .iter()
        .map(|row| (plan.statement.clone(), row.clone()))
        .collect::<Vec<_>>();
    connection.execute_in_transaction(&statements).await.unwrap();

    let restored = connection
        .query(&format!(
            "SELECT r.id, r.state::text, n.nspname, t.typname, r.note \
             FROM {quoted_schema}.target_rows r \
             JOIN pg_type t ON t.oid = pg_typeof(r.state)::oid \
             JOIN pg_namespace n ON n.oid = t.typnamespace ORDER BY r.id"
        ))
        .await
        .unwrap();
    assert_eq!(
        restored.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("NULL".into()),
                Value::Text(schema.into()),
                Value::Text(type_name.into()),
                Value::Text("literal NULL".into()),
            ],
            vec![
                Value::Int(2),
                Value::Text("東京".into()),
                Value::Text(schema.into()),
                Value::Text(type_name.into()),
                Value::Text("unicode".into()),
            ],
            vec![
                Value::Int(3),
                Value::Text(String::new()),
                Value::Text(schema.into()),
                Value::Text(type_name.into()),
                Value::Text("empty label".into()),
            ],
            vec![
                Value::Int(4),
                Value::Null,
                Value::Text(schema.into()),
                Value::Text(type_name.into()),
                Value::Text("sql NULL".into()),
            ],
            vec![
                Value::Int(99),
                Value::Text("ready".into()),
                Value::Text(schema.into()),
                Value::Text(type_name.into()),
                Value::Text("sibling".into()),
            ],
        ]
    );
}
