use tablepro_core::Value;

#[tokio::test]
async fn value_contract_extended_timestamptz_matches_duckdb_text_and_epoch() {
    let connection = crate::native_connection().await;
    connection.execute("SET TimeZone = 'UTC'").await.unwrap();
    connection
        .execute("CREATE TABLE extended_timestamptz_source (id INTEGER, moment TIMESTAMPTZ)")
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO extended_timestamptz_source VALUES \
             (1, TIMESTAMPTZ '280000-02-29 12:34:56.123456+05:30')",
        )
        .await
        .unwrap();
    let source = connection
        .query("SELECT * FROM extended_timestamptz_source")
        .await
        .unwrap();
    assert_eq!(source.rows[0][1], Value::Text("280000-02-29 07:04:56.123456+00".into()));
    let result = connection
        .query("SELECT TIMESTAMPTZ '280000-02-29 12:34:56.123456+05:30'")
        .await
        .unwrap();
    let oracle = connection
        .query("SELECT CAST(TIMESTAMPTZ '280000-02-29 12:34:56.123456+05:30' AS VARCHAR)")
        .await
        .unwrap();
    assert_eq!(
        result.rows[0][0], oracle.rows[0][0],
        "extended TIMESTAMPTZ result should retain a reusable zone marker"
    );
    assert_eq!(
        connection
            .query_params(
                "SELECT epoch_us(CAST(? AS TIMESTAMPTZ)) = epoch_us(TIMESTAMPTZ '280000-02-29 12:34:56.123456+05:30')",
                &[result.rows[0][0].clone()],
            )
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Bool(true)]]
    );
    let literal = tablepro_core::sql_literal::render_sql_literal("duckdb", &result.rows[0][0]).unwrap();
    assert_eq!(
        connection
            .query(&format!(
                "SELECT epoch_us(CAST({literal} AS TIMESTAMPTZ)) = \
                 epoch_us(TIMESTAMPTZ '280000-02-29 12:34:56.123456+05:30')"
            ))
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Bool(true)]]
    );

    connection
        .execute("CREATE TABLE extended_timestamptz_import (id INTEGER, moment TIMESTAMPTZ)")
        .await
        .unwrap();
    let csv = tablepro_core::export::render_csv(
        &source.columns,
        &source.rows,
        &tablepro_core::export::CsvOptions::default(),
    );
    let options = tablepro_core::import::CsvImportOptions::default();
    let sheet = tablepro_core::import::read_csv(csv.as_bytes(), &options, None).unwrap();
    let columns = connection
        .fetch_columns(None, "extended_timestamptz_import")
        .await
        .unwrap();
    let plan = tablepro_core::import::build_insert_plan(
        &tablepro_core::import::ImportTarget {
            driver_id: "duckdb",
            schema: None,
            table: "extended_timestamptz_import",
            columns: &columns,
            mapping: &[Some(0), Some(1)],
        },
        &sheet,
        &options,
    )
    .unwrap();
    for row in &plan.rows {
        connection.execute_params(&plan.statement, row).await.unwrap();
    }
    assert_eq!(
        connection
            .query(
                "SELECT epoch_us(moment) = epoch_us(TIMESTAMPTZ '280000-02-29 12:34:56.123456+05:30') \
                 FROM extended_timestamptz_import"
            )
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Bool(true)]]
    );
}
