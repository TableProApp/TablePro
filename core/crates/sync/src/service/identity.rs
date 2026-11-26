// Another account or server (0054, Moving between providers; orchestrator ruling on 0066): nothing personal goes up
// until the person picks Move my data or Start empty, after a restart too. The personal scope's row holds the wait;
// team scopes hold no data of the last account and go on.

use std::collections::HashSet;
use std::sync::Arc;

use super::{ServiceSync, begin};
use crate::adapters::approval;
use crate::api::adapter::LocalChange;
use crate::api::control::{NewIdentityChoice, NewIdentityPlan, PassReason};
use crate::api::error::SyncError;
use crate::api::ids::{KindName, ScopeName};
use crate::api::state::{
    HeldReason, PushWait, Row, RowKey, RowRange, ScopeRow, Standing, StateIdentity, StateStore, Table,
};
use crate::engine::{Adapters, diff};

// The scopes that hold this person's own data, which the choice decides about.
const OWN: [ScopeName; 2] = [ScopeName::Personal, ScopeName::History];

// The changes a state file holds that never went up: each own scope's stores against its bases, counted with the
// diff a push builds. The opener counts them in the last account's file, for the prompt.
pub async fn unsent_changes(state: &Arc<dyn StateStore>, adapters: &Adapters) -> Result<u64, SyncError> {
    let mut unsent = 0_u64;
    for scope in OWN {
        let held = approval::held_members(begin(state).await?.as_mut(), scope).await?;
        for adapter in adapters.in_scope(scope) {
            let kind = adapter.kind();
            let rows = begin(state)
                .await?
                .scan(&RowRange::ScopeKind(Table::Bases, scope, KindName::of(kind)))
                .await?;
            let bases: Vec<_> = rows
                .into_iter()
                .filter_map(|row| match row {
                    Row::Base(base) => Some(base),
                    _ => None,
                })
                .collect();
            let local = super::push::going_up(kind, scope, adapter.records(scope).await?, &bases, &held);
            let pending = diff(scope, kind, &local, &bases, &HashSet::new()).pending.len();
            unsent = unsent.saturating_add(u64::try_from(pending).unwrap_or(u64::MAX));
        }
    }
    Ok(unsent)
}

impl ServiceSync {
    // The account the choice is for, as the plan names it and the answer names it back.
    fn shown_for(&self) -> String {
        match self.state.identity() {
            StateIdentity::Service { origin, account, .. } => format!("{}/{}", origin.as_str(), account.to_wire()),
            StateIdentity::ICloud { user_record_name } => user_record_name.clone(),
        }
    }

    // A file new to this account, on a device that synced with another account or server, waits for the choice
    // before its first pull writes the personal row.
    pub(super) async fn owe_account_choice(&self) -> Result<(), SyncError> {
        let Some(unsent) = self.follows else {
            return Ok(());
        };
        if self.scope_row(ScopeName::Personal).await?.is_some() {
            return Ok(());
        }
        self.stop.check()?;
        let mut txn = begin(&self.state).await?;
        txn.put(Row::Scope(ScopeRow {
            push_wait: Some(PushWait::AccountChoice { unsent }),
            ..ScopeRow::new(ScopeName::Personal)
        }))
        .await?;
        txn.commit().await?;
        Ok(())
    }

    // What the push of this person's own scopes waits for.
    pub(super) async fn own_push_wait(&self) -> Result<Option<PushWait>, SyncError> {
        Ok(self.scope_row(ScopeName::Personal).await?.and_then(|row| row.push_wait))
    }

    pub(super) async fn plan_choice(&self) -> Result<NewIdentityPlan, SyncError> {
        match self.own_push_wait().await? {
            Some(PushWait::AccountChoice { unsent }) => Ok(NewIdentityPlan {
                unsent,
                account: self.shown_for(),
            }),
            _ => Err(SyncError::NotAllowed {
                what: "choose for a new account",
            }),
        }
    }

    // Move my data clears the wait, and the pass after it sends what this device holds. Start empty first takes the
    // synced records of the own scopes off this device, where the last account keeps them, keeps the Local only ones,
    // and forgets what the file knew of those scopes, so the pass fills the device from a snapshot. The wait clears
    // last, so a crash before asks again.
    pub(super) async fn answer_choice(&self, choice: NewIdentityChoice, account: &str) -> Result<(), SyncError> {
        {
            let _session = self.session.lock().await;
            if !matches!(self.own_push_wait().await?, Some(PushWait::AccountChoice { .. })) {
                return Err(SyncError::NotAllowed {
                    what: "choose for a new account",
                });
            }
            if account != self.shown_for() {
                return Err(SyncError::Changed { what: "account" });
            }
            if choice == NewIdentityChoice::StartEmpty {
                self.forget_own_scopes().await?;
                self.leave_synced_records().await?;
            }
            self.stop.check()?;
            let mut txn = begin(&self.state).await?;
            if let Some(Row::Scope(row)) = txn.get(&RowKey::Scope(ScopeName::Personal)).await? {
                txn.put(Row::Scope(ScopeRow { push_wait: None, ..row })).await?;
            }
            txn.commit().await?;
        }
        self.run_pass(PassReason::Person).await.map(|_| ())
    }

    async fn forget_own_scopes(&self) -> Result<(), SyncError> {
        self.stop.check()?;
        let mut txn = begin(&self.state).await?;
        for scope in OWN {
            for table in [Table::Bases, Table::PendingBases, Table::Deferred, Table::Refused] {
                for row in txn.scan(&RowRange::Scope(table, scope)).await? {
                    txn.delete(&row.key()).await?;
                }
            }
            for row in txn.scan(&RowRange::Scope(Table::Held, scope)).await? {
                if let Row::Held(held) = &row
                    && held.reason != HeldReason::AwaitingApproval
                {
                    txn.delete(&row.key()).await?;
                }
            }
            if let Some(Row::Scope(row)) = txn.get(&RowKey::Scope(scope)).await? {
                txn.put(Row::Scope(ScopeRow {
                    cursor: None,
                    caught_up: false,
                    ..row
                }))
                .await?;
            }
        }
        txn.commit().await?;
        Ok(())
    }

    async fn leave_synced_records(&self) -> Result<(), SyncError> {
        for scope in OWN {
            for adapter in self.adapters.in_scope(scope) {
                let leaving: Vec<LocalChange> = adapter
                    .records(scope)
                    .await?
                    .records
                    .into_iter()
                    .filter(|record| record.standing == Standing::Syncs)
                    .map(|record| LocalChange::Delete {
                        record_id: record.record_id,
                    })
                    .collect();
                if !leaving.is_empty() {
                    self.stop.check()?;
                    adapter.apply(scope, leaving).await?;
                }
            }
        }
        Ok(())
    }
}
