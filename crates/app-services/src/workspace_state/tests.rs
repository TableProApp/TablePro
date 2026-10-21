use super::*;

fn editor_with_file(path: &str) -> WorkspaceTabRecord {
    WorkspaceTabRecord::Editor {
        query: "SELECT 1".into(),
        draft_id: None,
        file: Some(std::path::PathBuf::from(path)),
    }
}

fn file_of(record: &WorkspaceTabRecord) -> Option<&std::path::Path> {
    match record {
        WorkspaceTabRecord::Editor { file, .. } => file.as_deref(),
        _ => None,
    }
}

#[test]
fn only_an_absolute_bounded_file_path_is_restored() {
    let long = format!("/{}", "a".repeat(MAX_FILE_PATH_BYTES));
    let mut state = ConnectionWorkspaceState {
        tabs: vec![
            editor_with_file("/home/me/report.sql"),
            editor_with_file("relative/report.sql"),
            editor_with_file(&long),
        ],
        active_idx: 0,
        ..Default::default()
    };
    clamp_connection(&mut state);

    assert_eq!(
        file_of(&state.tabs[0]),
        Some(std::path::Path::new("/home/me/report.sql"))
    );
    assert_eq!(file_of(&state.tabs[1]), None);
    assert_eq!(file_of(&state.tabs[2]), None);
}

#[test]
fn an_editor_record_without_a_file_keeps_the_older_format() {
    let json = serde_json::to_value(editor("SELECT 1")).unwrap();
    assert!(json.get("file").is_none(), "{json}");
    let back: WorkspaceTabRecord = serde_json::from_value(json).unwrap();
    assert_eq!(file_of(&back), None);

    let with_file = serde_json::to_value(editor_with_file("/tmp/a.sql")).unwrap();
    let restored: WorkspaceTabRecord = serde_json::from_value(with_file).unwrap();
    assert_eq!(file_of(&restored), Some(std::path::Path::new("/tmp/a.sql")));
}

#[test]
fn dropping_unknown_tabs_preserves_the_selected_editor() {
    let mut state = ConnectionWorkspaceState {
        tabs: vec![WorkspaceTabRecord::Unknown, editor("selected"), editor("other")],
        active_idx: 1,
        ..Default::default()
    };
    clamp_connection(&mut state);
    assert!(
        matches!(&state.tabs[state.active_idx as usize], WorkspaceTabRecord::Editor { query, .. } if query == "selected")
    );
}

#[test]
fn a_removed_active_tab_falls_back_to_the_first_retained_tab() {
    let mut state = ConnectionWorkspaceState {
        tabs: vec![editor("first"), WorkspaceTabRecord::Unknown, editor("last")],
        active_idx: 1,
        ..Default::default()
    };
    clamp_connection(&mut state);
    assert_eq!(state.active_idx, 0);
}

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
    WorkspaceTabRecord::Editor {
        query: query.into(),
        draft_id: None,
        file: None,
    }
}

fn connection(query: &str) -> ConnectionWorkspaceState {
    ConnectionWorkspaceState {
        tabs: vec![editor(query)],
        active_idx: 0,
        ..Default::default()
    }
}

#[test]
fn workspace_store_state_is_shared_only_with_its_clones() {
    let dir = tempfile::tempdir().unwrap();
    let path = Some(dir.path().join("workspace.json"));
    let drafts = dir.path().join("drafts");
    let first = WorkspaceStore::new(path.clone(), drafts.clone());
    let clone = first.clone();
    let separate = WorkspaceStore::new(path, drafts);
    let id = Uuid::new_v4();
    first
        .inner
        .memory
        .lock()
        .unwrap()
        .cache
        .insert(id, Some(connection("SELECT 1")));

    assert!(clone.load_connection(id).is_some());
    assert!(separate.load_connection(id).is_none());
}

