#[tokio::test]
async fn sqlite_strict_any_grid_edit_preserves_each_rows_runtime_storage_class() {
    use tablepro_core::{ConnectOptions, DatabaseDriver};

    let connection = drivers_sqlite::SqliteDriver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    connection
        .execute("CREATE TABLE flexible (id INTEGER PRIMARY KEY, value ANY) STRICT")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO flexible VALUES (1, 1.5), (2, 'text'), (3, 42), (4, NULL), (5, 'clear me')")
        .await
        .unwrap();

    let columns = connection.fetch_columns(None, "flexible").await.unwrap();
    let value_index = columns.iter().position(|column| column.name == "value").unwrap();
    assert_eq!(columns[value_index].data_type, "ANY");
    for (id, input) in [(1, "2.75"), (2, "007"), (3, "43")] {
        let current = connection
            .query_params("SELECT value FROM flexible WHERE id = ?", &[Value::Int(id)])
            .await
            .unwrap();
        let current = current.rows[0][0].clone();
        let edit = parse_input_for_grid_cell(input, Some(&columns[value_index]), "sqlite", Some(&current)).unwrap();
        let update = tablepro_core::sql_dialect::build_keyed_update(
            "sqlite",
            None,
            "flexible",
            &columns,
            &[(value_index, edit)],
            &[Value::Int(id)],
        )
        .unwrap();
        connection.execute_in_transaction(&[update]).await.unwrap();
    }

    let current = connection
        .query_params("SELECT value FROM flexible WHERE id = ?", &[Value::Int(5)])
        .await
        .unwrap()
        .rows[0][0]
        .clone();
    let clear = parse_input_for_grid_cell("", Some(&columns[value_index]), "sqlite", Some(&current)).unwrap();
    let clear_update = tablepro_core::sql_dialect::build_keyed_update(
        "sqlite",
        None,
        "flexible",
        &columns,
        &[(value_index, clear)],
        &[Value::Int(5)],
    )
    .unwrap();
    connection.execute_in_transaction(&[clear_update]).await.unwrap();

    let saved = connection
        .query("SELECT id, typeof(value), value FROM flexible ORDER BY id")
        .await
        .unwrap();
    assert_eq!(
        saved.rows,
        vec![
            vec![Value::Int(1), Value::Text("real".into()), Value::Float(2.75)],
            vec![Value::Int(2), Value::Text("text".into()), Value::Text("007".into())],
            vec![Value::Int(3), Value::Text("integer".into()), Value::Int(43)],
            vec![Value::Int(4), Value::Text("null".into()), Value::Null],
            vec![Value::Int(5), Value::Text("text".into()), Value::Text(String::new())],
        ]
    );
}

#[tokio::test]
async fn sqlite_strict_any_null_and_new_cells_use_text_unless_blank() {
    use tablepro_core::{ConnectOptions, DatabaseDriver};

    let connection = drivers_sqlite::SqliteDriver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    connection
        .execute("CREATE TABLE flexible (id INTEGER PRIMARY KEY, value ANY) STRICT")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO flexible VALUES (1, NULL), (3, NULL)")
        .await
        .unwrap();

    let columns = connection.fetch_columns(None, "flexible").await.unwrap();
    let id_index = columns.iter().position(|column| column.name == "id").unwrap();
    let value_index = columns.iter().position(|column| column.name == "value").unwrap();
    assert!(columns[id_index].is_auto_increment);
    assert_eq!(columns[value_index].data_type, "ANY");
    let null = Value::Null;
    let edit = parse_input_for_grid_cell("42", Some(&columns[value_index]), "sqlite", Some(&null)).unwrap();
    assert_eq!(edit, Value::Text("42".into()));
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "sqlite",
        None,
        "flexible",
        &columns,
        &[(value_index, edit)],
        &[Value::Int(1)],
    )
    .unwrap();
    connection.execute_in_transaction(&[update]).await.unwrap();

    let blank = parse_input_for_grid_cell("", Some(&columns[value_index]), "sqlite", Some(&null)).unwrap();
    assert_eq!(blank, Value::Null);
    let blank_update = tablepro_core::sql_dialect::build_keyed_update(
        "sqlite",
        None,
        "flexible",
        &columns,
        &[(value_index, blank)],
        &[Value::Int(3)],
    )
    .unwrap();
    connection.execute_in_transaction(&[blank_update]).await.unwrap();

    let mut draft = vec![Value::Null; columns.len()];
    draft[value_index] = parse_input_for_grid_cell("007", Some(&columns[value_index]), "sqlite", Some(&null)).unwrap();
    assert_eq!(draft[value_index], Value::Text("007".into()));
    let (insert_sql, insert_params) =
        tablepro_core::sql_dialect::build_insert_from_draft("sqlite", None, "flexible", &columns, &draft).unwrap();
    connection.execute_params(&insert_sql, &insert_params).await.unwrap();

    let saved = connection
        .query("SELECT id, typeof(value), value FROM flexible ORDER BY id")
        .await
        .unwrap();
    assert_eq!(
        saved.rows,
        vec![
            vec![Value::Int(1), Value::Text("text".into()), Value::Text("42".into())],
            vec![Value::Int(3), Value::Text("null".into()), Value::Null],
            vec![Value::Int(4), Value::Text("text".into()), Value::Text("007".into())],
        ]
    );
}

