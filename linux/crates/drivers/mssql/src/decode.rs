use chrono::{DateTime, Days, FixedOffset, NaiveDate, NaiveDateTime, NaiveTime};
use tablepro_core::value::{OffsetTimestamp, SqlDecimal, SqlTime, Temporal, UndecodableReason, UndecodedValue, Value};
use tiberius::time::{Date, DateTime as TdsDateTime, DateTime2, DateTimeOffset, SmallDateTime, Time};
use tiberius::{ColumnData, Row};

use crate::catalog::type_label;

const NANOS_PER_SECOND: u64 = 1_000_000_000;

/// Every cell of a row, in column order.
pub(crate) fn decode_row(row: &Row) -> Vec<Value> {
    row.cells()
        .map(|(column, data)| decode_cell(data, type_label(column.column_type())))
        .collect()
}

/// One cell, exactly. A NULL is the only thing that reads as `Null`; a
/// value the driver cannot represent says so instead.
pub(crate) fn decode_cell(data: &ColumnData<'static>, type_name: &str) -> Value {
    let decoded = match data {
        ColumnData::Bit(value) => value.map(Value::Bool),
        ColumnData::U8(value) => value.map(|integer| Value::Int(i64::from(integer))),
        ColumnData::I16(value) => value.map(|integer| Value::Int(i64::from(integer))),
        ColumnData::I32(value) => value.map(|integer| Value::Int(i64::from(integer))),
        ColumnData::I64(value) => value.map(Value::Int),
        ColumnData::F32(value) => value.map(Value::Float32),
        // MONEY arrives here too: tiberius reads it as a float. Browse
        // reads money columns through a decimal cast instead.
        ColumnData::F64(value) => value.map(Value::Float64),
        ColumnData::String(value) => value.as_ref().map(|text| Value::Text(text.to_string())),
        ColumnData::Guid(value) => value.map(Value::Uuid),
        // CLR types such as geography and hierarchyid arrive as their
        // serialised bytes.
        ColumnData::Binary(value) => value.as_ref().map(|bytes| Value::Bytes(bytes.to_vec())),
        // The wire carries the scaled integer, so no digit of a
        // decimal(38,x) is rounded on the way.
        ColumnData::Numeric(value) => value.map(|numeric| {
            Value::Decimal(SqlDecimal::from_scaled_i128(
                numeric.value(),
                u32::from(numeric.scale()),
            ))
        }),
        ColumnData::Xml(value) => value.as_ref().map(|xml| Value::Text(xml.to_string())),
        ColumnData::Date(value) => {
            value.map(|date| temporal(date_of(date).map(|date| Value::Date(Temporal::Finite(date))), type_name))
        }
        ColumnData::Time(value) => value.map(|time| {
            temporal(
                time_of(time).map(|time| Value::Time(SqlTime::from_time_of_day(time))),
                type_name,
            )
        }),
        ColumnData::DateTime2(value) => value.map(|stamp| {
            temporal(
                datetime2_of(stamp).map(|stamp| Value::Timestamp(Temporal::Finite(stamp))),
                type_name,
            )
        }),
        ColumnData::DateTime(value) => value.map(|stamp| {
            temporal(
                datetime_of(stamp).map(|stamp| Value::Timestamp(Temporal::Finite(stamp))),
                type_name,
            )
        }),
        ColumnData::SmallDateTime(value) => value.map(|stamp| {
            temporal(
                small_datetime_of(stamp).map(|stamp| Value::Timestamp(Temporal::Finite(stamp))),
                type_name,
            )
        }),
        ColumnData::DateTimeOffset(value) => value.map(|stamp| {
            temporal(
                datetimeoffset_of(stamp)
                    .map(|stamp| Value::TimestampTz(Temporal::Finite(OffsetTimestamp::from_datetime(stamp)))),
                type_name,
            )
        }),
    };
    decoded.unwrap_or(Value::Null)
}

fn temporal(value: Option<Value>, type_name: &str) -> Value {
    value.unwrap_or_else(|| {
        Value::Undecodable(Box::new(UndecodedValue {
            type_name: type_name.to_owned(),
            reason: UndecodableReason::OutOfRange,
        }))
    })
}

/// Days since 0001-01-01.
fn date_of(date: Date) -> Option<NaiveDate> {
    NaiveDate::from_ymd_opt(1, 1, 1)?.checked_add_days(Days::new(u64::from(date.days())))
}

