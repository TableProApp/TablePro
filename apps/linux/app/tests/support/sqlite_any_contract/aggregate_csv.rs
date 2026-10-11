#[tokio::test]
async fn sqlite_group_concat_any_csv_round_trip_preserves_text_and_null() {
    use tablepro_core::{ConnectOptions, DatabaseDriver};

    let connection = drivers_sqlite::SqliteDriver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    connection
        .execute("CREATE TABLE flexible (group_id INTEGER, position INTEGER, value ANY) STRICT")
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO flexible VALUES \
             (1, 1, 2), (1, 2, NULL), (1, 3, 1.5), (1, 4, 'alpha'), \
             (2, 1, 'a|b'), (2, 2, ''), (2, 3, 'tail'), \
             (3, 1, NULL), (3, 2, NULL), \
             (4, 1, 'bookie:sqlite-any:v1:integer:9'), (4, 2, 'end')",
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
            "SELECT group_id AS position, \
                    group_concat(value, '<>' ORDER BY position) AS result, \
                    typeof(group_concat(value, '<>' ORDER BY position)) AS storage_class \
             FROM flexible GROUP BY group_id ORDER BY group_id",
        )
        .await
        .unwrap();
    assert_eq!(result.columns[1].data_type, "NULL");
    assert_eq!(
        result.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("2<>1.5<>alpha".into()),
                Value::Text("text".into()),
            ],
            vec![
                Value::Int(2),
                Value::Text("a|b<><>tail".into()),
                Value::Text("text".into()),
            ],
            vec![Value::Int(3), Value::Null, Value::Text("null".into())],
            vec![
                Value::Int(4),
                Value::Text("bookie:sqlite-any:v1:integer:9<>end".into()),
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
                Value::Text("text".into()),
                Value::Text("2<>1.5<>alpha".into()),
                Value::Text("text".into()),
            ],
            vec![
                Value::Text("text".into()),
                Value::Text("a|b<><>tail".into()),
                Value::Text("text".into()),
            ],
            vec![Value::Text("null".into()), Value::Null, Value::Text("null".into())],
            vec![
                Value::Text("text".into()),
                Value::Text("bookie:sqlite-any:v1:integer:9<>end".into()),
                Value::Text("text".into()),
            ],
        ]
    );
}

