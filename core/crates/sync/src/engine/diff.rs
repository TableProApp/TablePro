use std::collections::{HashMap, HashSet};

use serde_json::Value;
use tablepro_records::record_id::parse_envelope_id;
use tablepro_records::schema::{Type, schema};
use tablepro_records::{Kind, limits, merge_patch, settings};
use uuid::Uuid;

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
    // Create-once tombstones of entries the provider already holds as tombstones: the store drops them unsent.
    pub acknowledged: Vec<RecordKey>,
}

// One kind of one scope: its store's records against its bases. `skip` holds the ids that sync by other rules for now:
// held, contested or waiting for the person.
pub fn diff(scope: ScopeName, kind: Kind, local: &LocalRecords, bases: &[BaseRow], skip: &HashSet<String>) -> Diffed {
    let key = |record_id: &str| RecordKey::new(scope, KindName::of(kind), record_id);
    let by_id: HashMap<&str, &BaseRow> = bases.iter().map(|base| (base.key.record_id.as_str(), base)).collect();
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
        let base = by_id.get(record.record_id.as_str()).copied();
        if let Some(op) = written(kind, base, record) {
            diffed.pending.push(Pending {
                key: key(&record.record_id),
                base: base.cloned(),
                op,
            });
        }
    }
    // In the bases' key order, so a batch rebuilt from the same diff is the same request.
    for base in bases {
        let record_id = base.key.record_id.as_str();
        if present.contains(record_id) || unreadable.contains(record_id) || skip.contains(record_id) {
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
            base: Some(base.clone()),
            op: PendingOp::Delete,
        });
    }
    for record_id in &local.tombstones {
        if skip.contains(record_id) {
            continue;
        }
        match by_id.get(record_id.as_str()) {
            // A tombstone of an entry that never went up: its delete answers applied with nothing stored.
            None => diffed.pending.push(Pending {
                key: key(record_id),
                base: None,
                op: PendingOp::Delete,
            }),
            Some(base) if base.deleted.is_some() => diffed.acknowledged.push(key(record_id)),
            Some(_) => {}
        }
    }
    diffed
}

// The connections whose records stay on the device: the ones the connection store keeps off sync or cannot read, or
// every one when the store could not be read at all (0054, Rules for both providers: Local only and sample connections
// never leave the device).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct KeptOff {
    ids: HashSet<Uuid>,
    // Connections this device kept off sync, as the state file recorded them, that its store no longer holds: what was
    // theirs left the device with them.
    gone: HashSet<Uuid>,
    present: HashSet<Uuid>,
    unknown: bool,
}

impl KeptOff {
    // An engine with no connection store: what its adapters say of each record's connection stands alone.
    pub fn none() -> Self {
        Self::default()
    }

    // None when the connection store could not be read.
    pub fn of(connections: Option<&LocalRecords>) -> Self {
        let Some(local) = connections else {
            return Self {
                unknown: true,
                ..Self::default()
            };
        };
        let ids = local
            .records
            .iter()
            .filter(|record| record.standing != Standing::Syncs)
            .map(|record| record.record_id.as_str())
            .chain(local.unreadable.iter().map(String::as_str))
            .filter_map(|id| Uuid::parse_str(id).ok())
            .collect();
        let present = local
            .records
            .iter()
            .map(|record| record.record_id.as_str())
            .chain(local.unreadable.iter().map(String::as_str))
            .filter_map(|id| Uuid::parse_str(id).ok())
            .collect();
        Self {
            ids,
            gone: HashSet::new(),
            present,
            unknown: false,
        }
    }

    // The connections the state file last saw kept off sync; the ones the store no longer holds are gone.
    #[must_use]
    pub fn recorded(mut self, kept: impl IntoIterator<Item = Uuid>) -> Self {
        let gone: HashSet<Uuid> = kept.into_iter().filter(|id| !self.present.contains(id)).collect();
        self.gone = gone;
        self
    }

    fn holds(&self, owner: Uuid) -> bool {
        self.unknown || self.ids.contains(&owner)
    }
}

// The ids of the connections a store holds kept off sync that a base names, which the state file records so their
// deletions stay on the device once the store no longer holds them.
pub fn kept_off_connections(connections: &LocalRecords, bases: &[BaseRow]) -> Vec<Uuid> {
    let based: HashSet<&str> = bases.iter().map(|base| base.key.record_id.as_str()).collect();
    connections
        .records
        .iter()
        .filter(|record| record.standing != Standing::Syncs && based.contains(record.record_id.as_str()))
        .filter_map(|record| Uuid::parse_str(&record.record_id).ok())
        .collect()
}

