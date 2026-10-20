use std::cell::RefCell;
use std::collections::{HashMap, VecDeque};

use uuid::Uuid;

use tablepro_core::{
    ColumnInfo, Value,
    sql_dialect::{
        build_insert_from_draft_touched, build_keyed_delete, build_keyed_update, build_mongodb_keyed_delete,
        build_mongodb_keyed_update, build_optimistic_keyed_update,
    },
};

#[path = "change_tracker_draft.rs"]
mod draft;
#[path = "change_tracker_row_identity.rs"]
mod row_identity;

pub use draft::DraftRow;

use row_identity::keyvalue_to_value;
pub use row_identity::{KeyValue, MaterializeError, RowKey, pk_values_are_unreadable};

const UNDO_LIMIT: usize = 50;

#[derive(Debug, Clone)]
pub struct CellEdit {
    pub prev_value: Value,
    pub new_value: Value,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CellState {
    Clean,
    Modified,
    InsertDraft,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RowState {
    Clean,
    Modified,
    PendingDelete,
    InsertDraft,
}

#[derive(Debug, Clone)]
pub enum StatementSource {
    Insert { draft_id: u64 },
    Update { row_key: RowKey },
    Delete { row_key: RowKey },
}

#[derive(Debug, Clone)]
pub enum UndoOp {
    CellEdit {
        row_key: RowKey,
        col: usize,
        prev_value: Value,
        new_value: Value,
        base: Value,
    },
    Insert {
        draft_id: u64,
        values: Vec<Value>,
    },
    Delete {
        row_key: RowKey,
        original_values: Vec<Value>,
    },
}

#[derive(Debug, Clone)]
pub enum TrackerEvent {
    ChangedRows(Vec<RowKey>),
    PendingCountChanged(usize),
    Cleared,
}

pub trait TrackerEventSink: std::fmt::Debug {
    fn emit(&self, event: TrackerEvent);
}

type MaterializedCellEdit = (usize, Value, Value);

pub type EditStatement = (String, Vec<Value>);
pub type MaterializedChanges = (Vec<EditStatement>, Vec<StatementSource>);

#[derive(Clone, Copy)]
struct EditTarget<'a> {
    driver_id: &'a str,
    schema: Option<&'a str>,
    table: &'a str,
    columns: &'a [ColumnInfo],
}

#[derive(Debug, Default)]
pub struct TabChangeTracker {
    inserts: Vec<DraftRow>,
    deletes: HashMap<RowKey, Vec<Value>>,
    updates: HashMap<(RowKey, usize), CellEdit>,
    undo: VecDeque<UndoOp>,
    redo: VecDeque<UndoOp>,
    next_draft_id: u64,
    subscribers: Vec<Box<dyn TrackerEventSink>>,
    error_row: Option<RowKey>,
    error_row_gen: u64,
}

impl TabChangeTracker {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn pending_count(&self) -> usize {
        self.inserts.len() + self.deletes.len() + self.updates.len()
    }

    pub fn has_pending(&self) -> bool {
        self.pending_count() > 0
    }

    pub fn subscribe(&mut self, sender: impl TrackerEventSink + 'static) {
        self.subscribers.push(Box::new(sender));
    }

    fn emit(&self, event: TrackerEvent) {
        for s in &self.subscribers {
            s.emit(event.clone());
        }
    }

    fn emit_changed(&self, keys: Vec<RowKey>) {
        self.emit(TrackerEvent::ChangedRows(keys));
        self.emit(TrackerEvent::PendingCountChanged(self.pending_count()));
    }

    fn push_undo(&mut self, op: UndoOp) {
        if self.undo.len() == UNDO_LIMIT {
            self.undo.pop_front();
        }
        self.undo.push_back(op);
        self.redo.clear();
    }

