#[cfg(feature = "duckdb")]
use super::parse_input_for_grid_cell;
#[cfg(feature = "duckdb")]
use tablepro_core::Value;

#[cfg(feature = "duckdb")]
#[tokio::test]
async fn value_contract_duckdb_enum_keyed_edit_preserves_native_type_and_siblings() {
    use tablepro_core::{ConnectOptions, DatabaseDriver};

    let connection = drivers_duckdb::DuckdbDriver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    connection
        .execute("CREATE TYPE mood AS ENUM ('', 'NULL', '東京', 'ready', 'O''Brien')")
        .await
        .unwrap();
    connection
        .execute("CREATE TABLE moods (id INTEGER PRIMARY KEY, status mood)")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO moods VALUES (1, ''), (2, 'NULL'), (3, NULL), (4, 'ready'), (5, 'O''Brien')")
        .await
        .unwrap();

    let columns = connection.fetch_columns(None, "moods").await.unwrap();
    let status_index = columns.iter().position(|column| column.name == "status").unwrap();
    assert!(columns[status_index].data_type.starts_with("ENUM"));
    let edit = parse_input_for_grid_cell("ready", Some(&columns[status_index]), "duckdb", None).unwrap();
    assert_eq!(edit, Value::Text("ready".into()));
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "duckdb",
        None,
        "moods",
        &columns,
        &[(status_index, edit)],
        &[Value::Int(2)],
    )
    .unwrap();
    connection.execute_in_transaction(&[update]).await.unwrap();

    assert_eq!(
        parse_input_for_grid_cell("", Some(&columns[status_index]), "duckdb", None).unwrap(),
        Value::Null
    );
    let empty_label = parse_input_for_grid_cell("''", Some(&columns[status_index]), "duckdb", None).unwrap();
    assert_eq!(empty_label, Value::Text(String::new()));
    let empty_update = tablepro_core::sql_dialect::build_keyed_update(
        "duckdb",
        None,
        "moods",
        &columns,
        &[(status_index, empty_label)],
        &[Value::Int(4)],
    )
    .unwrap();
    connection.execute_in_transaction(&[empty_update]).await.unwrap();

    let escaped = parse_input_for_grid_cell("'O''Brien'", Some(&columns[status_index]), "duckdb", None).unwrap();
    assert_eq!(escaped, Value::Text("O'Brien".into()));
    let escaped_update = tablepro_core::sql_dialect::build_keyed_update(
        "duckdb",
        None,
        "moods",
        &columns,
        &[(status_index, escaped)],
        &[Value::Int(2)],
    )
    .unwrap();
    connection.execute_in_transaction(&[escaped_update]).await.unwrap();

    let invalid = parse_input_for_grid_cell("not a label", Some(&columns[status_index]), "duckdb", None).unwrap();
    let invalid_update = tablepro_core::sql_dialect::build_keyed_update(
        "duckdb",
        None,
        "moods",
        &columns,
        &[(status_index, invalid)],
        &[Value::Int(2)],
    )
    .unwrap();
    assert!(connection.execute_in_transaction(&[invalid_update]).await.is_err());

    let saved = connection
        .query("SELECT id, typeof(status), status::VARCHAR FROM moods ORDER BY id")
        .await
        .unwrap();
    let enum_type = match &saved.rows[0][1] {
        Value::Text(type_name) if type_name.starts_with("ENUM") => type_name.clone(),
        other => panic!("expected native ENUM type, got {other:?}"),
    };
    assert_eq!(
        saved.rows,
        vec![
            vec![Value::Int(1), Value::Text(enum_type.clone()), Value::Text("".into())],
            vec![
                Value::Int(2),
                Value::Text(enum_type.clone()),
                Value::Text("O'Brien".into())
            ],
            vec![Value::Int(3), Value::Text(enum_type.clone()), Value::Null],
            vec![Value::Int(4), Value::Text(enum_type.clone()), Value::Text("".into())],
            vec![
                Value::Int(5),
                Value::Text(enum_type.clone()),
                Value::Text("O'Brien".into())
            ],
        ]
    );
}

