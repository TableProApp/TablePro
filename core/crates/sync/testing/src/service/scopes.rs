// `GET /v2/sync/scopes`, the calls beyond pull and push, and the transport traits over them.

use async_trait::async_trait;
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use sha2::{Digest, Sha256};
use tablepro_keys::encoding::{TeamId, Version};
use tablepro_sync::api::ids::{DeviceRowId, ScopeName};
use tablepro_sync::api::scopes::{
    LineageEpoch, ScopeInfo, ScopePolicies, ScopesAnswer, ScopesBody, ServerLimits, StopReport, TeamMember,
};
use tablepro_sync::api::transport::{
    DpopKey, Proof, PullRequest, PulledPage, PushAnswer, PushBatch, ServiceTransport, StepUpChallenge, Transport,
    TransportError,
};

use super::{Approval, FakeClient, ScopeOwner, State};

pub const STEP_UP_ACR: &str = "urn:tablepro:acr:passkey";

impl FakeClient {
    fn body(&self, state: &State, proof: &Proof) -> ScopesBody {
        let approved = match self.approval(state, proof) {
            Approval::NoProof => None,
            approval => Some(approval == Approval::Approved),
        };
        let mut scopes = vec![
            self.scope_info(state, ScopeName::Personal, approved),
            self.scope_info(state, ScopeName::History, approved),
        ];
        let teams = state
            .teams
            .iter()
            .filter(|(_, team)| team.members.contains_key(&self.account))
            .map(|(team, _)| *team);
        scopes.extend(teams.map(|team| self.scope_info(state, ScopeName::Team(team), None)));
        ScopesBody {
            epoch: state.epoch(),
            scopes,
            limits: ServerLimits::ADR_0051,
            server_version: "fake".to_owned(),
            capabilities: Vec::new(),
            idempotency_retention_secs: 86_400,
            poll_interval_secs: 60,
        }
    }

    fn scope_info(&self, state: &State, scope: ScopeName, approved: Option<bool>) -> ScopeInfo {
        let owner = ScopeOwner::of(scope, self.account);
        let policies = state.policies;
        let (role, rotation_due, members, stopped, policies) = match scope {
            ScopeName::Team(team) => {
                let data = state.teams.get(&team);
                let role = self.role(state, scope);
                let members = data.map_or_else(Vec::new, |data| {
                    data.members
                        .iter()
                        .map(|(account, role)| TeamMember {
                            account: *account,
                            role: *role,
                        })
                        .collect()
                });
                let stopped = if role.is_some_and(|role| role.manages_keys()) {
                    team_reports(state, team)
                } else {
                    Vec::new()
                };
                let password = policies.password_sync && data.is_some_and(|data| data.password_sync);
                let policies = ScopePolicies {
                    password_sync: Some(password),
                    ..ScopePolicies::default()
                };
                (
                    role,
                    data.is_some_and(|data| data.rotation_due),
                    members,
                    stopped,
                    policies,
                )
            }
            ScopeName::Personal => {
                let policies = ScopePolicies {
                    personal_sync: Some(policies.personal_sync),
                    password_sync: Some(policies.password_sync),
                    history_sync: None,
                };
                (None, false, Vec::new(), Vec::new(), policies)
            }
            ScopeName::History => {
                let policies = ScopePolicies {
                    personal_sync: Some(policies.personal_sync),
                    password_sync: None,
                    history_sync: Some(policies.history_sync),
                };
                (None, false, Vec::new(), Vec::new(), policies)
            }
        };
        ScopeInfo {
            scope,
            role,
            horizon: state.scopes.get(&owner).map_or(0, super::ScopeData::horizon),
            epochs: state
                .lineage
                .iter()
                .map(|epoch| LineageEpoch {
                    id: epoch.id,
                    kept_revision: epoch.cuts.get(&owner).copied().unwrap_or(0),
                })
                .collect(),
            writable: !state.lapsed,
            policies,
            quota: None,
            rotation_due,
            members,
            stopped,
            approved: if matches!(scope, ScopeName::Team(_)) {
                None
            } else {
                approved
            },
        }
    }

    fn stop_gate(&self, state: &mut State, team: TeamId, proof: &DpopKey) -> Result<(), TransportError> {
        self.admit(state, Some(ScopeName::Team(team)))?;
        if self.approval(state, &Proof::Dpop(proof.clone())) != Approval::Approved {
            return Err(TransportError::DeviceNotApproved);
        }
        Ok(())
    }
}

