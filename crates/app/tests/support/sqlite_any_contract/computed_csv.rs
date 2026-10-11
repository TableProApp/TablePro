#[tokio::test]
async fn sqlite_case_any_csv_round_trip_preserves_runtime_storage_classes() {
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
        .execute(
            "INSERT INTO flexible VALUES \
             (1, 42), (2, NULL), (3, NULL), (4, X'00FF'), \
             (5, 'bookie:sqlite-any:v1:integer:9'), (6, '')",
        )
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
            "SELECT id AS position, \
                    CASE id WHEN 2 THEN 'branch' WHEN 3 THEN NULL ELSE value END AS result, \
                    typeof(CASE id WHEN 2 THEN 'branch' WHEN 3 THEN NULL ELSE value END) AS storage_class \
             FROM flexible ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(result.columns[1].data_type, "NULL");
    assert_eq!(
        result.rows.iter().map(|row| row[2].clone()).collect::<Vec<_>>(),
        vec![
            Value::Text("integer".into()),
            Value::Text("text".into()),
            Value::Text("null".into()),
            Value::Text("blob".into()),
            Value::Text("text".into()),
            Value::Text("text".into()),
        ]
    );
    let directory = tempfile::tempdir().unwrap();
    let workbook_path = directory.path().join("sqlite-case-any.xlsx");
    std::fs::write(&workbook_path, b"existing workbook").unwrap();
    let error = tablepro_core::export::write_result_file(
        &workbook_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Xlsx,
            csv: &tablepro_core::export::CsvOptions::default(),
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap_err();
    assert!(
        matches!(
            error,
            tablepro_core::export::ExportError::WorkbookEmptyText { row: 6, column: 2 }
        ),
        "{error:?}"
    );
    assert_eq!(std::fs::read(&workbook_path).unwrap(), b"existing workbook");
    assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 1);

    sqlite_result_csv_round_trip(
        connection.as_ref(),
        &result,
        "restored",
        &[None, Some(0), Some(1), Some(2)],
    )
    .await;

    let restored = connection
        .query("SELECT typeof(result), result FROM restored ORDER BY id")
        .await
        .unwrap();
    assert_eq!(
        restored.rows,
        vec![
            vec![Value::Text("integer".into()), Value::Int(42)],
            vec![Value::Text("text".into()), Value::Text("branch".into())],
            vec![Value::Text("null".into()), Value::Null],
            vec![Value::Text("blob".into()), Value::Bytes(vec![0, 255])],
            vec![
                Value::Text("text".into()),
                Value::Text("bookie:sqlite-any:v1:integer:9".into()),
            ],
            vec![Value::Text("text".into()), Value::Text(String::new())],
        ]
    );
}

