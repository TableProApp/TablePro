// A publish as the Swift app ran it: a pass first, so the plan reads the team's latest copy, then the plan written to
// the store under the session lock, then a pass that pushes it. What a publish wrote of this device's own items
// becomes this device's to remove once the team holds it as sent.

use std::collections::HashMap;

use serde_json::Value;
use tablepro_keys::encoding::TeamId;
use tablepro_records::record_id::library_ids_match;
use tablepro_storage::{TeamLibraryCopy, TeamLibraryKind, TeamLibraryRef};

use super::super::{ServiceSync, Session, begin};
use super::plan::{Planned, TeamView, kind_of, same_item};
use super::unsent::{Unsent, settled};
use super::writes;
use crate::adapters::conflict::{contested, overlay};
use crate::api::adapter::LocalChange;
use crate::api::control::PassReason;
use crate::api::error::SyncError;
use crate::api::ids::{KindName, RecordKey, ScopeName};
use crate::api::scopes::ScopeInfo;
use crate::api::state::{ConflictRow, Row, RowKey, RowRange, Table};
use crate::api::team_library::{TeamLibraryError, TeamPublish, UnsentState};

impl ServiceSync {
    pub(super) async fn publish(
        &self,
        team: TeamId,
        plan: impl FnOnce(&TeamView<'_>) -> Vec<Planned> + Send,
    ) -> Result<TeamPublish, SyncError> {
        let scope = ScopeName::Team(team);
        self.signed_in()?;
        let first = self.run_pass(PassReason::Person).await;
        self.signed_in()?;
        let session = self.session.lock().await;
        let info = self.writable_team(&session, scope, first.as_ref().err()).await?;
        self.settle_ownership(scope).await?;
        let items = self.team_items(scope).await?;
        let bases = self.team_bases(scope).await?;
        let local = self.team_local(scope).await?;
        let planned = plan(&TeamView::new(&items, &bases, &local));
        let read = self.policy_read().await?;
        self.write_planned(scope, &planned).await?;
        drop(read);
        drop(session);
        if planned.is_empty() {
            return Ok(TeamPublish::default());
        }
        let second = self.run_pass(PassReason::Person).await;
        let _session = self.session.lock().await;
        let unsent = self.team_diff(scope).await?;
        Ok(outcome(&planned, &unsent, &info, second.err()))
    }

    // The team as the scopes body has it, when this account writes its library and it was pulled at least once: an
    // edit planned against nothing would overwrite what the team holds.
    async fn writable_team(
        &self,
        session: &Session,
        scope: ScopeName,
        failed: Option<&SyncError>,
    ) -> Result<ScopeInfo, SyncError> {
        let failure = || failed.cloned();
        let Some(body) = &session.body else {
            return Err(failure().unwrap_or_else(|| TeamLibraryError::UnknownTeam.into()));
        };
        let Some(info) = body.scopes.iter().find(|info| info.scope == scope).cloned() else {
            return Err(TeamLibraryError::UnknownTeam.into());
        };
        if !writes(info.role) {
            return Err(TeamLibraryError::NotWritable.into());
        }
        if !self.team_pulled(scope).await? {
            return Err(failure().unwrap_or_else(|| TeamLibraryError::NotPulled.into()));
        }
        Ok(info)
    }

    // Conflicts first: an open one takes the new copy as its side, so Keep Mine never puts back an older one and a sheet
    // showing that older one is turned away by its digest. The old base no longer says which members this device
    // changed, so the new copy stands against the team's whole, and the store holds the agreed members with the team's
    // value in each contested one, as a pull leaves a conflict. Each write checks the sign-in just before it lands.
    async fn write_planned(&self, scope: ScopeName, planned: &[Planned]) -> Result<(), SyncError> {
        let open: HashMap<RecordKey, ConflictRow> = begin(&self.state)
            .await?
            .scan(&RowRange::Scope(Table::Conflicts, scope))
            .await?
            .into_iter()
            .filter_map(|row| match row {
                Row::Conflict(row) => Some((row.key.clone(), row)),
                _ => None,
            })
            .collect();
        let ConflictWrites { rows, stored } = conflict_rows(scope, planned, &open);
        if !rows.is_empty() {
            let mut txn = begin(&self.state).await?;
            for row in rows {
                match row {
                    Ok(row) => txn.put(row).await?,
                    Err(key) => txn.delete(&key).await?,
                }
            }
            self.team_commit_check()?;
            txn.commit().await?;
            self.refresh_counts().await;
        }
        for (kind, adapter) in self.library_adapters(scope) {
            let changes: Vec<LocalChange> = planned
                .iter()
                .filter_map(|planned| match planned {
                    Planned::Put {
                        kind: of, id, fields, ..
                    } if *of == kind => match stored.get(id) {
                        Some(None) => None,
                        Some(Some(projected)) => Some(LocalChange::Put {
                            record_id: id.clone(),
                            fields: projected.clone(),
                        }),
                        None => Some(LocalChange::Put {
                            record_id: id.clone(),
                            fields: fields.clone(),
                        }),
                    },
                    Planned::Delete { kind: of, id } if *of == kind => {
                        Some(LocalChange::Delete { record_id: id.clone() })
                    }
                    _ => None,
                })
                .collect();
            if !changes.is_empty() {
                self.team_commit_check()?;
                adapter.apply(scope, changes).await?;
            }
        }
        let claims = claims_of(planned);
        self.team_commit_check()?;
        self.update_local(scope, move |local| {
            for (kind, id, claim) in claims {
                local
                    .claims
                    .retain(|held| !(held.kind == kind && library_ids_match(&held.id, &id)));
                local.claims.extend(claim);
            }
        })
        .await
    }

    // A claim becomes this device's once the team holds the copy it claimed and nothing of it waits to go up; a team
    // that holds something else, or nothing, ends it. An item the team no longer holds is no longer this device's, so a
    // later publish never removes what someone else brought back. Only against a team pulled to its end.
    pub(super) async fn settle_ownership(&self, scope: ScopeName) -> Result<(), SyncError> {
        if !self.team_pulled(scope).await? {
            return Ok(());
        }
        let local = self.team_local(scope).await?;
        if local.claims.is_empty() && local.published.is_empty() {
            return Ok(());
        }
        let unsent = self.team_diff(scope).await?;
        let skipped = self.skipped(scope).await?;
        let bases = self.team_bases(scope).await?;
        let live = |kind: TeamLibraryKind, id: &str| {
            bases
                .iter()
                .find(|(held, base)| *held == kind && library_ids_match(&base.key.record_id, id))
                .map(|(_, base)| base)
                .filter(|base| base.deleted.is_none())
        };
        let waiting = |kind: TeamLibraryKind, id: &str| {
            !settled(&unsent, kind, id)
                || skipped
                    .get(&KindName::of(kind_of(kind)))
                    .is_some_and(|held| held.iter().any(|held| library_ids_match(held, id)))
        };
        let mut taken = Vec::new();
        let mut ended = Vec::new();
        for claim in local.claims.iter().filter(|claim| !waiting(claim.kind, &claim.id)) {
            let holds = live(claim.kind, &claim.id)
                .and_then(|base| base.fields.as_ref())
                .is_some_and(|fields| same_item(claim.kind, fields, &claim.fields));
            let named = (claim.kind, claim.id.clone());
            if holds {
                taken.push(named);
            } else {
                ended.push(named);
            }
        }
        let released: Vec<(TeamLibraryKind, String)> = local
            .published
            .iter()
            .filter(|held| live(held.kind, &held.id).is_none() && !waiting(held.kind, &held.id))
            .map(|held| (held.kind, held.id.clone()))
            .collect();
        if taken.is_empty() && ended.is_empty() && released.is_empty() {
            return Ok(());
        }
        self.update_local(scope, move |local| {
            let named = |kind: TeamLibraryKind, id: &str, list: &[(TeamLibraryKind, String)]| {
                list.iter()
                    .any(|(held, held_id)| *held == kind && library_ids_match(held_id, id))
            };
            local
                .claims
                .retain(|claim| !named(claim.kind, &claim.id, &taken) && !named(claim.kind, &claim.id, &ended));
            local.declined.retain(|copy| !named(copy.kind, &copy.id, &taken));
            local.published.retain(|held| !named(held.kind, &held.id, &released));
            for (kind, id) in taken {
                if !local.published.iter().any(|held| held.names(kind, &id)) {
                    local.published.push(TeamLibraryRef { kind, id });
                }
            }
        })
        .await
    }
}
// What each planned item does to the conflict open on it, or the ask it opens.
struct ConflictWrites {
    // A row to put, or the key of one to drop.
    rows: Vec<Result<Row, RowKey>>,
    // The copy the store takes of each conflicted item: None while it stands against a deletion.
    stored: HashMap<String, Option<Value>>,
}

fn conflict_rows(scope: ScopeName, planned: &[Planned], open: &HashMap<RecordKey, ConflictRow>) -> ConflictWrites {
    let mut rows: Vec<Result<Row, RowKey>> = Vec::new();
    let mut stored: HashMap<String, Option<Value>> = HashMap::new();
    for planned in planned {
        let item = planned.item();
        let key = RecordKey::new(scope, KindName::of(kind_of(item.kind)), item.id.clone());
        let Some(held) = open.get(&key) else {
            if let Planned::Ask { fields, .. } = planned {
                rows.push(Ok(Row::Conflict(ConflictRow {
                    key,
                    base: None,
                    mine: Some(fields.clone()),
                    theirs: None,
                })));
            }
            continue;
        };
        let mine = match planned {
            Planned::Put { fields, .. } | Planned::Ask { fields, .. } => Some(fields.clone()),
            Planned::Delete { .. } => None,
        };
        if mine == held.theirs {
            rows.push(Err(RowKey::Conflict(key)));
            continue;
        }
        let row = ConflictRow {
            key,
            base: if mine.is_some() { None } else { held.base.clone() },
            mine,
            theirs: held.theirs.clone(),
        };
        if let Some(fields) = &row.mine {
            // Against a deletion the store holds nothing until the person answers, as an ask leaves it.
            let projected = row
                .theirs
                .as_ref()
                .map(|theirs| overlay(fields, Some(theirs), &contested(&row)));
            stored.insert(item.id, projected);
        }
        rows.push(Ok(Row::Conflict(row)));
    }
    ConflictWrites { rows, stored }
}

// Each planned item's claim: an own item's copy, or none for a move of someone else's item or a removal.
fn claims_of(planned: &[Planned]) -> Vec<(TeamLibraryKind, String, Option<TeamLibraryCopy>)> {
    planned
        .iter()
        .map(|planned| match planned {
            Planned::Put {
                kind, id, fields, own, ..
            }
            | Planned::Ask { kind, id, fields, own } => (
                *kind,
                id.clone(),
                own.then(|| TeamLibraryCopy {
                    kind: *kind,
                    id: id.clone(),
                    fields: fields.clone(),
                }),
            ),
            Planned::Delete { kind, id } => (*kind, id.clone(), None),
        })
        .collect()
}

fn outcome(planned: &[Planned], unsent: &[Unsent], info: &ScopeInfo, failed: Option<SyncError>) -> TeamPublish {
    let mine: Vec<&Unsent> = unsent
        .iter()
        .filter(|unsent| {
            planned.iter().any(|planned| {
                planned.item().kind == unsent.kind && library_ids_match(&planned.item().id, &unsent.key.record_id)
            })
        })
        .collect();
    let conflicts = mine
        .iter()
        .filter(|unsent| unsent.state == UnsentState::Conflict)
        .count();
    let refused = mine.iter().find_map(|unsent| match &unsent.state {
        UnsentState::Refused { code } => Some(code.clone()),
        _ => None,
    });
    let problem = failed
        .map(|error| error.code().to_owned())
        .or_else(|| (!info.writable).then(|| TeamLibraryError::PullOnly.code().to_owned()))
        .or(refused);
    TeamPublish {
        edits: u32::try_from(planned.len()).unwrap_or(u32::MAX),
        conflicts: u32::try_from(conflicts).unwrap_or(u32::MAX),
        unsent: u32::try_from(mine.len() - conflicts).unwrap_or(u32::MAX),
        problem,
    }
}