#[tokio::test]
async fn sqlite_printf_any_csv_round_trip_preserves_text_and_null_semantics() {
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
             (1, 42), (2, 1.25), (3, 'plain'), (4, 'NULL'), \
             (5, '=1+1'), (6, ''), (7, NULL)",
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
            "SELECT id AS position, printf('%s', value) AS result, \
                    typeof(printf('%s', value)) AS storage_class \
             FROM flexible ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(result.columns[1].data_type, "NULL");
    assert_eq!(
        result.rows,
        vec![
            vec![Value::Int(1), Value::Text("42".into()), Value::Text("text".into())],
            vec![Value::Int(2), Value::Text("1.25".into()), Value::Text("text".into())],
            vec![Value::Int(3), Value::Text("plain".into()), Value::Text("text".into())],
            vec![Value::Int(4), Value::Text("NULL".into()), Value::Text("text".into())],
            vec![Value::Int(5), Value::Text("=1+1".into()), Value::Text("text".into())],
            vec![Value::Int(6), Value::Text(String::new()), Value::Text("text".into())],
            vec![Value::Int(7), Value::Text(String::new()), Value::Text("text".into())],
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
        result
            .rows
            .iter()
            .map(|row| vec![Value::Text("text".into()), row[1].clone(), row[2].clone()])
            .collect::<Vec<_>>()
    );
}

#[tokio::test]
async fn sqlite_sum_any_csv_round_trip_preserves_runtime_storage_classes() {
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
             (1, 7), (1, 9), (2, 1.25), (2, 2.5), \
             (3, '12'), (3, '3'), (4, '1.5'), \
             (5, 'alpha'), (5, X'00FF'), (6, NULL), (6, NULL), \
             (7, 1), (7, 2.5)",
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
            "SELECT group_id AS position, SUM(value) AS result, \
                    typeof(SUM(value)) AS storage_class \
             FROM flexible GROUP BY group_id ORDER BY group_id",
        )
        .await
        .unwrap();
    assert_eq!(result.columns[1].data_type, "NULL");
    assert_eq!(
        result.rows,
        vec![
            vec![Value::Int(1), Value::Int(16), Value::Text("integer".into())],
            vec![Value::Int(2), Value::Float(3.75), Value::Text("real".into())],
            vec![Value::Int(3), Value::Int(15), Value::Text("integer".into())],
            vec![Value::Int(4), Value::Float(1.5), Value::Text("real".into())],
            vec![Value::Int(5), Value::Float(0.0), Value::Text("real".into())],
            vec![Value::Int(6), Value::Null, Value::Text("null".into())],
            vec![Value::Int(7), Value::Float(3.5), Value::Text("real".into())],
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
        result
            .rows
            .iter()
            .map(|row| vec![
                match &row[1] {
                    Value::Int(_) => Value::Text("integer".into()),
                    Value::Float(_) => Value::Text("real".into()),
                    Value::Null => Value::Text("null".into()),
                    other => panic!("unexpected SUM result: {other:?}"),
                },
                row[1].clone(),
                row[2].clone(),
            ])
            .collect::<Vec<_>>()
    );

    let overflow = connection
        .query(
            "SELECT SUM(value) FROM (\
                 SELECT 9223372036854775807 AS value UNION ALL SELECT 1 AS value\
             )",
        )
        .await
        .unwrap_err();
    assert!(overflow.to_string().contains("integer overflow"), "{overflow}");
}

#[tokio::test]
async fn sqlite_avg_any_csv_round_trip_preserves_runtime_storage_classes() {
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
             (1, 7), (1, 9), (2, 1.25), (2, 2.5), \
             (3, '12'), (3, '3'), (4, '1.5'), \
             (5, 'alpha'), (5, X'00FF'), (6, NULL), (6, NULL), \
             (7, 1), (7, 2.5), \
             (8, 9223372036854775807), (8, 1)",
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
            "SELECT group_id AS position, AVG(value) AS result, \
                    typeof(AVG(value)) AS storage_class \
             FROM flexible GROUP BY group_id ORDER BY group_id",
        )
        .await
        .unwrap();
    assert_eq!(result.columns[1].data_type, "NULL");

    let expected = [
        (1, Value::Float(8.0), "real"),
        (2, Value::Float(1.875), "real"),
        (3, Value::Float(7.5), "real"),
        (4, Value::Float(1.5), "real"),
        (5, Value::Float(0.0), "real"),
        (6, Value::Null, "null"),
        (7, Value::Float(1.75), "real"),
        (8, Value::Float((i64::MAX as f64 + 1.0) / 2.0), "real"),
    ];
    let expected_result_rows = expected
        .iter()
        .map(|(group_id, value, storage_class)| {
            vec![
                Value::Int(*group_id),
                value.clone(),
                Value::Text((*storage_class).into()),
            ]
        })
        .collect::<Vec<_>>();
    assert_eq!(result.rows, expected_result_rows);

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
    let expected_restored_rows = expected
        .iter()
        .map(|(_, value, storage_class)| {
            vec![
                Value::Text((*storage_class).into()),
                value.clone(),
                Value::Text((*storage_class).into()),
            ]
        })
        .collect::<Vec<_>>();
    assert_eq!(restored.rows, expected_restored_rows);
}

