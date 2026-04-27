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

// Many items are public for the upcoming UI integration but unused
// at this point of the rollout — silence dead-code warnings module-
// wide rather than annotating each item.
#![allow(dead_code)]

use std::cell::RefCell;
use std::collections::{HashMap, VecDeque};

use uuid::Uuid;

use tablepro_core::{
    ColumnInfo, Value,
    sql_dialect::{BuildSqlError, build_full_row_update, build_insert_from_draft, placeholder_for, quote_ident},
};

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
        Some(RowKey::Persisted(pk_values.iter().map(KeyValue::from).collect()))
    }
}

/// Hash- and Eq-friendly mirror of `Value`. Floats are stored as
/// IEEE-754 bits (so NaN equals NaN for identity purposes — pathological
/// PK case but defined behaviour). `Decimal` and `Json` are stored as
/// their canonical string forms because neither type derives `Hash`.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum KeyValue {
    Null,
    Bool(bool),
    Int(i64),
    FloatBits(u64),
    Text(String),
    Bytes(Vec<u8>),
    Date(chrono::NaiveDate),
    Time(chrono::NaiveTime),
    DateTime(chrono::NaiveDateTime),
    TimestampTz(chrono::DateTime<chrono::Utc>),
    Decimal(String),
    Uuid(uuid::Uuid),
    Json(String),
}

impl From<&Value> for KeyValue {
    fn from(v: &Value) -> Self {
        match v {
            Value::Null => KeyValue::Null,
            Value::Bool(b) => KeyValue::Bool(*b),
            Value::Int(i) => KeyValue::Int(*i),
            Value::Float(f) => KeyValue::FloatBits(f.to_bits()),
            Value::Text(s) => KeyValue::Text(s.clone()),
            Value::Bytes(b) => KeyValue::Bytes(b.clone()),
            Value::Date(d) => KeyValue::Date(*d),
            Value::Time(t) => KeyValue::Time(*t),
            Value::DateTime(dt) => KeyValue::DateTime(*dt),
            Value::TimestampTz(ts) => KeyValue::TimestampTz(*ts),
            Value::Decimal(d) => KeyValue::Decimal(d.to_string()),
            Value::Uuid(u) => KeyValue::Uuid(*u),
            Value::Json(j) => KeyValue::Json(j.to_string()),
        }
    }
}

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

    pub fn undo(&mut self) -> Option<RowKey> {
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
        self.redo.push_back(op);
        self.emit_changed(vec![row_key.clone()]);
        Some(row_key)
    }

    pub fn redo(&mut self) -> Option<RowKey> {
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
        self.undo.push_back(op);
        self.emit_changed(vec![row_key.clone()]);
        Some(row_key)
    }

    pub fn can_undo(&self) -> bool {
        !self.undo.is_empty()
    }

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
    ) -> Result<(Vec<(String, Vec<Value>)>, Vec<StatementSource>), BuildSqlError> {
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
        for (row_key, mut edits) in per_row {
            edits.sort_by_key(|e| e.0);
            // Build a synthetic original_row + new_row pair so we can
            // reuse `build_full_row_update`. For non-edited columns we
            // pass `Value::Null` for the new value but the UPDATE only
            // touches non-PK columns and we want it to leave un-edited
            // columns alone — so pass `original_row` for them too.
            // Easier: build the SQL directly here.
            let RowKey::Persisted(pk_keyvalues) = &row_key else {
                continue; // Drafts don't go through UPDATE
            };
            let pk_indices: Vec<usize> = columns
                .iter()
                .enumerate()
                .filter(|(_, c)| c.primary_key)
                .map(|(i, _)| i)
                .collect();
            if pk_indices.is_empty() {
                return Err(BuildSqlError::NoPrimaryKey);
            }
            // Reconstruct PK values (KeyValue → Value is lossy but
            // acceptable: PK values were captured from the original
            // row at edit time and are still equality-correct).
            let pk_values: Vec<Value> = pk_keyvalues.iter().map(keyvalue_to_value).collect();
            let mut params: Vec<Value> = Vec::new();
            let mut placeholder_idx = 0;
            let set_clauses: Vec<String> = edits
                .iter()
                .map(|(col_idx, _, new_val)| {
                    let s = format!(
                        "{} = {}",
                        quote_ident(driver_id, &columns[*col_idx].name),
                        placeholder_for(driver_id, placeholder_idx)
                    );
                    placeholder_idx += 1;
                    params.push(new_val.clone());
                    s
                })
                .collect();
            // NULL-safe WHERE: `col = NULL` is never true under SQL
            // three-valued logic. A nullable PK component holding NULL
            // must use `IS NULL` or the UPDATE silently matches zero
            // rows and the user thinks their save worked.
            let where_clauses: Vec<String> = pk_indices
                .iter()
                .enumerate()
                .map(|(local_idx, &col_idx)| {
                    let ident = quote_ident(driver_id, &columns[col_idx].name);
                    if matches!(pk_values[local_idx], Value::Null) {
                        format!("{ident} IS NULL")
                    } else {
                        let s = format!("{ident} = {}", placeholder_for(driver_id, placeholder_idx));
                        placeholder_idx += 1;
                        params.push(pk_values[local_idx].clone());
                        s
                    }
                })
                .collect();
            let qualified = match schema {
                Some(s) => format!("{}.{}", quote_ident(driver_id, s), quote_ident(driver_id, table)),
                None => quote_ident(driver_id, table),
            };
            let sql = format!(
                "UPDATE {} SET {} WHERE {}",
                qualified,
                set_clauses.join(", "),
                where_clauses.join(" AND ")
            );
            // Suppress unused-variable warning while keeping the same
            // build pattern as build_full_row_update.
            let _ = build_full_row_update;
            out.push((sql, params));
            sources.push(StatementSource::Update {
                row_key: row_key.clone(),
            });
        }
        // Deletes last so FK references unblocked first.
        for row_key in self.deletes.keys() {
            let RowKey::Persisted(pk_keyvalues) = row_key else {
                continue;
            };
            let pk_indices: Vec<usize> = columns
                .iter()
                .enumerate()
                .filter(|(_, c)| c.primary_key)
                .map(|(i, _)| i)
                .collect();
            if pk_indices.is_empty() {
                return Err(BuildSqlError::NoPrimaryKey);
            }
            let pk_values: Vec<Value> = pk_keyvalues.iter().map(keyvalue_to_value).collect();
            let mut params: Vec<Value> = Vec::new();
            // Same NULL-safe rewrite as the UPDATE path above.
            let where_clauses: Vec<String> = pk_indices
                .iter()
                .enumerate()
                .map(|(local_idx, &col_idx)| {
                    let ident = quote_ident(driver_id, &columns[col_idx].name);
                    if matches!(pk_values[local_idx], Value::Null) {
                        format!("{ident} IS NULL")
                    } else {
                        let s = format!("{ident} = {}", placeholder_for(driver_id, params.len()));
                        params.push(pk_values[local_idx].clone());
                        s
                    }
                })
                .collect();
            let qualified = match schema {
                Some(s) => format!("{}.{}", quote_ident(driver_id, s), quote_ident(driver_id, table)),
                None => quote_ident(driver_id, table),
            };
            let sql = format!("DELETE FROM {qualified} WHERE {}", where_clauses.join(" AND "));
            out.push((sql, params));
            sources.push(StatementSource::Delete {
                row_key: row_key.clone(),
            });
        }
        Ok((out, sources))
    }
}

