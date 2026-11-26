// The edits the library 0.88 kept, as the Mac's first core launch hands them over. They are kept on disk at once and
// applied once their team is pulled: an edit made against the version the team still holds goes up as it is, and one
// the team changed since is merged against the facade's base the way a pull merges, so a member both sides changed asks
// Keep Mine or Keep Theirs. Nothing is lost offline, and nothing goes up without its base (0054, The offline queue is
// on disk).

use serde_json::Value;
use tablepro_records::record_id::library_ids_match;
use tablepro_storage::{TeamLibraryCopy, TeamLibraryImported, TeamLibraryKind, TeamLibraryLocal, TeamLibraryRef};

use super::super::{ServiceSync, Session, begin};
use super::plan::{kind_of, with_unknown_members};
use super::writes;
use crate::api::adapter::{LocalChange, LocalRecord};
use crate::api::error::SyncError;
use crate::api::ids::{ChangeTag, KindName, RecordKey, ScopeName};
use crate::api::state::{BaseRow, ConflictRow, Row, RowKey, Standing};
use crate::api::team_library::{TeamLibraryError, TeamLibraryImport};
use crate::api::transport::{DeletedReason, PulledRecord};
use crate::engine::{JournalEntry, Judgement, settle};

// What one edit leaves: the store's write and a conflict to ask about; None while it waits.
struct Applied {
    change: Option<LocalChange>,
    conflict: Option<ConflictRow>,
    claim: Option<Value>,
}

fn keep(local: &mut TeamLibraryLocal, import: TeamLibraryImport) {
    for edit in import.edits {
        local
            .imports
            .retain(|held| !(held.kind == edit.item.kind && library_ids_match(&held.id, &edit.item.id)));
        local.imports.push(TeamLibraryImported {
            kind: edit.item.kind,
            id: edit.item.id,
            base_version: edit.base.as_ref().map(|base| base.version),
            base_fields: edit.base.and_then(|base| base.fields),
            fields: edit.fields,
            moved: edit.moved,
            refused: None,
        });
    }
    for item in import.published {
        if !local.published.iter().any(|held| held.names(item.kind, &item.id)) {
            local.published.push(TeamLibraryRef {
                kind: item.kind,
                id: item.id,
            });
        }
    }
    for (item, fields) in import.declined {
        local
            .declined
            .retain(|held| !(held.kind == item.kind && library_ids_match(&held.id, &item.id)));
        local.declined.push(TeamLibraryCopy {
            kind: item.kind,
            id: item.id,
            fields,
        });
    }
}

impl ServiceSync {
    pub(super) async fn keep_imports(&self, teams: Vec<TeamLibraryImport>) -> Result<(), SyncError> {
        for import in teams {
            let scope = ScopeName::Team(import.team);
            self.update_local(scope, move |local| keep(local, import)).await?;
        }
        Ok(())
    }

    // Once the team is pulled. A team this account only reads takes none of them: they stay listed until discarded.
    pub(super) async fn apply_imports(&self, session: &Session, scope: ScopeName) -> Result<(), SyncError> {
        let local = self.team_local(scope).await?;
        if local.imports.is_empty() {
            return Ok(());
        }
        let Some(info) = session
            .body
            .as_ref()
            .and_then(|body| body.scopes.iter().find(|info| info.scope == scope))
        else {
            return Ok(());
        };
        let code = TeamLibraryError::NotWritable.code();
        let writable = writes(info.role);
        // A role that writes again takes what it was refused for the role.
        self.update_local(scope, move |local| {
            for imported in &mut local.imports {
                match (writable, imported.refused.as_deref()) {
                    (false, None) => imported.refused = Some(code.to_owned()),
                    (true, Some(refused)) if refused == code => imported.refused = None,
                    _ => {}
                }
            }
        })
        .await?;
        if !writable {
            return Ok(());
        }
        let local = self.team_local(scope).await?;
        let pulled = self
            .scope_row(scope)
            .await?
            .is_some_and(|row| row.epoch.is_some() && row.caught_up && !row.refill);
        if !pulled || !self.team_sign_in_holds() {
            return Ok(());
        }
        let _read = self.policy_read().await?;
        self.apply_each(scope, local.imports).await
    }

    async fn apply_each(&self, scope: ScopeName, imports: Vec<TeamLibraryImported>) -> Result<(), SyncError> {
        let bases = self.team_bases(scope).await?;
        let mut done = Vec::new();
        let mut claims = Vec::new();
        for (kind, adapter) in self.library_adapters(scope) {
            let records = adapter.records(scope).await?.records;
            let mut changes = Vec::new();
            let mut conflicts = Vec::new();
            for imported in imports
                .iter()
                .filter(|imported| imported.kind == kind && imported.refused.is_none())
            {
                let Some(applied) = self.applied(scope, imported, &records, &bases).await? else {
                    continue;
                };
                changes.extend(applied.change);
                conflicts.extend(applied.conflict);
                if let Some(fields) = applied.claim.filter(|_| !imported.moved) {
                    claims.push(TeamLibraryCopy {
                        kind,
                        id: imported.id.clone(),
                        fields,
                    });
                }
                done.push((kind, imported.id.clone()));
            }
            if !conflicts.is_empty() {
                self.check_stop()?;
                let mut txn = begin(&self.state).await?;
                for conflict in conflicts {
                    txn.put(Row::Conflict(conflict)).await?;
                }
                txn.commit().await?;
            }
            if !changes.is_empty() {
                let (written, deleted) = changed_ids(&changes);
                self.check_stop()?;
                adapter.apply(scope, changes).await?;
                // The next pass sends them, as a store's own write would ask for it (0060).
                self.journal.changed(&[JournalEntry {
                    kind: adapter.kind(),
                    written,
                    deleted,
                }]);
            }
        }
        self.update_local(scope, move |local| {
            local.imports.retain(|held| {
                !done
                    .iter()
                    .any(|(kind, id)| held.kind == *kind && library_ids_match(&held.id, id))
            });
            local.claims.extend(claims);
        })
        .await?;
        self.refresh_counts().await;
        Ok(())
    }

