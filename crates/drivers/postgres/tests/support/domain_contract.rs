use tablepro_core::{Connection, FilterOp, FilterRule, FilterSet, FilterValue, Value};

use crate::{connect, start_pg};

include!("domain_contract_parts/basic_domains.rs");

include!("domain_contract_parts/array_functions.rs");

include!("domain_contract_parts/array_to_string.rs");

include!("domain_contract_parts/array_fill.rs");

include!("domain_contract_parts/multi_array_unnest.rs");

include!("domain_contract_parts/random_enum_arrays.rs");

include!("domain_contract_parts/array_cat.rs");

include!("domain_contract_parts/array_positions.rs");

include!("domain_contract_parts/array_subscripts.rs");

include!("domain_contract_parts/array_shape.rs");

include!("domain_contract_parts/array_equality.rs");

include!("domain_contract_parts/deep_domains.rs");

include!("domain_contract_parts/deep_enum_array_parameters.rs");

include!("domain_contract_parts/deep_enum_expression_contract.rs");

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_domain_over_enum_filters_preserve_values_and_type() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE SCHEMA value_contract_domain_filter")
        .await
        .unwrap();
    connection
        .execute("CREATE TYPE value_contract_domain_filter.status AS ENUM ('NULL', 'ready', '東京')")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE DOMAIN value_contract_domain_filter.status_domain \
             AS value_contract_domain_filter.status",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE value_contract_domain_filter.rows \
             (id INT PRIMARY KEY, label value_contract_domain_filter.status_domain)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO value_contract_domain_filter.rows VALUES \
             (1, 'NULL'), (2, 'ready'), (3, '東京'), (4, NULL)",
        )
        .await
        .unwrap();

    let columns = connection
        .fetch_columns(Some("value_contract_domain_filter"), "rows")
        .await
        .unwrap();
    assert_eq!(
        columns[1].enum_type,
        Some(tablepro_core::QualifiedTypeName {
            schema: "value_contract_domain_filter".into(),
            name: "status".into(),
        })
    );
    let cases = [
        (FilterOp::Eq, FilterValue::Single("NULL".into()), vec![(1, "NULL")]),
        (
            FilterOp::NotEq,
            FilterValue::Single("NULL".into()),
            vec![(2, "ready"), (3, "東京")],
        ),
        (
            FilterOp::Lt,
            FilterValue::Single("東京".into()),
            vec![(1, "NULL"), (2, "ready")],
        ),
        (
            FilterOp::LtEq,
            FilterValue::Single("ready".into()),
            vec![(1, "NULL"), (2, "ready")],
        ),
        (FilterOp::Gt, FilterValue::Single("ready".into()), vec![(3, "東京")]),
        (
            FilterOp::GtEq,
            FilterValue::Single("ready".into()),
            vec![(2, "ready"), (3, "東京")],
        ),
        (
            FilterOp::Contains,
            FilterValue::Single("ead".into()),
            vec![(2, "ready")],
        ),
        (
            FilterOp::StartsWith,
            FilterValue::Single("re".into()),
            vec![(2, "ready")],
        ),
        (FilterOp::EndsWith, FilterValue::Single("dy".into()), vec![(2, "ready")]),
        (FilterOp::Like, FilterValue::Single("re%".into()), vec![(2, "ready")]),
        (
            FilterOp::NotLike,
            FilterValue::Single("東%".into()),
            vec![(1, "NULL"), (2, "ready")],
        ),
        (
            FilterOp::Ilike,
            FilterValue::Single("%READY%".into()),
            vec![(2, "ready")],
        ),
        (
            FilterOp::In,
            FilterValue::List(vec!["ready".into(), "東京".into()]),
            vec![(2, "ready"), (3, "東京")],
        ),
        (
            FilterOp::NotIn,
            FilterValue::List(vec!["NULL".into(), "東京".into()]),
            vec![(2, "ready")],
        ),
        (
            FilterOp::Between,
            FilterValue::Pair("NULL".into(), "ready".into()),
            vec![(1, "NULL"), (2, "ready")],
        ),
    ];
    for (op, value, expected_ids) in cases {
        let filters = FilterSet {
            rules: vec![FilterRule {
                column: "label".into(),
                op,
                value: Some(value),
            }],
            ..Default::default()
        };
        let (where_sql, params) = tablepro_core::build_filter_where("postgres", &columns, &filters)
            .unwrap()
            .unwrap();
        let result = connection
            .query_params(
                &format!(
                    "SELECT id, label::text, pg_typeof(label)::text \
                     FROM value_contract_domain_filter.rows WHERE {where_sql} ORDER BY id"
                ),
                &params,
            )
            .await
            .unwrap();
        let expected = expected_ids
            .into_iter()
            .map(|(id, label)| {
                vec![
                    Value::Int(id),
                    Value::Text(label.into()),
                    Value::Text("value_contract_domain_filter.status_domain".into()),
                ]
            })
            .collect::<Vec<_>>();
        assert_eq!(result.rows, expected);
    }

    let null_filter = FilterSet {
        rules: vec![FilterRule {
            column: "label".into(),
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
                "SELECT id, label::text, pg_typeof(label)::text \
                 FROM value_contract_domain_filter.rows WHERE {where_sql}"
            ),
            &params,
        )
        .await
        .unwrap();
    assert_eq!(
        result.rows,
        vec![vec![
            Value::Int(4),
            Value::Null,
            Value::Text("value_contract_domain_filter.status_domain".into())
        ]]
    );

    let not_null_filter = FilterSet {
        rules: vec![FilterRule {
            column: "label".into(),
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
                "SELECT id, label::text, pg_typeof(label)::text \
                 FROM value_contract_domain_filter.rows WHERE {where_sql} ORDER BY id"
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
                Value::Text("value_contract_domain_filter.status_domain".into())
            ],
            vec![
                Value::Int(2),
                Value::Text("ready".into()),
                Value::Text("value_contract_domain_filter.status_domain".into())
            ],
            vec![
                Value::Int(3),
                Value::Text("東京".into()),
                Value::Text("value_contract_domain_filter.status_domain".into())
            ],
        ]
    );

    let (update_sql, update_params) = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        Some("value_contract_domain_filter"),
        "rows",
        &columns,
        &[(1, Value::Text("東京".into()))],
        &[Value::Int(1)],
    )
    .unwrap();
    connection.execute_params(&update_sql, &update_params).await.unwrap();
    let (insert_sql, insert_params) = tablepro_core::sql_dialect::build_insert_from_draft(
        "postgres",
        Some("value_contract_domain_filter"),
        "rows",
        &columns,
        &[Value::Int(5), Value::Text("ready".into())],
    )
    .unwrap();
    connection.execute_params(&insert_sql, &insert_params).await.unwrap();
    let writes = connection
        .query(
            "SELECT id, label::text, pg_typeof(label)::text \
             FROM value_contract_domain_filter.rows WHERE id IN (1, 5) ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(
        writes.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("東京".into()),
                Value::Text("value_contract_domain_filter.status_domain".into()),
            ],
            vec![
                Value::Int(5),
                Value::Text("ready".into()),
                Value::Text("value_contract_domain_filter.status_domain".into()),
            ],
        ]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_domain_over_enum_csv_round_trip_preserves_values_and_type() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    for sql in [
        "CREATE SCHEMA value_contract_domain_csv",
        "CREATE TYPE value_contract_domain_csv.status AS ENUM ('NULL', '', 'ready', '東京')",
        "CREATE DOMAIN value_contract_domain_csv.status_domain AS value_contract_domain_csv.status",
        "CREATE TABLE value_contract_domain_csv.source_rows (id INT PRIMARY KEY, label value_contract_domain_csv.status_domain)",
        "CREATE TABLE value_contract_domain_csv.target_rows (id INT PRIMARY KEY, label value_contract_domain_csv.status_domain)",
        "INSERT INTO value_contract_domain_csv.source_rows VALUES (1, 'NULL'), (2, ''), (3, 'ready'), (4, '東京'), (5, NULL)",
    ] {
        connection.execute(sql).await.unwrap();
    }

    let source = connection
        .query("SELECT id, label FROM value_contract_domain_csv.source_rows ORDER BY id")
        .await
        .unwrap();
    let default_csv = tablepro_core::export::render_csv(
        &source.columns,
        &source.rows,
        &tablepro_core::export::CsvOptions::default(),
    );
    let default_options = tablepro_core::import::CsvImportOptions::default();
    let default_sheet = tablepro_core::import::read_csv(default_csv.as_bytes(), &default_options, None).unwrap();
    let target_columns = connection
        .fetch_columns(Some("value_contract_domain_csv"), "target_rows")
        .await
        .unwrap();
    assert_eq!(
        target_columns[1].enum_type,
        Some(tablepro_core::QualifiedTypeName {
            schema: "value_contract_domain_csv".into(),
            name: "status".into(),
        })
    );
    assert_eq!(
        target_columns[1].domain_type,
        Some(tablepro_core::QualifiedTypeName {
            schema: "value_contract_domain_csv".into(),
            name: "status_domain".into(),
        })
    );
    let target = tablepro_core::import::ImportTarget {
        driver_id: "postgres",
        schema: Some("value_contract_domain_csv"),
        table: "target_rows",
        columns: &target_columns,
        mapping: &[Some(0), Some(1)],
    };
    assert!(matches!(
        tablepro_core::import::build_insert_plan(&target, &default_sheet, &default_options),
        Err(tablepro_core::import::PlanError::Rows { total: 2, .. })
    ));
    let untouched = connection
        .query("SELECT count(*)::bigint FROM value_contract_domain_csv.target_rows")
        .await
        .unwrap();
    assert_eq!(untouched.rows, vec![vec![Value::Int(0)]]);

    let options = tablepro_core::import::CsvImportOptions {
        null_marker: "\\N".into(),
        ..Default::default()
    };
    let export_options = tablepro_core::export::CsvOptions {
        null_to_empty: false,
        null_marker: Some("\\N".into()),
        ..Default::default()
    };
    let csv = tablepro_core::export::render_csv(&source.columns, &source.rows, &export_options);
    assert_eq!(csv, "id,label\n1,NULL\n2,\"\"\n3,ready\n4,東京\n5,\\N\n");
    let sheet = tablepro_core::import::read_csv(csv.as_bytes(), &options, None).unwrap();
    let plan = tablepro_core::import::build_insert_plan(&target, &sheet, &options).unwrap();
    assert!(
        plan.statement
            .contains("$2::text::\"value_contract_domain_csv\".\"status_domain\"")
    );
    for row in &plan.rows {
        connection.execute_params(&plan.statement, row).await.unwrap();
    }

    let restored = connection
        .query(
            "SELECT id, label::text, pg_typeof(label)::text \
             FROM value_contract_domain_csv.target_rows ORDER BY id",
        )
        .await
        .unwrap();
    let domain_type = Value::Text("value_contract_domain_csv.status_domain".into());
    assert_eq!(
        restored.rows,
        vec![
            vec![Value::Int(1), Value::Text("NULL".into()), domain_type.clone()],
            vec![Value::Int(2), Value::Text(String::new()), domain_type.clone()],
            vec![Value::Int(3), Value::Text("ready".into()), domain_type.clone()],
            vec![Value::Int(4), Value::Text("東京".into()), domain_type],
            vec![
                Value::Int(5),
                Value::Null,
                Value::Text("value_contract_domain_csv.status_domain".into())
            ],
        ]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_domain_over_enum_sql_file_replay_preserves_values_and_type() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    for sql in [
        "CREATE SCHEMA value_contract_domain_sql",
        "CREATE TYPE value_contract_domain_sql.state AS ENUM ('NULL', '', '東京', 'x''; DROP TABLE keep_me; --')",
        "CREATE DOMAIN value_contract_domain_sql.state_domain AS value_contract_domain_sql.state",
        "CREATE TABLE value_contract_domain_sql.source_rows (id INT PRIMARY KEY, label value_contract_domain_sql.state_domain)",
        "CREATE TABLE value_contract_domain_sql.restore_rows (id INT PRIMARY KEY, label value_contract_domain_sql.state_domain)",
        "INSERT INTO value_contract_domain_sql.source_rows VALUES \
         (1, 'NULL'), (2, ''), (3, '東京'), (4, 'x''; DROP TABLE keep_me; --'), (5, NULL)",
    ] {
        connection.execute(sql).await.unwrap();
    }
    connection
        .execute("CREATE TABLE value_contract_domain_sql.keep_me (id INT PRIMARY KEY)")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO value_contract_domain_sql.keep_me VALUES (1)")
        .await
        .unwrap();

    let result = connection
        .query("SELECT id, label FROM value_contract_domain_sql.source_rows ORDER BY id")
        .await
        .unwrap();
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("domain-enum.sql");
    tablepro_core::export::write_result_file(
        &path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Sql,
            csv: &tablepro_core::export::CsvOptions::default(),
            sql: Some(tablepro_core::export::SqlTarget {
                driver_id: "postgres",
                schema: Some("value_contract_domain_sql"),
                table: "restore_rows",
            }),
        },
        || false,
        |_| {},
    )
    .unwrap();
    let sql = std::fs::read_to_string(&path).unwrap();
    assert_eq!(sql.lines().count(), result.rows.len());
    assert!(
        sql.lines()
            .all(|line| line.starts_with("INSERT INTO \"value_contract_domain_sql\".\"restore_rows\""))
    );
    for statement in sql.lines() {
        connection.execute(statement).await.unwrap();
    }

    let restored = connection
        .query(
            "SELECT id, label::text, pg_typeof(label)::text \
             FROM value_contract_domain_sql.restore_rows ORDER BY id",
        )
        .await
        .unwrap();
    let domain_type = Value::Text("value_contract_domain_sql.state_domain".into());
    assert_eq!(
        restored.rows,
        vec![
            vec![Value::Int(1), Value::Text("NULL".into()), domain_type.clone()],
            vec![Value::Int(2), Value::Text(String::new()), domain_type.clone()],
            vec![Value::Int(3), Value::Text("東京".into()), domain_type.clone()],
            vec![
                Value::Int(4),
                Value::Text("x'; DROP TABLE keep_me; --".into()),
                domain_type.clone(),
            ],
            vec![Value::Int(5), Value::Null, domain_type],
        ]
    );
    let table = connection
        .query("SELECT count(*)::bigint FROM value_contract_domain_sql.keep_me")
        .await
        .unwrap();
    assert_eq!(table.rows, vec![vec![Value::Int(1)]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_domain_over_enum_file_formats_preserve_values_and_refuse_empty_xlsx() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE SCHEMA value_contract_domain_formats")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_domain_formats.label AS ENUM \
             ('NULL', '', '東京', '</label><img src=x onerror=\"alert(''x'')\">', \
              E'a|b\\nc', '<tag>&amp;', '=1+1')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE DOMAIN value_contract_domain_formats.label_domain \
             AS value_contract_domain_formats.label",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE value_contract_domain_formats.rows \
             (id INT PRIMARY KEY, label value_contract_domain_formats.label_domain)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO value_contract_domain_formats.rows VALUES \
             (1, 'NULL'), (2, ''), (3, '東京'), \
             (4, '</label><img src=x onerror=\"alert(''x'')\">'), \
             (5, E'a|b\\nc'), (6, '<tag>&amp;'), (7, '=1+1'), (8, NULL)",
        )
        .await
        .unwrap();

    let all_rows = connection
        .query(
            "SELECT id, label, pg_typeof(label)::text AS native_type \
             FROM value_contract_domain_formats.rows ORDER BY id",
        )
        .await
        .unwrap();
    let domain_type = Value::Text("value_contract_domain_formats.label_domain".into());
    let hostile = "</label><img src=x onerror=\"alert('x')\">";
    assert_eq!(
        all_rows.rows,
        vec![
            vec![Value::Int(1), Value::Text("NULL".into()), domain_type.clone()],
            vec![Value::Int(2), Value::Text(String::new()), domain_type.clone()],
            vec![Value::Int(3), Value::Text("東京".into()), domain_type.clone()],
            vec![Value::Int(4), Value::Text(hostile.into()), domain_type.clone()],
            vec![Value::Int(5), Value::Text("a|b\nc".into()), domain_type.clone()],
            vec![Value::Int(6), Value::Text("<tag>&amp;".into()), domain_type.clone()],
            vec![Value::Int(7), Value::Text("=1+1".into()), domain_type.clone()],
            vec![Value::Int(8), Value::Null, domain_type],
        ]
    );

    let directory = tempfile::tempdir().unwrap();
    let csv = tablepro_core::export::CsvOptions::default();
    for (name, format) in [
        ("domain.xml", tablepro_core::export::ResultFormat::Xml),
        ("domain.html", tablepro_core::export::ResultFormat::Html),
        ("domain.md", tablepro_core::export::ResultFormat::Markdown),
    ] {
        let path = directory.path().join(name);
        tablepro_core::export::write_result_file(
            &path,
            &all_rows,
            &tablepro_core::export::ResultExport {
                format,
                csv: &csv,
                sql: None,
            },
            || false,
            |_| {},
        )
        .unwrap();
        let output = std::fs::read_to_string(&path).unwrap();
        match format {
            tablepro_core::export::ResultFormat::Xml => {
                assert!(output.contains("<label>NULL</label>"), "{output}");
                assert!(output.contains("<label></label>"), "{output}");
                assert!(output.contains("<label>東京</label>"), "{output}");
                assert!(output.contains("onerror=&quot;alert(&apos;x&apos;)&quot;"), "{output}");
                assert!(output.contains("<label null=\"true\"/>"), "{output}");
            }
            tablepro_core::export::ResultFormat::Html => {
                assert!(output.contains("<td>NULL</td>"), "{output}");
                assert!(output.contains("<td></td>"), "{output}");
                assert!(output.contains("<td>東京</td>"), "{output}");
                assert!(output.contains("&lt;/label&gt;&lt;img src=x"), "{output}");
                assert!(!output.contains("<img src=x"), "{output}");
                assert!(output.contains("<td class=\"null\"></td>"), "{output}");
            }
            tablepro_core::export::ResultFormat::Markdown => {
                assert!(output.contains("| \"NULL\" |"), "{output}");
                assert!(output.contains("| \"\" |"), "{output}");
                assert!(output.contains("| \"東京\" |"), "{output}");
                assert!(output.contains("a\\|b&#92;nc"), "{output}");
                assert!(output.contains("&lt;tag&gt;&amp;amp;"), "{output}");
                assert!(output.contains("| NULL |"), "{output}");
            }
            tablepro_core::export::ResultFormat::Csv
            | tablepro_core::export::ResultFormat::Json
            | tablepro_core::export::ResultFormat::Sql
            | tablepro_core::export::ResultFormat::Xlsx => {}
        }
    }

    let valid_rows = connection
        .query(
            "SELECT id, label, pg_typeof(label)::text AS native_type \
             FROM value_contract_domain_formats.rows WHERE label::text <> '' ORDER BY id",
        )
        .await
        .unwrap();
    let xlsx_path = directory.path().join("domain.xlsx");
    tablepro_core::export::write_result_file(
        &xlsx_path,
        &valid_rows,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Xlsx,
            csv: &csv,
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap();
    let workbook = std::fs::read(&xlsx_path).unwrap();
    assert!(workbook.starts_with(b"PK"));
    assert!(workbook.len() > 1_000, "{}", workbook.len());

    let refusal_path = directory.path().join("keep.xlsx");
    std::fs::write(&refusal_path, b"existing workbook").unwrap();
    let error = tablepro_core::export::write_result_file(
        &refusal_path,
        &all_rows,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Xlsx,
            csv: &csv,
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap_err();
    assert!(
        matches!(
            error,
            tablepro_core::export::ExportError::WorkbookEmptyText { row: 2, column: 2 }
        ),
        "{error:?}"
    );
    assert_eq!(std::fs::read(&refusal_path).unwrap(), b"existing workbook");
    assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 5);
}