#[tokio::test]
async fn sqlite_coalesce_any_csv_round_trip_preserves_runtime_storage_classes() {
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
        .execute(
            "INSERT INTO flexible VALUES \
             (1, 42), (2, NULL), (3, 1.5), (4, 'ready'), (5, X'00FF'), \
             (6, 'bookie:sqlite-any:v1:integer:9')",
        )
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
            "SELECT id AS position, coalesce(value, 'fallback') AS result, \
                    typeof(coalesce(value, 'fallback')) AS storage_class \
             FROM flexible ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(result.columns[1].data_type, "NULL");
    assert_eq!(
        result.rows.iter().map(|row| row[2].clone()).collect::<Vec<_>>(),
        vec![
            Value::Text("integer".into()),
            Value::Text("text".into()),
            Value::Text("real".into()),
            Value::Text("text".into()),
            Value::Text("blob".into()),
            Value::Text("text".into()),
        ]
    );
    let directory = tempfile::tempdir().unwrap();
    let workbook_path = directory.path().join("sqlite-coalesce-any.xlsx");
    tablepro_core::export::write_result_file(
        &workbook_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Xlsx,
            csv: &tablepro_core::export::CsvOptions::default(),
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap();
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
    assert!(sheet.contains("<c r=\"B4\"><v>1.5</v></c>"), "{sheet}");
    for row in [5, 6, 7] {
        assert!(sheet.contains(&format!("<c r=\"B{row}\" t=\"s\">")), "{sheet}");
    }
    for text in ["fallback", "ready", "\\x00ff", "bookie:sqlite-any:v1:integer:9"] {
        assert!(shared_strings.contains(&format!("<t>{text}</t>")), "{shared_strings}");
    }
    assert!(!sheet.contains("<f>"), "{sheet}");

    let json_path = directory.path().join("sqlite-coalesce-any.json");
    tablepro_core::export::write_result_file(
        &json_path,
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
    let json: serde_json::Value = serde_json::from_slice(&std::fs::read(json_path).unwrap()).unwrap();
    assert_eq!(json[0]["result"], 42);
    assert_eq!(json[1]["result"], "fallback");
    assert_eq!(json[2]["result"], 1.5);
    assert_eq!(json[3]["result"], "ready");
    assert_eq!(json[4]["result"], "\\x00ff");
    assert_eq!(json[5]["result"], "bookie:sqlite-any:v1:integer:9");
    assert_eq!(json[0]["storage_class"], "integer");
    assert_eq!(json[1]["storage_class"], "text");
    assert_eq!(json[2]["storage_class"], "real");

    sqlite_result_csv_round_trip(
        connection.as_ref(),
        &result,
        "restored",
        &[None, Some(0), Some(1), Some(2)],
    )
    .await;

    let restored = connection
        .query("SELECT typeof(result), result FROM restored ORDER BY id")
        .await
        .unwrap();
    assert_eq!(
        restored.rows,
        vec![
            vec![Value::Text("integer".into()), Value::Int(42)],
            vec![Value::Text("text".into()), Value::Text("fallback".into())],
            vec![Value::Text("real".into()), Value::Float(1.5)],
            vec![Value::Text("text".into()), Value::Text("ready".into())],
            vec![Value::Text("blob".into()), Value::Bytes(vec![0, 255])],
            vec![
                Value::Text("text".into()),
                Value::Text("bookie:sqlite-any:v1:integer:9".into()),
            ],
        ]
    );
}

#[tokio::test]
async fn sqlite_strict_any_csv_import_refuses_ambiguous_blank_and_bad_tags() {
    use tablepro_core::{
        ConnectOptions, DatabaseDriver,
        import::{CsvImportOptions, ImportTarget, PlanError, build_insert_plan, read_csv},
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
    let columns = connection.fetch_columns(None, "flexible").await.unwrap();

    let import = |bytes: &[u8], null_marker: String| {
        let options = CsvImportOptions {
            has_header: true,
            null_marker,
            ..CsvImportOptions::default()
        };
        let sheet = read_csv(bytes, &options, None).unwrap();
        build_insert_plan(
            &ImportTarget {
                driver_id: "sqlite",
                schema: None,
                table: "flexible",
                columns: &columns,
                mapping: &[None, Some(0)],
            },
            &sheet,
            &options,
        )
    };

    let blank = import(b"value\n\"\"\n", String::new()).unwrap_err();
    assert!(matches!(
        blank,
        PlanError::Rows { first, total: 1 }
            if first[0].reason == tablepro_core::import::CellError::AmbiguousSqliteAnyNullOrEmpty
    ));

    let malformed = import(b"value\nbookie:sqlite-any:v1:blob:0xz1\n", "\\N".into()).unwrap_err();
    assert!(matches!(
        malformed,
        PlanError::Rows { first, total: 1 }
            if first[0].reason == tablepro_core::import::CellError::InvalidSqliteAnyCsvValue
    ));

    let untagged_text = import(b"value\n42\n", "\\N".into()).unwrap();
    assert_eq!(untagged_text.rows, vec![vec![Value::Text("42".into())]]);
    assert_eq!(
        connection.query("SELECT COUNT(*) FROM flexible").await.unwrap().rows,
        vec![vec![Value::Int(0)]]
    );
}

#[tokio::test]
async fn sqlite_nullif_any_csv_round_trip_preserves_runtime_storage_classes() {
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
        .execute(
            "INSERT INTO flexible VALUES \
             (1, 42), (2, 1.5), (3, 'keep'), (4, 'drop'), \
             (5, X'00FF'), (6, NULL), (7, 'bookie:sqlite-any:v1:integer:9')",
        )
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
            "SELECT id AS position, NULLIF(value, 'drop') AS result, \
                    typeof(NULLIF(value, 'drop')) AS storage_class \
             FROM flexible ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(result.columns[1].data_type, "NULL");
    assert_eq!(
        result.rows.iter().map(|row| row[2].clone()).collect::<Vec<_>>(),
        vec![
            Value::Text("integer".into()),
            Value::Text("real".into()),
            Value::Text("text".into()),
            Value::Text("null".into()),
            Value::Text("blob".into()),
            Value::Text("null".into()),
            Value::Text("text".into()),
        ]
    );

    sqlite_result_csv_round_trip(
        connection.as_ref(),
        &result,
        "restored",
        &[None, Some(0), Some(1), Some(2)],
    )
    .await;

    let restored = connection
        .query("SELECT typeof(result), result, storage_class FROM restored ORDER BY id")
        .await
        .unwrap();
    assert_eq!(
        restored.rows,
        vec![
            vec![
                Value::Text("integer".into()),
                Value::Int(42),
                Value::Text("integer".into())
            ],
            vec![
                Value::Text("real".into()),
                Value::Float(1.5),
                Value::Text("real".into())
            ],
            vec![
                Value::Text("text".into()),
                Value::Text("keep".into()),
                Value::Text("text".into())
            ],
            vec![Value::Text("null".into()), Value::Null, Value::Text("null".into())],
            vec![
                Value::Text("blob".into()),
                Value::Bytes(vec![0, 255]),
                Value::Text("blob".into())
            ],
            vec![Value::Text("null".into()), Value::Null, Value::Text("null".into())],
            vec![
                Value::Text("text".into()),
                Value::Text("bookie:sqlite-any:v1:integer:9".into()),
                Value::Text("text".into()),
            ],
        ]
    );
}

#[tokio::test]
async fn sqlite_max_any_csv_round_trip_preserves_runtime_storage_classes() {
    use tablepro_core::{ConnectOptions, DatabaseDriver};

    let connection = drivers_sqlite::SqliteDriver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    connection
        .execute("CREATE TABLE flexible (group_id INTEGER, value ANY) STRICT")
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO flexible VALUES \
             (1, 2), (1, 9), (2, 1.25), (2, 1.5), \
             (3, 'alpha'), (3, 'zebra'), (4, X'0001'), (4, X'00FF'), \
             (5, NULL), (5, NULL), (6, 'alpha'), (6, 'bookie:sqlite-any:v1:integer:9')",
        )
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
            "SELECT group_id AS position, MAX(value) AS result, \
                    typeof(MAX(value)) AS storage_class \
             FROM flexible GROUP BY group_id ORDER BY group_id",
        )
        .await
        .unwrap();
    assert_eq!(result.columns[1].data_type, "NULL");
    assert_eq!(
        result.rows,
        vec![
            vec![Value::Int(1), Value::Int(9), Value::Text("integer".into())],
            vec![Value::Int(2), Value::Float(1.5), Value::Text("real".into())],
            vec![Value::Int(3), Value::Text("zebra".into()), Value::Text("text".into())],
            vec![Value::Int(4), Value::Bytes(vec![0, 255]), Value::Text("blob".into())],
            vec![Value::Int(5), Value::Null, Value::Text("null".into())],
            vec![
                Value::Int(6),
                Value::Text("bookie:sqlite-any:v1:integer:9".into()),
                Value::Text("text".into()),
            ],
        ]
    );

    sqlite_result_csv_round_trip(
        connection.as_ref(),
        &result,
        "restored",
        &[None, Some(0), Some(1), Some(2)],
    )
    .await;

    let restored = connection
        .query("SELECT typeof(result), result, storage_class FROM restored ORDER BY id")
        .await
        .unwrap();
    assert_eq!(
        restored.rows,
        vec![
            vec![
                Value::Text("integer".into()),
                Value::Int(9),
                Value::Text("integer".into())
            ],
            vec![
                Value::Text("real".into()),
                Value::Float(1.5),
                Value::Text("real".into())
            ],
            vec![
                Value::Text("text".into()),
                Value::Text("zebra".into()),
                Value::Text("text".into())
            ],
            vec![
                Value::Text("blob".into()),
                Value::Bytes(vec![0, 255]),
                Value::Text("blob".into())
            ],
            vec![Value::Text("null".into()), Value::Null, Value::Text("null".into())],
            vec![
                Value::Text("text".into()),
                Value::Text("bookie:sqlite-any:v1:integer:9".into()),
                Value::Text("text".into()),
            ],
        ]
    );
}

#[tokio::test]
async fn sqlite_min_any_csv_round_trip_preserves_runtime_storage_classes() {
    use tablepro_core::{ConnectOptions, DatabaseDriver};

    let connection = drivers_sqlite::SqliteDriver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    connection
        .execute("CREATE TABLE flexible (group_id INTEGER, value ANY) STRICT")
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO flexible VALUES \
             (1, 2), (1, 9), (2, 1.25), (2, 2.5), \
             (3, 'zebra'), (3, 'alpha'), (4, X'00FF'), (4, X'0001'), \
             (5, NULL), (5, NULL), (6, 9), (6, '1'), \
             (7, 'zebra'), (7, 'bookie:sqlite-any:v1:integer:9')",
        )
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
            "SELECT group_id AS position, MIN(value) AS result, \
                    typeof(MIN(value)) AS storage_class \
             FROM flexible GROUP BY group_id ORDER BY group_id",
        )
        .await
        .unwrap();
    assert_eq!(result.columns[1].data_type, "NULL");
    assert_eq!(
        result.rows,
        vec![
            vec![Value::Int(1), Value::Int(2), Value::Text("integer".into())],
            vec![Value::Int(2), Value::Float(1.25), Value::Text("real".into())],
            vec![Value::Int(3), Value::Text("alpha".into()), Value::Text("text".into())],
            vec![Value::Int(4), Value::Bytes(vec![0, 1]), Value::Text("blob".into())],
            vec![Value::Int(5), Value::Null, Value::Text("null".into())],
            vec![Value::Int(6), Value::Int(9), Value::Text("integer".into())],
            vec![
                Value::Int(7),
                Value::Text("bookie:sqlite-any:v1:integer:9".into()),
                Value::Text("text".into()),
            ],
        ]
    );

    sqlite_result_csv_round_trip(
        connection.as_ref(),
        &result,
        "restored",
        &[None, Some(0), Some(1), Some(2)],
    )
    .await;

    let restored = connection
        .query("SELECT typeof(result), result, storage_class FROM restored ORDER BY id")
        .await
        .unwrap();
    assert_eq!(
        restored.rows,
        vec![
            vec![
                Value::Text("integer".into()),
                Value::Int(2),
                Value::Text("integer".into())
            ],
            vec![
                Value::Text("real".into()),
                Value::Float(1.25),
                Value::Text("real".into())
            ],
            vec![
                Value::Text("text".into()),
                Value::Text("alpha".into()),
                Value::Text("text".into())
            ],
            vec![
                Value::Text("blob".into()),
                Value::Bytes(vec![0, 1]),
                Value::Text("blob".into())
            ],
            vec![Value::Text("null".into()), Value::Null, Value::Text("null".into())],
            vec![
                Value::Text("integer".into()),
                Value::Int(9),
                Value::Text("integer".into())
            ],
            vec![
                Value::Text("text".into()),
                Value::Text("bookie:sqlite-any:v1:integer:9".into()),
                Value::Text("text".into()),
            ],
        ]
    );
}

