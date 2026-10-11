#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_xml_array_file_exports_preserve_native_text() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    let expression = "ARRAY[XMLPARSE(CONTENT '<a>one,two</a>'), \
        XMLPARSE(CONTENT '<b attr=\"quoted\">東京 &amp; 😀</b>'), NULL]::xml[]";
    let result = connection
        .query(&format!("SELECT {expression} AS value"))
        .await
        .unwrap();
    assert_array_value("xml[]", &result);

    let oracle = connection
        .query(&format!(
            "SELECT pg_typeof({expression})::text, {expression}::text, \
             array_to_json({expression})::text, encode(array_send({expression}), 'hex')"
    ))
        .await
        .unwrap();
    assert_eq!(oracle.rows[0][0], Value::Text("xml[]".into()));
    assert_eq!(result.rows[0][0], oracle.rows[0][1]);
    let Value::Text(native_json) = &oracle.rows[0][2] else {
        panic!("native array_to_json returned {:?}", oracle.rows[0][2]);
    };
    let Value::Text(driver_text) = &result.rows[0][0] else {
        panic!("xml[] result must remain text: {:?}", result.rows[0][0]);
    };
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(native_json).unwrap(),
        serde_json::json!(["<a>one,two</a>", "<b attr=\"quoted\">東京 &amp; 😀</b>", null])
    );
    let rebound = connection
        .query_params(
            "SELECT array_to_json($1::text::xml[])::text, encode(array_send($1::text::xml[]), 'hex')",
            std::slice::from_ref(&result.rows[0][0]),
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0][0], oracle.rows[0][2]);
    assert_eq!(rebound.rows[0][1], oracle.rows[0][3]);

    let directory = tempfile::tempdir().unwrap();
    let csv_options = tablepro_core::export::CsvOptions::default();
    let json_path = directory.path().join("xml-array.json");
    tablepro_core::export::write_result_file(
        &json_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Json,
            csv: &csv_options,
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap();
    let json: serde_json::Value = serde_json::from_slice(&std::fs::read(json_path).unwrap()).unwrap();
    assert_eq!(json[0]["value"], *driver_text);

    let csv_path = directory.path().join("xml-array.csv");
    tablepro_core::export::write_result_file(
        &csv_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Csv,
            csv: &csv_options,
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap();
    let mut csv = csv::Reader::from_path(csv_path).unwrap();
    assert_eq!(&csv.records().next().unwrap().unwrap()[0], driver_text);

    for (format, extension, escaped) in [
        (
            tablepro_core::export::ResultFormat::Xml,
            "xml",
            driver_text
                .replace('&', "&amp;")
                .replace('<', "&lt;")
                .replace('>', "&gt;")
                .replace('"', "&quot;")
                .replace('\'', "&apos;"),
        ),
        (
            tablepro_core::export::ResultFormat::Html,
            "html",
            driver_text
                .replace('&', "&amp;")
                .replace('<', "&lt;")
                .replace('>', "&gt;")
                .replace('"', "&quot;")
                .replace('\'', "&#39;"),
        ),
    ] {
        let path = directory.path().join(format!("xml-array.{extension}"));
        tablepro_core::export::write_result_file(
            &path,
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
        let output = std::fs::read_to_string(path).unwrap();
        assert!(output.contains(&escaped), "{extension}: {output}");
        assert!(!output.contains("<a>one,two</a>"), "{extension}: {output}");
    }

    let markdown_path = directory.path().join("xml-array.md");
    tablepro_core::export::write_result_file(
        &markdown_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Markdown,
            csv: &csv_options,
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap();
    let markdown = std::fs::read_to_string(markdown_path).unwrap();
    assert!(markdown.contains("&lt;a&gt;one,two&lt;/a&gt;"), "{markdown}");
    assert!(markdown.contains("東京"), "{markdown}");

    let xlsx_path = directory.path().join("xml-array.xlsx");
    tablepro_core::export::write_result_file(
        &xlsx_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Xlsx,
            csv: &csv_options,
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
    assert!(sheet.contains("<c r=\"A2\" t=\"s\">"), "{sheet}");
    assert!(shared_strings.contains("&lt;a&gt;one,two&lt;/a&gt;"), "{shared_strings}");
    assert!(!sheet.contains("<f>"), "{sheet}");

    connection
        .execute("CREATE TABLE xml_array_filewriter_target (value xml[])")
        .await
        .unwrap();
    let sql_path = directory.path().join("xml-array.sql");
    tablepro_core::export::write_result_file(
        &sql_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Sql,
            csv: &csv_options,
            sql: Some(tablepro_core::export::SqlTarget {
                driver_id: "postgres",
                schema: None,
                table: "xml_array_filewriter_target",
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
            "SELECT pg_typeof(value)::text, array_to_json(value)::text, \
             encode(array_send(value), 'hex') FROM xml_array_filewriter_target",
        )
        .await
        .unwrap();
    assert_eq!(
        restored.rows,
        vec![vec![oracle.rows[0][0].clone(), oracle.rows[0][2].clone(), oracle.rows[0][3].clone()]]
    );
}