// The connection a record of `kind` belongs to: the one a saved query, a folder, a favourite or a table folder names, or
// the one a settings category such as a column layout is about.
pub(crate) fn owner(kind: Kind, fields: &Value) -> Option<Uuid> {
    if kind.is_settings() {
        return fields.get("category").and_then(Value::as_str).and_then(settings::owner);
    }
    if !matches!(
        kind,
        Kind::SavedQuery
            | Kind::SavedQueryFolder
            | Kind::FavouriteTable
            | Kind::FavouriteDatabase
            | Kind::TableFolder
            | Kind::TableFolderItem
    ) {
        return None;
    }
    let field = schema(kind)
        .fields
        .iter()
        .find(|field| field.ty == Type::Reference(Kind::Connection))?;
    fields
        .get(field.key)
        .and_then(Value::as_str)
        .and_then(|id| Uuid::parse_str(id).ok())
}

// The connection whose secret an envelope holds, which its id names: its fields are ciphertext.
fn envelope_owner(kind: Kind, record_id: &str) -> Option<Uuid> {
    if kind != Kind::SecretEnvelope {
        return None;
    }
    parse_envelope_id(record_id)
        .filter(|(parent, _, _)| *parent == Kind::Connection)
        .and_then(|(_, id, _)| Uuid::parse_str(id).ok())
}

// The digest Start empty keeps of a settings copy it left on the device, over what a push would send of it.
pub fn left_behind_digest(fields: &Value) -> [u8; 32] {
    use sha2::Digest as _;
    sha2::Sha256::digest(serde_json::to_vec(fields).unwrap_or_default()).into()
}

// A settings copy Start empty left on the device goes up only once the person edits it here: its create of the copy
// kept then sends nothing (orchestrator ruling on 0066), nor does its revival over a tombstone, since the device keeps
// a named category a deletion reaches. Returns the records whose row goes, edited or met live on the provider.
pub fn hold_left_behind(diffed: &mut Diffed, bases: &[BaseRow], left: &HashMap<RecordKey, [u8; 32]>) -> Vec<RecordKey> {
    let mut gone: Vec<RecordKey> = bases
        .iter()
        .filter(|base| base.deleted.is_none() && left.contains_key(&base.key))
        .map(|base| base.key.clone())
        .collect();
    diffed.pending.retain(|pending| {
        let Some(kept) = left.get(&pending.key) else {
            return true;
        };
        let same = pending.base.as_ref().is_none_or(|base| base.deleted.is_some())
            && matches!(&pending.op, PendingOp::Write { fields, .. } if left_behind_digest(fields) == *kept);
        if !same {
            gone.push(pending.key.clone());
        }
        !same
    });
    gone.sort_by(|a, b| a.record_id.cmp(&b.record_id));
    gone.dedup();
    gone
}

// A deletion of a connection this device kept off sync and then deleted, or of a record that was one of its, sends
// nothing: the record was never this device's to sync, as the Swift engine never sent it (0054, Rules for both
// providers). Its base is forgotten, as a pruned one is.
pub fn forget_kept_off(diffed: &mut Diffed, kind: Kind, kept_off: &KeptOff) {
    if kept_off.gone.is_empty() {
        return;
    }
    let mut forgotten = Vec::new();
    diffed.pending.retain(|pending| {
        if pending.op != PendingOp::Delete {
            return true;
        }
        let owner = if kind == Kind::Connection {
            Uuid::parse_str(&pending.key.record_id).ok()
        } else {
            envelope_owner(kind, &pending.key.record_id).or_else(|| {
                pending
                    .base
                    .as_ref()
                    .and_then(|base| base.fields.as_ref())
                    .and_then(|fields| owner(kind, fields))
            })
        };
        let gone = owner.is_some_and(|owner| kept_off.gone.contains(&owner));
        if gone {
            forgotten.push(pending.key.clone());
        }
        !gone
    });
    diffed.pruned.extend(forgotten);
}

// Each change of a record whose connection stays on the device waits, a deletion by the owner its base names, since the
// store no longer holds it. It stays dirty against its base, so it goes once the connection syncs again. Returns the
// records it kept back.
pub fn hold_kept_off(diffed: &mut Diffed, kind: Kind, kept_off: &KeptOff) -> Vec<RecordKey> {
    let mut kept = Vec::new();
    diffed.pending.retain(|pending| {
        let fields = match &pending.op {
            PendingOp::Write { fields, .. } => Some(fields),
            PendingOp::Delete => pending.base.as_ref().and_then(|base| base.fields.as_ref()),
        };
        let held = envelope_owner(kind, &pending.key.record_id)
            .or_else(|| fields.and_then(|fields| owner(kind, fields)))
            .is_some_and(|owner| kept_off.holds(owner));
        if held {
            kept.push(pending.key.clone());
        }
        !held
    });
    kept
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

#[cfg(test)]
#[expect(
    clippy::disallowed_types,
    reason = "the records here are built with `json!`, and only their members are read"
)]
mod tests {
    use serde_json::json;
    use tablepro_records::record_id::column_layout_category;

    use super::*;

    fn base(kind: Kind, id: &str, fields: Value) -> BaseRow {
        BaseRow {
            key: RecordKey::new(ScopeName::Personal, KindName::of(kind), id),
            tag: crate::api::ids::ChangeTag::Service("t".to_owned()),
            version: None,
            revision: None,
            epoch: None,
            deleted: None,
            fields: Some(fields),
            created_ms: None,
        }
    }

