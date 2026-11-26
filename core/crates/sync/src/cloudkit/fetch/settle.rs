// One commit of what the zone said (0054, A pass): each copy merged three ways against its base, the stores written,
// then the bases, the held and deferred sets and last the token, in one state commit. A crash before the commit
// replays the batch, and the merge leaves what a store already took as it is.

use std::collections::{BTreeMap, BTreeSet};

use tablepro_records::Kind;
use tablepro_records::merge::{self, Merged, Mode, Sides};

use super::copy::{Copy, Incoming, kind_of};
use super::stores::{Local, Planned, carried, overlay};
use super::{Counts, Fetcher, PROFILES, SCOPE};
use crate::api::adapter::{LocalChange, LocalRecord, StoreStamp};
use crate::api::error::{AdapterError, SyncError};
use crate::api::ids::{ChangeTag, Cursor, KindName, RecordKey};
use crate::api::state::{BaseRow, DeferredRow, HeldReason, HeldRow, Row, RowKey, ScopeRow, Standing, StateTxn};
use crate::api::transport::{DeletedReason, PulledRecord};

// A store written this many times in a row while its batch merged is left to the next pass.
const ATTEMPTS: usize = 3;

#[derive(Debug, Clone, Default)]
pub(super) struct Batch {
    pub items: Vec<Incoming>,
    // Kinds in refill: the pull wins over the store.
    pub pull_wins: BTreeSet<Kind>,
    // The token this commit stores; None leaves the stored one.
    pub token: Option<Vec<u8>>,
    pub caught_up: bool,
    pub finish: Option<Finish>,
    // Each store's identity as the fetch found it: `stamps` moves the identity rows once, `started` tells a store
    // restored since then.
    pub stamps: BTreeMap<String, StoreStamp>,
    pub started: BTreeMap<String, StoreStamp>,
    // Held changes to drop: the zone holds no such record any more.
    pub release: Vec<RecordKey>,
}

// The last page of a full fetch.
#[derive(Debug, Clone, Default)]
pub(super) struct Finish {
    // Every record the zone listed.
    pub listed: BTreeSet<RecordKey>,
    pub refill: BTreeSet<Kind>,
    // The identities the refilling stores had when the fetch started, by identity row.
    pub started: BTreeMap<String, StoreStamp>,
    // Identity rows of kinds whose category is off while the whole state file refills.
    pub refill_later: Vec<String>,
    // The state file as a whole refilled.
    pub scope_refilled: bool,
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
    pub locals: BTreeMap<Kind, Option<Local>>,
    pub changes: BTreeMap<Kind, BTreeMap<String, LocalChange>>,
    pub pull_wins: BTreeSet<Kind>,
    // Each store's identity when the batch first read it, and a store written since.
    pub loaded: BTreeMap<String, StoreStamp>,
    pub moved: Option<String>,
    pub started: BTreeMap<String, StoreStamp>,
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

impl Fetcher<'_> {
    pub(super) async fn settle(&self, batch: Batch) -> Result<Counts, SyncError> {
        let mut moved = String::new();
        for _ in 0..ATTEMPTS {
            match self.settle_once(batch.clone()).await? {
                Ok(counts) => return Ok(counts),
                Err(store) => moved = store,
            }
        }
        Err(SyncError::Adapter(AdapterError::Store {
            store: moved,
            detail: "written while a pull merged into it".to_owned(),
        }))
    }

