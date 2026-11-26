// The edits still on this device, read as a push would build them but without sending or writing anything: the diff
// of each library kind, the server's refusals, the open conflicts and 0.88's edits still to apply. A discard puts the
// store back at the team's copy, so the diff holds nothing more.

use std::collections::{HashMap, HashSet};

use serde_json::Value;
use tablepro_storage::TeamLibraryKind;

use super::super::push::{fingerprint, going_up};
use super::super::{ServiceSync, Session, begin};
use super::{library_kind, team_of};
use crate::adapters::approval;
use crate::adapters::fields::with_members_of;
use crate::api::adapter::LocalChange;
use crate::api::control::{ConflictChoice, conflict_digest};
use crate::api::error::SyncError;
use crate::api::ids::{KindName, RecordKey, ScopeName};
use crate::api::state::{BaseRow, HeldReason, HeldRow, Row, RowKey, RowRange, Table};
use crate::api::team_library::{TeamItemRef, UnsentState, UnsentTeamEdit};
use crate::api::transport::PulledRecord;
use crate::engine::{PendingOp, diff};

// One record of a team that differs from what the team holds.
pub(super) struct Unsent {
    pub(super) key: RecordKey,
    pub(super) kind: TeamLibraryKind,
    pub(super) state: UnsentState,
    pub(super) deletion: bool,
    pub(super) fields: Option<Value>,
    pub(super) base: Option<BaseRow>,
    // A conflict's, as the conflict sheet shows it, which its answer names.
    pub(super) digest: Option<[u8; 32]>,
}

fn name_of(fields: Option<&Value>) -> Option<String> {
    fields
        .and_then(|fields| fields.get("name"))
        .and_then(Value::as_str)
        .filter(|name| !name.is_empty())
        .map(str::to_owned)
}

impl ServiceSync {
    // The pending diff and the conflicts of one team scope. A record held back by a pull still lists the edit the store
    // holds of it, which waits for the hold: only a copy missing because the whole record waits is not an edit.
    pub(super) async fn team_diff(&self, scope: ScopeName) -> Result<Vec<Unsent>, SyncError> {
        let mut skip: HashMap<KindName, HashSet<String>> = HashMap::new();
        let mut held_back: HashSet<RecordKey> = HashSet::new();
        for row in begin(&self.state)
            .await?
            .scan(&RowRange::Scope(Table::Conflicts, scope))
            .await?
        {
            if let Row::Conflict(row) = row {
                skip.entry(row.key.kind).or_default().insert(row.key.record_id);
            }
        }
        for row in begin(&self.state)
            .await?
            .scan(&RowRange::Scope(Table::Held, scope))
            .await?
        {
            if let Row::Held(row) = row {
                held_back.insert(row.key);
            }
        }
        let refused = self.refused_in(scope).await?;
        let held = approval::held_members(begin(&self.state).await?.as_mut(), scope).await?;
        let mut out = Vec::new();
        for (kind, adapter) in self.library_adapters(scope) {
            let record_kind = adapter.kind();
            let bases = self.bases_in(scope, record_kind).await?;
            let local = going_up(record_kind, scope, adapter.records(scope).await?, &bases, &held);
            let none: HashSet<String> = HashSet::new();
            let diffed = diff(
                scope,
                record_kind,
                &local,
                &bases,
                skip.get(&KindName::of(record_kind)).unwrap_or(&none),
            );
            for pending in diffed.pending {
                let waits = held_back.contains(&pending.key);
                if waits && matches!(pending.op, PendingOp::Delete) {
                    continue;
                }
                let print = fingerprint(&pending.change());
                let state = match refused.get(&pending.key) {
                    Some(row) if row.digest == print => UnsentState::Refused { code: row.code.clone() },
                    _ if waits => UnsentState::Waiting,
                    _ => UnsentState::Pending,
                };
                let (deletion, fields) = match &pending.op {
                    PendingOp::Write { fields, .. } => (false, Some(fields.clone())),
                    PendingOp::Delete => (true, None),
                };
                out.push(Unsent {
                    digest: None,
                    key: pending.key,
                    kind,
                    state,
                    deletion,
                    fields,
                    base: pending.base,
                });
            }
            for (key, code) in diffed.refused {
                let fields = local
                    .records
                    .iter()
                    .find(|record| record.record_id == key.record_id)
                    .map(|record| record.fields.clone());
                let base = bases.iter().find(|base| base.key == key).cloned();
                out.push(Unsent {
                    digest: None,
                    key,
                    kind,
                    state: UnsentState::Refused { code: code.to_owned() },
                    deletion: false,
                    fields,
                    base,
                });
            }
        }
        out.extend(self.team_conflicts(scope).await?);
        Ok(out)
    }

