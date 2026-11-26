// The crash window between a store write and the state commit that follows it (0064, `pending_bases`). A batch that
// writes a store first commits the bases it brings as pending rows, with the waiting values and the records it holds
// whole, then writes the store, then commits the bases, the token and the rest, which clears them. At a restart a
// pending base whose store copy is what that pull leaves becomes the base; any other is dropped, and the store's copy
// stays an edit against the base it had. A pull the store took is then no local edit, even when the zone changes again
// before the replay, and the store's value in a member that waits is never read as the device's edit of it.

use std::collections::{BTreeMap, BTreeSet};

use async_trait::async_trait;
use tablepro_records::merge::Merged;

use super::copy::kind_of;
use super::settle::{Settle, View};
use super::{Fetcher, SCOPE};
use crate::adapters::approval;
use crate::api::adapter::LocalRecord;
use crate::api::error::{StateError, SyncError};
use crate::api::ids::{ChangeTag, RecordKey};
use crate::api::state::{BaseRow, Committed, Row, RowKey, RowRange, Standing, StateStore, StateTxn, Table};
use crate::api::transport::DeletedReason;

#[derive(Debug, Clone)]
enum Write {
    Put(Box<Row>),
    Delete(RowKey),
}

// A batch's transaction, keeping its writes so they can go into the commit after the store write.
pub(super) struct Staged {
    inner: Box<dyn StateTxn>,
    writes: Vec<Write>,
}

impl Staged {
    pub(super) fn new(inner: Box<dyn StateTxn>) -> Self {
        Self {
            inner,
            writes: Vec::new(),
        }
    }

    pub(super) async fn get(&mut self, key: &RowKey) -> Result<Option<Row>, StateError> {
        self.inner.get(key).await
    }

    pub(super) async fn scan(&mut self, range: &RowRange) -> Result<Vec<Row>, StateError> {
        self.inner.scan(range).await
    }

    pub(super) async fn put(&mut self, row: Row) -> Result<(), StateError> {
        self.inner.put(row.clone()).await?;
        self.writes.push(Write::Put(Box::new(row)));
        Ok(())
    }

    pub(super) async fn delete(&mut self, key: &RowKey) -> Result<(), StateError> {
        self.inner.delete(key).await?;
        self.writes.push(Write::Delete(key.clone()));
        Ok(())
    }

    pub(super) async fn commit(self) -> Result<Committed, StateError> {
        self.inner.commit().await
    }

    // Each base the batch puts or removes, as it last left it.
    fn bases(&self) -> BTreeMap<RecordKey, Option<BaseRow>> {
        let mut bases = BTreeMap::new();
        for write in &self.writes {
            match write {
                Write::Put(row) => {
                    if let Row::Base(base) = row.as_ref() {
                        bases.insert(base.key.clone(), Some(base.clone()));
                    }
                }
                Write::Delete(RowKey::Base(key)) => {
                    bases.insert(key.clone(), None);
                }
                Write::Delete(_) => {}
            }
        }
        bases
    }

    // Rolls the batch's transaction back, commits its bases as pending rows in one of their own with the approval and
    // held rows it adds, and opens the transaction the batch commits after its store write, with every planned write in
    // it again and the pending rows cleared. The rolled back transaction goes first, since SQLite keeps one writer at a
    // time.
    pub(super) async fn split(self, state: &dyn StateStore) -> Result<Self, SyncError> {
        let pending = self.bases();
        let Self { inner, writes } = self;
        drop(inner);
        let mut staged = state.begin().await?;
        for row in staged.scan(&RowRange::Scope(Table::PendingBases, SCOPE)).await? {
            staged.delete(&row.key()).await?;
        }
        for (key, base) in &pending {
            let row = base.clone().unwrap_or_else(|| removal(key));
            staged.put(Row::PendingBase(row)).await?;
        }
        // A settle after a crash reads them: without them a held record reads as one the store dropped, and the store's
        // value in a member that waits as the device's own edit. Only what holds a value back goes early: a row the
        // batch removes stays until the store took what lets it go.
        for write in &writes {
            if let Write::Put(row) = write
                && matches!(row.as_ref(), Row::Approval(_) | Row::Held(_))
            {
                staged.put(row.as_ref().clone()).await?;
            }
        }
        staged.commit().await?;
        let mut next = Self::new(state.begin().await?);
        for write in writes {
            match write {
                Write::Put(row) => next.put(*row).await?,
                Write::Delete(key) => next.delete(&key).await?,
            }
        }
        for key in pending.into_keys() {
            next.delete(&RowKey::PendingBase(key)).await?;
        }
        Ok(next)
    }
}

// The approval queue writes its rows through the batch's transaction, so they go into the commit after the store write
// too.
#[async_trait]
impl StateTxn for Staged {
    async fn get(&mut self, key: &RowKey) -> Result<Option<Row>, StateError> {
        Staged::get(self, key).await
    }