    async fn settle_once(&self, batch: Batch) -> Result<Result<Counts, String>, SyncError> {
        let txn = self.state.begin().await?;
        let mut settle = Settle::new(self, txn, batch.pull_wins);
        settle.started = batch.started;
        for item in batch.items {
            settle.take(item).await?;
        }
        for key in &batch.release {
            settle.release(key).await?;
        }
        if let Some(finish) = &batch.finish {
            settle.finish(finish).await?;
        }
        if settle.write_stores().await?.is_none() {
            return Ok(Err(settle.moved.unwrap_or_default()));
        }
        for (store, stamp) in &batch.stamps {
            settle.note_store(store, *stamp).await?;
        }
        if let Some(finish) = &batch.finish {
            settle.refilled(finish).await?;
        }
        settle
            .store_token(batch.token, batch.caught_up, batch.finish.is_some())
            .await?;
        settle.commit().await.map(Ok)
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
            loaded: BTreeMap::new(),
            moved: None,
            started: BTreeMap::new(),
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
        let local = record.as_ref().map(|record| &record.fields);
        let held = local.and_then(|local| carried(copy.kind, &key.record_id, local));
        let merged = if self.pull_wins.contains(&copy.kind) {
            Merged::Record(copy.fields.clone())
        } else {
            let base = self.base(&key).await?;
            let sides = Sides {
                base: base.as_ref().and_then(|base| base.fields.as_ref()),
                local: held.as_ref().or(local),
                server: Some(&copy.fields),
            };
            merge::merge(copy.kind, Mode::Personal, sides)
        };
        let merged = match (merged, local, &held) {
            (Merged::Record(fields), Some(local), Some(held)) => Merged::Record(overlay(local, held, &fields)),
            (merged, ..) => merged,
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
                created_ms: copy.created_ms,
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
        match (kept, record) {
            (Some(fields), Some(record)) if record.fields == fields => {}
            (Some(fields), _) => self.plan(kind, key, Planned::Put(fields)),
            (None, Some(_)) => self.plan(kind, key, Planned::Delete),
            (None, None) => {}
        }
    }

    pub(super) async fn deleted(&mut self, key: &RecordKey) -> Result<(), SyncError> {
        let Some(kind) = kind_of(key) else {
            return Ok(());
        };
        if !self.fetcher.categories.syncs(kind) {
            self.counts.deferred += 1;
            self.txn
                .put(Row::Deferred(DeferredRow {
                    key: key.clone(),
                    record: held_deletion(key),
                }))
                .await?;
            return Ok(());
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
        let local = record.as_ref().map(|record| &record.fields);
        let held = local.and_then(|local| carried(kind, &key.record_id, local));
        let sides = Sides {
            base: base.as_ref().and_then(|base| base.fields.as_ref()),
            local: held.as_ref().or(local),
            server: None,
        };
        // Otherwise a content edit here revives the record: it stays, and with no base it goes up as a create. A
        // store in refill went back in time, so what differs from the base there is no edit.
        let goes = self.pull_wins.contains(&kind) || merge::merge(kind, Mode::Personal, sides) == Merged::Deleted;
        if record.is_some() && goes {
            self.plan(kind, key, Planned::Delete);
        }
        self.forget(key).await
    }

    // A copy this build cannot read goes by its id when its standing says it syncs, and a Local only one stays. Only
    // connections can be Local only, so another kind's copy with no standing recorded syncs. A connection with no
    // standing, or a profile, whose deletion unlinks connections a build has to read, waits for a build that reads it.
    async fn unreadable_deleted(
        &mut self,
        key: &RecordKey,
        kind: Kind,
        standing: Option<Standing>,
    ) -> Result<(), SyncError> {
        let standing = standing.or_else(|| (kind != Kind::Connection).then_some(Standing::Syncs));
        match standing {
            Some(Standing::Syncs) if !PROFILES.contains(&kind) => {
                self.plan(kind, key, Planned::Delete);
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
        let reason = match self.view(key, kind).await? {
            View::Stored(record) if record.standing == Standing::LocalOnly => return self.release(key).await,
            View::Unreadable(Some(Standing::LocalOnly)) => return self.release(key).await,
            View::NoAdapter => HeldReason::UnknownKind,
            View::Stored(_) | View::Unreadable(_) | View::Missing => HeldReason::Unreadable,
        };
        let record = PulledRecord {
            kind: key.kind.clone(),
            record_id: key.record_id.clone(),
            tag: ChangeTag::CloudKit(tag.unwrap_or_default()),
            fields: None,
            fields_json: None,
            deleted: None,
            service: None,
        };
        self.hold(key, reason, record).await
    }

    // The deletion is settled on both sides: no base, nothing held or waiting, a value awaiting approval included.
    async fn forget(&mut self, key: &RecordKey) -> Result<(), SyncError> {
        self.txn.delete(&RowKey::Base(key.clone())).await?;
        self.txn.delete(&RowKey::Deferred(key.clone())).await?;
        self.txn.delete(&RowKey::Held(key.clone())).await?;
        Ok(())
    }

    // The newer pulled state replaces whatever the row held, so the token never passes a change left unheld.
    async fn hold(&mut self, key: &RecordKey, reason: HeldReason, record: PulledRecord) -> Result<(), SyncError> {
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

    // A value awaiting approval is the approval queue's to settle.
    pub(super) async fn release(&mut self, key: &RecordKey) -> Result<(), SyncError> {
        let held = self.txn.get(&RowKey::Held(key.clone())).await?;
        if !matches!(
            held,
            Some(Row::Held(HeldRow {
                reason: HeldReason::AwaitingApproval,
                ..
            }))
        ) {
            self.txn.delete(&RowKey::Held(key.clone())).await?;
        }
        Ok(())
    }

    pub(super) async fn base(&mut self, key: &RecordKey) -> Result<Option<BaseRow>, SyncError> {
        Ok(match self.txn.get(&RowKey::Base(key.clone())).await? {
            Some(Row::Base(base)) => Some(base),
            _ => None,
        })
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
