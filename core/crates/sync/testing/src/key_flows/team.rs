use async_trait::async_trait;
use secrecy::{ExposeSecret, SecretString};
use serde_json::{Value, json};
use tablepro_keys::KeysError;
use tablepro_keys::encoding::{AccountId, TeamId, Version};
use tablepro_keys::envelope::EnvelopeId;
use tablepro_sync::api::error::SyncError;
use tablepro_sync::api::ids::{EpochId, ScopeName};
use tablepro_sync::api::key_flows::{
    KeyApplied, KeyArrival, KeyChangeSet, KeyNoticeKind, KeyState, LockCause, MemberKeyStatus, MemberKeys,
    OpenedEnvelope, PushBackVerdict, RestoreFlows, Roster, StopAction, StopFlows, TeamFlows, TeamKeys,
};
use tablepro_sync::api::scopes::Role;
use tablepro_sync::api::state::KeyVersionState;
use tablepro_sync::api::transport::{ChangeOutcome, RejectedCode};

use super::account::{fake_open, fake_seal, notice, opened, take_kv};
use super::{FakeKeyFlows, FakeTeam, Model, require_approved};

fn role(code: RejectedCode) -> SyncError {
    SyncError::Rejected { code }
}

fn team(model: &mut Model, team: TeamId) -> Result<&mut FakeTeam, SyncError> {
    model.teams.get_mut(&team).ok_or(SyncError::Unknown { what: "team" })
}

fn next(version: Option<Version>) -> Option<Version> {
    Version::new(version.map_or(1, |version| version.get() + 1)).ok()
}

#[async_trait]
impl TeamFlows for FakeKeyFlows {
    async fn team_keys(&self, id: TeamId) -> Result<TeamKeys, SyncError> {
        let mut model = self.lock();
        let held = team(&mut model, id)?;
        Ok(TeamKeys {
            team: id,
            version: held.version,
            state: KeyVersionState::Ok,
            rotation_due: held.rotation_due,
            holder: held.holder,
            members: held
                .members
                .iter()
                .map(|(account, (role, status))| MemberKeys {
                    account: *account,
                    role: *role,
                    status: *status,
                })
                .collect(),
        })
    }

    async fn create_team_keys(&self, id: TeamId) -> Result<(), SyncError> {
        let mut model = self.lock();
        require_approved(&model, "create a team key")?;
        let held = team(&mut model, id)?;
        if held.role != Role::Owner || held.version.is_some() {
            return Err(role(RejectedCode::Role));
        }
        held.version = next(None);
        held.holder = true;
        Ok(())
    }

    async fn publish_member_certificate(&self, id: TeamId) -> Result<(), SyncError> {
        let mut model = self.lock();
        require_approved(&model, "publish a member certificate")?;
        team(&mut model, id).map(|_| ())
    }

    async fn confirm_member(&self, id: TeamId, account: AccountId) -> Result<(), SyncError> {
        let mut model = self.lock();
        require_approved(&model, "confirm a member")?;
        let held = team(&mut model, id)?;
        if !held.role.manages_keys() {
            return Err(role(RejectedCode::Role));
        }
        if !held.holder {
            return Err(SyncError::Keys(KeysError::NotHolder));
        }
        let (_, status) = held
            .members
            .get_mut(&account)
            .ok_or(SyncError::Unknown { what: "member" })?;
        match status {
            MemberKeyStatus::NoKeys => Err(SyncError::NotAllowed {
                what: "confirm a member with no keys",
            }),
            // Nothing is wrapped to an account with an open alert until the person re-confirms it.
            MemberKeyStatus::Alert => Err(SyncError::NotAllowed {
                what: "confirm a member under an alert",
            }),
            MemberKeyStatus::AwaitingConfirmation | MemberKeyStatus::Holder => {
                *status = MemberKeyStatus::Holder;
                Ok(())
            }
        }
    }

    async fn rotate_team(&self, id: TeamId, remove: Vec<AccountId>) -> Result<(), SyncError> {
        let mut model = self.lock();
        require_approved(&model, "rotate a team key")?;
        let held = team(&mut model, id)?;
        if !held.holder {
            return Err(SyncError::Keys(KeysError::NotHolder));
        }
        if !held.role.manages_keys() && !held.rotation_due {
            return Err(role(RejectedCode::Role));
        }
        for (account, (_, status)) in &mut held.members {
            if remove.contains(account) && *status == MemberKeyStatus::Holder {
                *status = MemberKeyStatus::AwaitingConfirmation;
            }
        }
        held.version = next(held.version);
        held.rotation_due = false;
        Ok(())
    }

    async fn restart_team(&self, id: TeamId, confirm: Vec<AccountId>) -> Result<(), SyncError> {
        let mut model = self.lock();
        require_approved(&model, "restart a team key")?;
        let held = team(&mut model, id)?;
        if held.role != Role::Owner {
            return Err(role(RejectedCode::Role));
        }
        // A restart only once no member on the roster holds the current version.
        if held.holder
            || held
                .members
                .values()
                .any(|(_, status)| *status == MemberKeyStatus::Holder)
        {
            return Err(role(RejectedCode::Role));
        }
        for (account, (_, status)) in &mut held.members {
            if confirm.contains(account) && *status != MemberKeyStatus::NoKeys {
                *status = MemberKeyStatus::Holder;
            }
        }
        held.version = next(held.version);
        held.holder = true;
        held.rotation_due = false;
        notice(&mut model, KeyNoticeKind::TeamKeyRestarted { team: id });
        Ok(())
    }

