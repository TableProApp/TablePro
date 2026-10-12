use std::error::Error;

use bytes::{BufMut, BytesMut};
use chrono::Utc;
use postgres_protocol::types as wire;
use postgres_types::{Format, IsNull, ToSql, Type, to_sql_checked};
use tablepro_core::Value;
use tablepro_core::statement::{BoundParam, ParamType};
use tablepro_core::value::{BitString, SqlTime, Temporal, TimeWithOffset};

use super::interval_wire::interval_to_sql;
use super::temporal_wire::{time_to_sql, timetz_to_sql};

type EncodeError = Box<dyn Error + Sync + Send>;

const JSONB_VERSION: u8 = 1;

/// A bound parameter on its way to the server, encoded strictly by the
/// type it was bound as.
///
/// The few types without a binary encoder here (NUMERIC, and a time
/// finer than a microsecond) go as text, which the server parses with
/// the parameter's declared type, so nothing is rounded on this side.
#[derive(Debug)]
pub(crate) struct PgParam<'a>(pub(crate) &'a BoundParam);

impl ToSql for PgParam<'_> {
    fn to_sql(&self, _ty: &Type, out: &mut BytesMut) -> Result<IsNull, EncodeError> {
        encode(self.0, out)
    }

    fn accepts(_: &Type) -> bool {
        true
    }

    to_sql_checked!();

    fn encode_format(&self, _ty: &Type) -> Format {
        if sends_text(self.0) {
            Format::Text
        } else {
            Format::Binary
        }
    }
}

/// The type the parameter is declared as in the Parse message. A NULL
/// keeps it, so the server types the NULL the way the column is typed.
pub(crate) fn wire_type(param: &BoundParam) -> Type {
    match param.param_type() {
        ParamType::Bool => Type::BOOL,
        ParamType::Int16 => Type::INT2,
        ParamType::Int32 => Type::INT4,
        ParamType::Int64 => Type::INT8,
        // PostgreSQL has no unsigned integer; NUMERIC holds every u64.
        ParamType::UInt64 | ParamType::Decimal => Type::NUMERIC,
        ParamType::Float32 => Type::FLOAT4,
        ParamType::Float64 => Type::FLOAT8,
        ParamType::Text | ParamType::ServerText(_) => Type::TEXT,
        ParamType::FixedText => Type::BPCHAR,
        ParamType::Bytes => match param.value() {
            Value::Bits(_) => Type::VARBIT,
            _ => Type::BYTEA,
        },
        ParamType::Uuid => Type::UUID,
        ParamType::Json => Type::JSON,
        ParamType::JsonBinary => Type::JSONB,
        ParamType::Date => Type::DATE,
        ParamType::Time => Type::TIME,
        ParamType::TimeTz => Type::TIMETZ,
        ParamType::Timestamp => Type::TIMESTAMP,
        ParamType::TimestampTz => Type::TIMESTAMPTZ,
        ParamType::Interval => Type::INTERVAL,
    }
}

/// The parameters of a statement with the types they are declared as,
/// for `query_typed_raw` and `execute_typed`.
pub(crate) fn typed(params: &[BoundParam]) -> Vec<(PgParam<'_>, Type)> {
    params.iter().map(|param| (PgParam(param), wire_type(param))).collect()
}

fn sends_text(param: &BoundParam) -> bool {
    match (param.param_type(), param.value()) {
        (ParamType::UInt64 | ParamType::Decimal, _) => true,
        (ParamType::Time, Value::Time(time)) => time.total_micros().is_none(),
        (ParamType::TimeTz, Value::TimeTz(time)) => time.time.total_micros().is_none(),
        _ => false,
    }
}

