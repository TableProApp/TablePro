// A publish as the Swift app ran it: a pass first, so the plan reads the team's latest copy, then the plan written to
// the store under the session lock, then a pass that pushes it. What a publish wrote of this device's own items
// becomes this device's to remove once the team holds it as sent.

use tablepro_keys::encoding::TeamId;
use tablepro_records::record_id::library_ids_match;
use tablepro_storage::{TeamLibraryCopy, TeamLibraryKind, TeamLibraryRef};

use super::super::{ServiceSync, Session, begin};
use super::plan::{Planned, TeamView, kind_of};
use super::unsent::{Unsent, settled};
use super::writes;
use crate::api::adapter::LocalChange;
use crate::api::control::PassReason;
use crate::api::error::SyncError;
use crate::api::ids::{KindName, RecordKey, ScopeName};
use crate::api::scopes::ScopeInfo;
use crate::api::state::{ConflictRow, Row};
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
        self.settle_claims(scope).await?;
        let items = self.team_items(scope).await?;
        let bases = self.team_bases(scope).await?;
        let local = self.team_local(scope).await?;
        let planned = plan(&TeamView {
            items: &items,
            bases: &bases,
            local: &local,
        });
        self.signed_in()?;
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
        // An empty team's pull ends caught up with no cursor, which is pulled all the same.
        let pulled = self
            .scope_row(scope)
            .await?
            .is_some_and(|row| row.epoch.is_some() && row.caught_up && !row.refill);
        if !pulled {
            return Err(failure().unwrap_or_else(|| TeamLibraryError::NotPulled.into()));
        }
        Ok(info)
    }

    async fn write_planned(&self, scope: ScopeName, planned: &[Planned]) -> Result<(), SyncError> {
        for (kind, adapter) in self.library_adapters(scope) {
            let changes: Vec<LocalChange> = planned
                .iter()
                .filter_map(|planned| match planned {
                    Planned::Put {
                        kind: of, id, fields, ..
                    } if *of == kind => Some(LocalChange::Put {
                        record_id: id.clone(),
                        fields: fields.clone(),
                    }),
                    Planned::Delete { kind: of, id } if *of == kind => {
                        Some(LocalChange::Delete { record_id: id.clone() })
                    }
                    _ => None,
                })
                .collect();
            if !changes.is_empty() {
                self.check_stop()?;
                adapter.apply(scope, changes).await?;
            }
        }
        let asks: Vec<Row> = planned
            .iter()
            .filter_map(|planned| match planned {
                Planned::Ask { kind, id, fields, .. } => Some(Row::Conflict(ConflictRow {
                    key: RecordKey::new(scope, KindName::of(kind_of(*kind)), id.clone()),
                    base: None,
                    mine: Some(fields.clone()),
                    theirs: None,
                })),
                _ => None,
            })
            .collect();
        if !asks.is_empty() {
            self.check_stop()?;
            let mut txn = begin(&self.state).await?;
            for row in asks {
                txn.put(row).await?;
            }
            txn.commit().await?;
            self.refresh_counts().await;
        }
        let claims = claims_of(planned);
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

    // A claim stands until the team holds the item as sent, which makes it this device's, or until nothing of it is
    // left to send without the team holding it: Keep Theirs, a discard, or the team deleting it.
    pub(super) async fn settle_claims(&self, scope: ScopeName) -> Result<(), SyncError> {
        let local = self.team_local(scope).await?;
        if local.claims.is_empty() {
            return Ok(());
        }
        let unsent = self.team_diff(scope).await?;
        let bases = self.team_bases(scope).await?;
        let mut taken = Vec::new();
        let mut gone = Vec::new();
        for claim in &local.claims {
            if !settled(&unsent, claim.kind, &claim.id) {
                continue;
            }
            let held = bases.iter().find(|(kind, base)| {
                *kind == claim.kind && library_ids_match(&base.key.record_id, &claim.id) && base.deleted.is_none()
            });
            match held {
                Some(_) => taken.push((claim.kind, claim.id.clone())),
                None => gone.push((claim.kind, claim.id.clone())),
            }
        }
        self.update_local(scope, move |local| {
            let named = |kind: TeamLibraryKind, id: &str, list: &[(TeamLibraryKind, String)]| {
                list.iter()
                    .any(|(held, held_id)| *held == kind && library_ids_match(held_id, id))
            };
            local
                .claims
                .retain(|claim| !named(claim.kind, &claim.id, &taken) && !named(claim.kind, &claim.id, &gone));
            local.declined.retain(|copy| !named(copy.kind, &copy.id, &taken));
            for (kind, id) in taken {
                if !local.published.iter().any(|held| held.names(kind, &id)) {
                    local.published.push(TeamLibraryRef { kind, id });
                }
            }
        })
        .await
    }
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
