use std::collections::HashMap;
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use tablepro_core::FilterSet;
use uuid::Uuid;

use super::config_io::xdg_config_path;
use super::state_file::StateFile;

const FILE: &str = "named_filter_presets.json";
const MAX_PRESETS_PER_TABLE: usize = 20;
const MAX_NAME_CHARS: usize = 48;
const MAX_FILTER_RULES: usize = 64;
const MAX_FILTER_BYTES: usize = 64 * 1024;

type Tables = HashMap<String, HashMap<String, StoredPreset>>;
type Schemas = HashMap<String, Tables>;
type Connections = HashMap<String, Schemas>;

#[derive(Clone, Serialize, Deserialize)]
struct StoredPreset {
    name: String,
    filter: FilterSet,
}

#[derive(Clone)]
pub struct NamedFilterPresetsStore {
    file: Arc<StateFile<Connections>>,
}

impl NamedFilterPresetsStore {
    pub fn open() -> Option<Self> {
        Some(Self::load_at(xdg_config_path(FILE)?))
    }

    pub fn load_at(path: std::path::PathBuf) -> Self {
        Self {
            file: Arc::new(StateFile::load(path)),
        }
    }

    pub fn flush(&self) -> Result<(), String> {
        self.file.flush()
    }

    pub fn list(&self, connection: Uuid, schema: Option<&str>, table: &str) -> Vec<String> {
        let mut names = self
            .file
            .read(|map| {
                map.get(&connection.to_string())
                    .and_then(|schemas| schemas.get(schema.unwrap_or("")))
                    .and_then(|tables| tables.get(table))
                    .map(|presets| {
                        presets
                            .iter()
                            .filter(|(key, preset)| {
                                preset_key(&preset.name).as_deref() == Some(key.as_str())
                                    && valid_filter(&preset.filter)
                            })
                            .map(|(_, preset)| preset)
                            .filter(|preset| valid_name(&preset.name).is_some())
                            .map(|preset| preset.name.clone())
                            .collect::<Vec<_>>()
                    })
                    .unwrap_or_default()
            })
            .unwrap_or_default();
        names.sort_by_key(|name| name.to_lowercase());
        names
    }

    pub fn load(&self, connection: Uuid, schema: Option<&str>, table: &str, name: &str) -> Option<FilterSet> {
        let key = preset_key(name)?;
        self.file.read(|map| {
            map.get(&connection.to_string())
                .and_then(|schemas| schemas.get(schema.unwrap_or("")))
                .and_then(|tables| tables.get(table))
                .and_then(|presets| presets.get(&key))
                .filter(|preset| preset.name.to_lowercase() == key && valid_filter(&preset.filter))
                .map(|preset| preset.filter.clone())
        })?
    }

    pub fn save(
        &self,
        connection: Uuid,
        schema: Option<&str>,
        table: &str,
        name: &str,
        filter: FilterSet,
    ) -> Result<(), String> {
        let display_name = valid_name(name).ok_or_else(|| "Choose a name of 1 to 48 characters.".to_string())?;
        let key = display_name.to_lowercase();
        if !valid_filter(&filter) {
            return Err("Only bounded structured filters can be saved.".into());
        }
        let (count, existing_name) = self
            .file
            .read(|map| {
                map.get(&connection.to_string())
                    .and_then(|schemas| schemas.get(schema.unwrap_or("")))
                    .and_then(|tables| tables.get(table))
                    .map(|presets| (presets.len(), presets.get(&key).map(|preset| preset.name.clone())))
                    .unwrap_or_default()
            })
            .unwrap_or_default();
        if existing_name.is_none() && count >= MAX_PRESETS_PER_TABLE {
            return Err("This table already has the maximum number of saved filters.".into());
        }
        let display_name = existing_name
            .filter(|name| valid_name(name).is_some())
            .unwrap_or(display_name);
        self.file.update(|map| {
            let presets = map
                .entry(connection.to_string())
                .or_default()
                .entry(schema.unwrap_or("").to_string())
                .or_default()
                .entry(table.to_string())
                .or_default();
            presets.insert(
                key,
                StoredPreset {
                    name: display_name,
                    filter,
                },
            );
        })?;
        Ok(())
    }

