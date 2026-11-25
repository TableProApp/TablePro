// The CloudKit projection (0054, The CloudKit transport): a record's CloudKit fields to its wire fields and back.
// Field values cross as CloudKit's own types; a JSON field holds the Mac's JSON, whose member names are the wire
// schema's in camel case.

use std::collections::BTreeMap;

use serde_json::Value;

use super::registry::{Carries, CloudField, CloudType, RECORD_TYPES, RecordType, record_type_named, record_type_of};
use crate::kind::Kind;
use crate::record_id::{self, IdError};
use crate::schema::{self, Type};
use crate::settings;

// As the Mac's mapper stamps every record.
pub const SCHEMA_VERSION: i64 = 1;

#[derive(Debug, Clone, PartialEq)]
pub enum CloudValue {
    Text(String),
    Int64(i64),
    Double(f64),
    // Milliseconds since the Unix epoch, the precision a CloudKit date keeps.
    Timestamp(i64),
    Bytes(Vec<u8>),
    TextList(Vec<String>),
}

// A record's fields by name; a save names each field it sets, and `None` clears one.
pub type CloudFields = BTreeMap<String, CloudValue>;

#[derive(Debug, Clone, PartialEq)]
pub struct WireRecord {
    pub kind: Kind,
    pub record_id: String,
    pub fields: Value,
}

#[derive(Debug, Clone, PartialEq, thiserror::Error)]
pub enum ProjectionError {
    #[error("no synced record type is named {name}")]
    UnknownType { name: String },
    #[error("the record name does not start with its type's prefix")]
    Name,
    #[error(transparent)]
    Id(#[from] IdError),
    #[error("the field {field} does not hold what its type declares")]
    Field { field: &'static str },
}

impl ProjectionError {
    pub const fn code(&self) -> &'static str {
        match self {
            Self::UnknownType { .. } => "records.unknown_record_type",
            Self::Name => "records.bad_record_name",
            Self::Id(error) => error.code(),
            Self::Field { .. } => "records.bad_field",
        }
    }
}

// `SyncRecordType.parse(recordName:)`: the longest prefix wins, since one prefix can start another.
pub fn parse_record_name(name: &str) -> Option<(&'static RecordType, &str)> {
    let mut types: Vec<&'static RecordType> = RECORD_TYPES.iter().collect();
    types.sort_by_key(|record_type| std::cmp::Reverse(record_type.prefix.len()));
    types
        .into_iter()
        .find_map(|record_type| name.strip_prefix(record_type.prefix).map(|id| (record_type, id)))
}

// `SyncRecordType.recordName(for:)`. `None` for a kind iCloud does not carry.
pub fn record_name(kind: Kind, id: &str) -> Option<String> {
    let record_type = record_type_of(kind)?;
    Some(format!(
        "{}{}",
        record_type.prefix,
        record_id::shortened(kind, id.to_owned())
    ))
}

pub fn to_wire(record_type: &str, name: &str, fields: &CloudFields) -> Result<WireRecord, ProjectionError> {
    let record_type = record_type_named(record_type).ok_or_else(|| ProjectionError::UnknownType {
        name: record_type.to_owned(),
    })?;
    let id = name.strip_prefix(record_type.prefix).ok_or(ProjectionError::Name)?;
    record_id::check(record_type.kind, id)?;
    let schema = schema::schema(record_type.kind);
    let mut wire = serde_json::Map::new();
    for field in record_type.fields {
        let Carries::Wire(key) = field.carries else {
            continue;
        };
        let (Some(value), Some(declared)) = (fields.get(field.name), schema.field(key)) else {
            continue;
        };
        match read(field, &declared.ty, value) {
            Some(converted) => {
                wire.insert(key.to_owned(), converted);
            }
            // The Mac reads a route it cannot decode as none, and keeps the rest of the connection.
            None if field.name == "sshRouteJson" => {}
            None => return Err(ProjectionError::Field { field: field.name }),
        }
    }
    read_legacy(record_type.kind, fields, &mut wire);
    if record_type.kind == Kind::MacosSettings {
        settings_entries(&mut wire, Direction::ToWire);
    }
    Ok(WireRecord {
        kind: record_type.kind,
        record_id: id.to_owned(),
        fields: Value::Object(wire),
    })
}

// The fields a save sets: every field Production holds for the type, with `None` clearing one the wire record lacks.
// A field this build does not know is left to the copy CloudKit holds. `None` for a type Production does not hold.
pub fn from_wire(
    kind: Kind,
    id: &str,
    fields: &Value,
    now_ms: i64,
) -> Result<Option<BTreeMap<&'static str, Option<CloudValue>>>, ProjectionError> {
    let Some(record_type) = record_type_of(kind).filter(|record_type| record_type.deployed) else {
        return Ok(None);
    };
    let schema = schema::schema(kind);
    let mut fields = fields.clone();
    if kind == Kind::MacosSettings {
        settings_entries_value(&mut fields, Direction::ToCloud);
    }
    let mut saved = BTreeMap::new();
    for field in record_type.fields.iter().filter(|field| record_type.writes(field)) {
        let value = match field.carries {
            Carries::Own => Some(CloudValue::Text(id.to_owned())),
            Carries::Wire("schema_version") => Some(CloudValue::Int64(SCHEMA_VERSION)),
            Carries::Wire(key) => match (fields.get(key), schema.field(key)) {
                (Some(value), Some(declared)) => {
                    Some(write(field, &declared.ty, value).ok_or(ProjectionError::Field { field: field.name })?)
                }
                _ => None,
            },
            Carries::Stamp => Some(CloudValue::Timestamp(now_ms)),
            Carries::IsReadOnly => Some(CloudValue::Int64(i64::from(
                fields.get("safe_mode_level").and_then(Value::as_str) == Some("readOnly"),
            ))),
            Carries::ColorTag => fields
                .get("color")
                .and_then(Value::as_str)
                .map(|color| CloudValue::Text(color.to_owned())),
            Carries::TagId => fields
                .get("tag_ids")
                .and_then(|ids| ids.get(0))
                .and_then(Value::as_str)
                .map(|id| CloudValue::Text(id.to_owned())),
            Carries::Retired => continue,
        };
        saved.insert(field.name, value);
    }
    Ok(Some(saved))
}

