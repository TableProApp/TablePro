//! Per-tab pending-changeset tracker for inline spreadsheet edits.
//!
//! The tracker is the single source of truth for "what has the user
//! changed but not yet saved" in a Browse tab. It owns three buckets:
//!
//! - `inserts`: draft rows the user added (not yet persisted; PK
//!   will be assigned by the database on Save for auto-increment
//!   columns).
//! - `deletes`: row keys marked for deletion. Original cell values
//!   are kept so the row can re-render with strikethrough styling.
//! - `updates`: per-cell modifications keyed by `(RowKey, col)`.
//!
//! `RowKey` is PK-based and stable across sort, filter, and page
//! navigation. This is the entire reason the tracker is owned by a
//! services-layer registry rather than the GTK widget tree: a
//! position-keyed identity dies on every reorder, while PK-keyed
//! identity survives.
//!
//! Threading: the tracker is **single-thread, main-thread only**.
//! All UI events run on the GTK main thread (relm4 contract), so
//! interior mutability uses `RefCell` rather than `Mutex`. The
//! registry uses `thread_local!` to avoid lock overhead in the hot
//! `connect_bind` path.
//!
//! Tests should construct a fresh `ChangeTrackerRegistry::new()` to
//! avoid contaminating each other through the thread-local global.

use std::cell::RefCell;
use std::collections::{HashMap, VecDeque};

use uuid::Uuid;

use tablepro_core::{
    ColumnInfo, Value,
    sql_dialect::{
        build_insert_from_draft, build_keyed_delete, build_keyed_update, build_mongodb_keyed_delete,
        build_mongodb_keyed_update, build_optimistic_keyed_update,
    },
};

#[path = "change_tracker_row_identity.rs"]
mod row_identity;

use row_identity::keyvalue_to_value;
pub use row_identity::{KeyValue, MaterializeError, RowKey, pk_values_are_unreadable};

const UNDO_LIMIT: usize = 50;

/// A draft row collected by the tracker. `values` is the full column
/// vector (length = `columns.len()` at the time of creation). Empty
/// cells start as `Value::Null`.
#[derive(Debug, Clone)]
pub struct DraftRow {
    pub draft_id: u64,
    pub values: Vec<Value>,
}

/// One pending cell modification. `prev_value` is what the cell held
/// before the user touched it (used for undo + visual revert).
#[derive(Debug, Clone)]
pub struct CellEdit {
    pub prev_value: Value,
    pub new_value: Value,
}

/// What the grid factory asks the tracker per cell at bind time.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CellState {
    Clean,
    Modified,
    InsertDraft,
}

/// What the grid factory asks the tracker per row at bind time.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RowState {
    Clean,
    Modified,
    PendingDelete,
    InsertDraft,
}

/// Identifies which logical row produced a given materialised SQL
/// statement. Returned alongside the statements from `materialize` so
/// a downstream `DriverError::Transaction { statement_index }` can be
/// mapped back to the offending grid row for scroll-and-select.
#[derive(Debug, Clone)]
pub enum StatementSource {
    Insert { draft_id: u64 },
    Update { row_key: RowKey },
    Delete { row_key: RowKey },
}

/// Reversible action recorded for the per-tab undo stack.
#[derive(Debug, Clone)]
pub enum UndoOp {
    /// Cell was edited. `prev_value` is what it held before this op.
    CellEdit {
        row_key: RowKey,
        col: usize,
        prev_value: Value,
        new_value: Value,
    },
    /// Draft row was added. Undoing removes it.
    Insert { draft_id: u64, values: Vec<Value> },
    /// Row was marked for delete. Undoing unmarks.
    Delete {
        row_key: RowKey,
        original_values: Vec<Value>,
    },
}

/// Event emitted to subscribers when the tracker mutates. Subscribers
/// (BrowseTab) use the row keys to call `store.items_changed(...)` for
/// affected rows so `connect_bind` re-fires with updated CSS classes.
#[derive(Debug, Clone)]
pub enum TrackerEvent {
    ChangedRows(Vec<RowKey>),
    PendingCountChanged(usize),
    Cleared,
}

/// Per-tab tracker. Created on `BrowseTab::init`, dropped when the
/// tab is closed (via `ChangeTrackerRegistry::close_tab`).
#[derive(Debug, Default)]
pub struct TabChangeTracker {
    inserts: Vec<DraftRow>,
    deletes: HashMap<RowKey, Vec<Value>>,
    updates: HashMap<(RowKey, usize), CellEdit>,
    undo: VecDeque<UndoOp>,
    redo: VecDeque<UndoOp>,
    next_draft_id: u64,
    subscribers: Vec<relm4::Sender<TrackerEvent>>,
    /// Row that produced a failing statement during the most recent
    /// save. The grid bind callback consults this to apply the
    /// `tp-row-leftmost-error-flash` class. Cleared by a timeout on
    /// the BrowseTab side ~1.8s after the flash starts.
    error_row: Option<RowKey>,
    /// Generation counter incremented every time `set_error_row`
    /// records a new failing row. The clear-timeout closure captures
    /// the gen at scheduling and only clears `error_row` if the
    /// counter still matches — protects against a first-flash timeout
    /// blanking out a second flash that started inside its 1.8s window.
    error_row_gen: u64,
}