    async fn applied(
        &self,
        scope: ScopeName,
        imported: &TeamLibraryImported,
        records: &[LocalRecord],
        bases: &[(TeamLibraryKind, BaseRow)],
    ) -> Result<Option<Applied>, SyncError> {
        let current = bases
            .iter()
            .find(|(kind, base)| *kind == imported.kind && library_ids_match(&base.key.record_id, &imported.id))
            .map(|(_, base)| base);
        let stored = records
            .iter()
            .find(|record| library_ids_match(&record.record_id, &imported.id));
        let id = stored
            .map(|record| record.record_id.clone())
            .or_else(|| current.map(|base| base.key.record_id.clone()))
            .unwrap_or_else(|| imported.id.clone());
        let key = RecordKey::new(scope, KindName::of(kind_of(imported.kind)), id.clone());
        let open = begin(&self.state).await?.get(&RowKey::Conflict(key.clone())).await?;
        let live = current.filter(|base| base.deleted.is_none());
        // A copy the team holds that the store does not waits for the person, so the edit waits with it.
        if open.is_some() || (live.is_some() && stored.is_none()) {
            return Ok(None);
        }
        let unchanged = match (imported.base_version, live) {
            (Some(version), Some(base)) => base.version == Some(version),
            (None, None) => current.is_none(),
            _ => false,
        };
        let theirs = stored.map(|record| &record.fields);
        let mine = imported
            .fields
            .clone()
            .map(|fields| with_unknown_members(imported.kind, theirs, fields));
        if unchanged {
            return Ok(Some(direct(&id, mine, stored.is_some())));
        }
        // An edit 0.88 sent without a base asks before it brings back what the team deleted, as the facade did.
        let deleted = current.is_some_and(|base| base.deleted == Some(DeletedReason::User));
        if let (true, None, None, Some(fields)) = (deleted, imported.base_version, stored, &mine) {
            return Ok(Some(Applied {
                change: None,
                conflict: Some(ConflictRow {
                    key,
                    base: None,
                    mine: Some(fields.clone()),
                    theirs: None,
                }),
                claim: mine,
            }));
        }
        Ok(Some(merged(&key, imported, theirs, mine)))
    }
}

fn changed_ids(changes: &[LocalChange]) -> (Vec<String>, Vec<String>) {
    let mut written = Vec::new();
    let mut deleted = Vec::new();
    for change in changes {
        match change {
            LocalChange::Put { record_id, .. } => written.push(record_id.clone()),
            LocalChange::Delete { record_id } => deleted.push(record_id.clone()),
        }
    }
    (written, deleted)
}

fn direct(id: &str, mine: Option<Value>, stored: bool) -> Applied {
    Applied {
        change: match &mine {
            Some(fields) => Some(LocalChange::Put {
                record_id: id.to_owned(),
                fields: fields.clone(),
            }),
            None => stored.then(|| LocalChange::Delete {
                record_id: id.to_owned(),
            }),
        },
        conflict: None,
        claim: mine,
    }
}

// The facade's base, the edit and the team's copy as this device accepted it, merged as a pull merges.
fn merged(key: &RecordKey, imported: &TeamLibraryImported, theirs: Option<&Value>, mine: Option<Value>) -> Applied {
    let base = imported.base_version.map(|version| BaseRow {
        key: key.clone(),
        tag: ChangeTag::Service(String::new()),
        version: Some(version),
        revision: None,
        epoch: None,
        deleted: None,
        fields: imported.base_fields.clone(),
        created_ms: None,
    });
    let pulled = PulledRecord {
        kind: key.kind.clone(),
        record_id: key.record_id.clone(),
        tag: ChangeTag::Service("facade-import".to_owned()),
        fields: theirs.cloned(),
        fields_json: None,
        deleted: theirs.is_none().then_some(DeletedReason::User),
        service: None,
    };
    let local = mine.clone().map(|fields| LocalRecord {
        record_id: key.record_id.clone(),
        fields,
        standing: Standing::Syncs,
    });
    let kind = kind_of(imported.kind);
    let settled = settle(key, kind, Judgement::Merge, base.as_ref(), local.as_ref(), &pulled);
    let change = match (&settled.conflict, settled.kept) {
        (Some(_), None) => None,
        (_, Some(record)) => (theirs != Some(&record)).then(|| LocalChange::Put {
            record_id: key.record_id.clone(),
            fields: record,
        }),
        (None, None) => theirs.map(|_| LocalChange::Delete {
            record_id: key.record_id.clone(),
        }),
    };
    Applied {
        change,
        claim: mine,
        conflict: settled.conflict,
    }
}
