#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::{ConnectOptions, Connection, Value};

use crate::{connect, start_mariadb, start_mysql};

const MODES: [&str; 12] = [
    "",
    "NO_BACKSLASH_ESCAPES",
    "ANSI_QUOTES",
    "ANSI_QUOTES,NO_BACKSLASH_ESCAPES",
    "STRICT_TRANS_TABLES",
    "STRICT_TRANS_TABLES,NO_BACKSLASH_ESCAPES",
    "STRICT_TRANS_TABLES,ANSI_QUOTES",
    "STRICT_TRANS_TABLES,ANSI_QUOTES,NO_BACKSLASH_ESCAPES",
    "STRICT_ALL_TABLES",
    "STRICT_ALL_TABLES,NO_BACKSLASH_ESCAPES",
    "STRICT_ALL_TABLES,ANSI_QUOTES",
    "STRICT_ALL_TABLES,ANSI_QUOTES,NO_BACKSLASH_ESCAPES",
];

async fn connect_in_mode(options: &ConnectOptions, mode: &str) -> Box<dyn Connection> {
    let admin = connect(options.clone()).await;
    admin.execute(&format!("SET GLOBAL sql_mode = '{mode}'")).await.unwrap();
    admin.close().await.unwrap();
    let connection = connect(options.clone()).await;
    let active = connection.query("SELECT @@SESSION.sql_mode").await.unwrap().rows[0][0].clone();
    let Value::Text(active) = active else {
        panic!("unexpected sql_mode: {active:?}")
    };
    assert_eq!(
        active.split(',').any(|value| value.trim() == "NO_BACKSLASH_ESCAPES"),
        mode.split(',').any(|value| value.trim() == "NO_BACKSLASH_ESCAPES"),
        "requested sql_mode {mode:?}, got {active:?}"
    );
    assert_eq!(
        active.split(',').any(|value| value.trim() == "ANSI_QUOTES"),
        mode.split(',').any(|value| value.trim() == "ANSI_QUOTES"),
        "ANSI_QUOTES mode mismatch: {active}"
    );
    assert_eq!(
        active.split(',').any(|value| value.trim() == "STRICT_TRANS_TABLES"),
        mode.split(',').any(|value| value.trim() == "STRICT_TRANS_TABLES"),
        "STRICT_TRANS_TABLES mode mismatch: {active}"
    );
    assert_eq!(
        active.split(',').any(|value| value.trim() == "STRICT_ALL_TABLES"),
        mode.split(',').any(|value| value.trim() == "STRICT_ALL_TABLES"),
        "STRICT_ALL_TABLES mode mismatch: {active}"
    );
    assert_eq!(
        active.split(',').any(|value| value.trim() == "EMPTY_STRING_IS_NULL"),
        mode.split(',').any(|value| value.trim() == "EMPTY_STRING_IS_NULL"),
        "EMPTY_STRING_IS_NULL mode mismatch: {active}"
    );
    connection
}

