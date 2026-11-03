use std::borrow::Cow;
use std::cmp::Ordering;
use std::str::FromStr;

use super::{SqlDecimal, SqlInterval, Temporal, TimeWithOffset, Value};
use crate::column::{ColumnKind, ColumnType};

// Each value is ordered by what it holds, not by its column's declared type, since a SQLite column can hold any kind.
pub fn compare(a: &Value, b: &Value) -> Ordering {
    match (a, b) {
        (Value::Null, Value::Null) => Ordering::Equal,
        (Value::Null, _) => Ordering::Less,
        (_, Value::Null) => Ordering::Greater,
        _ => match (rank(a), rank(b)) {
            (left, right) if left != right => left.cmp(&right),
            _ => same_rank(a, b),
        },
    }
}

// Two texts are Equal here: a host collates them, or `held_order` does.
pub fn storage_class_order(a: &Value, b: &Value) -> Ordering {
    let class = storage_class(a);
    match class.cmp(&storage_class(b)) {
        Ordering::Equal => match class {
            StorageClass::Null | StorageClass::Text => Ordering::Equal,
            StorageClass::Numeric => numeric_order(a, b),
            StorageClass::Blob | StorageClass::Other => compare(a, b),
        },
        unequal => unequal,
    }
}

pub fn storage_class_rank(value: &Value) -> i32 {
    storage_class(value) as i32
}

// A column whose rows may hold text orders by storage class first, so a SQLite column of mixed kinds reads as
// NULL, numbers, text, blobs.
pub fn sorts_as_text(column: &ColumnType) -> bool {
    column.dynamic_storage
        || column.kind.is_textual()
        || matches!(column.kind, ColumnKind::Json { .. } | ColumnKind::Network(_))
}

pub fn sort_text(value: &Value) -> Option<&str> {
    let text = match value {
        Value::Text(text) => text,
        Value::Json(json) => json.as_str(),
        Value::Other(other) => &other.text,
        _ => return None,
    };
    Some(sort_head(text))
}

// Text as the macOS app orders a result it holds: digit runs by their value, everything else by code point, case
// counting. UTF-8 bytes order as their code points do, and a digit is never part of a longer character.
pub fn natural_text_order(a: &str, b: &str) -> Ordering {
    let (mut a, mut b) = (a.as_bytes(), b.as_bytes());
    loop {
        match (a.split_first(), b.split_first()) {
            (None, None) => return Ordering::Equal,
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some((left, _)), Some((right, _))) if left.is_ascii_digit() && right.is_ascii_digit() => {
                let (left, left_rest) = split_digits(a);
                let (right, right_rest) = split_digits(b);
                let order = digits_order(left, right);
                if order.is_ne() {
                    return order;
                }
                (a, b) = (left_rest, right_rest);
            }
            (Some((left, left_rest)), Some((right, right_rest))) => {
                if left != right {
                    return left.cmp(right);
                }
                (a, b) = (left_rest, right_rest);
            }
        }
    }
}

// The order a host shows a column of held rows in: stable, so equal values keep the order they arrived in, and
// descending is the comparison reversed, which puts NULL last.
pub fn row_order(values: &[Value], as_text: bool, ascending: bool) -> Vec<usize> {
    let mut rows: Vec<usize> = (0..values.len()).collect();
    let null = Value::Null;
    rows.sort_by(|&left, &right| {
        let left = values.get(left).unwrap_or(&null);
        let right = values.get(right).unwrap_or(&null);
        let order = held_order(left, right, as_text);
        if ascending { order } else { order.reverse() }
    });
    rows
}

fn held_order(a: &Value, b: &Value, as_text: bool) -> Ordering {
    if !as_text {
        return compare(a, b);
    }
    match (sort_text(a), sort_text(b)) {
        (Some(left), Some(right)) => natural_text_order(left, right),
        _ => storage_class_order(a, b),
    }
}

