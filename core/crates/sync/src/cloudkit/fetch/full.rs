// The end of a full fetch (0054, Rules for both providers). It lists every record the zone holds and no deletion, so
// a record it did not return was deleted, and a deletion that waited for its category applies once a fetch read that
// category. In a store that refills, the pull wins over what the store kept, and a record with no base, which the zone
// never saw, stays and goes up as a create.

use std::collections::BTreeSet;

use super::copy::kind_of;
use super::settle::{Finish, Settle};
use super::{PROFILES, SCOPE};
use crate::api::error::SyncError;
use crate::api::ids::{KindName, RecordKey};
use crate::api::state::{Row, RowKey, RowRange, Table};

impl Settle<'_, '_> {
    pub(super) async fn finish(&mut self, finish: &Finish) -> Result<(), SyncError> {
        self.deferred_due(&finish.listed).await?;
        self.unlisted(finish).await?;
        self.copies_done().await
    }

    // A deferred deletion of a record the zone lists again settles unapplied: the record was saved after it. A
    // profile's never applies late, since deleting one removes Keychain secrets no pull can bring back. A copy a refill
    // kept while the kind was off is no deletion: the fetch's own listing judges the record, by `unlisted`'s rules,
    // which merge against the copy.
    async fn deferred_due(&mut self, listed: &BTreeSet<RecordKey>) -> Result<(), SyncError> {
        for row in self.txn.scan(&RowRange::Scope(Table::Deferred, SCOPE)).await? {
            let Row::Deferred(deferred) = row else {
                continue;
            };
            if deferred.record.deleted.is_none() {
                continue;
            }
            match kind_of(&deferred.key) {
                Some(kind) if !self.fetcher.categories.syncs(kind) => {}
                Some(kind) if !listed.contains(&deferred.key) && !PROFILES.contains(&kind) => {
                    self.deleted(&deferred.key).await?;
                }
                _ => self.txn.delete(&RowKey::Deferred(deferred.key)).await?,
            }
        }
        Ok(())
    }

    // The copies kept for kinds now on have served their merge, the listed ones and the inferred deletions alike.
    async fn copies_done(&mut self) -> Result<(), SyncError> {
        for row in self.txn.scan(&RowRange::Scope(Table::Deferred, SCOPE)).await? {
            let Row::Deferred(deferred) = row else {
                continue;
            };
            let on = kind_of(&deferred.key).is_none_or(|kind| self.fetcher.categories.syncs(kind));
            if deferred.record.deleted.is_none() && on {
                self.txn.delete(&RowKey::Deferred(deferred.key)).await?;
            }
        }
        Ok(())
    }

    // A zone deleted and made again holds only records created after it was made, so a base created no earlier than
    // the oldest record the fetch returned belongs to the zone this fetch read, and its absence proves it was deleted
    // there. A fetch that returned no dated record proves nothing: it is as likely a zone made again elsewhere, or a
    // short answer, as a zone emptied record by record. A base with no creation date is never inferred deleted.
    async fn unlisted(&mut self, finish: &Finish) -> Result<(), SyncError> {
        let Some(oldest) = finish.oldest_created_ms else {
            return Ok(());
        };
        for row in self.txn.scan(&RowRange::Scope(Table::Bases, SCOPE)).await? {
            let Row::Base(base) = row else {
                continue;
            };
            if finish.listed.contains(&base.key) || base.created_ms.is_none_or(|created| created < oldest) {
                continue;
            }
            let Some(kind) = kind_of(&base.key) else {
                continue;
            };
            let inferred = self.fetcher.categories.syncs(kind)
                && self.fetcher.adapters.contains_key(&kind)
                && !PROFILES.contains(&kind);
            if inferred {
                self.counts.inferred += 1;
                self.deleted(&base.key).await?;
            }
        }
        Ok(())
    }

    // The kinds that refilled owe nothing more, unless their store was restored or replaced once more while the fetch
    // ran: then the mark stays and the next fetch refills them again. A kind that is off keeps its mark.
    pub(super) async fn refilled(&mut self, finish: &Finish) -> Result<(), SyncError> {
        let fetcher = self.fetcher;
        for kind in &finish.refill {
            let Some(adapter) = fetcher.adapters.get(kind) else {
                continue;
            };
            let store = adapter.store();
            let now = adapter.identity().await?;
            let unchanged = finish
                .started
                .get(store)
                .is_some_and(|started| started.generation == now.generation && started.sequence <= now.sequence);
            if unchanged {
                self.note_stamp(store, now, true).await?;
                self.txn
                    .delete(&RowKey::StoresKind(store.to_owned(), KindName::of(*kind)))
                    .await?;
            }
        }
        Ok(())
    }
}
