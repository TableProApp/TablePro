// The end of a full fetch (0054, Rules for both providers). It lists every record the zone holds and no deletion, so
// a record it did not return was deleted, and a deletion that waited for its category applies once a fetch read that
// category. In a store that refills, the pull wins over what the store kept, and a record with no base, which the zone
// never saw, stays and goes up as a create.

use std::collections::BTreeSet;

use tablepro_records::Kind;

use super::copy::kind_of;
use super::settle::{Finish, Settle};
use super::{PROFILES, SCOPE};
use crate::api::error::SyncError;
use crate::api::ids::RecordKey;
use crate::api::state::{Row, RowKey, RowRange, Table};

impl Settle<'_, '_> {
    pub(super) async fn finish(&mut self, finish: &Finish) -> Result<(), SyncError> {
        self.deferred_due(&finish.listed).await?;
        self.unlisted(finish).await
    }

    // A deferred deletion of a record the zone lists again settles unapplied: the record was saved after it. A
    // profile's never applies late, since deleting one removes Keychain secrets no pull can bring back.
    async fn deferred_due(&mut self, listed: &BTreeSet<RecordKey>) -> Result<(), SyncError> {
        for row in self.txn.scan(&RowRange::Scope(Table::Deferred, SCOPE)).await? {
            let Row::Deferred(deferred) = row else {
                continue;
            };
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

    async fn unlisted(&mut self, finish: &Finish) -> Result<(), SyncError> {
        for row in self.txn.scan(&RowRange::Scope(Table::Bases, SCOPE)).await? {
            let Row::Base(base) = row else {
                continue;
            };
            if finish.listed.contains(&base.key) {
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

    // The stores that refilled are current again; the next fetch is a delta for them.
    pub(super) async fn refilled(&mut self, refill: &BTreeSet<Kind>) -> Result<(), SyncError> {
        let fetcher = self.fetcher;
        for kind in refill {
            if let Some(adapter) = fetcher.adapters.get(kind) {
                let stamp = adapter.identity().await?;
                self.note_stamp(adapter.store(), stamp, true).await?;
            }
        }
        Ok(())
    }
}
