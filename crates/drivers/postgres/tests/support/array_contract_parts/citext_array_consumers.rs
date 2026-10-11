#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_citext_array_decodes_and_rebinds_exact_values() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    connection.execute("CREATE EXTENSION citext").await.unwrap();
    connection
        .execute("CREATE TABLE citext_array_source (id int, labels citext[])")
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO citext_array_source VALUES
               (1, '[0:1][3:5]={{\"Foo\",\"foo\",\"NULL\"},{\"\",\"a\\\"b\",NULL}}'::citext[]),
               (2, NULL), (3, ARRAY[]::citext[])",
        )
        .await
        .unwrap();

    let result = connection
        .query(
            "SELECT id, labels, labels::text, pg_typeof(labels)::text,
                    encode(array_send(labels), 'hex')
             FROM citext_array_source ORDER BY id",
        )
        .await
        .unwrap();
    let expected = r#"[0:1][3:5]={{"Foo","foo","NULL"},{"","a\"b",NULL}}"#;
    let server_text = r#"[0:1][3:5]={{Foo,foo,"NULL"},{"","a\"b",NULL}}"#;
    assert_eq!(result.rows[0][1], Value::Text(expected.into()));
    assert_eq!(result.rows[0][2], Value::Text(server_text.into()));
    assert_eq!(result.rows[0][3], Value::Text("citext[]".into()));
    assert!(matches!(&result.rows[0][4], Value::Text(wire) if !wire.is_empty()));
    assert_eq!(result.rows[1][1], Value::Null);
    assert_eq!(result.rows[2][1], Value::Text("{}".into()));

    let case = connection
        .query("SELECT labels[0][3]::text, labels[0][4]::text, labels[0][3] = labels[0][4] FROM citext_array_source WHERE id = 1")
        .await
        .unwrap();
    assert_eq!(case.rows[0][0], Value::Text("Foo".into()));
    assert_eq!(case.rows[0][1], Value::Text("foo".into()));
    assert_eq!(case.rows[0][2], Value::Bool(true));

    connection.execute("CREATE SCHEMA citext_shadow").await.unwrap();
    connection
        .execute("CREATE TYPE citext_shadow.citext AS (value text)")
        .await
        .unwrap();
    let shadow = connection
        .query("SELECT ARRAY[ROW('not text')::citext_shadow.citext]")
        .await
        .unwrap();
    assert!(matches!(shadow.rows[0][0], Value::Undecodable(_)));

    let value = &result.rows[0][1];
    let rebound = connection
        .query_params(
            "SELECT $1::citext[] AS value, encode(array_send($1::citext[]), 'hex') AS wire",
            std::slice::from_ref(value),
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0][0], *value);
    assert_eq!(rebound.rows[0][1], result.rows[0][4]);
    connection
        .query_params(
            "UPDATE citext_array_source SET labels = $1 WHERE id = 1",
            std::slice::from_ref(value),
        )
        .await
        .unwrap();
    let updated = connection
        .query("SELECT encode(array_send(labels), 'hex') FROM citext_array_source WHERE id = 1")
        .await
        .unwrap();
    assert_eq!(updated.rows[0][0], result.rows[0][4]);

    let malformed = Value::Text(r#"{"unterminated}"#.into());
    assert!(connection
        .query_params(
            "UPDATE citext_array_source SET labels = $1::citext[] WHERE id = 1",
            &[malformed],
        )
        .await
        .is_err());
    let unchanged = connection
        .query("SELECT encode(array_send(labels), 'hex') FROM citext_array_source WHERE id = 1")
        .await
        .unwrap();
    assert_eq!(unchanged.rows[0][0], result.rows[0][4]);

    let csv = tablepro_core::export::render_csv(
        &result.columns,
        &result.rows,
        &Default::default(),
    );
    assert!(csv.contains("[0:1][3:5]={{"));
    assert!(!csv.contains("<undecodable CITEXT[]>"));

    connection
        .execute("CREATE TABLE citext_array_target (id integer PRIMARY KEY, labels citext[])")
        .await
        .unwrap();
    let source = connection
        .query("SELECT id, labels FROM citext_array_source ORDER BY id")
        .await
        .unwrap();
    let null_marker = tablepro_core::export::unique_csv_null_marker(&source.rows);
    let csv = tablepro_core::export::render_csv(
        &source.columns,
        &source.rows,
        &tablepro_core::export::CsvOptions {
            null_marker: Some(null_marker.clone()),
            ..Default::default()
        },
    );
    let options = tablepro_core::import::CsvImportOptions {
        null_marker,
        ..Default::default()
    };
    let sheet = tablepro_core::import::read_csv(csv.as_bytes(), &options, None).unwrap();
    let columns = connection.fetch_columns(None, "citext_array_target").await.unwrap();
    let mapping = (0..columns.len()).map(Some).collect::<Vec<_>>();
    let plan = tablepro_core::import::build_insert_plan(
        &tablepro_core::import::ImportTarget {
            driver_id: "postgres",
            schema: None,
            table: "citext_array_target",
            columns: &columns,
            mapping: &mapping,
        },
        &sheet,
        &options,
    )
    .unwrap();
    assert_eq!(plan.rows, source.rows);
    for row in &plan.rows {
        connection.execute_params(&plan.statement, row).await.unwrap();
    }
    let restored = connection
        .query(
            "SELECT id, pg_typeof(labels)::text, labels::text, array_to_json(labels)::text, \
             encode(array_send(labels), 'hex') FROM citext_array_target ORDER BY id",
        )
        .await
        .unwrap();
    let source_native = connection
        .query(
            "SELECT id, pg_typeof(labels)::text, labels::text, array_to_json(labels)::text, \
             encode(array_send(labels), 'hex') FROM citext_array_source ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(restored.rows, source_native.rows);
}
