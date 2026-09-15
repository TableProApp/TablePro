use crate::column::SqlTypeExpr;
use crate::value::Value;

/// What the server expects a parameter to be.
///
/// The driver binds by this rather than by guessing from the value, so
/// an `Int` reaching a `smallint` column is caught here rather than
/// coming back as a server error the user has to read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParamType {
    Bool,
    Int16,
    Int32,
    Int64,
    UInt64,
    Float32,
    Float64,
    Decimal,
    Text,
    /// CHAR and friends: text the server pads to a fixed width.
    FixedText,
    Bytes,
    Uuid,
    Json,
    JsonBinary,
    Date,
    Time,
    TimeTz,
    Timestamp,
    TimestampTz,
    Interval,
    /// A type only the server names, bound as text and cast on the way
    /// in. Enums, ranges, composites and geometry arrive here.
    ServerText(SqlTypeExpr),
}

impl ParamType {
    /// Whether this parameter can carry the value.
    ///
    /// Null is accepted everywhere: every SQL type is nullable at the
    /// parameter level, and the column's own constraint is the
    /// server's to enforce.
    pub fn accepts(&self, value: &Value) -> bool {
        if value.is_null() {
            return true;
        }
        matches!(
            (self, value),
            (Self::Bool, Value::Bool(_))
                | (Self::Int16 | Self::Int32 | Self::Int64, Value::Int(_))
                | (Self::Int64 | Self::UInt64, Value::UInt(_))
                | (Self::Float32, Value::Float32(_))
                | (Self::Float64, Value::Float64(_) | Value::Float32(_))
                | (
                    Self::Decimal,
                    Value::Decimal(_) | Value::Int(_) | Value::UInt(_) | Value::WideInt(_)
                )
                | (Self::Text | Self::FixedText | Self::ServerText(_), Value::Text(_))
                | (Self::Bytes, Value::Bytes(_) | Value::Bits(_))
                | (Self::Uuid, Value::Uuid(_))
                | (Self::Json | Self::JsonBinary, Value::Json(_))
                | (Self::Date, Value::Date(_))
                | (Self::Time, Value::Time(_))
                | (Self::TimeTz, Value::TimeTz(_))
                | (Self::Timestamp, Value::Timestamp(_))
                | (Self::TimestampTz, Value::TimestampTz(_))
                | (Self::Interval, Value::Interval(_))
        )
    }

    pub fn name(&self) -> &'static str {
        match self {
            Self::Bool => "Bool",
            Self::Int16 => "Int16",
            Self::Int32 => "Int32",
            Self::Int64 => "Int64",
            Self::UInt64 => "UInt64",
            Self::Float32 => "Float32",
            Self::Float64 => "Float64",
            Self::Decimal => "Decimal",
            Self::Text => "Text",
            Self::FixedText => "FixedText",
            Self::Bytes => "Bytes",
            Self::Uuid => "Uuid",
            Self::Json => "Json",
            Self::JsonBinary => "JsonBinary",
            Self::Date => "Date",
            Self::Time => "Time",
            Self::TimeTz => "TimeTz",
            Self::Timestamp => "Timestamp",
            Self::TimestampTz => "TimestampTz",
            Self::Interval => "Interval",
            Self::ServerText(_) => "ServerText",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const EVERY_TYPE: [ParamType; 20] = [
        ParamType::Bool,
        ParamType::Int16,
        ParamType::Int32,
        ParamType::Int64,
        ParamType::UInt64,
        ParamType::Float32,
        ParamType::Float64,
        ParamType::Decimal,
        ParamType::Text,
        ParamType::FixedText,
        ParamType::Bytes,
        ParamType::Uuid,
        ParamType::Json,
        ParamType::JsonBinary,
        ParamType::Date,
        ParamType::Time,
        ParamType::TimeTz,
        ParamType::Timestamp,
        ParamType::TimestampTz,
        ParamType::Interval,
    ];

    #[test]
    fn param_type_accepts_null_for_every_variant() {
        for param_type in EVERY_TYPE {
            assert!(param_type.accepts(&Value::Null), "{param_type:?}");
        }
        assert!(
            ParamType::ServerText(SqlTypeExpr::from_catalog_text("mood")).accepts(&Value::Null),
            "a server type refused a null"
        );
    }

    #[test]
    fn a_param_type_refuses_a_value_of_another_shape() {
        assert!(!ParamType::Uuid.accepts(&Value::Text("not a uuid".to_owned())));
        assert!(!ParamType::Int32.accepts(&Value::Text("7".to_owned())));
        assert!(!ParamType::Bool.accepts(&Value::Int(1)));
        assert!(
            !ParamType::Timestamp.accepts(&Value::Date(crate::value::Temporal::Finite(
                chrono::NaiveDate::from_ymd_opt(2024, 1, 1).expect("a date")
            )))
        );
    }

    #[test]
    fn widening_conversions_the_server_does_anyway_are_accepted() {
        // The server widens these itself, so refusing them here would
        // only make the caller write a cast.
        assert!(ParamType::Float64.accepts(&Value::Float32(1.5)));
        assert!(ParamType::Decimal.accepts(&Value::Int(3)));
        assert!(ParamType::Int64.accepts(&Value::UInt(3)));
        assert!(
            !ParamType::Float32.accepts(&Value::Float64(1.5)),
            "narrowing was accepted"
        );
    }
}