#[test]
fn workspace_queue_coalesces_each_connection_to_its_newest_state() {
    let mut queue = WorkspaceQueue::default();
    let first = Uuid::new_v4();
    let second = Uuid::new_v4();
    queue.save(first, connection("SELECT 1"));
    queue.save(second, connection("SELECT 2"));
    queue.save(first, connection("SELECT 3"));

    let pending = queue.take_pending();
    assert_eq!(pending.len(), 2);
    let first_state = pending.iter().find(|(id, _)| *id == first).unwrap();
    assert_eq!(first_state.1.sequence, 3);
    assert!(matches!(&first_state.1.state.tabs[0], WorkspaceTabRecord::Editor { query, .. } if query == "SELECT 3"));
}

#[test]
fn workspace_queue_flush_waits_for_all_prior_window_saves() {
    let mut queue = WorkspaceQueue::default();
    queue.save(Uuid::new_v4(), connection("SELECT 1"));
    queue.save(Uuid::new_v4(), connection("SELECT 2"));
    let (sender, receiver) = mpsc::channel();
    queue.flush(sender);

    assert!(matches!(receiver.try_recv(), Err(mpsc::TryRecvError::Empty)));
    queue.complete_attempt(1, Ok(()));
    assert!(matches!(receiver.try_recv(), Err(mpsc::TryRecvError::Empty)));
    queue.complete_attempt(2, Ok(()));
    assert_eq!(receiver.try_recv(), Ok(Ok(())));
}

#[test]
fn workspace_queue_failed_write_is_not_acknowledged_as_persisted() {
    let mut queue = WorkspaceQueue::default();
    let id = Uuid::new_v4();
    queue.save(id, connection("SELECT 1"));
    let pending = queue.take_pending();
    let (sender, receiver) = mpsc::channel();
    queue.flush(sender);

    queue.restore_pending(pending);
    queue.complete_attempt(1, Err(WorkspaceFlushError::WriteFailed));

    assert_eq!(queue.persisted_sequence, 0);
    assert_eq!(queue.pending.len(), 1);
    assert_eq!(receiver.try_recv(), Ok(Err(WorkspaceFlushError::WriteFailed)));
}

#[test]
fn workspace_queue_failed_write_requires_a_successful_retry() {
    let mut queue = WorkspaceQueue::default();
    let id = Uuid::new_v4();
    queue.save(id, connection("SELECT 1"));
    let failed = queue.take_pending();
    let (failed_sender, failed_receiver) = mpsc::channel();
    queue.flush(failed_sender);

    queue.restore_pending(failed);
    queue.complete_attempt(1, Err(WorkspaceFlushError::WriteFailed));
    assert_eq!(failed_receiver.try_recv(), Ok(Err(WorkspaceFlushError::WriteFailed)));

    let (retry_sender, retry_receiver) = mpsc::channel();
    queue.flush(retry_sender);
    assert!(matches!(retry_receiver.try_recv(), Err(mpsc::TryRecvError::Empty)));
    let retried = queue.take_pending();
    assert_eq!(retried.len(), 1);
    queue.complete_attempt(1, Ok(()));

    assert_eq!(queue.persisted_sequence, 1);
    assert_eq!(retry_receiver.try_recv(), Ok(Ok(())));
}

#[test]
fn workspace_queue_preserves_saves_queued_during_an_older_write() {
    let mut queue = WorkspaceQueue::default();
    let first = Uuid::new_v4();
    let second = Uuid::new_v4();
    queue.save(first, connection("SELECT 1"));
    let first_batch = queue.take_pending();

    queue.save(second, connection("SELECT 2"));
    queue.save(first, connection("SELECT 3"));
    let (sender, receiver) = mpsc::channel();
    queue.flush(sender);

    queue.complete_attempt(first_batch[0].1.sequence, Ok(()));
    assert!(matches!(receiver.try_recv(), Err(mpsc::TryRecvError::Empty)));

    let second_batch = queue.take_pending();
    assert_eq!(second_batch.len(), 2);
    let attempted_sequence = second_batch.iter().map(|(_, entry)| entry.sequence).max().unwrap();
    queue.complete_attempt(attempted_sequence, Ok(()));

    assert_eq!(queue.persisted_sequence, 3);
    assert_eq!(receiver.try_recv(), Ok(Ok(())));
}