fn read(field: &CloudField, ty: &Type, value: &CloudValue) -> Option<Value> {
    match (field.ty, value) {
        (CloudType::String, CloudValue::Text(text)) => Some(Value::from(text.as_str())),
        (CloudType::Int64, CloudValue::Int64(number)) if *ty == Type::Boolean => Some(Value::Bool(*number != 0)),
        (CloudType::Int64, CloudValue::Int64(number)) => Some(Value::from(*number)),
        (CloudType::Timestamp, CloudValue::Timestamp(millis)) => Some(Value::from(*millis)),
        (CloudType::StringList, CloudValue::TextList(items)) => Some(Value::Array(
            items.iter().map(|item| Value::from(item.as_str())).collect(),
        )),
        (CloudType::Bytes, CloudValue::Bytes(bytes)) => {
            let document: Value = serde_json::from_slice(bytes).ok()?;
            Some(from_mac_json(ty, document))
        }
        _ => None,
    }
}

fn write(field: &CloudField, ty: &Type, value: &Value) -> Option<CloudValue> {
    match field.ty {
        CloudType::String => value.as_str().map(|text| CloudValue::Text(text.to_owned())),
        CloudType::Int64 => match value {
            Value::Bool(flag) => Some(CloudValue::Int64(i64::from(*flag))),
            other => other.as_i64().map(CloudValue::Int64),
        },
        CloudType::Timestamp => value.as_i64().map(CloudValue::Timestamp),
        CloudType::StringList => value
            .as_array()
            .map(|items| CloudValue::TextList(items.iter().filter_map(Value::as_str).map(str::to_owned).collect())),
        CloudType::Bytes => Some(CloudValue::Bytes(mac_json_bytes(&to_mac_json(ty, value)))),
    }
}

// The legacy fields older builds wrote, read where the current one is missing, as the Mac reads them.
fn read_legacy(kind: Kind, fields: &CloudFields, wire: &mut serde_json::Map<String, Value>) {
    if kind != Kind::Connection {
        return;
    }
    if !wire.contains_key("color")
        && let Some(CloudValue::Text(tag)) = fields.get("colorTag")
    {
        wire.insert("color".to_owned(), Value::from(stored_color(tag)));
    }
    if !wire.contains_key("safe_mode_level")
        && let Some(CloudValue::Int64(1)) = fields.get("isReadOnly")
    {
        wire.insert("safe_mode_level".to_owned(), Value::from("readOnly"));
    }
    let no_tags = wire.get("tag_ids").and_then(Value::as_array).is_none_or(Vec::is_empty);
    if no_tags && let Some(CloudValue::Text(tag)) = fields.get("tagId") {
        wire.insert("tag_ids".to_owned(), Value::Array(vec![Value::from(tag.as_str())]));
    }
}