#[tokio::test]
async fn sqlite_total_any_csv_round_trip_preserves_real_results() {
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
             (1, 7), (1, 9), (2, 1.25), (2, 2.5), \
             (3, '12'), (3, '3'), (4, '1.5'), \
             (5, 'alpha'), (5, X'00FF'), (6, NULL), (6, NULL), \
             (7, 1), (7, 2.5), \
             (8, 9223372036854775807), (8, 1)",
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
            "SELECT group_id AS position, TOTAL(value) AS result, \
                    typeof(TOTAL(value)) AS storage_class \
             FROM flexible GROUP BY group_id ORDER BY group_id",
        )
        .await
        .unwrap();
    assert_eq!(result.columns[1].data_type, "NULL");
    let expected = [
        (1, 16.0),
        (2, 3.75),
        (3, 15.0),
        (4, 1.5),
        (5, 0.0),
        (6, 0.0),
        (7, 3.5),
        (8, i64::MAX as f64 + 1.0),
    ];
    let expected_rows = expected
        .iter()
        .map(|(group_id, value)| vec![Value::Int(*group_id), Value::Float(*value), Value::Text("real".into())])
        .collect::<Vec<_>>();
    assert_eq!(result.rows, expected_rows);

    let empty = connection
        .query("SELECT TOTAL(value), typeof(TOTAL(value)) FROM flexible WHERE group_id = 999")
        .await
        .unwrap();
    assert_eq!(empty.rows, vec![vec![Value::Float(0.0), Value::Text("real".into())]]);

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
        expected
            .iter()
            .map(|(_, value)| vec![
                Value::Text("real".into()),
                Value::Float(*value),
                Value::Text("real".into()),
            ])
            .collect::<Vec<_>>()
    );
}

#[tokio::test]
async fn sqlite_any_arithmetic_csv_round_trip_preserves_runtime_storage_classes() {
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
             (1, 10), (2, 1.5), (3, '42'), (4, '1.5'), \
             (5, 'alpha'), (6, X'00FF'), (7, NULL), \
             (8, 9223372036854775807), (9, 3), (10, 0)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE restored (\
                 id INTEGER PRIMARY KEY, position INTEGER, added ANY, addition_class TEXT, \
                 halved ANY, half_class TEXT, divided_by_zero ANY, zero_class TEXT\
             ) STRICT",
        )
        .await
        .unwrap();

    let result = connection
        .query(
            "SELECT id AS position, value + 1 AS added, typeof(value + 1) AS addition_class, \
                    value / 2 AS halved, typeof(value / 2) AS half_class, \
                    value / 0 AS divided_by_zero, typeof(value / 0) AS zero_class \
             FROM flexible ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(result.columns[1].data_type, "NULL");
    assert_eq!(result.columns[3].data_type, "NULL");
    assert_eq!(result.columns[5].data_type, "NULL");
    let expected_row = |id: i64, added: Value, addition_class: &str, halved: Value, half_class: &str| {
        vec![
            Value::Int(id),
            added,
            Value::Text(addition_class.into()),
            halved,
            Value::Text(half_class.into()),
            Value::Null,
            Value::Text("null".into()),
        ]
    };
    assert_eq!(
        result.rows,
        vec![
            expected_row(1, Value::Int(11), "integer", Value::Int(5), "integer"),
            expected_row(2, Value::Float(2.5), "real", Value::Float(0.75), "real"),
            expected_row(3, Value::Int(43), "integer", Value::Int(21), "integer"),
            expected_row(4, Value::Float(2.5), "real", Value::Float(0.75), "real"),
            expected_row(5, Value::Int(1), "integer", Value::Int(0), "integer"),
            expected_row(6, Value::Int(1), "integer", Value::Int(0), "integer"),
            expected_row(7, Value::Null, "null", Value::Null, "null"),
            expected_row(
                8,
                Value::Float(i64::MAX as f64 + 1.0),
                "real",
                Value::Int(4_611_686_018_427_387_903),
                "integer",
            ),
            expected_row(9, Value::Int(4), "integer", Value::Int(1), "integer"),
            expected_row(10, Value::Int(1), "integer", Value::Int(0), "integer"),
        ]
    );

    sqlite_result_csv_round_trip(
        connection.as_ref(),
        &result,
        "restored",
        &[None, Some(0), Some(1), Some(2), Some(3), Some(4), Some(5), Some(6)],
    )
    .await;

    let restored = connection
        .query(
            "SELECT typeof(added), added, addition_class, typeof(halved), halved, half_class, \
                    typeof(divided_by_zero), divided_by_zero, zero_class \
             FROM restored ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(
        restored.rows,
        result
            .rows
            .iter()
            .map(|row| vec![
                row[2].clone(),
                row[1].clone(),
                row[2].clone(),
                row[4].clone(),
                row[3].clone(),
                row[4].clone(),
                row[6].clone(),
                row[5].clone(),
                row[6].clone(),
            ])
            .collect::<Vec<_>>()
    );
}

