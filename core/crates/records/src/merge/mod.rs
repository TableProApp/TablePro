// The field-map three-way merge both providers share (0051, Conflict rules). The client merges; the server only
// versions.

use std::collections::BTreeSet;

use serde_json::Value;

use crate::kind::Kind;
use crate::move_marker::MoveMarker;
use crate::schema::{Role, Schema, Type, schema};
use crate::settings::{self, Merge};

mod document;

pub use document::merge_document;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    // A field changed on both sides takes the pushing device's value, as `SyncRecordEdit` does.
    Personal,
    // A field both sides changed to different values opens Keep Mine, Keep Theirs or Decide Later (0044).
    Team,
}

// One record's three copies: what this device last took from the provider, what it holds now and what the provider
// holds now. `None` is a deletion, or no record yet.
#[derive(Debug, Clone, Copy)]
pub struct Sides<'a> {
    pub base: Option<&'a Value>,
    pub local: Option<&'a Value>,
    pub server: Option<&'a Value>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Merged {
    Record(Value),
    Deleted,
    // Team only: the agreed fields, with the server's value in each contested one.
    Contested { record: Value, fields: Vec<String> },
    // Team only: a content edit met a deletion. Keep Mine revives the record, Keep Theirs lets the deletion stand.
    DeletionContested { kept: Value, deleted_here: bool },
    // An envelope this device changed: ciphertext does not merge, so the device seals its secret again under the
    // newest key version and pushes it on the stored tag, and the later pusher wins (0051, Conflict rules).
    Reseal,
}

pub fn merge(kind: Kind, mode: Mode, sides: Sides<'_>) -> Merged {
    if kind == Kind::SecretEnvelope {
        return whole(sides);
    }
    if kind.is_create_once() {
        return created_once(kind, sides);
    }
    let schema = schema(kind);
    match (sides.base, sides.local, sides.server) {
        (_, None, None) => Merged::Deleted,
        (None, Some(local), None) => Merged::Record(local.clone()),
        (None, None, Some(server)) => Merged::Record(server.clone()),
        (base, Some(local), Some(server)) => fields(&schema, mode, base, local, server),
        (Some(base), None, Some(server)) => against_deletion(&schema, mode, base, server, true),
        (Some(base), Some(local), None) => against_deletion(&schema, mode, base, local, false),
    }
}

// The first meet after a move from iCloud whose service copy carries a move marker (0054, Moving between providers):
// the base is the copy the marker names, known only by its members' digests, so a member counts as changed on a side
// when its digest differs. A settings document merges whole here, not option by option. Kinds iCloud never carries
// merge with no base.
pub fn merge_against_marker(
    kind: Kind,
    mode: Mode,
    marker: &MoveMarker,
    local: Option<&Value>,
    server: Option<&Value>,
) -> Merged {
    if kind == Kind::SecretEnvelope || kind.is_create_once() {
        return merge(
            kind,
            mode,
            Sides {
                base: None,
                local,
                server,
            },
        );
    }
    let schema = schema(kind);
    match (local, server) {
        (None, None) => Merged::Deleted,
        (Some(local), None) => against_marked_deletion(&schema, mode, marker, local, false),
        (None, Some(server)) => against_marked_deletion(&schema, mode, marker, server, true),
        (Some(local), Some(server)) => {
            let mut merged = serde_json::Map::new();
            let mut contested = Vec::new();
            let mut names = keys(None, Some(local), Some(server));
            names.extend(marker.members().cloned());
            for key in names {
                let (mine, theirs) = (local.get(&key), server.get(&key));
                let value = if mine == theirs || marker.holds(&key, mine) {
                    theirs.cloned()
                } else if marker.holds(&key, theirs) {
                    mine.cloned()
                } else if mode == Mode::Team {
                    contested.push(key.clone());
                    theirs.cloned()
                } else {
                    mine.cloned()
                };
                if let Some(value) = value {
                    merged.insert(key, value);
                }
            }
            let record = Value::Object(merged);
            if contested.is_empty() {
                Merged::Record(record)
            } else {
                Merged::Contested {
                    record,
                    fields: contested,
                }
            }
        }
    }
}