async fn assert_nonempty_enum_set_xlsx(connection: &dyn Connection, suffix: usize, mode: &str) {
    let result = connection
        .query("SELECT id, mood, perms FROM enum_mode_source WHERE id IN (1, 2, 3, 6, 7) ORDER BY id")
        .await
        .unwrap();
    assert_eq!(
        result.rows,
        vec![
            vec![Value::Int(1), Value::Text("happy".into()), Value::Text("read".into())],
            vec![
                Value::Int(2),
                Value::Text("it's ok".into()),
                Value::Text("write,slash\\path".into())
            ],
            vec![
                Value::Int(3),
                Value::Text("back\\slash".into()),
                Value::Text("NULL".into())
            ],
            vec![Value::Int(6), Value::Null, Value::Null],
            vec![
                Value::Int(7),
                Value::Text("<tag>&".into()),
                Value::Text("<member>".into())
            ],
        ],
        "native enum/set values before XLSX export in sql_mode {mode:?}"
    );

    let path = std::env::temp_dir().join(format!(
        "tablepro-enum-set-xlsx-{}-{:?}-{suffix}.xlsx",
        std::process::id(),
        std::thread::current().id()
    ));
    tablepro_core::export::write_result_file(
        &path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Xlsx,
            csv: &tablepro_core::export::CsvOptions::default(),
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap_or_else(|error| panic!("non-empty ENUM/SET XLSX export in {mode:?}: {error}"));

    let mut archive = zip::ZipArchive::new(std::fs::File::open(&path).unwrap()).unwrap();
    let mut sheet = String::new();
    std::io::Read::read_to_string(&mut archive.by_name("xl/worksheets/sheet1.xml").unwrap(), &mut sheet).unwrap();
    let mut shared_strings = String::new();
    std::io::Read::read_to_string(
        &mut archive.by_name("xl/sharedStrings.xml").unwrap(),
        &mut shared_strings,
    )
    .unwrap();
    for (text, xml) in [
        ("happy", "happy"),
        ("read", "read"),
        ("it's ok", "it's ok"),
        ("write,slash\\path", "write,slash\\path"),
        ("back\\slash", "back\\slash"),
        ("NULL", "NULL"),
        ("<tag>&", "&lt;tag&gt;&amp;"),
        ("<member>", "&lt;member&gt;"),
    ] {
        assert!(
            shared_strings.contains(&format!("<t>{xml}</t>")),
            "XLSX must retain native ENUM/SET text {text:?} in sql_mode {mode:?}: {shared_strings}"
        );
    }
    assert!(
        sheet.contains("<c r=\"B4\" t=\"s\">"),
        "literal ENUM/SET strings must be string cells: {sheet}"
    );
    assert!(!sheet.contains("r=\"B5\""), "SQL NULL enum must remain blank: {sheet}");
    assert!(!sheet.contains("r=\"C5\""), "SQL NULL set must remain blank: {sheet}");
    assert!(
        !sheet.contains("<f>"),
        "enum/set labels must not become formulas: {sheet}"
    );
    std::fs::remove_file(path).unwrap();
}

async fn assert_enum_and_set_export_modes(options: ConnectOptions, extra_modes: &[&str]) {
    let setup = connect(options.clone()).await;
    setup
        .execute(
            r#"CREATE TABLE enum_mode_source (
                id INT PRIMARY KEY,
                mood ENUM('happy', 'it''s ok', 'back\\slash', 'NULL', '', '<tag>&'),
                perms SET('read', 'write', 'slash\\path', 'NULL', '<member>'),
                note VARCHAR(30) NULL
            )"#,
        )
        .await
        .unwrap();
    setup
        .execute("CREATE TABLE enum_mode_copy LIKE enum_mode_source")
        .await
        .unwrap();
    setup
        .execute("CREATE TABLE enum_csv_copy LIKE enum_mode_source")
        .await
        .unwrap();
    for (id, label, permissions, note) in [
        (1, Some("happy"), Some("read"), Some("plain")),
        (2, Some("it's ok"), Some("write,slash\\path"), Some("second")),
        (3, Some("back\\slash"), Some("NULL"), None),
        (4, Some("NULL"), Some(""), Some("four")),
        (5, Some(""), Some("slash\\path"), Some("five")),
        (6, None, None, Some("six")),
        (7, Some("<tag>&"), Some("<member>"), Some("")),
    ] {
        setup
            .execute_params(
                "INSERT INTO enum_mode_source VALUES (?, ?, ?, ?)",
                &[
                    Value::Int(id),
                    label.map_or(Value::Null, |value| Value::Text(value.into())),
                    permissions.map_or(Value::Null, |value| Value::Text(value.into())),
                    note.map_or(Value::Null, |value| Value::Text(value.into())),
                ],
            )
            .await
            .unwrap();
    }
    setup.close().await.unwrap();

    for (suffix, mode) in MODES.into_iter().chain(extra_modes.iter().copied()).enumerate() {
        let connection = connect_in_mode(&options, mode).await;
        connection.execute("DELETE FROM enum_mode_copy").await.unwrap();
        connection.execute("DELETE FROM enum_csv_copy").await.unwrap();
        let source = connection
            .query("SELECT id, mood, perms, note FROM enum_mode_source ORDER BY id")
            .await
            .unwrap();
        let native = connection
            .query(
                "SELECT id, CAST(mood + 0 AS CHAR), HEX(mood), \
                 CAST(perms + 0 AS CHAR), HEX(perms), HEX(note), note IS NULL \
                 FROM enum_mode_source ORDER BY id",
            )
            .await
            .unwrap();
        assert_eq!(
            native.rows,
            vec![
                vec![
                    Value::Int(1),
                    Value::Text("1".into()),
                    Value::Text("6861707079".into()),
                    Value::Text("1".into()),
                    Value::Text("72656164".into()),
                    Value::Text("706C61696E".into()),
                    Value::Int(0),
                ],
                vec![
                    Value::Int(2),
                    Value::Text("2".into()),
                    Value::Text("69742773206F6B".into()),
                    Value::Text("6".into()),
                    Value::Text("77726974652C736C6173685C70617468".into()),
                    Value::Text("7365636F6E64".into()),
                    Value::Int(0),
                ],
                vec![
                    Value::Int(3),
                    Value::Text("3".into()),
                    Value::Text("6261636B5C736C617368".into()),
                    Value::Text("8".into()),
                    Value::Text("4E554C4C".into()),
                    Value::Null,
                    Value::Int(1),
                ],
                vec![
                    Value::Int(4),
                    Value::Text("4".into()),
                    Value::Text("4E554C4C".into()),
                    Value::Text("0".into()),
                    Value::Text(String::new()),
                    Value::Text("666F7572".into()),
                    Value::Int(0),
                ],
                vec![
                    Value::Int(5),
                    Value::Text("5".into()),
                    Value::Text(String::new()),
                    Value::Text("4".into()),
                    Value::Text("736C6173685C70617468".into()),
                    Value::Text("66697665".into()),
                    Value::Int(0),
                ],
                vec![
                    Value::Int(6),
                    Value::Null,
                    Value::Null,
                    Value::Null,
                    Value::Null,
                    Value::Text("736978".into()),
                    Value::Int(0),
                ],
                vec![
                    Value::Int(7),
                    Value::Text("6".into()),
                    Value::Text("3C7461673E26".into()),
                    Value::Text("16".into()),
                    Value::Text("3C6D656D6265723E".into()),
                    Value::Text(String::new()),
                    Value::Int(0),
                ],
            ],
            "native ENUM ordinals and labels in sql_mode {mode:?}"
        );
        let json: serde_json::Value =
            serde_json::from_str(&tablepro_core::export::render_json(&source.columns, &source.rows)).unwrap();
        assert_eq!(
            json,
            serde_json::json!([
                {"id": 1, "mood": "happy", "perms": "read", "note": "plain"},
                {"id": 2, "mood": "it's ok", "perms": "write,slash\\path", "note": "second"},
                {"id": 3, "mood": "back\\slash", "perms": "NULL", "note": null},
                {"id": 4, "mood": "NULL", "perms": "", "note": "four"},
                {"id": 5, "mood": "", "perms": "slash\\path", "note": "five"},
                {"id": 6, "mood": null, "perms": null, "note": "six"},
                {"id": 7, "mood": "<tag>&", "perms": "<member>", "note": ""}
            ]),
            "JSON export under sql_mode {mode:?}"
        );
        let csv_options = tablepro_core::export::CsvOptions::default();
        for (extension, format) in [
            ("xml", tablepro_core::export::ResultFormat::Xml),
            ("html", tablepro_core::export::ResultFormat::Html),
            ("md", tablepro_core::export::ResultFormat::Markdown),
        ] {
            let path = std::env::temp_dir().join(format!(
                "tablepro-enum-set-{}-{:?}-{suffix}.{extension}",
                std::process::id(),
                std::thread::current().id()
            ));
            tablepro_core::export::write_result_file(
                &path,
                &source,
                &tablepro_core::export::ResultExport {
                    format,
                    csv: &csv_options,
                    sql: None,
                },
                || false,
                |_| {},
            )
            .unwrap();
            let output = std::fs::read_to_string(&path).unwrap();
            assert!(output.contains("&lt;tag&gt;&amp;"), "{extension}: {output}");
            assert!(output.contains("&lt;member&gt;"), "{extension}: {output}");
            assert!(!output.contains("<tag>&"), "{extension}: {output}");
            assert!(!output.contains("<member>"), "{extension}: {output}");
            std::fs::remove_file(path).unwrap();
        }
        let xlsx_path = std::env::temp_dir().join(format!(
            "tablepro-enum-xlsx-{}-{:?}-{suffix}.xlsx",
            std::process::id(),
            std::thread::current().id()
        ));
        std::fs::write(&xlsx_path, b"previous workbook").unwrap();
        let csv = tablepro_core::export::CsvOptions::default();
        let xlsx_error = tablepro_core::export::write_result_file(
            &xlsx_path,
            &source,
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
                xlsx_error,
                tablepro_core::export::ExportError::WorkbookEmptyText { row: 4, column: 3 }
            ),
            "sql_mode {mode:?}: {xlsx_error:?}"
        );
        assert_eq!(std::fs::read(&xlsx_path).unwrap(), b"previous workbook");
        std::fs::remove_file(xlsx_path).unwrap();
        assert_nonempty_enum_set_xlsx(connection.as_ref(), suffix, mode).await;

        let null_marker = tablepro_core::export::unique_csv_null_marker(&source.rows);
        let csv_options = tablepro_core::export::CsvOptions {
            null_to_empty: false,
            null_marker: Some(null_marker.clone()),
            ..tablepro_core::export::CsvOptions::default()
        };
        let csv = tablepro_core::export::render_csv(&source.columns, &source.rows, &csv_options);
        let import_options = tablepro_core::import::CsvImportOptions {
            null_marker,
            ..tablepro_core::import::CsvImportOptions::default()
        };
        let sheet = tablepro_core::import::read_csv(csv.as_bytes(), &import_options, None).unwrap();
        let columns = connection.fetch_columns(None, "enum_csv_copy").await.unwrap();
        let mapping = [Some(0), Some(1), Some(2), Some(3)];
        let plan = tablepro_core::import::build_insert_plan(
            &tablepro_core::import::ImportTarget {
                driver_id: "mysql",
                schema: None,
                table: "enum_csv_copy",
                columns: &columns,
                mapping: &mapping,
            },
            &sheet,
            &import_options,
        )
        .unwrap();
        for row in &plan.rows {
            connection.execute_params(&plan.statement, row).await.unwrap();
        }

        let path = std::env::temp_dir().join(format!(
            "tablepro-enum-sql-{}-{:?}-{suffix}.sql",
            std::process::id(),
            std::thread::current().id()
        ));
        let csv = tablepro_core::export::CsvOptions::default();
        tablepro_core::export::write_result_file(
            &path,
            &source,
            &tablepro_core::export::ResultExport {
                format: tablepro_core::export::ResultFormat::Sql,
                csv: &csv,
                sql: Some(tablepro_core::export::SqlTarget {
                    driver_id: "mysql",
                    schema: None,
                    table: "enum_mode_copy",
                }),
            },
            || false,
            |_| {},
        )
        .unwrap();
        let sql = std::fs::read_to_string(&path).unwrap();
        for statement in sql.lines() {
            connection
                .execute(statement)
                .await
                .unwrap_or_else(|error| panic!("sql_mode {mode:?}; {statement}: {error}"));
        }
        std::fs::remove_file(path).unwrap();
        for copy_table in ["enum_mode_copy", "enum_csv_copy"] {
            let matching = connection
                .query(&format!(
                    "SELECT COUNT(*) FROM enum_mode_source s \
                     JOIN {copy_table} c ON s.id = c.id \
                       AND s.mood + 0 <=> c.mood + 0 AND HEX(s.mood) <=> HEX(c.mood) \
                       AND s.perms + 0 <=> c.perms + 0 AND HEX(s.perms) <=> HEX(c.perms) \
                       AND (s.note IS NULL) <=> (c.note IS NULL) \
                       AND HEX(s.note) <=> HEX(c.note)"
                ))
                .await
                .unwrap();
            assert_eq!(
                matching.rows,
                vec![vec![Value::Int(7)]],
                "{copy_table} round trip under sql_mode {mode:?}"
            );
        }
        connection.close().await.unwrap();
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_enum_and_set_consumers_survive_mysql_sql_modes() {
    let (_container, options) = start_mysql().await;
    assert_enum_and_set_export_modes(options, &[]).await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_enum_and_set_consumers_survive_mariadb_sql_modes() {
    let (_container, options) = start_mariadb().await;
    assert_enum_and_set_export_modes(
        options,
        &[
            "EMPTY_STRING_IS_NULL",
            "EMPTY_STRING_IS_NULL,STRICT_TRANS_TABLES,ANSI_QUOTES,NO_BACKSLASH_ESCAPES",
        ],
    )
    .await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_mariadb_empty_enum_and_set_csv_restore_survive_empty_string_is_null() {
    let (_container, options) = start_mariadb().await;
    let setup = connect(options.clone()).await;
    setup
        .execute(
            "CREATE TABLE enum_empty_mode_source (id INT PRIMARY KEY, \
             state ENUM('', 'ready', 'NULL'), permissions SET('read', 'write'))",
        )
        .await
        .unwrap();
    setup
        .execute("CREATE TABLE enum_empty_mode_target LIKE enum_empty_mode_source")
        .await
        .unwrap();
    setup
        .execute("CREATE TABLE enum_empty_mode_combined_target LIKE enum_empty_mode_source")
        .await
        .unwrap();
    setup
        .execute(
            "INSERT INTO enum_empty_mode_source VALUES \
             (1, '', ''), (2, 'NULL', 'read'), (3, NULL, NULL)",
        )
        .await
        .unwrap();
    setup
        .execute("INSERT INTO enum_empty_mode_target VALUES (99, 'ready', 'write')")
        .await
        .unwrap();
    setup
        .execute("INSERT INTO enum_empty_mode_combined_target VALUES (99, 'ready', 'write')")
        .await
        .unwrap();
    setup
        .execute("SET GLOBAL sql_mode = 'EMPTY_STRING_IS_NULL'")
        .await
        .unwrap();
    setup.close().await.unwrap();

    let connection = connect(options.clone()).await;
    let active_mode = connection.query("SELECT @@SESSION.sql_mode").await.unwrap();
    let Value::Text(active_mode) = &active_mode.rows[0][0] else {
        panic!("unexpected sql_mode: {:?}", active_mode.rows)
    };
    assert!(
        active_mode.split(',').any(|mode| mode.trim() == "EMPTY_STRING_IS_NULL"),
        "EMPTY_STRING_IS_NULL must be active; got {active_mode}"
    );
    assert_eq!(
        connection
            .query("SELECT HEX(SPACE(0)), SPACE(0) IS NULL")
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Text(String::new()), Value::Int(0)]],
        "a server expression can represent empty text without the SQL mode turning it into NULL"
    );
    let source = connection
        .query("SELECT id, state, permissions FROM enum_empty_mode_source ORDER BY id")
        .await
        .unwrap();
    let source_native = connection
        .query(
            "SELECT id, CAST(state + 0 AS CHAR), HEX(state), state IS NULL, \
             CAST(permissions + 0 AS CHAR), HEX(permissions), permissions IS NULL \
             FROM enum_empty_mode_source ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(
        source_native.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("1".into()),
                Value::Text(String::new()),
                Value::Int(0),
                Value::Text("0".into()),
                Value::Text(String::new()),
                Value::Int(0),
            ],
            vec![
                Value::Int(2),
                Value::Text("3".into()),
                Value::Text("4E554C4C".into()),
                Value::Int(0),
                Value::Text("1".into()),
                Value::Text("72656164".into()),
                Value::Int(0),
            ],
            vec![
                Value::Int(3),
                Value::Null,
                Value::Null,
                Value::Int(1),
                Value::Null,
                Value::Null,
                Value::Int(1),
            ],
        ]
    );

    let null_marker = tablepro_core::export::unique_csv_null_marker(&source.rows);
    let csv_options = tablepro_core::export::CsvOptions {
        null_to_empty: false,
        null_marker: Some(null_marker.clone()),
        ..Default::default()
    };
    let csv = tablepro_core::export::render_csv(&source.columns, &source.rows, &csv_options);
    let import_options = tablepro_core::import::CsvImportOptions {
        null_marker,
        ..Default::default()
    };
    let sheet = tablepro_core::import::read_csv(csv.as_bytes(), &import_options, None).unwrap();
    let columns = connection.fetch_columns(None, "enum_empty_mode_target").await.unwrap();
    let plan = tablepro_core::import::build_insert_plan(
        &tablepro_core::import::ImportTarget {
            driver_id: "mysql",
            schema: None,
            table: "enum_empty_mode_target",
            columns: &columns,
            mapping: &[Some(0), Some(1), Some(2)],
        },
        &sheet,
        &import_options,
    )
    .unwrap();
    for row in &plan.rows {
        connection.execute_params(&plan.statement, row).await.unwrap();
    }

    let restored = connection
        .query(
            "SELECT id, CAST(state + 0 AS CHAR), HEX(state), state IS NULL, \
             CAST(permissions + 0 AS CHAR), HEX(permissions), permissions IS NULL \
             FROM enum_empty_mode_target ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(
        restored.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("1".into()),
                Value::Text(String::new()),
                Value::Int(0),
                Value::Text("0".into()),
                Value::Text(String::new()),
                Value::Int(0),
            ],
            vec![
                Value::Int(2),
                Value::Text("3".into()),
                Value::Text("4E554C4C".into()),
                Value::Int(0),
                Value::Text("1".into()),
                Value::Text("72656164".into()),
                Value::Int(0),
            ],
            vec![
                Value::Int(3),
                Value::Null,
                Value::Null,
                Value::Int(1),
                Value::Null,
                Value::Null,
                Value::Int(1),
            ],
            vec![
                Value::Int(99),
                Value::Text("2".into()),
                Value::Text("7265616479".into()),
                Value::Int(0),
                Value::Text("2".into()),
                Value::Text("7772697465".into()),
                Value::Int(0),
            ],
        ]
    );
    connection.close().await.unwrap();

    let setup = connect(options.clone()).await;
    setup
        .execute("SET GLOBAL sql_mode = 'EMPTY_STRING_IS_NULL,STRICT_TRANS_TABLES,ANSI_QUOTES,NO_BACKSLASH_ESCAPES'")
        .await
        .unwrap();
    setup.close().await.unwrap();

    let connection = connect(options).await;
    let active_mode = connection.query("SELECT @@SESSION.sql_mode").await.unwrap();
    let Value::Text(active_mode) = &active_mode.rows[0][0] else {
        panic!("unexpected sql_mode: {:?}", active_mode.rows)
    };
    for mode in [
        "EMPTY_STRING_IS_NULL",
        "STRICT_TRANS_TABLES",
        "ANSI_QUOTES",
        "NO_BACKSLASH_ESCAPES",
    ] {
        assert!(
            active_mode.split(',').any(|active| active.trim() == mode),
            "{mode} must be active in combined sql_mode; got {active_mode}"
        );
    }
    let columns = connection
        .fetch_columns(None, "enum_empty_mode_combined_target")
        .await
        .unwrap();
    let plan = tablepro_core::import::build_insert_plan(
        &tablepro_core::import::ImportTarget {
            driver_id: "mysql",
            schema: None,
            table: "enum_empty_mode_combined_target",
            columns: &columns,
            mapping: &[Some(0), Some(1), Some(2)],
        },
        &sheet,
        &import_options,
    )
    .unwrap();
    for row in &plan.rows {
        connection.execute_params(&plan.statement, row).await.unwrap();
    }
    let restored_combined = connection
        .query(
            "SELECT id, CAST(state + 0 AS CHAR), HEX(state), state IS NULL, \
             CAST(permissions + 0 AS CHAR), HEX(permissions), permissions IS NULL \
             FROM enum_empty_mode_combined_target ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(
        restored_combined.rows, restored.rows,
        "combined sql_mode must preserve empty ENUM/SET, SQL NULL, and the existing sibling"
    );
    connection.close().await.unwrap();
}

