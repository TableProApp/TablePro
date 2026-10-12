//! Values read by the storage class SQLite holds them in.
//!
//! A column's declared type is advice: any column of a table that is not
//! STRICT holds any of the five classes, row by row. A value is read as
//! exactly what is stored, so writing it back, or naming its row by it,
//! sends the same bytes. The declared type decides only how the grid
//! shows it, through the column's kind.

use sqlx::sqlite::{SqliteRow, SqliteValueRef};
use sqlx::{Decode, Row, Sqlite, TypeInfo, ValueRef};
use tablepro_core::value::{UndecodableReason, UndecodedValue, Value};

/// Every cell of a row, in column order.
pub(crate) fn decode_row(row: &SqliteRow) -> Vec<Value> {
    (0..row.len())
        .map(|index| match row.try_get_raw(index) {
            Ok(raw) => decode_cell(raw),
            Err(_) => undecodable("", UndecodableReason::UnsupportedType),
        })
        .collect()
}

pub(crate) fn decode_cell(raw: SqliteValueRef<'_>) -> Value {
    if raw.is_null() {
        return Value::Null;
    }
    let class = raw.type_info().name().to_owned();
    match class.as_str() {
        "INTEGER" => match <i64 as Decode<Sqlite>>::decode(raw) {
            Ok(integer) => Value::Int(integer),
            Err(_) => undecodable(&class, UndecodableReason::OutOfRange),
        },
        "REAL" => match <f64 as Decode<Sqlite>>::decode(raw) {
            Ok(real) => Value::Float64(real),
            Err(_) => undecodable(&class, UndecodableReason::OutOfRange),
        },
        // SQLite does not check that TEXT is UTF-8. Text that is not
        // stays unreadable rather than being repaired into other text.
        "TEXT" => match <&[u8] as Decode<Sqlite>>::decode(raw) {
            Ok(bytes) => match std::str::from_utf8(bytes) {
                Ok(text) => Value::Text(text.to_owned()),
                Err(_) => undecodable(&class, UndecodableReason::InvalidEncoding),
            },
            Err(_) => undecodable(&class, UndecodableReason::InvalidEncoding),
        },
        "BLOB" => match <&[u8] as Decode<Sqlite>>::decode(raw) {
            Ok(bytes) => Value::Bytes(bytes.to_vec()),
            Err(_) => undecodable(&class, UndecodableReason::InvalidEncoding),
        },
        _ => undecodable(&class, UndecodableReason::UnsupportedType),
    }
}

fn undecodable(type_name: &str, reason: UndecodableReason) -> Value {
    Value::Undecodable(Box::new(UndecodedValue {
        type_name: type_name.to_owned(),
        reason,
    }))
}
