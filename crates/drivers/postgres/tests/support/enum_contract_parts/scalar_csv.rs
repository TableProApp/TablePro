#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_custom_enum_csv_round_trip_preserves_labels_and_sql_null() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE SCHEMA value_contract_enum_import")
        .await
        .unwrap();
    connection
        .execute("CREATE TYPE value_contract_enum_import.status AS ENUM ('NULL', '東京', 'o''brien', 'with,comma', '', ' leading', 'trailing ')")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE value_contract_enum_import.source_rows (id INT PRIMARY KEY, \
             status value_contract_enum_import.status, note TEXT NOT NULL)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO value_contract_enum_import.source_rows VALUES \
             (1, 'NULL', 'literal null'), (2, '東京', 'unicode'), \
             (3, 'o''brien', 'apostrophe'), (4, 'with,comma', 'delimiter'), \
             (5, '', 'empty label'), (6, NULL, 'sql null'), \
             (7, ' leading', 'leading space'), (8, 'trailing ', 'trailing space')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE value_contract_enum_import.target_rows (id INT PRIMARY KEY, \
             status value_contract_enum_import.status, note TEXT NOT NULL)",
        )
        .await
        .unwrap();

    let source = connection
        .query("SELECT id, status, note FROM value_contract_enum_import.source_rows ORDER BY id")
        .await
        .unwrap();
    let options = tablepro_core::import::CsvImportOptions::default();
    let csv = tablepro_core::export::render_csv(
        &source.columns,
        &source.rows,
        &tablepro_core::export::CsvOptions::default(),
    );
    let exported_sheet = tablepro_core::import::read_csv(csv.as_bytes(), &options, None).unwrap();
    assert_eq!(exported_sheet.rows[0], vec!["1", "NULL", "literal null"]);
    assert_eq!(exported_sheet.rows[4], vec!["5", "", "empty label"]);
    assert_eq!(exported_sheet.rows[5], vec!["6", "", "sql null"]);
    assert_eq!(exported_sheet.rows[6], vec!["7", " leading", "leading space"]);
    assert_eq!(exported_sheet.rows[7], vec!["8", "trailing ", "trailing space"]);

    let columns = connection
        .fetch_columns(Some("value_contract_enum_import"), "target_rows")
        .await
        .unwrap();
    let default_target = tablepro_core::import::ImportTarget {
        driver_id: "postgres",
        schema: Some("value_contract_enum_import"),
        table: "target_rows",
        columns: &columns,
        mapping: &[Some(0), Some(1), Some(2)],
    };
    let error = tablepro_core::import::build_insert_plan(&default_target, &exported_sheet, &options)
        .expect_err("default CSV blanks cannot distinguish an empty enum label from SQL NULL");
    let tablepro_core::import::PlanError::Rows { total, first } = error else {
        panic!("expected ambiguous enum fields to be refused");
    };
    assert_eq!(total, 2);
    assert!(
        first
            .iter()
            .all(|row| row.reason == tablepro_core::import::CellError::AmbiguousEnumNullOrEmpty)
    );
    let untouched = connection
        .query("SELECT count(*)::bigint FROM value_contract_enum_import.target_rows")
        .await
        .unwrap();
    assert_eq!(untouched.rows, vec![vec![Value::Int(0)]]);

    let explicit_csv = "id,status,note\n1,NULL,literal null\n2,東京,unicode\n3,\"o'brien\",apostrophe\n4,\"with,comma\",delimiter\n5,,empty label\n6,\\N,sql null\n7,\" leading\",leading space\n8,\"trailing \",trailing space\n";
    let options = tablepro_core::import::CsvImportOptions {
        null_marker: "\\N".into(),
        ..Default::default()
    };
    let sheet = tablepro_core::import::read_csv(explicit_csv.as_bytes(), &options, None).unwrap();
    let plan = tablepro_core::import::build_insert_plan(
        &tablepro_core::import::ImportTarget {
            driver_id: "postgres",
            schema: Some("value_contract_enum_import"),
            table: "target_rows",
            columns: &columns,
            mapping: &[Some(0), Some(1), Some(2)],
        },
        &sheet,
        &options,
    )
    .unwrap();
    assert!(
        plan.statement
            .contains("$2::text::\"value_contract_enum_import\".\"status\""),
        "enum CSV input must bind with its catalog type: {}",
        plan.statement
    );
    assert_eq!(plan.rows.len(), 8);
    for row in &plan.rows {
        connection.execute_params(&plan.statement, row).await.unwrap();
    }

    let restored = connection
        .query(
            "SELECT id, status::text, pg_typeof(status)::text, note \
             FROM value_contract_enum_import.target_rows ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(
        restored.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("NULL".into()),
                Value::Text("value_contract_enum_import.status".into()),
                Value::Text("literal null".into()),
            ],
            vec![
                Value::Int(2),
                Value::Text("東京".into()),
                Value::Text("value_contract_enum_import.status".into()),
                Value::Text("unicode".into()),
            ],
            vec![
                Value::Int(3),
                Value::Text("o'brien".into()),
                Value::Text("value_contract_enum_import.status".into()),
                Value::Text("apostrophe".into()),
            ],
            vec![
                Value::Int(4),
                Value::Text("with,comma".into()),
                Value::Text("value_contract_enum_import.status".into()),
                Value::Text("delimiter".into()),
            ],
            vec![
                Value::Int(5),
                Value::Text(String::new()),
                Value::Text("value_contract_enum_import.status".into()),
                Value::Text("empty label".into()),
            ],
            vec![
                Value::Int(6),
                Value::Null,
                Value::Text("value_contract_enum_import.status".into()),
                Value::Text("sql null".into()),
            ],
            vec![
                Value::Int(7),
                Value::Text(" leading".into()),
                Value::Text("value_contract_enum_import.status".into()),
                Value::Text("leading space".into()),
            ],
            vec![
                Value::Int(8),
                Value::Text("trailing ".into()),
                Value::Text("value_contract_enum_import.status".into()),
                Value::Text("trailing space".into()),
            ],
        ]
    );
}