// As `against_deletion`, with the marked copy as the base.
fn against_marked_deletion(
    schema: &Schema,
    mode: Mode,
    marker: &MoveMarker,
    edited: &Value,
    deleted_here: bool,
) -> Merged {
    let mut names = keys(None, Some(edited), None);
    names.extend(marker.members().cloned());
    let content = names
        .iter()
        .any(|key| schema.role(key) == Role::Content && !marker.holds(key, edited.get(key)));
    if !content {
        return Merged::Deleted;
    }
    match mode {
        Mode::Personal => Merged::Record(edited.clone()),
        Mode::Team => Merged::DeletionContested {
            kept: edited.clone(),
            deleted_here,
        },
    }
}

fn whole(sides: Sides<'_>) -> Merged {
    match (sides.base, sides.local, sides.server) {
        (None, None, Some(server)) => Merged::Record(server.clone()),
        (_, None, _) => Merged::Deleted,
        (base, Some(local), server) if base == Some(local) => {
            server.map_or(Merged::Deleted, |server| Merged::Record(server.clone()))
        }
        (_, Some(_), _) => Merged::Reseal,
    }
}

// History entries and key objects are never patched: the stored copy stands, and one the provider no longer holds
// after this device took it was deleted (a `user` tombstone of a history entry is final). A device deletes a history
// entry it took; it never deletes a key object.
fn created_once(kind: Kind, sides: Sides<'_>) -> Merged {
    match (sides.base, sides.local, sides.server) {
        (Some(_), None, Some(_)) if kind == Kind::HistoryEntry => Merged::Deleted,
        (_, _, Some(server)) => Merged::Record(server.clone()),
        (None, Some(local), None) => Merged::Record(local.clone()),
        _ => Merged::Deleted,
    }
}

// A content edit revives the record with that edit. A placement-only edit never does, and the deletion stands.
fn against_deletion(schema: &Schema, mode: Mode, base: &Value, edited: &Value, deleted_here: bool) -> Merged {
    if !changes_content(schema, base, edited) {
        return Merged::Deleted;
    }
    match mode {
        Mode::Personal => Merged::Record(edited.clone()),
        Mode::Team => Merged::DeletionContested {
            kept: edited.clone(),
            deleted_here,
        },
    }
}

// Whether `edited` differs from `base` in a member the schema does not mark as placement.
pub fn changes_content(schema: &Schema, base: &Value, edited: &Value) -> bool {
    keys(Some(base), Some(edited), None)
        .into_iter()
        .any(|key| schema.role(&key) == Role::Content && base.get(&key) != edited.get(&key))
}

fn fields(schema: &Schema, mode: Mode, base: Option<&Value>, local: &Value, server: &Value) -> Merged {
    let mut merged = serde_json::Map::new();
    let mut contested = Vec::new();
    for key in keys(base, Some(local), Some(server)) {
        let held = base.and_then(|base| base.get(&key));
        let (mine, theirs) = (local.get(&key), server.get(&key));
        let value = if mine == held || mine == theirs {
            theirs.cloned()
        } else if theirs == held {
            mine.cloned()
        } else if by_option(schema, &key, [Some(local), Some(server), base]) {
            Some(merge_document(held, mine, theirs))
        } else if mode == Mode::Team {
            contested.push(key.clone());
            theirs.cloned()
        } else {
            mine.cloned()
        };
        if let Some(value) = value {
            merged.insert(key, value);
        }
    }
    let record = Value::Object(merged);
    if contested.is_empty() {
        Merged::Record(record)
    } else {
        Merged::Contested {
            record,
            fields: contested,
        }
    }
}

// A settings record's options merge one by one unless its category goes whole; a category this build does not know
// merges by option, as the Mac does.
fn by_option(schema: &Schema, key: &str, copies: [Option<&Value>; 3]) -> bool {
    if schema.field(key).map(|field| field.ty) != Some(Type::Options) {
        return false;
    }
    let Some(category) = copies
        .into_iter()
        .flatten()
        .find_map(|copy| copy.get("category").and_then(Value::as_str))
    else {
        return false;
    };
    settings::registry(schema.kind)
        .and_then(|registry| registry.category(category))
        .is_none_or(|known| known.merge == Merge::ByOption)
}

fn keys(base: Option<&Value>, local: Option<&Value>, server: Option<&Value>) -> BTreeSet<String> {
    [base, local, server]
        .into_iter()
        .flatten()
        .filter_map(|copy| match copy {
            Value::Object(members) => Some(members.keys().cloned()),
            _ => None,
        })
        .flatten()
        .collect()
}

#[cfg(test)]
mod tests;
