use std::borrow::Cow;

use chrono::{Datelike, NaiveDate};
use tablepro_core::DriverError;
use tablepro_core::statement::{BoundParam, ParamType};
use tablepro_core::value::{Temporal, Value};
use tiberius::numeric::Numeric;
use tiberius::{ColumnData, IntoSql, ToSql};

/// The widest decimal SQL Server stores: 38 digits.
const MAX_NUMERIC_DIGITS: u32 = 38;

/// The parameters of a statement as TDS values, typed by what the
/// server expects, so a NULL keeps its type: an untyped NULL arrives as
/// nvarchar, which SQL Server will not convert into varbinary.
pub(crate) fn encode_params(params: &[BoundParam]) -> Result<Vec<ColumnData<'static>>, DriverError> {
    params.iter().map(encode).collect()
}

/// The form `Client::query` and `Client::execute` take.
pub(crate) fn as_sql<'a>(params: &'a [ColumnData<'static>]) -> Vec<&'a dyn ToSql> {
    params.iter().map(|param| param as &dyn ToSql).collect()
}

pub(crate) fn encode(param: &BoundParam) -> Result<ColumnData<'static>, DriverError> {
    let value = param.value();
    let param_type = param.param_type();
    if value.is_null() {
        return Ok(typed_null(param_type));
    }
    match param_type {
        ParamType::Bool => match value {
            Value::Bool(flag) => Ok(ColumnData::Bit(Some(*flag))),
            other => Err(refused(param_type, other)),
        },
        ParamType::Int16 => {
            let integer = whole(param_type, value)?;
            let narrow = i16::try_from(integer).map_err(|_| out_of_range(integer, "smallint"))?;
            Ok(ColumnData::I16(Some(narrow)))
        }
        ParamType::Int32 => {
            let integer = whole(param_type, value)?;
            let narrow = i32::try_from(integer).map_err(|_| out_of_range(integer, "int"))?;
            Ok(ColumnData::I32(Some(narrow)))
        }
        ParamType::Int64 => {
            let integer = whole(param_type, value)?;
            let narrow = i64::try_from(integer).map_err(|_| out_of_range(integer, "bigint"))?;
            Ok(ColumnData::I64(Some(narrow)))
        }
        // SQL Server has no unsigned 64-bit type; decimal(20,0) holds
        // every value of one.
        ParamType::UInt64 | ParamType::Decimal => {
            numeric(param_type, value).map(|numeric| ColumnData::Numeric(Some(numeric)))
        }
        ParamType::Float32 => match value {
            Value::Float32(real) => Ok(ColumnData::F32(Some(*real))),
            other => Err(refused(param_type, other)),
        },
        ParamType::Float64 => match value {
            Value::Float64(real) => Ok(ColumnData::F64(Some(*real))),
            Value::Float32(real) => Ok(ColumnData::F64(Some(f64::from(*real)))),
            other => Err(refused(param_type, other)),
        },
        ParamType::Text | ParamType::FixedText | ParamType::ServerText(_) | ParamType::Json | ParamType::JsonBinary => {
            match value {
                Value::Text(text) => Ok(text_data(text.clone())),
                Value::Json(json) => Ok(text_data(json.as_str().to_owned())),
                Value::Other(other) => Ok(text_data(other.text.clone())),
                other => Err(refused(param_type, other)),
            }
        }
        ParamType::Bytes => match value {
            Value::Bytes(bytes) => Ok(ColumnData::Binary(Some(Cow::Owned(bytes.clone())))),
            other => Err(refused(param_type, other)),
        },
        ParamType::Uuid => match value {
            Value::Uuid(uuid) => Ok(ColumnData::Guid(Some(*uuid))),
            other => Err(refused(param_type, other)),
        },
        ParamType::Date => match value {
            Value::Date(Temporal::Finite(date)) => in_range(*date).map(|date| date.into_sql()),
            other => Err(refused(param_type, other)),
        },
        ParamType::Time => match value {
            Value::Time(time) => time
                .to_time_of_day()
                .map(IntoSql::into_sql)
                .ok_or(DriverError::Unsupported {
                    feature: "a time outside one day",
                }),
            other => Err(refused(param_type, other)),
        },
        ParamType::Timestamp => match value {
            Value::Timestamp(Temporal::Finite(stamp)) => {
                in_range(stamp.date())?;
                Ok((*stamp).into_sql())
            }
            other => Err(refused(param_type, other)),
        },
        ParamType::TimestampTz => match value {
            Value::TimestampTz(Temporal::Finite(stamp)) => {
                in_range(stamp.utc().date())?;
                Ok(stamp.to_datetime().into_sql())
            }
            other => Err(refused(param_type, other)),
        },
        ParamType::TimeTz => Err(DriverError::Unsupported {
            feature: "a time with an offset",
        }),
        ParamType::Interval => Err(DriverError::Unsupported { feature: "an interval" }),
    }
}

