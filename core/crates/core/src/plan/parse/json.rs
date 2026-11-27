use std::collections::BTreeMap;

use serde_json::Value;

/// A JSON object. `BTreeMap`, not `serde_json::Map`, which the core disallows for
/// its key order; a plan's property order does not matter.
pub(super) type Object = BTreeMap<String, Value>;

/// Read a JSON object from a value, or None when it is not an object.
pub(super) fn object(value: &Value) -> Option<Object> {
    serde_json::from_value(value.clone()).ok()
}

pub(super) fn str_field(dict: &Object, key: &str) -> Option<String> {
    dict.get(key).and_then(Value::as_str).map(str::to_string)
}

/// A number, or a number written as a string (MySQL quotes some costs).
pub(super) fn loose_f64(value: &Value) -> Option<f64> {
    match value {
        Value::Number(number) => number.as_f64(),
        Value::String(text) => text.parse().ok(),
        _ => None,
    }
}

pub(super) fn value_to_string(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        Value::Null => "null".to_string(),
        other => other.to_string(),
    }
}
