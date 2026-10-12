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

use tablepro_core::dml::BuildSqlError;
use tablepro_core::edit::CellInput;
use tablepro_core::meta::RowIdentity;
use tablepro_core::save::{ChangeOrigin, ChangeSet, RowInsert, RowUpdate};
use tablepro_core::{ColumnInfo, Value};

const UNDO_LIMIT: usize = 50;

/// Stable identity for a row across sort / filter / page navigation.
/// Persisted rows are keyed by their primary key tuple; draft rows
/// (not yet committed) are keyed by a monotonic local id assigned by
/// the tracker.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum RowKey {
    Persisted(Vec<KeyValue>),
    Draft(u64),
}

impl RowKey {
    /// Build a `Persisted` key from an existing row's PK column
    /// values, or `None` if the slice is empty (table has no PK,
    /// editing is blocked at the UI level).
    pub fn from_pk_values(pk_values: &[Value]) -> Option<Self> {
        if pk_values.is_empty() {
            return None;
        }
        Some(RowKey::Persisted(
            pk_values.iter().cloned().map(KeyValue::new).collect(),
        ))
    }
}

/// A key value that hashes and compares.
///
/// `ValueIdentity` wraps the value itself rather than a mirror of it:
/// a float compares by its bits, so NaN is its own key, and a
/// timestamp compares with its offset. Nothing is flattened to text on
/// the way in, so the value that goes back into the WHERE clause is
/// the one the row was read with.
pub type KeyValue = tablepro_core::value::ValueIdentity;

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

/// Which grid row a change came from, so a save that fails at one
/// statement can scroll to and flash the row the user edited.
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
        if prev_value == new {
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
                    self.updates.remove(&(row_key.clone(), *col));
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
                    self.updates.insert(
                        (row_key.clone(), *col),
                        CellEdit {
                            prev_value: prev_value.clone(),
                            new_value: new_value.clone(),
                        },
                    );
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

    /// What the user changed, as the change set a save is planned from.
    ///
    /// Rows are named by their primary key in column order, which is the
    /// identity `pk_identity` describes, so the keys bind straight back.
    /// A draft cell the user left empty asks for the server's default
    /// where the column has one, as does any column the server fills.
    pub fn change_set(&self, columns: &[ColumnInfo]) -> Result<TrackedChanges, BuildSqlError> {
        let mut tracked = TrackedChanges::default();
        for draft in &self.inserts {
            let cells = columns
                .iter()
                .zip(&draft.values)
                .map(|(column, value)| draft_cell(column, value))
                .collect();
            tracked.changes.inserts.push(RowInsert { cells });
            tracked.inserts.push(StatementSource::Insert {
                draft_id: draft.draft_id,
            });
        }

        // One UPDATE per row, setting only the cells that moved, so a
        // concurrent edit to a column this user never touched survives.
        let mut per_row: HashMap<RowKey, Vec<(usize, Value)>> = HashMap::new();
        for ((row_key, col), edit) in &self.updates {
            per_row
                .entry(row_key.clone())
                .or_default()
                .push((*col, edit.new_value.clone()));
        }
        for (row_key, mut assignments) in per_row {
            let RowKey::Persisted(key) = &row_key else {
                continue;
            };
            require_key(columns)?;
            assignments.sort_by_key(|(col, _)| *col);
            tracked.changes.updates.push(RowUpdate {
                key: key.iter().map(|part| part.value().clone()).collect(),
                assignments,
            });
            tracked.updates.push(StatementSource::Update { row_key });
        }

        for row_key in self.deletes.keys() {
            let RowKey::Persisted(key) = row_key else {
                continue;
            };
            require_key(columns)?;
            tracked
                .changes
                .deletes
                .push(key.iter().map(|part| part.value().clone()).collect());
            tracked.deletes.push(StatementSource::Delete {
                row_key: row_key.clone(),
            });
        }
        Ok(tracked)
    }
}

/// The tracker's changes in the form a save plans from, with the row
/// each one came from.
#[derive(Debug, Clone, Default)]
pub struct TrackedChanges {
    pub changes: ChangeSet,
    inserts: Vec<StatementSource>,
    updates: Vec<StatementSource>,
    deletes: Vec<StatementSource>,
}

impl TrackedChanges {
    /// The grid row behind one step of the planned save.
    pub fn source(&self, origin: ChangeOrigin) -> Option<StatementSource> {
        match origin {
            ChangeOrigin::Insert(index) => self.inserts.get(index),
            ChangeOrigin::Update(index) => self.updates.get(index),
            ChangeOrigin::Delete(index) => self.deletes.get(index),
        }
        .cloned()
    }
}

