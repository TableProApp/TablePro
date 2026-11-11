use std::fmt;

use serde::de::{self, Deserialize, Deserializer, MapAccess, SeqAccess, Visitor};

// A serde_json map sorts its keys, and a client's entry has to keep the
// catalog's order, so objects are kept as a list of members.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum JsonValue {
    Null,
    Bool(bool),
    Number(serde_json::Number),
    String(String),
    Array(Vec<JsonValue>),
    Object(Vec<(String, JsonValue)>),
}

impl JsonValue {
    pub fn get(&self, key: &str) -> Option<&JsonValue> {
        match self {
            Self::Object(members) => members.iter().find(|(name, _)| name == key).map(|(_, value)| value),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Self::String(text) => Some(text),
            _ => None,
        }
    }

    // Whether every member `wanted` has is here with the same value, as
    // an update that keeps the user's own members leaves an entry. Below
    // the top, as in a header map, a key matches ignoring case.
    pub fn holds(&self, wanted: &JsonValue) -> bool {
        holds(self, wanted, false)
    }

    pub fn to_compact(&self) -> String {
        let mut out = String::new();
        write_compact(self, &mut out);
        out
    }

    // `base` is the indent of the line the value starts on; nested lines
    // add one `unit` per level.
    pub fn to_pretty(&self, unit: &str, base: &str) -> String {
        let mut out = String::new();
        write_pretty(self, unit, base, &mut out);
        out
    }
}

fn holds(actual: &JsonValue, wanted: &JsonValue, nested: bool) -> bool {
    let (JsonValue::Object(have), JsonValue::Object(want)) = (actual, wanted) else {
        return actual == wanted;
    };
    want.iter().all(|(key, value)| {
        have.iter()
            .find(|(name, _)| name == key)
            .or_else(|| have.iter().find(|(name, _)| nested && name.eq_ignore_ascii_case(key)))
            .is_some_and(|(_, found)| holds(found, value, true))
    })
}

fn write_compact(value: &JsonValue, out: &mut String) {
    match value {
        JsonValue::Array(items) => {
            out.push('[');
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_compact(item, out);
            }
            out.push(']');
        }
        JsonValue::Object(members) => {
            out.push('{');
            for (index, (name, member)) in members.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                out.push_str(&quote(name));
                out.push(':');
                write_compact(member, out);
            }
            out.push('}');
        }
        scalar => write_scalar(scalar, out),
    }
}

fn write_pretty(value: &JsonValue, unit: &str, base: &str, out: &mut String) {
    let inner = format!("{base}{unit}");
    match value {
        JsonValue::Array(items) if !items.is_empty() => {
            out.push('[');
            for (index, item) in items.iter().enumerate() {
                out.push_str(if index > 0 { ",\n" } else { "\n" });
                out.push_str(&inner);
                write_pretty(item, unit, &inner, out);
            }
            out.push('\n');
            out.push_str(base);
            out.push(']');
        }
        JsonValue::Object(members) if !members.is_empty() => {
            out.push('{');
            for (index, (name, member)) in members.iter().enumerate() {
                out.push_str(if index > 0 { ",\n" } else { "\n" });
                out.push_str(&inner);
                out.push_str(&quote(name));
                out.push_str(": ");
                write_pretty(member, unit, &inner, out);
            }
            out.push('\n');
            out.push_str(base);
            out.push('}');
        }
        JsonValue::Array(_) => out.push_str("[]"),
        JsonValue::Object(_) => out.push_str("{}"),
        scalar => write_scalar(scalar, out),
    }
}

fn write_scalar(value: &JsonValue, out: &mut String) {
    match value {
        JsonValue::Null => out.push_str("null"),
        JsonValue::Bool(true) => out.push_str("true"),
        JsonValue::Bool(false) => out.push_str("false"),
        JsonValue::Number(number) => out.push_str(&number.to_string()),
        JsonValue::String(text) => out.push_str(&quote(text)),
        JsonValue::Array(_) | JsonValue::Object(_) => write_compact(value, out),
    }
}

pub(crate) fn quote(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for character in text.chars() {
        match character {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            control if u32::from(control) < 0x20 => out.push_str(&format!("\\u{:04x}", u32::from(control))),
            other => out.push(other),
        }
    }
    out.push('"');
    out
}

impl<'de> Deserialize<'de> for JsonValue {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        deserializer.deserialize_any(JsonValueVisitor)
    }
}