fn encode(param: &BoundParam, out: &mut BytesMut) -> Result<IsNull, EncodeError> {
    let value = param.value();
    if value.is_null() {
        return Ok(IsNull::Yes);
    }
    if sends_text(param) {
        let text = match value {
            Value::Time(time) => time.format(None),
            Value::TimeTz(time) => timetz_text(time),
            other => decimal_text(other).ok_or("this value is not a number")?,
        };
        wire::text_to_sql(&text, out);
        return Ok(IsNull::No);
    }
    match (param.param_type(), value) {
        (ParamType::Bool, Value::Bool(flag)) => wire::bool_to_sql(*flag, out),
        (ParamType::Int16, Value::Int(int)) => wire::int2_to_sql(i16::try_from(*int)?, out),
        (ParamType::Int32, Value::Int(int)) => wire::int4_to_sql(i32::try_from(*int)?, out),
        (ParamType::Int64, Value::Int(int)) => wire::int8_to_sql(*int, out),
        (ParamType::Int64, Value::UInt(int)) => wire::int8_to_sql(i64::try_from(*int)?, out),
        (ParamType::Float32, Value::Float32(float)) => wire::float4_to_sql(*float, out),
        (ParamType::Float64, Value::Float64(float)) => wire::float8_to_sql(*float, out),
        (ParamType::Float64, Value::Float32(float)) => wire::float8_to_sql(f64::from(*float), out),
        (ParamType::Text | ParamType::FixedText | ParamType::ServerText(_), Value::Text(text)) => {
            wire::text_to_sql(text, out)
        }
        (ParamType::Bytes, Value::Bytes(bytes)) => wire::bytea_to_sql(bytes, out),
        (ParamType::Bytes, Value::Bits(bits)) => varbit(bits, out)?,
        (ParamType::Uuid, Value::Uuid(uuid)) => wire::uuid_to_sql(*uuid.as_bytes(), out),
        (ParamType::Json, Value::Json(json)) => wire::text_to_sql(json.as_str(), out),
        (ParamType::JsonBinary, Value::Json(json)) => {
            out.put_u8(JSONB_VERSION);
            wire::text_to_sql(json.as_str(), out);
        }
        (ParamType::Date, Value::Date(date)) => match date {
            Temporal::Finite(date) => return date.to_sql(&Type::DATE, out),
            Temporal::Infinity => wire::date_to_sql(i32::MAX, out),
            Temporal::NegInfinity => wire::date_to_sql(i32::MIN, out),
        },
        (ParamType::Time, Value::Time(time)) => time_to_sql(micros(time)?, out),
        (ParamType::TimeTz, Value::TimeTz(time)) => timetz_to_sql(micros(&time.time)?, time.offset, out),
        (ParamType::Timestamp, Value::Timestamp(stamp)) => match stamp {
            Temporal::Finite(stamp) => return stamp.to_sql(&Type::TIMESTAMP, out),
            Temporal::Infinity => wire::timestamp_to_sql(i64::MAX, out),
            Temporal::NegInfinity => wire::timestamp_to_sql(i64::MIN, out),
        },
        (ParamType::TimestampTz, Value::TimestampTz(stamp)) => match stamp {
            Temporal::Finite(stamp) => {
                return stamp.to_datetime().with_timezone(&Utc).to_sql(&Type::TIMESTAMPTZ, out);
            }
            Temporal::Infinity => wire::timestamp_to_sql(i64::MAX, out),
            Temporal::NegInfinity => wire::timestamp_to_sql(i64::MIN, out),
        },
        (ParamType::Interval, Value::Interval(interval)) => interval_to_sql(interval, out),
        (param_type, value) => {
            return Err(format!(
                "a {} value cannot be sent as a {} parameter",
                value.variant_name(),
                param_type.name()
            )
            .into());
        }
    }
    Ok(IsNull::No)
}

fn micros(time: &SqlTime) -> Result<i64, EncodeError> {
    time.total_micros()
        .ok_or_else(|| "the time is finer than a microsecond".into())
}

fn decimal_text(value: &Value) -> Option<String> {
    match value {
        Value::Decimal(decimal) => Some(decimal.to_string()),
        Value::Int(int) => Some(int.to_string()),
        Value::UInt(int) => Some(int.to_string()),
        Value::WideInt(int) => Some(int.to_string()),
        _ => None,
    }
}