    async fn team_conflicts(&self, scope: ScopeName) -> Result<Vec<Unsent>, SyncError> {
        let rows = begin(&self.state)
            .await?
            .scan(&RowRange::Scope(Table::Conflicts, scope))
            .await?;
        Ok(rows
            .into_iter()
            .filter_map(|row| {
                let Row::Conflict(row) = row else { return None };
                let kind = library_kind(row.key.kind.known()?)?;
                let digest = conflict_digest(row.base.as_ref(), row.mine.as_ref(), row.theirs.as_ref());
                Some(Unsent {
                    kind,
                    digest: Some(digest),
                    state: UnsentState::Conflict,
                    deletion: row.mine.is_none(),
                    fields: row.mine.or(row.theirs),
                    base: None,
                    key: row.key,
                })
            })
            .collect())
    }

    pub(super) async fn team_unsent(&self, session: &Session) -> Result<Vec<UnsentTeamEdit>, SyncError> {
        let mut out = Vec::new();
        for scope in self.known_teams(session).await? {
            let Some(team) = team_of(scope) else { continue };
            let reached = session
                .body
                .as_ref()
                .is_none_or(|body| body.scopes.iter().any(|info| info.scope == scope));
            for unsent in self.team_diff(scope).await? {
                let name = name_of(unsent.fields.as_ref())
                    .or_else(|| name_of(unsent.base.as_ref().and_then(|base| base.fields.as_ref())));
                out.push(UnsentTeamEdit {
                    team,
                    item: TeamItemRef {
                        kind: unsent.kind,
                        id: unsent.key.record_id,
                    },
                    name,
                    deletion: unsent.deletion,
                    state: if reached { unsent.state } else { unreached() },
                });
            }
            for imported in self.team_local(scope).await?.imports {
                out.push(UnsentTeamEdit {
                    team,
                    name: name_of(imported.fields.as_ref()).or_else(|| name_of(imported.base_fields.as_ref())),
                    deletion: imported.fields.is_none(),
                    state: match imported.refused {
                        Some(code) => UnsentState::Refused { code },
                        None if reached => UnsentState::Waiting,
                        None => unreached(),
                    },
                    item: TeamItemRef {
                        kind: imported.kind,
                        id: imported.id,
                    },
                });
            }
        }
        Ok(out)
    }

    // Every unsent edit of `only`, or of every team, goes: the store takes the team's copy back, a conflict keeps
    // theirs, a refusal is forgotten and 0.88's edits still waiting are dropped. Nothing is sent.
    pub(super) async fn discard(&self, session: &Session, only: Option<ScopeName>) -> Result<(), SyncError> {
        let scopes = match only {
            Some(scope) => vec![scope],
            None => self.known_teams(session).await?,
        };
        for scope in scopes {
            // The team keeps its copy of each, so none becomes this device's.
            let mut reverted = Vec::new();
            for row in self.team_conflicts(scope).await? {
                self.conflict_table()
                    .resolve(&row.key, row.digest.unwrap_or_default(), ConflictChoice::KeepTheirs)
                    .await?;
                reverted.push((row.kind, row.key.record_id));
            }
            reverted.extend(self.revert(scope).await?);
            self.forget_refusals(scope).await?;
            self.update_local(scope, move |local| {
                local.imports.clear();
                local.claims.retain(|claim| {
                    !reverted.iter().any(|key| {
                        claim.kind == key.0 && tablepro_records::record_id::library_ids_match(&claim.id, &key.1)
                    })
                });
            })
            .await?;
        }
        self.refresh_counts().await;
        Ok(())
    }