struct JsonValueVisitor;

impl<'de> Visitor<'de> for JsonValueVisitor {
    type Value = JsonValue;

    fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("a JSON value")
    }

    fn visit_bool<E: de::Error>(self, value: bool) -> Result<JsonValue, E> {
        Ok(JsonValue::Bool(value))
    }

    fn visit_i64<E: de::Error>(self, value: i64) -> Result<JsonValue, E> {
        Ok(JsonValue::Number(value.into()))
    }

    fn visit_u64<E: de::Error>(self, value: u64) -> Result<JsonValue, E> {
        Ok(JsonValue::Number(value.into()))
    }

    fn visit_f64<E: de::Error>(self, value: f64) -> Result<JsonValue, E> {
        serde_json::Number::from_f64(value)
            .map(JsonValue::Number)
            .ok_or_else(|| E::custom("a number JSON cannot hold"))
    }

    fn visit_str<E: de::Error>(self, value: &str) -> Result<JsonValue, E> {
        Ok(JsonValue::String(value.to_owned()))
    }

    fn visit_string<E: de::Error>(self, value: String) -> Result<JsonValue, E> {
        Ok(JsonValue::String(value))
    }

    fn visit_unit<E: de::Error>(self) -> Result<JsonValue, E> {
        Ok(JsonValue::Null)
    }

    fn visit_none<E: de::Error>(self) -> Result<JsonValue, E> {
        Ok(JsonValue::Null)
    }

    fn visit_some<D: Deserializer<'de>>(self, deserializer: D) -> Result<JsonValue, D::Error> {
        JsonValue::deserialize(deserializer)
    }

    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<JsonValue, A::Error> {
        let mut items = Vec::new();
        while let Some(item) = seq.next_element()? {
            items.push(item);
        }
        Ok(JsonValue::Array(items))
    }

    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<JsonValue, A::Error> {
        let mut members: Vec<(String, JsonValue)> = Vec::new();
        while let Some((name, value)) = map.next_entry::<String, JsonValue>()? {
            if members.iter().any(|(existing, _)| *existing == name) {
                return Err(de::Error::custom(format!("duplicate key {name}")));
            }
            members.push((name, value));
        }
        Ok(JsonValue::Object(members))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(text: &str) -> JsonValue {
        serde_json::from_str(text).expect("a JSON value")
    }

    #[test]
    fn members_keep_the_order_they_were_written_in() {
        let value = parse(r#"{"zeta": 1, "alpha": [true, null], "mid": {"b": "x", "a": 2.5}}"#);

        assert_eq!(
            value.to_compact(),
            r#"{"zeta":1,"alpha":[true,null],"mid":{"b":"x","a":2.5}}"#
        );
    }

    #[test]
    fn pretty_output_indents_each_level_and_keeps_empty_containers_on_one_line() {
        let value = parse(r#"{"url": "u", "args": [], "env": {}, "tools": ["*"]}"#);

        assert_eq!(
            value.to_pretty("  ", ""),
            "{\n  \"url\": \"u\",\n  \"args\": [],\n  \"env\": {},\n  \"tools\": [\n    \"*\"\n  ]\n}"
        );
    }

    #[test]
    fn strings_are_escaped_as_json_requires() {
        assert_eq!(quote("a\"b\\c\nd\u{1}"), r#""a\"b\\c\nd\u0001""#);
    }

    #[test]
    fn an_entry_holds_what_was_written_beside_the_users_own_members() {
        let written = parse(r#"{"url": "u", "timeout": 30, "headers": {"authorization": "B", "X-Team": "d"}}"#);

        assert!(written.holds(&parse(r#"{"url": "u", "headers": {"Authorization": "B"}}"#)));
        assert!(!written.holds(&parse(r#"{"url": "v", "headers": {"Authorization": "B"}}"#)));
        assert!(
            !written.holds(&parse(r#"{"URL": "u"}"#)),
            "a key on top matches exactly"
        );
        assert!(!written.holds(&parse(r#"{"headers": {"Authorization": "C"}}"#)));
        assert!(parse("[1]").holds(&parse("[1]")) && !parse("[1, 2]").holds(&parse("[1]")));
    }

    #[test]
    fn a_duplicate_key_is_refused() {
        assert!(serde_json::from_str::<JsonValue>(r#"{"a": 1, "a": 2}"#).is_err());
    }
}