/// The identity the tracker's row keys are written in: the primary key
/// columns, in the order the table lists them.
pub fn pk_identity(columns: &[ColumnInfo]) -> RowIdentity {
    RowIdentity::UniqueKey {
        columns: columns
            .iter()
            .filter(|column| column.primary_key)
            .map(|column| column.name.clone())
            .collect(),
    }
}

fn require_key(columns: &[ColumnInfo]) -> Result<(), BuildSqlError> {
    match columns.iter().any(|column| column.primary_key) {
        true => Ok(()),
        false => Err(BuildSqlError::NoRowIdentity),
    }
}

/// A NULL the user left in a column with a default means "use the
/// default" (CURRENT_TIMESTAMP, gen_random_uuid()), not an explicit
/// NULL over it.
fn draft_cell(column: &ColumnInfo, value: &Value) -> CellInput {
    if column.is_auto_increment || column.is_generated {
        return CellInput::Default;
    }
    if matches!(value, Value::Null) && !column.default.is_none() {
        return CellInput::Default;
    }
    CellInput::Value(value.clone())
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

    pub fn any_pending(&self) -> bool {
        self.trackers.values().any(|t| t.has_pending())
    }

    pub fn pending_tabs(&self) -> Vec<Uuid> {
        self.trackers
            .iter()
            .filter(|(_, t)| t.has_pending())
            .map(|(id, _)| *id)
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

/// True if any open tab has pending changes — used by the app-level
/// quit guard to decide whether to show the "Unsaved changes" dialog.
pub fn any_pending_globally() -> bool {
    REGISTRY.with(|reg| reg.borrow().any_pending())
}

/// Tabs with pending changes — ordered arbitrary (HashMap iteration).
pub fn pending_tabs() -> Vec<Uuid> {
    REGISTRY.with(|reg| reg.borrow().pending_tabs())
}

#[cfg(test)]
mod tests {
    /// A column carrying the server's spelling and the kind it means,
    /// which is what these tests exercise.
    #[expect(
        clippy::disallowed_methods,
        reason = "a test fixture stands in for the catalogue, which is where this text comes from in production"
    )]
    fn test_column(name: &str, type_name: &str) -> tablepro_core::ColumnInfo {
        let kind = tablepro_core::column::classify_type_name(type_name);
        tablepro_core::ColumnInfo {
            name: name.to_owned(),
            column_type: tablepro_core::column::ColumnType {
                name: type_name.to_owned(),
                dynamic_storage: tablepro_core::column::has_dynamic_storage(&kind),
                kind,
                catalog: Some(tablepro_core::column::CatalogType {
                    declaration: tablepro_core::column::SqlTypeExpr::from_catalog_text(type_name),
                    cast_target: tablepro_core::column::SqlTypeExpr::from_catalog_text(type_name),
                }),
                read_form: tablepro_core::column::ReadForm::Native,
            },
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            default: tablepro_core::column::ColumnDefault::None,
            comment: None,
        }
    }

    use super::*;
    use tablepro_core::ColumnInfo;

    fn pk_col(name: &str) -> ColumnInfo {
        ColumnInfo {
            name: name.into(),
            column_type: test_column("", "integer").column_type,
            nullable: false,
            primary_key: true,
            is_auto_increment: true,
            default: tablepro_core::column::ColumnDefault::None,
            is_generated: false,
            comment: None,
        }
    }

    fn data_col(name: &str) -> ColumnInfo {
        ColumnInfo {
            name: name.into(),
            column_type: test_column("", "text").column_type,
            nullable: false,
            primary_key: false,
            is_auto_increment: false,
            default: tablepro_core::column::ColumnDefault::None,
            is_generated: false,
            comment: None,
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

    fn postgres() -> drivers_postgres::PgDialect {
        drivers_postgres::PgDialect::new(&tablepro_core::ServerInfo::new("PostgreSQL", "18.0", 18, 0, 0))
    }

    fn plan(tracker: &TabChangeTracker, columns: &[ColumnInfo]) -> (TrackedChanges, tablepro_core::save::SavePlan) {
        let tracked = tracker.change_set(columns).unwrap();
        let table = tablepro_core::meta::TableRef::unqualified("t");
        let plan =
            tablepro_core::save::plan_save(&postgres(), &table, columns, &pk_identity(columns), &tracked.changes)
                .unwrap();
        (tracked, plan)
    }

    #[test]
    fn change_set_orders_inserts_then_updates_then_deletes() {
        let mut t = TabChangeTracker::new();
        let columns = vec![pk_col("id"), data_col("name")];
        let updated = rk(&[Value::Int(5)]);
        t.track_cell_edit(updated.clone(), 1, Value::Text("old".into()), Value::Text("new".into()));
        t.track_insert(vec![Value::Null, Value::Text("draft".into())]);
        t.track_delete(rk(&[Value::Int(9)]), vec![Value::Int(9), Value::Text("doomed".into())]);

        let (tracked, plan) = plan(&t, &columns);

        let sql: Vec<&str> = plan.batch.steps.iter().map(|step| step.statement.sql()).collect();
        assert_eq!(sql.len(), 3);
        assert!(sql[0].starts_with("INSERT"), "{sql:?}");
        assert!(sql[1].starts_with("UPDATE"), "{sql:?}");
        assert!(sql[2].starts_with("DELETE"), "{sql:?}");
        let sources: Vec<_> = (0..3)
            .map(|step| plan.origin(step).and_then(|o| tracked.source(o)))
            .collect();
        assert!(matches!(sources[0], Some(StatementSource::Insert { .. })));
        assert!(matches!(&sources[1], Some(StatementSource::Update { row_key }) if *row_key == updated));
        assert!(matches!(sources[2], Some(StatementSource::Delete { .. })));
    }

    #[test]
    fn a_failing_step_maps_back_to_the_row_that_made_it() {
        let mut t = TabChangeTracker::new();
        let columns = vec![pk_col("id"), data_col("name")];
        let doomed = rk(&[Value::Int(9)]);
        t.track_insert(vec![Value::Null, Value::Text("draft".into())]);
        t.track_delete(doomed.clone(), vec![Value::Int(9), Value::Text("doomed".into())]);

        let (tracked, plan) = plan(&t, &columns);

        let failing = plan.origin(1).and_then(|origin| tracked.source(origin));
        assert!(matches!(failing, Some(StatementSource::Delete { row_key }) if row_key == doomed));
        assert!(plan.origin(2).is_none());
    }

    #[test]
    fn an_update_sets_only_the_moved_cell_and_keys_on_the_whole_primary_key() {
        let mut t = TabChangeTracker::new();
        let columns = vec![pk_col("a"), pk_col("b"), data_col("name")];
        let key = RowKey::from_pk_values(&[Value::Int(1), Value::Int(2)]).unwrap();
        t.track_cell_edit(key, 2, Value::Text("old".into()), Value::Text("new".into()));

        let tracked = t.change_set(&columns).unwrap();

        assert_eq!(tracked.changes.updates.len(), 1);
        assert_eq!(tracked.changes.updates[0].key, vec![Value::Int(1), Value::Int(2)]);
        assert_eq!(
            tracked.changes.updates[0].assignments,
            vec![(2, Value::Text("new".into()))]
        );
        assert_eq!(
            pk_identity(&columns),
            RowIdentity::UniqueKey {
                columns: vec!["a".to_owned(), "b".to_owned()]
            }
        );
    }

    #[test]
    #[expect(
        clippy::disallowed_methods,
        reason = "a test fixture stands in for the catalogue, which is where a default expression comes from"
    )]
    fn a_draft_leaves_server_filled_columns_to_the_server() {
        let mut t = TabChangeTracker::new();
        let mut stamped = data_col("created_at");
        stamped.default = tablepro_core::column::ColumnDefault::Expression(
            tablepro_core::column::SqlExpression::from_catalog_text("now()"),
        );
        let columns = vec![pk_col("id"), data_col("name"), stamped];
        t.track_insert(vec![Value::Null, Value::Text("draft".into()), Value::Null]);

        let tracked = t.change_set(&columns).unwrap();

        assert_eq!(
            tracked.changes.inserts[0].cells,
            vec![
                CellInput::Default,
                CellInput::Value(Value::Text("draft".into())),
                CellInput::Default
            ]
        );
    }

    #[test]
    fn a_table_without_a_primary_key_cannot_save_an_update() {
        let mut t = TabChangeTracker::new();
        let columns = vec![data_col("name")];
        t.track_cell_edit(
            rk(&[Value::Int(1)]),
            0,
            Value::Text("a".into()),
            Value::Text("b".into()),
        );

        assert!(matches!(t.change_set(&columns), Err(BuildSqlError::NoRowIdentity)));
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
        assert_eq!(reg.pending_tabs(), vec![id]);
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
}
