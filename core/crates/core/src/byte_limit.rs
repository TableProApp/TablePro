use std::num::NonZeroU64;

use crate::value::{OtherValue, UndecodedValue, Value};

// Zero is a run that can keep nothing, so it cannot be built.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct ByteLimit(NonZeroU64);

impl ByteLimit {
    // SI bytes, as the Linux banner prints them: "256.0 MB".
    pub const EDITOR_DEFAULT: Self = Self(NonZeroU64::new(256_000_000).expect("256 MB is not zero"));
    // About a thousand times the largest real table's columns, keys and indexes, and a million table names.
    pub const CATALOG_DEFAULT: Self = Self(NonZeroU64::new(64_000_000).expect("64 MB is not zero"));

    pub fn new(bytes: u64) -> Option<Self> {
        NonZeroU64::new(bytes).map(Self)
    }

    pub const fn get(self) -> u64 {
        self.0.get()
    }
}

// A wide integer is at most 256 bits.
const WIDE_INTEGER_BYTES: usize = 32;

impl Value {
    // Lengths, not capacities, so the same rows measure the same everywhere.
    pub fn retained_bytes(&self) -> usize {
        size_of::<Value>() + self.heap_bytes()
    }

    fn heap_bytes(&self) -> usize {
        match self {
            Value::Null
            | Value::Bool(_)
            | Value::Int32(_)
            | Value::Int(_)
            | Value::UInt(_)
            | Value::Float32(_)
            | Value::Float64(_)
            | Value::Uuid(_)
            | Value::Date(_)
            | Value::Time(_)
            | Value::TimeTz(_)
            | Value::Timestamp(_)
            | Value::TimestampTz(_)
            | Value::Interval(_) => 0,
            Value::WideInt(_) => WIDE_INTEGER_BYTES,
            Value::Decimal(decimal) => decimal.parts().map_or(0, |(_, digits, _)| digits.len()),
            Value::Text(text) => text.len(),
            Value::Bytes(bytes) => bytes.len(),
            Value::Json(json) => json.as_str().len(),
            Value::Bits(bits) => bits.as_bytes().len(),
            Value::Array(items) => items.iter().map(Value::retained_bytes).sum(),
            Value::Other(other) => size_of::<OtherValue>() + other.type_name.len() + other.text.len(),
            Value::Undecodable(undecoded) => size_of::<UndecodedValue>() + undecoded.type_name.len(),
        }
    }
}

pub(crate) fn row_bytes(row: &[Value]) -> u64 {
    row.iter()
        .map(|value| u64::try_from(value.retained_bytes()).unwrap_or(u64::MAX))
        .fold(0, u64::saturating_add)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::value::{BitString, JsonText, SqlDecimal, UndecodableReason, WideInteger};

    const SLOT: usize = size_of::<Value>();

    #[test]
    fn a_limit_of_no_bytes_cannot_be_built() {
        assert_eq!(ByteLimit::new(0), None);
        assert_eq!(ByteLimit::new(1).map(ByteLimit::get), Some(1));
    }

    #[test]
    fn the_editor_default_is_256_mb() {
        assert_eq!(ByteLimit::EDITOR_DEFAULT.get(), 256_000_000);
    }

    #[test]
    fn a_scalar_is_its_slot_alone() {
        for value in [
            Value::Null,
            Value::Bool(true),
            Value::Int32(7),
            Value::Int(7),
            Value::UInt(7),
            Value::Float32(0.5),
            Value::Float64(0.5),
            Value::Uuid(uuid::Uuid::nil()),
        ] {
            assert_eq!(value.retained_bytes(), SLOT, "{value:?}");
        }
    }

    #[test]
    fn a_value_with_a_heap_part_adds_its_length() {
        let decimal: SqlDecimal = "-123.45".parse().expect("a decimal");
        let json = JsonText::parse("{\"a\":1}".to_owned()).expect("json");
        let bits = BitString::from_u64(0b1011, 12);

        assert_eq!(Value::Text("héllo".to_owned()).retained_bytes(), SLOT + 6);
        assert_eq!(Value::Bytes(vec![0; 1_000]).retained_bytes(), SLOT + 1_000);
        assert_eq!(Value::Json(json).retained_bytes(), SLOT + 7);
        assert_eq!(Value::Decimal(decimal).retained_bytes(), SLOT + 5);
        assert_eq!(Value::Decimal(SqlDecimal::nan()).retained_bytes(), SLOT);
        assert_eq!(Value::Bits(bits).retained_bytes(), SLOT + 2);
        assert_eq!(
            Value::WideInt(WideInteger::from_u128(u128::MAX)).retained_bytes(),
            SLOT + WIDE_INTEGER_BYTES
        );
    }

    #[test]
    fn a_boxed_or_nested_value_counts_what_it_holds() {
        let other = Value::Other(Box::new(OtherValue {
            type_name: "inet".to_owned(),
            text: "10.0.0.1".to_owned(),
        }));
        let undecodable = Value::Undecodable(Box::new(UndecodedValue {
            type_name: "geometry".to_owned(),
            reason: UndecodableReason::UnsupportedType,
        }));
        let array = Value::Array(vec![Value::Int(1), Value::Text("ab".to_owned())]);

        assert_eq!(other.retained_bytes(), SLOT + size_of::<OtherValue>() + 4 + 8);
        assert_eq!(undecodable.retained_bytes(), SLOT + size_of::<UndecodedValue>() + 8);
        assert_eq!(array.retained_bytes(), SLOT + SLOT + SLOT + 2);
        assert_eq!(Value::Array(Vec::new()).retained_bytes(), SLOT);
    }

    #[test]
    fn a_row_is_the_sum_of_its_values() {
        let row = [Value::Int(1), Value::Text("abc".to_owned())];

        assert_eq!(row_bytes(&row), (SLOT * 2 + 3) as u64);
        assert_eq!(row_bytes(&[]), 0);
    }
}
