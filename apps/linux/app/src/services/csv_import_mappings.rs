use std::collections::HashMap;
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use tablepro_core::ColumnInfo;
use uuid::Uuid;

use super::config_io::xdg_config_path;
use super::state_file::StateFile;

const FILE: &str = "csv_import_mappings.json";
const MAX_COLUMNS: usize = 512;
const MAX_SCOPES: usize = 2_000;
const MAX_FILE_BYTES: usize = 256 * 1024;

#[derive(Clone)]
pub struct CsvMappingStore {
    file: Arc<StateFile<Mappings>>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CsvMappingScope {
    pub connection_id: Uuid,
    pub database: String,
    pub driver_id: String,
    pub schema: Option<String>,
    pub table: String,
}

#[derive(Clone, Default, Deserialize, Serialize)]
struct Mappings(HashMap<String, StoredMapping>);

#[derive(Clone, Deserialize, Serialize)]
struct StoredMapping {
    columns: Vec<StoredColumn>,
}

#[derive(Clone, Deserialize, Serialize)]
struct StoredColumn {
    target: String,
    source: Option<StoredHeader>,
}

#[derive(Clone, Deserialize, Serialize)]
struct StoredHeader {
    name: String,
    occurrence: usize,
}

impl CsvMappingScope {
    fn storage_key(&self) -> String {
        serde_json::to_string(&(
            self.connection_id,
            &self.database,
            &self.driver_id,
            &self.schema,
            &self.table,
        ))
        .unwrap_or_default()
    }
}

impl CsvMappingStore {
    pub fn open() -> Option<Self> {
        Some(Self::load_at(xdg_config_path(FILE)?))
    }

    fn load_at(path: std::path::PathBuf) -> Self {
        Self {
            file: Arc::new(StateFile::load(path)),
        }
    }

    pub fn save(
        &self,
        scope: &CsvMappingScope,
        headers: &[String],
        columns: &[ColumnInfo],
        mapping: &[Option<usize>],
        has_header: bool,
    ) -> Result<(), String> {
        validate_scope(scope)?;
        validate_inputs(headers, columns, mapping, has_header)?;
        let stored = StoredMapping {
            columns: columns
                .iter()
                .zip(mapping)
                .map(|(column, source)| {
                    Ok(StoredColumn {
                        target: column.name.clone(),
                        source: source.map(|index| header_identity(headers, index)).transpose()?,
                    })
                })
                .collect::<Result<_, String>>()?,
        };
        if serde_json::to_vec(&stored).map_err(|error| error.to_string())?.len() > MAX_FILE_BYTES {
            return Err("This column mapping is too large to save.".into());
        }
        let mut refusal = None;
        self.file.update(|mappings| {
            let key = scope.storage_key();
            if mappings.0.len() >= MAX_SCOPES && !mappings.0.contains_key(&key) {
                refusal = Some("The saved column mapping limit has been reached.");
            } else {
                let mut next = mappings.clone();
                next.0.insert(key, stored);
                match serde_json::to_vec(&next) {
                    Ok(bytes) if bytes.len() <= MAX_FILE_BYTES => *mappings = next,
                    _ => refusal = Some("Saved column mappings reached their storage limit."),
                }
            }
        })?;
        if let Some(message) = refusal {
            return Err(message.into());
        }
        Ok(())
    }

    pub fn restore(
        &self,
        scope: &CsvMappingScope,
        headers: &[String],
        columns: &[ColumnInfo],
        has_header: bool,
    ) -> Result<Option<Vec<Option<usize>>>, String> {
        validate_scope(scope)?;
        if !has_header {
            return Err("Saved mappings require a header row.".into());
        }
        validate_dimensions(headers, columns)?;
        let Some(stored) = self
            .file
            .read(|mappings| mappings.0.get(&scope.storage_key()).cloned())
            .flatten()
        else {
            return Ok(None);
        };
        if stored.columns.len() > MAX_COLUMNS {
            return Err("The saved column mapping is invalid.".into());
        }
        let mut result = vec![None; columns.len()];
        let mut seen_targets = std::collections::HashSet::new();
        for stored_column in stored.columns {
            if stored_column.target.is_empty() || !seen_targets.insert(stored_column.target.clone()) {
                return Err("The saved column mapping has duplicate or empty destination names.".into());
            }
            let matches: Vec<usize> = columns
                .iter()
                .enumerate()
                .filter_map(|(index, column)| (column.name == stored_column.target).then_some(index))
                .collect();
            let [target] = matches.as_slice() else {
                return Err("A saved destination column is missing or ambiguous. Review the mapping manually.".into());
            };
            if let Some(source) = stored_column.source {
                if server_managed(&columns[*target]) {
                    return Err("A saved mapping targets a database-generated column.".into());
                }
                result[*target] = Some(resolve_header(headers, &source)?);
            }
        }
        Ok(Some(result))
    }