    pub fn track_cell_edit(&mut self, row_key: RowKey, col: usize, original: Value, new: Value) {
        let key = (row_key.clone(), col);
        let (base, shown_before) = self.updates.get(&key).map_or_else(
            || (original.clone(), original.clone()),
            |e| (e.prev_value.clone(), e.new_value.clone()),
        );
        if KeyValue::from(&base) == KeyValue::from(&new) {
            self.updates.remove(&key);
        } else {
            self.updates.insert(
                key,
                CellEdit {
                    prev_value: base.clone(),
                    new_value: new.clone(),
                },
            );
        }
        self.push_undo(UndoOp::CellEdit {
            row_key: row_key.clone(),
            col,
            prev_value: shown_before,
            new_value: new,
            base,
        });
        self.emit_changed(vec![row_key]);
    }

    pub fn track_insert(&mut self, default_values: Vec<Value>) -> RowKey {
        let draft_id = self.next_draft_id;
        self.next_draft_id += 1;
        self.inserts.push(DraftRow::new(draft_id, default_values.clone()));
        let key = RowKey::Draft(draft_id);
        self.push_undo(UndoOp::Insert {
            draft_id,
            values: default_values,
        });
        self.emit_changed(vec![key.clone()]);
        key
    }

    pub fn track_delete(&mut self, row_key: RowKey, original_values: Vec<Value>) {
        self.deletes.insert(row_key.clone(), original_values.clone());
        self.push_undo(UndoOp::Delete {
            row_key: row_key.clone(),
            original_values,
        });
        self.emit_changed(vec![row_key]);
    }

    pub fn discard_draft(&mut self, draft_id: u64) -> bool {
        let before = self.inserts.len();
        self.inserts.retain(|d| d.draft_id != draft_id);
        if self.inserts.len() == before {
            return false;
        }
        let key = RowKey::Draft(draft_id);
        self.updates
            .retain(|(k, _), _| !matches!(k, RowKey::Draft(id) if *id == draft_id));
        self.deletes
            .retain(|k, _| !matches!(k, RowKey::Draft(id) if *id == draft_id));
        self.undo.retain(|op| !undo_op_matches_draft(op, draft_id));
        self.redo.retain(|op| !undo_op_matches_draft(op, draft_id));
        self.emit_changed(vec![key]);
        true
    }

    pub fn track_draft_cell_edit(&mut self, draft_id: u64, col: usize, new: Value) -> bool {
        if let Some(draft) = self.inserts.iter_mut().find(|d| d.draft_id == draft_id)
            && col < draft.values.len()
        {
            let prev = draft.values[col].clone();
            draft.set(col, new.clone(), true);
            self.push_undo(UndoOp::CellEdit {
                row_key: RowKey::Draft(draft_id),
                col,
                base: prev.clone(),
                prev_value: prev,
                new_value: new,
            });
            self.emit_changed(vec![RowKey::Draft(draft_id)]);
            return true;
        }
        false
    }

    pub fn undo(&mut self) -> Option<UndoOp> {
        let op = self.undo.pop_back()?;
        let row_key = match &op {
            UndoOp::CellEdit {
                row_key,
                col,
                prev_value,
                base,
                ..
            } => {
                if let RowKey::Draft(draft_id) = row_key {
                    if let Some(draft) = self.inserts.iter_mut().find(|d| d.draft_id == *draft_id)
                        && *col < draft.values.len()
                    {
                        draft.set(*col, prev_value.clone(), !matches!(prev_value, Value::Null));
                    }
                } else {
                    self.set_pending_edit(row_key, *col, Some(base), prev_value);
                }
                row_key.clone()
            }
            UndoOp::Insert { draft_id, .. } => {
                self.inserts.retain(|d| d.draft_id != *draft_id);
                RowKey::Draft(*draft_id)
            }
            UndoOp::Delete { row_key, .. } => {
                self.deletes.remove(row_key);
                row_key.clone()
            }
        };
        self.redo.push_back(op.clone());
        self.emit_changed(vec![row_key]);
        Some(op)
    }

