// One batch of what the zone said (0054, A pass): each copy merged three ways against its base, the stores written,
// then the bases, the held and deferred sets and last the token, in one state commit. A batch that writes a store
// first commits its bases as pending rows (0064), with the approval queue's rows and the records it holds, so a crash
// before the last commit replays the batch and leaves what a store already took as it is, even once the zone changed
// again.

use std::collections::{BTreeMap, BTreeSet};

use serde_json::Value;
use tablepro_records::Kind;
use tablepro_records::merge::{self, Merged, Mode, Sides};

use super::copy::{Copy, Incoming, kind_of};
use super::pending::Staged;
use super::stores::{Local, Planned, carried, overlay};
use super::{Counts, Fetcher, PROFILES, SCOPE};
use crate::adapters::approval::{self, Gated};
use crate::api::adapter::{LocalChange, LocalRecord, StoreStamp};
use crate::api::error::{AdapterError, SyncError};
use crate::api::ids::{ChangeTag, Cursor, KindName, RecordKey};
use crate::api::state::{
    ApprovalRow, BaseRow, DeferredRow, HeldReason, HeldRow, Row, RowKey, ScopeRow, Standing, StateTxn,
};
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
    // The oldest creation date among the records the fetch returned, in milliseconds; None when it returned none.
    pub oldest_created_ms: Option<i64>,
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
    pub txn: Staged,
    pub counts: Counts,
    pub locals: BTreeMap<Kind, Option<Local>>,
    pub changes: BTreeMap<Kind, BTreeMap<String, LocalChange>>,
    pub pull_wins: BTreeSet<Kind>,
    // Each store's identity when the batch first read it, and a store written since.
    pub loaded: BTreeMap<String, StoreStamp>,
    pub moved: Option<String>,
    pub started: BTreeMap<String, StoreStamp>,
    // For each record the batch plans a store change for, what holds it if its store refuses the change.
    pub(super) undo: BTreeMap<RecordKey, Undo>,
}

// A record's rows as the batch found them, and the pulled copy or deletion it is held with if its store refuses it.
#[derive(Debug, Clone)]
pub(super) struct Undo {
    pub base: Option<BaseRow>,
    pub approvals: Vec<ApprovalRow>,
    pub record: PulledRecord,
}

// The rows a refused store change puts back, read before the approval queue moves them.
pub(super) struct Found {
    base: Option<BaseRow>,
    approvals: Vec<ApprovalRow>,
}

// What the store's copy becomes: the merge's record, or a deletion of the copy it holds.
fn local_change(record: Option<&LocalRecord>, merged: Merged) -> Option<Planned> {
    let kept = match merged {
        Merged::Record(fields)
        | Merged::Contested { record: fields, .. }
        | Merged::DeletionContested { kept: fields, .. } => Some(fields),
        Merged::Deleted => None,
        // Only an envelope is sealed again, and iCloud carries none.
        Merged::Reseal => return None,
    };
    match (kept, record) {
        (Some(fields), Some(record)) if record.fields == fields => None,
        (Some(fields), _) => Some(Planned::Put(fields)),
        (None, Some(_)) => Some(Planned::Delete),
        (None, None) => None,
    }
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
        if let Some(store) = settle.moved {
            return Ok(Err(store));
        }
        self.check_stop()?;
        if settle.changes.is_empty() {
            settle.clear_pending().await?;
        } else {
            let planned = settle.txn;
            settle.txn = planned.split(self.state).await?;
            self.check_stop()?;
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
        self.check_stop()?;
        settle.commit().await.map(Ok)
    }
}