#[tokio::test]
async fn sqlite_substr_any_csv_round_trip_preserves_runtime_storage_classes() {
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
        .execute(
            "INSERT INTO flexible VALUES \
             (1, 42), (2, 1.5), (3, 'textual'), (4, ''), \
             (5, X'7465787420626C6F62'), (6, X'00FF80'), (7, NULL)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE restored (\
                 id INTEGER PRIMARY KEY, position INTEGER, result ANY, storage_class TEXT, bytes TEXT\
             ) STRICT",
        )
        .await
        .unwrap();

    let result = connection
        .query(
            "SELECT id AS position, substr(value, 1, 4) AS result, \
                    typeof(substr(value, 1, 4)) AS storage_class, \
                    hex(substr(value, 1, 4)) AS bytes \
             FROM flexible ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(result.columns[1].data_type, "NULL");
    assert_eq!(
        result.rows.iter().map(|row| row[2].clone()).collect::<Vec<_>>(),
        vec![
            Value::Text("text".into()),
            Value::Text("text".into()),
            Value::Text("text".into()),
            Value::Text("text".into()),
            Value::Text("blob".into()),
            Value::Text("blob".into()),
            Value::Text("null".into()),
        ]
    );
    assert_eq!(
        result.rows.iter().map(|row| row[3].clone()).collect::<Vec<_>>(),
        vec![
            Value::Text("3432".into()),
            Value::Text("312E35".into()),
            Value::Text("74657874".into()),
            Value::Text("".into()),
            Value::Text("74657874".into()),
            Value::Text("00FF80".into()),
            Value::Text("".into()),
        ]
    );

    sqlite_result_csv_round_trip(
        connection.as_ref(),
        &result,
        "restored",
        &[None, Some(0), Some(1), Some(2), Some(3)],
    )
    .await;

    let restored = connection
        .query("SELECT typeof(result), hex(result) FROM restored ORDER BY id")
        .await
        .unwrap();
    assert_eq!(
        restored.rows,
        vec![
            vec![Value::Text("text".into()), Value::Text("3432".into())],
            vec![Value::Text("text".into()), Value::Text("312E35".into())],
            vec![Value::Text("text".into()), Value::Text("74657874".into())],
            vec![Value::Text("text".into()), Value::Text("".into())],
            vec![Value::Text("blob".into()), Value::Text("74657874".into())],
            vec![Value::Text("blob".into()), Value::Text("00FF80".into())],
            vec![Value::Text("null".into()), Value::Text("".into())],
        ]
    );
}

#[tokio::test]
async fn sqlite_abs_any_csv_round_trip_preserves_runtime_storage_classes() {
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
        .execute(
            "INSERT INTO flexible VALUES \
             (1, -42), (2, -1.5), (3, '-42'), (4, 'not numeric'), \
             (5, ''), (6, X'2D34'), (7, X'00FF'), (8, NULL), \
             (9, -9223372036854775808)",
        )
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
            "SELECT id AS position, abs(value) AS result, \
                    typeof(abs(value)) AS storage_class \
             FROM flexible WHERE id < 9 ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(result.columns[1].data_type, "NULL");
    assert_eq!(
        result.rows,
        vec![
            vec![Value::Int(1), Value::Int(42), Value::Text("integer".into())],
            vec![Value::Int(2), Value::Float(1.5), Value::Text("real".into())],
            vec![Value::Int(3), Value::Float(42.0), Value::Text("real".into())],
            vec![Value::Int(4), Value::Float(0.0), Value::Text("real".into())],
            vec![Value::Int(5), Value::Float(0.0), Value::Text("real".into())],
            vec![Value::Int(6), Value::Float(4.0), Value::Text("real".into())],
            vec![Value::Int(7), Value::Float(0.0), Value::Text("real".into())],
            vec![Value::Int(8), Value::Null, Value::Text("null".into())],
        ]
    );

    sqlite_result_csv_round_trip(
        connection.as_ref(),
        &result,
        "restored",
        &[None, Some(0), Some(1), Some(2)],
    )
    .await;
    let restored = connection
        .query("SELECT typeof(result), result FROM restored ORDER BY id")
        .await
        .unwrap();
    assert_eq!(
        restored.rows,
        vec![
            vec![Value::Text("integer".into()), Value::Int(42)],
            vec![Value::Text("real".into()), Value::Float(1.5)],
            vec![Value::Text("real".into()), Value::Float(42.0)],
            vec![Value::Text("real".into()), Value::Float(0.0)],
            vec![Value::Text("real".into()), Value::Float(0.0)],
            vec![Value::Text("real".into()), Value::Float(4.0)],
            vec![Value::Text("real".into()), Value::Float(0.0)],
            vec![Value::Text("null".into()), Value::Null],
        ]
    );

    let overflow = connection
        .query("SELECT abs(value) FROM flexible WHERE id = 9")
        .await
        .expect_err("abs(i64::MIN) must retain SQLite's integer-overflow refusal");
    assert!(overflow.to_string().contains("integer overflow"), "{overflow}");
    assert_eq!(
        connection
            .query("SELECT id, typeof(value), value FROM flexible ORDER BY id")
            .await
            .unwrap()
            .rows,
        vec![
            vec![Value::Int(1), Value::Text("integer".into()), Value::Int(-42)],
            vec![Value::Int(2), Value::Text("real".into()), Value::Float(-1.5)],
            vec![Value::Int(3), Value::Text("text".into()), Value::Text("-42".into())],
            vec![Value::Int(4), Value::Text("text".into()), Value::Text("not numeric".into())],
            vec![Value::Int(5), Value::Text("text".into()), Value::Text(String::new())],
            vec![Value::Int(6), Value::Text("blob".into()), Value::Bytes(b"-4".to_vec())],
            vec![Value::Int(7), Value::Text("blob".into()), Value::Bytes(vec![0, 255])],
            vec![Value::Int(8), Value::Text("null".into()), Value::Null],
            vec![Value::Int(9), Value::Text("integer".into()), Value::Int(i64::MIN)],
        ],
        "overflowing computed expression must not alter source rows"
    );
}

#[tokio::test]
async fn sqlite_round_any_csv_round_trip_preserves_runtime_storage_classes() {
    use tablepro_core::{ConnectOptions, DatabaseDriver};

    let connection = drivers_sqlite::SqliteDriver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    connection
        .execute("CREATE TABLE flexible (id INTEGER PRIMARY KEY, value ANY, digits INTEGER) STRICT")
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO flexible VALUES \
             (1, 1.235, 2), (2, -1.235, 2), (3, '2.345', 2), \
             (4, 'plain', 2), (5, 125.0, -1), (6, NULL, 2)",
        )
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
            "SELECT id AS position, round(value, digits) AS result, \
                    typeof(round(value, digits)) AS storage_class \
             FROM flexible ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(result.columns[1].data_type, "NULL");
    assert_eq!(
        result.rows,
        vec![
            vec![Value::Int(1), Value::Float(1.24), Value::Text("real".into())],
            vec![Value::Int(2), Value::Float(-1.24), Value::Text("real".into())],
            vec![Value::Int(3), Value::Float(2.35), Value::Text("real".into())],
            vec![Value::Int(4), Value::Float(0.0), Value::Text("real".into())],
            vec![Value::Int(5), Value::Float(125.0), Value::Text("real".into())],
            vec![Value::Int(6), Value::Null, Value::Text("null".into())],
        ]
    );

    sqlite_result_csv_round_trip(
        connection.as_ref(),
        &result,
        "restored",
        &[None, Some(0), Some(1), Some(2)],
    )
    .await;
    let restored = connection
        .query("SELECT position, typeof(result), result, storage_class FROM restored ORDER BY id")
        .await
        .unwrap();
    assert_eq!(
        restored.rows,
        vec![
            vec![Value::Int(1), Value::Text("real".into()), Value::Float(1.24), Value::Text("real".into())],
            vec![Value::Int(2), Value::Text("real".into()), Value::Float(-1.24), Value::Text("real".into())],
            vec![Value::Int(3), Value::Text("real".into()), Value::Float(2.35), Value::Text("real".into())],
            vec![Value::Int(4), Value::Text("real".into()), Value::Float(0.0), Value::Text("real".into())],
            vec![Value::Int(5), Value::Text("real".into()), Value::Float(125.0), Value::Text("real".into())],
            vec![Value::Int(6), Value::Text("null".into()), Value::Null, Value::Text("null".into())],
        ]
    );
}

