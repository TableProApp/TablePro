// One commit of what the zone said (0054, A pass): each copy merged three ways against its base, the stores written,
// then the bases, the held and deferred sets and last the token, in one state commit. A crash before the commit
// replays the batch, and the merge leaves what a store already took as it is.

use std::collections::{BTreeMap, BTreeSet};

use tablepro_records::Kind;
use tablepro_records::merge::{self, Merged, Mode, Sides};

use super::copy::{Copy, Incoming, kind_of};
use super::{Counts, Fetcher, PROFILES, SCOPE};
use crate::api::adapter::{LocalChange, LocalRecord, StoreStamp};
use crate::api::error::SyncError;
use crate::api::ids::{ChangeTag, Cursor, KindName, RecordKey};
use crate::api::state::{
    BaseRow, DeferredRow, HeldReason, HeldRow, Row, RowKey, RowRange, ScopeRow, Standing, StandingRow, StateTxn,
    StoreRow, Table,
};
use crate::api::transport::{DeletedReason, PulledRecord};

#[derive(Debug, Default)]
pub(super) struct Batch {
    pub items: Vec<Incoming>,
    // Kinds in refill: the pull wins over the store.
    pub pull_wins: BTreeSet<Kind>,
    // The token this commit stores; None leaves the stored one.
    pub token: Option<Vec<u8>>,
    pub caught_up: bool,
    pub finish: Option<Finish>,
    // Store identities read when the fetch started, recorded where the state has none yet.
    pub stamps: BTreeMap<String, StoreStamp>,
    // Held changes to drop: the zone holds no such record any more.
    pub release: Vec<RecordKey>,
}

// The last page of a full fetch: every record the zone listed, and the kinds whose stores refill.
#[derive(Debug, Default)]
pub(super) struct Finish {
    pub listed: BTreeSet<RecordKey>,
    pub refill: BTreeSet<Kind>,
}

#[derive(Debug, Default)]
struct Local {
    records: BTreeMap<String, LocalRecord>,
    unreadable: BTreeSet<String>,
}

pub(super) enum View {
    NoAdapter,
    // The store holds the id but cannot read it, with the standing it last had.
    Unreadable(Option<Standing>),
    Stored(LocalRecord),
    Missing,
}

pub(super) struct Settle<'s, 'f> {
    pub fetcher: &'s Fetcher<'f>,
    pub txn: Box<dyn StateTxn>,
    pub counts: Counts,
    locals: BTreeMap<Kind, Option<Local>>,
    changes: BTreeMap<Kind, BTreeMap<String, LocalChange>>,
    pull_wins: BTreeSet<Kind>,
}

fn held_change(copy: &Copy) -> PulledRecord {
    PulledRecord {
        kind: KindName::of(copy.kind),
        record_id: copy.key.record_id.clone(),
        tag: ChangeTag::CloudKit(copy.tag.clone()),
        fields: Some(copy.fields.clone()),
        fields_json: None,
        deleted: None,
        service: None,
    }
}

fn held_deletion(key: &RecordKey) -> PulledRecord {
    PulledRecord {
        kind: key.kind.clone(),
        record_id: key.record_id.clone(),
        tag: ChangeTag::CloudKit(Vec::new()),
        fields: None,
        fields_json: None,
        deleted: Some(DeletedReason::User),
        service: None,
    }
}

const fn record_id(change: &LocalChange) -> &String {
    match change {
        LocalChange::Put { record_id, .. } | LocalChange::Delete { record_id } => record_id,
    }
}

impl Fetcher<'_> {
    pub(super) async fn settle(&self, batch: Batch) -> Result<Counts, SyncError> {
        let txn = self.state.begin().await?;
        let mut settle = Settle::new(self, txn, batch.pull_wins);
        for item in batch.items {
            settle.take(item).await?;
        }
        for key in &batch.release {
            settle.release(key).await?;
        }
        if let Some(finish) = &batch.finish {
            settle.finish(finish).await?;
        }
        settle.write_stores().await?;
        for (store, stamp) in &batch.stamps {
            settle.note_stamp(store, *stamp, false).await?;
        }
        if let Some(finish) = &batch.finish {
            settle.refilled(&finish.refill).await?;
        }
        settle
            .store_token(batch.token, batch.caught_up, batch.finish.is_some())
            .await?;
        settle.commit().await
    }
}