    async fn credentials_to_rotate(&self, scope: ScopeName) -> Result<Vec<EnvelopeId>, SyncError> {
        let _ = scope;
        Ok(self.lock().credentials.clone())
    }

    async fn roster_read(&self, id: TeamId, roster: Roster) -> Result<(), SyncError> {
        let mut model = self.lock();
        let held = team(&mut model, id)?;
        if !roster.caught_up {
            return Ok(());
        }
        let removed_holder = held.members.iter().any(|(account, (_, status))| {
            *status == MemberKeyStatus::Holder && !roster.members.iter().any(|member| member.account == *account)
        });
        held.members
            .retain(|account, _| roster.members.iter().any(|member| member.account == *account));
        for member in &roster.members {
            let entry = held
                .members
                .entry(member.account)
                .or_insert((member.role, MemberKeyStatus::AwaitingConfirmation));
            entry.0 = member.role;
        }
        if let Some(own) = roster.role {
            held.role = own;
        }
        held.rotation_due = roster.rotation_due || removed_holder;
        Ok(())
    }

    async fn apply_team_objects(&self, arrival: KeyArrival) -> Result<KeyApplied, SyncError> {
        let _ = arrival;
        Ok(KeyApplied::default())
    }

    async fn seal_team_envelope(
        &self,
        id: TeamId,
        envelope: EnvelopeId,
        secret: SecretString,
        dest: Value,
    ) -> Result<Value, SyncError> {
        let mut model = self.lock();
        require_approved(&model, "seal a team secret")?;
        let held = team(&mut model, id)?;
        if !held.holder {
            return Err(role(RejectedCode::Role));
        }
        // Team envelopes wait in the queue while the team is due a rotation (0051, Teams).
        if held.rotation_due {
            return Err(role(RejectedCode::RotationDue));
        }
        let kv = held.version.ok_or(SyncError::NotAllowed {
            what: "seal before a team key",
        })?;
        let _ = envelope;
        Ok(fake_seal(kv, &json!({"secret": secret.expose_secret(), "dest": dest})))
    }

    async fn open_team_envelope(
        &self,
        id: TeamId,
        envelope: EnvelopeId,
        fields: Value,
        in_force: Option<Version>,
    ) -> Result<OpenedEnvelope, SyncError> {
        let mut model = self.lock();
        let holder = team(&mut model, id)?.holder;
        if !holder {
            return Err(SyncError::Keys(KeysError::NotHolder));
        }
        let (kv, plaintext) = fake_open(&fields)?;
        take_kv(&mut model, ScopeName::Team(id), &envelope.to_wire(), kv, in_force)?;
        Ok(opened(kv, &plaintext))
    }
}

#[async_trait]
impl RestoreFlows for FakeKeyFlows {
    async fn push_back(&self, epoch: EpochId) -> Result<Vec<KeyChangeSet>, SyncError> {
        let _ = epoch;
        Ok(std::mem::take(&mut self.lock().push_back))
    }

    async fn push_back_answered(
        &self,
        set: KeyChangeSet,
        outcomes: Vec<ChangeOutcome>,
    ) -> Result<PushBackVerdict, SyncError> {
        if outcomes
            .iter()
            .all(|outcome| matches!(outcome, ChangeOutcome::Applied { .. }))
        {
            return Ok(PushBackVerdict::Continue);
        }
        // Every refusal is final (0051, After a restore).
        let mut model = self.lock();
        match set.scope {
            ScopeName::Personal | ScopeName::History => {
                model.key_state = KeyState::Locked {
                    cause: LockCause::AccountEnded,
                };
                notice(
                    &mut model,
                    KeyNoticeKind::Locked {
                        cause: LockCause::AccountEnded,
                    },
                );
                Ok(PushBackVerdict::AccountEnded)
            }
            scope @ ScopeName::Team(_) => {
                notice(&mut model, KeyNoticeKind::ScopeEnded { scope });
                Ok(PushBackVerdict::Ended { scope })
            }
        }
    }
}

#[async_trait]
impl StopFlows for FakeKeyFlows {
    async fn stop_actions(&self) -> Result<Vec<StopAction>, SyncError> {
        let mut actions = self.lock().stop_actions.clone();
        // A withdrawal settles before any new report for that team.
        actions.sort_by_key(|action| matches!(action, StopAction::Report { .. }));
        Ok(actions)
    }

    async fn stop_action_sent(&self, action: StopAction) -> Result<(), SyncError> {
        self.lock().stop_actions.retain(|held| *held != action);
        Ok(())
    }

    async fn resume_withdrawal(&self, team: TeamId) -> Result<(), SyncError> {
        let _ = team;
        Ok(())
    }
}
