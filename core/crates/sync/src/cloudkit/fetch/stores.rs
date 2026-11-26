// The stores' side of a commit: what each holds as the batch reads it, the changes it will write, the standing rows
// read records leave behind, and the identity rows that tell a restored store from a store this device wrote.

use std::collections::{BTreeMap, BTreeSet};

use serde_json::Value;
use tablepro_records::Kind;
use tablepro_records::cloudkit::{CloudFields, from_wire, record_name, record_type_of, to_wire};
use tablepro_records::record_id::{DIGEST_PREFIX, shortened};

use super::SCOPE;
use super::settle::{Settle, View};
use crate::api::adapter::{LocalChange, LocalRecord, StoreStamp};
use crate::api::error::{AdapterError, SyncError};
use crate::api::ids::{KindName, RecordKey};
use crate::api::state::{Row, RowKey, RowRange, Standing, StandingRow, StoreRow, Table};

// Keyed by the id the zone names a record with, so a long id meets its `sha256-` form (0052, Long ids).
#[derive(Debug)]
pub(super) struct Local {
    records: BTreeMap<String, LocalRecord>,
    unreadable: BTreeMap<String, String>,
}

pub(super) enum Planned {
    Put(Value),
    Delete,
}

// What iCloud holds of a local copy: its fields through the projection and back, so a field the zone never carries,
// device-only or TablePro Sync's alone, reads as neither an edit nor a removal. None when the projection does not
// take the copy, as for a type Production does not hold.
pub(in crate::cloudkit) fn carried(kind: Kind, id: &str, local: &Value) -> Option<Value> {
    let record_type = record_type_of(kind)?;
    let saved = from_wire(kind, id, local, 0).ok()??;
    let fields: CloudFields = saved
        .into_iter()
        .filter_map(|(name, value)| Some((name.to_owned(), value?)))
        .collect();
    to_wire(record_type.name, &record_name(kind, id)?, &fields)
        .ok()
        .map(|wire| wire.fields)
}

fn member_names(value: &Value) -> impl Iterator<Item = String> + '_ {
    let members = match value {
        Value::Object(members) => Some(members.keys().cloned()),
        _ => None,
    };
    members.into_iter().flatten()
}

// The merge of the carried fields put back on the local copy. Where the merge left a carried value as the local copy
// had it, the local value stays whole, with whatever it holds that iCloud does not carry.
pub(super) fn overlay(local: &Value, carried: &Value, merged: &Value) -> Value {
    if carried == merged || !local.is_object() || !merged.is_object() {
        return if carried == merged {
            local.clone()
        } else {
            merged.clone()
        };
    }
    let mut out = local.clone();
    let names: BTreeSet<String> = member_names(carried).chain(member_names(merged)).collect();
    for name in names {
        match merged.get(&name) {
            Some(value) => {
                let mine = local.get(&name).unwrap_or(&Value::Null);
                let held = carried.get(&name).unwrap_or(&Value::Null);
                out[&name] = overlay(mine, held, value);
            }
            None => {
                if let Value::Object(members) = &mut out {
                    members.remove(&name);
                }
            }
        }
    }
    out
}

// A record new to the store whose id is a digest takes the id its fields name, as the store keeps it (0052, Long ids).
fn stored_id(kind: Kind, wire: &str, fields: &Value) -> String {
    if kind.is_settings() && wire.starts_with(DIGEST_PREFIX) {
        let named = fields.get("category").and_then(Value::as_str);
        if let Some(category) = named.filter(|category| shortened(kind, (*category).to_owned()) == wire) {
            return category.to_owned();
        }
    }
    wire.to_owned()
}

impl Settle<'_, '_> {
    pub(super) async fn view(&mut self, key: &RecordKey, kind: Kind) -> Result<View, SyncError> {
        self.load(kind).await?;
        let Some(Some(local)) = self.locals.get(&kind) else {
            return Ok(View::NoAdapter);
        };
        if let Some(record) = local.records.get(&key.record_id) {
            return Ok(View::Stored(record.clone()));
        }
        if !local.unreadable.contains_key(&key.record_id) {
            return Ok(View::Missing);
        }
        Ok(View::Unreadable(
            match self.txn.get(&RowKey::Standing(key.clone())).await? {
                Some(Row::Standing(row)) => Some(row.standing),
                _ => None,
            },
        ))
    }

    // The identity is read before the records, so a write between the two shows when the stores are written.
    async fn load(&mut self, kind: Kind) -> Result<(), SyncError> {
        if self.locals.contains_key(&kind) {
            return Ok(());
        }
        let fetcher = self.fetcher;
        let Some(adapter) = fetcher.adapters.get(&kind) else {
            self.locals.insert(kind, None);
            return Ok(());
        };
        let stamp = adapter.identity().await?;
        // Restored or replaced after the fetch started: its copies would merge as edits, so the pass ends and the next
        // one refills the store.
        if self
            .started
            .get(adapter.store())
            .is_some_and(|started| stamp.needs_refill(*started))
        {
            return Err(AdapterError::Store {
                store: adapter.store().to_owned(),
                detail: "restored while the fetch ran".to_owned(),
            }
            .into());
        }
        match self.loaded.get(adapter.store()) {
            Some(seen) if *seen != stamp => self.moved = Some(adapter.store().to_owned()),
            Some(_) => {}
            None => {
                self.loaded.insert(adapter.store().to_owned(), stamp);
            }
        }
        let held = adapter.records(SCOPE).await?;
        let mut records: BTreeMap<String, LocalRecord> = BTreeMap::new();
        for record in held.records {
            let wire = shortened(kind, record.record_id.clone());
            // Two copies under one name: the one kept under the long id is the store's own.
            if records.get(&wire).is_none_or(|kept| kept.record_id == wire) {
                records.insert(wire, record);
            }
        }
        let local = Local {
            records,
            unreadable: held
                .unreadable
                .into_iter()
                .map(|id| (shortened(kind, id.clone()), id))
                .collect(),
        };
        self.keep_standing(kind, &local).await?;
        self.locals.insert(kind, Some(local));
        Ok(())
    }