fn split_digits(bytes: &[u8]) -> (&[u8], &[u8]) {
    let end = bytes
        .iter()
        .position(|byte| !byte.is_ascii_digit())
        .unwrap_or(bytes.len());
    bytes.split_at(end)
}

fn digits_order(a: &[u8], b: &[u8]) -> Ordering {
    let (a, b) = (significant(a), significant(b));
    a.len().cmp(&b.len()).then_with(|| a.cmp(b))
}

fn significant(digits: &[u8]) -> &[u8] {
    let start = digits.iter().position(|digit| *digit != b'0').unwrap_or(digits.len());
    digits.split_at(start).1
}

// A collation key is built from the whole text it is given; the head decides any order a person reads.
const SORT_TEXT_MAX_CHARS: usize = 4_096;

fn sort_head(text: &str) -> &str {
    if text.len() <= SORT_TEXT_MAX_CHARS {
        return text;
    }
    text.char_indices()
        .nth(SORT_TEXT_MAX_CHARS)
        .map_or(text, |(index, _)| &text[..index])
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum StorageClass {
    Null,
    Numeric,
    Text,
    Blob,
    Other,
}

fn storage_class(value: &Value) -> StorageClass {
    match value {
        Value::Null => StorageClass::Null,
        _ if is_number(value) => StorageClass::Numeric,
        _ if sort_text(value).is_some() => StorageClass::Text,
        Value::Bytes(_) => StorageClass::Blob,
        _ => StorageClass::Other,
    }
}

fn rank(value: &Value) -> u8 {
    match value {
        Value::Null => 0,
        Value::Bool(_) => 1,
        Value::Int(_)
        | Value::UInt(_)
        | Value::WideInt(_)
        | Value::Float32(_)
        | Value::Float64(_)
        | Value::Decimal(_) => 2,
        Value::Date(_) | Value::Timestamp(_) | Value::TimestampTz(_) => 3,
        Value::Time(_) | Value::TimeTz(_) => 4,
        Value::Interval(_) => 5,
        Value::Text(_) | Value::Json(_) | Value::Other(_) => 6,
        Value::Uuid(_) => 7,
        Value::Bits(_) => 8,
        Value::Bytes(_) => 9,
        Value::Array(_) => 10,
        Value::Undecodable(_) => 11,
    }
}

fn same_rank(a: &Value, b: &Value) -> Ordering {
    match (a, b) {
        (Value::Bool(a), Value::Bool(b)) => a.cmp(b),
        _ if is_number(a) && is_number(b) => numeric_order(a, b),
        (Value::Date(_) | Value::Timestamp(_) | Value::TimestampTz(_), _) => instant_order(a, b),
        (Value::Time(a), Value::Time(b)) => a.total_nanos().cmp(&b.total_nanos()),
        (Value::TimeTz(a), Value::TimeTz(b)) => {
            let utc = |time: &TimeWithOffset| {
                time.time.total_nanos() - i128::from(time.offset.local_minus_utc()) * 1_000_000_000
            };
            utc(a)
                .cmp(&utc(b))
                .then_with(|| a.offset.local_minus_utc().cmp(&b.offset.local_minus_utc()))
        }
        (Value::Time(_), Value::TimeTz(_)) => Ordering::Less,
        (Value::TimeTz(_), Value::Time(_)) => Ordering::Greater,
        (Value::Interval(a), Value::Interval(b)) => interval_span(a).cmp(&interval_span(b)),
        _ if sort_text(a).is_some() => sort_text(a).cmp(&sort_text(b)),
        (Value::Uuid(a), Value::Uuid(b)) => a.as_bytes().cmp(b.as_bytes()),
        (Value::Bits(a), Value::Bits(b)) => a
            .bit_len()
            .cmp(&b.bit_len())
            .then_with(|| a.as_bytes().cmp(b.as_bytes())),
        (Value::Bytes(a), Value::Bytes(b)) => a.cmp(b),
        (Value::Array(a), Value::Array(b)) => a
            .iter()
            .zip(b.iter())
            .map(|(a, b)| compare(a, b))
            .find(|order| order.is_ne())
            .unwrap_or_else(|| a.len().cmp(&b.len())),
        _ => Ordering::Equal,
    }
}

// As PostgreSQL compares two: a month is 30 days and a day 24 hours, so `1 mon` equals `30 days`.
fn interval_span(interval: &SqlInterval) -> i128 {
    const MICROS_PER_DAY: i128 = 86_400_000_000;
    let days = i128::from(interval.months) * 30 + i128::from(interval.days);
    days * MICROS_PER_DAY + i128::from(interval.microseconds)
}

fn is_number(value: &Value) -> bool {
    matches!(
        value,
        Value::Int(_) | Value::UInt(_) | Value::WideInt(_) | Value::Float32(_) | Value::Float64(_) | Value::Decimal(_)
    )
}

// NaN sorts after every number, as PostgreSQL sorts it.
fn numeric_order(a: &Value, b: &Value) -> Ordering {
    match (float_of(a), float_of(b)) {
        (Some(a), Some(b)) => return float_order(a, b),
        (Some(a), None) if a.is_nan() => return Ordering::Greater,
        (None, Some(b)) if b.is_nan() => return Ordering::Less,
        _ => {}
    }
    if let (Some(a), Some(b)) = (integer_of(a), integer_of(b)) {
        return a.cmp(&b);
    }
    match (decimal_of(a), decimal_of(b)) {
        (Some(a), Some(b)) => a.cmp_numeric(b.as_ref()),
        _ => Ordering::Equal,
    }
}

fn float_order(a: f64, b: f64) -> Ordering {
    match (a.is_nan(), b.is_nan()) {
        (true, true) => Ordering::Equal,
        (true, false) => Ordering::Greater,
        (false, true) => Ordering::Less,
        (false, false) => a.total_cmp(&b),
    }
}

fn float_of(value: &Value) -> Option<f64> {
    match value {
        Value::Float32(float) => Some(f64::from(*float)),
        Value::Float64(float) => Some(*float),
        _ => None,
    }
}

fn integer_of(value: &Value) -> Option<i128> {
    match value {
        Value::Int(int) => Some(i128::from(*int)),
        Value::UInt(int) => Some(i128::from(*int)),
        Value::WideInt(wide) => wide.to_i128(),
        _ => None,
    }
}

// A float is taken at the decimal its shortest form spells. A decimal is borrowed: a sort compares each one many
// times.
pub fn decimal_of(value: &Value) -> Option<Cow<'_, SqlDecimal>> {
    let owned = match value {
        Value::Decimal(decimal) => return Some(Cow::Borrowed(decimal)),
        Value::Float32(_) | Value::Float64(_) => {
            let float = float_of(value)?;
            if float.is_nan() {
                SqlDecimal::nan()
            } else if float.is_infinite() {
                SqlDecimal::infinity(float < 0.0)
            } else {
                SqlDecimal::from_str(&format_float(value)).ok()?
            }
        }
        _ => match integer_of(value) {
            Some(int) => SqlDecimal::from_scaled_i128(int, 0),
            None => match value {
                Value::WideInt(wide) => SqlDecimal::from_str(&wide.to_string()).ok()?,
                _ => return None,
            },
        },
    };
    Some(Cow::Owned(owned))
}