#[cfg(feature = "duckdb")]
#[tokio::test]
async fn value_contract_duckdb_enum_literal_null_edit_stays_distinct_from_sql_null() {
    use tablepro_core::{ConnectOptions, DatabaseDriver};

    let connection = drivers_duckdb::DuckdbDriver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    connection
        .execute("CREATE TYPE mood_null_label AS ENUM ('NULL', 'ready')")
        .await
        .unwrap();
    connection
        .execute("CREATE TABLE mood_null_labels (id INTEGER PRIMARY KEY, status mood_null_label)")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO mood_null_labels VALUES (1, 'ready'), (2, NULL)")
        .await
        .unwrap();

    let columns = connection.fetch_columns(None, "mood_null_labels").await.unwrap();
    let status_index = columns.iter().position(|column| column.name == "status").unwrap();
    let literal_null = parse_input_for_grid_cell("NULL", Some(&columns[status_index]), "duckdb", None).unwrap();
    assert_eq!(literal_null, Value::Text("NULL".into()));
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "duckdb",
        None,
        "mood_null_labels",
        &columns,
        &[(status_index, literal_null)],
        &[Value::Int(1)],
    )
    .unwrap();
    connection.execute_in_transaction(&[update]).await.unwrap();

    let result = connection
        .query(
            "SELECT id, typeof(status), status::VARCHAR, \
                    CASE WHEN status IS NULL THEN 'null' ELSE 'value' END \
             FROM mood_null_labels ORDER BY id",
        )
        .await
        .unwrap();
    let Value::Text(enum_type) = &result.rows[0][1] else {
        panic!("expected DuckDB ENUM type, got {:?}", result.rows[0][1]);
    };
    assert!(enum_type.starts_with("ENUM"), "{enum_type}");
    assert_eq!(
        result.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text(enum_type.clone()),
                Value::Text("NULL".into()),
                Value::Text("value".into()),
            ],
            vec![
                Value::Int(2),
                Value::Text(enum_type.clone()),
                Value::Null,
                Value::Text("null".into()),
            ],
        ]
    );
}

#[cfg(feature = "duckdb")]
#[tokio::test]
async fn value_contract_duckdb_enum_list_result_matches_native_json() {
    use tablepro_core::{ConnectOptions, DatabaseDriver};

    let connection = drivers_duckdb::DuckdbDriver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    connection
        .execute("CREATE TYPE mood_list AS ENUM ('NULL', '', '東京', 'ready')")
        .await
        .unwrap();

    let expression = "['NULL'::mood_list, NULL::mood_list, ''::mood_list, '東京'::mood_list]";
    let result = connection
        .query(&format!("SELECT {expression} AS value"))
        .await
        .unwrap();
    let native = connection
        .query(&format!(
            "SELECT typeof(value), to_json(value) FROM (SELECT {expression} AS value) AS source"
        ))
        .await
        .unwrap();
    assert!(
        matches!(&result.rows[0][0], Value::Undecodable(kind) if kind == "LIST"),
        "nested enum lists must be explicitly un-decodable: {:?}",
        result.rows[0][0]
    );
    assert!(tablepro_core::sql_literal::render_sql_literal("duckdb", &result.rows[0][0]).is_err());
    assert!(
        connection
            .query_params("SELECT ?", std::slice::from_ref(&result.rows[0][0]))
            .await
            .is_err()
    );
    let Value::Text(native_type) = &native.rows[0][0] else {
        panic!("native LIST<ENUM> type oracle returned {:?}", native.rows[0][0]);
    };
    assert!(
        native_type.starts_with("ENUM(") && native_type.ends_with("[]"),
        "{native_type}"
    );
    let Value::Text(json_text) = &native.rows[0][1] else {
        panic!("native LIST<ENUM> JSON oracle returned {:?}", native.rows[0][1]);
    };
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(json_text).unwrap(),
        serde_json::json!(["NULL", null, "", "東京"])
    );
}

#[cfg(feature = "duckdb")]
#[tokio::test]
async fn value_contract_duckdb_empty_enum_list_stays_distinct_from_sql_null() {
    use tablepro_core::{ConnectOptions, DatabaseDriver};

    let connection = drivers_duckdb::DuckdbDriver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    connection
        .execute("CREATE TYPE mood_empty_list AS ENUM ('NULL', 'ready')")
        .await
        .unwrap();

    let values = connection
        .query("SELECT []::mood_empty_list[] AS empty, NULL::mood_empty_list[] AS missing")
        .await
        .unwrap();
    assert_eq!(values.rows, vec![vec![Value::Undecodable("LIST".into()), Value::Null]]);
    assert!(tablepro_core::sql_literal::render_sql_literal("duckdb", &values.rows[0][0]).is_err());
    assert!(
        connection
            .query_params("SELECT ?", std::slice::from_ref(&values.rows[0][0]))
            .await
            .is_err()
    );

    let native = connection
        .query(
            "SELECT typeof(value), to_json(value) \
             FROM (SELECT []::mood_empty_list[] AS value \
                   UNION ALL SELECT NULL::mood_empty_list[]) AS source \
             ORDER BY CASE WHEN value IS NULL THEN 1 ELSE 0 END",
        )
        .await
        .unwrap();
    let Value::Text(list_type) = &native.rows[0][0] else {
        panic!("native empty-list type oracle returned {:?}", native.rows[0][0]);
    };
    assert!(
        list_type.starts_with("ENUM(") && list_type.ends_with("[]"),
        "{list_type}"
    );
    assert_eq!(
        native.rows,
        vec![
            vec![Value::Text(list_type.clone()), Value::Text("[]".into())],
            vec![Value::Text(list_type.clone()), Value::Null],
        ]
    );
}

