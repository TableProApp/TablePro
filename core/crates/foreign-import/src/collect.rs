use std::collections::{HashMap, HashSet};

use crate::{
    ForeignApp, ForeignConnection, ForeignConnectionRecord, ForeignCredentials, ForeignImportError, ForeignSavedQuery,
    SavedQueryContent,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PasswordOutcome {
    NotRequested,
    Read,
    // The user refused a keychain prompt, or the app's store was locked, so the rest were not read.
    Stopped,
    // The app keeps them in a keychain this platform does not let another app read.
    LeftInKeychain,
}

#[derive(Debug, Clone)]
pub struct CollectedImport {
    pub app: ForeignApp,
    pub connections: Vec<CollectedConnection>,
    pub saved_queries: Vec<CollectedSavedQuery>,
    pub passwords: PasswordOutcome,
}

#[derive(Debug, Clone)]
pub struct CollectedConnection {
    pub reference: String,
    pub settings: ForeignConnection,
    pub group_path: Vec<String>,
    pub credentials: Option<ForeignCredentials>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CollectedSavedQuery {
    pub reference: String,
    pub name: String,
    pub content: SavedQueryContent,
    pub keyword: Option<String>,
    // A query with no imported connection sits under a folder named after the app.
    pub folder_path: Vec<String>,
    pub connection: Option<String>,
    pub suggested: bool,
}

pub(crate) fn assemble(
    app: ForeignApp,
    connections: Vec<ForeignConnectionRecord>,
    saved_queries: Vec<ForeignSavedQuery>,
    passwords: PasswordOutcome,
) -> Result<CollectedImport, ForeignImportError> {
    if connections.is_empty() && saved_queries.is_empty() {
        return Err(ForeignImportError::NothingFound);
    }

    let mut used: HashSet<String> = HashSet::with_capacity(connections.len());
    let mut by_source: HashMap<String, String> = HashMap::with_capacity(connections.len());
    let mut collected = Vec::with_capacity(connections.len());
    for (index, record) in connections.into_iter().enumerate() {
        let source = record.source_id.filter(|id| !id.is_empty());
        let reference = unique_reference(
            source.clone().unwrap_or_else(|| format!("row-{index}")),
            index,
            &mut used,
        );
        if let Some(source) = source {
            by_source.entry(source).or_insert_with(|| reference.clone());
        }
        collected.push(CollectedConnection {
            reference,
            settings: record.settings,
            group_path: record.group_path,
            credentials: record.credentials.and_then(ForeignCredentials::non_empty),
        });
    }

    let queries = saved_queries
        .into_iter()
        .enumerate()
        .map(|(index, query)| {
            let connection = query
                .source_connection_id
                .as_ref()
                .and_then(|id| by_source.get(id))
                .cloned();
            // A query bound to a connection that is not imported still lands, global and unchecked.
            let unmapped = query.source_connection_id.is_some() && connection.is_none();
            let folder_path = match connection {
                Some(_) => query.folder_path,
                None => std::iter::once(app.display_name().to_owned())
                    .chain(query.folder_path)
                    .collect(),
            };
            let suggested = match query.content {
                SavedQueryContent::Text(_) => !query.is_auto_named && !unmapped,
                SavedQueryContent::Oversized { .. } => false,
            };
            CollectedSavedQuery {
                reference: format!("query-{}", index + 1),
                name: query.name,
                content: query.content,
                keyword: query.keyword,
                folder_path,
                connection,
                suggested,
            }
        })
        .collect();

    Ok(CollectedImport {
        app,
        connections: collected,
        saved_queries: queries,
        passwords,
    })
}

fn unique_reference(base: String, index: usize, used: &mut HashSet<String>) -> String {
    let mut candidate = base.clone();
    let mut suffix = index;
    while !used.insert(candidate.clone()) {
        candidate = format!("{base}-{suffix}");
        suffix += 1;
    }
    candidate
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::*;

    fn record(source: Option<&str>, name: &str) -> ForeignConnectionRecord {
        ForeignConnectionRecord {
            source_id: source.map(str::to_owned),
            settings: ForeignConnection {
                name: name.to_owned(),
                host: "localhost".to_owned(),
                port: 5432,
                database: String::new(),
                username: String::new(),
                engine: "PostgreSQL".to_owned(),
                ssh: None,
                ssl: None,
                color: None,
                additional_fields: BTreeMap::new(),
            },
            group_path: Vec::new(),
            credentials: Some(ForeignCredentials::default()),
        }
    }

    fn query(name: &str, connection: Option<&str>, auto: bool) -> ForeignSavedQuery {
        ForeignSavedQuery {
            name: name.to_owned(),
            content: SavedQueryContent::Text("SELECT 1".to_owned()),
            keyword: None,
            folder_path: vec!["Reports".to_owned()],
            source_connection_id: connection.map(str::to_owned),
            is_auto_named: auto,
        }
    }

    #[test]
    fn nothing_to_import_is_an_error() {
        let outcome = assemble(ForeignApp::DBeaver, Vec::new(), Vec::new(), PasswordOutcome::Read);
        assert!(matches!(outcome, Err(ForeignImportError::NothingFound)));
    }

    #[test]
    fn references_come_from_source_ids_and_stay_unique() {
        let collected = assemble(
            ForeignApp::DBeaver,
            vec![
                record(Some("a"), "one"),
                record(Some("a"), "two"),
                record(None, "three"),
                record(Some(""), "four"),
            ],
            Vec::new(),
            PasswordOutcome::Read,
        )
        .expect("an import");
        let references: Vec<&str> = collected.connections.iter().map(|c| c.reference.as_str()).collect();
        assert_eq!(references, ["a", "a-1", "row-2", "row-3"]);
        assert!(collected.connections.iter().all(|c| c.credentials.is_none()));
    }

    #[test]
    fn queries_follow_their_connection_or_land_in_the_apps_folder_unchecked() {
        let collected = assemble(
            ForeignApp::DataGrip,
            vec![record(Some("uuid-1"), "prod")],
            vec![
                query("report", Some("uuid-1"), false),
                query("console_2", Some("uuid-1"), true),
                query("orphan", Some("gone"), false),
                query("global", None, false),
            ],
            PasswordOutcome::Read,
        )
        .expect("an import");
        let queries = &collected.saved_queries;
        assert_eq!(queries[0].connection.as_deref(), Some("uuid-1"));
        assert_eq!(queries[0].folder_path, ["Reports"]);
        assert!(queries[0].suggested);
        assert!(!queries[1].suggested);
        assert_eq!(queries[2].connection, None);
        assert_eq!(queries[2].folder_path, ["DataGrip", "Reports"]);
        assert!(!queries[2].suggested);
        assert!(queries[3].suggested);
        assert_eq!(queries[3].reference, "query-4");
    }
}