#[tokio::test]
async fn sqlite_hex_any_csv_round_trip_keeps_hex_results_as_text() {
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
        .execute(
            "INSERT INTO flexible VALUES \
             (1, 42), (2, 1.5), (3, 'é'), (4, ''), (5, X'00FF'), \
             (6, NULL), (7, '=1+1'), (8, 'bookie:sqlite-any:v1:integer:9')",
        )
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
            "SELECT id AS position, hex(value) AS result, typeof(hex(value)) AS storage_class \
             FROM flexible ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(result.columns[1].data_type, "NULL");
    assert_eq!(
        result.rows,
        vec![
            vec![Value::Int(1), Value::Text("3432".into()), Value::Text("text".into())],
            vec![Value::Int(2), Value::Text("312E35".into()), Value::Text("text".into())],
            vec![Value::Int(3), Value::Text("C3A9".into()), Value::Text("text".into())],
            vec![Value::Int(4), Value::Text(String::new()), Value::Text("text".into())],
            vec![Value::Int(5), Value::Text("00FF".into()), Value::Text("text".into())],
            vec![Value::Int(6), Value::Text(String::new()), Value::Text("text".into())],
            vec![Value::Int(7), Value::Text("3D312B31".into()), Value::Text("text".into())],
            vec![
                Value::Int(8),
                Value::Text("626F6F6B69653A73716C6974652D616E793A76313A696E74656765723A39".into()),
                Value::Text("text".into()),
            ],
        ]
    );

    sqlite_result_csv_round_trip(
        connection.as_ref(),
        &result,
        "restored",
        &[None, Some(0), Some(1), Some(2)],
    )
    .await;

    let restored = connection
        .query("SELECT typeof(result), result FROM restored ORDER BY id")
        .await
        .unwrap();
    assert_eq!(
        restored.rows,
        result.rows[0..]
            .iter()
            .map(|row| vec![Value::Text("text".into()), row[1].clone()])
            .collect::<Vec<_>>()
    );
}

