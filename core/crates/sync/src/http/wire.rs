// `/v2/sync`'s bodies as the engine reads them (0051, Pull; Push; Scopes). A page is read with each record's fields as
// the raw text the server sent, so a key object parses from that text and a duplicate member is refused, not
// collapsed (0051, Key object bodies).

use serde::{Deserialize, Serialize};
use serde_json::Value;
use serde_json::value::RawValue;
use tablepro_cloud_api::v2::types;
use tablepro_keys::encoding::{AccountId, Version};
use uuid::Uuid;

use crate::api::ids::{ChangeTag, Cursor, DeviceRowId, EpochId, KindName, ScopeName, parse_typeid, typeid};
use crate::api::scopes::{
    LineageEpoch, Role, ScopeInfo, ScopePolicies, ScopesBody, ServerLimits, StopReport, TeamMember,
};
use crate::api::transport::{
    AppliedStamp, Change, ChangeOp, ChangeOutcome, DeletedReason, PulledPage, PulledRecord, RejectedCode, ServiceMeta,
    StoredCopy, StoredStamp,
};

const EPOCH: &str = "epoch_";
const ACCOUNT: &str = "acct_";

// A body that does not read as the document says, which no retry mends.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct Malformed;

fn epoch(text: &str) -> Result<EpochId, Malformed> {
    parse_typeid(EPOCH, text).map(EpochId).ok_or(Malformed)
}

pub(super) fn epoch_text(epoch: EpochId) -> String {
    typeid(EPOCH, epoch.0)
}

pub(super) fn account(text: &str) -> Option<AccountId> {
    parse_typeid(ACCOUNT, text).map(AccountId)
}

fn unsigned(value: i64) -> Result<u64, Malformed> {
    u64::try_from(value).map_err(|_| Malformed)
}

#[derive(Deserialize)]
struct Page<'a> {
    #[serde(borrow)]
    records: Vec<Record<'a>>,
    cursor: Option<String>,
    changes_cursor: Option<String>,
}

#[derive(Deserialize)]
struct Record<'a> {
    kind: String,
    record_id: String,
    version: i64,
    revision: i64,
    epoch: String,
    change_tag: String,
    deleted: bool,
    deleted_reason: Option<String>,
    #[serde(borrow)]
    fields: Option<&'a RawValue>,
    updated_at: chrono::DateTime<chrono::Utc>,
    taken_at: i64,
    held_until: Option<i64>,
    expires_at: Option<i64>,
    updated_by: Option<String>,
    updated_device: Option<String>,
    updated_by_name: Option<String>,
}

pub(super) fn page(body: &[u8]) -> Result<PulledPage, Malformed> {
    let page: Page<'_> = serde_json::from_slice(body).map_err(|_| Malformed)?;
    let records = page.records.into_iter().map(record).collect::<Result<Vec<_>, _>>()?;
    Ok(PulledPage {
        caught_up: records.is_empty(),
        records,
        cursor: page.cursor.map(Cursor::Service),
        changes_cursor: page.changes_cursor.map(Cursor::Service),
        unread: Vec::new(),
    })
}

fn record(record: Record<'_>) -> Result<PulledRecord, Malformed> {
    // A tombstone never carries fields; one that does reads as the tombstone it says it is.
    let (fields, fields_json) = match (record.deleted, record.fields) {
        (false, Some(raw)) => (
            Some(serde_json::from_str::<Value>(raw.get()).map_err(|_| Malformed)?),
            Some(raw.get().to_owned()),
        ),
        (false, None) => return Err(Malformed),
        (true, _) => (None, None),
    };
    // A reason this build does not know keeps the device's copy, as a policy's does.
    let deleted = record.deleted.then(|| match record.deleted_reason.as_deref() {
        Some("user") => DeletedReason::User,
        _ => DeletedReason::Policy,
    });
    Ok(PulledRecord {
        kind: KindName::parse(&record.kind).map_err(|_| Malformed)?,
        record_id: record.record_id,
        tag: ChangeTag::Service(record.change_tag),
        fields,
        fields_json,
        deleted,
        service: Some(ServiceMeta {
            version: unsigned(record.version)?,
            revision: unsigned(record.revision)?,
            epoch: epoch(&record.epoch)?,
            updated_at_us: record.updated_at.timestamp_micros(),
            taken_at_us: record.taken_at,
            held_until_us: record.held_until,
            expires_at_us: record.expires_at,
            updated_by: record.updated_by,
            updated_device: record.updated_device.map(DeviceRowId),
            updated_by_name: record.updated_by_name,
        }),
    })
}

#[derive(Serialize)]
struct Push<'a> {
    epoch: String,
    changes: Vec<PushChange<'a>>,
}

#[derive(Serialize)]
struct PushChange<'a> {
    kind: &'a str,
    record_id: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    base_tag: Option<&'a str>,
    op: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    patch: Option<&'a Value>,
}

// A base from CloudKit has no meaning on the service, so a change that carries one is not sent.
pub(super) fn push_body(epoch: EpochId, changes: &[Change]) -> Result<Vec<u8>, Malformed> {
    let changes = changes
        .iter()
        .map(|change| {
            let base_tag = match &change.base {
                None => None,
                Some(ChangeTag::Service(tag)) => Some(tag.as_str()),
                Some(ChangeTag::CloudKit(_)) => return Err(Malformed),
            };
            let (op, patch) = match &change.op {
                ChangeOp::Write { patch, .. } => ("patch", Some(patch)),
                ChangeOp::Delete => ("delete", None),
            };
            Ok(PushChange {
                kind: change.kind.as_str(),
                record_id: &change.record_id,
                base_tag,
                op,
                patch,
            })
        })
        .collect::<Result<Vec<_>, _>>()?;
    serde_json::to_vec(&Push {
        epoch: epoch_text(epoch),
        changes,
    })
    .map_err(|_| Malformed)
}