/// Lossy KeyValue → Value mapping. Used only by `materialize` to feed
/// PK values back into SQL params; equality-correctness preserved.
fn keyvalue_to_value(kv: &KeyValue) -> Value {
    match kv {
        KeyValue::Null => Value::Null,
        KeyValue::Bool(b) => Value::Bool(*b),
        KeyValue::Int(i) => Value::Int(*i),
        KeyValue::FloatBits(bits) => Value::Float(f64::from_bits(*bits)),
        KeyValue::Text(s) => Value::Text(s.clone()),
        KeyValue::Bytes(b) => Value::Bytes(b.clone()),
        KeyValue::Date(d) => Value::Date(*d),
        KeyValue::Time(t) => Value::Time(*t),
        KeyValue::DateTime(dt) => Value::DateTime(*dt),
        KeyValue::TimestampTz(ts) => Value::TimestampTz(*ts),
        KeyValue::Decimal(s) => s.parse().map(Value::Decimal).unwrap_or(Value::Text(s.clone())),
        KeyValue::Uuid(u) => Value::Uuid(*u),
        KeyValue::Json(s) => serde_json::from_str(s)
            .map(Value::Json)
            .unwrap_or(Value::Text(s.clone())),
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
#[allow(dead_code)]
pub fn open_tab(tab_id: Uuid) {
    REGISTRY.with(|reg| reg.borrow_mut().open_tab(tab_id));
}

/// Drop a tab's tracker. Called when the BrowseTab is closed.
#[allow(dead_code)]
pub fn close_tab(tab_id: Uuid) {
    REGISTRY.with(|reg| reg.borrow_mut().close_tab(tab_id));
}

/// True if any open tab has pending changes — used by the app-level
/// quit guard to decide whether to show the "Unsaved changes" dialog.
#[allow(dead_code)]
pub fn any_pending_globally() -> bool {
    REGISTRY.with(|reg| reg.borrow().any_pending())
}

/// Tabs with pending changes — ordered arbitrary (HashMap iteration).
#[allow(dead_code)]
pub fn pending_tabs() -> Vec<Uuid> {
    REGISTRY.with(|reg| reg.borrow().pending_tabs())
}

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
        assert_eq!(undone, Some(key.clone()));
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
        assert!(stmts[2].0.starts_with("DELETE"));
        assert!(matches!(sources[2], StatementSource::Delete { .. }));
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
            },
            ColumnInfo {
                name: "b".into(),
                data_type: "integer".into(),
                nullable: true,
                primary_key: true,
                is_auto_increment: false,
                default_value: None,
                is_generated: false,
            },
            data_col("name"),
        ];
        let key = RowKey::from_pk_values(&[Value::Int(1), Value::Null]).unwrap();
        t.track_cell_edit(key, 2, Value::Text("old".into()), Value::Text("new".into()));
        let (stmts, _sources) = t.materialize("postgres", None, "t", &columns).unwrap();
        assert_eq!(stmts.len(), 1);
        // SET "name" = $1 then WHERE "a" = $2 AND "b" IS NULL
        assert_eq!(
            stmts[0].0,
            "UPDATE \"t\" SET \"name\" = $1 WHERE \"a\" = $2 AND \"b\" IS NULL"
        );
        assert_eq!(stmts[0].1, vec![Value::Text("new".into()), Value::Int(1)]);
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
        assert_eq!(reg.pending_tabs(), vec![id]);
    }
}