#[tokio::test]
async fn sqlite_quote_any_csv_round_trip_keeps_literal_text_and_null_distinct() {
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
        .execute(
            "INSERT INTO flexible VALUES \
             (1, 42), (2, 1.5), (3, 'NULL'), (4, ''), (5, X'00FF'), \
             (6, NULL), (7, '=1+1'), (8, 'O''Brien'), (9, '東京')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE restored (\
                 id INTEGER PRIMARY KEY, position INTEGER, result ANY, storage_class TEXT, bytes TEXT\
             ) STRICT",
        )
        .await
        .unwrap();

    let result = connection
        .query(
            "SELECT id AS position, quote(value) AS result, \
                    typeof(quote(value)) AS storage_class, \
                    hex(quote(value)) AS bytes \
             FROM flexible ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(result.columns[1].data_type, "NULL");
    assert_eq!(
        result.rows,
        vec![
            vec![Value::Int(1), Value::Text("42".into()), Value::Text("text".into()), Value::Text("3432".into())],
            vec![Value::Int(2), Value::Text("1.5".into()), Value::Text("text".into()), Value::Text("312E35".into())],
            vec![Value::Int(3), Value::Text("'NULL'".into()), Value::Text("text".into()), Value::Text("274E554C4C27".into())],
            vec![Value::Int(4), Value::Text("''".into()), Value::Text("text".into()), Value::Text("2727".into())],
            vec![Value::Int(5), Value::Text("X'00FF'".into()), Value::Text("text".into()), Value::Text("58273030464627".into())],
            vec![Value::Int(6), Value::Text("NULL".into()), Value::Text("text".into()), Value::Text("4E554C4C".into())],
            vec![Value::Int(7), Value::Text("'=1+1'".into()), Value::Text("text".into()), Value::Text("273D312B3127".into())],
            vec![Value::Int(8), Value::Text("'O''Brien'".into()), Value::Text("text".into()), Value::Text("274F2727427269656E27".into())],
            vec![Value::Int(9), Value::Text("'東京'".into()), Value::Text("text".into()), Value::Text("27E69DB1E4BAAC27".into())],
        ]
    );

    sqlite_result_csv_round_trip(
        connection.as_ref(),
        &result,
        "restored",
        &[None, Some(0), Some(1), Some(2), Some(3)],
    )
    .await;

    let restored = connection
        .query("SELECT typeof(result), result, hex(result) FROM restored ORDER BY id")
        .await
        .unwrap();
    assert_eq!(
        restored.rows,
        result
            .rows
            .iter()
            .map(|row| vec![Value::Text("text".into()), row[1].clone(), row[3].clone()])
            .collect::<Vec<_>>()
    );
}

#[tokio::test]
async fn sqlite_instr_any_csv_round_trip_preserves_integer_and_null_results() {
    use tablepro_core::{ConnectOptions, DatabaseDriver};

    let connection = drivers_sqlite::SqliteDriver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE flexible (\
                 id INTEGER PRIMARY KEY, value ANY, needle ANY\
             ) STRICT",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO flexible VALUES \
             (1, 42, '2'), (2, 1.5, '5'), (3, 'a2', '2'), (4, '', 'x'), \
             (5, 'aé', 'é'), (6, X'00FF', X'FF'), (7, X'00FF', X'0001'), \
             (8, NULL, 'x'), (9, '=1+1', '='), (10, 'NULL', 'N')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE restored (\
                 id INTEGER PRIMARY KEY, position INTEGER, result ANY, storage_class TEXT, bytes TEXT\
             ) STRICT",
        )
        .await
        .unwrap();

    let result = connection
        .query(
            "SELECT id AS position, instr(value, needle) AS result, \
                    typeof(instr(value, needle)) AS storage_class, \
                    hex(instr(value, needle)) AS bytes \
             FROM flexible ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(result.columns[1].data_type, "NULL");
    assert_eq!(
        result.rows,
        vec![
            vec![Value::Int(1), Value::Int(2), Value::Text("integer".into()), Value::Text("32".into())],
            vec![Value::Int(2), Value::Int(3), Value::Text("integer".into()), Value::Text("33".into())],
            vec![Value::Int(3), Value::Int(2), Value::Text("integer".into()), Value::Text("32".into())],
            vec![Value::Int(4), Value::Int(0), Value::Text("integer".into()), Value::Text("30".into())],
            vec![Value::Int(5), Value::Int(2), Value::Text("integer".into()), Value::Text("32".into())],
            vec![Value::Int(6), Value::Int(2), Value::Text("integer".into()), Value::Text("32".into())],
            vec![Value::Int(7), Value::Int(0), Value::Text("integer".into()), Value::Text("30".into())],
            vec![Value::Int(8), Value::Null, Value::Text("null".into()), Value::Text(String::new())],
            vec![Value::Int(9), Value::Int(1), Value::Text("integer".into()), Value::Text("31".into())],
            vec![Value::Int(10), Value::Int(1), Value::Text("integer".into()), Value::Text("31".into())],
        ]
    );

    sqlite_result_csv_round_trip(
        connection.as_ref(),
        &result,
        "restored",
        &[None, Some(0), Some(1), Some(2), Some(3)],
    )
    .await;

    let restored = connection
        .query("SELECT typeof(result), result, hex(result) FROM restored ORDER BY id")
        .await
        .unwrap();
    assert_eq!(
        restored.rows,
        result
            .rows
            .iter()
            .map(|row| vec![row[2].clone(), row[1].clone(), row[3].clone()])
            .collect::<Vec<_>>()
    );
}

