//! Parameters as SQLite storage classes.
//!
//! SQLite has five classes and no wire types, so a parameter is bound
//! as the class that keeps its value exactly: integers as INTEGER,
//! floats as REAL, bytes as BLOB, and everything else as the text the
//! app shows for it. The `ParamType` was checked against the value when
//! the parameter was built, and the value alone names its class.

use sqlx::Sqlite;
use sqlx::query::Query;
use sqlx::sqlite::SqliteArguments;
use tablepro_core::DriverError;
use tablepro_core::export::value_to_text;
use tablepro_core::statement::BoundParam;
use tablepro_core::value::Value;

pub(crate) fn bind_all<'q>(
    mut query: Query<'q, Sqlite, SqliteArguments>,
    params: &[BoundParam],
) -> Result<Query<'q, Sqlite, SqliteArguments>, DriverError> {
    for param in params {
        query = bind_one(query, param)?;
    }
    Ok(query)
}

fn bind_one<'q>(
    query: Query<'q, Sqlite, SqliteArguments>,
    param: &BoundParam,
) -> Result<Query<'q, Sqlite, SqliteArguments>, DriverError> {
    Ok(match param.value() {
        Value::Null => query.bind(None::<i64>),
        Value::Bool(flag) => query.bind(i64::from(*flag)),
        Value::Int(integer) => query.bind(*integer),
        // SQLite has no unsigned integer. Past i64 the digits are bound
        // as text, which keeps them exact where a real would round.
        Value::UInt(integer) => match i64::try_from(*integer) {
            Ok(integer) => query.bind(integer),
            Err(_) => query.bind(integer.to_string()),
        },
        Value::WideInt(integer) => match integer.to_i128().and_then(|wide| i64::try_from(wide).ok()) {
            Some(integer) => query.bind(integer),
            None => query.bind(integer.to_string()),
        },
        Value::Float32(real) => query.bind(f64::from(*real)),
        Value::Float64(real) => query.bind(*real),
        Value::Bytes(bytes) => query.bind(bytes.clone()),
        Value::Undecodable(_) | Value::Array(_) => {
            return Err(DriverError::Protocol(format!(
                "a {} value cannot be bound as a SQLite parameter",
                param.value().variant_name()
            )));
        }
        // Text, decimals, UUIDs, JSON and temporals are stored as the
        // text SQLite's own functions read and write: ISO dates, and
        // decimals in full, left to the column's affinity to convert.
        other => match value_to_text(other) {
            Some(text) => query.bind(text),
            None => query.bind(None::<i64>),
        },
    })
}
