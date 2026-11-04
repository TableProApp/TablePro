use std::collections::hash_map::Entry;
use std::collections::{HashMap, HashSet};

use tablepro_storage::saved_queries::NewSavedQuery;
use tablepro_storage::{ConnectionStore, ImportedConnection, SavedConnection, SavedQueries, StorageError};
use uuid::Uuid;

use super::plan::PlannedTarget;
use super::{ImportPlan, ImportReview, ImportedSecret};

#[derive(Debug, Clone)]
pub struct AppliedConnection {
    pub reference: String,
    // As saved, with its id and the name the library gave it.
    pub connection: SavedConnection,
    pub replaced: bool,
    // For the keyring, under `connection.id`.
    pub secrets: Vec<ImportedSecret>,
}

#[derive(Debug, Clone)]
pub struct ImportedQuery {
    pub reference: String,
    pub query: NewSavedQuery,
}

#[derive(Debug, Clone, Default)]
pub struct AppliedImport {
    pub connections: Vec<AppliedConnection>,
    pub queries: Vec<ImportedQuery>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct QueryImportOutcome {
    pub added: usize,
    // The connection already holds a query of that name, which a save would overwrite.
    pub already_saved: usize,
    pub failed: usize,
}

// Refused with ImportOutdated when the library changed since the review, which would make its
// duplicates, and the connections Keep Existing names, stale.
pub fn apply_blocking(
    review: &ImportReview,
    plan: &ImportPlan,
    store: &ConnectionStore,
) -> Result<AppliedImport, StorageError> {
    let entries = plan
        .connections()
        .iter()
        .map(|planned| ImportedConnection {
            connection: planned.connection.clone(),
            group_path: planned.group_path.clone(),
            replaces: planned.replaces,
        })
        .collect();
    let saved = store.add_imported_blocking(review.library(), entries)?;

    let mut connections = Vec::with_capacity(saved.len());
    for (planned, connection) in plan.connections().iter().zip(saved) {
        let secrets = review
            .connection_row(&planned.reference)
            .map(|row| row.secrets.clone())
            .unwrap_or_default();
        connections.push(AppliedConnection {
            reference: planned.reference.clone(),
            replaced: planned.replaces == Some(connection.id),
            connection,
            secrets,
        });
    }

    let mut targets: HashMap<&str, (Uuid, &str)> = HashMap::new();
    let mut names: HashMap<Uuid, &str> = review
        .library()
        .connections
        .iter()
        .map(|existing| (existing.id, existing.name.as_str()))
        .collect();
    for applied in &connections {
        targets.insert(
            applied.reference.as_str(),
            (applied.connection.id, applied.connection.name.as_str()),
        );
        names.insert(applied.connection.id, applied.connection.name.as_str());
    }
    let queries = plan
        .queries()
        .iter()
        .filter_map(|planned| {
            let (connection_id, connection_name) = match &planned.target {
                PlannedTarget::Imported(reference) => targets.get(reference.as_str()).copied()?,
                PlannedTarget::Existing(id) => (*id, names.get(id).copied()?),
            };
            let text = review.query_row(&planned.reference)?.text.clone()?;
            Some(ImportedQuery {
                reference: planned.reference.clone(),
                query: NewSavedQuery {
                    name: planned.name.clone(),
                    query: text,
                    connection_id,
                    connection_name: connection_name.to_owned(),
                },
            })
        })
        .collect();
    Ok(AppliedImport { connections, queries })
}

// A name the connection already holds is left alone, since a save under it would overwrite that query.
pub async fn save_queries(applied: &AppliedImport, store: &SavedQueries) -> QueryImportOutcome {
    let mut outcome = QueryImportOutcome::default();
    let mut held: HashMap<Uuid, Option<HashSet<String>>> = HashMap::new();
    for imported in &applied.queries {
        let connection = imported.query.connection_id;
        let names = match held.entry(connection) {
            Entry::Occupied(entry) => entry.into_mut(),
            Entry::Vacant(entry) => entry.insert(held_names(store, connection).await),
        };
        let Some(names) = names else {
            outcome.failed += 1;
            continue;
        };
        let name = imported.query.name.trim();
        if names.contains(name) {
            outcome.already_saved += 1;
            continue;
        }
        match store.save_if_new(imported.query.clone()).await {
            Ok(Some(_)) => {
                names.insert(name.to_owned());
                outcome.added += 1;
            }
            // Saved by another window since the names were read.
            Ok(None) => {
                names.insert(name.to_owned());
                outcome.already_saved += 1;
            }
            Err(error) => {
                tracing::warn!(code = error.code(), "an imported saved query was not saved");
                outcome.failed += 1;
            }
        }
    }
    outcome
}

async fn held_names(store: &SavedQueries, connection: Uuid) -> Option<HashSet<String>> {
    match store.list(Some(connection)).await {
        Ok(queries) => Some(queries.into_iter().map(|query| query.name).collect()),
        Err(error) => {
            tracing::warn!(
                code = error.code(),
                "the saved queries of an imported connection were not read"
            );
            None
        }
    }
}