impl TabChangeTracker {
    #[cfg(test)]
    pub fn new() -> Self {
        Self::default()
    }

    pub fn pending_count(&self) -> usize {
        self.inserts.len() + self.deletes.len() + self.updates.len()
    }

    pub fn has_pending(&self) -> bool {
        self.pending_count() > 0
    }

    pub fn subscribe(&mut self, sender: relm4::Sender<TrackerEvent>) {
        self.subscribers.push(sender);
    }

    fn emit(&self, event: TrackerEvent) {
        for s in &self.subscribers {
            let _ = s.send(event.clone());
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

    /// Track a cell edit. If the cell was already modified, this
    /// updates the new value but keeps the original `prev_value` (so
    /// undoing restores the very-first untouched value, not the last
    /// intermediate state).
    pub fn track_cell_edit(&mut self, row_key: RowKey, col: usize, original: Value, new: Value) {
        let key = (row_key.clone(), col);
        let prev_value = self
            .updates
            .get(&key)
            .map(|e| e.prev_value.clone())
            .unwrap_or(original.clone());
        if KeyValue::from(&prev_value) == KeyValue::from(&new) {
            // User reverted to the original value — drop the edit.
            self.updates.remove(&key);
        } else {
            self.updates.insert(
                key,
                CellEdit {
                    prev_value: prev_value.clone(),
                    new_value: new.clone(),
                },
            );
        }
        self.push_undo(UndoOp::CellEdit {
            row_key: row_key.clone(),
            col,
            prev_value: original,
            new_value: new,
        });
        self.emit_changed(vec![row_key]);
    }

    /// Append a draft row. Returns the assigned RowKey for UI to use
    /// when prepending the GObject to the grid's ListStore.
    pub fn track_insert(&mut self, default_values: Vec<Value>) -> RowKey {
        let draft_id = self.next_draft_id;
        self.next_draft_id += 1;
        self.inserts.push(DraftRow {
            draft_id,
            values: default_values.clone(),
        });
        let key = RowKey::Draft(draft_id);
        self.push_undo(UndoOp::Insert {
            draft_id,
            values: default_values,
        });
        self.emit_changed(vec![key.clone()]);
        key
    }

    /// Mark a persisted row for deletion. `original_values` is the
    /// full row at the time of mark — needed both for the strikethrough
    /// render and the undo path.
    pub fn track_delete(&mut self, row_key: RowKey, original_values: Vec<Value>) {
        self.deletes.insert(row_key.clone(), original_values.clone());
        self.push_undo(UndoOp::Delete {
            row_key: row_key.clone(),
            original_values,
        });
        self.emit_changed(vec![row_key]);
    }

    /// Drop a draft row entirely. Mirrors what `undo` does for an
    /// `UndoOp::Insert`, but reachable from the bulk-delete path
    /// (Ctrl+A → Delete) so a mixed selection of drafts + persisted
    /// rows behaves uniformly: persisted rows get strikethrough
    /// pending-delete, drafts disappear.
    ///
    /// Returns `true` when a draft with `draft_id` was found and
    /// removed; `false` otherwise (already discarded, or never
    /// existed). Also clears any draft-cell edits and undo / redo
    /// entries scoped to this draft so a subsequent Ctrl+Z doesn't
    /// resurrect the draft into a half-edited state.
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

    /// Update a draft row's cell value (only valid for `RowKey::Draft`).
    pub fn track_draft_cell_edit(&mut self, draft_id: u64, col: usize, new: Value) -> bool {
        if let Some(draft) = self.inserts.iter_mut().find(|d| d.draft_id == draft_id)
            && col < draft.values.len()
        {
            let prev = draft.values[col].clone();
            draft.values[col] = new.clone();
            self.push_undo(UndoOp::CellEdit {
                row_key: RowKey::Draft(draft_id),
                col,
                prev_value: prev,
                new_value: new,
            });
            self.emit_changed(vec![RowKey::Draft(draft_id)]);
            return true;
        }
        false
    }

    /// Pop one entry off the undo stack, revert the tracker's
    /// internal state, push it onto the redo stack, and return the
    /// `UndoOp` so the UI layer knows which visual change to apply
    /// (revert a RowObject's cell, remove a draft from the
    /// ListStore, or just re-bind a row to drop its strikethrough).
    ///
    /// Returning the full op (instead of only the `RowKey`) is what
    /// lets the visual revert happen: the tracker holds the
    /// `prev_value` needed to restore the RowObject's cell, and the
    /// caller would otherwise have to peek `self.redo.back()` after
    /// the call — fragile and bypasses the encapsulation.
    pub fn undo(&mut self) -> Option<UndoOp> {
        let op = self.undo.pop_back()?;
        let row_key = match &op {
            UndoOp::CellEdit {
                row_key,
                col,
                prev_value,
                ..
            } => {
                if let RowKey::Draft(draft_id) = row_key {
                    if let Some(draft) = self.inserts.iter_mut().find(|d| d.draft_id == *draft_id)
                        && *col < draft.values.len()
                    {
                        draft.values[*col] = prev_value.clone();
                    }
                } else {
                    self.set_pending_edit(row_key, *col, None, prev_value);
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

    /// Pop one entry off the redo stack, re-apply the tracker's
    /// internal state, push back onto the undo stack, and return
    /// the `UndoOp` so the UI layer knows which visual change to
    /// re-apply (set a RowObject's cell to `new_value`, re-add a
    /// draft to the ListStore, or re-bind a row's strikethrough).
    pub fn redo(&mut self) -> Option<UndoOp> {
        let op = self.redo.pop_back()?;
        let row_key = match &op {
            UndoOp::CellEdit {
                row_key,
                col,
                prev_value,
                new_value,
            } => {
                if let RowKey::Draft(draft_id) = row_key {
                    if let Some(draft) = self.inserts.iter_mut().find(|d| d.draft_id == *draft_id)
                        && *col < draft.values.len()
                    {
                        draft.values[*col] = new_value.clone();
                    }
                } else {
                    self.set_pending_edit(row_key, *col, Some(prev_value), new_value);
                }
                row_key.clone()
            }
            UndoOp::Insert { draft_id, values } => {
                self.inserts.push(DraftRow {
                    draft_id: *draft_id,
                    values: values.clone(),
                });
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

    /// Drop all pending changes, undo, redo. Called by Discard and by
    /// Save (after successful commit).
    pub fn clear(&mut self) {
        self.inserts.clear();
        self.deletes.clear();
        self.updates.clear();
        self.undo.clear();
        self.redo.clear();
        self.emit(TrackerEvent::Cleared);
        self.emit(TrackerEvent::PendingCountChanged(0));
    }

    /// State for a given (row, col) cell. Used by grid `connect_bind`.
    pub fn cell_state(&self, row_key: &RowKey, col: usize) -> CellState {
        if matches!(row_key, RowKey::Draft(_)) {
            return CellState::InsertDraft;
        }
        if self.updates.contains_key(&(row_key.clone(), col)) {
            return CellState::Modified;
        }
        CellState::Clean
    }

    /// Coarse row state. PendingDelete wins over Modified.
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

    /// Mark a row as the "currently failing" row for the flash animation.
    /// Returns the generation counter the caller should pass to
    /// `clear_error_row_if_gen` after the flash timeout, so a new flash
    /// during the timeout window doesn't get blanked out by the older
    /// timer firing.
    pub fn set_error_row(&mut self, key: RowKey) -> u64 {
        self.error_row_gen = self.error_row_gen.wrapping_add(1);
        self.error_row = Some(key);
        self.error_row_gen
    }

    /// Clear the error row only if the generation hasn't been bumped by
    /// a newer `set_error_row` call. Used by the flash timeout to avoid
    /// clearing a fresh flash that started after this timer was scheduled.
    pub fn clear_error_row_if_gen(&mut self, generation: u64) {
        if self.error_row_gen == generation {
            self.error_row = None;
        }
    }

    /// True when the given generation matches the most recent
    /// `set_error_row`. Used by the flash-clear timeout to detect
    /// whether its scheduled clear is still authoritative.
    pub fn is_error_row_gen(&self, generation: u64) -> bool {
        self.error_row_gen == generation
    }

    /// True when `key` matches the row currently flagged as the error
    /// row. Used by the grid bind callback to apply the flash class.
    pub fn is_error_row(&self, key: &RowKey) -> bool {
        self.error_row.as_ref() == Some(key)
    }

    /// Display value for a cell — pending edit if present, else
    /// `original`. Used by the grid bind to render the user's pending
    /// edit instead of the stale DB value.
    pub fn current_cell_value<'a>(&'a self, row_key: &RowKey, col: usize, original: &'a Value) -> &'a Value {
        if let Some(edit) = self.updates.get(&(row_key.clone(), col)) {
            &edit.new_value
        } else {
            original
        }
    }

    /// Build the ordered statement list for atomic commit:
    ///
    /// 1. INSERTs (so server defaults / auto-increment fire first;
    ///    subsequent FK-aware updates can reference fresh keys).
    /// 2. UPDATEs grouped per row into a single full-row UPDATE.
    /// 3. DELETEs.
    ///
    /// Each statement is a (SQL, params) pair fed straight into
    /// `Connection::execute_in_transaction`. The parallel `sources`
    /// vector lets the caller map a `DriverError::Transaction
    /// { statement_index, .. }` back to the grid row that produced
    /// the failing statement.
    #[allow(clippy::type_complexity)]
    pub fn materialize(
        &self,
        driver_id: &str,
        schema: Option<&str>,
        table: &str,
        columns: &[ColumnInfo],
    ) -> Result<(Vec<(String, Vec<Value>)>, Vec<StatementSource>), MaterializeError> {
        let mut out: Vec<(String, Vec<Value>)> = Vec::new();
        let mut sources: Vec<StatementSource> = Vec::new();
        for draft in &self.inserts {
            out.push(build_insert_from_draft(
                driver_id,
                schema,
                table,
                columns,
                &draft.values,
            )?);
            sources.push(StatementSource::Insert {
                draft_id: draft.draft_id,
            });
        }
        // Group updates by row_key so each row becomes ONE UPDATE
        // (a multi-cell edit on one row is one statement, not N).
        let mut per_row: HashMap<RowKey, Vec<(usize, Value, Value)>> = HashMap::new();
        for ((row_key, col), edit) in &self.updates {
            per_row
                .entry(row_key.clone())
                .or_default()
                .push((*col, edit.prev_value.clone(), edit.new_value.clone()));
        }
        // `per_row` is a HashMap, so iterating it emits statements in an
        // order that changes between processes. Two windows saving
        // overlapping rows could then take row locks in opposite orders
        // and deadlock against each other, and a partial failure could
        // report a different row each run. Sort by primary key so the
        // batch is reproducible and every client locks in one order.
        let mut per_row: Vec<(RowKey, Vec<(usize, Value, Value)>)> = per_row.into_iter().collect();
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
        Ok((out, sources))
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

/// Per-tab registry of trackers. Singleton via `thread_local!` because
/// all UI work runs on the GTK main thread.
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

/// Run a closure with mutable access to a specific tab's tracker.
/// Returns `None` if the tab has not been registered yet (e.g.,
/// during early init).
pub fn with_tab<F, R>(tab_id: Uuid, f: F) -> Option<R>
where
    F: FnOnce(&mut TabChangeTracker) -> R,
{
    REGISTRY.with(|reg| reg.borrow_mut().trackers.get_mut(&tab_id).map(f))
}

/// Run a closure with read-only access to a specific tab's tracker.
pub fn with_tab_ref<F, R>(tab_id: Uuid, f: F) -> Option<R>
where
    F: FnOnce(&TabChangeTracker) -> R,
{
    REGISTRY.with(|reg| reg.borrow().trackers.get(&tab_id).map(f))
}

/// Open a tracker for a tab. Idempotent.
pub fn open_tab(tab_id: Uuid) {
    REGISTRY.with(|reg| reg.borrow_mut().open_tab(tab_id));
}

/// Drop a tab's tracker. Called when the BrowseTab is closed.
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
#[cfg(test)]
#[path = "change_tracker_materialize_tests.rs"]
mod materialize_tests;

#[cfg(test)]
mod tests {
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
        // User edits again, this time back to "a"
        t.track_cell_edit(key.clone(), 1, Value::Text("a".into()), Value::Text("a".into()));
        assert_eq!(t.cell_state(&key, 1), CellState::Clean);
        // pending_count drops; undo stack still has 2 ops
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
        // Composite PK where one component is NULL — the WHERE must use
        // `IS NULL` for that component or the UPDATE silently matches
        // zero rows.
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
        // Edit the draft so undo stack has a CellEdit on top of Insert.
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
        // The remaining draft is still undoable on its own.
        assert!(t.can_undo());
    }

    #[test]
    fn bulk_delete_via_track_delete_is_per_row_undoable() {
        // Multi-row delete sequence (what the UI does on Ctrl+A → Delete
        // for persisted rows): track_delete N times. Each push is its
        // own undoable op so Ctrl+Z restores rows one at a time —
        // matches the per-op undo contract elsewhere.
        let mut t = TabChangeTracker::new();
        let k1 = rk(&[Value::Int(1)]);
        let k2 = rk(&[Value::Int(2)]);
        let k3 = rk(&[Value::Int(3)]);
        t.track_delete(k1.clone(), vec![Value::Int(1)]);
        t.track_delete(k2.clone(), vec![Value::Int(2)]);
        t.track_delete(k3.clone(), vec![Value::Int(3)]);
        assert_eq!(t.pending_count(), 3);

        // First undo restores the most-recent delete (k3).
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
}
