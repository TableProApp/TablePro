#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::Value;

use crate::{connect, start_pg};

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_custom_enum_xml_file_export_preserves_labels_null_and_escapes_markup() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute(
            "CREATE TYPE value_contract_xml_enum AS ENUM \
             ('NULL', '', '東京', '</label><injected attr=\"x\">''&amp;</injected>')",
        )
        .await
        .unwrap();

    let result = connection
        .query(
            "SELECT label, pg_typeof(label)::text AS native_type FROM (VALUES \
             ('NULL'::value_contract_xml_enum), (''::value_contract_xml_enum), \
             ('東京'::value_contract_xml_enum), \
             ('</label><injected attr=\"x\">''&amp;</injected>'::value_contract_xml_enum), \
             (NULL::value_contract_xml_enum)) AS labels(label)",
        )
        .await
        .unwrap();
    let hostile_label = "</label><injected attr=\"x\">'&amp;</injected>";
    assert_eq!(
        result.rows,
        vec![
            vec![
                Value::Text("NULL".into()),
                Value::Text("value_contract_xml_enum".into())
            ],
            vec![
                Value::Text(String::new()),
                Value::Text("value_contract_xml_enum".into())
            ],
            vec![
                Value::Text("東京".into()),
                Value::Text("value_contract_xml_enum".into())
            ],
            vec![
                Value::Text(hostile_label.into()),
                Value::Text("value_contract_xml_enum".into())
            ],
            vec![Value::Null, Value::Text("value_contract_xml_enum".into())],
        ]
    );

    let directory = tempfile::tempdir().unwrap();
    let xml_path = directory.path().join("enum.xml");
    let csv_options = tablepro_core::export::CsvOptions::default();
    tablepro_core::export::write_result_file(
        &xml_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Xml,
            csv: &csv_options,
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap();
    let xml = std::fs::read_to_string(&xml_path).unwrap();
    assert!(xml.contains("<label>NULL</label>"), "{xml}");
    assert!(xml.contains("<label></label>"), "{xml}");
    assert!(xml.contains("<label>東京</label>"), "{xml}");
    assert!(
        xml.contains(
            "<label>&lt;/label&gt;&lt;injected attr=&quot;x&quot;&gt;&apos;&amp;amp;&lt;/injected&gt;</label>"
        ),
        "{xml}"
    );
    assert!(xml.contains("<label null=\"true\"/>"), "{xml}");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_custom_enum_html_file_export_preserves_labels_null_and_escapes_markup() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute(
            "CREATE TYPE value_contract_html_enum AS ENUM \
             ('NULL', '', '東京', '<img src=x onerror=\"alert(''x'')\">')",
        )
        .await
        .unwrap();

    let result = connection
        .query(
            "SELECT label, pg_typeof(label)::text AS native_type FROM (VALUES \
             ('NULL'::value_contract_html_enum), (''::value_contract_html_enum), \
             ('東京'::value_contract_html_enum), \
             ('<img src=x onerror=\"alert(''x'')\">'::value_contract_html_enum), \
             (NULL::value_contract_html_enum)) AS labels(label)",
        )
        .await
        .unwrap();
    let hostile_label = "<img src=x onerror=\"alert('x')\">";
    assert_eq!(
        result.rows,
        vec![
            vec![
                Value::Text("NULL".into()),
                Value::Text("value_contract_html_enum".into())
            ],
            vec![
                Value::Text(String::new()),
                Value::Text("value_contract_html_enum".into())
            ],
            vec![
                Value::Text("東京".into()),
                Value::Text("value_contract_html_enum".into())
            ],
            vec![
                Value::Text(hostile_label.into()),
                Value::Text("value_contract_html_enum".into())
            ],
            vec![Value::Null, Value::Text("value_contract_html_enum".into())],
        ]
    );

    let directory = tempfile::tempdir().unwrap();
    let html_path = directory.path().join("enum.html");
    let csv_options = tablepro_core::export::CsvOptions::default();
    tablepro_core::export::write_result_file(
        &html_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Html,
            csv: &csv_options,
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap();
    let html = std::fs::read_to_string(&html_path).unwrap();
    assert!(html.contains("<td>NULL</td>"), "{html}");
    assert!(html.contains("<td></td>"), "{html}");
    assert!(html.contains("<td>東京</td>"), "{html}");
    assert!(
        html.contains("<td>&lt;img src=x onerror=&quot;alert(&#39;x&#39;)&quot;&gt;</td>"),
        "{html}"
    );
    assert!(!html.contains("<img src=x"), "{html}");
    assert!(html.contains("<td class=\"null\"></td>"), "{html}");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_custom_enum_markdown_file_export_preserves_labels_null_and_cell_text() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute(
            "CREATE TYPE value_contract_markdown_enum AS ENUM \
             ('NULL', '', '東京', 'a|b\nc', '<tag>&amp;')",
        )
        .await
        .unwrap();

    let result = connection
        .query(
            "SELECT label, pg_typeof(label)::text AS native_type FROM (VALUES \
             ('NULL'::value_contract_markdown_enum), (''::value_contract_markdown_enum), \
             ('東京'::value_contract_markdown_enum), ('a|b\nc'::value_contract_markdown_enum), \
             ('<tag>&amp;'::value_contract_markdown_enum), (NULL::value_contract_markdown_enum)) \
             AS labels(label)",
        )
        .await
        .unwrap();
    assert_eq!(
        result.rows,
        vec![
            vec![
                Value::Text("NULL".into()),
                Value::Text("value_contract_markdown_enum".into())
            ],
            vec![
                Value::Text(String::new()),
                Value::Text("value_contract_markdown_enum".into())
            ],
            vec![
                Value::Text("東京".into()),
                Value::Text("value_contract_markdown_enum".into())
            ],
            vec![
                Value::Text("a|b\nc".into()),
                Value::Text("value_contract_markdown_enum".into())
            ],
            vec![
                Value::Text("<tag>&amp;".into()),
                Value::Text("value_contract_markdown_enum".into())
            ],
            vec![Value::Null, Value::Text("value_contract_markdown_enum".into())],
        ]
    );

    let directory = tempfile::tempdir().unwrap();
    let markdown_path = directory.path().join("enum.md");
    let csv_options = tablepro_core::export::CsvOptions::default();
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
    assert_eq!(
        std::fs::read_to_string(&markdown_path).unwrap(),
        concat!(
            "| label | native&#95;type |\n| --- | --- |\n",
            "| \"NULL\" | \"value&#95;contract&#95;markdown&#95;enum\" |\n",
            "| \"\" | \"value&#95;contract&#95;markdown&#95;enum\" |\n",
            "| \"東京\" | \"value&#95;contract&#95;markdown&#95;enum\" |\n",
            "| \"a\\|b&#92;nc\" | \"value&#95;contract&#95;markdown&#95;enum\" |\n",
            "| \"&lt;tag&gt;&amp;amp;\" | \"value&#95;contract&#95;markdown&#95;enum\" |\n",
            "| NULL | \"value&#95;contract&#95;markdown&#95;enum\" |\n",
        )
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_custom_enum_xlsx_file_export_keeps_text_labels_and_refuses_empty_safely() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute(
            "CREATE TYPE value_contract_xlsx_enum AS ENUM \
             ('NULL', '', '東京', '<tag>&amp;', '=1+1', ' leading', 'trailing ')",
        )
        .await
        .unwrap();

    let all_rows = connection
        .query(
            "SELECT id, label, pg_typeof(label)::text AS native_type FROM (VALUES \
             (1, 'NULL'::value_contract_xlsx_enum), (2, ''::value_contract_xlsx_enum), \
             (3, '東京'::value_contract_xlsx_enum), (4, '<tag>&amp;'::value_contract_xlsx_enum), \
             (5, '=1+1'::value_contract_xlsx_enum), (6, ' leading'::value_contract_xlsx_enum), \
             (7, 'trailing '::value_contract_xlsx_enum), (8, NULL::value_contract_xlsx_enum)) \
             AS labels(id, label) ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(
        all_rows.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("NULL".into()),
                Value::Text("value_contract_xlsx_enum".into())
            ],
            vec![
                Value::Int(2),
                Value::Text(String::new()),
                Value::Text("value_contract_xlsx_enum".into())
            ],
            vec![
                Value::Int(3),
                Value::Text("東京".into()),
                Value::Text("value_contract_xlsx_enum".into())
            ],
            vec![
                Value::Int(4),
                Value::Text("<tag>&amp;".into()),
                Value::Text("value_contract_xlsx_enum".into())
            ],
            vec![
                Value::Int(5),
                Value::Text("=1+1".into()),
                Value::Text("value_contract_xlsx_enum".into())
            ],
            vec![
                Value::Int(6),
                Value::Text(" leading".into()),
                Value::Text("value_contract_xlsx_enum".into())
            ],
            vec![
                Value::Int(7),
                Value::Text("trailing ".into()),
                Value::Text("value_contract_xlsx_enum".into())
            ],
            vec![
                Value::Int(8),
                Value::Null,
                Value::Text("value_contract_xlsx_enum".into())
            ],
        ]
    );

    let valid_rows = connection
        .query(
            "SELECT id, label, pg_typeof(label)::text AS native_type FROM (VALUES \
             (1, 'NULL'::value_contract_xlsx_enum), (2, ''::value_contract_xlsx_enum), \
             (3, '東京'::value_contract_xlsx_enum), (4, '<tag>&amp;'::value_contract_xlsx_enum), \
             (5, '=1+1'::value_contract_xlsx_enum), (6, ' leading'::value_contract_xlsx_enum), \
             (7, 'trailing '::value_contract_xlsx_enum), (8, NULL::value_contract_xlsx_enum)) \
             AS labels(id, label) WHERE id <> 2 ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(
        valid_rows.rows,
        [
            all_rows.rows[0].clone(),
            all_rows.rows[2].clone(),
            all_rows.rows[3].clone(),
            all_rows.rows[4].clone(),
            all_rows.rows[5].clone(),
            all_rows.rows[6].clone(),
            all_rows.rows[7].clone()
        ]
    );

    let directory = tempfile::tempdir().unwrap();
    let csv_options = tablepro_core::export::CsvOptions::default();
    let xlsx_path = std::env::var_os("BOOKIEE_XLSX_REIMPORT_ARTIFACT")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| directory.path().join("enum.xlsx"));
    tablepro_core::export::write_result_file(
        &xlsx_path,
        &valid_rows,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Xlsx,
            csv: &csv_options,
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap();
    let mut workbook = zip::ZipArchive::new(std::fs::File::open(&xlsx_path).unwrap()).unwrap();
    let mut sheet = String::new();
    std::io::Read::read_to_string(&mut workbook.by_name("xl/worksheets/sheet1.xml").unwrap(), &mut sheet).unwrap();
    let mut shared_strings = String::new();
    std::io::Read::read_to_string(
        &mut workbook.by_name("xl/sharedStrings.xml").unwrap(),
        &mut shared_strings,
    )
    .unwrap();
    for cell in ["B2", "B3", "B4", "B5", "B6", "B7"] {
        assert!(sheet.contains(&format!("<c r=\"{cell}\" t=\"s\">")), "{sheet}");
    }
    assert!(
        !sheet.contains("r=\"B8\""),
        "SQL NULL should remain a blank cell: {sheet}"
    );
    assert!(shared_strings.contains("<t>NULL</t>"), "{shared_strings}");
    assert!(shared_strings.contains("<t>東京</t>"), "{shared_strings}");
    assert!(shared_strings.contains("&lt;tag&gt;&amp;amp;"), "{shared_strings}");
    assert!(shared_strings.contains("<t>=1+1</t>"), "{shared_strings}");
    assert!(
        shared_strings.contains("<t xml:space=\"preserve\"> leading</t>"),
        "{shared_strings}"
    );
    assert!(
        shared_strings.contains("<t xml:space=\"preserve\">trailing </t>"),
        "{shared_strings}"
    );
    assert!(!sheet.contains("<f>"), "enum labels must not become formulas: {sheet}");

    let refusal_path = directory.path().join("preserve.xlsx");
    std::fs::write(&refusal_path, b"existing workbook").unwrap();
    let error = tablepro_core::export::write_result_file(
        &refusal_path,
        &all_rows,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Xlsx,
            csv: &csv_options,
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
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_custom_enum_csv_file_export_import_preserves_empty_and_null() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    for sql in [
        "CREATE SCHEMA csv_file_enum",
        "CREATE TYPE csv_file_enum.state AS ENUM ('NULL', '', '東京', E'\\\\N', E'\\\\NN', '=1+1', '''=1+1')",
        "CREATE TABLE csv_file_enum.source_rows (id INT PRIMARY KEY, status csv_file_enum.state)",
        "CREATE TABLE csv_file_enum.target_rows (id INT PRIMARY KEY, status csv_file_enum.state)",
        "CREATE TABLE csv_file_enum.safe_target_rows (id INT PRIMARY KEY, status csv_file_enum.state)",
        "INSERT INTO csv_file_enum.source_rows VALUES (1, 'NULL'), (2, ''), (3, '東京'), \
         (4, E'\\\\N'), (5, E'\\\\NN'), (6, '=1+1'), (7, '''=1+1'), (8, NULL)",
    ] {
        connection.execute(sql).await.unwrap();
    }
    let source = connection
        .query("SELECT id, status FROM csv_file_enum.source_rows ORDER BY id")
        .await
        .unwrap();
    let directory = tempfile::tempdir().unwrap();
    let default_path = directory.path().join("default.csv");
    let default_options = tablepro_core::export::CsvOptions::default();
    tablepro_core::export::write_result_file(
        &default_path,
        &source,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Csv,
            csv: &default_options,
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap();
    let default_sheet =
        tablepro_core::import::read_csv_file(&default_path, &tablepro_core::import::CsvImportOptions::default(), None)
            .unwrap();
    let target_columns = connection
        .fetch_columns(Some("csv_file_enum"), "target_rows")
        .await
        .unwrap();
    let target = tablepro_core::import::ImportTarget {
        driver_id: "postgres",
        schema: Some("csv_file_enum"),
        table: "target_rows",
        columns: &target_columns,
        mapping: &[Some(0), Some(1)],
    };
    let error = tablepro_core::import::build_insert_plan(
        &target,
        &default_sheet,
        &tablepro_core::import::CsvImportOptions::default(),
    )
    .expect_err("default file-writer blanks are ambiguous for enum NULL and empty text");
    assert!(
        matches!(error, tablepro_core::import::PlanError::Rows { total: 2, .. }),
        "{error:?}"
    );
    let empty_target = connection
        .query("SELECT count(*)::bigint FROM csv_file_enum.target_rows")
        .await
        .unwrap();
    assert_eq!(empty_target.rows, vec![vec![Value::Int(0)]]);

    let marker = tablepro_core::export::unique_csv_null_marker(&source.rows);
    assert_eq!(marker, "\\NNN");
    let options = tablepro_core::export::CsvOptions {
        null_to_empty: false,
        sanitize_formulas: false,
        null_marker: Some(marker.clone()),
        ..Default::default()
    };
    let marked_path = directory.path().join("marked.csv");
    tablepro_core::export::write_result_file(
        &marked_path,
        &source,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Csv,
            csv: &options,
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap();
    let csv = std::fs::read_to_string(&marked_path).unwrap();
    assert_eq!(
        csv,
        "id,status\n1,NULL\n2,\"\"\n3,東京\n4,\\N\n5,\\NN\n6,=1+1\n7,'=1+1\n8,\\NNN\n"
    );
    let import_options = tablepro_core::import::CsvImportOptions {
        null_marker: marker,
        ..Default::default()
    };
    let sheet = tablepro_core::import::read_csv_file(&marked_path, &import_options, None).unwrap();
    let plan = tablepro_core::import::build_insert_plan(&target, &sheet, &import_options).unwrap();
    for row in &plan.rows {
        connection.execute_params(&plan.statement, row).await.unwrap();
    }
    let restored = connection
        .query("SELECT id, status::text, pg_typeof(status)::text FROM csv_file_enum.target_rows ORDER BY id")
        .await
        .unwrap();
    assert_eq!(restored.rows.len(), source.rows.len());
    for (source, restored) in source.rows.iter().zip(&restored.rows) {
        assert_eq!(&source[0], &restored[0]);
        assert_eq!(&source[1], &restored[1]);
        assert_eq!(restored[2], Value::Text("csv_file_enum.state".into()));
    }

    let safe_options = tablepro_core::export::CsvOptions {
        null_to_empty: false,
        null_marker: Some("\\NNN".into()),
        ..Default::default()
    };
    let safe_path = directory.path().join("spreadsheet-safe.csv");
    tablepro_core::export::write_result_file(
        &safe_path,
        &source,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Csv,
            csv: &safe_options,
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap();
    let safe_csv = std::fs::read_to_string(&safe_path).unwrap();
    assert_eq!(
        safe_csv,
        "id,status\n1,NULL\n2,\"\"\n3,東京\n4,\\N\n5,\\NN\n6,\"'=1+1\"\n7,'=1+1\n8,\\NNN\n"
    );
    let safe_import_options = tablepro_core::import::CsvImportOptions {
        null_marker: "\\NNN".into(),
        ..Default::default()
    };
    let safe_sheet = tablepro_core::import::read_csv_file(&safe_path, &safe_import_options, None).unwrap();
    let safe_target_columns = connection
        .fetch_columns(Some("csv_file_enum"), "safe_target_rows")
        .await
        .unwrap();
    let safe_target = tablepro_core::import::ImportTarget {
        driver_id: "postgres",
        schema: Some("csv_file_enum"),
        table: "safe_target_rows",
        columns: &safe_target_columns,
        mapping: &[Some(0), Some(1)],
    };
    let safe_plan = tablepro_core::import::build_insert_plan(&safe_target, &safe_sheet, &safe_import_options).unwrap();
    assert_eq!(source.rows[5][1], Value::Text("=1+1".into()));
    assert_eq!(source.rows[6][1], Value::Text("'=1+1".into()));
    assert_eq!(safe_plan.rows[5][1], Value::Text("'=1+1".into()));
    assert_eq!(safe_plan.rows[6][1], Value::Text("'=1+1".into()));
    let statements = safe_plan
        .rows
        .iter()
        .map(|row| (safe_plan.statement.clone(), row.clone()))
        .collect::<Vec<_>>();
    connection.execute_in_transaction(&statements).await.unwrap();
    let safe_restored = connection
        .query(
            "SELECT id, status::text, pg_typeof(status)::text \
             FROM csv_file_enum.safe_target_rows ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(safe_restored.rows.len(), source.rows.len());
    assert_eq!(safe_restored.rows[5][0], source.rows[5][0]);
    assert_eq!(safe_restored.rows[6][0], source.rows[6][0]);
    assert_eq!(safe_restored.rows[5][1], Value::Text("'=1+1".into()));
    assert_eq!(safe_restored.rows[6][1], Value::Text("'=1+1".into()));
    assert_eq!(safe_restored.rows[5][2], Value::Text("csv_file_enum.state".into()));
    assert_eq!(safe_restored.rows[6][2], Value::Text("csv_file_enum.state".into()));
}