/// A NULL of the type the server expects in that place.
fn typed_null(param_type: &ParamType) -> ColumnData<'static> {
    match param_type {
        ParamType::Bool => ColumnData::Bit(None),
        ParamType::Int16 => ColumnData::I16(None),
        ParamType::Int32 => ColumnData::I32(None),
        ParamType::Int64 => ColumnData::I64(None),
        ParamType::UInt64 | ParamType::Decimal => ColumnData::Numeric(None),
        ParamType::Float32 => ColumnData::F32(None),
        ParamType::Float64 => ColumnData::F64(None),
        ParamType::Bytes => ColumnData::Binary(None),
        ParamType::Uuid => ColumnData::Guid(None),
        ParamType::Date => ColumnData::Date(None),
        ParamType::Time => ColumnData::Time(None),
        ParamType::Timestamp => ColumnData::DateTime2(None),
        ParamType::TimestampTz => ColumnData::DateTimeOffset(None),
        ParamType::Text
        | ParamType::FixedText
        | ParamType::ServerText(_)
        | ParamType::Json
        | ParamType::JsonBinary
        | ParamType::TimeTz
        | ParamType::Interval => ColumnData::String(None),
    }
}

fn text_data(text: String) -> ColumnData<'static> {
    ColumnData::String(Some(Cow::Owned(text)))
}

/// An integer value as the widest integer it can be, so each width can
/// say whether it fits.
fn whole(param_type: &ParamType, value: &Value) -> Result<i128, DriverError> {
    match value {
        Value::Int(integer) => Ok(i128::from(*integer)),
        Value::UInt(integer) => Ok(i128::from(*integer)),
        other => Err(refused(param_type, other)),
    }
}

fn numeric(param_type: &ParamType, value: &Value) -> Result<Numeric, DriverError> {
    let (mantissa, scale) = match value {
        Value::Int(integer) => (i128::from(*integer), 0),
        Value::UInt(integer) => (i128::from(*integer), 0),
        Value::WideInt(integer) => (
            integer.to_i128().ok_or(DriverError::Unsupported {
                feature: "an integer wider than 38 digits",
            })?,
            0,
        ),
        Value::Decimal(decimal) => decimal.to_scaled_i128().ok_or(DriverError::Unsupported {
            feature: "a decimal NaN, infinity or wider than 38 digits",
        })?,
        other => return Err(refused(param_type, other)),
    };
    let fits = 10u128
        .checked_pow(MAX_NUMERIC_DIGITS)
        .is_some_and(|limit| mantissa.unsigned_abs() < limit);
    let scale = u8::try_from(scale)
        .ok()
        .filter(|scale| *scale <= Numeric::MAX_NUMERIC_SCALE);
    match (fits, scale) {
        (true, Some(scale)) => Ok(Numeric::new_with_scale(mantissa, scale)),
        _ => Err(DriverError::Unsupported {
            feature: "a decimal wider than 38 digits",
        }),
    }
}

/// SQL Server's dates run from 0001-01-01 to 9999-12-31.
fn in_range(date: NaiveDate) -> Result<NaiveDate, DriverError> {
    match (1..=9999).contains(&date.year()) {
        true => Ok(date),
        false => Err(DriverError::Unsupported {
            feature: "a date outside years 1 to 9999",
        }),
    }
}

