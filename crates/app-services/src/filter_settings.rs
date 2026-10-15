use std::collections::HashMap;
use std::sync::Arc;

use tablepro_core::FilterSet;
use uuid::Uuid;

use super::config_io::xdg_config_path;
use super::state_file::StateFile;

const FILE: &str = "filter_settings.json";

/// `FilterSet` keyed by `(connection_id, schema-or-empty, table)`.
type Tables = HashMap<String, FilterSet>;
type Schemas = HashMap<String, Tables>;
type Connections = HashMap<String, Schemas>;

#[derive(Clone)]
pub struct FilterSettingsStore {
    file: Arc<StateFile<Connections>>,
}

fn schema_key(schema: Option<&str>) -> String {
    schema.unwrap_or("").to_string()
}

impl FilterSettingsStore {
    pub fn open() -> Option<Self> {
        Some(Self::load_at(xdg_config_path(FILE)?))
    }

    fn load_at(path: std::path::PathBuf) -> Self {
        Self {
            file: Arc::new(StateFile::load(path)),
        }
    }

    pub fn flush(&self) -> Result<(), String> {
        self.file.flush()
    }

    pub fn load(&self, connection_id: Uuid, schema: Option<&str>, table: &str) -> FilterSet {
        self.file
            .read(|map| {
                map.get(&connection_id.to_string())
                    .and_then(|schemas| schemas.get(&schema_key(schema)))
                    .and_then(|tables| tables.get(table))
                    .cloned()
                    .unwrap_or_default()
            })
            .unwrap_or_default()
    }

    pub fn save(&self, connection_id: Uuid, schema: Option<&str>, table: &str, set: FilterSet) -> Result<(), String> {
        self.file.update(|map| {
            if set.is_empty() {
                // Empty FilterSet → remove the entry (and any now-empty
                // ancestor maps) so the file shrinks back to its previous
                // shape. Without this, "clear filter" would leave a
                // `{"rules":[]}` blob behind on disk, which loads as an
                // empty FilterSet anyway but bloats the file over time.
                if let Some(schemas) = map.get_mut(&connection_id.to_string()) {
                    if let Some(tables) = schemas.get_mut(&schema_key(schema)) {
                        tables.remove(table);
                        if tables.is_empty() {
                            schemas.remove(&schema_key(schema));
                        }
                    }
                    if schemas.is_empty() {
                        map.remove(&connection_id.to_string());
                    }
                }
            } else {
                map.entry(connection_id.to_string())
                    .or_default()
                    .entry(schema_key(schema))
                    .or_default()
                    .insert(table.to_string(), set);
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tablepro_core::{Combinator, FilterOp, FilterRule, FilterValue};

    fn sample_set() -> FilterSet {
        FilterSet {
            combinator: Combinator::Or,
            rules: vec![FilterRule {
                column: "name".into(),
                op: FilterOp::Eq,
                value: Some(FilterValue::Single("alice".into())),
            }],
            extra_sql: None,
        }
    }

    #[test]
    fn empty_set_returns_default() {
        let dir = tempfile::tempdir().unwrap();
        let store = FilterSettingsStore::load_at(dir.path().join("filters.json"));
        let id = Uuid::new_v4();
        let loaded = store.load(id, Some("public"), "users");
        assert!(loaded.is_empty());
    }

    #[test]
    fn schema_none_distinct_from_some() {
        // An empty-string schema slot lives next to a "public" slot;
        // they don't collide. Verified by writing two sets with
        // different schema keys to the cache directly.
        let mut connections: Connections = HashMap::new();
        let id = Uuid::new_v4();
        connections
            .entry(id.to_string())
            .or_default()
            .entry(String::new())
            .or_default()
            .insert("t".into(), sample_set());
        connections
            .entry(id.to_string())
            .or_default()
            .entry("public".into())
            .or_default()
            .insert("t".into(), FilterSet::default());
        let none_set = connections.get(&id.to_string()).and_then(|s| s.get("")).unwrap();
        let public_set = connections.get(&id.to_string()).and_then(|s| s.get("public")).unwrap();
        assert!(!none_set.get("t").unwrap().is_empty());
        assert!(public_set.get("t").unwrap().is_empty());
    }

    #[test]
    fn round_trip_serialises_and_deserialises() {
        // Ensure the on-disk representation round-trips a non-trivial
        // FilterSet — schemes / Combinator default behaviour / nested
        // FilterValue tagged-content serde.
        let original = sample_set();
        let json = serde_json::to_string(&original).unwrap();
        let parsed: FilterSet = serde_json::from_str(&json).unwrap();
        assert_eq!(original, parsed);
    }

    fn other_set() -> FilterSet {
        FilterSet {
            combinator: Combinator::And,
            rules: vec![FilterRule {
                column: "age".into(),
                op: FilterOp::Gt,
                value: Some(FilterValue::Single("30".into())),
            }],
            extra_sql: None,
        }
    }

    #[test]
    fn a_saved_filter_loads_back_and_survives_a_restart() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("filters.json");
        let id = Uuid::new_v4();
        let store = FilterSettingsStore::load_at(path.clone());
        store.save(id, Some("public"), "users", sample_set()).unwrap();
        assert_eq!(store.load(id, Some("public"), "users"), sample_set());
        store.flush().unwrap();
        drop(store);
        let reopened = FilterSettingsStore::load_at(path);
        assert_eq!(reopened.load(id, Some("public"), "users"), sample_set());
    }

    #[test]
    fn a_table_without_a_schema_is_stored_apart_from_the_same_table_in_a_schema() {
        let dir = tempfile::tempdir().unwrap();
        let store = FilterSettingsStore::load_at(dir.path().join("filters.json"));
        let id = Uuid::new_v4();
        store.save(id, None, "users", sample_set()).unwrap();
        assert!(store.load(id, Some("public"), "users").is_empty());
        store.save(id, Some("public"), "users", other_set()).unwrap();
        assert_eq!(store.load(id, None, "users"), sample_set());
        assert_eq!(store.load(id, Some("public"), "users"), other_set());
    }

    #[test]
    fn saving_an_empty_filter_removes_it_and_leaves_an_empty_file_behind() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("filters.json");
        let id = Uuid::new_v4();
        let store = FilterSettingsStore::load_at(path.clone());
        store.save(id, None, "users", sample_set()).unwrap();
        store.save(id, None, "users", FilterSet::default()).unwrap();
        assert!(store.load(id, None, "users").is_empty());
        store.flush().unwrap();
        let on_disk: serde_json::Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
        assert_eq!(on_disk, serde_json::json!({}));
    }

    #[test]
    fn open_follows_the_config_directory_environment() {
        let configured = std::env::var_os("XDG_CONFIG_HOME").is_some() || std::env::var_os("HOME").is_some();
        assert_eq!(FilterSettingsStore::open().is_some(), configured);
    }
}
