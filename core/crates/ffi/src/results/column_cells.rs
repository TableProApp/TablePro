use std::io::Write;
use std::ops::Range;
use std::str::FromStr;

use chrono::{DateTime, FixedOffset, TimeDelta};
use tablepro_core::Value;
use tablepro_core::column::ColumnType;
use tablepro_core::export::value_text;
use tablepro_core::value::{
    BitString, OffsetTimestamp, OtherValue, SqlDecimal, SqlInterval, SqlTime, Temporal, TimeWithOffset,
    UndecodableReason, UndecodedValue, WideInteger,
};

use super::ValueKind;

/// The kind byte of a null cell, outside every `ValueKind`.
const NULL_CELL: u8 = u8::MAX;

/// One column's cells, as flat arrays: a kind byte, a `raw` and the end
/// of the cell's bytes in one shared buffer. A value is formatted once,
/// when it arrives, into the exact text the core's export writes; a
/// binary value keeps its bytes, which a window shows as hex.
#[derive(Debug, Clone, Default)]
pub(super) struct ColumnCells {
    kinds: Vec<u8>,
    raw: Vec<i64>,
    ends: Vec<usize>,
    bytes: Vec<u8>,
}

/// One cell, borrowed from its column.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct Cell<'a> {
    /// `None` for null.
    pub kind: Option<ValueKind>,
    pub raw: i64,
    pub bytes: &'a [u8],
}

impl ColumnCells {
    pub(super) fn push(&mut self, value: &Value, column: &ColumnType) {
        let kind = ValueKind::of_value(value);
        let raw = match value {
            Value::Null => {
                self.close(NULL_CELL, 0);
                return;
            }
            Value::Bool(flag) => {
                self.bytes.extend_from_slice(if *flag { b"true" } else { b"false" });
                i64::from(*flag)
            }
            Value::Int(number) => {
                let _ = write!(self.bytes, "{number}");
                *number
            }
            Value::UInt(number) => {
                let _ = write!(self.bytes, "{number}");
                i64::from_ne_bytes(number.to_ne_bytes())
            }
            Value::Text(text) => self.keep(text.as_bytes()),
            Value::Json(json) => self.keep(json.as_str().as_bytes()),
            Value::Bytes(bytes) => self.keep(bytes),
            other => {
                if let Some(text) = value_text(other, column) {
                    self.bytes.extend_from_slice(text.as_bytes());
                }
                raw_of(other)
            }
        };
        self.close(kind as u8, raw);
    }

    #[cfg(test)]
    pub(super) fn len(&self) -> usize {
        self.kinds.len()
    }

    pub(super) fn cell(&self, index: usize) -> Cell<'_> {
        let start = match index {
            0 => 0,
            _ => self.ends[index - 1],
        };
        let kind = self.kinds[index];
        Cell {
            kind: (kind != NULL_CELL).then(|| ValueKind::from_byte(kind)),
            raw: self.raw[index],
            bytes: &self.bytes[start..self.ends[index]],
        }
    }

    /// Appends `rows` of `other`, a column of the same set.
    pub(super) fn extend_from(&mut self, other: &ColumnCells, rows: Range<usize>) {
        if rows.is_empty() {
            return;
        }
        let first = match rows.start {
            0 => 0,
            start => other.ends[start - 1],
        };
        let last = other.ends[rows.end - 1];
        let base = self.bytes.len();
        self.bytes.extend_from_slice(&other.bytes[first..last]);
        self.kinds.extend_from_slice(&other.kinds[rows.clone()]);
        self.raw.extend_from_slice(&other.raw[rows.clone()]);
        self.ends.extend(other.ends[rows].iter().map(|end| end - first + base));
    }

    /// Gives back what doubling left over, once nothing more is added.
    pub(super) fn shrink(&mut self) {
        self.kinds.shrink_to_fit();
        self.raw.shrink_to_fit();
        self.ends.shrink_to_fit();
        self.bytes.shrink_to_fit();
    }

    fn keep(&mut self, bytes: &[u8]) -> i64 {
        self.bytes.extend_from_slice(bytes);
        i64::try_from(bytes.len()).unwrap_or(i64::MAX)
    }

    fn close(&mut self, kind: u8, raw: i64) {
        self.kinds.push(kind);
        self.raw.push(raw);
        self.ends.push(self.bytes.len());
    }
}