impl<'s, 'f> Settle<'s, 'f> {
    pub(super) fn new(fetcher: &'s Fetcher<'f>, txn: Box<dyn StateTxn>, pull_wins: BTreeSet<Kind>) -> Self {
        Self {
            fetcher,
            txn,
            counts: Counts::default(),
            locals: BTreeMap::new(),
            changes: BTreeMap::new(),
            pull_wins,
        }
    }

    async fn take(&mut self, item: Incoming) -> Result<(), SyncError> {
        match item {
            Incoming::Changed(copy) => self.changed(copy).await,
            Incoming::Deleted(key) => self.deleted(&key).await,
            Incoming::Unread { key, tag } => self.unread(&key, tag).await,
        }
    }

    async fn changed(&mut self, copy: Copy) -> Result<(), SyncError> {
        let key = copy.key.clone();
        // A save after a deletion that waited for its category was made after it.
        self.txn.delete(&RowKey::Deferred(key.clone())).await?;
        if !self.fetcher.categories.syncs(copy.kind) {
            self.counts.skipped += 1;
            return Ok(());
        }
        let record = match self.view(&key, copy.kind).await? {
            View::NoAdapter => return self.hold(&key, HeldReason::UnknownKind, held_change(&copy)).await,
            View::Unreadable(Some(Standing::LocalOnly)) => return self.release(&key).await,
            View::Unreadable(_) => return self.hold(&key, HeldReason::Unreadable, held_change(&copy)).await,
            View::Stored(record) if record.standing == Standing::LocalOnly => return self.release(&key).await,
            View::Stored(record) => Some(record),
            View::Missing => None,
        };
        let base = self.base(&key).await?;
        let merged = if self.pull_wins.contains(&copy.kind) {
            Merged::Record(copy.fields.clone())
        } else {
            let sides = Sides {
                base: base.as_ref().and_then(|base| base.fields.as_ref()),
                local: record.as_ref().map(|record| &record.fields),
                server: Some(&copy.fields),
            };
            merge::merge(copy.kind, Mode::Personal, sides)
        };
        self.settle_local(copy.kind, &key, record.as_ref(), merged);
        self.txn
            .put(Row::Base(BaseRow {
                key: key.clone(),
                tag: ChangeTag::CloudKit(copy.tag),
                version: None,
                revision: None,
                epoch: None,
                deleted: None,
                fields: Some(copy.fields),
            }))
            .await?;
        self.release(&key).await
    }

    fn settle_local(&mut self, kind: Kind, key: &RecordKey, record: Option<&LocalRecord>, merged: Merged) {
        let kept = match merged {
            Merged::Record(fields)
            | Merged::Contested { record: fields, .. }
            | Merged::DeletionContested { kept: fields, .. } => Some(fields),
            Merged::Deleted => None,
            // Only an envelope is sealed again, and iCloud carries none.
            Merged::Reseal => return,
        };
        let record_id = key.record_id.clone();
        match (kept, record) {
            (Some(fields), Some(record)) if record.fields == fields => {}
            (Some(fields), _) => self.plan(kind, LocalChange::Put { record_id, fields }),
            (None, Some(_)) => self.plan(kind, LocalChange::Delete { record_id }),
            (None, None) => {}
        }
    }

    pub(super) async fn deleted(&mut self, key: &RecordKey) -> Result<(), SyncError> {
        let Some(kind) = kind_of(key) else {
            return Ok(());
        };
        if !self.fetcher.categories.syncs(kind) {
            self.counts.deferred += 1;
            return self
                .txn
                .put(Row::Deferred(DeferredRow {
                    key: key.clone(),
                    record: held_deletion(key),
                }))
                .await
                .map_err(SyncError::from);
        }
        self.txn.delete(&RowKey::Deferred(key.clone())).await?;
        let record = match self.view(key, kind).await? {
            View::NoAdapter => return self.hold(key, HeldReason::UnknownKind, held_deletion(key)).await,
            View::Unreadable(standing) => return self.unreadable_deleted(key, kind, standing).await,
            View::Stored(record) if record.standing == Standing::LocalOnly => return self.forget(key).await,
            View::Stored(record) => Some(record),
            View::Missing => None,
        };
        let base = self.base(key).await?;
        let sides = Sides {
            base: base.as_ref().and_then(|base| base.fields.as_ref()),
            local: record.as_ref().map(|record| &record.fields),
            server: None,
        };
        // Otherwise a content edit here revives the record: it stays, and with no base it goes up as a create. A
        // store in refill went back in time, so what differs from the base there is no edit.
        let goes = self.pull_wins.contains(&kind) || merge::merge(kind, Mode::Personal, sides) == Merged::Deleted;
        if record.is_some() && goes {
            self.plan(
                kind,
                LocalChange::Delete {
                    record_id: key.record_id.clone(),
                },
            );
        }
        self.forget(key).await
    }