    fn set_pending_edit(&mut self, row_key: &RowKey, col: usize, untouched: Option<&Value>, target: &Value) {
        let key = (row_key.clone(), col);
        let stored = self
            .updates
            .get(&key)
            .map(|edit| edit.prev_value.clone())
            .or_else(|| untouched.cloned());
        match stored {
            Some(stored) if KeyValue::from(&stored) != KeyValue::from(target) => {
                self.updates.insert(
                    key,
                    CellEdit {
                        prev_value: stored,
                        new_value: target.clone(),
                    },
                );
            }
            _ => {
                self.updates.remove(&key);
            }
        }
    }

    pub fn redo(&mut self) -> Option<UndoOp> {
        let op = self.redo.pop_back()?;
        let row_key = match &op {
            UndoOp::CellEdit {
                row_key,
                col,
                new_value,
                base,
                ..
            } => {
                if let RowKey::Draft(draft_id) = row_key {
                    if let Some(draft) = self.inserts.iter_mut().find(|d| d.draft_id == *draft_id)
                        && *col < draft.values.len()
                    {
                        draft.set(*col, new_value.clone(), true);
                    }
                } else {
                    self.set_pending_edit(row_key, *col, Some(base), new_value);
                }
                row_key.clone()
            }
            UndoOp::Insert { draft_id, values } => {
                self.inserts.push(DraftRow::new(*draft_id, values.clone()));
                RowKey::Draft(*draft_id)
            }
            UndoOp::Delete {
                row_key,
                original_values,
            } => {
                self.deletes.insert(row_key.clone(), original_values.clone());
                row_key.clone()
            }
        };
        self.undo.push_back(op.clone());
        self.emit_changed(vec![row_key]);
        Some(op)
    }

    #[cfg(test)]
    pub fn can_undo(&self) -> bool {
        !self.undo.is_empty()
    }

    #[cfg(test)]
    pub fn can_redo(&self) -> bool {
        !self.redo.is_empty()
    }

    pub fn clear(&mut self) {
        self.inserts.clear();
        self.deletes.clear();
        self.updates.clear();
        self.undo.clear();
        self.redo.clear();
        self.emit(TrackerEvent::Cleared);
        self.emit(TrackerEvent::PendingCountChanged(0));
    }

    pub fn cell_state(&self, row_key: &RowKey, col: usize) -> CellState {
        if matches!(row_key, RowKey::Draft(_)) {
            return CellState::InsertDraft;
        }
        if self.updates.contains_key(&(row_key.clone(), col)) {
            return CellState::Modified;
        }
        CellState::Clean
    }

    pub fn row_state(&self, row_key: &RowKey) -> RowState {
        if matches!(row_key, RowKey::Draft(_)) {
            return RowState::InsertDraft;
        }
        if self.deletes.contains_key(row_key) {
            return RowState::PendingDelete;
        }
        let any_modified = self.updates.keys().any(|(k, _)| k == row_key);
        if any_modified {
            RowState::Modified
        } else {
            RowState::Clean
        }
    }

    pub fn drafts(&self) -> &[DraftRow] {
        &self.inserts
    }

    pub fn set_error_row(&mut self, key: RowKey) -> u64 {
        self.error_row_gen = self.error_row_gen.wrapping_add(1);
        self.error_row = Some(key);
        self.error_row_gen
    }

    pub fn clear_error_row_if_gen(&mut self, generation: u64) {
        if self.error_row_gen == generation {
            self.error_row = None;
        }
    }

    pub fn is_error_row_gen(&self, generation: u64) -> bool {
        self.error_row_gen == generation
    }

    pub fn is_error_row(&self, key: &RowKey) -> bool {
        self.error_row.as_ref() == Some(key)
    }

    pub fn current_cell_value<'a>(&'a self, row_key: &RowKey, col: usize, original: &'a Value) -> &'a Value {
        if let Some(edit) = self.updates.get(&(row_key.clone(), col)) {
            &edit.new_value
        } else {
            original
        }
    }