#[tokio::test]
async fn sqlite_strict_any_blob_values_are_read_only_and_keep_exact_bytes() {
    use tablepro_core::{ConnectOptions, DatabaseDriver};

    let connection = drivers_sqlite::SqliteDriver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    connection
        .execute("CREATE TABLE flexible (id INTEGER PRIMARY KEY, value ANY) STRICT")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO flexible VALUES (1, X'00FF80')")
        .await
        .unwrap();

    let columns = connection.fetch_columns(None, "flexible").await.unwrap();
    let value_index = columns.iter().position(|column| column.name == "value").unwrap();
    let current = connection
        .query("SELECT value FROM flexible WHERE id = 1")
        .await
        .unwrap()
        .rows[0][0]
        .clone();
    assert_eq!(current, Value::Bytes(vec![0x00, 0xff, 0x80]));
    assert!(!crate::ui::grid::cell_allows_inline_edit(
        &columns[value_index],
        &current
    ));

    let saved = connection
        .query("SELECT id, typeof(value), value FROM flexible")
        .await
        .unwrap();
    assert_eq!(
        saved.rows,
        vec![vec![
            Value::Int(1),
            Value::Text("blob".into()),
            Value::Bytes(vec![0x00, 0xff, 0x80]),
        ]]
    );
}

#[tokio::test]
async fn sqlite_strict_any_csv_round_trip_preserves_runtime_storage_classes() {
    use tablepro_core::{
        ConnectOptions, DatabaseDriver,
        export::{CsvOptions, render_csv, unique_csv_null_marker},
        import::{CsvImportOptions, ImportTarget, build_insert_plan, read_csv},
    };

    let connection = drivers_sqlite::SqliteDriver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    connection
        .execute("CREATE TABLE source (id INTEGER PRIMARY KEY, value ANY) STRICT")
        .await
        .unwrap();
    connection
        .execute("CREATE TABLE restored (id INTEGER PRIMARY KEY, value ANY) STRICT")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO source VALUES (1, 42), (2, 1.5), (3, '42'), (4, ''), (5, NULL), (6, X'00FF80'), (7, X''), (8, 'bookie:sqlite-any:v1:integer:9'), (9, '=SUM(1)')")
        .await
        .unwrap();

    let source_result = connection.query("SELECT value FROM source ORDER BY id").await.unwrap();
    assert_eq!(source_result.columns[0].data_type, "ANY");
    let empty_result = connection.query("SELECT value FROM source WHERE 0").await.unwrap();
    assert_eq!(empty_result.columns[0].data_type, "ANY");
    assert!(empty_result.rows.is_empty());
    assert_eq!(
        render_csv(&empty_result.columns, &empty_result.rows, &CsvOptions::default()),
        "value\n"
    );
    let source_rows = source_result.rows;
    let null_marker = unique_csv_null_marker(&source_rows);
    let csv = render_csv(
        &source_result.columns,
        &source_rows,
        &CsvOptions {
            null_to_empty: false,
            null_marker: Some(null_marker.clone()),
            ..CsvOptions::default()
        },
    );

    let sheet = read_csv(
        csv.as_bytes(),
        &CsvImportOptions {
            has_header: true,
            null_marker: null_marker.clone(),
            ..CsvImportOptions::default()
        },
        None,
    )
    .unwrap();
    let target_columns = connection.fetch_columns(None, "restored").await.unwrap();
    let plan = build_insert_plan(
        &ImportTarget {
            driver_id: "sqlite",
            schema: None,
            table: "restored",
            columns: &target_columns,
            mapping: &[None, Some(0)],
        },
        &sheet,
        &CsvImportOptions {
            has_header: true,
            null_marker: null_marker.clone(),
            ..CsvImportOptions::default()
        },
    )
    .unwrap();
    for row in &plan.rows {
        connection.execute_params(&plan.statement, row).await.unwrap();
    }

    let restored = connection
        .query("SELECT typeof(value), value FROM restored ORDER BY id")
        .await
        .unwrap();
    assert_eq!(
        restored.rows,
        vec![
            vec![Value::Text("integer".into()), Value::Int(42)],
            vec![Value::Text("real".into()), Value::Float(1.5)],
            vec![Value::Text("text".into()), Value::Text("42".into())],
            vec![Value::Text("text".into()), Value::Text(String::new())],
            vec![Value::Text("null".into()), Value::Null],
            vec![Value::Text("blob".into()), Value::Bytes(vec![0x00, 0xff, 0x80])],
            vec![Value::Text("blob".into()), Value::Bytes(vec![])],
            vec![
                Value::Text("text".into()),
                Value::Text("bookie:sqlite-any:v1:integer:9".into()),
            ],
            vec![Value::Text("text".into()), Value::Text("=SUM(1)".into())],
        ]
    );
    let source_real = match source_rows[1][0] {
        Value::Float(value) => value.to_bits(),
        ref other => panic!("expected source REAL value, got {other:?}"),
    };
    let restored_real = match restored.rows[1][1] {
        Value::Float(value) => value.to_bits(),
        ref other => panic!("expected restored REAL value, got {other:?}"),
    };
    assert_eq!(restored_real, source_real);
}

