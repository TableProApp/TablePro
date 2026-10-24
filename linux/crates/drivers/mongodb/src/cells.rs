use bson::Bson;
use bson::spec::BinarySubtype;
use chrono::DateTime;
use tablepro_core::value::{JsonText, OffsetTimestamp, OtherValue, SqlDecimal, Temporal, Value};

use crate::extended_json::extended_json;

/// A field's value as a grid cell, by the value's own type: the grid shows
/// a number, a string, a date or an id plainly, and anything that nests or
/// has no plain form as extended JSON, which reads back as the same type.
pub(crate) fn cell(value: &Bson) -> Value {
    match value {
        Bson::Double(number) => Value::Float64(*number),
        Bson::Int32(number) => Value::Int(i64::from(*number)),
        Bson::Int64(number) => Value::Int(*number),
        Bson::Decimal128(number) => match number.to_string().parse::<SqlDecimal>() {
            Ok(decimal) if decimal.is_finite() => Value::Decimal(decimal),
            _ => json(value),
        },
        Bson::String(text) => Value::Text(text.clone()),
        Bson::Boolean(flag) => Value::Bool(*flag),
        Bson::Null => Value::Null,
        Bson::DateTime(date) => match DateTime::from_timestamp_millis(date.timestamp_millis()) {
            Some(utc) => Value::TimestampTz(Temporal::Finite(OffsetTimestamp::from_datetime(utc.fixed_offset()))),
            None => json(value),
        },
        Bson::ObjectId(id) => Value::Other(Box::new(OtherValue {
            type_name: "objectId".to_owned(),
            text: id.to_hex(),
        })),
        Bson::Binary(binary) if binary.subtype == BinarySubtype::Uuid => match uuid::Uuid::from_slice(&binary.bytes) {
            Ok(uuid) => Value::Uuid(uuid),
            Err(_) => json(value),
        },
        Bson::Binary(binary) if binary.subtype == BinarySubtype::Generic => Value::Bytes(binary.bytes.clone()),
        _ => json(value),
    }
}

/// A value as an extended JSON cell.
pub(crate) fn json(value: &Bson) -> Value {
    match JsonText::parse(extended_json(value)) {
        Ok(text) => Value::Json(text),
        Err(_) => Value::Text(extended_json(value)),
    }
}

#[cfg(test)]
mod tests {
    use bson::oid::ObjectId;
    use bson::{Binary, doc};

    use super::*;

    #[test]
    fn plain_values_show_plainly_and_the_rest_as_extended_json() {
        let id = ObjectId::parse_str("5f1d7a0c9b1e8b2a3c4d5e6f").expect("an id");
        assert_eq!(cell(&Bson::Int32(3)), Value::Int(3));
        assert_eq!(cell(&Bson::String("a".to_owned())), Value::Text("a".to_owned()));
        assert_eq!(
            cell(&Bson::ObjectId(id)),
            Value::Other(Box::new(OtherValue {
                type_name: "objectId".to_owned(),
                text: "5f1d7a0c9b1e8b2a3c4d5e6f".to_owned(),
            }))
        );
        let uuid = uuid::Uuid::new_v4();
        assert_eq!(
            cell(&Bson::Binary(Binary {
                subtype: BinarySubtype::Uuid,
                bytes: uuid.as_bytes().to_vec(),
            })),
            Value::Uuid(uuid)
        );
        assert!(matches!(
            cell(&Bson::DateTime(bson::DateTime::from_millis(0))),
            Value::TimestampTz(_)
        ));
        let nested = cell(&Bson::Document(doc! { "a": [1_i32, 2_i64] }));
        assert_eq!(
            nested,
            Value::Json(JsonText::parse(r#"{"a": [1, {"$numberLong": "2"}]}"#.to_owned()).expect("JSON"))
        );
        assert!(matches!(cell(&Bson::MaxKey), Value::Json(_)));
    }
}