// At the float's own width, so `0.1f32` is `1e-1` rather than the double it widens to.
fn format_float(value: &Value) -> String {
    match value {
        Value::Float32(float) => format!("{float:e}"),
        Value::Float64(float) => format!("{float:e}"),
        _ => String::new(),
    }
}

// An offset timestamp orders by its instant, then by its offset, so two spellings of one instant keep a stable order.
fn instant_order(a: &Value, b: &Value) -> Ordering {
    let (Some(a_key), Some(b_key)) = (instant(a), instant(b)) else {
        return rank(a).cmp(&rank(b));
    };
    a_key.cmp(&b_key)
}

// The first part puts -infinity first and infinity last.
fn instant(value: &Value) -> Option<(i8, Option<chrono::NaiveDateTime>, i32)> {
    let midnight = |date: &chrono::NaiveDate| date.and_hms_opt(0, 0, 0);
    match value {
        Value::Date(date) => Some(temporal_key(date, |date| (midnight(date), 0))),
        Value::Timestamp(stamp) => Some(temporal_key(stamp, |stamp| (Some(*stamp), 0))),
        Value::TimestampTz(stamp) => Some(temporal_key(stamp, |stamp| {
            (Some(stamp.utc()), stamp.offset().local_minus_utc())
        })),
        _ => None,
    }
}

