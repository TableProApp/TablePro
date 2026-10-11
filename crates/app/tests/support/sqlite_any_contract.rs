use super::parse_input_for_grid_cell;
use tablepro_core::Value;

async fn sqlite_result_csv_round_trip(
    connection: &dyn tablepro_core::Connection,
    result: &tablepro_core::QueryResult,
    target_table: &str,
    mapping: &[Option<usize>],
) {
    use tablepro_core::{
        export::{CsvOptions, ResultExport, ResultFormat, unique_csv_null_marker, write_result_file},
        import::{CsvImportOptions, ImportTarget, build_insert_plan, read_csv},
    };

    let null_marker = unique_csv_null_marker(&result.rows);
    let options = CsvOptions {
        null_to_empty: false,
        null_marker: Some(null_marker.clone()),
        preserve_sqlite_result_types: true,
        ..CsvOptions::default()
    };
    let directory = tempfile::tempdir().unwrap();
    let csv_path = directory.path().join("sqlite-result.csv");
    write_result_file(
        &csv_path,
        result,
        &ResultExport {
            format: ResultFormat::Csv,
            csv: &options,
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap();
    let csv = std::fs::read(&csv_path).unwrap();
    let sheet = read_csv(
        &csv,
        &CsvImportOptions {
            has_header: true,
            null_marker: null_marker.clone(),
            ..CsvImportOptions::default()
        },
        None,
    )
    .unwrap();
    let target_columns = connection.fetch_columns(None, target_table).await.unwrap();
    let plan = build_insert_plan(
        &ImportTarget {
            driver_id: "sqlite",
            schema: None,
            table: target_table,
            columns: &target_columns,
            mapping,
        },
        &sheet,
        &CsvImportOptions {
            has_header: true,
            null_marker,
            ..CsvImportOptions::default()
        },
    )
    .unwrap();
    for row in &plan.rows {
        connection.execute_params(&plan.statement, row).await.unwrap();
    }
}

include!("sqlite_any_contract/table_and_compound.rs");
include!("sqlite_any_contract/computed_csv.rs");
include!("sqlite_any_contract/iif_csv.rs");
include!("sqlite_any_contract/aggregate_csv.rs");
include!("sqlite_any_contract/json_each_csv.rs");
#[tokio::test]
async fn sqlite_cast_blob_any_csv_round_trip_preserves_computed_bytes() {
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
             (1, 42), (2, 1.5), (3, '42'), (4, ''), (5, X'00FF'), \
             (6, 'not numeric'), (7, NULL)",
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
            "SELECT id AS position, CAST(value AS BLOB) AS result, \
                    typeof(CAST(value AS BLOB)) AS storage_class, \
                    hex(CAST(value AS BLOB)) AS bytes \
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
                Value::Bytes(b"42".to_vec()),
                Value::Text("blob".into()),
                Value::Text("3432".into())
            ],
            vec![
                Value::Int(2),
                Value::Bytes(b"1.5".to_vec()),
                Value::Text("blob".into()),
                Value::Text("312E35".into())
            ],
            vec![
                Value::Int(3),
                Value::Bytes(b"42".to_vec()),
                Value::Text("blob".into()),
                Value::Text("3432".into())
            ],
            vec![
                Value::Int(4),
                Value::Bytes(vec![]),
                Value::Text("blob".into()),
                Value::Text(String::new())
            ],
            vec![
                Value::Int(5),
                Value::Bytes(vec![0x00, 0xff]),
                Value::Text("blob".into()),
                Value::Text("00FF".into())
            ],
            vec![
                Value::Int(6),
                Value::Bytes(b"not numeric".to_vec()),
                Value::Text("blob".into()),
                Value::Text("6E6F74206E756D65726963".into()),
            ],
            vec![
                Value::Int(7),
                Value::Null,
                Value::Text("null".into()),
                Value::Text(String::new())
            ],
        ]
    );

    let consumer_result = connection
        .query(
            "SELECT id AS position, CAST(value AS BLOB) AS result, \
                    typeof(CAST(value AS BLOB)) AS storage_class \
             FROM flexible ORDER BY id",
        )
        .await
        .unwrap();
    let directory = tempfile::tempdir().unwrap();
    let json_path = directory.path().join("sqlite-cast-blob-any.json");
    tablepro_core::export::write_result_file(
        &json_path,
        &consumer_result,
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
    let expected_json = [
        "\\x3432",
        "\\x312e35",
        "\\x3432",
        "\\x",
        "\\x00ff",
        "\\x6e6f74206e756d65726963",
    ];
    for (row, value) in json.as_array().unwrap().iter().zip(expected_json) {
        assert_eq!(row["result"], value);
        assert_eq!(row["storage_class"], "blob");
    }
    assert!(json[6]["result"].is_null());
    assert_eq!(json[6]["storage_class"], "null");

    let xlsx_path = directory.path().join("sqlite-cast-blob-any.xlsx");
    tablepro_core::export::write_result_file(
        &xlsx_path,
        &consumer_result,
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
    for row in 2..=7 {
        assert!(sheet.contains(&format!("<c r=\"B{row}\" t=\"s\">")), "{sheet}");
    }
    for value in ["\\x3432", "\\x312e35", "\\x", "\\x00ff", "\\x6e6f74206e756d65726963"] {
        assert!(shared_strings.contains(&format!("<t>{value}</t>")), "{shared_strings}");
    }
    assert!(!sheet.contains("<c r=\"B8\""), "{sheet}");
    assert!(!sheet.contains("<f>"), "{sheet}");

    sqlite_result_csv_round_trip(
        connection.as_ref(),
        &result,
        "restored",
        &[None, Some(0), Some(1), Some(2), Some(3)],
    )
    .await;

    let restored = connection
        .query(
            "SELECT position, typeof(result), result, storage_class, bytes, hex(result) \
             FROM restored ORDER BY position",
        )
        .await
        .unwrap();
    assert_eq!(
        restored.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("blob".into()),
                Value::Bytes(b"42".to_vec()),
                Value::Text("blob".into()),
                Value::Text("3432".into()),
                Value::Text("3432".into())
            ],
            vec![
                Value::Int(2),
                Value::Text("blob".into()),
                Value::Bytes(b"1.5".to_vec()),
                Value::Text("blob".into()),
                Value::Text("312E35".into()),
                Value::Text("312E35".into())
            ],
            vec![
                Value::Int(3),
                Value::Text("blob".into()),
                Value::Bytes(b"42".to_vec()),
                Value::Text("blob".into()),
                Value::Text("3432".into()),
                Value::Text("3432".into())
            ],
            vec![
                Value::Int(4),
                Value::Text("blob".into()),
                Value::Bytes(vec![]),
                Value::Text("blob".into()),
                Value::Text(String::new()),
                Value::Text(String::new())
            ],
            vec![
                Value::Int(5),
                Value::Text("blob".into()),
                Value::Bytes(vec![0x00, 0xff]),
                Value::Text("blob".into()),
                Value::Text("00FF".into()),
                Value::Text("00FF".into())
            ],
            vec![
                Value::Int(6),
                Value::Text("blob".into()),
                Value::Bytes(b"not numeric".to_vec()),
                Value::Text("blob".into()),
                Value::Text("6E6F74206E756D65726963".into()),
                Value::Text("6E6F74206E756D65726963".into()),
            ],
            vec![
                Value::Int(7),
                Value::Text("null".into()),
                Value::Null,
                Value::Text("null".into()),
                Value::Text(String::new()),
                Value::Text(String::new())
            ],
        ]
    );
}
include!("sqlite_any_contract/length_csv.rs");