fn refused(param_type: &ParamType, value: &Value) -> DriverError {
    DriverError::Protocol(format!(
        "a {} parameter cannot carry a {} value",
        param_type.name(),
        value.variant_name()
    ))
}

fn out_of_range(integer: i128, sql_type: &str) -> DriverError {
    DriverError::Protocol(format!("{integer} does not fit a {sql_type} parameter"))
}

#[cfg(test)]
mod tests {
    use chrono::DateTime;
    use tablepro_core::column::SqlTypeExpr;
    use tablepro_core::value::{OffsetTimestamp, SqlDecimal};

    use super::*;

    fn bound(value: Value, param_type: ParamType) -> BoundParam {
        BoundParam::new(value, param_type).unwrap()
    }

    #[test]
    fn a_null_keeps_the_type_the_server_expects() {
        let varbinary = encode(&bound(Value::Null, ParamType::Bytes)).unwrap();
        let uuid = encode(&bound(Value::Null, ParamType::Uuid)).unwrap();
        let server = encode(&bound(
            Value::Null,
            ParamType::ServerText(SqlTypeExpr::from_catalog_text("geography")),
        ))
        .unwrap();

        assert_eq!(varbinary, ColumnData::Binary(None));
        assert_eq!(uuid, ColumnData::Guid(None));
        assert_eq!(server, ColumnData::String(None));
    }

    #[test]
    fn a_decimal_travels_as_its_scaled_integer() {
        let decimal: SqlDecimal = "-12345678901234567890.1234".parse().unwrap();

        let encoded = encode(&bound(Value::Decimal(decimal), ParamType::Decimal)).unwrap();

        assert_eq!(
            encoded,
            ColumnData::Numeric(Some(Numeric::new_with_scale(-123_456_789_012_345_678_901_234, 4)))
        );
        assert!(encode(&bound(Value::Decimal(SqlDecimal::nan()), ParamType::Decimal)).is_err());
        assert_eq!(
            encode(&bound(Value::UInt(u64::MAX), ParamType::UInt64)).unwrap(),
            ColumnData::Numeric(Some(Numeric::new_with_scale(i128::from(u64::MAX), 0)))
        );
    }

    #[test]
    fn integers_are_checked_against_their_width() {
        assert_eq!(
            encode(&bound(Value::Int(255), ParamType::Int16)).unwrap(),
            ColumnData::I16(Some(255))
        );
        assert!(encode(&bound(Value::Int(70_000), ParamType::Int16)).is_err());
        assert!(encode(&bound(Value::UInt(u64::MAX), ParamType::Int64)).is_err());
    }

    #[test]
    fn a_timestamp_with_offset_keeps_its_offset() {
        let stamp = DateTime::parse_from_rfc3339("2024-06-15T13:45:30.1234567+05:30").unwrap();
        let value = Value::TimestampTz(Temporal::Finite(OffsetTimestamp::from_datetime(stamp)));

        let encoded = encode(&bound(value, ParamType::TimestampTz)).unwrap();

        let ColumnData::DateTimeOffset(Some(offset)) = encoded else {
            panic!("not a datetimeoffset: {encoded:?}");
        };
        assert_eq!(offset.offset(), 330);
        assert_eq!(
            offset.datetime2().time().increments(),
            (8 * 3600 + 15 * 60 + 30) * 10_000_000 + 1_234_567
        );
    }

    #[test]
    fn a_date_before_year_one_is_refused_rather_than_wrapped() {
        let early = NaiveDate::from_ymd_opt(0, 12, 31)
            .and_then(|date| date.and_hms_opt(0, 0, 0))
            .unwrap();

        assert!(encode(&bound(Value::Timestamp(Temporal::Finite(early)), ParamType::Timestamp)).is_err());
        assert!(matches!(
            encode(&bound(Value::Date(Temporal::Infinity), ParamType::Date)),
            Err(DriverError::Protocol(_))
        ));
    }

    #[test]
    fn text_travels_as_nvarchar() {
        assert_eq!(
            encode(&bound(Value::Text("Zoë".to_owned()), ParamType::FixedText)).unwrap(),
            ColumnData::String(Some(Cow::Borrowed("Zoë")))
        );
    }
}
