use crate::sql_syntax::mongo::{ShellConstructor, ShellValue, parse_value};
use crate::value::Value;

/// The brackets MongoDB sorts values of different types in, lowest
/// first, each by the `$type` aliases that fall in it. A comparison such
/// as `$gt` only matches values of the operand's own bracket, so a key
/// page reaches the brackets after it with `$type`.
const BRACKETS: [&[&str]; 13] = [
    &["minKey"],
    &["null"],
    &["double", "int", "long", "decimal"],
    &["string", "symbol"],
    &["object"],
    &["array"],
    &["binData"],
    &["objectId"],
    &["bool"],
    &["date"],
    &["timestamp"],
    &["regex"],
    &["maxKey"],
];

/// The type aliases of every bracket after `value`'s, or before it, or
/// `None` when the value's bracket is not known.
pub(crate) fn aliases_beyond(value: &Value, after: bool) -> Option<Vec<&'static str>> {
    let bracket = bracket_of(value)?;
    let brackets = match after {
        true => BRACKETS.get(bracket + 1..)?,
        false => BRACKETS.get(..bracket)?,
    };
    Some(brackets.iter().flat_map(|aliases| aliases.iter().copied()).collect())
}

fn bracket_named(alias: &str) -> Option<usize> {
    BRACKETS.iter().position(|aliases| aliases.contains(&alias))
}

/// Where a key read from a page sorts, by the type it was read as.
fn bracket_of(value: &Value) -> Option<usize> {
    let alias = match value {
        Value::Null => "null",
        Value::Int(_)
        | Value::UInt(_)
        | Value::Float32(_)
        | Value::Float64(_)
        | Value::Decimal(_)
        | Value::WideInt(_) => "double",
        Value::Text(_) => "string",
        Value::Bool(_) => "bool",
        Value::Bytes(_) | Value::Uuid(_) => "binData",
        Value::Date(_) | Value::Timestamp(_) | Value::TimestampTz(_) => "date",
        Value::Other(other) => other.type_name.as_str(),
        Value::Json(json) => return shell_bracket(&parse_value(json.as_str()).ok()?),
        Value::Time(_)
        | Value::TimeTz(_)
        | Value::Interval(_)
        | Value::Bits(_)
        | Value::Array(_)
        | Value::Undecodable(_) => return None,
    };
    bracket_named(alias)
}

/// The bracket of a value written as extended JSON or shell text.
fn shell_bracket(value: &ShellValue) -> Option<usize> {
    let alias = match value {
        ShellValue::Null => "null",
        ShellValue::Number(_) => "double",
        ShellValue::String(_) => "string",
        ShellValue::Bool(_) => "bool",
        ShellValue::Array(_) => "array",
        ShellValue::Regex { .. } => "regex",
        ShellValue::Param(_) => return None,
        ShellValue::Constructor { kind, .. } => match kind {
            ShellConstructor::ObjectId => "objectId",
            ShellConstructor::Date => "date",
            ShellConstructor::Int32
            | ShellConstructor::Int64
            | ShellConstructor::Double
            | ShellConstructor::Decimal128 => "double",
            ShellConstructor::Timestamp => "timestamp",
            ShellConstructor::Uuid | ShellConstructor::BinData | ShellConstructor::HexData => "binData",
            ShellConstructor::MinKey => "minKey",
            ShellConstructor::MaxKey => "maxKey",
            ShellConstructor::RegExp => "regex",
            ShellConstructor::Code => return None,
        },
        ShellValue::Object(fields) => match fields.first().map(|(key, _)| key.as_str()) {
            Some("$oid") => "objectId",
            Some("$date") => "date",
            Some("$numberInt" | "$numberLong" | "$numberDouble" | "$numberDecimal") => "double",
            Some("$binary" | "$uuid") => "binData",
            Some("$timestamp") => "timestamp",
            Some("$regularExpression") => "regex",
            Some("$minKey") => "minKey",
            Some("$maxKey") => "maxKey",
            Some("$symbol") => "string",
            Some("$code") => return None,
            _ => "object",
        },
    };
    bracket_named(alias)
}

#[cfg(test)]
mod tests {
    use crate::value::{JsonText, OtherValue};

    use super::*;

    fn object_id() -> Value {
        Value::Other(Box::new(OtherValue {
            type_name: "objectId".to_owned(),
            text: "5f1d7a0c9b1e8b2a3c4d5e6f".to_owned(),
        }))
    }

    #[test]
    fn the_brackets_after_an_object_id_are_the_later_types() {
        assert_eq!(
            aliases_beyond(&object_id(), true),
            Some(vec!["bool", "date", "timestamp", "regex", "maxKey"])
        );
        assert_eq!(aliases_beyond(&Value::Int(5), false), Some(vec!["minKey", "null"]));
        assert_eq!(
            aliases_beyond(&Value::Text("a".to_owned()), true).map(|aliases| aliases.len()),
            Some(9)
        );
    }

    #[test]
    fn a_key_read_as_json_sorts_by_the_type_it_names() {
        let json = |text: &str| Value::Json(JsonText::parse(text.to_owned()).unwrap());

        assert_eq!(
            aliases_beyond(&json(r#"{"$oid": "5f1d7a0c9b1e8b2a3c4d5e6f"}"#), false),
            aliases_beyond(&object_id(), false)
        );
        assert_eq!(
            aliases_beyond(&json(r#"{"$numberLong": "7"}"#), true),
            aliases_beyond(&Value::Int(7), true)
        );
        assert_eq!(
            aliases_beyond(&json(r#"{"a": 1}"#), true),
            Some(vec![
                "array",
                "binData",
                "objectId",
                "bool",
                "date",
                "timestamp",
                "regex",
                "maxKey"
            ])
        );
        assert_eq!(aliases_beyond(&json(r#"{"$code": "x"}"#), true), None);
        assert_eq!(aliases_beyond(&Value::Array(Vec::new()), true), None);
    }
}