#[tokio::test]
async fn sqlite_attached_any_csv_round_trip_preserves_runtime_storage_classes() {
    use tablepro_core::{ConnectOptions, DatabaseDriver};

    let connection = drivers_sqlite::SqliteDriver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    connection
        .execute("CREATE TABLE restored (id INTEGER PRIMARY KEY, value ANY) STRICT")
        .await
        .unwrap();
    let target_columns = connection.fetch_columns(None, "restored").await.unwrap();

    let mut transaction = connection.begin().await.unwrap();
    transaction.execute("ATTACH DATABASE ':memory:' AS aux").await.unwrap();
    transaction
        .execute("CREATE TABLE aux.flexible (id INTEGER PRIMARY KEY, value ANY) STRICT")
        .await
        .unwrap();
    transaction
        .execute(
            "INSERT INTO aux.flexible VALUES \
             (1, 42), (2, 1.5), (3, 'NULL'), (4, ''), (5, NULL), \
             (6, X'00FF80'), (7, '=SUM(1)')",
        )
        .await
        .unwrap();

    let source = transaction
        .query("SELECT id, value FROM aux.flexible ORDER BY id")
        .await
        .unwrap();
    assert_eq!(source.columns[1].data_type, "ANY");
    transaction.commit().await.unwrap();

    use tablepro_core::{
        export::{CsvOptions, render_csv, unique_csv_null_marker},
        import::{CsvImportOptions, ImportTarget, build_insert_plan, read_csv},
    };
    let null_marker = unique_csv_null_marker(&source.rows);
    let csv_options = CsvOptions {
        null_to_empty: false,
        null_marker: Some(null_marker.clone()),
        preserve_sqlite_result_types: true,
        ..Default::default()
    };
    let csv = render_csv(&source.columns, &source.rows, &csv_options);
    let import_options = CsvImportOptions {
        has_header: true,
        null_marker,
        ..Default::default()
    };
    let sheet = read_csv(csv.as_bytes(), &import_options, None).unwrap();
    let plan = build_insert_plan(
        &ImportTarget {
            driver_id: "sqlite",
            schema: None,
            table: "restored",
            columns: &target_columns,
            mapping: &[Some(0), Some(1)],
        },
        &sheet,
        &import_options,
    )
    .unwrap();
    for row in &plan.rows {
        connection.execute_params(&plan.statement, row).await.unwrap();
    }

    let restored = connection
        .query("SELECT id, typeof(value), value, hex(value) FROM restored ORDER BY id")
        .await
        .unwrap();
    assert_eq!(
        restored.rows,
        vec![
            vec![Value::Int(1), Value::Text("integer".into()), Value::Int(42), Value::Text("3432".into())],
            vec![Value::Int(2), Value::Text("real".into()), Value::Float(1.5), Value::Text("312E35".into())],
            vec![Value::Int(3), Value::Text("text".into()), Value::Text("NULL".into()), Value::Text("4E554C4C".into())],
            vec![Value::Int(4), Value::Text("text".into()), Value::Text(String::new()), Value::Text(String::new())],
            vec![Value::Int(5), Value::Text("null".into()), Value::Null, Value::Text(String::new())],
            vec![Value::Int(6), Value::Text("blob".into()), Value::Bytes(vec![0, 255, 128]), Value::Text("00FF80".into())],
            vec![Value::Int(7), Value::Text("text".into()), Value::Text("=SUM(1)".into()), Value::Text("3D53554D283129".into())],
        ]
    );
}