    // A library record's refusal goes with what it refused, here and after a restart (0066, `refused`).
    pub(super) async fn forget_refusals(&self, scope: ScopeName) -> Result<(), SyncError> {
        let rows = self.refused_in(scope).await?;
        let keys: Vec<RecordKey> = rows
            .into_keys()
            .filter(|key| key.kind.known().and_then(library_kind).is_some())
            .collect();
        if keys.is_empty() {
            return Ok(());
        }
        self.check_stop()?;
        let mut txn = begin(&self.state).await?;
        for key in keys {
            txn.delete(&RowKey::Refused(key)).await?;
        }
        txn.commit().await?;
        Ok(())
    }

    // The store's copy of each pending record back at its base, with the members that wait for the person kept as the
    // store holds them, so a discard approves nothing.
    async fn revert(&self, scope: ScopeName) -> Result<Vec<(TeamLibraryKind, String)>, SyncError> {
        let held = approval::held_members(begin(&self.state).await?.as_mut(), scope).await?;
        let pending = self.team_diff(scope).await?;
        let mut reverted = Vec::new();
        for (kind, adapter) in self.library_adapters(scope) {
            let records = adapter.records(scope).await?.records;
            let mut changes = Vec::new();
            for unsent in pending.iter().filter(|unsent| unsent.kind == kind) {
                if unsent.state == UnsentState::Conflict {
                    continue;
                }
                let id = unsent.key.record_id.clone();
                let stored = records
                    .iter()
                    .find(|record| record.record_id == id)
                    .map(|record| &record.fields);
                let live = unsent.base.as_ref().filter(|base| base.deleted.is_none());
                let members = held
                    .get(&(unsent.key.kind.clone(), id.clone()))
                    .cloned()
                    .unwrap_or_default();
                reverted.push((kind, id.clone()));
                let Some(base) = live.and_then(|live| live.fields.as_ref().map(|fields| (live, fields))) else {
                    changes.push(LocalChange::Delete { record_id: id });
                    continue;
                };
                if stored.is_some() {
                    changes.push(LocalChange::Put {
                        record_id: id,
                        fields: with_members_of(adapter.kind(), scope, base.1, stored, &members),
                    });
                    continue;
                }
                // Nothing here holds the approved values, so the team's copy comes back through the approval queue
                // and a member still waiting keeps the whole record out of the store.
                if let Some(fields) = self
                    .restore_waiting(adapter.kind(), &unsent.key, base.0, base.1)
                    .await?
                {
                    changes.push(LocalChange::Put { record_id: id, fields });
                }
            }
            if !changes.is_empty() {
                self.check_stop()?;
                adapter.apply(scope, changes).await?;
            }
        }
        Ok(reverted)
    }
}

impl ServiceSync {
    async fn restore_waiting(
        &self,
        kind: tablepro_records::Kind,
        key: &RecordKey,
        base: &BaseRow,
        fields: &Value,
    ) -> Result<Option<Value>, SyncError> {
        let mut txn = begin(&self.state).await?;
        let rows = approval::rows_of(txn.as_mut(), key).await?;
        let split = approval::split(kind, key, None, fields, &rows);
        approval::write(txn.as_mut(), key, &split).await?;
        if split.hold {
            txn.put(Row::Held(HeldRow {
                key: key.clone(),
                reason: HeldReason::AwaitingApproval,
                record: PulledRecord {
                    kind: key.kind.clone(),
                    record_id: key.record_id.clone(),
                    tag: base.tag.clone(),
                    fields: Some(fields.clone()),
                    fields_json: None,
                    deleted: None,
                    service: None,
                },
            }))
            .await?;
        }
        self.check_stop()?;
        txn.commit().await?;
        Ok((!split.hold).then_some(split.fields))
    }
}

// A team this sign-in no longer reaches takes nothing: its edits stay listed until they are discarded.
fn unreached() -> UnsentState {
    UnsentState::Refused {
        code: crate::api::team_library::TeamLibraryError::UnknownTeam
            .code()
            .to_owned(),
    }
}

// Whether a team's record has nothing left to send: neither in its diff nor waiting in a conflict.
pub(super) fn settled(unsent: &[Unsent], kind: TeamLibraryKind, id: &str) -> bool {
    !unsent
        .iter()
        .any(|unsent| unsent.kind == kind && tablepro_records::record_id::library_ids_match(&unsent.key.record_id, id))
}
