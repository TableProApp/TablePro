#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_app_services::workspace_state::{ConnectionWorkspaceState, WorkspaceStore, WorkspaceTabRecord};
use uuid::Uuid;

#[test]
fn an_explicit_workspace_path_survives_flush_and_a_fresh_store() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("workspace_state.json");
    let drafts = dir.path().join("drafts");
    let id = Uuid::new_v4();
    let store = WorkspaceStore::new(Some(path.clone()), drafts.clone());
    store.save_connection(
        id,
        ConnectionWorkspaceState {
            tabs: vec![WorkspaceTabRecord::Editor {
                query: "SELECT 'é';".into(),
                draft_id: None,
                file: Some("/tmp/report.sql".into()),
            }],
            ..Default::default()
        },
    );
    assert_eq!(
        store.flush().recv_timeout(std::time::Duration::from_secs(5)).unwrap(),
        Ok(())
    );
    let restored = WorkspaceStore::new(Some(path.clone()), drafts);
    restored.prefetch_connections(&[id]).unwrap();
    let state = restored.load_connection(id).unwrap();
    assert!(
        matches!(&state.tabs[0], WorkspaceTabRecord::Editor { query, draft_id: Some(_), file: Some(file) }
        if query == "SELECT 'é';" && file == std::path::Path::new("/tmp/report.sql"))
    );
    let json: serde_json::Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
    assert!(json["connections"][id.to_string()]["tabs"][0].get("query").is_none());
}

fn flush(store: &WorkspaceStore) -> Result<(), tablepro_app_services::workspace_state::WorkspaceFlushError> {
    store.flush().recv_timeout(std::time::Duration::from_secs(5)).unwrap()
}

#[test]
fn legacy_records_migrate_without_changing_selection_or_the_disk_contract() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("workspace_state.json");
    let id = Uuid::new_v4();
    let legacy = serde_json::json!({"connections": {id.to_string(): {
        "tabs": [
            {"kind": "future_tab"},
            {"kind": "browse", "schema": "public", "table": "items", "offset": 500,
             "page_size": 500, "sort_col": 2, "sort_asc": false},
            {"kind": "structure", "schema": null, "table": "jobs"}
        ], "active_idx": 1, "collapsed_groups": ["schema:public/views"], "hidden_schemas": ["private"]
    }}});
    std::fs::write(&path, serde_json::to_vec(&legacy).unwrap()).unwrap();
    let store = WorkspaceStore::new(Some(path.clone()), dir.path().join("drafts"));
    store.prefetch_connections(&[id]).unwrap();
    let state = store.load_connection(id).unwrap();
    assert_eq!(state.active_idx, 0);
    assert_eq!(state.tabs.len(), 2);
    store.save_connection(id, state);
    assert_eq!(flush(&store), Ok(()));
    let saved: serde_json::Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
    assert_eq!(
        saved,
        serde_json::json!({"connections": {id.to_string(): {
            "tabs": [
                {"kind": "table", "schema": "public", "table": "items", "mode": "data", "offset": 500,
                 "page_size": 500, "sort_col": 2, "sort_asc": false},
                {"kind": "table", "schema": null, "table": "jobs", "mode": "structure", "offset": 0,
                 "page_size": 1000, "sort_col": null, "sort_asc": null}
            ], "active_idx": 0, "collapsed_groups": ["schema:public/views"], "hidden_schemas": ["private"]
        }}})
    );
}