impl<'s, 'f> Settle<'s, 'f> {
    pub(super) fn new(fetcher: &'s Fetcher<'f>, txn: Box<dyn StateTxn>, pull_wins: BTreeSet<Kind>) -> Self {
        Self {
            fetcher,
            txn: Staged::new(txn),
            counts: Counts::default(),
            locals: BTreeMap::new(),
            changes: BTreeMap::new(),
            pull_wins,
            loaded: BTreeMap::new(),
            moved: None,
            started: BTreeMap::new(),
            undo: BTreeMap::new(),
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
        let pull_wins = self.pull_wins.contains(&copy.kind);
        let merged = self
            .merged(copy.kind, &key, record.as_ref(), Some(&copy.fields), pull_wins)
            .await?;
        let stored = record.as_ref().map(|record| &record.fields);
        let found = self.found(&key).await?;
        match approval::gate(&mut self.txn, &key, copy.kind, stored, merged).await? {
            Gated::Apply(merged) => {
                if let Some(planned) = local_change(record.as_ref(), merged) {
                    self.plan_held(copy.kind, &key, planned, held_change(&copy), found);
                }
            }
            // Its base, the copy and its creation date, lands only with this held row (`Staged::split`), so nothing
            // reads the record's absence from the store as a deletion made here.
            Gated::Hold => {
                self.hold(&key, HeldReason::AwaitingApproval, held_change(&copy))
                    .await?;
            }
        }
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

    // What a pulled copy, or a deletion when `server` is None, leaves of the store's copy: the merge of what iCloud
    // carries of it against the base, put back on the local copy with what iCloud does not carry. In refill the pull
    // wins. The approval queue's sides keep a value that waits or was refused out of the device's side, as the
    // service's pull does; a caller that writes the result passes it through `approval::gate` first.
    pub(super) async fn merged(
        &mut self,
        kind: Kind,
        key: &RecordKey,
        record: Option<&LocalRecord>,
        server: Option<&Value>,
        pull_wins: bool,
    ) -> Result<Merged, SyncError> {
        let local = record.map(|record| &record.fields);
        let in_icloud = local.and_then(|local| carried(kind, &key.record_id, local));
        let merged = if pull_wins {
            server.map_or(Merged::Deleted, |server| Merged::Record(server.clone()))
        } else {
            let base = self.base(key).await?;
            let base = base.as_ref().and_then(|base| base.fields.as_ref());
            let (base, mine) =
                approval::merge_sides(&mut self.txn, key, kind, base, in_icloud.as_ref().or(local)).await?;
            let sides = Sides {
                base: base.as_ref(),
                local: mine.as_ref(),
                server,
            };
            merge::merge(kind, Mode::Personal, sides)
        };
        Ok(match (merged, local, &in_icloud) {
            (Merged::Record(fields), Some(local), Some(carried)) => Merged::Record(overlay(local, carried, &fields)),
            (merged, ..) => merged,
        })
    }

    async fn found(&mut self, key: &RecordKey) -> Result<Found, SyncError> {
        let base = match self.txn.get(&RowKey::Base(key.clone())).await? {
            Some(Row::Base(base)) => Some(base),
            _ => None,
        };
        let approvals = approval::rows_of(&mut self.txn, key).await?;
        Ok(Found { base, approvals })
    }

    // A planned store change, with what holds the record if its store refuses it: the rows the first change of it in
    // the batch found, and the latest pulled copy or deletion.
    fn plan_held(&mut self, kind: Kind, key: &RecordKey, planned: Planned, record: PulledRecord, found: Found) {
        self.undo
            .entry(key.clone())
            .and_modify(|undo| undo.record = record.clone())
            .or_insert(Undo {
                base: found.base,
                approvals: found.approvals,
                record,
            });
        self.plan(kind, key, planned);
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
        // Otherwise a content edit here revives the record: it stays, and with no base it goes up as a create. A
        // store in refill went back in time, so what differs from the base there is no edit.
        let pull_wins = self.pull_wins.contains(&kind);
        let merged = self.merged(kind, key, record.as_ref(), None, pull_wins).await?;
        let stored = record.as_ref().map(|record| &record.fields);
        let found = self.found(key).await?;
        let goes = matches!(
            approval::gate(&mut self.txn, key, kind, stored, merged).await?,
            Gated::Apply(Merged::Deleted)
        );
        if record.is_some() && goes {
            self.plan_held(kind, key, Planned::Delete, held_deletion(key), found);
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
                let found = self.found(key).await?;
                self.plan_held(kind, key, Planned::Delete, held_deletion(key), found);
                approval::gate(&mut self.txn, key, kind, None, Merged::Deleted).await?;
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
            // A record held whole stays held for the person, so it still merges as new to the device once it reads.
            View::Missing if approval::awaits(&mut self.txn, key).await? => HeldReason::AwaitingApproval,
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
    pub(super) async fn hold(
        &mut self,
        key: &RecordKey,
        reason: HeldReason,
        record: PulledRecord,
    ) -> Result<(), SyncError> {
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