    pub fn materialize(
        &self,
        driver_id: &str,
        schema: Option<&str>,
        table: &str,
        columns: &[ColumnInfo],
    ) -> Result<MaterializedChanges, MaterializeError> {
        let target = EditTarget {
            driver_id,
            schema,
            table,
            columns,
        };
        let mut changes = (Vec::new(), Vec::new());
        self.materialize_inserts(target, &mut changes)?;
        self.materialize_updates(target, &mut changes)?;
        self.materialize_deletes(target, &mut changes)?;
        Ok(changes)
    }
    fn materialize_inserts(
        &self,
        target: EditTarget<'_>,
        changes: &mut MaterializedChanges,
    ) -> Result<(), MaterializeError> {
        let EditTarget {
            driver_id,
            schema,
            table,
            columns,
        } = target;
        let (out, sources) = changes;
        for draft in &self.inserts {
            out.push(build_insert_from_draft_touched(
                driver_id,
                schema,
                table,
                columns,
                &draft.values,
                &draft.touched,
            )?);
            sources.push(StatementSource::Insert {
                draft_id: draft.draft_id,
            });
        }
        Ok(())
    }

    fn materialize_updates(
        &self,
        target: EditTarget<'_>,
        changes: &mut MaterializedChanges,
    ) -> Result<(), MaterializeError> {
        let EditTarget {
            driver_id,
            schema,
            table,
            columns,
        } = target;
        let (out, sources) = changes;
        let mut per_row: HashMap<RowKey, Vec<MaterializedCellEdit>> = HashMap::new();
        for ((row_key, col), edit) in &self.updates {
            per_row
                .entry(row_key.clone())
                .or_default()
                .push((*col, edit.prev_value.clone(), edit.new_value.clone()));
        }
        let mut per_row: Vec<(RowKey, Vec<MaterializedCellEdit>)> = per_row.into_iter().collect();
        per_row.sort_by(|left, right| left.0.cmp(&right.0));
        for (row_key, mut edits) in per_row {
            edits.sort_by_key(|e| e.0);
            let RowKey::Persisted(pk_keyvalues) = &row_key else {
                continue;
            };
            let pk_values = readable_pk_values(pk_keyvalues)?;
            if driver_id == "mongodb" {
                out.push(build_mongodb_keyed_update(schema, table, columns, &edits, &pk_values)?);
            } else if matches!(driver_id, "postgres" | "mysql" | "mssql" | "sqlite") {
                out.push(build_optimistic_keyed_update(
                    driver_id, schema, table, columns, &edits, &pk_values,
                )?);
            } else {
                let new_values = edits
                    .iter()
                    .map(|(column, _, new_value)| (*column, new_value.clone()))
                    .collect::<Vec<_>>();
                out.push(build_keyed_update(
                    driver_id,
                    schema,
                    table,
                    columns,
                    &new_values,
                    &pk_values,
                )?);
            }
            sources.push(StatementSource::Update {
                row_key: row_key.clone(),
            });
        }
        Ok(())
    }