    pub fn forget(&self, scope: &CsvMappingScope) -> Result<bool, String> {
        validate_scope(scope)?;
        let mut removed = false;
        self.file
            .update(|mappings| removed = mappings.0.remove(&scope.storage_key()).is_some())?;
        Ok(removed)
    }

    pub fn flush(&self) -> Result<(), String> {
        self.file.flush()
    }
}

fn validate_scope(scope: &CsvMappingScope) -> Result<(), String> {
    if scope.database.len() > 1024
        || scope.driver_id.len() > 128
        || scope.schema.as_ref().is_some_and(|schema| schema.len() > 1024)
        || scope.table.len() > 1024
    {
        return Err("The connection or table name is too long to save a mapping.".into());
    }
    Ok(())
}

fn validate_inputs(
    headers: &[String],
    columns: &[ColumnInfo],
    mapping: &[Option<usize>],
    has_header: bool,
) -> Result<(), String> {
    if !has_header {
        return Err("Saved mappings require a header row.".into());
    }
    validate_dimensions(headers, columns)?;
    if mapping.len() != columns.len() {
        return Err("The column mapping does not match the destination table.".into());
    }
    let mut targets = std::collections::HashSet::new();
    for (column, source) in columns.iter().zip(mapping) {
        if column.name.is_empty() || !targets.insert(&column.name) {
            return Err("Destination column names are empty or ambiguous.".into());
        }
        if source.is_some_and(|index| index >= headers.len()) || (source.is_some() && server_managed(column)) {
            return Err("The selected mapping is invalid for this table.".into());
        }
    }
    Ok(())
}

fn validate_dimensions(headers: &[String], columns: &[ColumnInfo]) -> Result<(), String> {
    if headers.len() > MAX_COLUMNS || columns.len() > MAX_COLUMNS {
        return Err("This table or CSV has too many columns to save a mapping.".into());
    }
    if headers.iter().any(|header| header.len() > 1024) {
        return Err("A CSV header is too long to save in a mapping.".into());
    }
    Ok(())
}

fn header_identity(headers: &[String], index: usize) -> Result<StoredHeader, String> {
    let name = headers.get(index).ok_or("The selected CSV column no longer exists.")?;
    let occurrence = headers[..=index].iter().filter(|header| *header == name).count();
    Ok(StoredHeader {
        name: name.clone(),
        occurrence,
    })
}

fn resolve_header(headers: &[String], source: &StoredHeader) -> Result<usize, String> {
    if source.occurrence == 0 {
        return Err("The saved CSV header reference is invalid.".into());
    }
    headers
        .iter()
        .enumerate()
        .filter(|(_, name)| **name == source.name)
        .nth(source.occurrence - 1)
        .map(|(index, _)| index)
        .ok_or_else(|| format!("CSV header '{}' is missing. Review the mapping manually.", source.name))
}

fn server_managed(column: &ColumnInfo) -> bool {
    column.is_auto_increment || column.is_generated
}

#[cfg(test)]
mod tests {
    use super::*;

    fn column(name: &str) -> ColumnInfo {
        ColumnInfo {
            name: name.into(),
            data_type: "TEXT".into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        }
    }

    fn scope(connection_id: Uuid, database: &str, table: &str) -> CsvMappingScope {
        CsvMappingScope {
            connection_id,
            database: database.into(),
            driver_id: "postgres".into(),
            schema: Some("public".into()),
            table: table.into(),
        }
    }

