// The engine's control values in the app's records, and the app's arguments read back. Field values cross as JSON
// text.

use tablepro_sync::SyncError;
use tablepro_sync::api::control::{
    ConflictChoice, HeldRecord, HeldRecordReason, MoveBackPlan, MovePlan, NewIdentityChoice, NewIdentityPlan,
    PassReason, PendingApproval, ProviderChoice, RecordApproval, SyncCategories, SyncPhase, SyncStatus, TeamConflict,
};
use tablepro_sync::api::state::{HeldReason, Provider};
use tablepro_sync::api::{KindName, RecordKey, ScopeName};

use super::service::{
    ConflictChoiceTag, FieldApprovalInfo, HeldReasonTag, HeldRecordInfo, MoveBackPlanInfo, MovePlanInfo,
    NewIdentityChoiceTag, NewIdentityPlanInfo, PassReasonTag, RecordApprovalInfo, ScopeStatusInfo, SyncCategoriesArg,
    SyncPhaseTag, SyncRecordRef, SyncStatusInfo, TeamConflictInfo,
};
use crate::account::SyncProviderTag;

pub(crate) fn categories_arg(categories: &SyncCategoriesArg) -> Result<SyncCategories, SyncError> {
    let off = categories
        .off_kinds
        .iter()
        .map(|kind| KindName::parse(kind))
        .collect::<Result<Vec<_>, _>>()?;
    Ok(SyncCategories {
        off,
        passwords: categories.passwords,
    })
}

// A digest as `approvals` and `conflicts` give it, 32 bytes in lower-case hex.
pub(crate) fn digest_arg(text: &str) -> Result<[u8; 32], SyncError> {
    let malformed = SyncError::Malformed { what: "digest" };
    if text.bytes().any(|byte| byte.is_ascii_uppercase()) {
        return Err(malformed);
    }
    let bytes = hex::decode(text).map_err(|_| malformed.clone())?;
    bytes.try_into().map_err(|_| malformed)
}

pub(crate) fn record_arg(record: &SyncRecordRef) -> Result<RecordKey, SyncError> {
    Ok(RecordKey::new(
        ScopeName::parse(&record.scope)?,
        KindName::parse(&record.kind)?,
        record.record_id.clone(),
    ))
}

impl From<RecordKey> for SyncRecordRef {
    fn from(key: RecordKey) -> Self {
        Self {
            scope: key.scope.wire(),
            kind: key.kind.as_str().to_owned(),
            record_id: key.record_id,
        }
    }
}

impl From<Provider> for SyncProviderTag {
    fn from(provider: Provider) -> Self {
        match provider {
            Provider::Service => Self::TableproSync,
            Provider::ICloud => Self::Icloud,
        }
    }
}

impl From<SyncProviderTag> for ProviderChoice {
    fn from(provider: SyncProviderTag) -> Self {
        match provider {
            SyncProviderTag::Off => Self::Off,
            SyncProviderTag::Icloud => Self::ICloud,
            SyncProviderTag::TableproSync => Self::Service,
        }
    }
}

impl From<SyncPhase> for SyncPhaseTag {
    fn from(phase: SyncPhase) -> Self {
        match phase {
            SyncPhase::Off => Self::Off,
            SyncPhase::Unavailable => Self::Unavailable,
            SyncPhase::Idle => Self::Idle,
            SyncPhase::Syncing => Self::Syncing,
            SyncPhase::Waiting { retry_in_ms } => Self::Waiting { retry_in_ms },
            SyncPhase::PullOnly => Self::PullOnly,
            SyncPhase::ZoneRemoved => Self::ZoneRemoved,
            SyncPhase::NewIdentity => Self::NewIdentity,
            SyncPhase::NeedsApproval => Self::NeedsApproval,
        }
    }
}

impl From<SyncStatus> for SyncStatusInfo {
    fn from(status: SyncStatus) -> Self {
        Self {
            provider: status.provider.map(SyncProviderTag::from),
            phase: status.phase.into(),
            last_pass_ms: status.last_pass_ms,
            problem: status.problem.map(str::to_owned),
            waiting_approvals: status.waiting_approvals,
            conflicts: status.conflicts,
            held: status.held,
            queued_changes: status.queued_changes,
        }
    }
}