#[tokio::test]
async fn sqlite_compound_any_result_exports_csv_text_and_xlsx_cell_kinds() {
    use tablepro_core::{
        ConnectOptions, DatabaseDriver,
        export::{CsvOptions, ResultExport, ResultFormat, render_csv, write_result_file},
    };

    let connection = drivers_sqlite::SqliteDriver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    connection
        .execute("CREATE TABLE flexible (id INTEGER PRIMARY KEY, value ANY) STRICT")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO flexible VALUES (1, 42), (2, NULL), (3, '42'), (4, '=1+1'), (5, '''=1+1')")
        .await
        .unwrap();
    let result = connection
        .query(
            "SELECT 1 AS position, value AS result, typeof(value) AS storage_class \
             FROM flexible WHERE id = 1 \
             UNION ALL SELECT 2, '42', typeof('42') \
             UNION ALL SELECT 3, value, typeof(value) FROM flexible WHERE id = 2 \
             UNION ALL SELECT 4, '=1+1', typeof('=1+1') \
             UNION ALL SELECT 5, '''=1+1', typeof('''=1+1') \
             ORDER BY position",
        )
        .await
        .unwrap();
    assert_eq!(result.columns[1].data_type, "NULL");
    assert_eq!(
        render_csv(&result.columns, &result.rows, &CsvOptions::default()),
        "position,result,storage_class\n1,42,integer\n2,42,text\n3,,null\n4,\"'=1+1\",text\n5,'=1+1,text\n"
    );

    let directory = tempfile::tempdir().unwrap();
    let workbook_path = directory.path().join("sqlite-compound-any.xlsx");
    write_result_file(
        &workbook_path,
        &result,
        &ResultExport {
            format: ResultFormat::Xlsx,
            csv: &CsvOptions::default(),
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap();
    if let Some(path) = std::env::var_os("BOOKIEE_XLSX_REIMPORT_ARTIFACT") {
        std::fs::copy(&workbook_path, path).unwrap();
    }
    let mut archive = zip::ZipArchive::new(std::fs::File::open(workbook_path).unwrap()).unwrap();
    let mut sheet = String::new();
    std::io::Read::read_to_string(&mut archive.by_name("xl/worksheets/sheet1.xml").unwrap(), &mut sheet).unwrap();
    let mut shared_strings = String::new();
    std::io::Read::read_to_string(
        &mut archive.by_name("xl/sharedStrings.xml").unwrap(),
        &mut shared_strings,
    )
    .unwrap();
    assert!(sheet.contains("<c r=\"B2\"><v>42</v></c>"), "{sheet}");
    assert!(sheet.contains("<c r=\"B3\" t=\"s\">"), "{sheet}");
    assert!(!sheet.contains("r=\"B4\""), "{sheet}");
    assert!(sheet.contains("<c r=\"B5\" t=\"s\">"), "{sheet}");
    assert!(sheet.contains("<c r=\"B6\" t=\"s\">"), "{sheet}");
    assert!(
        !sheet.contains("<f>"),
        "formula-shaped source text must not become an XLSX formula: {sheet}"
    );
    assert!(shared_strings.contains("<t>42</t>"), "{shared_strings}");
    assert!(shared_strings.contains("<t>=1+1</t>"), "{shared_strings}");
    assert!(shared_strings.contains("<t>'=1+1</t>"), "{shared_strings}");

    let table_result = connection
        .query("SELECT id AS position, value AS result, typeof(value) AS storage_class FROM flexible ORDER BY id")
        .await
        .unwrap();
    assert_eq!(table_result.columns[1].data_type, "ANY");
    let table_workbook_path = directory.path().join("sqlite-table-any.xlsx");
    write_result_file(
        &table_workbook_path,
        &table_result,
        &ResultExport {
            format: ResultFormat::Xlsx,
            csv: &CsvOptions::default(),
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap();
    if let Some(path) = std::env::var_os("BOOKIEE_XLSX_TABLE_REIMPORT_ARTIFACT") {
        std::fs::copy(&table_workbook_path, path).unwrap();
    }
    let mut table_archive = zip::ZipArchive::new(std::fs::File::open(table_workbook_path).unwrap()).unwrap();
    let mut table_sheet = String::new();
    std::io::Read::read_to_string(
        &mut table_archive.by_name("xl/worksheets/sheet1.xml").unwrap(),
        &mut table_sheet,
    )
    .unwrap();
    let mut table_shared_strings = String::new();
    std::io::Read::read_to_string(
        &mut table_archive.by_name("xl/sharedStrings.xml").unwrap(),
        &mut table_shared_strings,
    )
    .unwrap();
    assert!(table_sheet.contains("<c r=\"B2\"><v>42</v></c>"), "{table_sheet}");
    assert!(!table_sheet.contains("r=\"B3\""), "{table_sheet}");
    assert!(table_sheet.contains("<c r=\"B4\" t=\"s\">"), "{table_sheet}");
    assert!(table_sheet.contains("<c r=\"B5\" t=\"s\">"), "{table_sheet}");
    assert!(table_sheet.contains("<c r=\"B6\" t=\"s\">"), "{table_sheet}");
    assert!(!table_sheet.contains("<f>"), "{table_sheet}");
    assert!(table_shared_strings.contains("<t>42</t>"), "{table_shared_strings}");
    assert!(table_shared_strings.contains("<t>=1+1</t>"), "{table_shared_strings}");
    assert!(table_shared_strings.contains("<t>'=1+1</t>"), "{table_shared_strings}");
}

#[tokio::test]
async fn sqlite_compound_any_csv_round_trip_preserves_runtime_storage_classes() {
    use tablepro_core::{ConnectOptions, DatabaseDriver};

    let connection = drivers_sqlite::SqliteDriver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    connection
        .execute("CREATE TABLE flexible (id INTEGER PRIMARY KEY, value ANY) STRICT")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO flexible VALUES (1, 42), (2, NULL), (3, X'00FF')")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE restored (\
                 id INTEGER PRIMARY KEY, position INTEGER, result ANY, storage_class TEXT\
             ) STRICT",
        )
        .await
        .unwrap();
    let result = connection
        .query(
            "SELECT 1 AS position, value AS result, typeof(value) AS storage_class \
             FROM flexible WHERE id = 1 \
             UNION ALL SELECT 2, 'branch', typeof('branch') \
             UNION ALL SELECT 3, value, typeof(value) FROM flexible WHERE id = 2 \
             UNION ALL SELECT 4, value, typeof(value) FROM flexible WHERE id = 3 \
             UNION ALL SELECT 5, 'bookie:sqlite-any:v1:integer:9', typeof('bookie:sqlite-any:v1:integer:9') \
             ORDER BY position",
        )
        .await
        .unwrap();
    assert_eq!(result.columns[1].data_type, "NULL");

    sqlite_result_csv_round_trip(
        connection.as_ref(),
        &result,
        "restored",
        &[None, Some(0), Some(1), Some(2)],
    )
    .await;

    let restored = connection
        .query("SELECT typeof(position), position, typeof(result), result, storage_class FROM restored ORDER BY id")
        .await
        .unwrap();
    assert_eq!(
        restored.rows,
        vec![
            vec![
                Value::Text("integer".into()),
                Value::Int(1),
                Value::Text("integer".into()),
                Value::Int(42),
                Value::Text("integer".into()),
            ],
            vec![
                Value::Text("integer".into()),
                Value::Int(2),
                Value::Text("text".into()),
                Value::Text("branch".into()),
                Value::Text("text".into()),
            ],
            vec![
                Value::Text("integer".into()),
                Value::Int(3),
                Value::Text("null".into()),
                Value::Null,
                Value::Text("null".into()),
            ],
            vec![
                Value::Text("integer".into()),
                Value::Int(4),
                Value::Text("blob".into()),
                Value::Bytes(vec![0, 255]),
                Value::Text("blob".into()),
            ],
            vec![
                Value::Text("integer".into()),
                Value::Int(5),
                Value::Text("text".into()),
                Value::Text("bookie:sqlite-any:v1:integer:9".into()),
                Value::Text("text".into()),
            ],
        ]
    );
}