fn temporal_key<T>(
    temporal: &Temporal<T>,
    finite: impl Fn(&T) -> (Option<chrono::NaiveDateTime>, i32),
) -> (i8, Option<chrono::NaiveDateTime>, i32) {
    match temporal {
        Temporal::NegInfinity => (-1, None, 0),
        Temporal::Finite(value) => {
            let (instant, offset) = finite(value);
            (0, instant, offset)
        }
        Temporal::Infinity => (1, None, 0),
    }
}

#[cfg(test)]
mod tests {
    use chrono::{DateTime, NaiveDate};

    use super::*;
    use crate::column::ReadForm;
    use crate::value::{BitString, JsonText, OffsetTimestamp, OtherValue, WideInteger};

    fn order(a: &Value, b: &Value) -> Ordering {
        compare(a, b)
    }

    fn sorted(mut values: Vec<Value>) -> Vec<Value> {
        values.sort_by(order);
        values
    }

    fn decimal(text: &str) -> Value {
        Value::Decimal(SqlDecimal::from_str(text).expect("a decimal"))
    }

    fn text(text: &str) -> Value {
        Value::Text(text.to_owned())
    }

    #[test]
    fn nulls_sort_first() {
        assert_eq!(
            sorted(vec![Value::Int(1), Value::Null, Value::Bool(false), Value::Null]),
            [Value::Null, Value::Null, Value::Bool(false), Value::Int(1)]
        );
        assert_eq!(order(&Value::Null, &Value::Float64(f64::NAN)), Ordering::Less);
    }

    #[test]
    fn int_decimal_and_float_compare_numerically() {
        let values = vec![
            decimal("2.5"),
            Value::Int(-3),
            Value::Float64(2.25),
            Value::UInt(u64::MAX),
            Value::Float32(0.1),
            decimal("0.09"),
            Value::Int(2),
            Value::WideInt(WideInteger::from_i128(i128::from(u64::MAX) + 1)),
            Value::WideInt(WideInteger::from_u128(u128::MAX)),
        ];

        assert_eq!(
            sorted(values),
            [
                Value::Int(-3),
                decimal("0.09"),
                Value::Float32(0.1),
                Value::Int(2),
                Value::Float64(2.25),
                decimal("2.5"),
                Value::UInt(u64::MAX),
                Value::WideInt(WideInteger::from_i128(i128::from(u64::MAX) + 1)),
                Value::WideInt(WideInteger::from_u128(u128::MAX)),
            ]
        );
        assert_eq!(order(&Value::Int(2), &decimal("2.000")), Ordering::Equal);
        assert_eq!(order(&Value::Float64(-0.0), &Value::Float64(0.0)), Ordering::Less);
    }

    #[test]
    fn nan_sorts_after_numbers() {
        let nan = Value::Float64(f64::NAN);

        assert_eq!(order(&nan, &Value::Float64(f64::INFINITY)), Ordering::Greater);
        assert_eq!(order(&nan, &decimal("1e300")), Ordering::Greater);
        assert_eq!(order(&Value::Int(i64::MAX), &nan), Ordering::Less);
        assert_eq!(order(&nan, &Value::Float32(f32::NAN)), Ordering::Equal);
        assert_eq!(
            order(&Value::Decimal(SqlDecimal::nan()), &Value::Float64(1.0)),
            Ordering::Greater
        );
    }