    // A copy this build cannot read goes by its id when its standing says it syncs, and a Local only one stays. With
    // no standing, or a profile, whose deletion unlinks connections a build has to read, the deletion waits.
    async fn unreadable_deleted(
        &mut self,
        key: &RecordKey,
        kind: Kind,
        standing: Option<Standing>,
    ) -> Result<(), SyncError> {
        match standing {
            Some(Standing::Syncs) if !PROFILES.contains(&kind) => {
                self.plan(
                    kind,
                    LocalChange::Delete {
                        record_id: key.record_id.clone(),
                    },
                );
                self.forget(key).await
            }
            Some(Standing::LocalOnly) if !PROFILES.contains(&kind) => self.forget(key).await,
            _ => self.hold(key, HeldReason::Unreadable, held_deletion(key)).await,
        }
    }

    async fn unread(&mut self, key: &RecordKey, tag: Option<Vec<u8>>) -> Result<(), SyncError> {
        let Some(kind) = kind_of(key) else {
            return Ok(());
        };
        self.txn.delete(&RowKey::Deferred(key.clone())).await?;
        if !self.fetcher.categories.syncs(kind) {
            self.counts.skipped += 1;
            return Ok(());
        }
        let local_only = match self.view(key, kind).await? {
            View::Stored(record) => record.standing == Standing::LocalOnly,
            View::Unreadable(standing) => standing == Some(Standing::LocalOnly),
            View::NoAdapter | View::Missing => false,
        };
        if local_only {
            return self.release(key).await;
        }
        let record = PulledRecord {
            kind: key.kind.clone(),
            record_id: key.record_id.clone(),
            tag: ChangeTag::CloudKit(tag.unwrap_or_default()),
            fields: None,
            fields_json: None,
            deleted: None,
            service: None,
        };
        self.hold(key, HeldReason::Unreadable, record).await
    }

    // The deletion is settled on both sides: no base, nothing held or waiting.
    async fn forget(&mut self, key: &RecordKey) -> Result<(), SyncError> {
        self.txn.delete(&RowKey::Base(key.clone())).await?;
        self.txn.delete(&RowKey::Deferred(key.clone())).await?;
        self.release(key).await
    }

    // A value waiting for approval is the approval queue's, so neither a hold nor a release here touches it.
    async fn held_for_approval(&mut self, key: &RecordKey) -> Result<bool, SyncError> {
        Ok(matches!(
            self.txn.get(&RowKey::Held(key.clone())).await?,
            Some(Row::Held(HeldRow {
                reason: HeldReason::AwaitingApproval,
                ..
            }))
        ))
    }

    async fn hold(&mut self, key: &RecordKey, reason: HeldReason, record: PulledRecord) -> Result<(), SyncError> {
        if self.held_for_approval(key).await? {
            return Ok(());
        }
        self.counts.held += 1;
        self.txn
            .put(Row::Held(HeldRow {
                key: key.clone(),
                reason,
                record,
            }))
            .await?;
        Ok(())
    }

    pub(super) async fn release(&mut self, key: &RecordKey) -> Result<(), SyncError> {
        if self.held_for_approval(key).await? {
            return Ok(());
        }
        self.txn.delete(&RowKey::Held(key.clone())).await?;
        Ok(())
    }

    pub(super) async fn base(&mut self, key: &RecordKey) -> Result<Option<BaseRow>, SyncError> {
        Ok(match self.txn.get(&RowKey::Base(key.clone())).await? {
            Some(Row::Base(base)) => Some(base),
            _ => None,
        })
    }

