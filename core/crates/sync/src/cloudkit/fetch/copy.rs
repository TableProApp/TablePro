// What the zone says about one record, read through the core's projection (0054, Field values). A name not in its
// type's form stays unapplied (0052, Every id), and a type iCloud no longer writes is left to the zone.

use serde_json::Value;
use tablepro_records::Kind;
use tablepro_records::cloudkit::{
    CloudFields, CloudValue, RecordType, parse_record_name, record_name, record_type_named, to_wire,
};
use tablepro_records::record_id;

use super::SCOPE;
use crate::api::cloudkit::{CloudKitDeletion, CloudKitRecord, CloudKitValue};
use crate::api::ids::RecordKey;

#[derive(Debug, Clone, PartialEq)]
pub(in crate::cloudkit) enum Incoming {
    Changed(Copy),
    Deleted(RecordKey),
    // Listed by the zone, but not read: its fetch failed, or this build cannot project the copy.
    Unread { key: RecordKey, tag: Option<Vec<u8>> },
}

impl Incoming {
    pub(super) const fn key(&self) -> &RecordKey {
        match self {
            Self::Changed(copy) => &copy.key,
            Self::Deleted(key) | Self::Unread { key, .. } => key,
        }
    }

    pub(super) const fn listed(&self) -> bool {
        !matches!(self, Self::Deleted(_))
    }
}

// The server's copy as wire fields, with the system fields that guard the next save on it.
#[derive(Debug, Clone, PartialEq)]
pub(in crate::cloudkit) struct Copy {
    pub key: RecordKey,
    pub kind: Kind,
    pub tag: Vec<u8>,
    pub fields: Value,
    // `CKRecord.creationDate`, which the base keeps to tell a record made again after a zone removal.
    pub created_ms: Option<i64>,
}

fn key_in(record_type: &RecordType, name: &str) -> Option<RecordKey> {
    let id = name.strip_prefix(record_type.prefix)?;
    record_id::check(record_type.kind, id).ok()?;
    Some(RecordKey::new(SCOPE, record_type.kind, id))
}

pub(in crate::cloudkit) fn key_of_name(name: &str) -> Option<RecordKey> {
    let (record_type, _) = parse_record_name(name)?;
    key_in(record_type, name)
}

pub(super) fn name_of(key: &RecordKey) -> Option<String> {
    record_name(key.kind.known()?, &key.record_id)
}

pub(super) fn kind_of(key: &RecordKey) -> Option<Kind> {
    key.kind.known()
}

fn cloud_value(value: &CloudKitValue) -> CloudValue {
    match value {
        CloudKitValue::Text(text) => CloudValue::Text(text.clone()),
        CloudKitValue::Int64(number) => CloudValue::Int64(*number),
        CloudKitValue::Double(number) => CloudValue::Double(*number),
        CloudKitValue::Timestamp(millis) => CloudValue::Timestamp(*millis),
        CloudKitValue::Bytes(bytes) => CloudValue::Bytes(bytes.clone()),
        CloudKitValue::TextList(items) => CloudValue::TextList(items.clone()),
    }
}

pub(in crate::cloudkit) fn changed(record: &CloudKitRecord) -> Option<Incoming> {
    let record_type = record_type_named(&record.record_type)?;
    let key = key_in(record_type, &record.name)?;
    let Some(tag) = record.system_fields.clone() else {
        return Some(Incoming::Unread { key, tag: None });
    };
    let fields: CloudFields = record
        .fields
        .iter()
        .filter_map(|field| Some((field.name.clone(), cloud_value(field.value.as_ref()?))))
        .collect();
    Some(match to_wire(record_type.name, &record.name, &fields) {
        Ok(wire) => Incoming::Changed(Copy {
            key,
            kind: record_type.kind,
            tag,
            fields: wire.fields,
            created_ms: record.created_ms,
        }),
        Err(_) => Incoming::Unread { key, tag: Some(tag) },
    })
}

pub(super) fn deleted(deletion: &CloudKitDeletion) -> Option<Incoming> {
    let record_type = record_type_named(&deletion.record_type)?;
    key_in(record_type, &deletion.name).map(Incoming::Deleted)
}