    fn materialize_deletes(
        &self,
        target: EditTarget<'_>,
        changes: &mut MaterializedChanges,
    ) -> Result<(), MaterializeError> {
        let EditTarget {
            driver_id,
            schema,
            table,
            columns,
        } = target;
        let (out, sources) = changes;
        let mut delete_entries: Vec<(&RowKey, &Vec<Value>)> = self.deletes.iter().collect();
        delete_entries.sort_by(|left, right| left.0.cmp(right.0));
        for (row_key, original_values) in delete_entries {
            let RowKey::Persisted(pk_keyvalues) = row_key else {
                continue;
            };
            let pk_values = readable_pk_values(pk_keyvalues)?;
            if driver_id == "mongodb" {
                out.push(build_mongodb_keyed_delete(
                    schema,
                    table,
                    columns,
                    original_values,
                    &pk_values,
                )?);
            } else {
                out.push(build_keyed_delete(driver_id, schema, table, columns, &pk_values)?);
            }
            sources.push(StatementSource::Delete {
                row_key: row_key.clone(),
            });
        }
        Ok(())
    }
}

fn readable_pk_values(pk_keyvalues: &[KeyValue]) -> Result<Vec<Value>, MaterializeError> {
    let pk_values: Vec<Value> = pk_keyvalues.iter().map(keyvalue_to_value).collect();
    if pk_values_are_unreadable(&pk_values) {
        return Err(MaterializeError::UnreadableRowKey);
    }
    Ok(pk_values)
}

fn undo_op_matches_draft(op: &UndoOp, draft_id: u64) -> bool {
    match op {
        UndoOp::Insert { draft_id: id, .. } => *id == draft_id,
        UndoOp::CellEdit {
            row_key: RowKey::Draft(id),
            ..
        } => *id == draft_id,
        UndoOp::Delete {
            row_key: RowKey::Draft(id),
            ..
        } => *id == draft_id,
        _ => false,
    }
}

#[derive(Debug, Default)]
pub struct ChangeTrackerRegistry {
    trackers: HashMap<Uuid, TabChangeTracker>,
}

impl ChangeTrackerRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn open_tab(&mut self, tab_id: Uuid) {
        self.trackers.entry(tab_id).or_default();
    }

    pub fn close_tab(&mut self, tab_id: Uuid) {
        self.trackers.remove(&tab_id);
    }

    #[cfg(test)]
    pub fn any_pending(&self) -> bool {
        self.trackers.values().any(|t| t.has_pending())
    }

    pub fn any_pending_in(&self, ids: impl IntoIterator<Item = Uuid>) -> bool {
        ids.into_iter()
            .any(|id| self.trackers.get(&id).is_some_and(|tracker| tracker.has_pending()))
    }

    pub fn pending_among(&self, ids: impl IntoIterator<Item = Uuid>) -> Vec<Uuid> {
        ids.into_iter()
            .filter(|id| self.trackers.get(id).is_some_and(|tracker| tracker.has_pending()))
            .collect()
    }

    pub fn pending_tabs_for(&self, tab_ids: &std::collections::HashSet<Uuid>) -> Vec<Uuid> {
        self.trackers
            .iter()
            .filter_map(|(id, tracker)| (tab_ids.contains(id) && tracker.has_pending()).then_some(*id))
            .collect()
    }
}

thread_local! {
    static REGISTRY: RefCell<ChangeTrackerRegistry> = RefCell::new(ChangeTrackerRegistry::new());
}

pub fn with_tab<F, R>(tab_id: Uuid, f: F) -> Option<R>
where
    F: FnOnce(&mut TabChangeTracker) -> R,
{
    REGISTRY.with(|reg| reg.borrow_mut().trackers.get_mut(&tab_id).map(f))
}

pub fn with_tab_ref<F, R>(tab_id: Uuid, f: F) -> Option<R>
where
    F: FnOnce(&TabChangeTracker) -> R,
{
    REGISTRY.with(|reg| reg.borrow().trackers.get(&tab_id).map(f))
}

pub fn open_tab(tab_id: Uuid) {
    REGISTRY.with(|reg| reg.borrow_mut().open_tab(tab_id));
}

pub fn close_tab(tab_id: Uuid) {
    REGISTRY.with(|reg| reg.borrow_mut().close_tab(tab_id));
}

pub fn any_pending_in(ids: impl IntoIterator<Item = Uuid>) -> bool {
    REGISTRY.with(|reg| reg.borrow().any_pending_in(ids))
}

pub fn pending_among(ids: impl IntoIterator<Item = Uuid>) -> Vec<Uuid> {
    REGISTRY.with(|reg| reg.borrow().pending_among(ids))
}

pub fn pending_tabs_for(tab_ids: &std::collections::HashSet<Uuid>) -> Vec<Uuid> {
    REGISTRY.with(|reg| reg.borrow().pending_tabs_for(tab_ids))
}

#[cfg(test)]
#[path = "change_tracker_materialize_tests.rs"]
mod materialize_tests;

#[cfg(test)]
mod tests;