/// Increments of 10^-scale seconds since midnight, kept to the 100 ns
/// the widest scale gives.
fn time_of(time: Time) -> Option<NaiveTime> {
    let scale = u32::from(time.scale());
    let unit = 10u64.checked_pow(9u32.checked_sub(scale)?)?;
    let nanos = time.increments().checked_mul(unit)?;
    let seconds = u32::try_from(nanos / NANOS_PER_SECOND).ok()?;
    let fraction = u32::try_from(nanos % NANOS_PER_SECOND).ok()?;
    NaiveTime::from_num_seconds_from_midnight_opt(seconds, fraction)
}

fn datetime2_of(stamp: DateTime2) -> Option<NaiveDateTime> {
    Some(NaiveDateTime::new(date_of(stamp.date())?, time_of(stamp.time())?))
}

/// A datetimeoffset carries UTC and the offset it was written with; both
/// are kept, so `+05:30` reads back as `+05:30`.
fn datetimeoffset_of(stamp: DateTimeOffset) -> Option<DateTime<FixedOffset>> {
    let utc = datetime2_of(stamp.datetime2())?;
    let offset = FixedOffset::east_opt(i32::from(stamp.offset()).checked_mul(60)?)?;
    Some(DateTime::from_naive_utc_and_offset(utc, offset))
}

/// Days since 1900-01-01, which may be negative back to 1753, and
/// three-hundredths of a second since midnight. SQL Server shows those
/// rounded to the millisecond (.000, .003, .007), and so does this.
fn datetime_of(stamp: TdsDateTime) -> Option<NaiveDateTime> {
    let epoch = NaiveDate::from_ymd_opt(1900, 1, 1)?;
    let days = stamp.days();
    let date = match u64::try_from(days) {
        Ok(forward) => epoch.checked_add_days(Days::new(forward))?,
        Err(_) => epoch.checked_sub_days(Days::new(u64::from(days.unsigned_abs())))?,
    };
    let millis = (u64::from(stamp.seconds_fragments()) * 20 + 3) / 6;
    let seconds = u32::try_from(millis / 1_000).ok()?;
    let nanos = u32::try_from(millis % 1_000 * 1_000_000).ok()?;
    Some(NaiveDateTime::new(
        date,
        NaiveTime::from_num_seconds_from_midnight_opt(seconds, nanos)?,
    ))
}

/// Days since 1900-01-01 and minutes since midnight.
fn small_datetime_of(stamp: SmallDateTime) -> Option<NaiveDateTime> {
    let date = NaiveDate::from_ymd_opt(1900, 1, 1)?.checked_add_days(Days::new(u64::from(stamp.days())))?;
    let seconds = u32::from(stamp.seconds_fragments()).checked_mul(60)?;
    Some(NaiveDateTime::new(
        date,
        NaiveTime::from_num_seconds_from_midnight_opt(seconds, 0)?,
    ))
}

#[cfg(test)]
mod tests {
    use std::borrow::Cow;

    use tiberius::numeric::Numeric;

    use super::*;

    fn decode(data: ColumnData<'static>) -> Value {
        decode_cell(&data, "test")
    }

    /// 2024-06-15 counted in days from 0001-01-01.
    fn june_15_2024() -> Date {
        let days = NaiveDate::from_ymd_opt(2024, 6, 15)
            .unwrap()
            .signed_duration_since(NaiveDate::from_ymd_opt(1, 1, 1).unwrap())
            .num_days();
        Date::new(u32::try_from(days).unwrap())
    }

    #[test]
    fn a_null_of_any_type_is_null_and_nothing_else_is() {
        for null in [
            ColumnData::I32(None),
            ColumnData::String(None),
            ColumnData::Binary(None),
            ColumnData::DateTimeOffset(None),
            ColumnData::Numeric(None),
        ] {
            assert_eq!(decode(null), Value::Null);
        }
        assert_eq!(
            decode(ColumnData::String(Some(Cow::Borrowed("")))),
            Value::Text(String::new())
        );
    }

    #[test]
    fn integers_floats_and_bits() {
        assert_eq!(decode(ColumnData::U8(Some(255))), Value::Int(255));
        assert_eq!(decode(ColumnData::I64(Some(i64::MIN))), Value::Int(i64::MIN));
        assert_eq!(decode(ColumnData::F32(Some(1.5))), Value::Float32(1.5));
        assert_eq!(decode(ColumnData::Bit(Some(true))), Value::Bool(true));
    }