// One outcome per change, in the order sent; any other count is no answer the engine can pair.
pub(super) fn outcomes(body: &[u8], sent: &[Change]) -> Result<Vec<ChangeOutcome>, Malformed> {
    let answer: types::SyncPushResult = serde_json::from_slice(body).map_err(|_| Malformed)?;
    if answer.outcomes.len() != sent.len() {
        return Err(Malformed);
    }
    answer
        .outcomes
        .into_iter()
        .zip(sent)
        .map(|(outcome, change)| {
            if outcome.kind != change.kind.as_str() || outcome.record_id != change.record_id {
                return Err(Malformed);
            }
            self::outcome(outcome)
        })
        .collect()
}

fn outcome(outcome: types::SyncOutcome) -> Result<ChangeOutcome, Malformed> {
    match outcome.status.as_str() {
        "applied" => Ok(ChangeOutcome::Applied {
            tag: outcome.change_tag.map(ChangeTag::Service),
            service: match (outcome.version, outcome.revision) {
                (Some(version), Some(revision)) => Some(AppliedStamp {
                    version: unsigned(version)?,
                    revision: unsigned(revision)?,
                }),
                _ => None,
            },
        }),
        "conflict" => Ok(ChangeOutcome::Conflict {
            stored: outcome.stored.map(stored).transpose()?,
        }),
        "rejected" => Ok(ChangeOutcome::Rejected {
            code: RejectedCode::parse(outcome.code.as_deref().ok_or(Malformed)?),
        }),
        // A status a newer server sends that this build does not know applies nothing it can tell.
        other => Ok(ChangeOutcome::Rejected {
            code: RejectedCode::Other(other.to_owned()),
        }),
    }
}

fn stored(stored: types::SyncStored) -> Result<StoredCopy, Malformed> {
    Ok(StoredCopy {
        tag: ChangeTag::Service(stored.change_tag),
        tombstone: stored.deleted,
        service: Some(StoredStamp {
            version: unsigned(stored.version)?,
            revision: unsigned(stored.revision)?,
            epoch: epoch(&stored.epoch)?,
        }),
        fields: None,
    })
}

// A role this build does not know grants no more than a member's.
fn role(text: &str) -> Role {
    Role::parse(text).unwrap_or(Role::Member)
}

pub(super) fn scopes(body: types::SyncScopes) -> Result<ScopesBody, Malformed> {
    let limits = &body.limits;
    let narrow = |value: i64| u32::try_from(value).map_err(|_| Malformed);
    Ok(ScopesBody {
        epoch: epoch(&body.epoch)?,
        limits: ServerLimits {
            record_bytes: unsigned(limits.record_bytes)?,
            body_bytes: unsigned(limits.body_bytes)?,
            changes_per_push: narrow(limits.push_changes)?,
            changes_per_change_set: narrow(limits.change_set_changes)?,
            page_records: narrow(limits.page_records)?,
            page_bytes: unsigned(limits.page_bytes)?,
            json_depth: narrow(limits.json_depth)?,
            team_key_holders: narrow(limits.team_key_holders)?,
        },
        scopes: body
            .scopes
            .into_iter()
            .filter_map(|scope| scope_info(scope).transpose())
            .collect::<Result<Vec<_>, _>>()?,
        server_version: body.server_version,
        capabilities: body.capabilities,
        idempotency_retention_secs: unsigned(body.idempotency_retention)?,
        poll_interval_secs: unsigned(body.poll_interval)?,
    })
}

// A scope whose id this build cannot name, as a type a newer server adds, is left out.
fn scope_info(scope: types::SyncScope) -> Result<Option<ScopeInfo>, Malformed> {
    let Ok(name) = ScopeName::parse(&scope.id) else {
        return Ok(None);
    };
    let team = matches!(name, ScopeName::Team(_));
    let members = scope
        .members
        .unwrap_or_default()
        .into_iter()
        .map(|member| {
            Ok(TeamMember {
                account: account(&member.account).ok_or(Malformed)?,
                role: role(&member.role),
            })
        })
        .collect::<Result<Vec<_>, _>>()?;
    let stopped = scope
        .stopped
        .unwrap_or_default()
        .into_iter()
        .map(|report| {
            Ok(StopReport {
                account: account(&report.account).ok_or(Malformed)?,
                device: DeviceRowId(report.device),
                version: Version::from_i64(i64::from(report.version)).map_err(|_| Malformed)?,
            })
        })
        .collect::<Result<Vec<_>, _>>()?;
    Ok(Some(ScopeInfo {
        scope: name,
        role: team.then(|| role(&scope.role)),
        horizon: unsigned(scope.horizon)?,
        epochs: scope
            .epochs
            .into_iter()
            .map(|lineage| {
                Ok(LineageEpoch {
                    id: epoch(&lineage.id)?,
                    kept_revision: unsigned(lineage.kept_revision)?,
                })
            })
            .collect::<Result<Vec<_>, _>>()?,
        writable: scope.writable,
        policies: ScopePolicies {
            personal_sync: scope.policies.personal_sync,
            password_sync: scope.policies.password_sync,
            history_sync: scope.policies.history_sync,
        },
        quota: None,
        rotation_due: scope.rotation_due.unwrap_or(false),
        members,
        stopped,
        approved: scope.approved,
    }))
}

// A device row is named by its TypeID on the wire, which the engine keeps as text.
pub(super) fn device_row_ok(device: &DeviceRowId) -> bool {
    parse_typeid("dev_", &device.0).is_some()
}

#[cfg(test)]
pub(super) fn epoch_of(uuid: Uuid) -> String {
    epoch_text(EpochId(uuid))
}