#[cfg(feature = "duckdb")]
#[tokio::test]
async fn value_contract_duckdb_enum_csv_roundtrip_preserves_labels_and_null() {
    use tablepro_core::{ConnectOptions, DatabaseDriver};

    let connection = drivers_duckdb::DuckdbDriver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    connection
        .execute("CREATE TYPE mood_csv AS ENUM ('', 'NULL', '東京', 'O''Brien', '=1+1', '''=1+1', 'ready')")
        .await
        .unwrap();
    connection
        .execute("CREATE TABLE mood_csv_source (id INTEGER PRIMARY KEY, status mood_csv)")
        .await
        .unwrap();
    connection
        .execute("CREATE TABLE mood_csv_target (id INTEGER PRIMARY KEY, status mood_csv)")
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO mood_csv_source VALUES \
             (1, ''), (2, 'NULL'), (3, '東京'), (4, 'O''Brien'), \
             (5, '=1+1'), (6, '''=1+1'), (7, NULL)",
        )
        .await
        .unwrap();
    connection
        .execute("INSERT INTO mood_csv_target VALUES (99, 'ready')")
        .await
        .unwrap();

    let source = connection
        .query("SELECT id, status FROM mood_csv_source ORDER BY id")
        .await
        .unwrap();
    let marker = tablepro_core::export::unique_csv_null_marker(&source.rows);
    let export_options = tablepro_core::export::CsvOptions {
        null_to_empty: false,
        sanitize_formulas: false,
        null_marker: Some(marker.clone()),
        ..Default::default()
    };
    let csv = tablepro_core::export::render_csv(&source.columns, &source.rows, &export_options);
    assert_eq!(
        csv,
        format!("id,status\n1,\"\"\n2,NULL\n3,東京\n4,O'Brien\n5,=1+1\n6,'=1+1\n7,{marker}\n")
    );

    let import_options = tablepro_core::import::CsvImportOptions {
        null_marker: marker,
        ..Default::default()
    };
    let sheet = tablepro_core::import::read_csv(csv.as_bytes(), &import_options, None).unwrap();
    let columns = connection.fetch_columns(None, "mood_csv_target").await.unwrap();
    let plan = tablepro_core::import::build_insert_plan(
        &tablepro_core::import::ImportTarget {
            driver_id: "duckdb",
            schema: None,
            table: "mood_csv_target",
            columns: &columns,
            mapping: &[Some(0), Some(1)],
        },
        &sheet,
        &import_options,
    )
    .unwrap();
    assert_eq!(plan.rows, source.rows);
    for row in &plan.rows {
        connection.execute_params(&plan.statement, row).await.unwrap();
    }

    let safe_options = tablepro_core::export::CsvOptions {
        null_to_empty: false,
        sanitize_formulas: true,
        null_marker: Some(import_options.null_marker.clone()),
        ..Default::default()
    };
    let safe_csv = tablepro_core::export::render_csv(&source.columns, &source.rows, &safe_options);
    assert_eq!(
        safe_csv,
        format!(
            "id,status\n1,\"\"\n2,NULL\n3,東京\n4,O'Brien\n5,\"'=1+1\"\n6,'=1+1\n7,{marker}\n",
            marker = import_options.null_marker
        )
    );
    let safe_sheet = tablepro_core::import::read_csv(safe_csv.as_bytes(), &import_options, None).unwrap();
    let safe_plan = tablepro_core::import::build_insert_plan(
        &tablepro_core::import::ImportTarget {
            driver_id: "duckdb",
            schema: None,
            table: "mood_csv_target",
            columns: &columns,
            mapping: &[Some(0), Some(1)],
        },
        &safe_sheet,
        &import_options,
    )
    .unwrap();
    assert_eq!(
        safe_plan.rows[4][1],
        Value::Text("'=1+1".into()),
        "spreadsheet-safe CSV adds a leading apostrophe"
    );
    assert_eq!(
        safe_plan.rows[5][1], safe_plan.rows[4][1],
        "the leading-apostrophe enum label collides after safe export, so this mode is not lossless for restore"
    );

    let restored = connection
        .query(
            "SELECT id, typeof(status), status::VARCHAR, status IS NULL \
             FROM mood_csv_target ORDER BY id",
        )
        .await
        .unwrap();
    let Value::Text(enum_type) = &restored.rows[0][1] else {
        panic!("expected a native DuckDB ENUM type, got {:?}", restored.rows[0][1]);
    };
    assert!(enum_type.starts_with("ENUM"), "{enum_type}");
    let expected = [
        (1, Some(""), false),
        (2, Some("NULL"), false),
        (3, Some("東京"), false),
        (4, Some("O'Brien"), false),
        (5, Some("=1+1"), false),
        (6, Some("'=1+1"), false),
        (7, None, true),
        (99, Some("ready"), false),
    ];
    assert_eq!(restored.rows.len(), expected.len());
    for (row, (id, label, is_null)) in restored.rows.iter().zip(expected) {
        assert_eq!(row[0], Value::Int(id));
        assert_eq!(row[1], Value::Text(enum_type.clone()));
        assert_eq!(row[2], label.map_or(Value::Null, |label| Value::Text(label.into())));
        assert_eq!(row[3], Value::Bool(is_null));
    }
}
