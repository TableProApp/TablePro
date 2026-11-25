// The stores' side of a commit: what each holds as the batch reads it, the changes it will write, the standing rows
// read records leave behind, and the identity rows that tell a restored store from a store this device wrote.

use std::collections::{BTreeMap, BTreeSet};

use serde_json::Value;
use tablepro_records::Kind;
use tablepro_records::cloudkit::{Carries, record_type_of};
use tablepro_records::record_id::shortened;
use uuid::Uuid;

use super::settle::{Settle, View};
use super::{SCOPE, identity_row};
use crate::api::adapter::{LocalChange, LocalRecord, StoreStamp};
use crate::api::error::SyncError;
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

// The pull wins only over what iCloud carries. Device-only fields and those only TablePro Sync carries stay as the
// store holds them.
pub(super) fn pulled_over(kind: Kind, local: Option<&Value>, server: &Value) -> Value {
    let (Some(mut kept @ Value::Object(_)), Some(record_type)) = (local.cloned(), record_type_of(kind)) else {
        return server.clone();
    };
    for field in record_type.fields {
        let Carries::Wire(key) = field.carries else {
            continue;
        };
        match server.get(key) {
            Some(value) => kept[key] = value.clone(),
            None => {
                if let Value::Object(members) = &mut kept {
                    members.remove(key);
                }
            }
        }
    }
    kept
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
        match self.loaded.get(adapter.store()) {
            Some(seen) if *seen != stamp => self.moved = Some(adapter.store().to_owned()),
            Some(_) => {}
            None => {
                self.loaded.insert(adapter.store().to_owned(), stamp);
            }
        }
        let held = adapter.records().await?;
        let local = Local {
            records: held
                .records
                .into_iter()
                .map(|record| (shortened(kind, record.record_id.clone()), record))
                .collect(),
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
        let mut record_id = wire.clone();
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
            let changes: Vec<LocalChange> = changes.into_values().collect();
            for change in &changes {
                match change {
                    LocalChange::Put { .. } => self.counts.written += 1,
                    LocalChange::Delete { .. } => self.counts.removed += 1,
                }
            }
            let stamp = adapter.apply(changes).await?;
            // A store in refill moves its row only once the refill ends, so a fetch stopped midway refills again.
            if !self.pull_wins.contains(&kind) {
                self.note_stamp(&identity_row(kind, adapter.store()), stamp, false)
                    .await?;
            }
        }
        Ok(Some(()))
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

    // A kind whose category was off while its state file refilled is left with a generation no store has, so it
    // refills once the category is on.
    pub(super) async fn refill_later(&mut self, row: &str) -> Result<(), SyncError> {
        self.put_stamp(
            row,
            StoreStamp {
                generation: Uuid::nil(),
                sequence: 0,
            },
        )
        .await
    }
}
