use std::collections::{HashMap, HashSet};

use serde_json::Value;
use tablepro_records::{Kind, limits, merge_patch};

use crate::api::adapter::{LocalRecord, LocalRecords};
use crate::api::ids::{KindName, RecordKey, ScopeName};
use crate::api::state::{BaseRow, Standing};
use crate::api::transport::{Change, ChangeOp, DeletedReason};

// One change the diff found, with the base it was built on (0054, Dirty state is a diff).
#[derive(Debug, Clone, PartialEq)]
pub struct Pending {
    pub key: RecordKey,
    pub base: Option<BaseRow>,
    pub op: PendingOp,
}

#[derive(Debug, Clone, PartialEq)]
pub enum PendingOp {
    Write { fields: Value, patch: Value },
    Delete,
}

impl Pending {
    pub fn change(&self) -> Change {
        Change {
            kind: self.key.kind.clone(),
            record_id: self.key.record_id.clone(),
            base: self.base.as_ref().map(|base| base.tag.clone()),
            op: match &self.op {
                PendingOp::Write { fields, patch } => ChangeOp::Write {
                    fields: fields.clone(),
                    patch: patch.clone(),
                },
                PendingOp::Delete => ChangeOp::Delete,
            },
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Diffed {
    pub pending: Vec<Pending>,
    // Records the server's rules would refuse, kept on the device with a notice (0051, Limits).
    pub refused: Vec<(RecordKey, &'static str)>,
    // Create-once bases whose entry a local prune dropped: the base goes and nothing is pushed.
    pub pruned: Vec<RecordKey>,
}

// One kind of one scope: its store's records against its bases. `skip` holds the ids that sync by other rules for now:
// held, contested or waiting for the person.
pub fn diff(scope: ScopeName, kind: Kind, local: &LocalRecords, bases: &[BaseRow], skip: &HashSet<String>) -> Diffed {
    let key = |record_id: &str| RecordKey::new(scope, KindName::of(kind), record_id);
    let bases: HashMap<&str, &BaseRow> = bases.iter().map(|base| (base.key.record_id.as_str(), base)).collect();
    let unreadable: HashSet<&str> = local.unreadable.iter().map(String::as_str).collect();
    let tombstones: HashSet<&str> = local.tombstones.iter().map(String::as_str).collect();
    let mut diffed = Diffed::default();
    let mut present = HashSet::new();
    for record in &local.records {
        present.insert(record.record_id.as_str());
        if record.standing != Standing::Syncs || skip.contains(&record.record_id) {
            continue;
        }
        if let Err(refusal) = limits::check(&record.fields) {
            diffed.refused.push((key(&record.record_id), refusal.code()));
            continue;
        }
        let base = bases.get(record.record_id.as_str()).copied();
        if let Some(op) = written(kind, base, record) {
            diffed.pending.push(Pending {
                key: key(&record.record_id),
                base: base.cloned(),
                op,
            });
        }
    }
    for (record_id, base) in &bases {
        if present.contains(record_id) || unreadable.contains(record_id) || skip.contains(*record_id) {
            continue;
        }
        if base.deleted.is_some() {
            continue;
        }
        if kind.is_create_once() && !tombstones.contains(record_id) {
            diffed.pruned.push(key(record_id));
            continue;
        }
        diffed.pending.push(Pending {
            key: key(record_id),
            base: Some((*base).clone()),
            op: PendingOp::Delete,
        });
    }
    // A tombstone of an entry that never went up: its delete answers applied with nothing stored.
    for record_id in &local.tombstones {
        if !bases.contains_key(record_id.as_str()) && !skip.contains(record_id) {
            diffed.pending.push(Pending {
                key: key(record_id),
                base: None,
                op: PendingOp::Delete,
            });
        }
    }
    diffed
}

fn written(kind: Kind, base: Option<&BaseRow>, record: &LocalRecord) -> Option<PendingOp> {
    let whole = || PendingOp::Write {
        fields: record.fields.clone(),
        patch: record.fields.clone(),
    };
    let Some(base) = base else {
        return Some(whole());
    };
    match base.deleted {
        // A `user` tombstone of a history entry is final (0051, Conflict rules).
        Some(DeletedReason::User) if kind.is_create_once() => None,
        // A revival patches the tombstone's fields, which it carries none of.
        Some(_) => Some(whole()),
        None if kind.is_create_once() => None,
        None => {
            let held = base.fields.clone().unwrap_or(Value::Null);
            merge_patch::diff(&held, &record.fields).map(|patch| PendingOp::Write {
                fields: record.fields.clone(),
                patch,
            })
        }
    }
}
