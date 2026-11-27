// The move marker (0054, Moving between providers): the first device that moves a record from iCloud to TablePro Sync
// writes it into the record as an inert reserved member the server never reads (0051, Move markers). It names the
// CloudKit copy the record moved from by a digest of that copy's archived system fields and of each member's JSON, so
// a later mover merges against that copy and tells a deletion made on iCloud after the move from a record that never
// was on iCloud. A pull takes it out of the record, so no store, base or patch ever holds it.

use std::collections::BTreeMap;

use serde_json::{Map, Value};
use sha2::{Digest, Sha256};

pub const MEMBER: &str = "moved_from_icloud";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MoveMarker {
    // Hex SHA-256 of the copy's archived system fields.
    pub tag: String,
    // Hex SHA-256 of each top-level member's JSON text, as `serde_json` writes it with members in key order.
    pub fields: BTreeMap<String, String>,
}

fn digest(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

fn member_digest(value: &Value) -> String {
    digest(value.to_string().as_bytes())
}

impl MoveMarker {
    // The CloudKit copy as a device's base holds it: its wire members and its archived system fields.
    pub fn of(fields: &Value, system_fields: &[u8]) -> Self {
        let members = match fields {
            Value::Object(members) => members
                .iter()
                .map(|(name, value)| (name.clone(), member_digest(value)))
                .collect(),
            _ => BTreeMap::new(),
        };
        Self {
            tag: digest(system_fields),
            fields: members,
        }
    }

    pub fn to_value(&self) -> Value {
        let fields: Map<String, Value> = self
            .fields
            .iter()
            .map(|(name, digest)| (name.clone(), Value::String(digest.clone())))
            .collect();
        serde_json::json!({"tag": self.tag, "fields": fields})
    }

    // A member of another shape reads as no marker.
    pub fn parse(value: &Value) -> Option<Self> {
        let tag = value.get("tag")?.as_str()?.to_owned();
        let Value::Object(members) = value.get("fields")? else {
            return None;
        };
        let fields = members
            .iter()
            .map(|(name, digest)| Some((name.clone(), digest.as_str()?.to_owned())))
            .collect::<Option<BTreeMap<_, _>>>()?;
        Some(Self { tag, fields })
    }

    // Whether `value` is the marked copy's value of `member`. A member the copy lacked matches only its absence.
    pub fn holds(&self, member: &str, value: Option<&Value>) -> bool {
        match (self.fields.get(member), value) {
            (Some(held), Some(value)) => *held == member_digest(value),
            (None, None) => true,
            _ => false,
        }
    }

    pub fn members(&self) -> impl Iterator<Item = &String> {
        self.fields.keys()
    }
}

// Takes the marker out of a pulled record's fields. A member that does not parse goes too, and reads as no marker.
pub fn strip(fields: &mut Value) -> Option<MoveMarker> {
    let Value::Object(members) = fields else {
        return None;
    };
    members.remove(MEMBER).and_then(|marker| MoveMarker::parse(&marker))
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn a_marker_reads_back_and_holds_each_member_of_the_copy_it_names() {
        let copy = json!({"name": "Prod", "sort_order": 1, "ssh_config": {"host": "h", "port": 22}});
        let marker = MoveMarker::of(&copy, b"system fields");

        let read = MoveMarker::parse(&marker.to_value()).unwrap();

        assert_eq!(read, marker);
        assert!(marker.holds("name", Some(&json!("Prod"))));
        assert!(marker.holds("ssh_config", Some(&json!({"port": 22, "host": "h"}))));
        assert!(!marker.holds("name", Some(&json!("Prod 2"))));
        assert!(!marker.holds("name", None));
        assert!(marker.holds("icon_name", None));
        assert!(!marker.holds("icon_name", Some(&json!("database"))));
        assert_eq!(marker.tag, hex::encode(Sha256::digest(b"system fields")));
    }

    #[test]
    fn a_pull_strips_the_marker_and_one_of_another_shape_reads_as_none() {
        let marker = MoveMarker::of(&json!({"name": "Prod"}), b"tag");
        let mut marked = json!({"name": "Prod", "moved_from_icloud": marker.to_value()});
        let mut malformed = json!({"name": "Prod", "moved_from_icloud": "not a marker"});

        assert_eq!(strip(&mut marked), Some(marker));
        assert_eq!(marked, json!({"name": "Prod"}));
        assert_eq!(strip(&mut malformed), None);
        assert_eq!(malformed, json!({"name": "Prod"}));
    }
}