// The value a cell was made from, near enough to order it: what `push` kept in `raw` or as exact text. A kind it
// kept only as display text orders by that text.
pub(super) fn cell_value(cell: Cell<'_>) -> Value {
    let Some(kind) = cell.kind else {
        return Value::Null;
    };
    let text = || String::from_utf8_lossy(cell.bytes);
    let raw = cell.raw;
    let parsed = match kind {
        ValueKind::Bool => Some(Value::Bool(raw != 0)),
        ValueKind::Integer => Some(Value::Int(raw)),
        ValueKind::UnsignedInteger => Some(Value::UInt(u64::from_ne_bytes(raw.to_ne_bytes()))),
        ValueKind::Float => Some(Value::Float64(f64::from_bits(u64::from_ne_bytes(raw.to_ne_bytes())))),
        ValueKind::WideInteger => WideInteger::from_str(&text()).ok().map(Value::WideInt),
        ValueKind::Decimal => SqlDecimal::from_str(&text()).ok().map(Value::Decimal),
        ValueKind::Text | ValueKind::Json | ValueKind::Xml => Some(Value::Text(text().into_owned())),
        ValueKind::Bytes => Some(Value::Bytes(cell.bytes.to_vec())),
        ValueKind::Uuid => uuid::Uuid::try_parse(&text()).ok().map(Value::Uuid),
        ValueKind::Date => Some(Value::Date(from_raw(raw, |days| {
            DateTime::UNIX_EPOCH.date_naive().checked_add_signed(TimeDelta::try_days(days)?)
        }))),
        ValueKind::Timestamp => Some(Value::Timestamp(from_raw(raw, |micros| {
            Some(DateTime::from_timestamp_micros(micros)?.naive_utc())
        }))),
        ValueKind::TimestampWithOffset => Some(Value::TimestampTz(from_raw(raw, |micros| {
            let offset = trailing_offset(&text()).unwrap_or(FixedOffset::east_opt(0)?);
            Some(OffsetTimestamp::from_datetime(
                DateTime::from_timestamp_micros(micros)?.with_timezone(&offset),
            ))
        }))),
        ValueKind::Time => SqlTime::from_micros(raw).ok().map(Value::Time),
        ValueKind::TimeWithOffset => SqlTime::from_micros(raw).ok().and_then(|time| {
            Some(Value::TimeTz(TimeWithOffset {
                time,
                offset: trailing_offset(&text())?,
            }))
        }),
        ValueKind::Interval => SqlInterval::from_str(&text()).ok().map(Value::Interval),
        ValueKind::Bits => bits_of(cell.bytes).map(Value::Bits),
        ValueKind::Undecodable => Some(Value::Undecodable(Box::new(UndecodedValue {
            type_name: String::new(),
            reason: UndecodableReason::UnsupportedType,
        }))),
        ValueKind::Array | ValueKind::Network | ValueKind::Spatial | ValueKind::Other => None,
    };
    parsed.unwrap_or_else(|| {
        Value::Other(Box::new(OtherValue {
            type_name: String::new(),
            text: text().into_owned(),
        }))
    })
}

fn from_raw<T>(raw: i64, finite: impl FnOnce(i64) -> Option<T>) -> Temporal<T> {
    match raw {
        i64::MAX => Temporal::Infinity,
        i64::MIN => Temporal::NegInfinity,
        // A value too far out for chrono still orders past every other.
        raw => finite(raw).map_or(
            if raw < 0 { Temporal::NegInfinity } else { Temporal::Infinity },
            Temporal::Finite,
        ),
    }
}

// The `+07:00` or `-03:30:15` that ends the text `value_text` writes, before a timestamp's era.
fn trailing_offset(text: &str) -> Option<FixedOffset> {
    let text = text.strip_suffix(" BC").unwrap_or(text);
    let digits = text.get(text.rfind(['+', '-'])?..)?;
    let negative = digits.starts_with('-');
    let mut parts = digits.get(1..)?.split(':').map(|part| part.parse::<i32>().ok());
    let hours = parts.next()??;
    let minutes = parts.next()??;
    let seconds = parts.next().flatten().unwrap_or(0);
    let total = hours * 3600 + minutes * 60 + seconds;
    FixedOffset::east_opt(if negative { -total } else { total })
}