    fn headers(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).into()).collect()
    }

    #[test]
    fn restore_resolves_header_names_after_reordering_and_skips_added_columns() {
        let directory = tempfile::tempdir().unwrap();
        let store = CsvMappingStore::load_at(directory.path().join("mappings.json"));
        let scope = scope(Uuid::new_v4(), "appdb", "users");
        store
            .save(
                &scope,
                &headers(&["id", "full name"]),
                &[column("id"), column("name")],
                &[None, Some(1)],
                true,
            )
            .unwrap();
        let restored = store
            .restore(
                &scope,
                &headers(&["full name", "id", "new source"]),
                &[column("id"), column("name"), column("created_at")],
                true,
            )
            .unwrap()
            .unwrap();
        assert_eq!(restored, [None, Some(0), None]);
    }

    #[test]
    fn duplicate_headers_restore_by_name_and_occurrence_not_old_position() {
        let directory = tempfile::tempdir().unwrap();
        let store = CsvMappingStore::load_at(directory.path().join("mappings.json"));
        let scope = scope(Uuid::new_v4(), "appdb", "tags");
        store
            .save(
                &scope,
                &headers(&["tag", "tag", "email"]),
                &[column("label")],
                &[Some(1)],
                true,
            )
            .unwrap();
        assert_eq!(
            store
                .restore(&scope, &headers(&["email", "tag", "tag"]), &[column("label")], true)
                .unwrap()
                .unwrap(),
            [Some(2)]
        );
    }

    #[test]
    fn missing_source_headers_and_renamed_or_ambiguous_targets_are_refused() {
        let directory = tempfile::tempdir().unwrap();
        let store = CsvMappingStore::load_at(directory.path().join("mappings.json"));
        let scope = scope(Uuid::new_v4(), "appdb", "users");
        store
            .save(&scope, &headers(&["full name"]), &[column("name")], &[Some(0)], true)
            .unwrap();
        assert!(
            store
                .restore(&scope, &headers(&["email"]), &[column("name")], true)
                .is_err()
        );
        assert!(
            store
                .restore(&scope, &headers(&["full name"]), &[column("display_name")], true)
                .is_err()
        );
        assert!(
            store
                .restore(
                    &scope,
                    &headers(&["full name"]),
                    &[column("name"), column("name")],
                    true
                )
                .is_err()
        );
    }

    #[test]
    fn mappings_are_isolated_by_connection_and_database() {
        let directory = tempfile::tempdir().unwrap();
        let store = CsvMappingStore::load_at(directory.path().join("mappings.json"));
        let connection_id = Uuid::new_v4();
        let original = scope(connection_id, "appdb", "users");
        store
            .save(
                &original,
                &headers(&["display name"]),
                &[column("name")],
                &[Some(0)],
                true,
            )
            .unwrap();
        assert!(
            store
                .restore(
                    &scope(Uuid::new_v4(), "appdb", "users"),
                    &headers(&["display name"]),
                    &[column("name")],
                    true
                )
                .unwrap()
                .is_none()
        );
        let mut other_schema = original.clone();
        other_schema.schema = Some("private".into());
        let mut other_table = original.clone();
        other_table.table = "accounts".into();
        let mut other_driver = original.clone();
        other_driver.driver_id = "mysql".into();
        for isolated in [other_schema, other_table, other_driver] {
            assert!(
                store
                    .restore(&isolated, &headers(&["display name"]), &[column("name")], true)
                    .unwrap()
                    .is_none()
            );
        }
        assert!(
            store
                .restore(
                    &scope(connection_id, "otherdb", "users"),
                    &headers(&["display name"]),
                    &[column("name")],
                    true
                )
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn mappings_without_headers_and_generated_column_values_are_refused() {
        let directory = tempfile::tempdir().unwrap();
        let store = CsvMappingStore::load_at(directory.path().join("mappings.json"));
        let scope = scope(Uuid::new_v4(), "appdb", "users");
        assert!(
            store
                .save(&scope, &headers(&["Column 1"]), &[column("name")], &[Some(0)], false)
                .is_err()
        );
        assert!(
            store
                .restore(&scope, &headers(&["Column 1"]), &[column("name")], false)
                .is_err()
        );
        let mut generated = column("id");
        generated.is_auto_increment = true;
        assert!(
            store
                .save(&scope, &headers(&["id"]), &[generated], &[Some(0)], true)
                .is_err()
        );
    }

    #[test]
    fn forget_removes_only_the_scoped_mapping() {
        let directory = tempfile::tempdir().unwrap();
        let store = CsvMappingStore::load_at(directory.path().join("mappings.json"));
        let scope = scope(Uuid::new_v4(), "appdb", "users");
        let mut other_scope = scope.clone();
        other_scope.table = "accounts".into();
        store
            .save(&scope, &headers(&["full name"]), &[column("name")], &[Some(0)], true)
            .unwrap();
        store
            .save(
                &other_scope,
                &headers(&["account name"]),
                &[column("name")],
                &[Some(0)],
                true,
            )
            .unwrap();
        assert!(store.forget(&scope).unwrap());
        assert!(!store.forget(&scope).unwrap());
        assert!(
            store
                .restore(&scope, &headers(&["full name"]), &[column("name")], true)
                .unwrap()
                .is_none()
        );
        assert!(
            store
                .restore(&other_scope, &headers(&["account name"]), &[column("name")], true)
                .unwrap()
                .is_some()
        );
    }

    #[test]
    fn saved_mapping_survives_reopen_and_contains_names_not_row_values() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("mappings.json");
        let scope = scope(Uuid::new_v4(), "appdb", "users");
        let store = CsvMappingStore::load_at(path.clone());
        store
            .save(&scope, &headers(&["full name"]), &[column("name")], &[Some(0)], true)
            .unwrap();
        store.flush().unwrap();
        let stored = std::fs::read_to_string(path).unwrap();
        assert!(stored.contains("full name"));
        assert!(stored.contains("name"));
        assert!(!stored.contains("private row value"));
        let reopened = CsvMappingStore::load_at(directory.path().join("mappings.json"));
        assert_eq!(
            reopened
                .restore(&scope, &headers(&["full name"]), &[column("name")], true)
                .unwrap()
                .unwrap(),
            [Some(0)]
        );
    }
}