async fn assert_collated_enum_round_trip(options: ConnectOptions) {
    let connection = connect(options).await;
    connection
        .execute(
            "CREATE TABLE enum_collation_source (
                id INT PRIMARY KEY,
                mood ENUM('Café', 'Tea') CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci
            )",
        )
        .await
        .unwrap();
    connection
        .execute("CREATE TABLE enum_collation_copy LIKE enum_collation_source")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO enum_collation_source VALUES (1, 'CAFE'), (2, 'tEa')")
        .await
        .unwrap();

    let columns = connection.fetch_columns(None, "enum_collation_source").await.unwrap();
    let mood = columns.iter().position(|column| column.name == "mood").unwrap();
    assert_eq!(columns[mood].collation.as_deref(), Some("utf8mb4_unicode_ci"));

    let native = connection
        .query(
            "SELECT id, mood, CAST(mood + 0 AS CHAR), HEX(mood), COLLATION(mood) \
             FROM enum_collation_source ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(native.columns[1].data_type, "ENUM");
    assert_eq!(
        native.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("Café".into()),
                Value::Text("1".into()),
                Value::Text("436166C3A9".into()),
                Value::Text("utf8mb4_unicode_ci".into()),
            ],
            vec![
                Value::Int(2),
                Value::Text("Tea".into()),
                Value::Text("2".into()),
                Value::Text("546561".into()),
                Value::Text("utf8mb4_unicode_ci".into()),
            ],
        ]
    );

    for row in &native.rows {
        connection
            .execute_params("INSERT INTO enum_collation_copy (id, mood) VALUES (?, ?)", &row[..2])
            .await
            .unwrap();
    }
    let copied = connection
        .query(
            "SELECT id, mood, CAST(mood + 0 AS CHAR), HEX(mood), COLLATION(mood) \
             FROM enum_collation_copy ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(copied.rows, native.rows);

    connection
        .execute(
            "CREATE TABLE enum_binary_collation_source (
                id INT PRIMARY KEY,
                mood ENUM('Café', 'cafe', 'Tea') CHARACTER SET utf8mb4 COLLATE utf8mb4_bin,
                raw BINARY(4),
                opaque ENUM('raw') CHARACTER SET binary
            )",
        )
        .await
        .unwrap();
    connection
        .execute("CREATE TABLE enum_binary_collation_copy LIKE enum_binary_collation_source")
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO enum_binary_collation_source VALUES \
             (1, 'Café', 'text', 'raw'), (2, 'cafe', 'data', 'raw'), (3, 'Tea', 'byte', 'raw')",
        )
        .await
        .unwrap();

    let binary_columns = connection
        .fetch_columns(None, "enum_binary_collation_source")
        .await
        .unwrap();
    let binary_mood = binary_columns.iter().position(|column| column.name == "mood").unwrap();
    assert_eq!(binary_columns[binary_mood].collation.as_deref(), Some("utf8mb4_bin"));
    let native = connection
        .query(
            "SELECT id, mood, raw, opaque, CAST(mood + 0 AS CHAR), HEX(mood), COLLATION(mood) \
             FROM enum_binary_collation_source ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(native.columns[1].data_type, "ENUM");
    assert_eq!(native.columns[2].data_type, "BINARY");
    assert_eq!(native.columns[3].data_type, "ENUM");
    assert_eq!(
        native.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("Café".into()),
                Value::Bytes(b"text".to_vec()),
                Value::Bytes(b"raw".to_vec()),
                Value::Text("1".into()),
                Value::Text("436166C3A9".into()),
                Value::Text("utf8mb4_bin".into()),
            ],
            vec![
                Value::Int(2),
                Value::Text("cafe".into()),
                Value::Bytes(b"data".to_vec()),
                Value::Bytes(b"raw".to_vec()),
                Value::Text("2".into()),
                Value::Text("63616665".into()),
                Value::Text("utf8mb4_bin".into()),
            ],
            vec![
                Value::Int(3),
                Value::Text("Tea".into()),
                Value::Bytes(b"byte".to_vec()),
                Value::Bytes(b"raw".to_vec()),
                Value::Text("3".into()),
                Value::Text("546561".into()),
                Value::Text("utf8mb4_bin".into()),
            ],
        ]
    );
    for row in &native.rows {
        connection
            .execute_params(
                "INSERT INTO enum_binary_collation_copy (id, mood, raw, opaque) VALUES (?, ?, ?, ?)",
                &row[..4],
            )
            .await
            .unwrap();
    }
    let copied = connection
        .query(
            "SELECT id, mood, raw, opaque, CAST(mood + 0 AS CHAR), HEX(mood), COLLATION(mood) \
             FROM enum_binary_collation_copy ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(copied.rows, native.rows);

    connection
        .execute(
            "CREATE TABLE set_binary_collation_source (
                id INT PRIMARY KEY,
                permissions SET('Café', 'cafe', 'Tea') CHARACTER SET utf8mb4 COLLATE utf8mb4_bin,
                opaque SET('raw') CHARACTER SET binary
            )",
        )
        .await
        .unwrap();
    connection
        .execute("CREATE TABLE set_binary_collation_copy LIKE set_binary_collation_source")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO set_binary_collation_source VALUES (1, 'cafe,Café', 'raw'), (2, 'Tea', 'raw')")
        .await
        .unwrap();
    let set_columns = connection
        .fetch_columns(None, "set_binary_collation_source")
        .await
        .unwrap();
    let set_column = set_columns
        .iter()
        .position(|column| column.name == "permissions")
        .unwrap();
    assert_eq!(set_columns[set_column].collation.as_deref(), Some("utf8mb4_bin"));
    let native = connection
        .query(
            "SELECT id, permissions, opaque, CAST(permissions + 0 AS CHAR), HEX(permissions), \
             COLLATION(permissions) FROM set_binary_collation_source ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(native.columns[1].data_type, "SET");
    assert_eq!(native.columns[2].data_type, "SET");
    assert_eq!(
        native.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("Café,cafe".into()),
                Value::Bytes(b"raw".to_vec()),
                Value::Text("3".into()),
                Value::Text("436166C3A92C63616665".into()),
                Value::Text("utf8mb4_bin".into()),
            ],
            vec![
                Value::Int(2),
                Value::Text("Tea".into()),
                Value::Bytes(b"raw".to_vec()),
                Value::Text("4".into()),
                Value::Text("546561".into()),
                Value::Text("utf8mb4_bin".into()),
            ],
        ]
    );
    for row in &native.rows {
        connection
            .execute_params("INSERT INTO set_binary_collation_copy VALUES (?, ?, ?)", &row[..3])
            .await
            .unwrap();
    }
    let copied = connection
        .query(
            "SELECT id, permissions, opaque, CAST(permissions + 0 AS CHAR), HEX(permissions), \
             COLLATION(permissions) FROM set_binary_collation_copy ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(copied.rows, native.rows);

    connection
        .execute(
            "CREATE TABLE latin1_collation_source (
                id INT PRIMARY KEY,
                mood ENUM('Café', 'Tea') CHARACTER SET latin1 COLLATE latin1_swedish_ci,
                permissions SET('Café', 'Tea') CHARACTER SET latin1 COLLATE latin1_swedish_ci
            )",
        )
        .await
        .unwrap();
    connection
        .execute("CREATE TABLE latin1_collation_copy LIKE latin1_collation_source")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO latin1_collation_source VALUES (1, 'CAFÉ', 'tea,Café'), (2, 'tEa', 'Tea')")
        .await
        .unwrap();
    let latin1_columns = connection.fetch_columns(None, "latin1_collation_source").await.unwrap();
    for column in latin1_columns
        .iter()
        .filter(|column| column.name == "mood" || column.name == "permissions")
    {
        assert_eq!(column.collation.as_deref(), Some("latin1_swedish_ci"));
    }
    let native = connection
        .query(
            "SELECT id, mood, permissions, CAST(mood + 0 AS CHAR), \
             CAST(permissions + 0 AS CHAR), HEX(mood), HEX(permissions), \
             COLLATION(mood), COLLATION(permissions) \
             FROM latin1_collation_source ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(native.columns[1].data_type, "ENUM");
    assert_eq!(native.columns[2].data_type, "SET");
    assert_eq!(
        native.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("Café".into()),
                Value::Text("Café,Tea".into()),
                Value::Text("1".into()),
                Value::Text("3".into()),
                Value::Text("436166E9".into()),
                Value::Text("436166E92C546561".into()),
                Value::Text("latin1_swedish_ci".into()),
                Value::Text("latin1_swedish_ci".into()),
            ],
            vec![
                Value::Int(2),
                Value::Text("Tea".into()),
                Value::Text("Tea".into()),
                Value::Text("2".into()),
                Value::Text("2".into()),
                Value::Text("546561".into()),
                Value::Text("546561".into()),
                Value::Text("latin1_swedish_ci".into()),
                Value::Text("latin1_swedish_ci".into()),
            ],
        ]
    );
    for row in &native.rows {
        connection
            .execute_params("INSERT INTO latin1_collation_copy VALUES (?, ?, ?)", &row[..3])
            .await
            .unwrap();
    }
    let copied = connection
        .query(
            "SELECT id, mood, permissions, CAST(mood + 0 AS CHAR), \
             CAST(permissions + 0 AS CHAR), HEX(mood), HEX(permissions), \
             COLLATION(mood), COLLATION(permissions) \
             FROM latin1_collation_copy ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(copied.rows, native.rows);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_mysql_and_mariadb_collated_enum_inputs_preserve_canonical_labels() {
    let (_mysql, mysql_options) = start_mysql().await;
    assert_collated_enum_round_trip(mysql_options).await;

    let (_mariadb, mariadb_options) = start_mariadb().await;
    assert_collated_enum_round_trip(mariadb_options).await;
}