fn bits_of(text: &[u8]) -> Option<BitString> {
    let bit_len = u32::try_from(text.len()).ok()?;
    let mut bytes = vec![0u8; text.len().div_ceil(8)];
    for (position, bit) in text.iter().enumerate() {
        match bit {
            b'1' => *bytes.get_mut(position / 8)? |= 0x80 >> (position % 8),
            b'0' => {}
            _ => return None,
        }
    }
    BitString::from_bytes(bit_len, bytes).ok()
}

fn raw_of(value: &Value) -> i64 {
    match value {
        Value::Float32(number) => float_bits(f64::from(*number)),
        Value::Float64(number) => float_bits(*number),
        Value::Date(date) => temporal(date, |date| {
            date.signed_duration_since(DateTime::UNIX_EPOCH.date_naive()).num_days()
        }),
        Value::Timestamp(stamp) => temporal(stamp, |stamp| stamp.and_utc().timestamp_micros()),
        Value::TimestampTz(stamp) => temporal(stamp, |stamp| stamp.to_datetime().timestamp_micros()),
        Value::Time(time) => time.total_micros().unwrap_or(0),
        Value::TimeTz(time) => time.time.total_micros().unwrap_or(0),
        _ => 0,
    }
}

fn float_bits(number: f64) -> i64 {
    i64::from_ne_bytes(number.to_bits().to_ne_bytes())
}

fn temporal<T>(value: &Temporal<T>, finite: impl FnOnce(&T) -> i64) -> i64 {
    match value {
        Temporal::Finite(value) => finite(value),
        Temporal::Infinity => i64::MAX,
        Temporal::NegInfinity => i64::MIN,
    }
}

#[cfg(test)]
mod tests {
    use chrono::{NaiveDate, NaiveDateTime};

    use super::*;

    fn column() -> ColumnType {
        ColumnType::untyped_text("")
    }

    fn cells(values: &[Value]) -> ColumnCells {
        let mut cells = ColumnCells::default();
        for value in values {
            cells.push(value, &column());
        }
        cells
    }

    fn text(cell: Cell<'_>) -> &str {
        std::str::from_utf8(cell.bytes).unwrap()
    }

    #[test]
    fn each_value_keeps_its_exact_text_and_raw() {
        let date = NaiveDate::from_ymd_opt(2024, 1, 2).unwrap();
        let stamp: NaiveDateTime = date.and_hms_micro_opt(3, 4, 5, 600_007).unwrap();
        let cells = cells(&[
            Value::Int(-42),
            Value::UInt(u64::MAX),
            Value::Float64(0.1),
            Value::Decimal("2553875341786898348777948.6813196487".parse::<SqlDecimal>().unwrap()),
            Value::Date(Temporal::Finite(date)),
            Value::Timestamp(Temporal::Finite(stamp)),
            Value::Date(Temporal::Infinity),
            Value::Null,
            Value::Text("héllo".to_owned()),
        ]);

        assert_eq!((text(cells.cell(0)), cells.cell(0).raw), ("-42", -42));
        assert_eq!((text(cells.cell(1)), cells.cell(1).raw), ("18446744073709551615", -1));
        assert_eq!(text(cells.cell(2)), "0.1");
        assert_eq!(f64::from_bits(cells.cell(2).raw as u64), 0.1);
        assert_eq!(text(cells.cell(3)), "2553875341786898348777948.6813196487");
        assert_eq!((text(cells.cell(4)), cells.cell(4).raw), ("2024-01-02", 19_724));
        assert_eq!(text(cells.cell(5)), "2024-01-02 03:04:05.600007");
        assert_eq!(cells.cell(5).raw, stamp.and_utc().timestamp_micros());
        assert_eq!(cells.cell(6).raw, i64::MAX);
        assert_eq!(cells.cell(7).kind, None);
        assert_eq!((text(cells.cell(8)), cells.cell(8).raw), ("héllo", 6));
        assert_eq!(cells.cell(8).kind, Some(ValueKind::Text));
    }

