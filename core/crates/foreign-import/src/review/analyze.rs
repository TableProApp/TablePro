use std::collections::{HashMap, HashSet};

use tablepro_core::DriverRegistry;
use tablepro_storage::{ConnectionGroup, ConnectionGroupName, SavedConnection};

use super::mapping::{self, Mapped};
use super::match_key::MatchKey;
use super::notes::{self, RowNote};
use super::{ConnectionRow, ExistingConnection, ImportReview, QueryRow, Resolution, ReviewInputs};
use crate::{CollectedConnection, CollectedImport, CollectedSavedQuery, SavedQueryContent};

// The cap the library puts on one saved query's text.
pub(super) const MAX_QUERY_BYTES: u64 = 1024 * 1024;

impl ImportReview {
    pub fn analyze(collected: CollectedImport, inputs: ReviewInputs<'_>) -> Self {
        let queries = query_rows(&collected);
        let mut query_counts: HashMap<&str, usize> = HashMap::new();
        for query in &queries {
            if let Some(connection) = &query.connection {
                *query_counts.entry(connection.as_str()).or_default() += 1;
            }
        }

        let mut existing_by_key: HashMap<MatchKey, &SavedConnection> = HashMap::new();
        for existing in inputs.library.connections.iter() {
            existing_by_key
                .entry(library_key(existing, inputs.drivers))
                .or_insert(existing);
        }

        let connections = collected
            .connections
            .iter()
            .map(|connection| {
                let saved_query_count = query_counts.get(connection.reference.as_str()).copied().unwrap_or(0);
                row(connection, saved_query_count, &existing_by_key, &inputs)
            })
            .collect();

        Self {
            app: collected.app,
            passwords: collected.passwords,
            connections,
            queries,
            library: inputs.library,
        }
    }
}

fn row(
    collected: &CollectedConnection,
    saved_query_count: usize,
    existing_by_key: &HashMap<MatchKey, &SavedConnection>,
    inputs: &ReviewInputs<'_>,
) -> ConnectionRow {
    let settings = &collected.settings;
    let driver = mapping::driver_id(&settings.engine).and_then(|id| inputs.drivers.get(id));
    let mapped = driver
        .as_ref()
        .map(|driver| mapping::map(settings, collected.credentials.as_ref(), driver.as_ref(), inputs.dirs));

    let key = match (&mapped, &driver) {
        (Some(mapped), Some(driver)) => connection_key(&mapped.connection, driver.capabilities().is_key_value()),
        _ => MatchKey::new(
            &settings.host,
            settings.port,
            &settings.database,
            &settings.username,
            false,
        ),
    };
    let existing = existing_by_key.get(&key).copied();
    let duplicate = existing.map(|existing| ExistingConnection {
        id: existing.id,
        name: existing.name.clone(),
    });

    let mut row_notes = Vec::new();
    if mapped.is_none() {
        row_notes.push(RowNote::UnsupportedEngine {
            engine: settings.engine.clone(),
        });
    }
    row_notes.extend(notes::missing_files(settings, inputs.dirs, inputs.file_exists));

    let resolutions = match (&mapped, existing) {
        (None, _) => Vec::new(),
        (Some(_), None) => vec![Resolution::Add],
        (Some(mapped), Some(existing)) => duplicate_resolutions(existing, &mapped.connection, saved_query_count > 0),
    };
    let (connection, secrets) = match mapped {
        Some(Mapped {
            connection,
            notes,
            secrets,
        }) => {
            row_notes.extend(notes);
            (Some(connection), secrets)
        }
        None => (None, Vec::new()),
    };

    ConnectionRow {
        reference: collected.reference.clone(),
        name: settings.name.clone(),
        engine: settings.engine.clone(),
        // A connection whose TLS could not be read waits for the user, since importing it turns TLS off.
        selected_by_default: duplicate.is_none()
            && connection.is_some()
            && !row_notes.contains(&RowNote::TlsSettingsNotRead),
        connection,
        group_path: group_path(&collected.group_path),
        duplicate,
        resolutions,
        notes: row_notes,
        saved_query_count,
        carries_credentials: !secrets.is_empty(),
        secrets,
    }
}

