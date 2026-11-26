use tablepro_records::Kind;

use super::{ServiceSync, Session, begin};
use crate::api::error::SyncError;
use crate::api::ids::ScopeName;
use crate::api::scopes::{ScopeInfo, ScopePolicies, ScopesAnswer, ScopesBody};
use crate::api::state::{Row, RowKey, ScopeRow};
use crate::api::transport::{Proof, TransportError};

impl ServiceSync {
    // `GET /v2/sync/scopes` with the last body's ETag; 304 keeps the body this session holds. The proof makes the
    // server say whether this device is approved.
    pub(super) async fn poll_scopes(&self, session: &mut Session) -> Result<ScopesBody, SyncError> {
        let proof = self.keys.dpop_key().await?.map_or(Proof::None, Proof::Dpop);
        let held = session.body.is_some().then(|| session.etag.clone()).flatten();
        match self.transport.scopes(held, proof).await? {
            ScopesAnswer::Body { body, etag } => {
                session.etag = Some(etag);
                session.body = Some(*body);
            }
            ScopesAnswer::NotModified => {}
        }
        session.body.clone().ok_or(SyncError::Transport(TransportError::Server {
            status: 304,
            code: "not_modified_without_body".to_owned(),
            retry_after_ms: None,
        }))
    }

    pub(super) async fn scope_row(&self, scope: ScopeName) -> Result<Option<ScopeRow>, SyncError> {
        let mut txn = begin(&self.state).await?;
        match txn.get(&RowKey::Scope(scope)).await? {
            Some(Row::Scope(row)) => Ok(Some(row)),
            _ => Ok(None),
        }
    }
}

// What the scopes body says of a scope, which a pull keeps in its row. The epoch and lineage are adopted only once a
// refill against them is done.
pub(super) fn refresh(row: &mut ScopeRow, info: &ScopeInfo) {
    row.role = info.role;
    row.horizon = Some(info.horizon);
    row.policies = info.policies;
    row.rotation_due = info.rotation_due;
}

// A kind a switch turns off in the scope sends nothing (0051, Policies). Key objects sync whatever `personal_sync` says.
pub(super) fn kind_off(policies: ScopePolicies, scope: ScopeName, kind: Kind) -> bool {
    let off = |switch: Option<bool>| switch == Some(false);
    match scope {
        ScopeName::Personal => {
            !kind.is_key()
                && (off(policies.personal_sync) || (kind == Kind::SecretEnvelope && off(policies.password_sync)))
        }
        ScopeName::History => kind == Kind::HistoryEntry && (off(policies.personal_sync) || off(policies.history_sync)),
        ScopeName::Team(_) => kind == Kind::SecretEnvelope && off(policies.password_sync),
    }
}