#[tokio::test]
async fn sqlite_json_group_array_any_csv_round_trip_preserves_json_null_and_text() {
    use tablepro_core::{ConnectOptions, DatabaseDriver};

    let connection = drivers_sqlite::SqliteDriver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    connection
        .execute("CREATE TABLE groups (id INTEGER PRIMARY KEY) STRICT")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO groups VALUES (1), (2), (3)")
        .await
        .unwrap();
    connection
        .execute("CREATE TABLE flexible (group_id INTEGER, position INTEGER, value ANY) STRICT")
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO flexible VALUES \
             (1, 1, 42), (1, 2, 1.5), (1, 3, '42'), (1, 4, 'NULL'), \
             (1, 5, NULL), (1, 6, ''), (1, 7, '=1+1'), (1, 8, '<tag>&amp;'), \
             (1, 9, '東京'), (2, 1, NULL), (2, 2, NULL)",
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
            "SELECT groups.id AS position, \
                    json_group_array(flexible.value ORDER BY flexible.position) \
                        FILTER (WHERE flexible.position IS NOT NULL) AS result, \
                    typeof(json_group_array(flexible.value ORDER BY flexible.position) \
                        FILTER (WHERE flexible.position IS NOT NULL)) AS storage_class \
             FROM groups LEFT JOIN flexible ON flexible.group_id = groups.id \
             GROUP BY groups.id ORDER BY groups.id",
        )
        .await
        .unwrap();
    assert_eq!(result.columns[1].data_type, "NULL");
    assert_eq!(
        result.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text(r#"[42,1.5,"42","NULL",null,"","=1+1","<tag>&amp;","東京"]"#.into()),
                Value::Text("text".into()),
            ],
            vec![
                Value::Int(2),
                Value::Text("[null,null]".into()),
                Value::Text("text".into()),
            ],
            vec![
                Value::Int(3),
                Value::Text("[]".into()),
                Value::Text("text".into()),
            ],
        ]
    );
    let json: serde_json::Value = serde_json::from_str(&tablepro_core::export::render_json(
        &result.columns,
        &result.rows,
    ))
    .unwrap();
    assert_eq!(json[0]["result"], r#"[42,1.5,"42","NULL",null,"","=1+1","<tag>&amp;","東京"]"#);
    assert_eq!(json[1]["result"], "[null,null]");
    assert_eq!(json[2]["result"], "[]");

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
        result
            .rows
            .iter()
            .map(|row| vec![Value::Text("text".into()), row[1].clone(), Value::Text("text".into())])
            .collect::<Vec<_>>()
    );
}