#[test]
fn failed_older_write_does_not_replace_newer_pending_state() {
    let mut queue = WorkspaceQueue::default();
    let id = Uuid::new_v4();
    queue.save(id, connection("SELECT 1"));
    let failed = queue.take_pending();
    queue.save(id, connection("SELECT 2"));

    queue.restore_pending(failed);

    let pending = queue.take_pending();
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].1.sequence, 2);
    assert!(matches!(&pending[0].1.state.tabs[0], WorkspaceTabRecord::Editor { query, .. } if query == "SELECT 2"));
}

#[test]
fn prefetch_cannot_replace_a_save_started_while_snapshot_is_loading() {
    let memory = Arc::new(Mutex::new(Memory::default()));
    let queue = Arc::new(Mutex::new(WorkspaceQueue::default()));
    let id = Uuid::new_v4();
    let mut disk_state = WorkspaceState::default();
    disk_state.connections.insert(id.to_string(), connection("SELECT old"));
    let (load_started_sender, load_started_receiver) = mpsc::sync_channel(0);
    let (continue_load_sender, continue_load_receiver) = mpsc::sync_channel(0);

    let prefetch_memory = Arc::clone(&memory);
    let prefetch = std::thread::spawn(move || {
        prefetch_connections_coordinated(
            &prefetch_memory,
            &[id],
            || {},
            || {
                load_started_sender.send(()).unwrap();
                continue_load_receiver.recv().unwrap();
                Ok(disk_state)
            },
        )
        .unwrap();
    });
    load_started_receiver.recv().unwrap();

    save_connection_coordinated(&memory, &queue, id, connection("SELECT new"));

    continue_load_sender.send(()).unwrap();
    prefetch.join().unwrap();

    let cached = memory.lock().unwrap().cache.get(&id).cloned().flatten().unwrap();
    assert!(matches!(&cached.tabs[0], WorkspaceTabRecord::Editor { query, .. } if query == "SELECT new"));
    let pending = queue.lock().unwrap().take_pending();
    assert_eq!(pending.len(), 1);
    assert!(matches!(&pending[0].1.state.tabs[0], WorkspaceTabRecord::Editor { query, .. } if query == "SELECT new"));
}

#[test]
fn a_save_does_not_wait_for_a_slow_prefetch() {
    let memory = Arc::new(Mutex::new(Memory::default()));
    let queue = Arc::new(Mutex::new(WorkspaceQueue::default()));
    let id = Uuid::new_v4();
    let (load_started_sender, load_started_receiver) = mpsc::sync_channel(0);
    let (continue_load_sender, continue_load_receiver) = mpsc::sync_channel(0);

    let prefetch_memory = Arc::clone(&memory);
    let prefetch = std::thread::spawn(move || {
        prefetch_connections_coordinated(
            &prefetch_memory,
            &[id],
            || {},
            || {
                load_started_sender.send(()).unwrap();
                continue_load_receiver.recv().unwrap();
                Ok(WorkspaceState::default())
            },
        )
        .unwrap();
    });
    load_started_receiver.recv().unwrap();

    let (saved_sender, saved_receiver) = mpsc::channel();
    let save_memory = Arc::clone(&memory);
    let save_queue = Arc::clone(&queue);
    let save = std::thread::spawn(move || {
        save_connection_coordinated(&save_memory, &save_queue, id, connection("SELECT new"));
        saved_sender.send(()).unwrap();
    });
    let finished_while_loading = saved_receiver.recv_timeout(std::time::Duration::from_secs(5)).is_ok();

    continue_load_sender.send(()).unwrap();
    prefetch.join().unwrap();
    save.join().unwrap();
    assert!(
        finished_while_loading,
        "a save must not block behind a prefetch's disk work"
    );
}

