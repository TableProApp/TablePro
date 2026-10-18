mod bit_string;
mod decimal;
mod identity;
mod interval;
mod json_text;
mod offset_timestamp;
mod other;
mod temporal;
mod time;
mod time_with_offset;
mod undecodable;
mod wide_integer;

pub use bit_string::{BitString, BitStringError};
pub use decimal::{DecimalParseError, SqlDecimal};
pub use identity::{ValueIdentity, same_value};
pub use interval::{IntervalParseError, SqlInterval};
pub use json_text::{JsonText, JsonTextError};
pub use offset_timestamp::OffsetTimestamp;
pub use other::OtherValue;
pub use temporal::Temporal;
pub use time::{SqlTime, TimeRangeError};
pub use time_with_offset::TimeWithOffset;
pub use undecodable::{UndecodableReason, UndecodedValue};
pub use wide_integer::{WideInteger, WideIntegerParseError};

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Null,
    Bool(bool),
    Int(i64),
    UInt(u64),
    WideInt(WideInteger),
    Float32(f32),
    Float64(f64),
    Decimal(SqlDecimal),
    Text(String),
    Bytes(Vec<u8>),
    Uuid(uuid::Uuid),
    Json(JsonText),
    Date(Temporal<chrono::NaiveDate>),
    Time(SqlTime),
    TimeTz(TimeWithOffset),
    Timestamp(Temporal<chrono::NaiveDateTime>),
    TimestampTz(Temporal<OffsetTimestamp>),
    Interval(SqlInterval),
    Bits(BitString),
    Array(Vec<Value>),
    Other(Box<OtherValue>),
    Undecodable(Box<UndecodedValue>),
}

impl Value {
    pub fn is_null(&self) -> bool {
        matches!(self, Self::Null)
    }

    pub fn variant_name(&self) -> &'static str {
        match self {
            Self::Null => "Null",
            Self::Bool(_) => "Bool",
            Self::Int(_) => "Int",
            Self::UInt(_) => "UInt",
            Self::WideInt(_) => "WideInt",
            Self::Float32(_) => "Float32",
            Self::Float64(_) => "Float64",
            Self::Decimal(_) => "Decimal",
            Self::Text(_) => "Text",
            Self::Bytes(_) => "Bytes",
            Self::Uuid(_) => "Uuid",
            Self::Json(_) => "Json",
            Self::Date(_) => "Date",
            Self::Time(_) => "Time",
            Self::TimeTz(_) => "TimeTz",
            Self::Timestamp(_) => "Timestamp",
            Self::TimestampTz(_) => "TimestampTz",
            Self::Interval(_) => "Interval",
            Self::Bits(_) => "Bits",
            Self::Array(_) => "Array",
            Self::Other(_) => "Other",
            Self::Undecodable(_) => "Undecodable",
        }
    }

    pub fn as_exact_u64(&self) -> Option<u64> {
        match self {
            Self::Int(value) => u64::try_from(*value).ok(),
            Self::UInt(value) => Some(*value),
            Self::Decimal(decimal) => match decimal.to_scaled_i128() {
                Some((mantissa, 0)) => u64::try_from(mantissa).ok(),
                _ => None,
            },
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn value_size_is_at_most_32_bytes() {
        assert!(std::mem::size_of::<Value>() <= 32, "{}", std::mem::size_of::<Value>());
    }

    #[test]
    fn as_exact_u64_accepts_only_exact_non_negative_integers() {
        assert_eq!(Value::Int(7).as_exact_u64(), Some(7));
        assert_eq!(Value::Int(-1).as_exact_u64(), None);
        assert_eq!(Value::UInt(u64::MAX).as_exact_u64(), Some(u64::MAX));
        assert_eq!(Value::Decimal("42".parse().unwrap()).as_exact_u64(), Some(42));
        assert_eq!(Value::Decimal("42.0".parse().unwrap()).as_exact_u64(), None);
        assert_eq!(Value::Text("7".to_owned()).as_exact_u64(), None);
        assert!(Value::Null.is_null());
        assert_eq!(Value::Array(Vec::new()).variant_name(), "Array");
    }
}