    #[test]
    fn temporal_infinities_order() {
        let day = |d| Value::Date(Temporal::Finite(NaiveDate::from_ymd_opt(2024, 1, d).expect("a date")));

        assert_eq!(
            sorted(vec![
                Value::Date(Temporal::Infinity),
                day(2),
                Value::Date(Temporal::NegInfinity),
                day(1),
            ]),
            [
                Value::Date(Temporal::NegInfinity),
                day(1),
                day(2),
                Value::Date(Temporal::Infinity),
            ]
        );
    }

    #[test]
    fn offset_timestamps_compare_by_instant_then_offset() {
        let at = |text: &str| {
            Value::TimestampTz(Temporal::Finite(OffsetTimestamp::from_datetime(
                DateTime::parse_from_rfc3339(text).expect("a timestamp"),
            )))
        };
        let noon_utc = at("2024-06-15T12:00:00+00:00");
        let same_in_hanoi = at("2024-06-15T19:00:00+07:00");
        let earlier_in_hanoi = at("2024-06-15T18:00:00+07:00");

        assert_eq!(order(&earlier_in_hanoi, &noon_utc), Ordering::Less);
        assert_eq!(
            order(&noon_utc, &same_in_hanoi),
            Ordering::Less,
            "a tie broke on the wall clock"
        );
        assert_eq!(order(&same_in_hanoi, &noon_utc), Ordering::Greater);
        assert_eq!(
            order(&Value::TimestampTz(Temporal::Infinity), &noon_utc),
            Ordering::Greater
        );
    }

    #[test]
    fn intervals_compare_by_their_length() {
        let interval = |months, days, microseconds| {
            Value::Interval(SqlInterval {
                months,
                days,
                microseconds,
            })
        };
        let hour = 3_600_000_000;

        assert_eq!(order(&interval(1, 0, 0), &interval(0, 40, 0)), Ordering::Less);
        assert_eq!(order(&interval(1, 0, 0), &interval(0, 30, 0)), Ordering::Equal);
        assert_eq!(order(&interval(0, 1, 0), &interval(0, 0, 25 * hour)), Ordering::Less);
        assert_eq!(order(&interval(0, -1, 0), &interval(0, 0, -hour)), Ordering::Less);
    }

    #[test]
    fn bytes_bits_uuids_and_arrays_order_by_content() {
        let bits = |value, len| Value::Bits(BitString::from_u64(value, len));

        assert_eq!(
            order(&Value::Bytes(vec![1, 2]), &Value::Bytes(vec![1, 3])),
            Ordering::Less
        );
        assert_eq!(
            order(&bits(0b1, 1), &bits(0b0, 2)),
            Ordering::Less,
            "a shorter bit string sorts first"
        );
        assert_eq!(order(&bits(0b01, 2), &bits(0b10, 2)), Ordering::Less);
        assert_eq!(
            order(
                &Value::Uuid(uuid::Uuid::from_u128(1)),
                &Value::Uuid(uuid::Uuid::from_u128(2))
            ),
            Ordering::Less
        );
        assert_eq!(
            order(
                &Value::Array(vec![Value::Int(1), Value::Int(2)]),
                &Value::Array(vec![Value::Int(1), Value::Int(2), Value::Int(0)])
            ),
            Ordering::Less
        );
        assert_eq!(
            order(
                &Value::Array(vec![Value::Int(10)]),
                &Value::Array(vec![Value::Int(9), Value::Int(9)])
            ),
            Ordering::Greater
        );
    }

    #[test]
    fn dynamic_storage_orders_by_storage_class() {
        let mut values = vec![
            Value::Bytes(vec![0]),
            text("apple"),
            Value::Float64(2.5),
            Value::Null,
            Value::Int(3),
            Value::Int(-1),
        ];
        values.sort_by(storage_class_order);

        assert_eq!(
            values,
            [
                Value::Null,
                Value::Int(-1),
                Value::Float64(2.5),
                Value::Int(3),
                text("apple"),
                Value::Bytes(vec![0]),
            ]
        );
        assert_eq!(
            storage_class_order(&text("b"), &text("a")),
            Ordering::Equal,
            "text is the collating sorter's to order"
        );
    }