// Replace keeps the saved id, and with it every secret saved under that id, so it is offered only to an
// entry that connects like the saved connection. Any other duplicate is added as a copy with a new id.
fn duplicate_resolutions(
    existing: &SavedConnection,
    mapped: &SavedConnection,
    carries_queries: bool,
) -> Vec<Resolution> {
    let mut resolutions = Vec::with_capacity(3);
    if carries_queries {
        resolutions.push(Resolution::KeepExisting(existing.id));
    }
    resolutions.push(Resolution::AddCopy);
    let in_place = SavedConnection {
        id: existing.id,
        ..mapped.clone()
    };
    if existing.connects_like(&in_place) {
        resolutions.push(Resolution::Replace(existing.id));
    }
    resolutions
}

fn library_key(saved: &SavedConnection, drivers: &DriverRegistry) -> MatchKey {
    let key_value = drivers
        .get(&saved.driver_id)
        .is_some_and(|driver| driver.capabilities().is_key_value());
    connection_key(saved, key_value)
}

fn connection_key(saved: &SavedConnection, key_value: bool) -> MatchKey {
    MatchKey::new(&saved.host, saved.port, &saved.database, &saved.username, key_value)
}

fn group_path(path: &[String]) -> Vec<String> {
    path.iter()
        .filter_map(|name| ConnectionGroupName::new(name).ok())
        .take(ConnectionGroup::MAX_DEPTH)
        .map(String::from)
        .collect()
}

fn query_rows(collected: &CollectedImport) -> Vec<QueryRow> {
    let mut connection_names: HashMap<&str, &str> = HashMap::new();
    for connection in &collected.connections {
        connection_names
            .entry(connection.reference.as_str())
            .or_insert(connection.settings.name.as_str());
    }
    let connection_name = |query: &CollectedSavedQuery| {
        query
            .connection
            .as_deref()
            .and_then(|reference| connection_names.get(reference))
            .map(|name| (*name).to_owned())
    };

    let mut rows = Vec::with_capacity(collected.saved_queries.len());
    let mut seen: HashSet<(Option<&str>, String, &str)> = HashSet::new();
    for query in &collected.saved_queries {
        let SavedQueryContent::Text(text) = &query.content else {
            continue;
        };
        let key = (
            query.connection.as_deref(),
            query.name.trim().to_lowercase(),
            text.trim(),
        );
        if !seen.insert(key) {
            continue;
        }
        let byte_count = text.len() as u64;
        rows.push(QueryRow {
            reference: query.reference.clone(),
            name: query_name(&query.name, text),
            connection: query.connection.clone(),
            connection_name: connection_name(query),
            byte_count,
            too_large: byte_count > MAX_QUERY_BYTES,
            suggested: query.suggested,
            text: Some(text.clone()),
        });
    }
    // As on macOS, files too large to read follow the rest.
    for query in &collected.saved_queries {
        let SavedQueryContent::Oversized { byte_count } = query.content else {
            continue;
        };
        rows.push(QueryRow {
            reference: query.reference.clone(),
            name: query_name(&query.name, ""),
            connection: query.connection.clone(),
            connection_name: connection_name(query),
            byte_count,
            too_large: true,
            suggested: false,
            text: None,
        });
    }
    rows
}

fn query_name(name: &str, text: &str) -> String {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        derived_name(text)
    } else {
        trimmed.to_owned()
    }
}

// The first line with text, or the text of the first comment that has some.
fn derived_name(text: &str) -> String {
    for line in text.split(['\n', '\r']) {
        let line = line.trim_matches([' ', '\t']);
        let shown = match line.strip_prefix("--") {
            Some(comment) => comment.trim_matches([' ', '\t']),
            None => line,
        };
        if !shown.is_empty() {
            return shown.chars().take(50).collect();
        }
    }
    "Untitled".to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_blank_name_comes_from_the_first_comment_or_line_with_text() {
        assert_eq!(derived_name("-- Active users\nselect 1"), "Active users");
        assert_eq!(derived_name("\r\n  --  \n\tselect 2 \n"), "select 2");
        assert_eq!(derived_name(&"x".repeat(80)), "x".repeat(50));
        assert_eq!(derived_name(" \n--\n"), "Untitled");
    }
}
