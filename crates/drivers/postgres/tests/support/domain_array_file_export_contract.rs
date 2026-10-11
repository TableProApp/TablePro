#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::Value;

use crate::{connect, start_pg};

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_domain_enum_array_file_exports_preserve_values_and_native_type() {
    let (_container, options) = start_pg().await;
    let connection = connect(options).await;
    connection
        .execute("CREATE SCHEMA domain_array_file_export")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE domain_array_file_export.label AS ENUM \
             ('NULL', '', '東京', 'a,b', 'a\"b', '<tag>&', '=1+1', 'sibling', 'forbidden')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE DOMAIN domain_array_file_export.label_domain \
             AS domain_array_file_export.label CHECK (VALUE <> 'forbidden')",
        )
        .await
        .unwrap();

    let expression = "ARRAY[\
        'NULL'::domain_array_file_export.label_domain, \
        ''::domain_array_file_export.label_domain, \
        '東京'::domain_array_file_export.label_domain, \
        'a,b'::domain_array_file_export.label_domain, \
        'a\"b'::domain_array_file_export.label_domain, \
        '<tag>&'::domain_array_file_export.label_domain, \
        '=1+1'::domain_array_file_export.label_domain, \
        NULL::domain_array_file_export.label_domain\
    ]";
    let result = connection
        .query(&format!("SELECT {expression} AS value"))
        .await
        .unwrap();
    assert_eq!(result.columns[0].data_type, "domain_array_file_export.label_domain[]");
    let Value::Text(array_text) = &result.rows[0][0] else {
        panic!(
            "domain-over-enum array result must remain text: {:?}",
            result.rows[0][0]
        );
    };
    let native = connection
        .query(&format!(
            "SELECT pg_typeof({expression})::text, {expression}::text, \
                    array_to_json({expression})::text, encode(array_send({expression}), 'hex')"
        ))
        .await
        .unwrap();
    assert_eq!(
        native.rows[0][0],
        Value::Text("domain_array_file_export.label_domain[]".into())
    );
    let Value::Text(native_json) = &native.rows[0][2] else {
        panic!("array_to_json oracle returned {:?}", native.rows[0][2]);
    };
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(native_json).unwrap(),
        serde_json::json!(["NULL", "", "東京", "a,b", "a\"b", "<tag>&", "=1+1", null])
    );
    let rebound = connection
        .query_params(
            "SELECT array_to_json($1::text::domain_array_file_export.label_domain[])::text, \
                    encode(array_send($1::text::domain_array_file_export.label_domain[]), 'hex')",
            std::slice::from_ref(&result.rows[0][0]),
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0], native.rows[0][2..4]);

    let directory = tempfile::tempdir().unwrap();
    let csv = tablepro_core::export::CsvOptions::default();
    for (extension, format, marker) in [
        ("xml", tablepro_core::export::ResultFormat::Xml, "&lt;tag&gt;&amp;"),
        ("html", tablepro_core::export::ResultFormat::Html, "&lt;tag&gt;&amp;"),
        ("md", tablepro_core::export::ResultFormat::Markdown, "&lt;tag&gt;&amp;"),
    ] {
        let path = directory.path().join(format!("domain-array.{extension}"));
        tablepro_core::export::write_result_file(
            &path,
            &result,
            &tablepro_core::export::ResultExport {
                format,
                csv: &csv,
                sql: None,
            },
            || false,
            |_| {},
        )
        .unwrap();
        let output = std::fs::read_to_string(path).unwrap();
        assert!(output.contains(marker), "{extension}: {output}");
        assert!(!output.contains("<tag>&"), "{extension}: {output}");
        assert!(output.contains("東京"), "{extension}: {output}");
        assert!(output.contains("NULL"), "{extension}: {output}");
    }

    let json_path = directory.path().join("domain-array.json");
    tablepro_core::export::write_result_file(
        &json_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Json,
            csv: &csv,
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap();
    let json: serde_json::Value = serde_json::from_slice(&std::fs::read(json_path).unwrap()).unwrap();
    assert_eq!(json[0]["value"], array_text.as_str());

    let csv_path = directory.path().join("domain-array.csv");
    tablepro_core::export::write_result_file(
        &csv_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Csv,
            csv: &csv,
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap();
    let mut csv_file = csv::Reader::from_path(csv_path).unwrap();
    assert_eq!(csv_file.headers().unwrap().iter().collect::<Vec<_>>(), ["value"]);
    assert_eq!(&csv_file.records().next().unwrap().unwrap()[0], array_text);

    let xlsx_path = std::env::var_os("BOOKIEE_XLSX_REIMPORT_ARTIFACT")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| directory.path().join("domain-array.xlsx"));
    tablepro_core::export::write_result_file(
        &xlsx_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Xlsx,
            csv: &csv,
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap();
    let mut workbook = zip::ZipArchive::new(std::fs::File::open(xlsx_path).unwrap()).unwrap();
    let mut sheet = String::new();
    std::io::Read::read_to_string(&mut workbook.by_name("xl/worksheets/sheet1.xml").unwrap(), &mut sheet).unwrap();
    let mut strings = String::new();
    std::io::Read::read_to_string(&mut workbook.by_name("xl/sharedStrings.xml").unwrap(), &mut strings).unwrap();
    assert!(sheet.contains("<c r=\"A2\" t=\"s\">"), "{sheet}");
    assert!(
        strings.contains(
            &array_text
                .replace('&', "&amp;")
                .replace('<', "&lt;")
                .replace('>', "&gt;")
        )
    );
    assert!(!sheet.contains("<f>"), "{sheet}");

    connection
        .execute(
            "CREATE TABLE domain_array_file_export.target \
             (value domain_array_file_export.label_domain[])",
        )
        .await
        .unwrap();
    let sql_path = directory.path().join("domain-array.sql");
    tablepro_core::export::write_result_file(
        &sql_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Sql,
            csv: &csv,
            sql: Some(tablepro_core::export::SqlTarget {
                driver_id: "postgres",
                schema: Some("domain_array_file_export"),
                table: "target",
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
                    encode(array_send(value), 'hex') \
             FROM domain_array_file_export.target",
        )
        .await
        .unwrap();
    assert_eq!(restored.rows, native.rows);
}