#[test]
fn an_unreadable_workspace_is_preserved_and_a_retry_can_flush_the_pending_save() {
    use tablepro_app_services::workspace_state::WorkspaceFlushError;
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("workspace_state.json");
    std::fs::write(&path, b"invalid workspace").unwrap();
    let id = Uuid::new_v4();
    let store = WorkspaceStore::new(Some(path.clone()), dir.path().join("drafts"));
    assert_eq!(store.prefetch_connections(&[id]), Err(WorkspaceFlushError::WriteFailed));
    store.save_connection(id, ConnectionWorkspaceState::default());
    assert_eq!(flush(&store), Err(WorkspaceFlushError::WriteFailed));
    assert_eq!(std::fs::read(&path).unwrap(), b"invalid workspace");
    std::fs::write(&path, br#"{"connections":{}}"#).unwrap();
    assert_eq!(flush(&store), Ok(()));
    let saved: serde_json::Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
    assert_eq!(saved["connections"][id.to_string()]["tabs"], serde_json::json!([]));
}

#[test]
fn a_missing_config_path_reports_failure_without_creating_drafts() {
    use tablepro_app_services::workspace_state::WorkspaceFlushError;
    let dir = tempfile::tempdir().unwrap();
    let drafts = dir.path().join("drafts");
    let store = WorkspaceStore::new(None, drafts.clone());
    store.save_connection(Uuid::new_v4(), ConnectionWorkspaceState::default());
    assert_eq!(flush(&store), Err(WorkspaceFlushError::WriteFailed));
    assert!(!drafts.exists());
}

#[test]
fn forgetting_a_connection_only_removes_its_own_workspace_and_drafts() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("workspace_state.json");
    let drafts = dir.path().join("drafts");
    let store = WorkspaceStore::new(Some(path.clone()), drafts.clone());
    let first = Uuid::new_v4();
    let second = Uuid::new_v4();
    for id in [first, second] {
        store.save_connection(
            id,
            ConnectionWorkspaceState {
                tabs: vec![WorkspaceTabRecord::Editor {
                    query: id.to_string(),
                    draft_id: None,
                    file: None,
                }],
                ..Default::default()
            },
        );
    }
    assert_eq!(flush(&store), Ok(()));
    store.forget_connection(first);
    assert!(!drafts.join(first.to_string()).exists());
    assert!(drafts.join(second.to_string()).is_dir());
    assert!(store.load_connection(first).is_none());
    let restored = WorkspaceStore::new(Some(path), drafts);
    restored.prefetch_connections(&[first, second]).unwrap();
    assert!(restored.load_connection(first).is_none());
    assert!(matches!(&restored.load_connection(second).unwrap().tabs[0],
        WorkspaceTabRecord::Editor { query, .. } if query == &second.to_string()));
}

#[test]
fn startup_preview_cleanup_preserves_the_selected_kept_tab_on_disk() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("workspace_state.json");
    let id = Uuid::new_v4();
    let store = WorkspaceStore::new(Some(path.clone()), dir.path().join("drafts"));
    let tabs = [true, false]
        .into_iter()
        .map(|preview| WorkspaceTabRecord::Table {
            schema: None,
            table: if preview { "preview" } else { "kept" }.into(),
            mode: Default::default(),
            offset: 0,
            page_size: 1000,
            sort_col: None,
            sort_asc: None,
            preview,
        })
        .collect();
    store.save_connection(
        id,
        ConnectionWorkspaceState {
            tabs,
            active_idx: 1,
            ..Default::default()
        },
    );
    assert_eq!(flush(&store), Ok(()));
    store.discard_preview_tabs();
    let restored = WorkspaceStore::new(Some(path), dir.path().join("drafts"));
    restored.prefetch_connections(&[id]).unwrap();
    let state = restored.load_connection(id).unwrap();
    assert_eq!(state.active_idx, 0);
    assert_eq!(state.tabs.len(), 1);
    assert!(matches!(&state.tabs[0], WorkspaceTabRecord::Table { table, preview: false, .. } if table == "kept"));
}

fn repeated_large_draft_saves(connection_count: usize) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("workspace_state.json");
    let drafts = dir.path().join("drafts");
    let store = WorkspaceStore::new(Some(path.clone()), drafts.clone());
    let ids: Vec<_> = (0..connection_count).map(|_| Uuid::new_v4()).collect();
    let original = "SELECT '東京é';\n".repeat(65_536);
    let record = |query: String| ConnectionWorkspaceState {
        tabs: vec![WorkspaceTabRecord::Editor {
            query,
            draft_id: None,
            file: None,
        }],
        ..Default::default()
    };
    for id in &ids {
        store.save_connection(*id, record(original.clone()));
    }
    assert_eq!(flush(&store), Ok(()));
    let mut latest = original.clone();
    for revision in 0..3 {
        latest = format!("{original}SELECT {revision};\n");
        store.save_connection(ids[0], record(latest.clone()));
        assert_eq!(flush(&store), Ok(()));
    }
    let restored = WorkspaceStore::new(Some(path), drafts);
    restored.prefetch_connections(&ids).unwrap();
    for (index, id) in ids.iter().enumerate() {
        let expected = if index == 0 { &latest } else { &original };
        let state = restored.load_connection(*id).unwrap();
        assert_eq!(state.tabs.len(), 1);
        assert!(matches!(&state.tabs[0], WorkspaceTabRecord::Editor { query, .. } if query == expected));
    }
}

#[test]
fn repeated_large_draft_saves_preserve_other_connections_and_unicode_text() {
    repeated_large_draft_saves(4);
}

#[test]
fn repeated_large_draft_saves_preserve_one_connections_unicode_text() {
    repeated_large_draft_saves(1);
}
