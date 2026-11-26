use serde_json::Value;
use tablepro_records::Kind;
use tablepro_records::merge::{self, Merged, Mode, Sides};
use tablepro_records::move_marker::MoveMarker;

use crate::api::adapter::{LocalChange, LocalRecord};
use crate::api::ids::{EpochId, RecordKey, ScopeName};
use crate::api::state::{BaseRow, ConflictRow};
use crate::api::transport::{Change, ChangeOp, ChangeOutcome, DeletedReason, PulledRecord};

// How a pulled copy meets the device's: by the conflict rules, or, in a refill, the provider's copy or the device's.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Judgement {
    Merge,
    // A restored store or state file: the pull wins (0054, Store identity).
    PullWins,
    // A base the server lost in a restore and a copy not written since: the device pushes its own on the copy's tag
    // (0051, Refill).
    LocalWins,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Settled {
    pub store: Option<LocalChange>,
    pub base: Option<BaseRow>,
    pub conflict: Option<ConflictRow>,
    // The record the store should hold after the merge, whatever it holds now; None when the merge leaves the store
    // as it is or deletes the record. A caller that merged a view of the store's copy decides its write from this.
    pub kept: Option<Value>,
}

impl Settled {
    const NOTHING: Self = Self {
        store: None,
        base: None,
        conflict: None,
        kept: None,
    };
}

pub fn mode(scope: ScopeName) -> Mode {
    match scope {
        ScopeName::Team(_) => Mode::Team,
        ScopeName::Personal | ScopeName::History => Mode::Personal,
    }
}

// The base an applied create of a key object leaves, in the epoch it was pushed under, so a push-back after a restore
// judges what the server holds by it as by a pulled one (0051, Lost writes).
pub fn key_base(scope: ScopeName, epoch: EpochId, change: &Change, outcome: &ChangeOutcome) -> Option<BaseRow> {
    let ChangeOutcome::Applied {
        tag: Some(tag),
        service,
    } = outcome
    else {
        return None;
    };
    let ChangeOp::Write { fields, .. } = &change.op else {
        return None;
    };
    if !change.kind.is_key() {
        return None;
    }
    Some(BaseRow {
        key: RecordKey::new(scope, change.kind.clone(), change.record_id.clone()),
        tag: tag.clone(),
        version: service.map(|stamp| stamp.version),
        revision: service.map(|stamp| stamp.revision),
        epoch: Some(epoch),
        deleted: None,
        fields: Some(fields.clone()),
        created_ms: None,
    })
}

// The base a pulled copy leaves: its tag and server columns, and its fields unless the kind is created once.
pub fn base_of(key: &RecordKey, create_once: bool, pulled: &PulledRecord) -> BaseRow {
    let service = pulled.service.as_ref();
    BaseRow {
        key: key.clone(),
        tag: pulled.tag.clone(),
        version: service.map(|meta| meta.version),
        revision: service.map(|meta| meta.revision),
        epoch: service.map(|meta| meta.epoch),
        deleted: pulled.deleted,
        fields: if create_once || pulled.deleted.is_some() {
            None
        } else {
            pulled.fields.clone()
        },
        created_ms: None,
    }
}

fn put_if_changed(local: Option<&LocalRecord>, record_id: &str, fields: &Value) -> Option<LocalChange> {
    (local.map(|local| &local.fields) != Some(fields)).then(|| LocalChange::Put {
        record_id: record_id.to_owned(),
        fields: fields.clone(),
    })
}

fn delete_if_held(local: Option<&LocalRecord>, record_id: &str) -> Option<LocalChange> {
    local.map(|_| LocalChange::Delete {
        record_id: record_id.to_owned(),
    })
}

