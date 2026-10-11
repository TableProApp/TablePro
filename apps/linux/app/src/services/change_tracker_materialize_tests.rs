//! `materialize` turns pending edits into the statements a save runs
//! inside one transaction. These tests pin the properties that make the
//! batch safe to execute and reproducible to diagnose.

use super::*;
use tablepro_core::ColumnInfo;
use tablepro_core::sql_dialect::BuildSqlError;

fn pk(name: &str) -> ColumnInfo {
    ColumnInfo {
        name: name.into(),
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
    }
}

fn data(name: &str) -> ColumnInfo {
    ColumnInfo {
        name: name.into(),
        data_type: "text".into(),
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

fn schema() -> Vec<ColumnInfo> {
    vec![pk("id"), data("note"), data("label")]
}

fn key(id: i64) -> RowKey {
    RowKey::from_pk_values(&[Value::Int(id)]).expect("a single-column key")
}

fn materialize(tracker: &TabChangeTracker) -> (Vec<(String, Vec<Value>)>, Vec<StatementSource>) {
    tracker
        .materialize("postgres", None, "t", &schema())
        .expect("the batch must build")
}

/// The primary-key value each update targets, read from its WHERE placeholder.
fn targeted_ids(statements: &[(String, Vec<Value>)]) -> Vec<i64> {
    statements
        .iter()
        .filter_map(|(sql, params)| {
            let (_, predicate) = sql.split_once("WHERE \"id\" = $")?;
            let digits: String = predicate.chars().take_while(char::is_ascii_digit).collect();
            let index = digits.parse::<usize>().ok()?.checked_sub(1)?;
            match params.get(index) {
                Some(Value::Int(id)) => Some(*id),
                _ => None,
            }
        })
        .collect()
}

#[test]
fn updates_are_emitted_in_primary_key_order_so_a_batch_is_reproducible() {
    let mut tracker = TabChangeTracker::new();
    // Insertion order deliberately unsorted: a HashMap walk would emit
    // these in an order that depends on the process's hash seed.
    for id in [7, 2, 5, 1, 8, 3, 6, 4] {
        tracker.track_cell_edit(key(id), 1, Value::Null, Value::Text(format!("v{id}")));
    }

    let (statements, _) = materialize(&tracker);
    assert_eq!(
        targeted_ids(&statements),
        vec![1, 2, 3, 4, 5, 6, 7, 8],
        "an unordered batch cannot be reproduced or locked consistently"
    );
}

#[test]
fn deletes_are_emitted_in_primary_key_order_too() {
    let mut tracker = TabChangeTracker::new();
    for id in [4, 1, 3, 2] {
        tracker.track_delete(key(id), vec![Value::Int(id), Value::Null, Value::Null]);
    }

    let (statements, _) = materialize(&tracker);
    assert!(statements.iter().all(|(sql, _)| sql.starts_with("DELETE")));
    assert_eq!(targeted_ids(&statements), vec![1, 2, 3, 4]);
}

#[test]
fn the_batch_runs_inserts_then_updates_then_deletes() {
    let mut tracker = TabChangeTracker::new();
    tracker.track_cell_edit(key(1), 1, Value::Null, Value::Text("edited".into()));
    tracker.track_delete(key(2), vec![Value::Int(2), Value::Null, Value::Null]);
    tracker.track_insert(vec![Value::Int(9), Value::Text("new".into()), Value::Null]);

    let (statements, _) = materialize(&tracker);
    let kinds: Vec<&str> = statements
        .iter()
        .map(|(sql, _)| match sql {
            sql if sql.starts_with("INSERT") => "insert",
            sql if sql.starts_with("UPDATE") => "update",
            sql if sql.starts_with("DELETE") => "delete",
            _ => "other",
        })
        .collect();
    assert_eq!(
        kinds,
        vec!["insert", "update", "delete"],
        "deletes must run last so a foreign key referencing a deleted row is freed first"
    );
}

#[test]
fn every_statement_has_a_source_describing_the_row_it_came_from() {
    let mut tracker = TabChangeTracker::new();
    tracker.track_cell_edit(key(1), 1, Value::Null, Value::Text("a".into()));
    tracker.track_cell_edit(key(2), 2, Value::Null, Value::Text("b".into()));
    tracker.track_delete(key(3), vec![Value::Int(3), Value::Null, Value::Null]);
    let draft = tracker.track_insert(vec![Value::Int(4), Value::Null, Value::Null]);

    let (statements, sources) = materialize(&tracker);
    assert_eq!(
        statements.len(),
        sources.len(),
        "a failing statement index has to resolve to a row, so the two lists must stay aligned"
    );
    assert!(matches!(sources[0], StatementSource::Insert { draft_id } if RowKey::Draft(draft_id) == draft));
    assert!(matches!(&sources[1], StatementSource::Update { row_key } if *row_key == key(1)));
    assert!(matches!(&sources[2], StatementSource::Update { row_key } if *row_key == key(2)));
    assert!(matches!(&sources[3], StatementSource::Delete { row_key } if *row_key == key(3)));
}

#[test]
fn several_edits_to_one_row_become_a_single_update() {
    let mut tracker = TabChangeTracker::new();
    tracker.track_cell_edit(key(1), 1, Value::Null, Value::Text("note".into()));
    tracker.track_cell_edit(key(1), 2, Value::Null, Value::Text("label".into()));

    let (statements, sources) = materialize(&tracker);
    assert_eq!(statements.len(), 1, "one row must not be updated twice in one batch");
    assert_eq!(sources.len(), 1);
    let (sql, params) = &statements[0];
    assert_eq!(
        sql,
        "UPDATE \"t\" SET \"note\" = $1, \"label\" = $2 WHERE \"id\" = $3 AND \"note\" IS NOT DISTINCT FROM $4 AND \"label\" IS NOT DISTINCT FROM $5"
    );
    assert_eq!(
        params,
        &vec![
            Value::Text("note".into()),
            Value::Text("label".into()),
            Value::Int(1),
            Value::Null,
            Value::Null,
        ]
    );
}

#[test]
fn an_update_writes_only_the_columns_the_user_touched() {
    let mut tracker = TabChangeTracker::new();
    tracker.track_cell_edit(key(1), 2, Value::Null, Value::Text("only label".into()));

    let (statements, _) = materialize(&tracker);
    let (sql, _) = &statements[0];
    assert!(sql.contains("\"label\""), "{sql}");
    assert!(
        !sql.contains("\"note\""),
        "writing an untouched column would clobber another session's edit: {sql}"
    );
}

#[test]
fn a_discarded_draft_contributes_no_statement() {
    let mut tracker = TabChangeTracker::new();
    let draft = tracker.track_insert(vec![Value::Int(1), Value::Null, Value::Null]);
    let RowKey::Draft(draft_id) = draft else {
        panic!("track_insert must return a draft key");
    };
    assert!(tracker.discard_draft(draft_id));

    let (statements, sources) = materialize(&tracker);
    assert!(statements.is_empty(), "a discarded draft must not be inserted");
    assert!(sources.is_empty());
}

#[test]
fn a_null_key_component_is_matched_with_is_null_rather_than_equality() {
    let columns = vec![pk("a"), pk("b"), data("note")];
    let mut tracker = TabChangeTracker::new();
    let row_key = RowKey::from_pk_values(&[Value::Int(1), Value::Null]).expect("a composite key");
    tracker.track_cell_edit(row_key, 2, Value::Null, Value::Text("x".into()));

    let (statements, _) = tracker
        .materialize("postgres", None, "t", &columns)
        .expect("the batch must build");
    let (sql, params) = &statements[0];
    assert_eq!(
        sql,
        "UPDATE \"t\" SET \"note\" = $1 WHERE \"a\" = $2 AND \"b\" IS NULL AND \"note\" IS NOT DISTINCT FROM $3"
    );
    assert_eq!(
        params,
        &vec![Value::Text("x".into()), Value::Int(1), Value::Null],
        "a NULL key component must not consume a placeholder, but the old cell value does"
    );
}

#[test]
fn a_table_without_a_primary_key_refuses_to_build_an_update() {
    let columns = vec![data("a"), data("b")];
    let mut tracker = TabChangeTracker::new();
    tracker.track_cell_edit(key(1), 1, Value::Null, Value::Text("x".into()));

    let error = tracker
        .materialize("postgres", None, "t", &columns)
        .expect_err("without a key there is no safe WHERE clause");
    assert!(matches!(error, MaterializeError::BuildSql(BuildSqlError::NoPrimaryKey)));
}

/// H11: a Structure tab dropping a column must not panic a pending Browse
/// tab edit that recorded an index into the old, wider column list.
#[test]
fn an_update_targeting_a_column_dropped_since_it_was_tracked_refuses_instead_of_panicking() {
    let mut tracker = TabChangeTracker::new();
    tracker.track_cell_edit(key(1), 2, Value::Null, Value::Text("x".into()));

    // The column at index 2 ("label") no longer exists after the drop.
    let narrow_columns = vec![pk("id"), data("note")];
    let error = tracker
        .materialize("postgres", None, "t", &narrow_columns)
        .expect_err("an index into the old column list must not be reused against the new one");
    assert!(matches!(error, MaterializeError::BuildSql(BuildSqlError::StaleColumns)));
}

/// H11's other half: a delete recorded against a wider primary key (before
/// a PK column was dropped) must not panic when the current PK is narrower.
#[test]
fn a_delete_targeting_a_shrunk_primary_key_refuses_instead_of_panicking() {
    let mut tracker = TabChangeTracker::new();
    let row_key = RowKey::from_pk_values(&[Value::Int(1), Value::Int(2)]).expect("a composite key");
    tracker.track_delete(row_key, vec![Value::Int(1), Value::Int(2), Value::Null]);

    // Column "b" was dropped from the primary key; only "a" remains.
    let narrow_columns = vec![pk("a"), data("note")];
    let error = tracker
        .materialize("postgres", None, "t", &narrow_columns)
        .expect_err("a PK shape recorded before the drop must not be reused against the new one");
    assert!(matches!(error, MaterializeError::BuildSql(BuildSqlError::StaleColumns)));
}

#[test]
fn an_empty_tracker_produces_no_statements() {
    let tracker = TabChangeTracker::new();
    let (statements, sources) = materialize(&tracker);
    assert!(statements.is_empty());
    assert!(sources.is_empty());
}

#[test]
fn the_batch_is_identical_however_the_edits_arrived() {
    let mut forwards = TabChangeTracker::new();
    for id in [1, 2, 3, 4, 5] {
        forwards.track_cell_edit(key(id), 1, Value::Null, Value::Text(format!("v{id}")));
    }
    let mut backwards = TabChangeTracker::new();
    for id in [5, 4, 3, 2, 1] {
        backwards.track_cell_edit(key(id), 1, Value::Null, Value::Text(format!("v{id}")));
    }

    assert_eq!(materialize(&forwards).0, materialize(&backwards).0);
}

#[test]
fn typed_primary_keys_reach_the_where_clause_unchanged() {
    let wide = rust_decimal::Decimal::from_str_exact("18446744073709551615").unwrap();
    let id = uuid::Uuid::parse_str("6f1c2a8e-3b4d-4e5f-8a9b-0c1d2e3f4a5b").unwrap();
    let keys = [
        vec![Value::Uuid(id)],
        vec![Value::Int(9_007_199_254_740_993)],
        vec![Value::Decimal(wide)],
        vec![Value::Bytes(id.as_bytes().to_vec())],
        vec![Value::Int(1), Value::Text("a".into())],
    ];
    for key_values in keys {
        let columns: Vec<ColumnInfo> = (0..key_values.len())
            .map(|i| pk(&format!("k{i}")))
            .chain(std::iter::once(data("note")))
            .collect();
        let note = columns.len() - 1;
        let row_key = RowKey::from_pk_values(&key_values).unwrap();
        let mut tracker = TabChangeTracker::new();
        tracker.track_cell_edit(row_key.clone(), note, Value::Null, Value::Text("edited".into()));
        tracker.track_delete(row_key, Vec::new());

        let (statements, _) = tracker.materialize("postgres", None, "t", &columns).unwrap();
        let mut update_params = vec![Value::Text("edited".into())];
        update_params.extend(key_values.iter().cloned());
        update_params.push(Value::Null);
        assert_eq!(statements[0].1, update_params);
        assert_eq!(statements[1].1, key_values);
    }
}

#[test]
fn an_edit_that_changes_only_the_stored_form_of_a_number_is_kept() {
    let decimal = |text: &str| Value::Decimal(text.parse().unwrap());
    for (before, after) in [
        (decimal("1.5"), decimal("1.50")),
        (Value::Float(0.0), Value::Float(-0.0)),
    ] {
        let mut tracker = TabChangeTracker::new();
        tracker.track_cell_edit(key(1), 1, before, after);
        assert_eq!(tracker.pending_count(), 1);
    }
}

#[test]
fn an_edit_back_to_the_identical_value_is_dropped() {
    for value in [
        Value::Float(f64::NAN),
        Value::Decimal("1.50".parse().unwrap()),
        Value::Int(3),
    ] {
        let mut tracker = TabChangeTracker::new();
        tracker.track_cell_edit(key(1), 1, value.clone(), value);
        assert_eq!(tracker.pending_count(), 0);
    }
}

fn only_update(tracker: &TabChangeTracker) -> Vec<Value> {
    let (statements, _) = materialize(tracker);
    assert_eq!(statements.len(), 1, "{statements:?}");
    statements[0].1.clone()
}

fn text(value: &str) -> Value {
    Value::Text(value.into())
}

#[test]
fn undoing_the_second_of_two_edits_keeps_the_first_pending_against_the_stored_value() {
    let mut tracker = TabChangeTracker::new();
    tracker.track_cell_edit(key(1), 1, text("a"), text("b"));
    tracker.track_cell_edit(key(1), 1, text("b"), text("c"));

    tracker.undo().expect("the second edit");

    assert_eq!(tracker.pending_count(), 1);
    assert_eq!(only_update(&tracker), vec![text("b"), Value::Int(1), text("a")]);
    tracker.undo().expect("the first edit");
    assert_eq!(tracker.pending_count(), 0);
}

#[test]
fn redoing_an_edit_after_a_partial_undo_still_guards_on_the_stored_value() {
    let mut tracker = TabChangeTracker::new();
    tracker.track_cell_edit(key(1), 1, text("a"), text("b"));
    tracker.track_cell_edit(key(1), 1, text("b"), text("c"));
    tracker.undo().expect("the second edit");

    tracker.redo().expect("the second edit again");

    assert_eq!(only_update(&tracker), vec![text("c"), Value::Int(1), text("a")]);
}

#[test]
fn redoing_after_undoing_everything_restores_the_first_edit() {
    let mut tracker = TabChangeTracker::new();
    tracker.track_cell_edit(key(1), 1, text("a"), text("b"));
    tracker.undo().expect("the edit");
    assert_eq!(tracker.pending_count(), 0);

    tracker.redo().expect("the edit again");

    assert_eq!(only_update(&tracker), vec![text("b"), Value::Int(1), text("a")]);
}