    #[test]
    fn a_long_text_sorts_by_its_head() {
        let long = format!("{}tail", "é".repeat(SORT_TEXT_MAX_CHARS));

        assert_eq!(
            sort_text(&Value::Text(long)),
            Some("é".repeat(SORT_TEXT_MAX_CHARS).as_str())
        );
        assert_eq!(sort_text(&text("short")), Some("short"));
    }

    #[test]
    fn sort_text_covers_text_kinds_only() {
        let json = JsonText::parse("{\"a\":1}".to_owned()).expect("json");
        let other = Value::Other(Box::new(OtherValue {
            type_name: "inet".to_owned(),
            text: "10.0.0.1".to_owned(),
        }));

        assert_eq!(sort_text(&text("plain")), Some("plain"));
        assert_eq!(sort_text(&Value::Json(json)), Some("{\"a\":1}"));
        assert_eq!(sort_text(&other), Some("10.0.0.1"));
        for value in [
            Value::Null,
            Value::Int(1),
            Value::Bytes(b"text".to_vec()),
            Value::Uuid(uuid::Uuid::nil()),
            Value::Bool(true),
        ] {
            assert_eq!(sort_text(&value), None, "{value:?}");
        }
    }

    #[test]
    fn natural_text_orders_digit_runs_by_value() {
        let mut names = vec![
            "file10", "file2", "File1", "file1", "file02b", "file", "file2a", "a1", "ab",
        ];
        names.sort_by(|a, b| natural_text_order(a, b));

        assert_eq!(
            names,
            [
                "File1", "a1", "ab", "file", "file1", "file2", "file2a", "file02b", "file10"
            ]
        );
        assert_eq!(natural_text_order("v01", "v1"), Ordering::Equal);
        assert_eq!(
            natural_text_order("99999999999999999999999", "100000000000000000000000"),
            Ordering::Less
        );
        assert_eq!(
            natural_text_order("é", "z"),
            Ordering::Greater,
            "code points, not a locale"
        );
        assert_eq!(natural_text_order("a!", "a1"), Ordering::Less);
    }

    #[test]
    fn held_rows_order_as_text_with_null_first_and_stable_ties() {
        let values = vec![
            text("b10"),
            Value::Null,
            text("b9"),
            Value::Int(5),
            text("a"),
            text("b9"),
            Value::Bytes(vec![1]),
        ];

        assert_eq!(row_order(&values, true, true), [1, 3, 4, 2, 5, 0, 6]);
        assert_eq!(
            row_order(&values, true, false),
            [6, 0, 2, 5, 4, 3, 1],
            "descending reverses the order, NULL last, and equal values keep their arrival order"
        );
    }

    #[test]
    fn held_rows_of_a_typed_column_order_by_value() {
        let values = vec![
            decimal("10.5"),
            Value::Int(-2),
            Value::Null,
            Value::Float64(3.0),
            Value::Int(10),
        ];

        assert_eq!(row_order(&values, false, true), [2, 1, 3, 4, 0]);
        assert_eq!(row_order(&values, false, false), [0, 4, 3, 1, 2]);
    }

    #[test]
    fn text_columns_sort_by_storage_class_first() {
        let typed = |kind| ColumnType {
            name: "t".to_owned(),
            kind,
            catalog: None,
            dynamic_storage: false,
            read_form: ReadForm::Native,
        };

        assert!(sorts_as_text(&ColumnType::untyped_text("")));
        assert!(sorts_as_text(&typed(ColumnKind::Xml)));
        assert!(!sorts_as_text(&typed(ColumnKind::Date)));
        assert!(!sorts_as_text(&typed(ColumnKind::Uuid)));
    }
}