// One pulled record against its base and the store's copy. The store writes what this returns, then the bases.
pub fn settle(
    key: &RecordKey,
    kind: Kind,
    judgement: Judgement,
    base: Option<&BaseRow>,
    local: Option<&LocalRecord>,
    pulled: &PulledRecord,
) -> Settled {
    if judgement == Judgement::Merge && base.is_some_and(|base| base.tag == pulled.tag) {
        return Settled::NOTHING;
    }
    let next = Some(base_of(key, kind.is_create_once(), pulled));
    let id = key.record_id.as_str();
    // A device keeps its copy of what a policy removed, whatever it pulls (0051, Tombstones).
    if pulled.deleted == Some(DeletedReason::Policy) {
        return Settled {
            base: next,
            ..Settled::NOTHING
        };
    }
    let server = if pulled.deleted.is_some() {
        None
    } else {
        pulled.fields.as_ref()
    };
    match judgement {
        Judgement::LocalWins => Settled {
            base: next,
            ..Settled::NOTHING
        },
        Judgement::PullWins => Settled {
            store: match server {
                Some(fields) => put_if_changed(local, id, fields),
                None => delete_if_held(local, id),
            },
            base: next,
            conflict: None,
            kept: server.cloned(),
        },
        Judgement::Merge => merged(key, kind, base, local, pulled, server),
    }
}

// The first meet after a move from iCloud with a service copy that carries a move marker: the merge's base is the copy
// the marker names (0054, Moving between providers).
pub fn settle_moved(
    key: &RecordKey,
    kind: Kind,
    marker: &MoveMarker,
    local: Option<&LocalRecord>,
    pulled: &PulledRecord,
) -> Settled {
    let next = Some(base_of(key, kind.is_create_once(), pulled));
    if pulled.deleted == Some(DeletedReason::Policy) {
        return Settled {
            base: next,
            ..Settled::NOTHING
        };
    }
    let server = if pulled.deleted.is_some() {
        None
    } else {
        pulled.fields.as_ref()
    };
    let mine = local.map(|local| &local.fields);
    let merge = merge::merge_against_marker(kind, mode(key.scope), marker, mine, server);
    outcome(key, kind, None, local, pulled, server, merge)
}

fn merged(
    key: &RecordKey,
    kind: Kind,
    base: Option<&BaseRow>,
    local: Option<&LocalRecord>,
    pulled: &PulledRecord,
    server: Option<&Value>,
) -> Settled {
    let mine = local.map(|local| &local.fields);
    // A created-once base keeps no fields: only that it exists counts.
    let held = base.and_then(|base| {
        if base.deleted.is_some() {
            None
        } else if kind.is_create_once() {
            Some(&Value::Null)
        } else {
            base.fields.as_ref()
        }
    });
    let sides = Sides {
        base: held,
        local: mine,
        server,
    };
    let merge = merge::merge(kind, mode(key.scope), sides);
    outcome(key, kind, held, local, pulled, server, merge)
}

fn outcome(
    key: &RecordKey,
    kind: Kind,
    held: Option<&Value>,
    local: Option<&LocalRecord>,
    pulled: &PulledRecord,
    server: Option<&Value>,
    merge: Merged,
) -> Settled {
    let id = key.record_id.as_str();
    let mine = local.map(|local| &local.fields);
    let next = Some(base_of(key, kind.is_create_once(), pulled));
    let conflict = || ConflictRow {
        key: key.clone(),
        base: held.cloned().filter(|value| !value.is_null()),
        mine: mine.cloned(),
        theirs: server.cloned(),
    };
    match merge {
        Merged::Record(record) => Settled {
            store: put_if_changed(local, id, &record),
            base: next,
            conflict: None,
            kept: Some(record),
        },
        Merged::Deleted => Settled {
            store: delete_if_held(local, id),
            base: next,
            conflict: None,
            kept: None,
        },
        Merged::Contested { record, .. } => Settled {
            store: put_if_changed(local, id, &record),
            base: next,
            conflict: Some(conflict()),
            kept: Some(record),
        },
        // The device's side stays as it is until the person picks Keep Mine or Keep Theirs.
        Merged::DeletionContested { .. } => Settled {
            store: None,
            base: next,
            conflict: Some(conflict()),
            kept: None,
        },
        // Ciphertext does not merge: the device's envelope goes up again on the stored tag.
        Merged::Reseal => Settled {
            base: next,
            ..Settled::NOTHING
        },
    }
}
