use tablepro_core::{Connection, QueryResult};

use super::zoned_copies_matching;

pub(super) async fn assert_csv_round_trip(connection: &dyn Connection, source: &QueryResult) {
    connection
        .execute("SELECT * INTO zoned_csv_copy FROM zoned_source WHERE 1 = 0")
        .await
        .unwrap();
    let json: serde_json::Value =
        serde_json::from_str(&tablepro_core::export::render_json(&source.columns, &source.rows)).unwrap();
    for (index, stamp) in super::ZONED_STAMPS.iter().enumerate() {
        assert_eq!(json[index]["zoned"], serde_json::Value::String((*stamp).into()));
    }
    let csv = tablepro_core::export::render_csv(
        &source.columns,
        &source.rows,
        &tablepro_core::export::CsvOptions::default(),
    );
    let options = tablepro_core::import::CsvImportOptions::default();
    let sheet = tablepro_core::import::read_csv(csv.as_bytes(), &options, None).unwrap();
    let mapping = (0..source.columns.len()).map(Some).collect::<Vec<_>>();

    for (index, fields) in sheet.rows.iter().enumerate() {
        let values =
            tablepro_core::import::row_to_values(fields, &mapping, &source.columns, &options, index + 2).unwrap();
        assert_eq!(
            values, source.rows[index],
            "CSV import must preserve the datetimeoffset text, including its original offset"
        );
        connection
            .execute_params("INSERT INTO zoned_csv_copy VALUES (@P1, @P2)", &values)
            .await
            .unwrap();
    }

    assert_eq!(
        zoned_copies_matching(connection, "zoned_csv_copy").await,
        tablepro_core::Value::Int(source.rows.len() as i64),
        "CSV import must preserve both the instant and source UTC offsets"
    );
}
