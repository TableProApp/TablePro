// Reading and writing wire members as the Mac's mapper does: a value of another shape reads as missing, as a Swift
// cast to the field's type fails.

use serde_json::{Map, Value};
use tablepro_records::record_id::uuid_id;
use uuid::Uuid;

pub(super) fn text<'a>(fields: &'a Value, key: &str) -> Option<&'a str> {
    fields.get(key).and_then(Value::as_str)
}

pub(super) fn integer(fields: &Value, key: &str) -> Option<i64> {
    fields.get(key).and_then(Value::as_i64)
}

pub(super) fn boolean(fields: &Value, key: &str) -> Option<bool> {
    fields.get(key).and_then(Value::as_bool)
}

// As Swift's `UUID(uuidString:)` reads one: hyphenated, in either case.
pub(super) fn uuid(raw: Option<&str>) -> Option<Uuid> {
    raw.filter(|raw| raw.len() == 36)
        .and_then(|raw| Uuid::try_parse(raw).ok())
}

pub(super) fn uuid_at(fields: &Value, key: &str) -> Option<Uuid> {
    uuid(text(fields, key))
}

pub(super) fn uuid_value(id: Uuid) -> Value {
    Value::String(uuid_id(id))
}

// A Mac `Int` stored in a narrower field: out of range reads as the nearest bound.
pub(super) fn clamped<T: TryFrom<i64> + Bounded>(raw: i64) -> T {
    T::try_from(raw).unwrap_or(if raw < 0 { T::MIN } else { T::MAX })
}

pub(super) trait Bounded {
    const MIN: Self;
    const MAX: Self;
}

impl Bounded for u16 {
    const MIN: Self = u16::MIN;
    const MAX: Self = u16::MAX;
}

impl Bounded for u32 {
    const MIN: Self = u32::MIN;
    const MAX: Self = u32::MAX;
}

// A JSON object built member by member in the order written.
#[derive(Default)]
pub(super) struct Object(Map<String, Value>);

impl Object {
    pub(super) fn put(&mut self, key: &str, value: impl Into<Value>) -> &mut Self {
        self.0.insert(key.to_owned(), value.into());
        self
    }

    pub(super) fn put_some(&mut self, key: &str, value: Option<impl Into<Value>>) -> &mut Self {
        if let Some(value) = value {
            self.0.insert(key.to_owned(), value.into());
        }
        self
    }

    // A member the object already names keeps its value.
    pub(super) fn keep(&mut self, key: &str, value: Value) -> &mut Self {
        self.0.entry(key.to_owned()).or_insert(value);
        self
    }

    pub(super) fn done(&mut self) -> Value {
        Value::Object(std::mem::take(&mut self.0))
    }
}

// The members of `fields` no key in `known` names, as a store keeps the keys a newer build wrote.
pub(super) fn unknown_members(fields: &Value, known: &[&str]) -> std::collections::BTreeMap<String, Value> {
    match fields {
        Value::Object(members) => members
            .iter()
            .filter(|(key, _)| !known.contains(&key.as_str()))
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect(),
        _ => std::collections::BTreeMap::new(),
    }
}