    #[test]
    fn a_cell_reads_back_as_a_value_that_orders_as_the_one_it_was_made_from() {
        use std::cmp::Ordering;

        use tablepro_core::value::order::compare;

        let at = |text: &str| {
            Value::TimestampTz(Temporal::Finite(OffsetTimestamp::from_datetime(
                DateTime::parse_from_rfc3339(text).unwrap(),
            )))
        };
        let time_at = |micros, offset| {
            Value::TimeTz(TimeWithOffset {
                time: SqlTime::from_micros(micros).unwrap(),
                offset: FixedOffset::east_opt(offset).unwrap(),
            })
        };
        let groups: Vec<Vec<Value>> = vec![
            vec![Value::Int(-5), Value::Int(3)],
            vec![Value::UInt(7), Value::UInt(u64::MAX)],
            vec![Value::Float64(-0.5), Value::Float64(f64::NAN)],
            vec![
                Value::WideInt(WideInteger::from_i128(-(1_i128 << 70))),
                Value::WideInt(WideInteger::from_u128(1_u128 << 100)),
            ],
            vec![
                Value::Decimal("0.10".parse().unwrap()),
                Value::Decimal("2553875341786898348777948.6813196487".parse().unwrap()),
            ],
            vec![
                Value::Date(Temporal::NegInfinity),
                Value::Date(Temporal::Finite(NaiveDate::from_ymd_opt(1999, 12, 31).unwrap())),
                Value::Date(Temporal::Infinity),
            ],
            vec![
                Value::Timestamp(Temporal::Finite(
                    NaiveDate::from_ymd_opt(2024, 1, 2).unwrap().and_hms_opt(3, 4, 5).unwrap(),
                )),
                Value::Timestamp(Temporal::Infinity),
            ],
            vec![
                at("2024-06-15T12:00:00+00:00"),
                at("2024-06-15T19:00:00+07:00"),
                at("2024-06-15T13:00:00+00:00"),
            ],
            vec![time_at(3_600_000_000, 0), time_at(3_600_000_000, -3600)],
            vec![
                Value::Interval(SqlInterval {
                    months: 1,
                    days: 0,
                    microseconds: 0,
                }),
                Value::Interval(SqlInterval {
                    months: 0,
                    days: 40,
                    microseconds: 0,
                }),
            ],
            vec![
                Value::Bits(BitString::from_u64(0b1, 1)),
                Value::Bits(BitString::from_u64(0b01, 2)),
                Value::Bits(BitString::from_u64(0b10, 2)),
            ],
            vec![Value::Uuid(uuid::Uuid::from_u128(1)), Value::Uuid(uuid::Uuid::from_u128(2))],
            vec![Value::Bytes(vec![1, 2]), Value::Bytes(vec![1, 3])],
            vec![Value::Text("a".to_owned()), Value::Text("b".to_owned())],
            vec![Value::Bool(false), Value::Bool(true)],
        ];

        for values in groups {
            let cells = cells(&values);
            let read: Vec<Value> = (0..values.len()).map(|index| cell_value(cells.cell(index))).collect();
            for (left, right) in (0..values.len()).flat_map(|left| (0..values.len()).map(move |right| (left, right))) {
                let expected: Ordering = compare(&values[left], &values[right]);
                assert_eq!(
                    compare(&read[left], &read[right]),
                    expected,
                    "{:?} against {:?}, read as {:?} and {:?}",
                    values[left],
                    values[right],
                    read[left],
                    read[right]
                );
            }
        }
        assert_eq!(cell_value(cells(&[Value::Null]).cell(0)), Value::Null);
    }

    #[test]
    fn a_range_copied_into_another_column_reads_the_same() {
        let source = cells(&[
            Value::Text("a".to_owned()),
            Value::Null,
            Value::Text("bcd".to_owned()),
            Value::Bytes(vec![0xde, 0xad]),
        ]);
        let mut target = cells(&[Value::Text("first".to_owned())]);

        target.extend_from(&source, 1..4);

        assert_eq!(target.len(), 4);
        assert_eq!(text(target.cell(0)), "first");
        assert_eq!(target.cell(1).kind, None);
        assert_eq!(text(target.cell(2)), "bcd");
        assert_eq!(target.cell(3).bytes, [0xde, 0xad]);
        assert_eq!(target.cell(3).raw, 2);
    }
}