#[test]
fn clamp_truncates_tabs_beyond_limit() {
    let mut conn = ConnectionWorkspaceState {
        tabs: (0..40).map(|i| browse(&format!("t{i}"))).collect(),
        active_idx: 35,
        ..Default::default()
    };
    clamp_connection(&mut conn);
    assert_eq!(conn.tabs.len(), MAX_TABS_PER_CONNECTION);
    assert_eq!(conn.active_idx, 0);
}

#[test]
fn clamp_never_drops_editor_tabs_beyond_limit() {
    let mut tabs: Vec<_> = (0..40).map(|i| browse(&format!("t{i}"))).collect();
    tabs.extend((0..3).map(|i| editor(&format!("SELECT {i}"))));
    let mut conn = ConnectionWorkspaceState {
        tabs,
        active_idx: 41,
        ..Default::default()
    };
    clamp_connection(&mut conn);
    assert_eq!(conn.tabs.len(), MAX_TABS_PER_CONNECTION);
    assert_eq!(
        conn.tabs
            .iter()
            .filter(|tab| matches!(tab, WorkspaceTabRecord::Editor { .. }))
            .count(),
        3
    );
    assert_eq!(conn.active_idx, 30);
}

#[test]
fn clamp_keeps_every_editor_even_when_they_exceed_the_limit() {
    let mut conn = ConnectionWorkspaceState {
        tabs: (0..40).map(|i| editor(&format!("SELECT {i}"))).collect(),
        ..Default::default()
    };
    clamp_connection(&mut conn);
    assert_eq!(conn.tabs.len(), 40);
}

#[test]
fn clamp_handles_mixed_browse_and_editor_tabs() {
    let mut conn = ConnectionWorkspaceState {
        tabs: vec![browse("users"), editor("SELECT 1"), browse("orders")],
        active_idx: 1,
        ..Default::default()
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
        ..Default::default()
    };
    clamp_connection(&mut conn);
    match &conn.tabs[0] {
        WorkspaceTabRecord::Table { mode, page_size, .. } => {
            assert_eq!(*mode, PersistedTableMode::Data);
            assert_eq!(*page_size, DEFAULT_PAGE_SIZE);
        }
        _ => panic!("expected Table after migration"),
    }
}

