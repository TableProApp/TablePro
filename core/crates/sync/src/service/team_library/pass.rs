// What a pass and a conflict's answer leave for Team Library: each team's last pull and the code it met, the edits
// 0.88 left once their team is pulled, a team this sign-in no longer reaches, and what Keep Mine or Keep Theirs says of
// this device's copy.

use std::collections::HashMap;

use serde_json::Value;
use tablepro_records::record_id::library_ids_match;
use tablepro_storage::TeamLibraryCopy;

use super::super::{PassReport, ServiceSync, Session, begin};
use super::{library_kind, team_of};
use crate::api::control::ConflictChoice;
use crate::api::error::SyncError;
use crate::api::ids::{RecordKey, ScopeName};
use crate::api::state::{Row, RowKey};

impl ServiceSync {
    // A delete left unfinished is finished before anything reads the team scopes; until it is, they stay out.
    pub(in crate::service) async fn before_team_pass(&self) {
        if self.team_library.attached.get().is_none() || !self.team_library_off() {
            return;
        }
        if let Err(error) = self.finish_delete().await {
            tracing::warn!(code = error.code(), "the team library delete waits for the next pass");
        }
    }

    // Never fails the pass: what it could not record waits for the next one.
    pub(in crate::service) async fn after_team_pass(&self, session: &Session, outcome: &Result<PassReport, SyncError>) {
        if self.team_library.attached.get().is_none() || self.team_library_off() {
            return;
        }
        if let Err(error) = self.record_team_pass(session, outcome).await {
            tracing::warn!(code = error.code(), "team library state after the pass");
        }
    }

    async fn record_team_pass(
        &self,
        session: &Session,
        outcome: &Result<PassReport, SyncError>,
    ) -> Result<(), SyncError> {
        let Some(body) = &session.body else {
            return Ok(());
        };
        let teams: Vec<ScopeName> = body
            .scopes
            .iter()
            .filter(|info| team_of(info.scope).is_some())
            .map(|info| info.scope)
            .collect();
        let report = match outcome {
            Ok(report) => report,
            Err(error) => {
                let code = error.code().to_owned();
                self.set_problems(teams.iter().map(|scope| (*scope, code.clone())).collect());
                return Ok(());
            }
        };
        let skipped: HashMap<ScopeName, String> = report
            .skipped
            .iter()
            .filter(|(scope, _)| team_of(*scope).is_some())
            .map(|(scope, code)| (*scope, (*code).to_owned()))
            .collect();
        let now = self.clock.now_ms();
        for scope in teams.iter().filter(|scope| !skipped.contains_key(scope)) {
            self.update_local(*scope, move |local| local.synced_at_ms = Some(now))
                .await?;
            self.apply_imports(session, *scope).await?;
        }
        self.set_problems(skipped);
        self.drop_unreached(session, &teams).await
    }

    // A team the account lost its seat in goes with what this device held of it, once nothing of it is left unsent.
    async fn drop_unreached(&self, session: &Session, reached: &[ScopeName]) -> Result<(), SyncError> {
        for scope in self.known_teams(session).await? {
            if reached.contains(&scope) || !self.team_diff(scope).await?.is_empty() {
                continue;
            }
            if !self.team_local(scope).await?.imports.is_empty() {
                continue;
            }
            self.drop_library_rows(&[scope]).await?;
            let team = scope.wire();
            self.store_call(move |store| store.remove_team_blocking(&team)).await?;
        }
        Ok(())
    }

    // The device's side of a team library conflict, read before the answer removes it. None for any other record.
    pub(in crate::service) async fn team_conflict_side(
        &self,
        key: &RecordKey,
    ) -> Result<Option<Option<Value>>, SyncError> {
        if self.team_library.attached.get().is_none() || key.kind.known().and_then(library_kind).is_none() {
            return Ok(None);
        }
        Ok(
            match begin(&self.state).await?.get(&RowKey::Conflict(key.clone())).await? {
                Some(Row::Conflict(row)) => Some(row.mine),
                _ => None,
            },
        )
    }

    // Keep Theirs turns this device's copy down, so a later publish leaves the team's alone until the copy here changes,
    // and a deletion the team kept is no longer this device's to make. Keep Mine undoes an earlier Keep Theirs.
    pub(in crate::service) async fn team_resolved(
        &self,
        key: &RecordKey,
        keep: ConflictChoice,
        mine: Option<Value>,
    ) -> Result<(), SyncError> {
        let Some(kind) = key.kind.known().and_then(library_kind) else {
            return Ok(());
        };
        let id = key.record_id.clone();
        self.update_local(key.scope, move |local| {
            let named = |held_kind, held_id: &str| held_kind == kind && library_ids_match(held_id, &id);
            local.declined.retain(|copy| !named(copy.kind, &copy.id));
            if keep == ConflictChoice::KeepMine {
                return;
            }
            local.claims.retain(|claim| !named(claim.kind, &claim.id));
            match mine {
                Some(fields) => local.declined.push(TeamLibraryCopy {
                    kind,
                    id: id.clone(),
                    fields,
                }),
                None => local.published.retain(|held| !named(held.kind, &held.id)),
            }
        })
        .await
    }
}