#[tokio::test]
async fn sqlite_json_group_object_any_csv_round_trip_preserves_native_text() {
    use tablepro_core::{ConnectOptions, DatabaseDriver};

    let connection = drivers_sqlite::SqliteDriver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    connection
        .execute("CREATE TABLE groups (id INTEGER PRIMARY KEY) STRICT")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO groups VALUES (1), (2), (3)")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE flexible (group_id INTEGER, position INTEGER, key ANY, value ANY) STRICT",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO flexible VALUES \
             (1, 1, 'a', 42), (1, 2, 'a', NULL), (1, 3, NULL, 2), \
             (1, 4, '', '=1+1'), (1, 5, '東京', 'NULL'), (1, 6, 'sqlnull', NULL), \
             (2, 1, 'nil', NULL)",
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

    let version = connection.query("SELECT sqlite_version()").await.unwrap();
    let Value::Text(version) = &version.rows[0][0] else {
        panic!("SQLite version must be text: {:?}", version.rows[0][0]);
    };
    let mut parts = version.split('.').map(|part| part.parse::<u32>().unwrap());
    let version = (
        parts.next().expect("SQLite major version"),
        parts.next().expect("SQLite minor version"),
        parts.next().expect("SQLite patch version"),
    );
    assert!(parts.next().is_none(), "unexpected SQLite version format");
    // SQLite 3.50.0 fixed NULL labels. Earlier system versions emit malformed
    // JSON for that row; as a database client, BookiE must preserve that text.
    let expected_first_result = if version >= (3, 50, 0) {
        r#"{"a":42,"a":null,"":"=1+1","東京":"NULL","sqlnull":null}"#
    } else {
        r#"{"a":42,"a":null,:2,"":"=1+1","東京":"NULL","sqlnull":null}"#
    };

    let result = connection
        .query(
            "SELECT groups.id AS position, \
                    json_group_object(flexible.key, flexible.value ORDER BY flexible.position) \
                        FILTER (WHERE flexible.position IS NOT NULL) AS result, \
                    typeof(json_group_object(flexible.key, flexible.value ORDER BY flexible.position) \
                        FILTER (WHERE flexible.position IS NOT NULL)) AS storage_class \
             FROM groups LEFT JOIN flexible ON flexible.group_id = groups.id \
             GROUP BY groups.id ORDER BY groups.id",
        )
        .await
        .unwrap();
    assert_eq!(result.columns[1].data_type, "NULL");
    assert_eq!(
        result.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text(expected_first_result.into()),
                Value::Text("text".into()),
            ],
            vec![Value::Int(2), Value::Text(r#"{"nil":null}"#.into()), Value::Text("text".into())],
            vec![Value::Int(3), Value::Text("{}".into()), Value::Text("text".into())],
        ],
        "SQLite {version:?} native aggregate output must be preserved"
    );
    let json: serde_json::Value = serde_json::from_str(&tablepro_core::export::render_json(
        &result.columns,
        &result.rows,
    ))
    .unwrap();
    assert_eq!(json[0]["result"], expected_first_result);
    assert_eq!(json[1]["result"], r#"{"nil":null}"#);
    assert_eq!(json[2]["result"], "{}");

    let directory = tempfile::tempdir().unwrap();
    let workbook_path = directory.path().join("sqlite-json-object-any.xlsx");
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
    std::io::Read::read_to_string(&mut archive.by_name("xl/worksheets/sheet1.xml").unwrap(), &mut sheet)
        .unwrap();
    let mut shared_strings = String::new();
    std::io::Read::read_to_string(&mut archive.by_name("xl/sharedStrings.xml").unwrap(), &mut shared_strings)
        .unwrap();
    for row in 2..=4 {
        assert!(sheet.contains(&format!("<c r=\"B{row}\" t=\"s\">")), "{sheet}");
    }
    assert!(shared_strings.contains(expected_first_result));
    assert!(shared_strings.contains(r#"{"nil":null}"#));
    assert!(shared_strings.contains("{}"));
    assert!(!sheet.contains("<f>"), "{sheet}");

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
        result
            .rows
            .iter()
            .map(|row| vec![Value::Text("text".into()), row[1].clone(), Value::Text("text".into())])
            .collect::<Vec<_>>()
    );
}

#[tokio::test]
async fn sqlite_json_extract_any_csv_round_trip_preserves_runtime_storage_classes() {
    use tablepro_core::{ConnectOptions, DatabaseDriver};

    let connection = drivers_sqlite::SqliteDriver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    connection
        .execute("CREATE TABLE flexible (id INTEGER PRIMARY KEY, document ANY) STRICT")
        .await
        .unwrap();
    connection
        .execute(
            r#"INSERT INTO flexible VALUES
                 (1, '{"v":9223372036854775807}'),
                 (2, '{"v":1.25}'),
                 (3, '{"v":"42"}'),
                 (4, '{"v":true}'),
                 (5, '{"v":null}'),
                 (6, '{"v":{"x":1}}'),
                 (7, '{"v":[1,2]}'),
                 (8, '{"v":"bookie:sqlite-any:v1:integer:9"}'),
                 (9, '{}')"#,
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE restored (\
                 id INTEGER PRIMARY KEY, position INTEGER, result ANY, \
                 storage_class TEXT, json_kind TEXT\
             ) STRICT",
        )
        .await
        .unwrap();

    let result = connection
        .query(
            "SELECT id AS position, json_extract(document, '$.v') AS result, \
                    typeof(json_extract(document, '$.v')) AS storage_class, \
                    json_type(document, '$.v') AS json_kind \
             FROM flexible ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(result.columns[1].data_type, "NULL");
    assert_eq!(
        result.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Int(i64::MAX),
                Value::Text("integer".into()),
                Value::Text("integer".into()),
            ],
            vec![
                Value::Int(2),
                Value::Float(1.25),
                Value::Text("real".into()),
                Value::Text("real".into()),
            ],
            vec![
                Value::Int(3),
                Value::Text("42".into()),
                Value::Text("text".into()),
                Value::Text("text".into()),
            ],
            vec![
                Value::Int(4),
                Value::Int(1),
                Value::Text("integer".into()),
                Value::Text("true".into()),
            ],
            vec![
                Value::Int(5),
                Value::Null,
                Value::Text("null".into()),
                Value::Text("null".into()),
            ],
            vec![
                Value::Int(6),
                Value::Text("{\"x\":1}".into()),
                Value::Text("text".into()),
                Value::Text("object".into()),
            ],
            vec![
                Value::Int(7),
                Value::Text("[1,2]".into()),
                Value::Text("text".into()),
                Value::Text("array".into()),
            ],
            vec![
                Value::Int(8),
                Value::Text("bookie:sqlite-any:v1:integer:9".into()),
                Value::Text("text".into()),
                Value::Text("text".into()),
            ],
            vec![Value::Int(9), Value::Null, Value::Text("null".into()), Value::Null,],
        ]
    );

    let directory = tempfile::tempdir().unwrap();
    let json_path = directory.path().join("sqlite-json-extract-any.json");
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
    assert_eq!(json[0]["result"], i64::MAX);
    assert_eq!(json[1]["result"], 1.25);
    assert_eq!(json[2]["result"], "42");
    assert_eq!(json[3]["result"], 1);
    assert!(json[4]["result"].is_null());
    assert_eq!(json[5]["result"], "{\"x\":1}");
    assert_eq!(json[6]["result"], "[1,2]");
    assert_eq!(json[7]["result"], "bookie:sqlite-any:v1:integer:9");
    assert!(json[8]["result"].is_null());
    assert_eq!(json[4]["json_kind"], "null");
    assert!(json[8]["json_kind"].is_null());

    let xlsx_path = directory.path().join("sqlite-json-extract-any.xlsx");
    tablepro_core::export::write_result_file(
        &xlsx_path,
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
    let mut archive = zip::ZipArchive::new(std::fs::File::open(xlsx_path).unwrap()).unwrap();
    let mut sheet = String::new();
    std::io::Read::read_to_string(&mut archive.by_name("xl/worksheets/sheet1.xml").unwrap(), &mut sheet).unwrap();
    let mut shared_strings = String::new();
    std::io::Read::read_to_string(
        &mut archive.by_name("xl/sharedStrings.xml").unwrap(),
        &mut shared_strings,
    )
    .unwrap();
    assert!(sheet.contains("<c r=\"B2\" t=\"s\">"), "{sheet}");
    assert!(sheet.contains("<c r=\"B3\"><v>1.25</v></c>"), "{sheet}");
    assert!(sheet.contains("<c r=\"B4\" t=\"s\">"), "{sheet}");
    assert!(sheet.contains("<c r=\"B5\"><v>1</v></c>"), "{sheet}");
    for text in [
        "9223372036854775807",
        "42",
        "{\"x\":1}",
        "[1,2]",
        "bookie:sqlite-any:v1:integer:9",
    ] {
        assert!(shared_strings.contains(&format!("<t>{text}</t>")), "{shared_strings}");
    }
    assert!(!sheet.contains("<f>"), "{sheet}");

    sqlite_result_csv_round_trip(
        connection.as_ref(),
        &result,
        "restored",
        &[None, Some(0), Some(1), Some(2), Some(3)],
    )
    .await;

    let restored = connection
        .query("SELECT typeof(result), result, storage_class, json_kind FROM restored ORDER BY id")
        .await
        .unwrap();
    assert_eq!(
        restored.rows,
        vec![
            vec![
                Value::Text("integer".into()),
                Value::Int(i64::MAX),
                Value::Text("integer".into()),
                Value::Text("integer".into()),
            ],
            vec![
                Value::Text("real".into()),
                Value::Float(1.25),
                Value::Text("real".into()),
                Value::Text("real".into()),
            ],
            vec![
                Value::Text("text".into()),
                Value::Text("42".into()),
                Value::Text("text".into()),
                Value::Text("text".into()),
            ],
            vec![
                Value::Text("integer".into()),
                Value::Int(1),
                Value::Text("integer".into()),
                Value::Text("true".into()),
            ],
            vec![
                Value::Text("null".into()),
                Value::Null,
                Value::Text("null".into()),
                Value::Text("null".into()),
            ],
            vec![
                Value::Text("text".into()),
                Value::Text("{\"x\":1}".into()),
                Value::Text("text".into()),
                Value::Text("object".into()),
            ],
            vec![
                Value::Text("text".into()),
                Value::Text("[1,2]".into()),
                Value::Text("text".into()),
                Value::Text("array".into()),
            ],
            vec![
                Value::Text("text".into()),
                Value::Text("bookie:sqlite-any:v1:integer:9".into()),
                Value::Text("text".into()),
                Value::Text("text".into()),
            ],
            vec![
                Value::Text("null".into()),
                Value::Null,
                Value::Text("null".into()),
                Value::Null,
            ],
        ]
    );
}

#[tokio::test]
async fn sqlite_json_quote_any_csv_round_trip_keeps_json_text_distinct_from_null() {
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
             (1, NULL), (2, ''), (3, 'NULL'), (4, '=1+1'), (5, '東京'), \
             (6, 7), (7, 1.5), (8, 'line' || char(10) || '\"quoted\",text')",
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
            "SELECT id AS position, json_quote(value) AS result, \
                    typeof(json_quote(value)) AS storage_class \
             FROM flexible ORDER BY id",
        )
        .await
        .unwrap();
    let expected = [
        "null",
        "\"\"",
        "\"NULL\"",
        "\"=1+1\"",
        "\"東京\"",
        "7",
        "1.5",
        r#""line\n\"quoted\",text""#,
    ]
        .into_iter()
        .enumerate()
        .map(|(index, quoted)| {
            vec![
                Value::Int(index as i64 + 1),
                Value::Text(quoted.into()),
                Value::Text("text".into()),
            ]
        })
        .collect::<Vec<_>>();
    assert_eq!(result.columns[1].data_type, "NULL");
    assert_eq!(result.rows, expected);
    let json: serde_json::Value = serde_json::from_str(&tablepro_core::export::render_json(
        &result.columns,
        &result.rows,
    ))
    .unwrap();
    assert_eq!(json[0]["result"], "null");
    assert!(json[0]["result"].is_string());
    assert_eq!(json[5]["result"], "7");
    assert!(json[5]["result"].is_string());

    sqlite_result_csv_round_trip(connection.as_ref(), &result, "restored", &[None, Some(0), Some(1), Some(2)])
        .await;
    let restored = connection
        .query("SELECT typeof(result), result, storage_class FROM restored ORDER BY id")
        .await
        .unwrap();
    assert_eq!(
        restored.rows,
        expected
            .into_iter()
            .map(|row| vec![Value::Text("text".into()), row[1].clone(), Value::Text("text".into())])
            .collect::<Vec<_>>()
    );
}