// `ConnectionColor(storedValue:)`: a name in any case, else a hex older iOS builds wrote, else none.
fn stored_color(raw: &str) -> &'static str {
    if let Some(name) = schema::COLORS.iter().find(|name| name.eq_ignore_ascii_case(raw)) {
        return name;
    }
    let hex = raw.trim_matches(|c: char| c == '#' || c == ' ').to_lowercase();
    match hex.as_str() {
        "ff0000" | "ff3b30" | "cc0000" => "Red",
        "ff9500" | "ff8c00" | "ffa500" => "Orange",
        "ffcc00" | "ffff00" | "ffd700" => "Yellow",
        "34c759" | "28cd41" | "00ff00" | "008000" => "Green",
        "007aff" | "0000ff" | "5856d6" => "Blue",
        "af52de" | "800080" | "9b59b6" => "Purple",
        "ff2d55" | "ff69b4" | "ffc0cb" => "Pink",
        _ => "None",
    }
}

// Members TablePro Sync carries inside a JSON field that the Mac's type does not know. Written to CloudKit, a Mac
// would drop them on its next save and both would keep rewriting the field.
const SERVICE_ONLY: &[&str] = &["passphrase_stored", "server_name"];

fn from_mac_json(ty: &Type, value: Value) -> Value {
    match (ty, value) {
        (Type::Object(fields), Value::Object(members)) => Value::Object(
            members
                .into_iter()
                .map(
                    |(key, member)| match fields.iter().find(|field| camel(field.key) == key) {
                        Some(field) => (field.key.to_owned(), from_mac_json(&field.ty, member)),
                        None => (key, member),
                    },
                )
                .collect(),
        ),
        (Type::List(inner), Value::Array(items)) => {
            Value::Array(items.into_iter().map(|item| from_mac_json(inner, item)).collect())
        }
        (Type::Entries(_), Value::Object(members)) => entries(members),
        (_, other) => other,
    }
}

fn to_mac_json(ty: &Type, value: &Value) -> Value {
    match (ty, value) {
        (Type::Object(fields), Value::Object(members)) => Value::Object(
            members
                .iter()
                .filter(|(key, _)| !SERVICE_ONLY.contains(&key.as_str()))
                .map(|(key, member)| match fields.iter().find(|field| field.key == key) {
                    Some(field) => (camel(field.key), to_mac_json(&field.ty, member)),
                    None => (key.clone(), member.clone()),
                })
                .collect(),
        ),
        (Type::List(inner), Value::Array(items)) => {
            Value::Array(items.iter().map(|item| to_mac_json(inner, item)).collect())
        }
        (Type::Entries(_), Value::Array(items)) => map(items),
        (_, other) => other.clone(),
    }
}

// A map keyed by data as `{"id", "value"}` entries, in id order.
fn entries(members: serde_json::Map<String, Value>) -> Value {
    Value::Array(
        members
            .into_iter()
            .map(|(id, value)| {
                let mut entry = serde_json::Map::new();
                entry.insert("id".to_owned(), Value::String(id));
                entry.insert("value".to_owned(), value);
                Value::Object(entry)
            })
            .collect(),
    )
}

fn map(items: &[Value]) -> Value {
    Value::Object(
        items
            .iter()
            .filter_map(|item| Some((item.get("id")?.as_str()?.to_owned(), item.get("value")?.clone())))
            .collect(),
    )
}

#[derive(Clone, Copy)]
enum Direction {
    ToWire,
    ToCloud,
}

// A settings document's maps keyed by data, such as column widths by column, go as entries on the wire.
fn settings_entries(wire: &mut serde_json::Map<String, Value>, direction: Direction) {
    let category = wire.get("category").and_then(Value::as_str).map(str::to_owned);
    let Some(options) = wire.get_mut("options") else {
        return;
    };
    let Some(known) = category
        .as_deref()
        .and_then(|category| settings::registry(Kind::MacosSettings)?.category(category))
    else {
        return;
    };
    let Value::Object(members) = options else {
        return;
    };
    for option in known
        .document
        .options()
        .iter()
        .filter(|option| matches!(option.ty, Type::Entries(_)))
    {
        let converted = match (direction, members.get(option.key)) {
            (Direction::ToWire, Some(Value::Object(map))) => entries(map.clone()),
            (Direction::ToCloud, Some(Value::Array(items))) => map(items),
            _ => continue,
        };
        members.insert(option.key.to_owned(), converted);
    }
}

fn settings_entries_value(fields: &mut Value, direction: Direction) {
    if let Value::Object(members) = fields {
        settings_entries(members, direction);
    }
}

// `JSONEncoder` with `.sortedKeys`, as the Mac's mapper writes a JSON field: compact, keys in order, `/` escaped.
pub fn mac_json_bytes(value: &Value) -> Vec<u8> {
    let text = serde_json::to_string(value).unwrap_or_default();
    text.replace('/', "\\/").into_bytes()
}

pub(super) fn camel(key: &str) -> String {
    let mut out = String::with_capacity(key.len());
    let mut upper = false;
    for c in key.chars() {
        if c == '_' {
            upper = true;
        } else if upper {
            out.extend(c.to_uppercase());
            upper = false;
        } else {
            out.push(c);
        }
    }
    out
}