    #[test]
    fn a_decimal_keeps_all_38_digits() {
        let widest = 10i128.pow(37) * 9 + 1;

        let decoded = decode(ColumnData::Numeric(Some(Numeric::new_with_scale(widest, 10))));

        assert_eq!(decoded, Value::Decimal(SqlDecimal::from_scaled_i128(widest, 10)));
    }

    #[test]
    fn money_max_min_through_the_decimal_cast_is_exact() {
        let max = decode(ColumnData::Numeric(Some(Numeric::new_with_scale(
            9_223_372_036_854_775_807,
            4,
        ))));
        let min = decode(ColumnData::Numeric(Some(Numeric::new_with_scale(
            -9_223_372_036_854_775_808,
            4,
        ))));

        assert_eq!(max, Value::Decimal("922337203685477.5807".parse().unwrap()));
        assert_eq!(min, Value::Decimal("-922337203685477.5808".parse().unwrap()));
    }

    #[test]
    fn datetimeoffset_plus_0530_keeps_its_offset() {
        let utc_time = Time::new((8 * 3600 + 15 * 60) * 10_000_000 + 1_234_567, 7);
        let stamp = DateTimeOffset::new(DateTime2::new(june_15_2024(), utc_time), 330);

        let decoded = decode(ColumnData::DateTimeOffset(Some(stamp)));

        let expected = DateTime::parse_from_rfc3339("2024-06-15T13:45:00.1234567+05:30").unwrap();
        assert_eq!(
            decoded,
            Value::TimestampTz(Temporal::Finite(OffsetTimestamp::from_datetime(expected)))
        );
    }

    #[test]
    fn datetime2_and_time_keep_100_nanoseconds() {
        let time = Time::new(10 * 3600 * 10_000_000 + 1, 7);

        let stamp = decode(ColumnData::DateTime2(Some(DateTime2::new(june_15_2024(), time))));
        let Value::Timestamp(Temporal::Finite(stamp)) = stamp else {
            panic!("not a timestamp: {stamp:?}");
        };
        assert_eq!(
            stamp.format("%Y-%m-%d %H:%M:%S%.9f").to_string(),
            "2024-06-15 10:00:00.000000100"
        );

        let coarse = decode(ColumnData::Time(Some(Time::new(12_345, 3))));
        assert_eq!(
            coarse,
            Value::Time(SqlTime::from_time_of_day(
                NaiveTime::from_hms_milli_opt(0, 0, 12, 345).unwrap()
            ))
        );
    }

    #[test]
    fn datetime_rounds_three_hundredths_as_the_server_shows_them() {
        let three_ms = decode(ColumnData::DateTime(Some(TdsDateTime::new(0, 1))));
        let seven_ms = decode(ColumnData::DateTime(Some(TdsDateTime::new(-1, 2))));

        let expected = |text: &str| {
            Value::Timestamp(Temporal::Finite(
                NaiveDateTime::parse_from_str(text, "%Y-%m-%d %H:%M:%S%.3f").unwrap(),
            ))
        };
        assert_eq!(three_ms, expected("1900-01-01 00:00:00.003"));
        assert_eq!(seven_ms, expected("1899-12-31 00:00:00.007"));
        assert_eq!(
            decode(ColumnData::SmallDateTime(Some(SmallDateTime::new(1, 61)))),
            expected("1900-01-02 01:01:00.000")
        );
    }

    #[test]
    fn a_time_past_midnight_is_undecodable_not_null() {
        let decoded = decode(ColumnData::Time(Some(Time::new(86_400 * 10_000_000, 7))));

        assert!(matches!(
            decoded,
            Value::Undecodable(undecoded) if undecoded.reason == UndecodableReason::OutOfRange
        ));
    }

    #[test]
    fn guid_binary_and_xml() {
        let id = uuid::Uuid::from_u128(42);

        assert_eq!(decode(ColumnData::Guid(Some(id))), Value::Uuid(id));
        assert_eq!(
            decode(ColumnData::Binary(Some(Cow::Owned(vec![0xde, 0xad])))),
            Value::Bytes(vec![0xde, 0xad])
        );
        let xml = tiberius::xml::XmlData::new("<a/>");
        assert_eq!(
            decode(ColumnData::Xml(Some(Cow::Owned(xml)))),
            Value::Text("<a/>".to_owned())
        );
    }
}
