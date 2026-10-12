//! Parameters bound by the type the dialect gave them.
//!
//! The `ParamType` was checked against the value when the parameter was
//! built, so here it only decides the wire form. Integers stay 64-bit:
//! the server converts to the column's width and reports what does not
//! fit, where a narrowing here would fail first with a vaguer message.

use sqlx::MySql;
use sqlx::mysql::MySqlArguments;
use sqlx::query::Query;
use tablepro_core::DriverError;
use tablepro_core::export::value_to_text;
use tablepro_core::statement::{BoundParam, ParamType};
use tablepro_core::value::{Temporal, Value};

pub(crate) type MySqlQuery<'q> = Query<'q, MySql, MySqlArguments>;

pub(crate) fn bind_all<'q>(mut query: MySqlQuery<'q>, params: &[BoundParam]) -> Result<MySqlQuery<'q>, DriverError> {
    for param in params {
        query = bind_one(query, param)?;
    }
    Ok(query)
}

fn bind_one<'q>(query: MySqlQuery<'q>, param: &BoundParam) -> Result<MySqlQuery<'q>, DriverError> {
    let value = param.value();
    Ok(match (param.param_type(), value) {
        (_, Value::Null) => query.bind(None::<String>),
        (_, Value::Bool(flag)) => query.bind(*flag),
        (_, Value::Int(integer)) => query.bind(*integer),
        (_, Value::UInt(integer)) => query.bind(*integer),
        (ParamType::Float32, Value::Float32(real)) => query.bind(*real),
        (_, Value::Float32(real)) => query.bind(f64::from(*real)),
        (_, Value::Float64(real)) => query.bind(*real),
        (_, Value::Bytes(bytes)) => query.bind(bytes.clone()),
        // A BIT column takes the number its bits spell.
        (_, Value::Bits(bits)) => match bits.to_u64() {
            Some(number) => query.bind(number),
            None => return Err(unrepresentable(value)),
        },
        (_, Value::Date(Temporal::Finite(date))) => query.bind(*date),
        (_, Value::Timestamp(Temporal::Finite(stamp))) => query.bind(*stamp),
        // The workspace session reads and writes TIMESTAMP in UTC, so the
        // instant goes as its UTC wall time.
        (_, Value::TimestampTz(Temporal::Finite(stamp))) => query.bind(stamp.utc()),
        (_, Value::Date(_) | Value::Timestamp(_) | Value::TimestampTz(_)) => return Err(unrepresentable(value)),
        (_, Value::Decimal(decimal)) if !decimal.is_finite() => return Err(unrepresentable(value)),
        (_, Value::Undecodable(_) | Value::Array(_)) => return Err(unrepresentable(value)),
        // Decimals in full, TIME with its sign and hundreds of hours, JSON
        // as written, enum labels and UUIDs: the server parses the text
        // into the column's own type.
        (_, other) => match value_to_text(other) {
            Some(text) => query.bind(text),
            None => return Err(unrepresentable(value)),
        },
    })
}

fn unrepresentable(value: &Value) -> DriverError {
    DriverError::Protocol(format!(
        "a {} value cannot be bound as a MySQL parameter",
        value.variant_name()
    ))
}
