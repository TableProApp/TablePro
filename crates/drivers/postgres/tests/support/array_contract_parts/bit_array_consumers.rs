#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_bit_arrays_roundtrip_wire_and_csv() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    connection
        .execute("CREATE TABLE bit_array_source (id integer PRIMARY KEY, fixed bit(5)[], variable bit varying[])")
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO bit_array_source VALUES
               (1, ARRAY[B'10101', B'00000', NULL]::bit(5)[],
                   ARRAY[B'1', B'10100101', B'', NULL]::bit varying[]),
               (2, NULL, NULL),
               (3, ARRAY[]::bit(5)[], ARRAY[]::bit varying[]),
               (4, '[0:1]={00001,11000}'::bit(5)[], '[0:1]={1,110000001}'::bit varying[])",
        )
        .await
        .unwrap();
    connection
        .execute("CREATE TABLE bit_array_target (id integer PRIMARY KEY, fixed bit(5)[], variable bit varying[])")
        .await
        .unwrap();

    let source = connection
        .query("SELECT id, fixed, variable FROM bit_array_source ORDER BY id")
        .await
        .unwrap();
    let native = connection
        .query(
            "SELECT id, fixed::text, variable::text,
                    pg_typeof(fixed)::text, pg_typeof(variable)::text,
                    array_to_json(fixed)::text, array_to_json(variable)::text,
                    encode(array_send(fixed), 'hex'), encode(array_send(variable), 'hex')
             FROM bit_array_source ORDER BY id",
        )
        .await
        .unwrap();
    for (row, oracle) in source.rows.iter().zip(&native.rows) {
        assert_eq!(row[0], oracle[0]);
        for (index, cast, json) in [
            (1, "bit(5)[]", &oracle[5]),
            (2, "bit varying[]", &oracle[6]),
        ] {
            let rebound = connection
                .query_params(
                    &format!("SELECT array_to_json($1::text::{cast})::text"),
                    std::slice::from_ref(&row[index]),
                )
                .await
                .unwrap();
            assert_eq!(rebound.rows[0][0], *json);
        }
    }
    assert_eq!(source.columns[1].data_type, "BIT[]");
    assert_eq!(source.columns[2].data_type, "VARBIT[]");

    for (value, cast, expected_wire) in [
        (&source.rows[0][1], "bit(5)[]", &native.rows[0][7]),
        (&source.rows[0][2], "bit varying[]", &native.rows[0][8]),
    ] {
        let rebound = connection
            .query_params(
                &format!("SELECT encode(array_send($1::text::{cast}), 'hex')"),
                std::slice::from_ref(value),
            )
            .await
            .unwrap();
        assert_eq!(rebound.rows[0][0], *expected_wire);
    }

    let null_marker = tablepro_core::export::unique_csv_null_marker(&source.rows);
    let csv = tablepro_core::export::render_csv(
        &source.columns,
        &source.rows,
        &tablepro_core::export::CsvOptions {
            null_marker: Some(null_marker.clone()),
            ..Default::default()
        },
    );
    let import_options = tablepro_core::import::CsvImportOptions {
        null_marker,
        ..Default::default()
    };
    let sheet = tablepro_core::import::read_csv(csv.as_bytes(), &import_options, None).unwrap();
    let columns = connection.fetch_columns(None, "bit_array_target").await.unwrap();
    let mapping = (0..columns.len()).map(Some).collect::<Vec<_>>();
    let plan = tablepro_core::import::build_insert_plan(
        &tablepro_core::import::ImportTarget {
            driver_id: "postgres",
            schema: None,
            table: "bit_array_target",
            columns: &columns,
            mapping: &mapping,
        },
        &sheet,
        &import_options,
    )
    .expect("BIT and VARBIT arrays should have safe native CSV casts");
    assert_eq!(plan.rows, source.rows);
    for row in &plan.rows {
        connection.execute_params(&plan.statement, row).await.unwrap();
    }
    let restored = connection
        .query(
            "SELECT id, fixed::text, variable::text,
                    pg_typeof(fixed)::text, pg_typeof(variable)::text,
                    array_to_json(fixed)::text, array_to_json(variable)::text,
                    encode(array_send(fixed), 'hex'), encode(array_send(variable), 'hex')
             FROM bit_array_target ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(restored.rows, native.rows);
}
