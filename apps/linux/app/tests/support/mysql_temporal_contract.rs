use super::parse_input_for_driver;
use tablepro_core::{ColumnInfo, Value};

fn col(data_type: &str, nullable: bool) -> ColumnInfo {
    ColumnInfo {
        name: "value".into(),
        data_type: data_type.into(),
        nullable,
        primary_key: false,
        is_auto_increment: false,
        default_value: None,
        is_generated: false,
        comment: None,
        collation: None,
        enum_type: None,
        domain_type: None,
    }
}

#[test]
fn value_contract_mysql_temporal_parser_keeps_fractional_input_typed() {
    assert_eq!(
        parse_input_for_driver("12:34:56.123456", Some(&col("time(6)", false)), "mysql"),
        Ok(Value::Time(
            chrono::NaiveTime::from_hms_micro_opt(12, 34, 56, 123_456).unwrap()
        ))
    );
    assert_eq!(
        parse_input_for_driver("2024-01-02 03:04:05.123456", Some(&col("datetime(6)", false)), "mysql"),
        Ok(Value::DateTime(
            chrono::NaiveDate::from_ymd_opt(2024, 1, 2)
                .unwrap()
                .and_hms_micro_opt(3, 4, 5, 123_456)
                .unwrap()
        ))
    );
    assert_eq!(
        parse_input_for_driver("2024-01-02 03:04:05.123456", Some(&col("timestamp(6)", false)), "mysql"),
        Ok(Value::DateTime(
            chrono::NaiveDate::from_ymd_opt(2024, 1, 2)
                .unwrap()
                .and_hms_micro_opt(3, 4, 5, 123_456)
                .unwrap()
        )),
        "MySQL TIMESTAMP grid text parses to a naive datetime for the UTC session binding"
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_mysql_temporal_parser_keyed_edit_preserves_native_values_and_siblings() {
    use chrono::{TimeZone, Utc};
    use tablepro_core::{ConnectOptions, DatabaseDriver, OperationControl, TlsConfig};
    use testcontainers::ImageExt;
    use testcontainers::runners::AsyncRunner;
    use testcontainers_modules::mysql::Mysql;

    let container = Mysql::default()
        .with_env_var("MYSQL_ROOT_PASSWORD", "tablepro_test")
        .with_cmd(["--default-authentication-plugin=mysql_native_password"])
        .start()
        .await
        .unwrap();
    let connection = drivers_mysql::MysqlDriver
        .connect(ConnectOptions {
            host: container.get_host().await.unwrap().to_string(),
            port: container.get_host_port_ipv4(3306).await.unwrap(),
            database: "test".into(),
            username: "root".into(),
            password: secrecy::SecretString::new("tablepro_test".to_string().into()),
            tls: TlsConfig::disabled(),
            ..Default::default()
        })
        .await
        .unwrap();
    let control = OperationControl::with_timeout(std::time::Duration::from_secs(30));
    let mut session = connection.open_session().await.unwrap();
    session
        .query_params_controlled("SET SESSION time_zone = '+00:00'", &[], &control)
        .await
        .unwrap();
    session
        .query_params_controlled(
            "CREATE TABLE temporal_grid_edit (
                id INT PRIMARY KEY,
                clock TIME(6) NOT NULL,
                local_at DATETIME(6) NOT NULL,
                instant TIMESTAMP(6) NOT NULL
            )",
            &[],
            &control,
        )
        .await
        .unwrap();
    session
        .query_params_controlled(
            "INSERT INTO temporal_grid_edit VALUES
                (1, '01:02:03.654321', '2024-01-02 01:02:03.654321', '2024-01-02 01:02:03.654321'),
                (2, '04:05:06.987654', '2024-02-03 04:05:06.987654', '2024-02-03 04:05:06.987654')",
            &[],
            &control,
        )
        .await
        .unwrap();

    let columns = connection.fetch_columns(None, "temporal_grid_edit").await.unwrap();
    let index = |name: &str| columns.iter().position(|column| column.name == name).unwrap();
    let clock = index("clock");
    let local_at = index("local_at");
    let instant = index("instant");
    assert!(columns[index("id")].primary_key);
    assert_eq!(columns[clock].data_type, "time(6)");
    assert_eq!(columns[local_at].data_type, "datetime(6)");
    assert_eq!(columns[instant].data_type, "timestamp(6)");

    let clock_value = parse_input_for_driver("12:34:56.123456", Some(&columns[clock]), "mysql").unwrap();
    let datetime_value =
        parse_input_for_driver("2024-01-02 03:04:05.123456", Some(&columns[local_at]), "mysql").unwrap();
    let timestamp_value =
        parse_input_for_driver("2024-01-02 03:04:05.123456", Some(&columns[instant]), "mysql").unwrap();
    assert!(matches!(&timestamp_value, Value::DateTime(_)));
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "mysql",
        None,
        "temporal_grid_edit",
        &columns,
        &[
            (clock, clock_value),
            (local_at, datetime_value),
            (instant, timestamp_value),
        ],
        &[Value::Int(1)],
    )
    .unwrap();
    session
        .query_params_controlled(&update.0, &update.1, &control)
        .await
        .unwrap();

    let saved = session
        .query_params_controlled(
            "SELECT id, clock, CAST(clock AS CHAR), MICROSECOND(clock),
                    local_at, CAST(local_at AS CHAR), MICROSECOND(local_at),
                    instant, CAST(instant AS CHAR), MICROSECOND(instant),
                    CAST(UNIX_TIMESTAMP(instant) * 1000000 AS SIGNED)
             FROM temporal_grid_edit ORDER BY id",
            &[],
            &control,
        )
        .await
        .unwrap();
    let edited_instant = Utc.with_ymd_and_hms(2024, 1, 2, 3, 4, 5).unwrap() + chrono::Duration::microseconds(123_456);
    let sibling_instant = Utc.with_ymd_and_hms(2024, 2, 3, 4, 5, 6).unwrap() + chrono::Duration::microseconds(987_654);
    assert_eq!(
        saved.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Time(chrono::NaiveTime::from_hms_micro_opt(12, 34, 56, 123_456).unwrap()),
                Value::Text("12:34:56.123456".into()),
                Value::Int(123_456),
                Value::DateTime(
                    chrono::NaiveDate::from_ymd_opt(2024, 1, 2)
                        .unwrap()
                        .and_hms_micro_opt(3, 4, 5, 123_456)
                        .unwrap()
                ),
                Value::Text("2024-01-02 03:04:05.123456".into()),
                Value::Int(123_456),
                Value::TimestampTz(edited_instant),
                Value::Text("2024-01-02 03:04:05.123456".into()),
                Value::Int(123_456),
                Value::Int(edited_instant.timestamp_micros()),
            ],
            vec![
                Value::Int(2),
                Value::Time(chrono::NaiveTime::from_hms_micro_opt(4, 5, 6, 987_654).unwrap()),
                Value::Text("04:05:06.987654".into()),
                Value::Int(987_654),
                Value::DateTime(
                    chrono::NaiveDate::from_ymd_opt(2024, 2, 3)
                        .unwrap()
                        .and_hms_micro_opt(4, 5, 6, 987_654)
                        .unwrap()
                ),
                Value::Text("2024-02-03 04:05:06.987654".into()),
                Value::Int(987_654),
                Value::TimestampTz(sibling_instant),
                Value::Text("2024-02-03 04:05:06.987654".into()),
                Value::Int(987_654),
                Value::Int(sibling_instant.timestamp_micros()),
            ],
        ]
    );

    let export = session
        .query_params_controlled(
            "SELECT id, clock, local_at, instant FROM temporal_grid_edit ORDER BY id",
            &[],
            &control,
        )
        .await
        .unwrap();
    let csv_options = tablepro_core::export::CsvOptions::default();
    let csv = tablepro_core::export::render_csv(&export.columns, &export.rows, &csv_options);
    assert_eq!(
        csv,
        "id,clock,local_at,instant\n\
         1,12:34:56.123456,2024-01-02 03:04:05.123456,2024-01-02T03:04:05.123456+00:00\n\
         2,04:05:06.987654,2024-02-03 04:05:06.987654,2024-02-03T04:05:06.987654+00:00\n"
    );
    let json: serde_json::Value =
        serde_json::from_str(&tablepro_core::export::render_json(&export.columns, &export.rows)).unwrap();
    assert_eq!(json[0]["clock"], "12:34:56.123456");
    assert_eq!(json[0]["local_at"], "2024-01-02 03:04:05.123456");
    assert_eq!(json[0]["instant"], "2024-01-02T03:04:05.123456+00:00");

    let directory = tempfile::tempdir().unwrap();
    let workbook_path = directory.path().join("mysql-temporal.xlsx");
    tablepro_core::export::write_result_file(
        &workbook_path,
        &export,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Xlsx,
            csv: &csv_options,
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap();
    let mut archive = zip::ZipArchive::new(std::fs::File::open(workbook_path).unwrap()).unwrap();
    let mut shared_strings = String::new();
    std::io::Read::read_to_string(
        &mut archive.by_name("xl/sharedStrings.xml").unwrap(),
        &mut shared_strings,
    )
    .unwrap();
    for value in [
        "12:34:56.123456",
        "2024-01-02 03:04:05.123456",
        "2024-01-02T03:04:05.123456+00:00",
    ] {
        assert!(shared_strings.contains(&format!("<t>{value}</t>")), "{shared_strings}");
    }

    session
        .query_params_controlled(
            "CREATE TABLE temporal_grid_imported LIKE temporal_grid_edit",
            &[],
            &control,
        )
        .await
        .unwrap();
    let import_columns = connection.fetch_columns(None, "temporal_grid_imported").await.unwrap();
    let sheet = tablepro_core::import::read_csv(
        csv.as_bytes(),
        &tablepro_core::import::CsvImportOptions::default(),
        None,
    )
    .unwrap();
    let mapping = vec![Some(0), Some(1), Some(2), Some(3)];
    let plan = tablepro_core::import::build_insert_plan(
        &tablepro_core::import::ImportTarget {
            driver_id: "mysql",
            schema: None,
            table: "temporal_grid_imported",
            columns: &import_columns,
            mapping: &mapping,
        },
        &sheet,
        &tablepro_core::import::CsvImportOptions::default(),
    )
    .unwrap();
    assert_eq!(
        plan.rows,
        export
            .rows
            .iter()
            .map(|row| vec![row[0].clone(), row[1].clone(), row[2].clone(), row[3].clone()])
            .collect::<Vec<_>>()
    );
    for row in &plan.rows {
        session
            .query_params_controlled(&plan.statement, row, &control)
            .await
            .unwrap();
    }
    let imported = session
        .query_params_controlled(
            "SELECT id, clock, local_at, instant FROM temporal_grid_imported ORDER BY id",
            &[],
            &control,
        )
        .await
        .unwrap();
    assert_eq!(imported.rows, export.rows);
    session.close().await.unwrap();
}