    pub(super) async fn view(&mut self, key: &RecordKey, kind: Kind) -> Result<View, SyncError> {
        self.load(kind).await?;
        let Some(Some(local)) = self.locals.get(&kind) else {
            return Ok(View::NoAdapter);
        };
        if let Some(record) = local.records.get(&key.record_id) {
            return Ok(View::Stored(record.clone()));
        }
        if !local.unreadable.contains(&key.record_id) {
            return Ok(View::Missing);
        }
        Ok(View::Unreadable(
            match self.txn.get(&RowKey::Standing(key.clone())).await? {
                Some(Row::Standing(row)) => Some(row.standing),
                _ => None,
            },
        ))
    }

    async fn load(&mut self, kind: Kind) -> Result<(), SyncError> {
        if self.locals.contains_key(&kind) {
            return Ok(());
        }
        let Some(adapter) = self.fetcher.adapters.get(&kind) else {
            self.locals.insert(kind, None);
            return Ok(());
        };
        let held = adapter.records().await?;
        let local = Local {
            records: held
                .records
                .into_iter()
                .map(|record| (record.record_id.clone(), record))
                .collect(),
            unreadable: held.unreadable.into_iter().collect(),
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
        for record in local.records.values() {
            if known.remove(&record.record_id) != Some(record.standing) {
                self.txn
                    .put(Row::Standing(StandingRow {
                        key: RecordKey::new(SCOPE, kind, record.record_id.clone()),
                        standing: record.standing,
                    }))
                    .await?;
            }
        }
        for record_id in known.into_keys().filter(|id| !local.unreadable.contains(id)) {
            self.txn
                .delete(&RowKey::Standing(RecordKey::new(SCOPE, kind, record_id)))
                .await?;
        }
        Ok(())
    }

    // Later items of the batch see what the stores will hold once it is written.
    fn plan(&mut self, kind: Kind, change: LocalChange) {
        if let Some(Some(local)) = self.locals.get_mut(&kind) {
            match &change {
                LocalChange::Put { record_id, fields } => {
                    let standing = local
                        .records
                        .get(record_id)
                        .map_or(Standing::Syncs, |record| record.standing);
                    local.unreadable.remove(record_id);
                    local.records.insert(
                        record_id.clone(),
                        LocalRecord {
                            record_id: record_id.clone(),
                            fields: fields.clone(),
                            standing,
                        },
                    );
                }
                LocalChange::Delete { record_id } => {
                    local.records.remove(record_id);
                    local.unreadable.remove(record_id);
                }
            }
        }
        self.changes
            .entry(kind)
            .or_default()
            .insert(record_id(&change).clone(), change);
    }

    async fn write_stores(&mut self) -> Result<(), SyncError> {
        let fetcher = self.fetcher;
        let mut stamps = BTreeMap::new();
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
            stamps.insert(adapter.store().to_owned(), stamp);
        }
        for (store, stamp) in stamps {
            self.note_stamp(&store, stamp, false).await?;
        }
        Ok(())
    }

    // A stamp moves the store's row forward only. One of another generation, or behind the row, means the store was
    // restored since the fetch started: the row stays, and the next fetch refills that store's kinds.
    pub(super) async fn note_stamp(&mut self, store: &str, stamp: StoreStamp, force: bool) -> Result<(), SyncError> {
        let forward = match self.txn.get(&RowKey::Store(store.to_owned())).await? {
            Some(Row::Store(seen)) => seen.generation == stamp.generation && seen.sequence <= stamp.sequence,
            _ => true,
        };
        if !force && !forward {
            return Ok(());
        }
        self.txn
            .put(Row::Store(StoreRow {
                store: store.to_owned(),
                generation: stamp.generation,
                sequence: stamp.sequence,
            }))
            .await?;
        Ok(())
    }

    async fn store_token(&mut self, token: Option<Vec<u8>>, caught_up: bool, finished: bool) -> Result<(), SyncError> {
        if token.is_none() && !finished {
            return Ok(());
        }
        let mut scope = match self.txn.get(&RowKey::Scope(SCOPE)).await? {
            Some(Row::Scope(scope)) => scope,
            _ => ScopeRow::new(SCOPE),
        };
        if let Some(token) = token {
            scope.cursor = Some(Cursor::CloudKit(token));
            scope.caught_up = caught_up;
        }
        if finished {
            scope.refill = false;
        }
        self.txn.put(Row::Scope(scope)).await?;
        Ok(())
    }

    async fn commit(self) -> Result<Counts, SyncError> {
        self.txn.commit().await?;
        Ok(self.counts)
    }
}
