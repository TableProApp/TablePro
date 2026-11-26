// The zone's place in the state file (0054, Rules for both providers: a removed zone clears the state, and Upload Again
// asks before anything is sent). The scope row says this device saw the zone. Only a device that never saw it makes
// it, so a zone the person removed in iCloud settings, or another device deleted, is never filled again on the app's
// own initiative, after a restart too, as Apple asks.

use super::SCOPE;
use crate::api::error::SyncError;
use crate::api::state::{HeldReason, Row, RowKey, RowRange, ScopeRow, StateStore, StateTxn, Table};

pub(super) async fn seen(state: &dyn StateStore) -> Result<bool, SyncError> {
    let mut txn = state.begin().await?;
    Ok(matches!(txn.get(&RowKey::Scope(SCOPE)).await?, Some(Row::Scope(_))))
}

// The zone exists: this device made it or found it.
pub(super) async fn saw(state: &dyn StateStore) -> Result<(), SyncError> {
    let mut txn = state.begin().await?;
    if txn.get(&RowKey::Scope(SCOPE)).await?.is_none() {
        txn.put(Row::Scope(ScopeRow::new(SCOPE))).await?;
        txn.commit().await?;
    }
    Ok(())
}

// What the state knew of the zone's records: their bases, those pending, the changes held for them, the deletions
// waiting and the token. A value waiting for the person is the approval queue's. Standing is this device's own.
async fn clear(txn: &mut dyn StateTxn) -> Result<(), SyncError> {
    for table in [Table::Bases, Table::PendingBases, Table::Deferred] {
        for row in txn.scan(&RowRange::Scope(table, SCOPE)).await? {
            txn.delete(&row.key()).await?;
        }
    }
    for row in txn.scan(&RowRange::Scope(Table::Held, SCOPE)).await? {
        if let Row::Held(held) = &row
            && held.reason != HeldReason::AwaitingApproval
        {
            txn.delete(&row.key()).await?;
        }
    }
    Ok(())
}

// A state file the open found restored or uncertain trusts none of its sync tables: the next fetch reads the zone whole
// and the pull wins (0054, A stale file).
pub(super) async fn refill(state: &dyn StateStore) -> Result<(), SyncError> {
    let mut txn = state.begin().await?;
    if let Some(Row::Scope(mut scope)) = txn.get(&RowKey::Scope(SCOPE)).await?
        && !scope.refill
    {
        scope.refill = true;
        txn.put(Row::Scope(scope)).await?;
        txn.commit().await?;
    }
    Ok(())
}

// The zone is gone. Its scope row stays, empty, so the next pass knows it was removed rather than never made.
pub(super) async fn removed(state: &dyn StateStore) -> Result<(), SyncError> {
    let mut txn = state.begin().await?;
    clear(txn.as_mut()).await?;
    txn.put(Row::Scope(ScopeRow::new(SCOPE))).await?;
    txn.commit().await?;
    Ok(())
}

// Upload Again: the next pass makes the zone and everything this device holds goes up from a full fetch.
pub(super) async fn upload_again(state: &dyn StateStore) -> Result<(), SyncError> {
    let mut txn = state.begin().await?;
    clear(txn.as_mut()).await?;
    txn.delete(&RowKey::Scope(SCOPE)).await?;
    txn.commit().await?;
    Ok(())
}