    pub fn delete(&self, connection: Uuid, schema: Option<&str>, table: &str, name: &str) -> Result<bool, String> {
        let key = preset_key(name).ok_or_else(|| "Choose a saved filter to delete.".to_string())?;
        let mut removed = false;
        self.file.update(|map| {
            let connection_key = connection.to_string();
            let schema_key = schema.unwrap_or("").to_string();
            if let Some(schemas) = map.get_mut(&connection_key) {
                if let Some(tables) = schemas.get_mut(&schema_key) {
                    if let Some(presets) = tables.get_mut(table) {
                        removed = presets.remove(&key).is_some();
                        if presets.is_empty() {
                            tables.remove(table);
                        }
                    }
                    if tables.is_empty() {
                        schemas.remove(&schema_key);
                    }
                }
                if schemas.is_empty() {
                    map.remove(&connection_key);
                }
            }
        })?;
        Ok(removed)
    }

    pub fn rename(
        &self,
        connection: Uuid,
        schema: Option<&str>,
        table: &str,
        old_name: &str,
        new_name: &str,
    ) -> Result<(), String> {
        let new_name = valid_name(new_name).ok_or_else(|| "Choose a name of 1 to 48 characters.".to_string())?;
        let old_key = preset_key(old_name).ok_or_else(|| "Choose a saved filter to rename.".to_string())?;
        let new_key = new_name.to_lowercase();
        let filter = self
            .load(connection, schema, table, &old_key)
            .ok_or_else(|| "That saved filter is no longer available.".to_string())?;
        if old_key == new_key {
            return self.file.update(|map| {
                if let Some(preset) = map
                    .get_mut(&connection.to_string())
                    .and_then(|schemas| schemas.get_mut(schema.unwrap_or("")))
                    .and_then(|tables| tables.get_mut(table))
                    .and_then(|presets| presets.get_mut(&old_key))
                {
                    preset.name = new_name;
                    preset.filter = filter;
                }
            });
        }
        if self
            .list(connection, schema, table)
            .iter()
            .any(|name| name.to_lowercase() == new_key)
        {
            return Err("A saved filter already uses that name.".into());
        }
        self.file.update(|map| {
            let connection_key = connection.to_string();
            if let Some(presets) = map
                .get_mut(&connection_key)
                .and_then(|schemas| schemas.get_mut(schema.unwrap_or("")))
                .and_then(|tables| tables.get_mut(table))
            {
                presets.remove(&old_key);
                presets.insert(new_key, StoredPreset { name: new_name, filter });
            }
        })
    }
}

fn valid_name(name: &str) -> Option<String> {
    let name = name.trim();
    (!name.is_empty() && name.chars().count() <= MAX_NAME_CHARS && !name.chars().any(char::is_control))
        .then(|| name.to_string())
}

fn preset_key(name: &str) -> Option<String> {
    valid_name(name).map(|name| name.to_lowercase())
}