    fn connections(kept: Uuid) -> LocalRecords {
        LocalRecords {
            records: vec![LocalRecord {
                record_id: kept.to_string().to_uppercase(),
                fields: json!({"name": "Local"}),
                standing: Standing::LocalOnly,
            }],
            ..LocalRecords::default()
        }
    }

    // A tombstone on the new account is no live copy: the settings Start empty kept stay unsent until edited, and only
    // a live base lets their row go (Codex security round 4).
    #[test]
    fn a_tombstone_keeps_a_left_behind_setting_unsent() {
        let kind = Kind::MacosSettings;
        let fields = json!({"category": "ai", "options": {"chatMode": "ask"}});
        let local = LocalRecords {
            records: vec![LocalRecord {
                record_id: "ai".to_owned(),
                fields: fields.clone(),
                standing: Standing::Syncs,
            }],
            ..LocalRecords::default()
        };
        let key = RecordKey::new(ScopeName::Personal, KindName::of(kind), "ai");
        let left = HashMap::from([(key.clone(), left_behind_digest(&fields))]);
        let tombstone = BaseRow {
            deleted: Some(crate::api::transport::DeletedReason::User),
            fields: None,
            ..base(kind, "ai", json!({}))
        };
        let live = base(kind, "ai", fields.clone());

        let mut over_tombstone = diff(
            ScopeName::Personal,
            kind,
            &local,
            std::slice::from_ref(&tombstone),
            &HashSet::new(),
        );
        let gone_over_tombstone = hold_left_behind(&mut over_tombstone, &[tombstone], &left);
        let mut over_live = diff(
            ScopeName::Personal,
            kind,
            &local,
            std::slice::from_ref(&live),
            &HashSet::new(),
        );
        let gone_over_live = hold_left_behind(&mut over_live, &[live], &left);

        assert!(over_tombstone.pending.is_empty());
        assert!(gone_over_tombstone.is_empty());
        assert!(over_live.pending.is_empty());
        assert_eq!(gone_over_live, vec![key]);
    }

    #[test]
    fn every_kind_that_names_a_connection_waits_while_that_connection_stays_on_the_device() {
        let kept = Uuid::new_v4();
        let synced = Uuid::new_v4();
        let layout = |connection| column_layout_category(connection, Some("shop"), Some("public"), "orders");
        let owned = [
            (
                Kind::SavedQuery,
                json!({"name": "q", "connection_id": kept.to_string()}),
            ),
            (
                Kind::SavedQueryFolder,
                json!({"name": "f", "connection_id": kept.to_string()}),
            ),
            (
                Kind::FavouriteTable,
                json!({"connection_id": kept.to_string(), "name": "t"}),
            ),
            (
                Kind::FavouriteDatabase,
                json!({"connection_id": kept.to_string(), "database": "d"}),
            ),
            (
                Kind::TableFolder,
                json!({"connection_id": kept.to_string(), "name": "tf"}),
            ),
            (
                Kind::TableFolderItem,
                json!({"connection_id": kept.to_string(), "name": "ti"}),
            ),
            (Kind::MacosSettings, json!({"category": layout(kept), "options": {}})),
        ];
        let kept_off = KeptOff::of(Some(&connections(kept)));
        for (kind, fields) in owned {
            let mut held = diff(
                ScopeName::Personal,
                kind,
                &LocalRecords::default(),
                &[base(kind, "gone", fields.clone())],
                &HashSet::new(),
            );
            hold_kept_off(&mut held, kind, &kept_off);
            assert!(held.pending.is_empty(), "{kind:?}");

            let mut moved = fields.clone();
            match moved.get_mut("connection_id") {
                Some(owner) => *owner = json!(synced.to_string()),
                None => moved["category"] = json!(layout(synced)),
            }
            let mut sent = diff(
                ScopeName::Personal,
                kind,
                &LocalRecords::default(),
                &[base(kind, "gone", moved)],
                &HashSet::new(),
            );
            hold_kept_off(&mut sent, kind, &kept_off);
            assert_eq!(sent.pending.len(), 1, "{kind:?}");
        }
    }

    #[test]
    fn a_connection_store_that_cannot_be_read_holds_owned_records_and_sends_the_rest() {
        let owner = Uuid::new_v4();
        let bases = [
            base(
                Kind::SavedQuery,
                "owned",
                json!({"name": "q", "connection_id": owner.to_string()}),
            ),
            base(Kind::SavedQuery, "global", json!({"name": "everywhere"})),
        ];
        let mut diffed = diff(
            ScopeName::Personal,
            Kind::SavedQuery,
            &LocalRecords::default(),
            &bases,
            &HashSet::new(),
        );

        hold_kept_off(&mut diffed, Kind::SavedQuery, &KeptOff::of(None));

        assert_eq!(diffed.pending.len(), 1);
        assert_eq!(diffed.pending[0].key.record_id, "global");
    }
}