fn timetz_text(time: &TimeWithOffset) -> String {
    let seconds = time.offset.local_minus_utc();
    let sign = if seconds < 0 { '-' } else { '+' };
    let magnitude = seconds.unsigned_abs();
    format!(
        "{}{sign}{:02}:{:02}:{:02}",
        time.time.format(None),
        magnitude / 3600,
        magnitude / 60 % 60,
        magnitude % 60
    )
}

fn varbit(bits: &BitString, out: &mut BytesMut) -> Result<(), EncodeError> {
    let text = bits.to_string();
    let packed = text.as_bytes().chunks(8).map(|chunk| {
        chunk.iter().enumerate().fold(0u8, |byte, (position, bit)| match bit {
            b'1' => byte | (0x80 >> position),
            _ => byte,
        })
    });
    wire::varbit_to_sql(text.len(), packed, out)
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::SqlTypeExpr;
    use tablepro_core::value::SqlDecimal;

    use super::*;

    fn bound(value: Value, param_type: ParamType) -> BoundParam {
        BoundParam::new(value, param_type).expect("a bound parameter")
    }

    fn encoded(param: &BoundParam) -> (IsNull, BytesMut) {
        let mut out = BytesMut::new();
        let is_null = PgParam(param)
            .to_sql_checked(&wire_type(param), &mut out)
            .expect("an encodable parameter");
        (is_null, out)
    }

    #[test]
    fn pg_param_null_typed_by_oid() {
        for (param_type, expected) in [
            (ParamType::Int32, Type::INT4),
            (ParamType::Int64, Type::INT8),
            (ParamType::Bool, Type::BOOL),
            (ParamType::Date, Type::DATE),
            (ParamType::Uuid, Type::UUID),
            (ParamType::Decimal, Type::NUMERIC),
            (ParamType::TimestampTz, Type::TIMESTAMPTZ),
        ] {
            let param = bound(Value::Null, param_type);

            let (is_null, out) = encoded(&param);

            assert_eq!(wire_type(&param), expected);
            assert!(matches!(is_null, IsNull::Yes));
            assert!(out.is_empty());
        }
    }

    #[test]
    fn pg_param_decimal_nan_sent_as_text_numeric() {
        let param = bound(Value::Decimal(SqlDecimal::nan()), ParamType::Decimal);

        let (_, out) = encoded(&param);

        assert_eq!(wire_type(&param), Type::NUMERIC);
        assert!(matches!(PgParam(&param).encode_format(&Type::NUMERIC), Format::Text));
        assert_eq!(&out[..], b"NaN");
    }

    #[test]
    fn a_value_too_wide_for_its_parameter_is_refused_not_wrapped() {
        let param = bound(Value::Int(70_000), ParamType::Int16);
        let mut out = BytesMut::new();

        assert!(PgParam(&param).to_sql_checked(&Type::INT2, &mut out).is_err());
    }

    #[test]
    fn bits_go_as_varbit_and_server_text_as_text() {
        let bits = bound(Value::Bits(BitString::from_u64(0b101, 3)), ParamType::Bytes);
        let (_, out) = encoded(&bits);
        assert_eq!(wire_type(&bits), Type::VARBIT);
        assert_eq!(&out[..], &[0, 0, 0, 3, 0b1010_0000]);

        let mood = bound(
            Value::Text("happy".to_owned()),
            ParamType::ServerText(SqlTypeExpr::from_catalog_text("mood")),
        );
        assert_eq!(wire_type(&mood), Type::TEXT);
        assert_eq!(&encoded(&mood).1[..], b"happy");
    }

    #[test]
    fn infinite_dates_and_the_end_of_day_encode_exactly() {
        let date = bound(Value::Date(Temporal::Infinity), ParamType::Date);
        assert_eq!(&encoded(&date).1[..], &i32::MAX.to_be_bytes());

        let end_of_day: SqlTime = "24:00:00".parse().expect("a time");
        let time = bound(Value::Time(end_of_day), ParamType::Time);
        assert_eq!(&encoded(&time).1[..], &86_400_000_000i64.to_be_bytes());
    }
}
