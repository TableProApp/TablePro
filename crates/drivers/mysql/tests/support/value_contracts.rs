use chrono::{NaiveDate, NaiveDateTime, NaiveTime, TimeZone, Utc};
use serde_json::json;

use tablepro_core::{ConnectOptions, Connection, OperationControl, Value};

use super::{connect, start_mariadb, start_mysql};

#[path = "../../../../core/tests/support/value_contract.rs"]
mod value_contract;

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_preserves_scalar_boundaries_through_parameters_and_exports() {
    let (_container, options) = start_mysql().await;
    let connection = connect(options).await;
    value_contract::assert_scalar_contract(connection.as_ref(), "mysql").await;
}

async fn connect_with_permissive_dates(options: ConnectOptions) -> Box<dyn Connection> {
    let admin = connect(options.clone()).await;
    admin.execute("SET GLOBAL sql_mode = ''").await.unwrap();
    admin.close().await.unwrap();
    connect(options).await
}

fn micros_time(hour: u32, minute: u32, second: u32, micro: u32) -> NaiveTime {
    NaiveTime::from_hms_micro_opt(hour, minute, second, micro).unwrap()
}

fn text(value: &str) -> Value {
    Value::Text(value.into())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn native_time_zero_date_and_year_values_survive_reads_parameters_and_exports() {
    let (_container, options) = start_mysql().await;
    let conn = connect_with_permissive_dates(options).await;
    let definition = "(id INT PRIMARY KEY, t TIME(6), d DATE, dt DATETIME(6), ts TIMESTAMP(6) NULL, y YEAR)";
    for table in ["native_source", "native_bound", "native_exported"] {
        conn.execute(&format!("CREATE TABLE {table} {definition}"))
            .await
            .unwrap();
    }
    conn.execute(
        "INSERT INTO native_source VALUES
         (1, '-01:00:00', '0000-00-00', '0000-00-00 00:00:00', '0000-00-00 00:00:00', 0),
         (2, '838:59:59', '2024-00-15', '2024-02-00 12:00:00.5', NULL, 2155),
         (3, '-838:59:59', '9999-12-31', '9999-12-31 23:59:59.999999', '2038-01-19 03:14:07.999999', 1901),
         (4, '-00:00:01.5', '1000-01-01', '1000-01-01 00:00:00', '1970-01-01 00:00:01', 2024),
         (5, '24:00:00', NULL, NULL, NULL, NULL),
         (6, '23:59:59.999999', NULL, NULL, NULL, NULL)",
    )
    .await
    .unwrap();

    let result = conn
        .query("SELECT id, t, d, dt, ts, y FROM native_source ORDER BY id")
        .await
        .unwrap();
    let date = |y, m, d| NaiveDate::from_ymd_opt(y, m, d).unwrap();
    let instant = |naive: NaiveDateTime| Utc.from_utc_datetime(&naive);
    let expected = vec![
        vec![
            Value::Int(1),
            text("-01:00:00"),
            text("0000-00-00"),
            text("0000-00-00 00:00:00"),
            text("0000-00-00 00:00:00"),
            Value::Int(0),
        ],
        vec![
            Value::Int(2),
            text("838:59:59"),
            text("2024-00-15"),
            text("2024-02-00 12:00:00.500000"),
            Value::Null,
            Value::Int(2155),
        ],
        vec![
            Value::Int(3),
            text("-838:59:59"),
            Value::Date(date(9999, 12, 31)),
            Value::DateTime(date(9999, 12, 31).and_time(micros_time(23, 59, 59, 999_999))),
            Value::TimestampTz(instant(date(2038, 1, 19).and_time(micros_time(3, 14, 7, 999_999)))),
            Value::Int(1901),
        ],
        vec![
            Value::Int(4),
            text("-00:00:01.500000"),
            Value::Date(date(1000, 1, 1)),
            Value::DateTime(date(1000, 1, 1).and_time(micros_time(0, 0, 0, 0))),
            Value::TimestampTz(instant(date(1970, 1, 1).and_time(micros_time(0, 0, 1, 0)))),
            Value::Int(2024),
        ],
        vec![
            Value::Int(5),
            text("24:00:00"),
            Value::Null,
            Value::Null,
            Value::Null,
            Value::Null,
        ],
        vec![
            Value::Int(6),
            Value::Time(micros_time(23, 59, 59, 999_999)),
            Value::Null,
            Value::Null,
            Value::Null,
            Value::Null,
        ],
    ];
    assert_eq!(result.rows, expected);

    let columns = conn.fetch_columns(None, "native_exported").await.unwrap();
    for row in &result.rows {
        conn.execute_params("INSERT INTO native_bound VALUES (?, ?, ?, ?, ?, ?)", row)
            .await
            .unwrap();
        let statement =
            tablepro_core::sql_literal::build_insert_literal("mysql", None, "native_exported", &columns, row).unwrap();
        conn.execute(&statement).await.unwrap();
    }
    for copy in ["native_bound", "native_exported"] {
        let matching = conn
            .query(&format!(
                "SELECT COUNT(*) FROM native_source s JOIN {copy} c ON s.id = c.id AND s.t <=> c.t \
                 AND s.d <=> c.d AND s.dt <=> c.dt AND s.ts <=> c.ts AND s.y <=> c.y"
            ))
            .await
            .unwrap();
        assert_eq!(matching.rows, vec![vec![Value::Int(6)]], "{copy}");
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn strict_zero_date_modes_refuse_invalid_dates_without_writing() {
    let (_container, options) = start_mysql().await;
    assert_strict_zero_date_modes_refuse_invalid_dates(&options, "MySQL").await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mariadb_strict_zero_date_modes_refuse_invalid_dates_without_writing() {
    let (_container, options) = start_mariadb().await;
    assert_strict_zero_date_modes_refuse_invalid_dates(&options, "MariaDB").await;
}

async fn assert_strict_zero_date_modes_refuse_invalid_dates(options: &ConnectOptions, engine: &str) {
    let conn = connect(options.clone()).await;
    conn.execute("CREATE TABLE strict_dates (id INT PRIMARY KEY, value DATE NOT NULL)")
        .await
        .unwrap();

    let mut session = conn.open_session().await.unwrap();
    let control = OperationControl::with_timeout(std::time::Duration::from_secs(30));
    session
        .query_params_controlled(
            "SET SESSION sql_mode = 'STRICT_TRANS_TABLES,NO_ZERO_DATE,NO_ZERO_IN_DATE'",
            &[],
            &control,
        )
        .await
        .unwrap();
    let mode = session
        .query_params_controlled("SELECT @@SESSION.sql_mode", &[], &control)
        .await
        .unwrap();
    assert!(
        matches!(&mode.rows[0][0], Value::Text(mode) if mode.contains("STRICT_TRANS_TABLES") && mode.contains("NO_ZERO_DATE") && mode.contains("NO_ZERO_IN_DATE")),
        "{engine} session mode: {:?}",
        mode.rows[0][0]
    );

    for (id, value) in [(1, "0000-00-00"), (2, "2024-00-15")] {
        let error = session
            .query_params_controlled(
                &format!("INSERT INTO strict_dates VALUES ({id}, '{value}')"),
                &[],
                &control,
            )
            .await
            .expect_err("strict zero-date modes must reject zero and incomplete dates");
        assert!(
            matches!(
                &error,
                tablepro_core::DriverError::Query {
                    sqlstate: Some(code), ..
                } if code == "22007"
            ),
            "{engine}, id {id}, date {value}: {error:?}"
        );
    }

    session
        .query_params_controlled("INSERT INTO strict_dates VALUES (3, '2024-02-15')", &[], &control)
        .await
        .unwrap();
    let stored = session
        .query_params_controlled(
            "SELECT id, value, CAST(value AS CHAR) FROM strict_dates ORDER BY id",
            &[],
            &control,
        )
        .await
        .unwrap();
    assert_eq!(
        stored.rows,
        vec![vec![
            Value::Int(3),
            Value::Date(NaiveDate::from_ymd_opt(2024, 2, 15).unwrap()),
            text("2024-02-15"),
        ]]
    );
    session.close().await.unwrap();
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mysql_time_fractional_storage_respects_truncate_mode_for_binds_and_literals() {
    let (_container, options) = start_mysql().await;
    assert_fractional_storage_mode_for_binds_and_literals(
        &options,
        "TIME(3)",
        "TIME_TRUNCATE_FRACTIONAL",
        Value::Time(micros_time(12, 34, 56, 789_900)),
        790_000,
        789_000,
        |microseconds| {
            (
                Value::Time(micros_time(12, 34, 56, microseconds)),
                format!("12:34:56.{:03}", microseconds / 1_000),
            )
        },
    )
    .await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mariadb_time_fractional_storage_respects_round_mode_for_binds_and_literals() {
    let (_container, options) = start_mariadb().await;
    assert_fractional_storage_mode_for_binds_and_literals(
        &options,
        "TIME(3)",
        "TIME_ROUND_FRACTIONAL",
        Value::Time(micros_time(12, 34, 56, 789_900)),
        789_000,
        790_000,
        |microseconds| {
            (
                Value::Time(micros_time(12, 34, 56, microseconds)),
                format!("12:34:56.{:03}", microseconds / 1_000),
            )
        },
    )
    .await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mysql_time_fractional_half_millisecond_boundary_respects_truncate_mode() {
    let (_container, options) = start_mysql().await;
    assert_fractional_storage_mode_for_binds_and_literals(
        &options,
        "TIME(3)",
        "TIME_TRUNCATE_FRACTIONAL",
        Value::Time(micros_time(12, 34, 56, 789_500)),
        790_000,
        789_000,
        |microseconds| {
            (
                Value::Time(micros_time(12, 34, 56, microseconds)),
                format!("12:34:56.{:03}", microseconds / 1_000),
            )
        },
    )
    .await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mariadb_time_fractional_half_millisecond_boundary_respects_round_mode() {
    let (_container, options) = start_mariadb().await;
    assert_fractional_storage_mode_for_binds_and_literals(
        &options,
        "TIME(3)",
        "TIME_ROUND_FRACTIONAL",
        Value::Time(micros_time(12, 34, 56, 789_500)),
        789_000,
        790_000,
        |microseconds| {
            (
                Value::Time(micros_time(12, 34, 56, microseconds)),
                format!("12:34:56.{:03}", microseconds / 1_000),
            )
        },
    )
    .await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mysql_datetime_fractional_storage_respects_truncate_mode_for_binds_and_literals() {
    let (_container, options) = start_mysql().await;
    assert_fractional_storage_mode_for_binds_and_literals(
        &options,
        "DATETIME(3)",
        "TIME_TRUNCATE_FRACTIONAL",
        Value::DateTime(
            NaiveDate::from_ymd_opt(2024, 1, 2)
                .unwrap()
                .and_time(micros_time(3, 4, 5, 789_900)),
        ),
        790_000,
        789_000,
        |microseconds| {
            (
                Value::DateTime(NaiveDate::from_ymd_opt(2024, 1, 2).unwrap().and_time(micros_time(
                    3,
                    4,
                    5,
                    microseconds,
                ))),
                format!("2024-01-02 03:04:05.{:03}", microseconds / 1_000),
            )
        },
    )
    .await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mariadb_datetime_fractional_storage_respects_round_mode_for_binds_and_literals() {
    let (_container, options) = start_mariadb().await;
    assert_fractional_storage_mode_for_binds_and_literals(
        &options,
        "DATETIME(3)",
        "TIME_ROUND_FRACTIONAL",
        Value::DateTime(
            NaiveDate::from_ymd_opt(2024, 1, 2)
                .unwrap()
                .and_time(micros_time(3, 4, 5, 789_900)),
        ),
        789_000,
        790_000,
        |microseconds| {
            (
                Value::DateTime(NaiveDate::from_ymd_opt(2024, 1, 2).unwrap().and_time(micros_time(
                    3,
                    4,
                    5,
                    microseconds,
                ))),
                format!("2024-01-02 03:04:05.{:03}", microseconds / 1_000),
            )
        },
    )
    .await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mysql_datetime_fractional_half_millisecond_boundary_respects_truncate_mode() {
    let (_container, options) = start_mysql().await;
    let date = NaiveDate::from_ymd_opt(2024, 1, 2).unwrap();
    assert_fractional_storage_mode_for_binds_and_literals(
        &options,
        "DATETIME(3)",
        "TIME_TRUNCATE_FRACTIONAL",
        Value::DateTime(date.and_time(micros_time(3, 4, 5, 789_500))),
        790_000,
        789_000,
        |microseconds| {
            (
                Value::DateTime(date.and_time(micros_time(3, 4, 5, microseconds))),
                format!("2024-01-02 03:04:05.{:03}", microseconds / 1_000),
            )
        },
    )
    .await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mariadb_datetime_fractional_half_millisecond_boundary_respects_round_mode() {
    let (_container, options) = start_mariadb().await;
    let date = NaiveDate::from_ymd_opt(2024, 1, 2).unwrap();
    assert_fractional_storage_mode_for_binds_and_literals(
        &options,
        "DATETIME(3)",
        "TIME_ROUND_FRACTIONAL",
        Value::DateTime(date.and_time(micros_time(3, 4, 5, 789_500))),
        789_000,
        790_000,
        |microseconds| {
            (
                Value::DateTime(date.and_time(micros_time(3, 4, 5, microseconds))),
                format!("2024-01-02 03:04:05.{:03}", microseconds / 1_000),
            )
        },
    )
    .await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mysql_timestamp_fractional_storage_respects_truncate_mode_for_binds_and_literals() {
    let (_container, options) = start_mysql().await;
    let instant = Utc.with_ymd_and_hms(2024, 1, 2, 3, 4, 5).unwrap();
    assert_fractional_storage_mode_for_binds_and_literals(
        &options,
        "TIMESTAMP(3)",
        "TIME_TRUNCATE_FRACTIONAL",
        Value::TimestampTz(instant + chrono::Duration::microseconds(789_900)),
        790_000,
        789_000,
        |microseconds| {
            let value = instant + chrono::Duration::microseconds(i64::from(microseconds));
            (
                Value::TimestampTz(value),
                format!("2024-01-02 03:04:05.{:03}", microseconds / 1_000),
            )
        },
    )
    .await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mariadb_timestamp_fractional_storage_respects_round_mode_for_binds_and_literals() {
    let (_container, options) = start_mariadb().await;
    let instant = Utc.with_ymd_and_hms(2024, 1, 2, 3, 4, 5).unwrap();
    assert_fractional_storage_mode_for_binds_and_literals(
        &options,
        "TIMESTAMP(3)",
        "TIME_ROUND_FRACTIONAL",
        Value::TimestampTz(instant + chrono::Duration::microseconds(789_900)),
        789_000,
        790_000,
        |microseconds| {
            let value = instant + chrono::Duration::microseconds(i64::from(microseconds));
            (
                Value::TimestampTz(value),
                format!("2024-01-02 03:04:05.{:03}", microseconds / 1_000),
            )
        },
    )
    .await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mysql_timestamp_fractional_half_millisecond_boundary_respects_truncate_mode() {
    let (_container, options) = start_mysql().await;
    let instant = Utc.with_ymd_and_hms(2024, 1, 2, 3, 4, 5).unwrap();
    assert_fractional_storage_mode_for_binds_and_literals(
        &options,
        "TIMESTAMP(3)",
        "TIME_TRUNCATE_FRACTIONAL",
        Value::TimestampTz(instant + chrono::Duration::microseconds(789_500)),
        790_000,
        789_000,
        |microseconds| {
            let value = instant + chrono::Duration::microseconds(i64::from(microseconds));
            (
                Value::TimestampTz(value),
                format!("2024-01-02 03:04:05.{:03}", microseconds / 1_000),
            )
        },
    )
    .await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mariadb_timestamp_fractional_half_millisecond_boundary_respects_round_mode() {
    let (_container, options) = start_mariadb().await;
    let instant = Utc.with_ymd_and_hms(2024, 1, 2, 3, 4, 5).unwrap();
    assert_fractional_storage_mode_for_binds_and_literals(
        &options,
        "TIMESTAMP(3)",
        "TIME_ROUND_FRACTIONAL",
        Value::TimestampTz(instant + chrono::Duration::microseconds(789_500)),
        789_000,
        790_000,
        |microseconds| {
            let value = instant + chrono::Duration::microseconds(i64::from(microseconds));
            (
                Value::TimestampTz(value),
                format!("2024-01-02 03:04:05.{:03}", microseconds / 1_000),
            )
        },
    )
    .await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mysql_time_fractional_precision_matrix_respects_truncate_mode() {
    let (_container, options) = start_mysql().await;
    assert_time_fractional_precision_matrix(&options, "TIME_TRUNCATE_FRACTIONAL", true, false).await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mariadb_time_fractional_precision_matrix_respects_round_mode() {
    let (_container, options) = start_mariadb().await;
    assert_time_fractional_precision_matrix(&options, "TIME_ROUND_FRACTIONAL", false, true).await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mysql_datetime_and_timestamp_fractional_precision_matrix_respects_truncate_mode() {
    let (_container, options) = start_mysql().await;
    assert_datetime_and_timestamp_fractional_precision_matrix(&options, "TIME_TRUNCATE_FRACTIONAL", true, false).await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mariadb_datetime_and_timestamp_fractional_precision_matrix_respects_round_mode() {
    let (_container, options) = start_mariadb().await;
    assert_datetime_and_timestamp_fractional_precision_matrix(&options, "TIME_ROUND_FRACTIONAL", false, true).await;
}

async fn assert_datetime_and_timestamp_fractional_precision_matrix(
    options: &ConnectOptions,
    alternate_mode: &str,
    baseline_rounds: bool,
    alternate_rounds: bool,
) {
    let conn = connect(options.clone()).await;
    let definitions = (0..=6)
        .map(|precision| format!("datetime_{precision} DATETIME({precision}) NOT NULL"))
        .chain((0..=6).map(|precision| format!("timestamp_{precision} TIMESTAMP({precision}) NOT NULL")))
        .collect::<Vec<_>>()
        .join(", ");
    conn.execute(&format!(
        "CREATE TABLE fractional_temporal_precision_values (id INT PRIMARY KEY, {definitions})"
    ))
    .await
    .unwrap();
    let columns = conn
        .fetch_columns(None, "fractional_temporal_precision_values")
        .await
        .unwrap();
    let mut session = conn.open_session().await.unwrap();
    let control = OperationControl::with_timeout(std::time::Duration::from_secs(30));
    session
        .query_params_controlled("SET SESSION time_zone = '+00:00'", &[], &control)
        .await
        .unwrap();

    let date = NaiveDate::from_ymd_opt(2024, 1, 2).unwrap();
    let input_datetime = Value::DateTime(date.and_time(micros_time(3, 4, 5, 789_956)));
    let input_timestamp = Value::TimestampTz(Utc.from_utc_datetime(&date.and_time(micros_time(3, 4, 5, 789_956))));
    for (mode, bound_id, literal_id) in [("", 1, 2), (alternate_mode, 3, 4)] {
        session
            .query_params_controlled(&format!("SET SESSION sql_mode = '{mode}'"), &[], &control)
            .await
            .unwrap();
        for (id, literal) in [(bound_id, false), (literal_id, true)] {
            let mut row = vec![Value::Int(id)];
            row.extend((0..=6).map(|_| input_datetime.clone()));
            row.extend((0..=6).map(|_| input_timestamp.clone()));
            if literal {
                let statement = tablepro_core::sql_literal::build_insert_literal(
                    "mysql",
                    None,
                    "fractional_temporal_precision_values",
                    &columns,
                    &row,
                )
                .unwrap();
                session
                    .query_params_controlled(&statement, &[], &control)
                    .await
                    .unwrap();
            } else {
                let placeholders = (0..row.len()).map(|_| "?").collect::<Vec<_>>().join(", ");
                session
                    .query_params_controlled(
                        &format!("INSERT INTO fractional_temporal_precision_values VALUES ({placeholders})"),
                        &row,
                        &control,
                    )
                    .await
                    .unwrap();
            }
        }
    }

    let projections = (0..=6)
        .flat_map(|precision| {
            [
                format!("datetime_{precision}"),
                format!("CAST(datetime_{precision} AS CHAR)"),
                format!("MICROSECOND(datetime_{precision})"),
            ]
        })
        .chain((0..=6).flat_map(|precision| {
            [
                format!("timestamp_{precision}"),
                format!("CAST(timestamp_{precision} AS CHAR)"),
                format!("MICROSECOND(timestamp_{precision})"),
                format!("CAST(UNIX_TIMESTAMP(timestamp_{precision}) * 1000000 AS SIGNED)"),
            ]
        }))
        .collect::<Vec<_>>()
        .join(", ");
    let result = session
        .query_params_controlled(
            &format!("SELECT id, {projections} FROM fractional_temporal_precision_values ORDER BY id"),
            &[],
            &control,
        )
        .await
        .unwrap();
    let expected_row = |id, rounds| {
        let mut row = vec![Value::Int(id)];
        for precision in 0..=6 {
            row.extend(expected_fractional_datetime(precision, rounds, false));
        }
        for precision in 0..=6 {
            row.extend(expected_fractional_datetime(precision, rounds, true));
        }
        row
    };
    assert_eq!(
        result.rows,
        vec![
            expected_row(1, baseline_rounds),
            expected_row(2, baseline_rounds),
            expected_row(3, alternate_rounds),
            expected_row(4, alternate_rounds),
        ]
    );
    session.close().await.unwrap();
}

fn expected_fractional_datetime(precision: u32, rounds: bool, timestamp: bool) -> Vec<Value> {
    let input_micros = i64::from((3 * 60 + 4) * 60 + 5) * 1_000_000 + 789_956;
    let quantum = 10_i64.pow(6 - precision);
    let stored_micros = if rounds {
        (input_micros + quantum / 2) / quantum * quantum
    } else {
        input_micros / quantum * quantum
    };
    let seconds = (stored_micros / 1_000_000) as u32;
    let microseconds = (stored_micros % 1_000_000) as u32;
    let date = NaiveDate::from_ymd_opt(2024, 1, 2).unwrap();
    let value = date
        .and_hms_micro_opt(seconds / 3600, seconds / 60 % 60, seconds % 60, microseconds)
        .unwrap();
    let rendered = if precision == 0 {
        value.format("%Y-%m-%d %H:%M:%S").to_string()
    } else {
        format!(
            "{}.{}",
            value.format("%Y-%m-%d %H:%M:%S"),
            microseconds / quantum as u32
        )
    };
    let mut expected = vec![
        if timestamp {
            Value::TimestampTz(Utc.from_utc_datetime(&value))
        } else {
            Value::DateTime(value)
        },
        Value::Text(rendered),
        Value::Int(i64::from(microseconds)),
    ];
    if timestamp {
        expected.push(Value::Int(Utc.from_utc_datetime(&value).timestamp_micros()));
    }
    expected
}

async fn assert_time_fractional_precision_matrix(
    options: &ConnectOptions,
    alternate_mode: &str,
    baseline_rounds: bool,
    alternate_rounds: bool,
) {
    let conn = connect(options.clone()).await;
    let precisions = 0..=6;
    let definitions = precisions
        .map(|precision| format!("value_{precision} TIME({precision}) NOT NULL"))
        .collect::<Vec<_>>()
        .join(", ");
    conn.execute(&format!(
        "CREATE TABLE fractional_precision_values (id INT PRIMARY KEY, {definitions})"
    ))
    .await
    .unwrap();
    let columns = conn.fetch_columns(None, "fractional_precision_values").await.unwrap();
    let mut session = conn.open_session().await.unwrap();
    let control = OperationControl::with_timeout(std::time::Duration::from_secs(30));
    session
        .query_params_controlled("SET SESSION time_zone = '+00:00'", &[], &control)
        .await
        .unwrap();

    let input = Value::Time(micros_time(12, 34, 56, 789_956));
    for (mode, bound_id, literal_id) in [("", 1, 2), (alternate_mode, 3, 4)] {
        session
            .query_params_controlled(&format!("SET SESSION sql_mode = '{mode}'"), &[], &control)
            .await
            .unwrap();
        for (id, literal) in [(bound_id, false), (literal_id, true)] {
            let mut row = vec![Value::Int(id)];
            row.extend((0..=6).map(|_| input.clone()));
            if literal {
                let statement = tablepro_core::sql_literal::build_insert_literal(
                    "mysql",
                    None,
                    "fractional_precision_values",
                    &columns,
                    &row,
                )
                .unwrap();
                session
                    .query_params_controlled(&statement, &[], &control)
                    .await
                    .unwrap();
            } else {
                let placeholders = (0..row.len()).map(|_| "?").collect::<Vec<_>>().join(", ");
                session
                    .query_params_controlled(
                        &format!("INSERT INTO fractional_precision_values VALUES ({placeholders})"),
                        &row,
                        &control,
                    )
                    .await
                    .unwrap();
            }
        }
    }

    let projections = (0..=6)
        .flat_map(|precision| {
            [
                format!("value_{precision}"),
                format!("CAST(value_{precision} AS CHAR)"),
                format!("MICROSECOND(value_{precision})"),
            ]
        })
        .collect::<Vec<_>>()
        .join(", ");
    let result = session
        .query_params_controlled(
            &format!("SELECT id, {projections} FROM fractional_precision_values ORDER BY id"),
            &[],
            &control,
        )
        .await
        .unwrap();
    let expected_row = |id, rounds| {
        let mut row = vec![Value::Int(id)];
        for precision in 0..=6 {
            let (value, rendered, microseconds) = expected_fractional_time(precision, rounds);
            row.extend([value, Value::Text(rendered), Value::Int(microseconds)]);
        }
        row
    };
    assert_eq!(
        result.rows,
        vec![
            expected_row(1, baseline_rounds),
            expected_row(2, baseline_rounds),
            expected_row(3, alternate_rounds),
            expected_row(4, alternate_rounds),
        ]
    );
    session.close().await.unwrap();
}

fn expected_fractional_time(precision: u32, rounds: bool) -> (Value, String, i64) {
    let input_micros = i64::from((12 * 60 + 34) * 60 + 56) * 1_000_000 + 789_956;
    let quantum = 10_i64.pow(6 - precision);
    let stored_micros = if rounds {
        (input_micros + quantum / 2) / quantum * quantum
    } else {
        input_micros / quantum * quantum
    };
    let seconds = (stored_micros / 1_000_000) as u32;
    let microseconds = (stored_micros % 1_000_000) as u32;
    let value = NaiveTime::from_num_seconds_from_midnight_opt(seconds, microseconds * 1_000).unwrap();
    let rendered = if precision == 0 {
        format!("{:02}:{:02}:{:02}", seconds / 3600, seconds / 60 % 60, seconds % 60)
    } else {
        format!(
            "{:02}:{:02}:{:02}.{:0width$}",
            seconds / 3600,
            seconds / 60 % 60,
            seconds % 60,
            microseconds / quantum as u32,
            width = precision as usize,
        )
    };
    (Value::Time(value), rendered, i64::from(microseconds))
}

async fn assert_fractional_storage_mode_for_binds_and_literals(
    options: &ConnectOptions,
    column_type: &str,
    alternate_mode: &str,
    input: Value,
    baseline_microseconds: u32,
    alternate_microseconds: u32,
    value_and_text_for_microseconds: impl Fn(u32) -> (Value, String),
) {
    let conn = connect(options.clone()).await;
    conn.execute(&format!(
        "CREATE TABLE fractional_values (id INT PRIMARY KEY, value {column_type} NOT NULL)"
    ))
    .await
    .unwrap();
    let columns = conn.fetch_columns(None, "fractional_values").await.unwrap();
    let mut session = conn.open_session().await.unwrap();
    let control = OperationControl::with_timeout(std::time::Duration::from_secs(30));
    let timestamp_epoch_seconds = match &input {
        Value::TimestampTz(timestamp) => Some(timestamp.timestamp()),
        _ => None,
    };
    session
        .query_params_controlled("SET SESSION time_zone = '+00:00'", &[], &control)
        .await
        .unwrap();

    for (mode, bound_id, literal_id) in [("", 1, 2), (alternate_mode, 3, 4)] {
        session
            .query_params_controlled(&format!("SET SESSION sql_mode = '{mode}'"), &[], &control)
            .await
            .unwrap();
        session
            .query_params_controlled(
                "INSERT INTO fractional_values VALUES (?, ?)",
                &[Value::Int(bound_id), input.clone()],
                &control,
            )
            .await
            .unwrap();
        let literal = tablepro_core::sql_literal::build_insert_literal(
            "mysql",
            None,
            "fractional_values",
            &columns,
            &[Value::Int(literal_id), input.clone()],
        )
        .unwrap();
        session.query_params_controlled(&literal, &[], &control).await.unwrap();
    }

    let epoch_projection = if timestamp_epoch_seconds.is_some() {
        ", CAST(UNIX_TIMESTAMP(value) * 1000000 AS SIGNED)"
    } else {
        ""
    };
    let result = session
        .query_params_controlled(
            &format!(
                "SELECT id, value, CAST(value AS CHAR), MICROSECOND(value){epoch_projection} \
                 FROM fractional_values ORDER BY id"
            ),
            &[],
            &control,
        )
        .await
        .unwrap();
    let expected_row = |id, microseconds| {
        let (value, text) = value_and_text_for_microseconds(microseconds);
        let mut row = vec![
            Value::Int(id),
            value,
            Value::Text(text),
            Value::Int(i64::from(microseconds)),
        ];
        if let Some(epoch_seconds) = timestamp_epoch_seconds {
            row.push(Value::Int(epoch_seconds * 1_000_000 + i64::from(microseconds)));
        }
        row
    };
    assert_eq!(
        result.rows,
        vec![
            expected_row(1, baseline_microseconds),
            expected_row(2, baseline_microseconds),
            expected_row(3, alternate_microseconds),
            expected_row(4, alternate_microseconds),
        ]
    );
    session.close().await.unwrap();
}

const BACKSLASH_SENSITIVE_TEXTS: [&str; 7] = [
    "a\\b",
    "\\",
    "x\\' OR 1=1 -- ",
    "line\nbreak\\n",
    "nul\0byte",
    "\\0 \\Z \\% \\_ \\\\",
    "plain 'quoted' text",
];

async fn connect_in_sql_mode(options: &ConnectOptions, mode: &str) -> Box<dyn Connection> {
    let admin = connect(options.clone()).await;
    admin.execute(&format!("SET GLOBAL sql_mode = '{mode}'")).await.unwrap();
    admin.close().await.unwrap();
    let conn = connect(options.clone()).await;
    let active = conn.query("SELECT @@SESSION.sql_mode").await.unwrap().rows[0][0].clone();
    let Value::Text(active) = active else {
        panic!("{active:?}")
    };
    let active_modes = active.split(',').map(str::trim).collect::<Vec<_>>();
    let expected_modes = mode.split(',').map(str::trim).filter(|mode| !mode.is_empty());
    for expected_mode in expected_modes {
        assert!(
            active_modes.contains(&expected_mode),
            "mode {expected_mode:?} missing from {active:?}"
        );
    }
    assert_eq!(
        active_modes.contains(&"NO_BACKSLASH_ESCAPES"),
        mode.split(',').any(|mode| mode.trim() == "NO_BACKSLASH_ESCAPES"),
        "NO_BACKSLASH_ESCAPES mode mismatch: {active}"
    );
    conn
}

async fn assert_text_exports_survive_sql_mode(options: &ConnectOptions, mode: &str, suffix: usize) {
    let conn = connect_in_sql_mode(options, mode).await;
    let (source, copy) = (format!("escaped_source_{suffix}"), format!("escaped_copy_{suffix}"));
    conn.execute(&format!(
        "CREATE TABLE {source} (id INT PRIMARY KEY, label TEXT, doc JSON)"
    ))
    .await
    .unwrap();
    conn.execute(&format!("CREATE TABLE {copy} LIKE {source}"))
        .await
        .unwrap();
    let doc = json!({"k": "a\\b\"c\n\0"});
    for (id, label) in BACKSLASH_SENSITIVE_TEXTS.iter().enumerate() {
        conn.execute_params(
            &format!("INSERT INTO {source} VALUES (?, ?, ?)"),
            &[
                Value::Int(id as i64),
                Value::Text((*label).into()),
                Value::Json(doc.clone()),
            ],
        )
        .await
        .unwrap();
    }
    let rows = conn
        .query(&format!("SELECT id, label, doc FROM {source} ORDER BY id"))
        .await
        .unwrap()
        .rows;
    let labels: Vec<Value> = rows.iter().map(|row| row[1].clone()).collect();
    let expected: Vec<Value> = BACKSLASH_SENSITIVE_TEXTS
        .iter()
        .map(|label| Value::Text((*label).into()))
        .collect();
    assert_eq!(labels, expected, "sql_mode '{mode}'");
    let columns = conn.fetch_columns(None, &copy).await.unwrap();
    for row in &rows {
        let statement = tablepro_core::sql_literal::build_insert_literal("mysql", None, &copy, &columns, row).unwrap();
        conn.execute(&statement)
            .await
            .unwrap_or_else(|error| panic!("sql_mode '{mode}': {statement}: {error}"));
    }
    let matching = conn
        .query(&format!(
            "SELECT COUNT(*) FROM {source} s JOIN {copy} c ON s.id = c.id \
             AND HEX(s.label) = HEX(c.label) AND HEX(s.doc) = HEX(c.doc)"
        ))
        .await
        .unwrap();
    assert_eq!(
        matching.rows,
        vec![vec![Value::Int(BACKSLASH_SENSITIVE_TEXTS.len() as i64)]],
        "sql_mode '{mode}'"
    );
}

async fn assert_text_exports_survive_both_backslash_modes(options: ConnectOptions) {
    for (suffix, mode) in [
        "",
        "NO_BACKSLASH_ESCAPES",
        "ANSI_QUOTES",
        "ANSI_QUOTES,NO_BACKSLASH_ESCAPES",
    ]
    .into_iter()
    .enumerate()
    {
        assert_text_exports_survive_sql_mode(&options, mode, suffix).await;
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_text_exports_survive_with_and_without_backslash_escapes() {
    let (_container, options) = start_mysql().await;
    assert_text_exports_survive_both_backslash_modes(options).await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_mariadb_text_exports_survive_with_and_without_backslash_escapes() {
    let (_container, options) = start_mariadb().await;
    assert_text_exports_survive_both_backslash_modes(options).await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_mysql_pad_char_mode_keeps_fixed_width_text_through_csv_and_writes() {
    let (_container, options) = start_mysql().await;
    let connection = connect_in_sql_mode(&options, "PAD_CHAR_TO_FULL_LENGTH").await;
    for table in ["pad_char_source", "pad_char_bound", "pad_char_literal"] {
        connection
            .execute(&format!("CREATE TABLE {table} (value CHAR(5) NOT NULL)"))
            .await
            .unwrap();
    }
    connection
        .execute("INSERT INTO pad_char_source VALUES ('x')")
        .await
        .unwrap();

    let source = connection
        .query("SELECT value, CHAR_LENGTH(value), HEX(value) FROM pad_char_source")
        .await
        .unwrap();
    assert_eq!(
        source.rows,
        vec![vec![
            Value::Text("x    ".into()),
            Value::Int(5),
            Value::Text("7820202020".into())
        ]],
        "PAD_CHAR_TO_FULL_LENGTH must expose the native five-byte CHAR value"
    );

    let csv = tablepro_core::export::render_csv(
        &source.columns[..1],
        &[source.rows[0][..1].to_vec()],
        &tablepro_core::export::CsvOptions::default(),
    );
    let options = tablepro_core::import::CsvImportOptions::default();
    let sheet = tablepro_core::import::read_csv(csv.as_bytes(), &options, None).unwrap();
    let columns = connection.fetch_columns(None, "pad_char_bound").await.unwrap();
    let imported = tablepro_core::import::row_to_values(&sheet.rows[0], &[Some(0)], &columns, &options, 2).unwrap();
    assert_eq!(imported, vec![Value::Text("x    ".into())]);
    connection
        .execute_params("INSERT INTO pad_char_bound VALUES (?)", &imported)
        .await
        .unwrap();

    let literal_columns = connection.fetch_columns(None, "pad_char_literal").await.unwrap();
    let literal = tablepro_core::sql_literal::build_insert_literal(
        "mysql",
        None,
        "pad_char_literal",
        &literal_columns,
        &imported,
    )
    .unwrap();
    connection.execute(&literal).await.unwrap();

    for table in ["pad_char_bound", "pad_char_literal"] {
        let persisted = connection
            .query(&format!("SELECT CHAR_LENGTH(value), HEX(value) FROM {table}"))
            .await
            .unwrap();
        assert_eq!(
            persisted.rows,
            vec![vec![Value::Int(5), Value::Text("7820202020".into())]],
            "CSV, bound and SQL-literal writes must retain CHAR padding in {table}"
        );
    }
}

const PACKED_DEFINITION: &str = "(id INT PRIMARY KEY, flags BIT(8), wide BIT(64), tiny BIT(1), \
     mood ENUM('happy', 'it''s ok', 'ünï', ''), perms SET('read', 'write', 'ëx'), shape GEOMETRY, \
     pin POINT SRID 4326)";

async fn server_bytes(conn: &dyn Connection, sql: &str) -> Vec<Value> {
    let rows = conn.query(sql).await.unwrap().rows;
    rows.into_iter()
        .map(|row| match &row[0] {
            Value::Null => Value::Null,
            Value::Text(hex) => Value::Bytes(
                (0..hex.len())
                    .step_by(2)
                    .map(|at| u8::from_str_radix(&hex[at..at + 2], 16).unwrap())
                    .collect(),
            ),
            other => panic!("{other:?}"),
        })
        .collect()
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_bit_enum_set_and_geometry_survive_reads_parameters_and_exports() {
    let (_container, options) = start_mysql().await;
    let conn = connect(options).await;
    for table in ["packed_source", "packed_bound", "packed_exported"] {
        conn.execute(&format!("CREATE TABLE {table} {PACKED_DEFINITION}"))
            .await
            .unwrap();
    }
    conn.execute(
        "INSERT INTO packed_source VALUES \
         (1, b'10101010', 0xFFFFFFFFFFFFFFFF, b'1', 'happy', 'read,ëx', \
          ST_GeomFromText('POLYGON((0 0, 1 0, 1 1, 0 0))'), ST_GeomFromText('POINT(52.5 13.4)', 4326)), \
         (2, b'0', 0x8000000000000000, b'0', 'it''s ok', '', \
          ST_GeomFromText('POINT(-1.5 2.25)', 3857), ST_GeomFromText('POINT(0 0)', 4326)), \
         (3, b'1', 0x7FFFFFFFFFFFFFFF, NULL, 'ünï', 'write', NULL, NULL), \
         (4, NULL, 0, NULL, '', 'read,write,ëx', NULL, NULL), \
         (5, NULL, NULL, NULL, NULL, NULL, NULL, NULL)",
    )
    .await
    .unwrap();
    let rows = conn
        .query("SELECT id, flags, wide, tiny, mood, perms, shape, pin FROM packed_source ORDER BY id")
        .await
        .unwrap()
        .rows;
    let column = |index: usize| rows.iter().map(|row| row[index].clone()).collect::<Vec<_>>();
    let ints = |values: [Option<i64>; 5]| values.map(|value| value.map_or(Value::Null, Value::Int)).to_vec();
    assert_eq!(column(1), ints([Some(170), Some(0), Some(1), None, None]));
    assert_eq!(
        column(2),
        vec![
            Value::Bytes(vec![0xff; 8]),
            Value::Bytes(vec![0x80, 0, 0, 0, 0, 0, 0, 0]),
            Value::Int(i64::MAX),
            Value::Int(0),
            Value::Null,
        ]
    );
    assert_eq!(column(3), ints([Some(1), Some(0), None, None, None]));
    let texts = |values: [Option<&str>; 5]| values.map(|value| value.map_or(Value::Null, text)).to_vec();
    assert_eq!(
        column(4),
        texts([Some("happy"), Some("it's ok"), Some("ünï"), Some(""), None])
    );
    assert_eq!(
        column(5),
        texts([Some("read,ëx"), Some(""), Some("write"), Some("read,write,ëx"), None])
    );
    let shapes = server_bytes(conn.as_ref(), "SELECT HEX(shape) FROM packed_source ORDER BY id").await;
    let pins = server_bytes(conn.as_ref(), "SELECT HEX(pin) FROM packed_source ORDER BY id").await;
    assert_eq!(column(6), shapes);
    assert_eq!(column(7), pins);

    let columns = conn.fetch_columns(None, "packed_exported").await.unwrap();
    for row in &rows {
        conn.execute_params("INSERT INTO packed_bound VALUES (?, ?, ?, ?, ?, ?, ?, ?)", row)
            .await
            .unwrap();
        let statement =
            tablepro_core::sql_literal::build_insert_literal("mysql", None, "packed_exported", &columns, row).unwrap();
        conn.execute(&statement)
            .await
            .unwrap_or_else(|error| panic!("{statement}: {error}"));
    }
    for copy in ["packed_bound", "packed_exported"] {
        let matching = conn
            .query(&format!(
                "SELECT COUNT(*) FROM packed_source s JOIN {copy} c ON s.id = c.id \
                 AND s.flags <=> c.flags AND s.wide <=> c.wide AND s.tiny <=> c.tiny \
                 AND s.mood + 0 <=> c.mood + 0 AND s.perms + 0 <=> c.perms + 0 \
                 AND HEX(s.shape) <=> HEX(c.shape) AND HEX(s.pin) <=> HEX(c.pin)"
            ))
            .await
            .unwrap();
        assert_eq!(matching.rows, vec![vec![Value::Int(5)]], "{copy}");
    }

    conn.execute("CREATE TABLE packed_edit (id INT PRIMARY KEY, flags BIT(8), tiny BIT(1))")
        .await
        .unwrap();
    conn.execute("INSERT INTO packed_edit VALUES (1, b'10101010', b'1')")
        .await
        .unwrap();
    conn.execute_params(
        "UPDATE packed_edit SET flags = ?, tiny = ? WHERE id = ?",
        &[Value::Int(85), Value::Bool(false), Value::Int(1)],
    )
    .await
    .unwrap();
    let edited = conn
        .query("SELECT flags, tiny FROM packed_edit WHERE id = 1")
        .await
        .unwrap();
    assert_eq!(edited.rows, vec![vec![Value::Int(85), Value::Int(0)]]);
}
