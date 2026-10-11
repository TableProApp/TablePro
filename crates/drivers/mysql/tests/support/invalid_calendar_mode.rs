use tablepro_core::{ConnectOptions, Connection, OperationControl, Session, Value};

use super::{connect, start_mariadb, start_mysql};

fn stored_row() -> Vec<Value> {
    [
        "2024-02-31",
        "2024-04-31",
        "2024-02-31 12:34:56",
        "2024-02-31 12:34:56.123456",
    ]
    .map(|text| Value::Text(text.into()))
    .to_vec()
}

fn native_row() -> Vec<Value> {
    let mut row = stored_row();
    row.extend(
        ["20240231", "20240431", "20240231123456", "20240231123456.123456"].map(|text| Value::Text(text.into())),
    );
    row
}

fn native_query(table: &str) -> String {
    format!(
        "SELECT CAST(d AS CHAR), CAST(d_april AS CHAR), CAST(dt AS CHAR), CAST(dt_fractional AS CHAR), \
         CAST(d + 0 AS CHAR), CAST(d_april + 0 AS CHAR), CAST(dt + 0 AS CHAR), CAST(dt_fractional + 0 AS CHAR) \
         FROM {table}"
    )
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mysql_allow_invalid_dates_preserves_native_calendar_text() {
    let (_container, options) = start_mysql().await;
    assert_invalid_calendar_text(&options, "MySQL").await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mariadb_allow_invalid_dates_preserves_native_calendar_text() {
    let (_container, options) = start_mariadb().await;
    assert_invalid_calendar_text(&options, "MariaDB").await;
}

async fn assert_invalid_calendar_text(options: &ConnectOptions, engine: &str) {
    let connection = connect(options.clone()).await;
    connection
        .execute("CREATE TABLE allow_invalid_dates (d DATE, d_april DATE, dt DATETIME, dt_fractional DATETIME(6))")
        .await
        .unwrap();
    let mut session = connection.open_session().await.unwrap();
    let control = OperationControl::with_timeout(std::time::Duration::from_secs(30));
    session
        .query_params_controlled("SET SESSION sql_mode = 'ALLOW_INVALID_DATES'", &[], &control)
        .await
        .unwrap();
    session
        .query_params_controlled(
            "INSERT INTO allow_invalid_dates VALUES \
             ('2024-02-31', '2024-04-31', '2024-02-31 12:34:56', '2024-02-31 12:34:56.123456')",
            &[],
            &control,
        )
        .await
        .unwrap_or_else(|error| panic!("{engine} must accept the calendar values in ALLOW_INVALID_DATES: {error}"));

    let result = session
        .query_params_controlled(
            "SELECT d, d_april, dt, dt_fractional FROM allow_invalid_dates",
            &[],
            &control,
        )
        .await
        .unwrap();
    assert_eq!(result.rows, vec![stored_row()], "{engine} driver values");
    let native = session
        .query_params_controlled(&native_query("allow_invalid_dates"), &[], &control)
        .await
        .unwrap();
    assert_eq!(native.rows, vec![native_row()], "{engine} native storage oracle");
    assert_invalid_calendar_csv_round_trip(connection.as_ref(), session.as_mut(), &result, &control).await;
}

async fn assert_invalid_calendar_csv_round_trip(
    connection: &dyn Connection,
    session: &mut dyn Session,
    source: &tablepro_core::QueryResult,
    control: &OperationControl,
) {
    let csv = tablepro_core::export::render_csv(
        &source.columns,
        &source.rows,
        &tablepro_core::export::CsvOptions::default(),
    );
    let options = tablepro_core::import::CsvImportOptions::default();
    let sheet = tablepro_core::import::read_csv(csv.as_bytes(), &options, None).unwrap();
    session
        .query_params_controlled(
            "CREATE TABLE allow_invalid_dates_csv_copy \
             (d DATE, d_april DATE, dt DATETIME, dt_fractional DATETIME(6))",
            &[],
            control,
        )
        .await
        .unwrap();
    let columns = connection
        .fetch_columns(None, "allow_invalid_dates_csv_copy")
        .await
        .unwrap();
    let mapping = (0..columns.len()).map(Some).collect::<Vec<_>>();
    let plan = tablepro_core::import::build_insert_plan(
        &tablepro_core::import::ImportTarget {
            driver_id: "mysql",
            schema: None,
            table: "allow_invalid_dates_csv_copy",
            columns: &columns,
            mapping: &mapping,
        },
        &sheet,
        &options,
    )
    .expect("CSV import must retain the native invalid calendar values");
    let imported = plan.rows[0].clone();
    assert_eq!(imported, stored_row());
    session
        .query_params_controlled(&plan.statement, &imported, control)
        .await
        .unwrap();
    let restored = session
        .query_params_controlled(&native_query("allow_invalid_dates_csv_copy"), &[], control)
        .await
        .unwrap();
    assert_eq!(restored.rows, vec![native_row()]);
}
