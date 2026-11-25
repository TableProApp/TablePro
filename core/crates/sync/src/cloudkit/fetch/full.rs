// The end of a full fetch (0054, Rules for both providers). It lists every record the zone holds and no deletion, so
// a record it did not return was deleted, and a deletion that waited for its category applies once a fetch read that
// category. In a store that refills, the pull wins over what the store kept, and a record with no base, which the zone
// never saw, stays and goes up as a create.

use std::collections::BTreeSet;

use super::copy::kind_of;
use super::settle::{Finish, Settle};
use super::{PROFILES, SCOPE, identity_row};
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

    // A fetch that listed nothing proves nothing: it is as likely a zone made again elsewhere, or a short answer, as
    // a zone emptied record by record.
    async fn unlisted(&mut self, finish: &Finish) -> Result<(), SyncError> {
        if finish.listed.is_empty() {
            return Ok(());
        }
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

    // The kinds that refilled are current again, unless their store was restored or replaced once more while the fetch
    // ran: then the row stays and the next fetch refills it again.
    pub(super) async fn refilled(&mut self, finish: &Finish) -> Result<(), SyncError> {
        let fetcher = self.fetcher;
        for kind in &finish.refill {
            let Some(adapter) = fetcher.adapters.get(kind) else {
                continue;
            };
            let row = identity_row(*kind, adapter.store());
            let now = adapter.identity().await?;
            let unchanged = finish
                .started
                .get(&row)
                .is_some_and(|started| started.generation == now.generation && started.sequence <= now.sequence);
            if unchanged {
                self.note_stamp(&row, now, true).await?;
            } else if finish.scope_refilled {
                // The scope's own refill ends with this commit, so the row has to say that this kind still refills.
                self.refill_later(&row).await?;
            }
        }
        if finish.scope_refilled {
            for row in &finish.refill_later {
                self.refill_later(row).await?;
            }
        }
        Ok(())
    }
}