// Tombstones each pending `key.reset` of the account whose proposed device's DSK is `key`.
fn end_resets_proposed_under(state: &mut State, account: tablepro_keys::encoding::AccountId, key: &[u8; 32]) {
    let owner = ScopeOwner::Personal(account);
    let ids: Vec<(String, String)> = state.scopes.get(&owner).map_or_else(Vec::new, |data| {
        data.records
            .iter()
            .filter(|(_, record)| record.kind.as_str() == "key.reset" && record.deleted.is_none())
            .filter(|(_, record)| {
                record
                    .fields
                    .as_ref()
                    .and_then(|fields| fields.get("device"))
                    .and_then(|device| super::push::key_field(device, "dsk"))
                    == Some(*key)
            })
            .map(|(id, _)| id.clone())
            .collect()
    });
    for id in ids {
        let revision = state.take_revision();
        let epoch = state.epoch();
        let now = state.clock_us;
        if let Some(record) = state.scopes.get_mut(&owner).and_then(|data| data.records.get_mut(&id)) {
            record.version += 1;
            record.revision = revision;
            record.written_epoch = epoch;
            record.write_tag = *uuid::Uuid::new_v4().as_bytes();
            record.deleted = Some(tablepro_sync::api::transport::DeletedReason::User);
            record.fields = None;
            record.updated_at_us = now;
        }
    }
}

fn team_reports(state: &State, team: TeamId) -> Vec<StopReport> {
    state
        .stopped
        .iter()
        .filter(|((reported, _), _)| *reported == team)
        .map(|(_, report)| report.clone())
        .collect()
}

#[async_trait]
impl Transport for FakeClient {
    async fn pull(&self, request: PullRequest) -> Result<PulledPage, TransportError> {
        self.pull_page(&request)
    }

    async fn push(&self, batch: PushBatch) -> Result<PushAnswer, TransportError> {
        self.push_batch(&batch)
    }
}

#[async_trait]
impl ServiceTransport for FakeClient {
    async fn scopes(&self, if_none_match: Option<String>, proof: Proof) -> Result<ScopesAnswer, TransportError> {
        let mut state = self.server.lock();
        self.admit(&mut state, None)?;
        let body = self.body(&state, &proof);
        let digest = Sha256::digest(format!("{body:?}").as_bytes());
        let etag = format!("\"{}\"", URL_SAFE_NO_PAD.encode(digest));
        if if_none_match.as_deref() == Some(etag.as_str()) {
            return Ok(ScopesAnswer::NotModified);
        }
        Ok(ScopesAnswer::Body {
            body: Box::new(body),
            etag,
        })
    }

    async fn revoke_key_device(&self, proof: DpopKey) -> Result<(), TransportError> {
        let mut state = self.server.lock();
        self.admit(&mut state, None)?;
        // Taken from any signed-in device; it clears the row's key device only under that key device's own DSK, and
        // ends a pending reset only under the DSK its `key.reset` names (0051, Sign Out).
        let key = super::push::proof_key(&Proof::Dpop(proof.clone()));
        if self.approval(&state, &Proof::Dpop(proof)) == Approval::Approved {
            state.approved.remove(&self.device_row);
        }
        if let Some(key) = key {
            end_resets_proposed_under(&mut state, self.account, &key);
        }
        Ok(())
    }

    async fn report_stopped(&self, team: TeamId, version: Version, proof: DpopKey) -> Result<(), TransportError> {
        let mut state = self.server.lock();
        self.stop_gate(&mut state, team, &proof)?;
        let report = StopReport {
            account: self.account,
            device: self.device_row.clone(),
            version,
        };
        state.stopped.insert((team, self.device_row.clone()), report);
        Ok(())
    }

    async fn withdraw_stopped(&self, team: TeamId, proof: DpopKey) -> Result<(), TransportError> {
        let mut state = self.server.lock();
        self.stop_gate(&mut state, team, &proof)?;
        state.stopped.remove(&(team, self.device_row.clone()));
        Ok(())
    }

    async fn remove_device_row(&self, device: DeviceRowId, proof: DpopKey) -> Result<(), TransportError> {
        let mut state = self.server.lock();
        self.admit(&mut state, None)?;
        if self.approval(&state, &Proof::Dpop(proof)) != Approval::Approved {
            return Err(TransportError::DeviceNotApproved);
        }
        // Only a row of the caller's own account, and only on a sign-in with a fresh step-up.
        if state.rows.get(&device) != Some(&self.account) {
            return Err(TransportError::NotFound);
        }
        if !state.stepped_up.contains(&self.device_row) {
            return Err(TransportError::StepUpRequired(StepUpChallenge {
                acr_values: vec![STEP_UP_ACR.to_owned()],
                max_age_secs: 300,
            }));
        }
        state.approved.remove(&device);
        state.removed_rows.insert(device.clone());
        state.stopped.retain(|(_, row), _| *row != device);
        Ok(())
    }
}