impl From<PassReasonTag> for PassReason {
    fn from(why: PassReasonTag) -> Self {
        match why {
            PassReasonTag::Journal => Self::Journal,
            PassReasonTag::AccountChanged => Self::AccountChanged,
            PassReasonTag::Launch => Self::Launch,
            PassReasonTag::Foreground => Self::Foreground,
            PassReasonTag::NetworkBack => Self::NetworkBack,
            PassReasonTag::CloudKitPush => Self::CloudKitPush,
            PassReasonTag::Person => Self::Person,
        }
    }
}

impl From<NewIdentityChoiceTag> for NewIdentityChoice {
    fn from(choice: NewIdentityChoiceTag) -> Self {
        match choice {
            NewIdentityChoiceTag::MoveMyData => Self::MoveMyData,
            NewIdentityChoiceTag::StartEmpty => Self::StartEmpty,
        }
    }
}

impl From<ConflictChoiceTag> for ConflictChoice {
    fn from(choice: ConflictChoiceTag) -> Self {
        match choice {
            ConflictChoiceTag::KeepMine => Self::KeepMine,
            ConflictChoiceTag::KeepTheirs => Self::KeepTheirs,
        }
    }
}

impl From<MovePlan> for MovePlanInfo {
    fn from(plan: MovePlan) -> Self {
        Self {
            records: plan.records,
            staying_behind: plan.staying_behind,
            secrets_to_seal: plan.secrets_to_seal,
        }
    }
}

impl From<MoveBackPlan> for MoveBackPlanInfo {
    fn from(plan: MoveBackPlan) -> Self {
        Self {
            icloud_deletions: plan.icloud_deletions,
        }
    }
}

impl From<NewIdentityPlan> for NewIdentityPlanInfo {
    fn from(plan: NewIdentityPlan) -> Self {
        Self {
            unsent: plan.unsent,
            account: plan.account,
        }
    }
}

impl From<RecordApproval> for RecordApprovalInfo {
    fn from(approval: RecordApproval) -> Self {
        Self {
            record: approval.key.into(),
            name: approval.name,
            new_record: approval.new_record,
            digest: hex::encode(approval.digest),
            fields: approval.fields.into_iter().map(FieldApprovalInfo::from).collect(),
        }
    }
}

impl From<PendingApproval> for FieldApprovalInfo {
    fn from(approval: PendingApproval) -> Self {
        Self {
            field: approval.field,
            current: approval.current.map(|value| value.to_string()),
            pulled: (!approval.pulled.is_null()).then(|| approval.pulled.to_string()),
            digest: hex::encode(approval.digest),
        }
    }
}

impl From<TeamConflict> for TeamConflictInfo {
    fn from(conflict: TeamConflict) -> Self {
        Self {
            record: conflict.key.into(),
            fields: conflict.fields,
            mine: conflict.mine.map(|value| value.to_string()),
            theirs: conflict.theirs.map(|value| value.to_string()),
            digest: hex::encode(conflict.digest),
        }
    }
}

impl From<HeldRecordReason> for HeldReasonTag {
    fn from(reason: HeldRecordReason) -> Self {
        match reason {
            HeldRecordReason::Held(HeldReason::Unreadable | HeldReason::RefusedInRefill | HeldReason::Collides) => {
                Self::Unreadable
            }
            HeldRecordReason::Held(HeldReason::UnknownKind) => Self::UnknownKind,
            // A secret mostly waits for its record's approval, so the app shows it with what waits for the person.
            HeldRecordReason::Held(HeldReason::AwaitingApproval | HeldReason::AwaitingStore) => Self::AwaitingApproval,
            HeldRecordReason::Held(HeldReason::AwaitingDeviceApproval) => Self::AwaitingDeviceApproval,
            HeldRecordReason::Refused { code } => Self::Refused { code },
        }
    }
}

impl From<HeldRecord> for HeldRecordInfo {
    fn from(held: HeldRecord) -> Self {
        Self {
            record: held.key.into(),
            reason: held.reason.into(),
        }
    }
}

impl From<tablepro_sync::api::ScopeInfo> for ScopeStatusInfo {
    fn from(info: tablepro_sync::api::ScopeInfo) -> Self {
        Self {
            scope: info.scope.wire(),
            writable: info.writable,
            personal_sync: info.policies.personal_sync,
            password_sync: info.policies.password_sync,
            history_sync: info.policies.history_sync,
        }
    }
}