fn valid_filter(filter: &FilterSet) -> bool {
    !filter.is_empty()
        && filter.extra_sql.is_none()
        && filter.rules.len() <= MAX_FILTER_RULES
        && serde_json::to_vec(filter).is_ok_and(|bytes| bytes.len() <= MAX_FILTER_BYTES)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tablepro_core::{FilterOp, FilterRule, FilterSet, FilterValue};
    use uuid::Uuid;

    fn filter(value: &str) -> FilterSet {
        FilterSet {
            rules: vec![FilterRule {
                column: "status".into(),
                op: FilterOp::Eq,
                value: Some(FilterValue::Single(value.into())),
            }],
            ..FilterSet::default()
        }
    }

    #[test]
    fn presets_round_trip_and_remain_scoped_to_connection_schema_and_table() {
        let directory = tempfile::tempdir().unwrap();
        let store = NamedFilterPresetsStore::load_at(directory.path().join("presets.json"));
        let connection = Uuid::new_v4();
        store
            .save(connection, Some("public"), "jobs", "Failed", filter("failed"))
            .unwrap();
        store.flush().unwrap();
        let reopened = NamedFilterPresetsStore::load_at(directory.path().join("presets.json"));

        assert_eq!(reopened.list(connection, Some("public"), "jobs"), vec!["Failed"]);
        assert_eq!(
            reopened.load(connection, Some("public"), "jobs", "Failed"),
            Some(filter("failed"))
        );
        assert!(reopened.load(connection, Some("private"), "jobs", "Failed").is_none());
        assert!(reopened.load(connection, Some("public"), "users", "Failed").is_none());
        assert!(
            reopened
                .load(Uuid::new_v4(), Some("public"), "jobs", "Failed")
                .is_none()
        );
    }

    #[test]
    fn names_are_trimmed_and_case_insensitive_collisions_replace_the_existing_preset() {
        let directory = tempfile::tempdir().unwrap();
        let store = NamedFilterPresetsStore::load_at(directory.path().join("presets.json"));
        let connection = Uuid::new_v4();
        store
            .save(connection, None, "jobs", " Failed ", filter("failed"))
            .unwrap();
        store.save(connection, None, "jobs", "failed", filter("open")).unwrap();

        assert_eq!(store.list(connection, None, "jobs"), vec!["Failed"]);
        assert_eq!(store.load(connection, None, "jobs", "FAILED"), Some(filter("open")));
    }

    #[test]
    fn invalid_names_and_empty_filters_are_refused() {
        let directory = tempfile::tempdir().unwrap();
        let store = NamedFilterPresetsStore::load_at(directory.path().join("presets.json"));
        let connection = Uuid::new_v4();

        assert!(store.save(connection, None, "jobs", "  ", filter("failed")).is_err());
        assert!(
            store
                .save(
                    connection,
                    None,
                    "jobs",
                    &"x".repeat(MAX_NAME_CHARS + 1),
                    filter("failed")
                )
                .is_err()
        );
        assert!(
            store
                .save(connection, None, "jobs", "Empty", FilterSet::default())
                .is_err()
        );
    }

    #[test]
    fn raw_sql_is_refused_and_hostile_saved_filters_are_not_offered() {
        let directory = tempfile::tempdir().unwrap();
        let store = NamedFilterPresetsStore::load_at(directory.path().join("presets.json"));
        let connection = Uuid::new_v4();
        let mut raw = filter("failed");
        raw.extra_sql = Some("1=1; DROP TABLE jobs".into());
        assert!(store.save(connection, None, "jobs", "Unsafe", raw.clone()).is_err());
        store
            .file
            .update(|map| {
                map.entry(connection.to_string())
                    .or_default()
                    .entry(String::new())
                    .or_default()
                    .entry("jobs".into())
                    .or_default()
                    .insert(
                        "unsafe".into(),
                        StoredPreset {
                            name: "Unsafe".into(),
                            filter: raw,
                        },
                    );
            })
            .unwrap();

        assert!(store.list(connection, None, "jobs").is_empty());
        assert!(store.load(connection, None, "jobs", "Unsafe").is_none());
    }

    #[test]
    fn preset_count_is_bounded_without_discarding_existing_entries() {
        let directory = tempfile::tempdir().unwrap();
        let store = NamedFilterPresetsStore::load_at(directory.path().join("presets.json"));
        let connection = Uuid::new_v4();
        for index in 0..MAX_PRESETS_PER_TABLE {
            store
                .save(connection, None, "jobs", &format!("preset {index}"), filter("failed"))
                .unwrap();
        }

        assert!(
            store
                .save(connection, None, "jobs", "one too many", filter("open"))
                .is_err()
        );
        assert_eq!(store.list(connection, None, "jobs").len(), MAX_PRESETS_PER_TABLE);
    }

    #[test]
    fn delete_removes_only_the_requested_preset() {
        let directory = tempfile::tempdir().unwrap();
        let store = NamedFilterPresetsStore::load_at(directory.path().join("presets.json"));
        let connection = Uuid::new_v4();
        store
            .save(connection, None, "jobs", "Failed", filter("failed"))
            .unwrap();
        store.save(connection, None, "jobs", "Open", filter("open")).unwrap();

        assert!(store.delete(connection, None, "jobs", "FAILED").unwrap());
        assert!(!store.delete(connection, None, "jobs", "missing").unwrap());
        assert_eq!(store.list(connection, None, "jobs"), vec!["Open"]);
    }

    #[test]
    fn rename_preserves_filter_and_refuses_to_overwrite_another_name() {
        let directory = tempfile::tempdir().unwrap();
        let store = NamedFilterPresetsStore::load_at(directory.path().join("presets.json"));
        let connection = Uuid::new_v4();
        store
            .save(connection, None, "jobs", "Failed", filter("failed"))
            .unwrap();
        store.save(connection, None, "jobs", "Open", filter("open")).unwrap();

        assert!(store.rename(connection, None, "jobs", "Failed", "Open").is_err());
        store.rename(connection, None, "jobs", "Failed", "Errors").unwrap();
        assert_eq!(store.load(connection, None, "jobs", "Errors"), Some(filter("failed")));
        assert!(store.load(connection, None, "jobs", "Failed").is_none());
    }
}
