use super::*;
use tablepro_core::ColumnInfo;

fn pk_col(name: &str) -> ColumnInfo {
    ColumnInfo {
        name: name.into(),
        data_type: "integer".into(),
        nullable: false,
        primary_key: true,
        is_auto_increment: true,
        default_value: None,
        is_generated: false,
        comment: None,
        collation: None,
        enum_type: None,
        domain_type: None,
    }
}

fn data_col(name: &str) -> ColumnInfo {
    ColumnInfo {
        name: name.into(),
        data_type: "text".into(),
        nullable: false,
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

fn rk(values: &[Value]) -> RowKey {
    RowKey::from_pk_values(values).unwrap()
}

#[test]
fn cell_edit_creates_modified_state() {
    let mut t = TabChangeTracker::new();
    let key = rk(&[Value::Int(1)]);
    t.track_cell_edit(key.clone(), 1, Value::Text("a".into()), Value::Text("b".into()));
    assert_eq!(t.cell_state(&key, 1), CellState::Modified);
    assert_eq!(t.row_state(&key), RowState::Modified);
    assert_eq!(t.pending_count(), 1);
}

#[test]
fn cell_edit_back_to_original_drops_modification() {
    let mut t = TabChangeTracker::new();
    let key = rk(&[Value::Int(1)]);
    t.track_cell_edit(key.clone(), 1, Value::Text("a".into()), Value::Text("b".into()));
    t.track_cell_edit(key.clone(), 1, Value::Text("a".into()), Value::Text("a".into()));
    assert_eq!(t.cell_state(&key, 1), CellState::Clean);
    assert_eq!(t.pending_count(), 0);
    assert!(t.can_undo());
}

#[test]
fn insert_assigns_unique_draft_ids() {
    let mut t = TabChangeTracker::new();
    let k1 = t.track_insert(vec![Value::Null, Value::Null]);
    let k2 = t.track_insert(vec![Value::Null, Value::Null]);
    assert_ne!(k1, k2);
    assert!(matches!(k1, RowKey::Draft(_)));
    assert_eq!(t.drafts().len(), 2);
    assert_eq!(t.pending_count(), 2);
}

#[test]
fn delete_marks_row_pending() {
    let mut t = TabChangeTracker::new();
    let key = rk(&[Value::Int(7)]);
    t.track_delete(key.clone(), vec![Value::Int(7), Value::Text("dave".into())]);
    assert_eq!(t.row_state(&key), RowState::PendingDelete);
    assert_eq!(t.pending_count(), 1);
}

#[test]
fn undo_reverts_cell_edit() {
    let mut t = TabChangeTracker::new();
    let key = rk(&[Value::Int(1)]);
    t.track_cell_edit(key.clone(), 1, Value::Text("a".into()), Value::Text("b".into()));
    let undone = t.undo();
    assert!(matches!(
        undone,
        Some(UndoOp::CellEdit { ref row_key, col: 1, .. }) if row_key == &key
    ));
    assert_eq!(t.cell_state(&key, 1), CellState::Clean);
    assert!(t.can_redo());
}

#[test]
fn redo_reapplies_cell_edit() {
    let mut t = TabChangeTracker::new();
    let key = rk(&[Value::Int(1)]);
    t.track_cell_edit(key.clone(), 1, Value::Text("a".into()), Value::Text("b".into()));
    t.undo();
    t.redo();
    assert_eq!(t.cell_state(&key, 1), CellState::Modified);
}

#[test]
fn undo_stack_caps_at_50() {
    let mut t = TabChangeTracker::new();
    let key = rk(&[Value::Int(1)]);
    for i in 0..100 {
        t.track_cell_edit(key.clone(), 1, Value::Int(i), Value::Int(i + 1));
    }
    assert_eq!(t.undo.len(), UNDO_LIMIT);
}

#[test]
fn clear_removes_all_state() {
    let mut t = TabChangeTracker::new();
    let key = rk(&[Value::Int(1)]);
    t.track_cell_edit(key.clone(), 1, Value::Text("a".into()), Value::Text("b".into()));
    t.track_insert(vec![Value::Null]);
    t.track_delete(rk(&[Value::Int(2)]), vec![Value::Int(2)]);
    t.clear();
    assert_eq!(t.pending_count(), 0);
    assert!(!t.can_undo());
}

#[test]
fn materialize_orders_inserts_then_updates_then_deletes() {
    let mut t = TabChangeTracker::new();
    let columns = vec![pk_col("id"), data_col("name")];
    let updated = rk(&[Value::Int(5)]);
    t.track_cell_edit(updated.clone(), 1, Value::Text("old".into()), Value::Text("new".into()));
    t.track_insert(vec![Value::Null, Value::Text("draft".into())]);
    t.track_delete(rk(&[Value::Int(9)]), vec![Value::Int(9), Value::Text("doomed".into())]);
    let (stmts, sources) = t.materialize("postgres", None, "users", &columns).unwrap();
    assert_eq!(stmts.len(), 3);
    assert_eq!(sources.len(), 3);
    assert!(stmts[0].0.starts_with("INSERT"));
    assert!(matches!(sources[0], StatementSource::Insert { .. }));
    assert!(stmts[1].0.starts_with("UPDATE"));
    assert!(matches!(sources[1], StatementSource::Update { .. }));
    assert!(stmts[1].0.contains("\"name\" IS NOT DISTINCT FROM $3"));
    assert_eq!(
        stmts[1].1,
        vec![Value::Text("new".into()), Value::Int(5), Value::Text("old".into())]
    );
    assert!(stmts[2].0.starts_with("DELETE"));
    assert!(matches!(sources[2], StatementSource::Delete { .. }));
}

#[test]
fn mongodb_materialize_guards_edited_fields_with_the_original_value() {
    let mut t = TabChangeTracker::new();
    let columns = vec![pk_col("_id"), data_col("payload")];
    let key = rk(&[Value::Text("id-1".into())]);
    t.track_cell_edit(key, 1, Value::Text("before".into()), Value::Text("edited".into()));

    let (statements, _) = t.materialize("mongodb", Some("appdb"), "records", &columns).unwrap();

    assert_eq!(
        statements[0].0,
        "UPDATE \"appdb\".\"records\" SET \"payload\" = ? WHERE \"_id\" = ? AND \"payload\" = ?"
    );
    assert_eq!(
        statements[0].1,
        vec![
            Value::Text("edited".into()),
            Value::Text("id-1".into()),
            Value::Text("before".into())
        ]
    );

    let mut explicit_null = TabChangeTracker::new();
    explicit_null.track_cell_edit(
        rk(&[Value::Text("id-2".into())]),
        1,
        Value::Null,
        Value::Text("edited".into()),
    );
    let (statements, _) = explicit_null
        .materialize("mongodb", Some("appdb"), "records", &columns)
        .unwrap();
    assert_eq!(statements[0].1[2], Value::Null);
}

#[test]
fn mongodb_materialize_guards_deletes_with_the_complete_original_row() {
    let mut t = TabChangeTracker::new();
    let columns = vec![pk_col("_id"), data_col("nullable"), data_col("missing")];
    t.track_delete(
        rk(&[Value::Text("id-1".into())]),
        vec![
            Value::Text("id-1".into()),
            Value::Null,
            Value::Undecodable("missing BSON field".into()),
        ],
    );

    let (statements, _) = t.materialize("mongodb", Some("appdb"), "records", &columns).unwrap();

    assert_eq!(
        statements[0].0,
        "DELETE FROM \"appdb\".\"records\" WHERE \"_id\" = ? AND \"nullable\" = ? AND \"missing\" = ? AND tablepro_mongodb_exact_field_set(?)"
    );
    assert_eq!(
        statements[0].1,
        vec![
            Value::Text("id-1".into()),
            Value::Null,
            Value::Undecodable("missing BSON field".into()),
            Value::Json(serde_json::json!(["_id", "nullable"]))
        ]
    );
}

#[test]
fn materialize_uses_is_null_for_null_pk_components() {
    let mut t = TabChangeTracker::new();
    let columns = vec![
        ColumnInfo {
            name: "a".into(),
            data_type: "integer".into(),
            nullable: false,
            primary_key: true,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        },
        ColumnInfo {
            name: "b".into(),
            data_type: "integer".into(),
            nullable: true,
            primary_key: true,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        },
        data_col("name"),
    ];
    let key = RowKey::from_pk_values(&[Value::Int(1), Value::Null]).unwrap();
    t.track_cell_edit(key, 2, Value::Text("old".into()), Value::Text("new".into()));
    let (stmts, _sources) = t.materialize("postgres", None, "t", &columns).unwrap();
    assert_eq!(stmts.len(), 1);
    assert_eq!(
        stmts[0].0,
        "UPDATE \"t\" SET \"name\" = $1 WHERE \"a\" = $2 AND \"b\" IS NULL AND \"name\" IS NOT DISTINCT FROM $3"
    );
    assert_eq!(
        stmts[0].1,
        vec![Value::Text("new".into()), Value::Int(1), Value::Text("old".into())]
    );
}

#[test]
fn materialize_delete_uses_is_null_for_null_pk_components() {
    let mut t = TabChangeTracker::new();
    let columns = vec![
        ColumnInfo {
            name: "a".into(),
            data_type: "integer".into(),
            nullable: true,
            primary_key: true,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        },
        data_col("name"),
    ];
    let key = RowKey::from_pk_values(&[Value::Null]).unwrap();
    t.track_delete(key, vec![Value::Null, Value::Text("doomed".into())]);
    let (stmts, _sources) = t.materialize("mysql", None, "t", &columns).unwrap();
    assert_eq!(stmts.len(), 1);
    assert_eq!(stmts[0].0, "DELETE FROM `t` WHERE `a` IS NULL");
    assert!(stmts[0].1.is_empty());
}

#[test]
fn registry_open_close_idempotent() {
    let mut reg = ChangeTrackerRegistry::new();
    let id = Uuid::new_v4();
    reg.open_tab(id);
    reg.open_tab(id);
    assert!(reg.trackers.contains_key(&id));
    reg.close_tab(id);
    assert!(!reg.trackers.contains_key(&id));
}

#[test]
fn registry_any_pending_reports_correctly() {
    let mut reg = ChangeTrackerRegistry::new();
    let id = Uuid::new_v4();
    reg.open_tab(id);
    assert!(!reg.any_pending());
    let key = rk(&[Value::Int(1)]);
    reg.trackers
        .get_mut(&id)
        .unwrap()
        .track_cell_edit(key, 0, Value::Int(1), Value::Int(2));
    assert!(reg.any_pending());
    assert_eq!(reg.pending_tabs_for(&std::collections::HashSet::from([id])), vec![id]);
}

#[test]
fn registry_pending_tabs_for_does_not_include_another_window() {
    let mut reg = ChangeTrackerRegistry::new();
    let first = Uuid::new_v4();
    let second = Uuid::new_v4();
    reg.open_tab(first);
    reg.open_tab(second);
    reg.trackers
        .get_mut(&first)
        .unwrap()
        .track_cell_edit(rk(&[Value::Int(1)]), 0, Value::Int(1), Value::Int(2));
    reg.trackers
        .get_mut(&second)
        .unwrap()
        .track_cell_edit(rk(&[Value::Int(2)]), 0, Value::Int(2), Value::Int(3));

    let first_window = std::collections::HashSet::from([first]);
    let second_window = std::collections::HashSet::from([second]);

    assert_eq!(reg.pending_tabs_for(&first_window), vec![first]);
    assert_eq!(reg.pending_tabs_for(&second_window), vec![second]);
}

#[test]
fn discard_draft_removes_insert_and_clears_undo() {
    let mut t = TabChangeTracker::new();
    let key = t.track_insert(vec![Value::Null, Value::Text("hi".into())]);
    let RowKey::Draft(draft_id) = key else {
        panic!("track_insert must return Draft key");
    };
    t.track_draft_cell_edit(draft_id, 1, Value::Text("edited".into()));
    assert_eq!(t.drafts().len(), 1);
    assert!(t.can_undo());

    let removed = t.discard_draft(draft_id);

    assert!(removed, "discard_draft must report removal");
    assert!(t.drafts().is_empty(), "draft must be gone");
    assert!(!t.can_undo(), "undo entries scoped to the draft must be cleared");
    assert!(!t.has_pending(), "no pending state after discard");
}

#[test]
fn discard_draft_no_op_for_unknown_id() {
    let mut t = TabChangeTracker::new();
    assert!(!t.discard_draft(99_999));
    assert!(!t.has_pending());
}

#[test]
fn discard_draft_leaves_other_drafts_intact() {
    let mut t = TabChangeTracker::new();
    let RowKey::Draft(a) = t.track_insert(vec![Value::Int(1)]) else {
        panic!()
    };
    let RowKey::Draft(b) = t.track_insert(vec![Value::Int(2)]) else {
        panic!()
    };
    assert_eq!(t.drafts().len(), 2);
    assert!(t.discard_draft(a));
    assert_eq!(t.drafts().len(), 1);
    assert_eq!(t.drafts()[0].draft_id, b);
    assert!(t.can_undo());
}

#[test]
fn bulk_delete_via_track_delete_is_per_row_undoable() {
    let mut t = TabChangeTracker::new();
    let k1 = rk(&[Value::Int(1)]);
    let k2 = rk(&[Value::Int(2)]);
    let k3 = rk(&[Value::Int(3)]);
    t.track_delete(k1.clone(), vec![Value::Int(1)]);
    t.track_delete(k2.clone(), vec![Value::Int(2)]);
    t.track_delete(k3.clone(), vec![Value::Int(3)]);
    assert_eq!(t.pending_count(), 3);

    let _ = t.undo();
    assert_eq!(t.pending_count(), 2);
    assert!(matches!(t.row_state(&k3), RowState::Clean));
    assert!(matches!(t.row_state(&k1), RowState::PendingDelete));
    assert!(matches!(t.row_state(&k2), RowState::PendingDelete));
}

#[test]
fn an_undecodable_pk_value_round_trips_through_key_value() {
    let original = Value::Undecodable("NUMERIC".into());
    let key = KeyValue::from(&original);
    assert_eq!(key, KeyValue::Undecodable("NUMERIC".into()));
    assert_eq!(keyvalue_to_value(&key), original);
}

#[test]
fn an_undecodable_pk_component_yields_no_persisted_row_key() {
    assert!(RowKey::from_pk_values(&[Value::Undecodable("NUMERIC".into())]).is_none());
    assert!(RowKey::from_pk_values(&[Value::Int(1), Value::Undecodable("INTERVAL".into())]).is_none());
    assert!(RowKey::from_pk_values(&[Value::Int(1)]).is_some());
    assert!(RowKey::from_pk_values(&[]).is_none());
}

#[test]
fn two_rows_with_the_same_undecodable_key_type_never_share_a_row_key() {
    let first = RowKey::from_pk_values(&[Value::Undecodable("NUMERIC".into())]);
    let second = RowKey::from_pk_values(&[Value::Undecodable("NUMERIC".into())]);
    assert!(first.is_none());
    assert!(second.is_none());
}

#[test]
fn a_pending_delete_on_an_undecodable_key_cannot_be_attributed_to_another_row() {
    let mut t = TabChangeTracker::new();
    let readable = rk(&[Value::Int(1)]);
    t.track_delete(readable.clone(), vec![Value::Int(1), Value::Text("doomed".into())]);
    let unreadable = RowKey::from_pk_values(&[Value::Undecodable("NUMERIC".into())]);
    assert!(unreadable.is_none());
    assert!(matches!(t.row_state(&readable), RowState::PendingDelete));
    assert_eq!(t.pending_count(), 1);
}

#[test]
fn materialize_refuses_an_update_whose_key_could_not_be_read() {
    let mut t = TabChangeTracker::new();
    let columns = vec![pk_col("id"), data_col("name")];
    let key = RowKey::Persisted(vec![KeyValue::Undecodable("NUMERIC".into())]);
    t.track_cell_edit(key, 1, Value::Text("old".into()), Value::Text("new".into()));
    let err = t.materialize("postgres", None, "t", &columns).unwrap_err();
    assert!(matches!(err, MaterializeError::UnreadableRowKey));
}

#[test]
fn materialize_refuses_a_delete_whose_key_could_not_be_read() {
    let mut t = TabChangeTracker::new();
    let columns = vec![pk_col("id"), data_col("name")];
    let key = RowKey::Persisted(vec![KeyValue::Undecodable("NUMERIC".into())]);
    t.track_delete(key, vec![Value::Undecodable("NUMERIC".into()), Value::Text("x".into())]);
    let err = t.materialize("postgres", None, "t", &columns).unwrap_err();
    assert!(matches!(err, MaterializeError::UnreadableRowKey));
}
