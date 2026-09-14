//! Per-table filter persistence. Mirrors `column_widths.rs` but the
//! key includes the schema (so `public.users` and `audit.users` don't
//! collide on a multi-schema Postgres database) and the value is a
//! `FilterSet` rather than a single integer.
//!
//! Save path is debounced via `relm4::spawn`; rapid Apply clicks land
//! one disk write each, but they don't block the GTK main loop. An
//! empty `FilterSet` removes the entry from the file so it shrinks
//! back when the user clears their filter.

use std::collections::HashMap;
use std::sync::Mutex;

use tablepro_core::FilterSet;
use uuid::Uuid;

use super::config_io::{atomic_write_json, xdg_config_path};

const FILE: &str = "filter_settings.json";

/// `FilterSet` keyed by `(connection_id, schema-or-empty, table)`.
type Tables = HashMap<String, FilterSet>;
type Schemas = HashMap<String, Tables>;
type Connections = HashMap<String, Schemas>;

static CACHE: Mutex<Option<Connections>> = Mutex::new(None);

/// `None` schema is stored as the empty string so JSON keys are
/// always concrete. This is the only callsite-facing translation.
fn schema_key(schema: Option<&str>) -> String {
    schema.unwrap_or("").to_string()
}

pub fn load(connection_id: Uuid, schema: Option<&str>, table: &str) -> FilterSet {
    let mut guard = match CACHE.lock() {
        Ok(g) => g,
        Err(_) => return FilterSet::default(),
    };
    let map = guard.get_or_insert_with(load_from_disk);
    map.get(&connection_id.to_string())
        .and_then(|s| s.get(&schema_key(schema)))
        .and_then(|t| t.get(table))
        .cloned()
        .unwrap_or_default()
}

pub fn save(connection_id: Uuid, schema: Option<&str>, table: &str, set: FilterSet) {
    let mut guard = match CACHE.lock() {
        Ok(g) => g,
        Err(_) => return,
    };
    let map = guard.get_or_insert_with(load_from_disk);
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
    let snapshot = map.clone();
    drop(guard);
    relm4::spawn(async move {
        if let Some(path) = xdg_config_path(FILE)
            && let Err(e) = atomic_write_json(&path, &snapshot)
        {
            tracing::warn!(error = %e, "filter_settings: persist failed");
        }
    });
}

fn load_from_disk() -> Connections {
    let Some(path) = xdg_config_path(FILE) else {
        return HashMap::new();
    };
    let Ok(bytes) = std::fs::read(path) else {
        return HashMap::new();
    };
    serde_json::from_slice(&bytes).unwrap_or_default()
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
        // Without touching the file, the cache initialises lazily; an
        // entry that doesn't exist returns the FilterSet default.
        let id = Uuid::new_v4();
        let loaded = load(id, Some("public"), "users");
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
}