    // Standing is written by id whenever the store reads a record, so a copy it can no longer read keeps the standing
    // it last had, and one no longer stored loses it.
    async fn keep_standing(&mut self, kind: Kind, local: &Local) -> Result<(), SyncError> {
        let range = RowRange::ScopeKind(Table::Standing, SCOPE, KindName::of(kind));
        let mut known: BTreeMap<String, Standing> = BTreeMap::new();
        for row in self.txn.scan(&range).await? {
            if let Row::Standing(row) = row {
                known.insert(row.key.record_id, row.standing);
            }
        }
        for (id, record) in &local.records {
            if known.remove(id) != Some(record.standing) {
                self.txn
                    .put(Row::Standing(StandingRow {
                        key: RecordKey::new(SCOPE, kind, id.clone()),
                        standing: record.standing,
                    }))
                    .await?;
            }
        }
        for id in known.into_keys().filter(|id| !local.unreadable.contains_key(id)) {
            self.txn
                .delete(&RowKey::Standing(RecordKey::new(SCOPE, kind, id)))
                .await?;
        }
        Ok(())
    }

    // Later items of the batch see what the stores will hold once it is written. The change names the record by the
    // id its store keeps.
    pub(super) fn plan(&mut self, kind: Kind, key: &RecordKey, planned: Planned) {
        let wire = &key.record_id;
        let mut record_id = match &planned {
            Planned::Put(fields) => stored_id(kind, wire, fields),
            Planned::Delete => wire.clone(),
        };
        let change = match self.locals.get_mut(&kind) {
            Some(Some(local)) => {
                if let Some(id) = local
                    .records
                    .get(wire)
                    .map(|record| record.record_id.clone())
                    .or_else(|| local.unreadable.get(wire).cloned())
                {
                    record_id = id;
                }
                match planned {
                    Planned::Put(fields) => {
                        let standing = local
                            .records
                            .get(wire)
                            .map_or(Standing::Syncs, |record| record.standing);
                        local.unreadable.remove(wire);
                        local.records.insert(
                            wire.clone(),
                            LocalRecord {
                                record_id: record_id.clone(),
                                fields: fields.clone(),
                                standing,
                            },
                        );
                        LocalChange::Put { record_id, fields }
                    }
                    Planned::Delete => {
                        local.records.remove(wire);
                        local.unreadable.remove(wire);
                        LocalChange::Delete { record_id }
                    }
                }
            }
            _ => return,
        };
        self.changes.entry(kind).or_default().insert(wire.clone(), change);
    }

    // None when a store was written between the batch's read and now: the merge was built on what it no longer holds,
    // so the batch is read and merged again.
    pub(super) async fn write_stores(&mut self) -> Result<Option<()>, SyncError> {
        let fetcher = self.fetcher;
        let touched: BTreeSet<&str> = self
            .changes
            .keys()
            .filter_map(|kind| fetcher.adapters.get(kind))
            .map(|adapter| adapter.store())
            .collect();
        if self.moved.is_some() {
            return Ok(None);
        }
        for store in touched {
            let Some(adapter) = fetcher.adapters.values().find(|adapter| adapter.store() == store) else {
                continue;
            };
            if Some(&adapter.identity().await?) != self.loaded.get(store) {
                self.moved = Some(store.to_owned());
                return Ok(None);
            }
        }
        for (kind, changes) in std::mem::take(&mut self.changes) {
            let Some(adapter) = fetcher.adapters.get(&kind) else {
                continue;
            };
            fetcher.check_stop()?;
            let changes: Vec<LocalChange> = changes.into_values().collect();
            for change in &changes {
                match change {
                    LocalChange::Put { .. } => self.counts.written += 1,
                    LocalChange::Delete { .. } => self.counts.removed += 1,
                }
            }
            let stamp = adapter.apply(SCOPE, changes).await?;
            self.note_store(adapter.store(), stamp).await?;
        }
        Ok(Some(()))
    }

    // Each identity of a store this fetch sees moves its row, so a later rollback of the file below it shows for every
    // kind it keeps, written by this pull or not. A kind in refill keeps its mark until the refill ends, so a fetch
    // stopped midway refills it again.
    pub(super) async fn note_store(&mut self, store: &str, stamp: StoreStamp) -> Result<(), SyncError> {
        if self.fetcher.adapters.values().any(|adapter| adapter.store() == store) {
            self.note_stamp(store, stamp, false).await?;
        }
        Ok(())
    }

    // A stamp moves an identity row forward only. One of another generation, or behind the row, means the store was
    // restored since the fetch started: the row stays, and the next fetch refills that kind.
    pub(super) async fn note_stamp(&mut self, row: &str, stamp: StoreStamp, force: bool) -> Result<(), SyncError> {
        let forward = match self.txn.get(&RowKey::Store(row.to_owned())).await? {
            Some(Row::Store(seen)) => seen.generation == stamp.generation && seen.sequence <= stamp.sequence,
            _ => true,
        };
        if force || forward {
            self.put_stamp(row, stamp).await?;
        }
        Ok(())
    }

    async fn put_stamp(&mut self, row: &str, stamp: StoreStamp) -> Result<(), SyncError> {
        self.txn
            .put(Row::Store(StoreRow {
                store: row.to_owned(),
                generation: stamp.generation,
                sequence: stamp.sequence,
            }))
            .await?;
        Ok(())
    }
}
