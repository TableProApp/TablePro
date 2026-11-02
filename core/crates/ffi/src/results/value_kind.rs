use tablepro_core::Value;
use tablepro_core::column::{ColumnKind, IntegerWidth, TemporalZone};

/// What a column or a cell holds. A window carries it as a byte per
/// column and per cell, and these numbers are that byte: never renumber
/// one. A cell's kind is what tells the app what its `raw` means, since
/// an engine such as SQLite can hold any kind in any column.
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum ValueKind {
    /// Anything else, as the server's text: a composite, a variant.
    Other = 0,
    /// `raw` is 1 or 0.
    Bool = 1,
    /// `raw` is the value.
    Integer = 2,
    /// `raw` is the value's 64 bits.
    UnsignedInteger = 3,
    /// Wider than 64 bits. The text is exact; `raw` is unused.
    WideInteger = 4,
    /// `raw` is the IEEE 754 bits of the value as a double.
    Float = 5,
    /// The text is exact at the column's scale; `raw` is unused.
    Decimal = 6,
    /// `raw` is the full length in UTF-8 bytes.
    Text = 7,
    /// The text is `0x` and lowercase hex of the leading bytes; `raw` is
    /// the full length in bytes.
    Bytes = 8,
    Uuid = 9,
    /// `raw` is the full length in UTF-8 bytes.
    Json = 10,
    /// `raw` is days from 1970-01-01, or the i64 limits for infinity.
    Date = 11,
    /// `raw` is microseconds from midnight, negative or past a day for
    /// a duration.
    Time = 12,
    /// `raw` is microseconds from midnight, before the offset.
    TimeWithOffset = 13,
    /// `raw` is microseconds from 1970-01-01 00:00, read as UTC, or the
    /// i64 limits for infinity.
    Timestamp = 14,
    /// `raw` is microseconds from the Unix epoch, or the i64 limits for
    /// infinity.
    TimestampWithOffset = 15,
    Interval = 16,
    Bits = 17,
    Array = 18,
    Network = 19,
    Spatial = 20,
    /// `raw` is the full length in UTF-8 bytes.
    Xml = 21,
    /// The driver could not read the value, so it has no text.
    Undecodable = 22,
}

impl ValueKind {
    pub fn of_column(kind: &ColumnKind) -> Self {
        match kind {
            ColumnKind::Bool(_) => Self::Bool,
            ColumnKind::Integer(integer) => match integer.width {
                IntegerWidth::W128 | IntegerWidth::W256 => Self::WideInteger,
                IntegerWidth::W64 if !integer.signed => Self::UnsignedInteger,
                _ => Self::Integer,
            },
            ColumnKind::Float(_) => Self::Float,
            ColumnKind::Decimal { .. } | ColumnKind::Money { .. } => Self::Decimal,
            ColumnKind::Text { .. } | ColumnKind::Enum { .. } => Self::Text,
            ColumnKind::Bytes { .. } => Self::Bytes,
            ColumnKind::Uuid => Self::Uuid,
            ColumnKind::Json { .. } => Self::Json,
            ColumnKind::Date => Self::Date,
            ColumnKind::Time { with_offset: true, .. } => Self::TimeWithOffset,
            ColumnKind::Time { .. } => Self::Time,
            ColumnKind::Timestamp {
                zone: TemporalZone::Naive,
                ..
            } => Self::Timestamp,
            ColumnKind::Timestamp { .. } => Self::TimestampWithOffset,
            ColumnKind::Interval => Self::Interval,
            ColumnKind::BitString { .. } => Self::Bits,
            ColumnKind::Network(_) => Self::Network,
            ColumnKind::Xml => Self::Xml,
            ColumnKind::Spatial => Self::Spatial,
            ColumnKind::Array { .. } => Self::Array,
            ColumnKind::Variant | ColumnKind::Composite | ColumnKind::Other => Self::Other,
        }
    }

    /// The kind of a value that is not null.
    pub fn of_value(value: &Value) -> Self {
        match value {
            Value::Bool(_) => Self::Bool,
            Value::Int(_) => Self::Integer,
            Value::UInt(_) => Self::UnsignedInteger,
            Value::WideInt(_) => Self::WideInteger,
            Value::Float32(_) | Value::Float64(_) => Self::Float,
            Value::Decimal(_) => Self::Decimal,
            Value::Text(_) => Self::Text,
            Value::Bytes(_) => Self::Bytes,
            Value::Uuid(_) => Self::Uuid,
            Value::Json(_) => Self::Json,
            Value::Date(_) => Self::Date,
            Value::Time(_) => Self::Time,
            Value::TimeTz(_) => Self::TimeWithOffset,
            Value::Timestamp(_) => Self::Timestamp,
            Value::TimestampTz(_) => Self::TimestampWithOffset,
            Value::Interval(_) => Self::Interval,
            Value::Bits(_) => Self::Bits,
            Value::Array(_) => Self::Array,
            Value::Null | Value::Other(_) => Self::Other,
            Value::Undecodable(_) => Self::Undecodable,
        }
    }

    pub fn from_byte(byte: u8) -> Self {
        Self::ALL.get(usize::from(byte)).copied().unwrap_or(Self::Other)
    }

    const ALL: [Self; 23] = [
        Self::Other,
        Self::Bool,
        Self::Integer,
        Self::UnsignedInteger,
        Self::WideInteger,
        Self::Float,
        Self::Decimal,
        Self::Text,
        Self::Bytes,
        Self::Uuid,
        Self::Json,
        Self::Date,
        Self::Time,
        Self::TimeWithOffset,
        Self::Timestamp,
        Self::TimestampWithOffset,
        Self::Interval,
        Self::Bits,
        Self::Array,
        Self::Network,
        Self::Spatial,
        Self::Xml,
        Self::Undecodable,
    ];
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_kind_is_the_byte_a_window_carries() {
        for (index, kind) in ValueKind::ALL.iter().enumerate() {
            assert_eq!(*kind as u8 as usize, index, "{kind:?}");
            assert_eq!(ValueKind::from_byte(*kind as u8), *kind);
        }
        assert_eq!(ValueKind::Integer as u8, 2);
        assert_eq!(ValueKind::Text as u8, 7);
        assert_eq!(ValueKind::Undecodable as u8, 22);
    }
}