#[test]
fn clamp_preserves_the_complete_query() {
    let mut q = "a".repeat(512 * 1024);
    q.push('é');
    let mut conn = ConnectionWorkspaceState {
        tabs: vec![editor(&q)],
        active_idx: 0,
        ..Default::default()
    };
    clamp_connection(&mut conn);
    match &conn.tabs[0] {
        WorkspaceTabRecord::Editor { query, .. } => {
            assert!(query.is_char_boundary(query.len()));
            assert_eq!(query, &q);
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
            ..Default::default()
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
fn a_structure_record_restores_as_a_structure_tab() {
    let record = WorkspaceTabRecord::Structure {
        schema: Some("public".into()),
        table: "users".into(),
    };
    assert_eq!(
        restored_workspace_tab(&record),
        Some(RestoredWorkspaceTab::Structure {
            schema: Some("public".into()),
            table: "users".into(),
        })
    );
}

#[test]
fn a_table_record_in_structure_mode_restores_as_a_structure_tab() {
    let record = WorkspaceTabRecord::Table {
        schema: Some("public".into()),
        table: "users".into(),
        mode: PersistedTableMode::Structure,
        offset: 100,
        page_size: DEFAULT_PAGE_SIZE,
        sort_col: Some(1),
        sort_asc: Some(true),
        preview: false,
    };
    assert_eq!(
        restored_workspace_tab(&record),
        Some(RestoredWorkspaceTab::Structure {
            schema: Some("public".into()),
            table: "users".into(),
        })
    );
}

#[test]
fn a_table_record_in_data_mode_restores_browse_state() {
    let record = WorkspaceTabRecord::Table {
        schema: None,
        table: "jobs".into(),
        mode: PersistedTableMode::Data,
        offset: 50,
        page_size: 100,
        sort_col: Some(2),
        sort_asc: Some(false),
        preview: false,
    };
    assert_eq!(
        restored_workspace_tab(&record),
        Some(RestoredWorkspaceTab::Table {
            schema: None,
            table: "jobs".into(),
            offset: 50,
            page_size: 100,
            sort: Some((2, false)),
            preview: false,
        })
    );
}

#[test]
fn an_empty_structure_table_is_not_restored() {
    let record = WorkspaceTabRecord::Structure {
        schema: None,
        table: String::new(),
    };
    assert_eq!(restored_workspace_tab(&record), None);
}

#[test]
fn legacy_record_loads_with_serde_defaults() {
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
        WorkspaceTabRecord::Editor { query, .. } => assert_eq!(query, ""),
        _ => panic!("expected Editor"),
    }
}

#[test]
fn collapsed_groups_round_trip_and_an_older_file_has_none() {
    let mut conn = connection("SELECT 1");
    conn.collapsed_groups = vec!["schema:public/views".into()];
    let json = serde_json::to_string(&conn).unwrap();
    let restored: ConnectionWorkspaceState = serde_json::from_str(&json).unwrap();
    assert_eq!(restored.collapsed_groups, vec!["schema:public/views".to_string()]);

    let older: ConnectionWorkspaceState = serde_json::from_str(r#"{"tabs":[],"active_idx":0}"#).unwrap();
    assert!(older.collapsed_groups.is_empty());
    assert!(!serde_json::to_string(&older).unwrap().contains("collapsed_groups"));
}

#[test]
fn collapsed_groups_are_bounded_when_saved() {
    let mut conn = connection("SELECT 1");
    conn.collapsed_groups = (0..MAX_COLLAPSED_GROUPS + 10)
        .map(|index| format!("schema:s{index}/tables"))
        .collect();
    conn.collapsed_groups.push("x".repeat(MAX_COLLAPSED_KEY_BYTES + 1));
    clamp_connection(&mut conn);
    assert_eq!(conn.collapsed_groups.len(), MAX_COLLAPSED_GROUPS);
    assert!(
        conn.collapsed_groups
            .iter()
            .all(|key| key.len() <= MAX_COLLAPSED_KEY_BYTES)
    );
}

#[test]
fn hidden_schemas_round_trip_and_are_bounded_when_saved() {
    let mut conn = connection("SELECT 1");
    conn.hidden_schemas = vec!["private".into(), "private".into(), String::new()];
    conn.hidden_schemas.push("x".repeat(MAX_SCHEMA_NAME_BYTES + 1));
    conn.hidden_schemas
        .extend((0..MAX_HIDDEN_SCHEMAS + 2).map(|i| format!("s{i}")));
    clamp_connection(&mut conn);

    let restored: ConnectionWorkspaceState = serde_json::from_str(&serde_json::to_string(&conn).unwrap()).unwrap();
    assert_eq!(restored.hidden_schemas, conn.hidden_schemas);
    assert_eq!(restored.hidden_schemas.len(), MAX_HIDDEN_SCHEMAS);
    assert!(
        restored
            .hidden_schemas
            .iter()
            .all(|schema| !schema.is_empty() && schema.len() <= MAX_SCHEMA_NAME_BYTES)
    );
}

#[test]
fn an_older_workspace_defaults_to_no_hidden_schemas() {
    let older: ConnectionWorkspaceState = serde_json::from_str(r#"{"tabs":[],"active_idx":0}"#).unwrap();
    assert!(older.hidden_schemas.is_empty());
}
