use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::config_io::{atomic_write_json, xdg_config_path};

const MAX_TABS_PER_CONNECTION: usize = 32;
const MAX_TABLE_NAME_BYTES: usize = 256;
const MAX_SCHEMA_NAME_BYTES: usize = 256;
const MAX_QUERY_BYTES: usize = 256 * 1024;
const FILE_NAME: &str = "workspace_state.json";

const PAGE_SIZE_OPTIONS: &[u64] = &[100, 500, 1_000, 5_000, 10_000];
const DEFAULT_PAGE_SIZE: u64 = 1_000;

/// Unified workspace persistence: one tab strip per connection containing
/// both Browse and Editor tabs in user-chosen display order. Replaces the
/// previous split between browse_state.json and editor.json.
///
/// Per-connection_id because tabs are written against a specific schema —
/// pulling them across connections silently switches their semantic
/// meaning. Selection state is intentionally omitted (ephemeral).
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct WorkspaceState {
    #[serde(default)]
    pub connections: HashMap<String, ConnectionWorkspaceState>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ConnectionWorkspaceState {
    pub tabs: Vec<WorkspaceTabRecord>,
    #[serde(default)]
    pub active_idx: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum WorkspaceTabRecord {
    Browse {
        schema: Option<String>,
        table: String,
        #[serde(default)]
        offset: u64,
        #[serde(default = "default_page_size")]
        page_size: u64,
        #[serde(default)]
        sort_col: Option<usize>,
        #[serde(default)]
        sort_asc: Option<bool>,
    },
    Editor {
        #[serde(default)]
        query: String,
    },
}

fn default_page_size() -> u64 {
    DEFAULT_PAGE_SIZE
}

pub fn load() -> WorkspaceState {
    let Some(path) = xdg_config_path(FILE_NAME) else {
        return WorkspaceState::default();
    };
    let mut state: WorkspaceState = std::fs::read(path)
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default();
    clamp(&mut state);
    state
}

pub fn save(state: &WorkspaceState) {
    let Some(path) = xdg_config_path(FILE_NAME) else {
        return;
    };
    let mut snapshot = state.clone();
    clamp(&mut snapshot);
    let _ = atomic_write_json(&path, &snapshot);
}

pub fn load_connection(id: Uuid) -> Option<ConnectionWorkspaceState> {
    let state = load();
    state.connections.get(&id.to_string()).cloned()
}

pub fn save_connection(id: Uuid, conn_state: ConnectionWorkspaceState) {
    let mut state = load();
    state.connections.insert(id.to_string(), conn_state);
    save(&state);
}

fn clamp(state: &mut WorkspaceState) {
    for conn in state.connections.values_mut() {
        clamp_connection(conn);
    }
}

fn clamp_connection(conn: &mut ConnectionWorkspaceState) {
    if conn.tabs.len() > MAX_TABS_PER_CONNECTION {
        conn.tabs.truncate(MAX_TABS_PER_CONNECTION);
    }
    for tab in &mut conn.tabs {
        match tab {
            WorkspaceTabRecord::Browse {
                schema,
                table,
                page_size,
                ..
            } => {
                if table.len() > MAX_TABLE_NAME_BYTES {
                    let boundary = floor_char_boundary(table, MAX_TABLE_NAME_BYTES);
                    table.truncate(boundary);
                }
                if let Some(s) = schema.as_mut()
                    && s.len() > MAX_SCHEMA_NAME_BYTES
                {
                    let boundary = floor_char_boundary(s, MAX_SCHEMA_NAME_BYTES);
                    s.truncate(boundary);
                }
                if !PAGE_SIZE_OPTIONS.contains(page_size) {
                    *page_size = DEFAULT_PAGE_SIZE;
                }
            }
            WorkspaceTabRecord::Editor { query } => {
                if query.len() > MAX_QUERY_BYTES {
                    let boundary = floor_char_boundary(query, MAX_QUERY_BYTES);
                    query.truncate(boundary);
                }
            }
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

    fn browse(table: &str) -> WorkspaceTabRecord {
        WorkspaceTabRecord::Browse {
            schema: None,
            table: table.into(),
            offset: 0,
            page_size: DEFAULT_PAGE_SIZE,
            sort_col: None,
            sort_asc: None,
        }
    }

    fn editor(query: &str) -> WorkspaceTabRecord {
        WorkspaceTabRecord::Editor { query: query.into() }
    }

    #[test]
    fn clamp_truncates_tabs_beyond_limit() {
        let mut conn = ConnectionWorkspaceState {
            tabs: (0..40).map(|i| browse(&format!("t{i}"))).collect(),
            active_idx: 35,
        };
        clamp_connection(&mut conn);
        assert_eq!(conn.tabs.len(), MAX_TABS_PER_CONNECTION);
        assert_eq!(conn.active_idx, 0);
    }

    #[test]
    fn clamp_handles_mixed_browse_and_editor_tabs() {
        let mut conn = ConnectionWorkspaceState {
            tabs: vec![browse("users"), editor("SELECT 1"), browse("orders")],
            active_idx: 1,
        };
        clamp_connection(&mut conn);
        assert_eq!(conn.tabs.len(), 3);
        assert_eq!(conn.active_idx, 1);
        assert!(matches!(conn.tabs[1], WorkspaceTabRecord::Editor { .. }));
    }

    #[test]
    fn clamp_replaces_foreign_browse_page_size() {
        let mut conn = ConnectionWorkspaceState {
            tabs: vec![WorkspaceTabRecord::Browse {
                schema: None,
                table: "t".into(),
                offset: 0,
                page_size: 999_999,
                sort_col: None,
                sort_asc: None,
            }],
            active_idx: 0,
        };
        clamp_connection(&mut conn);
        match &conn.tabs[0] {
            WorkspaceTabRecord::Browse { page_size, .. } => assert_eq!(*page_size, DEFAULT_PAGE_SIZE),
            _ => panic!("expected Browse"),
        }
    }

    #[test]
    fn clamp_truncates_long_query_at_char_boundary() {
        let mut q = "a".repeat(MAX_QUERY_BYTES - 1);
        q.push('é');
        let mut conn = ConnectionWorkspaceState {
            tabs: vec![editor(&q)],
            active_idx: 0,
        };
        clamp_connection(&mut conn);
        match &conn.tabs[0] {
            WorkspaceTabRecord::Editor { query } => {
                assert!(query.is_char_boundary(query.len()));
                assert!(query.len() <= MAX_QUERY_BYTES);
            }
            _ => panic!("expected Editor"),
        }
    }

    #[test]
    fn round_trip_preserves_mixed_tabs() {
        let mut state = WorkspaceState::default();
        let id = Uuid::new_v4();
        state.connections.insert(
            id.to_string(),
            ConnectionWorkspaceState {
                tabs: vec![
                    browse("users"),
                    editor("SELECT * FROM orders"),
                    WorkspaceTabRecord::Browse {
                        schema: Some("public".into()),
                        table: "products".into(),
                        offset: 5000,
                        page_size: 5_000,
                        sort_col: Some(2),
                        sort_asc: Some(false),
                    },
                ],
                active_idx: 1,
            },
        );
        let bytes = serde_json::to_vec(&state).unwrap();
        let parsed: WorkspaceState = serde_json::from_slice(&bytes).unwrap();
        let conn = parsed.connections.get(&id.to_string()).unwrap();
        assert_eq!(conn.tabs.len(), 3);
        assert_eq!(conn.active_idx, 1);
        match &conn.tabs[2] {
            WorkspaceTabRecord::Browse { sort_col, sort_asc, .. } => {
                assert_eq!(*sort_col, Some(2));
                assert_eq!(*sort_asc, Some(false));
            }
            _ => panic!("expected Browse"),
        }
    }

    #[test]
    fn legacy_record_loads_with_serde_defaults() {
        // Forward-compat: missing optional fields fall back to defaults.
        let json = r#"{"connections":{"abc":{"tabs":[{"kind":"browse","schema":null,"table":"t"},{"kind":"editor"}],"active_idx":0}}}"#;
        let parsed: WorkspaceState = serde_json::from_str(json).unwrap();
        let tabs = &parsed.connections["abc"].tabs;
        match &tabs[0] {
            WorkspaceTabRecord::Browse { offset, page_size, .. } => {
                assert_eq!(*offset, 0);
                assert_eq!(*page_size, DEFAULT_PAGE_SIZE);
            }
            _ => panic!("expected Browse"),
        }
        match &tabs[1] {
            WorkspaceTabRecord::Editor { query } => assert_eq!(query, ""),
            _ => panic!("expected Editor"),
        }
    }
}
