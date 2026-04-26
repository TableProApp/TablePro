#![allow(dead_code)]
// Multi-tab Browse persistence. The App-side wiring (lookup, save on tab
// changes, restore on connect) lands in the follow-up App integration —
// the surface here is intentionally complete so that integration is a pure
// consumer-side change, not a re-architecture.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::config_io::{atomic_write_json, xdg_config_path};

const MAX_TABS_PER_CONNECTION: usize = 32;
const MAX_TABLE_NAME_BYTES: usize = 256;
const MAX_SCHEMA_NAME_BYTES: usize = 256;
const FILE_NAME: &str = "browse_state.json";

const PAGE_SIZE_OPTIONS: &[u64] = &[100, 500, 1_000, 5_000, 10_000];
const DEFAULT_PAGE_SIZE: u64 = 1_000;

/// Persists open Browse tabs across sessions, keyed by connection id.
///
/// Mirrors the editor_state.rs layout so the on-disk format and the
/// clamp/truncate behaviour stay consistent across the two persistence
/// stores. Selection state is intentionally omitted — it's ephemeral
/// GTK state that the user wouldn't expect to survive a relaunch.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct BrowseState {
    /// Keyed by `connection_id.to_string()` so the JSON stays human-readable.
    #[serde(default)]
    pub connections: HashMap<String, ConnectionBrowseState>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ConnectionBrowseState {
    pub tabs: Vec<BrowseTabRecord>,
    #[serde(default)]
    pub active_idx: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BrowseTabRecord {
    pub schema: Option<String>,
    pub table: String,
    #[serde(default)]
    pub offset: u64,
    #[serde(default = "default_page_size")]
    pub page_size: u64,
    #[serde(default)]
    pub sort_col: Option<usize>,
    #[serde(default)]
    pub sort_asc: Option<bool>,
}

fn default_page_size() -> u64 {
    DEFAULT_PAGE_SIZE
}

pub fn load() -> BrowseState {
    let Some(path) = xdg_config_path(FILE_NAME) else {
        return BrowseState::default();
    };
    let mut state: BrowseState = std::fs::read(path)
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default();
    clamp(&mut state);
    state
}

pub fn save(state: &BrowseState) {
    let Some(path) = xdg_config_path(FILE_NAME) else {
        return;
    };
    let mut snapshot = state.clone();
    clamp(&mut snapshot);
    let _ = atomic_write_json(&path, &snapshot);
}

pub fn load_connection(id: Uuid) -> Option<ConnectionBrowseState> {
    let state = load();
    state.connections.get(&id.to_string()).cloned()
}

/// Read-modify-write for a single connection's tab set. Avoids stomping
/// other connections' state when only this connection's tabs changed.
pub fn save_connection(id: Uuid, conn_state: ConnectionBrowseState) {
    let mut state = load();
    state.connections.insert(id.to_string(), conn_state);
    save(&state);
}

fn clamp(state: &mut BrowseState) {
    for conn in state.connections.values_mut() {
        clamp_connection(conn);
    }
}

fn clamp_connection(conn: &mut ConnectionBrowseState) {
    if conn.tabs.len() > MAX_TABS_PER_CONNECTION {
        conn.tabs.truncate(MAX_TABS_PER_CONNECTION);
    }
    for tab in &mut conn.tabs {
        if tab.table.len() > MAX_TABLE_NAME_BYTES {
            let boundary = floor_char_boundary(&tab.table, MAX_TABLE_NAME_BYTES);
            tab.table.truncate(boundary);
        }
        if let Some(schema) = tab.schema.as_mut()
            && schema.len() > MAX_SCHEMA_NAME_BYTES
        {
            let boundary = floor_char_boundary(schema, MAX_SCHEMA_NAME_BYTES);
            schema.truncate(boundary);
        }
        // Foreign page_size values fall back to the default so the UI
        // dropdown doesn't show a non-existent option.
        if !PAGE_SIZE_OPTIONS.contains(&tab.page_size) {
            tab.page_size = DEFAULT_PAGE_SIZE;
        }
    }
    if (conn.active_idx as usize) >= conn.tabs.len() {
        conn.active_idx = 0;
    }
}

fn floor_char_boundary(s: &str, idx: usize) -> usize {
    if idx >= s.len() {
        return s.len();
    }
    let mut b = idx;
    while b > 0 && !s.is_char_boundary(b) {
        b -= 1;
    }
    b
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(table: &str) -> BrowseTabRecord {
        BrowseTabRecord {
            schema: None,
            table: table.into(),
            offset: 0,
            page_size: DEFAULT_PAGE_SIZE,
            sort_col: None,
            sort_asc: None,
        }
    }

    #[test]
    fn clamp_truncates_tabs_beyond_limit() {
        let mut conn = ConnectionBrowseState {
            tabs: (0..40).map(|i| record(&format!("t{i}"))).collect(),
            active_idx: 35,
        };
        clamp_connection(&mut conn);
        assert_eq!(conn.tabs.len(), MAX_TABS_PER_CONNECTION);
        // active_idx was past the truncated end, snaps to 0
        assert_eq!(conn.active_idx, 0);
    }

    #[test]
    fn clamp_snaps_active_idx_into_range() {
        let mut conn = ConnectionBrowseState {
            tabs: vec![record("a"), record("b")],
            active_idx: 7,
        };
        clamp_connection(&mut conn);
        assert_eq!(conn.active_idx, 0);
    }

    #[test]
    fn clamp_keeps_valid_active_idx() {
        let mut conn = ConnectionBrowseState {
            tabs: vec![record("a"), record("b"), record("c")],
            active_idx: 1,
        };
        clamp_connection(&mut conn);
        assert_eq!(conn.active_idx, 1);
    }

    #[test]
    fn clamp_replaces_foreign_page_size_with_default() {
        let mut conn = ConnectionBrowseState {
            tabs: vec![BrowseTabRecord {
                page_size: 999_999,
                ..record("t")
            }],
            active_idx: 0,
        };
        clamp_connection(&mut conn);
        assert_eq!(conn.tabs[0].page_size, DEFAULT_PAGE_SIZE);
    }

    #[test]
    fn clamp_preserves_valid_page_size_options() {
        for &size in PAGE_SIZE_OPTIONS {
            let mut conn = ConnectionBrowseState {
                tabs: vec![BrowseTabRecord {
                    page_size: size,
                    ..record("t")
                }],
                active_idx: 0,
            };
            clamp_connection(&mut conn);
            assert_eq!(conn.tabs[0].page_size, size);
        }
    }

    #[test]
    fn clamp_truncates_long_table_name_at_char_boundary() {
        // A multi-byte character at the truncation boundary must not be
        // chopped mid-byte — produces non-UTF-8 otherwise.
        let mut name = "a".repeat(MAX_TABLE_NAME_BYTES - 1);
        name.push('é'); // 2 bytes; pushes past the limit
        let mut conn = ConnectionBrowseState {
            tabs: vec![BrowseTabRecord {
                table: name.clone(),
                ..record("ignored")
            }],
            active_idx: 0,
        };
        clamp_connection(&mut conn);
        // The 'é' should be dropped entirely (not split mid-byte)
        assert!(conn.tabs[0].table.is_char_boundary(conn.tabs[0].table.len()));
        assert!(conn.tabs[0].table.len() <= MAX_TABLE_NAME_BYTES);
    }

    #[test]
    fn round_trip_serialize_preserves_tabs() {
        let mut state = BrowseState::default();
        let id = Uuid::new_v4();
        state.connections.insert(
            id.to_string(),
            ConnectionBrowseState {
                tabs: vec![
                    BrowseTabRecord {
                        schema: Some("public".into()),
                        table: "users".into(),
                        offset: 5000,
                        page_size: 5_000,
                        sort_col: Some(2),
                        sort_asc: Some(false),
                    },
                    record("orders"),
                ],
                active_idx: 1,
            },
        );
        let bytes = serde_json::to_vec(&state).unwrap();
        let parsed: BrowseState = serde_json::from_slice(&bytes).unwrap();
        let conn = parsed.connections.get(&id.to_string()).unwrap();
        assert_eq!(conn.tabs.len(), 2);
        assert_eq!(conn.tabs[0].schema, Some("public".into()));
        assert_eq!(conn.tabs[0].sort_col, Some(2));
        assert_eq!(conn.tabs[0].sort_asc, Some(false));
        assert_eq!(conn.active_idx, 1);
    }

    #[test]
    fn legacy_record_without_optional_fields_loads_with_defaults() {
        // When the on-disk format is older (e.g. before sort_col existed),
        // serde defaults must kick in so we don't hard-fail on load.
        let json = r#"{"connections":{"abc":{"tabs":[{"schema":null,"table":"t"}],"active_idx":0}}}"#;
        let parsed: BrowseState = serde_json::from_str(json).unwrap();
        let tab = &parsed.connections["abc"].tabs[0];
        assert_eq!(tab.offset, 0);
        assert_eq!(tab.page_size, DEFAULT_PAGE_SIZE);
        assert_eq!(tab.sort_col, None);
    }
}
