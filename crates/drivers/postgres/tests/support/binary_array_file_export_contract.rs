#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::Value;

use crate::{connect, start_pg};

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_bytea_array_escape_output_rebinds_across_output_settings() {
    let (_container, options) = start_pg().await;
    let connection = connect(options).await;
    let mut transaction = connection.begin().await.unwrap();
    transaction.execute("SET LOCAL bytea_output = 'escape'").await.unwrap();
    let output_setting = transaction
        .query("SELECT current_setting('bytea_output')")
        .await
        .unwrap();
    assert_eq!(output_setting.rows[0][0], Value::Text("escape".into()));
    let expression = "ARRAY[decode('00ff275c', 'hex'), decode('', 'hex'), NULL::bytea]::bytea[]";
    let result = transaction
        .query(&format!("SELECT {expression}::text AS value"))
        .await
        .unwrap();
    assert_eq!(result.columns[0].data_type, "TEXT");
    let Value::Text(array_text) = &result.rows[0][0] else {
        panic!("escape-format bytea[] must remain text: {:?}", result.rows[0][0]);
    };

    let native = transaction
        .query(&format!(
            "SELECT pg_typeof({expression})::text, {expression}::text, \
                    array_to_json({expression})::text, encode(array_send({expression}), 'hex')"
        ))
        .await
        .unwrap();
    assert_eq!(native.rows[0][0], Value::Text("bytea[]".into()));
    assert_eq!(native.rows[0][1], Value::Text(array_text.clone()));
    assert!(
        array_text.contains("\\\\000"),
        "escape-form bytea array text: {array_text:?}"
    );
    assert!(
        array_text.contains("\\\\377"),
        "escape-form bytea array text: {array_text:?}"
    );

    let bytes = transaction
        .query(&format!(
            "SELECT ord::bigint, encode(element, 'hex') \
             FROM unnest({expression}) WITH ORDINALITY AS items(element, ord) ORDER BY ord"
        ))
        .await
        .unwrap();
    assert_eq!(
        bytes.rows,
        vec![
            vec![Value::Int(1), Value::Text("00ff275c".into())],
            vec![Value::Int(2), Value::Text(String::new())],
            vec![Value::Int(3), Value::Null],
        ]
    );

    let rebound = transaction
        .query_params(
            "SELECT array_to_json($1::text::bytea[])::text, \
                    encode(array_send($1::text::bytea[]), 'hex')",
            std::slice::from_ref(&result.rows[0][0]),
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0], native.rows[0][2..4]);

    transaction.execute("SET LOCAL bytea_output = 'hex'").await.unwrap();
    let output_setting = transaction
        .query("SELECT current_setting('bytea_output')")
        .await
        .unwrap();
    assert_eq!(output_setting.rows[0][0], Value::Text("hex".into()));
    let rebound_after_switch = transaction
        .query_params(
            "SELECT pg_typeof($1::text::bytea[])::text, \
                    encode(array_send($1::text::bytea[]), 'hex')",
            std::slice::from_ref(&result.rows[0][0]),
        )
        .await
        .unwrap();
    assert_eq!(rebound_after_switch.rows[0][0], Value::Text("bytea[]".into()));
    assert_eq!(rebound_after_switch.rows[0][1], native.rows[0][3]);
    transaction.rollback().await.unwrap();
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_bytea_array_file_exports_preserve_binary_elements() {
    let (_container, options) = start_pg().await;
    let connection = connect(options).await;
    let expression = "ARRAY[decode('00ff275c', 'hex'), decode('', 'hex'), NULL::bytea]::bytea[]";
    let result = connection
        .query(&format!("SELECT {expression} AS value"))
        .await
        .unwrap();
    assert_eq!(result.columns[0].data_type, "BYTEA[]");
    let Value::Text(array_text) = &result.rows[0][0] else {
        panic!("bytea[] must remain exact text: {:?}", result.rows[0][0]);
    };

    let native = connection
        .query(&format!(
            "SELECT pg_typeof({expression})::text, {expression}::text, \
                    array_to_json({expression})::text, encode(array_send({expression}), 'hex')"
        ))
        .await
        .unwrap();
    assert_eq!(native.rows[0][0], Value::Text("bytea[]".into()));
    assert_eq!(result.rows[0][0], native.rows[0][1]);
    let bytes = connection
        .query(&format!(
            "SELECT ord::bigint, encode(element, 'hex') \
             FROM unnest({expression}) WITH ORDINALITY AS items(element, ord) ORDER BY ord"
        ))
        .await
        .unwrap();
    assert_eq!(
        bytes.rows,
        vec![
            vec![Value::Int(1), Value::Text("00ff275c".into())],
            vec![Value::Int(2), Value::Text(String::new())],
            vec![Value::Int(3), Value::Null],
        ]
    );

    let rebound = connection
        .query_params(
            "SELECT array_to_json($1::text::bytea[])::text, \
                    encode(array_send($1::text::bytea[]), 'hex')",
            std::slice::from_ref(&result.rows[0][0]),
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0], native.rows[0][2..4]);

    let directory = tempfile::tempdir().unwrap();
    let options = tablepro_core::export::CsvOptions::default();
    let json_path = directory.path().join("bytea-array.json");
    tablepro_core::export::write_result_file(
        &json_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Json,
            csv: &options,
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap();
    let json: serde_json::Value = serde_json::from_slice(&std::fs::read(json_path).unwrap()).unwrap();
    assert_eq!(json[0]["value"], array_text.as_str());

    let csv_path = directory.path().join("bytea-array.csv");
    tablepro_core::export::write_result_file(
        &csv_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Csv,
            csv: &options,
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap();
    let mut csv = csv::Reader::from_path(csv_path).unwrap();
    assert_eq!(csv.headers().unwrap().iter().collect::<Vec<_>>(), ["value"]);
    assert_eq!(&csv.records().next().unwrap().unwrap()[0], array_text);

    let xlsx_path = directory.path().join("bytea-array.xlsx");
    tablepro_core::export::write_result_file(
        &xlsx_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Xlsx,
            csv: &options,
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap();
    if let Some(path) = std::env::var_os("BOOKIEE_XLSX_REIMPORT_ARTIFACT") {
        std::fs::copy(&xlsx_path, path).unwrap();
    }
    let mut archive = zip::ZipArchive::new(std::fs::File::open(xlsx_path).unwrap()).unwrap();
    let mut sheet = String::new();
    std::io::Read::read_to_string(&mut archive.by_name("xl/worksheets/sheet1.xml").unwrap(), &mut sheet).unwrap();
    let mut shared = String::new();
    std::io::Read::read_to_string(&mut archive.by_name("xl/sharedStrings.xml").unwrap(), &mut shared).unwrap();
    assert!(sheet.contains("<c r=\"A2\" t=\"s\">"), "{sheet}");
    assert!(shared.contains(array_text), "{shared}");
    assert!(!sheet.contains("<f>"), "{sheet}");

    connection
        .execute("CREATE TABLE bytea_array_filewriter_target (value bytea[])")
        .await
        .unwrap();
    let sql_path = directory.path().join("bytea-array.sql");
    tablepro_core::export::write_result_file(
        &sql_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Sql,
            csv: &options,
            sql: Some(tablepro_core::export::SqlTarget {
                driver_id: "postgres",
                schema: None,
                table: "bytea_array_filewriter_target",
            }),
        },
        || false,
        |_| {},
    )
    .unwrap();
    connection
        .execute(&std::fs::read_to_string(sql_path).unwrap())
        .await
        .unwrap();
    let restored = connection
        .query(
            "SELECT pg_typeof(value)::text, value::text, array_to_json(value)::text, \
                    encode(array_send(value), 'hex') FROM bytea_array_filewriter_target",
        )
        .await
        .unwrap();
    assert_eq!(restored.rows, native.rows);
}