    async fn scan(&mut self, range: &RowRange) -> Result<Vec<Row>, StateError> {
        Staged::scan(self, range).await
    }

    async fn put(&mut self, row: Row) -> Result<(), StateError> {
        Staged::put(self, row).await
    }

    async fn delete(&mut self, key: &RowKey) -> Result<(), StateError> {
        Staged::delete(self, key).await
    }

    // An iCloud file has no key tables.
    async fn clear_key_tables(&mut self) -> Result<(), StateError> {
        Ok(())
    }

    async fn commit(self: Box<Self>) -> Result<Committed, StateError> {
        Staged::commit(*self).await
    }
}

// A base the pull removes. iCloud keeps no tombstone bases, so a deletion mark on a pending row can only mean this.
fn removal(key: &RecordKey) -> BaseRow {
    BaseRow {
        key: key.clone(),
        tag: ChangeTag::CloudKit(Vec::new()),
        version: None,
        revision: None,
        epoch: None,
        deleted: Some(DeletedReason::User),
        fields: None,
        created_ms: None,
    }
}

// Whether the store holds what a merge leaves.
fn holds(record: Option<&LocalRecord>, merged: &Merged) -> bool {
    match merged {
        Merged::Record(fields)
        | Merged::Contested { record: fields, .. }
        | Merged::DeletionContested { kept: fields, .. } => record.is_some_and(|record| record.fields == *fields),
        Merged::Deleted => record.is_none(),
        Merged::Reseal => false,
    }
}

impl Settle<'_, '_> {
    // A batch that writes no store commits once, and what an earlier attempt of it staged no longer stands.
    pub(super) async fn clear_pending(&mut self) -> Result<(), SyncError> {
        for row in self.txn.scan(&RowRange::Scope(Table::PendingBases, SCOPE)).await? {
            self.txn.delete(&row.key()).await?;
        }
        Ok(())
    }

    // The pull left the store as it is now: merging it again against the base the state still holds would write
    // nothing. A copy this build cannot read proves nothing, so its base stays.
    async fn took(&mut self, pending: &BaseRow) -> Result<bool, SyncError> {
        let Some(kind) = kind_of(&pending.key) else {
            return Ok(false);
        };
        let record = match self.view(&pending.key, kind).await? {
            View::Stored(record) => Some(record),
            View::Missing => None,
            View::NoAdapter | View::Unreadable(_) => return Ok(false),
        };
        // A pull leaves a Local only copy alone and keeps no base for it.
        if record
            .as_ref()
            .is_some_and(|record| record.standing == Standing::LocalOnly)
        {
            return Ok(pending.deleted.is_some());
        }
        let server = match (&pending.deleted, &pending.fields) {
            (Some(_), _) => None,
            (None, Some(fields)) => Some(fields),
            (None, None) => return Ok(false),
        };
        let merged = self.merged(kind, &pending.key, record.as_ref(), server, false).await?;
        let (Merged::Record(fields) | Merged::Contested { record: fields, .. }) = &merged else {
            return Ok(holds(record.as_ref(), &merged));
        };
        // The store took what the approval queue left of the merge, and nothing of a new record it holds whole. That
        // record's held row committed with this base, so its base reads as no deletion here, and it keeps the copy's
        // creation date a full fetch infers a deletion by.
        let rows = approval::rows_of(&mut self.txn, &pending.key).await?;
        let split = approval::split(
            kind,
            &pending.key,
            record.as_ref().map(|record| &record.fields),
            fields,
            &rows,
        );
        Ok(if split.hold {
            record.is_none()
        } else {
            record.is_some_and(|record| record.fields == split.fields)
        })
    }
}

impl Fetcher<'_> {
    // Settles what a crash left in `pending_bases`, before anything reads the bases: the fetch, a rebase, a push.
    pub async fn settle_pending(&self) -> Result<(), SyncError> {
        let txn = self.state.begin().await?;
        let mut settle = Settle::new(self, txn, BTreeSet::new());
        let rows = settle.txn.scan(&RowRange::Scope(Table::PendingBases, SCOPE)).await?;
        if rows.is_empty() {
            return Ok(());
        }
        for row in rows {
            let Row::PendingBase(pending) = row else {
                continue;
            };
            let key = pending.key.clone();
            if settle.took(&pending).await? {
                match pending.deleted {
                    Some(_) => settle.txn.delete(&RowKey::Base(key.clone())).await?,
                    None => settle.txn.put(Row::Base(pending)).await?,
                }
            }
            settle.txn.delete(&RowKey::PendingBase(key)).await?;
        }
        self.check_stop()?;
        settle.txn.commit().await?;
        Ok(())
    }
}
