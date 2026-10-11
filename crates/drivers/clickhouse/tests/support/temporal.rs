use chrono::NaiveDate;
use tablepro_core::Value;

#[tokio::test]
#[ignore = "requires docker"]
async fn second_precision_datetime64_beyond_nanosecond_limit_round_trips() {
    let (_container, options) = super::start_clickhouse().await;
    let connection = super::connect(options).await;
    for (precision, fraction, nanos) in [
        (0, "", 0),
        (1, ".1", 100_000_000),
        (2, ".12", 120_000_000),
        (3, ".123", 123_000_000),
        (4, ".1234", 123_400_000),
        (5, ".12345", 123_450_000),
        (6, ".123456", 123_456_000),
        (7, ".1234567", 123_456_700),
    ] {
        let value_text = format!("2299-12-31 23:59:59{fraction}");
        let stamp = NaiveDate::from_ymd_opt(2299, 12, 31)
            .unwrap()
            .and_hms_nano_opt(23, 59, 59, nanos)
            .unwrap();
        let expected = vec![vec![
            Value::DateTime(stamp),
            Value::Int(stamp.and_utc().timestamp_millis()),
        ]];

        let expression = format!("toDateTime64('{value_text}', {precision})");
        let native = connection
            .query(&format!("SELECT {expression}, toUnixTimestamp64Milli({expression})"))
            .await
            .unwrap_or_else(|error| panic!("native DateTime64({precision}) oracle: {error:?}"));
        assert_eq!(native.rows, expected, "native scale {precision} is exact");

        let values = [Value::DateTime(stamp), Value::DateTime(stamp)];
        let cast = format!("DateTime64({precision})");
        let bound = connection
            .query_params(
                &format!("SELECT CAST(? AS {cast}), toUnixTimestamp64Milli(CAST(? AS {cast}))"),
                &values,
            )
            .await
            .unwrap_or_else(|error| panic!("bound DateTime64({precision}) value: {error:?}"));
        assert_eq!(bound.rows, expected, "bound scale {precision} is exact");

        let literal = tablepro_core::sql_literal::render_sql_literal("clickhouse", &Value::DateTime(stamp))
            .expect("representable DateTime64 value has a SQL literal");
        let exported = connection
            .query(&format!(
                "SELECT CAST({literal} AS {cast}), toUnixTimestamp64Milli(CAST({literal} AS {cast}))"
            ))
            .await
            .unwrap_or_else(|error| panic!("literal DateTime64({precision}) value: {error:?}"));
        assert_eq!(exported.rows, expected, "SQL literal scale {precision} is exact");
    }
}
