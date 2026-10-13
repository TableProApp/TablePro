//! Pending row edits for one browse tab. Rows are keyed by primary key
//! so an edit survives sort, filter and paging; the tracker is reached
//! only through `TabTrackerHandle`.

use std::collections::{HashMap, HashSet, VecDeque};

use tablepro_core::dml::BuildSqlError;
use tablepro_core::edit::CellInput;
use tablepro_core::meta::RowIdentity;
use tablepro_core::save::{ChangeSet, RowChange, RowUpdate};
use tablepro_core::{ColumnInfo, Value};

use super::cell_overlay::CellOverlay;
use super::touch::Touch;
use super::tracker_delta::{TrackerDelta, VisualChange};
use super::tracker_edit::TrackerEdit;
use super::undo_op::UndoOp;

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
#[derive(Debug, Clone, PartialEq)]
pub struct DraftRow {
    pub draft_id: u64,
    pub values: Vec<Value>,
    /// The insert or the latest edit to one of its cells.
    pub touched: Touch,
}

/// A pending edit to a fetched cell.
#[derive(Debug, Clone, PartialEq)]
pub struct CellEdit {
    /// The fetched value. An edit back to it drops the entry.
    pub original: Value,
    pub pending: Value,
    pub touched: Touch,
}

/// A fetched row marked for delete, with the row as it was read.
#[derive(Debug, Clone, PartialEq)]
pub struct DeleteMark {
    pub original_values: Vec<Value>,
    pub touched: Touch,
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

/// Which grid row a change came from, so a save that fails at one
/// statement can scroll to and flash the row the user edited.
#[derive(Debug, Clone)]
pub enum StatementSource {
    Insert { draft_id: u64 },
    Update { row_key: RowKey },
    Delete { row_key: RowKey },
}

#[derive(Debug, Default)]
pub struct TabChangeTracker {
    drafts: Vec<DraftRow>,
    deletes: HashMap<RowKey, DeleteMark>,
    updates: HashMap<(RowKey, usize), CellEdit>,
    undo: VecDeque<UndoOp>,
    redo: VecDeque<UndoOp>,
    next_draft_id: u64,
    next_touch: Touch,
    /// Row behind the statement the last save failed on.
    error_row: Option<RowKey>,
    // A flash that starts inside an older flash's timeout must not be
    // cleared by that older timer.
    error_row_gen: u64,
}

impl TabChangeTracker {
    pub fn pending_count(&self) -> usize {
        self.drafts.len() + self.deletes.len() + self.updates.len()
    }

    pub fn apply(&mut self, edit: TrackerEdit) -> TrackerDelta {
        match edit {
            TrackerEdit::Cell {
                row_key,
                col,
                original,
                value,
            } => self.track_cell_edit(row_key, col, original, value),
            TrackerEdit::DraftCell { draft_id, col, value } => self.track_draft_cell_edit(draft_id, col, value),
            TrackerEdit::Insert { values } => self.track_insert(values),
            TrackerEdit::Delete {
                row_key,
                original_values,
            } => self.track_delete(row_key, original_values),
            TrackerEdit::DiscardDraft { draft_id } => self.discard_draft(draft_id),
        }
    }

    fn delta(&self, rows: Vec<RowKey>, visual: Vec<VisualChange>) -> TrackerDelta {
        TrackerDelta {
            rows,
            visual,
            pending_count: self.pending_count(),
        }
    }

    fn touch(&mut self) -> Touch {
        let touch = self.next_touch;
        self.next_touch = touch.next();
        touch
    }

    fn push_undo(&mut self, op: UndoOp) {
        if self.undo.len() == UNDO_LIMIT {
            self.undo.pop_front();
        }
        self.undo.push_back(op);
        self.redo.clear();
    }

    fn track_cell_edit(&mut self, row_key: RowKey, col: usize, original: Value, value: Value) -> TrackerDelta {
        let before = self.updates.get(&(row_key.clone(), col)).cloned();
        let original = before.as_ref().map_or(original, |edit| edit.original.clone());
        let after = (value != original).then(|| CellEdit {
            original,
            pending: value,
            touched: self.touch(),
        });
        self.push_undo(UndoOp::CellEdit {
            row_key: row_key.clone(),
            col,
            before,
            after: after.clone(),
        });
        self.put_cell_edit(&row_key, col, after)
    }

    fn track_insert(&mut self, values: Vec<Value>) -> TrackerDelta {
        let draft = DraftRow {
            draft_id: self.next_draft_id,
            values,
            touched: self.touch(),
        };
        self.next_draft_id += 1;
        self.push_undo(UndoOp::Insert { draft: draft.clone() });
        self.put_draft(draft)
    }

    fn track_delete(&mut self, row_key: RowKey, original_values: Vec<Value>) -> TrackerDelta {
        let after = DeleteMark {
            original_values,
            touched: self.touch(),
        };
        self.push_undo(UndoOp::Delete {
            row_key: row_key.clone(),
            before: self.deletes.get(&row_key).cloned(),
            after: after.clone(),
        });
        self.put_delete_mark(&row_key, Some(after))
    }

    // The draft's undo and redo entries go with it, so Ctrl+Z cannot
    // bring it back half-edited.
    fn discard_draft(&mut self, draft_id: u64) -> TrackerDelta {
        let before = self.drafts.len();
        self.drafts.retain(|d| d.draft_id != draft_id);
        if self.drafts.len() == before {
            return self.delta(Vec::new(), Vec::new());
        }
        self.updates
            .retain(|(k, _), _| !matches!(k, RowKey::Draft(id) if *id == draft_id));
        self.deletes
            .retain(|k, _| !matches!(k, RowKey::Draft(id) if *id == draft_id));
        self.undo.retain(|op| !op.is_about_draft(draft_id));
        self.redo.retain(|op| !op.is_about_draft(draft_id));
        self.delta(
            vec![RowKey::Draft(draft_id)],
            vec![VisualChange::RemoveDraft { draft_id }],
        )
    }

    fn track_draft_cell_edit(&mut self, draft_id: u64, col: usize, value: Value) -> TrackerDelta {
        let Some((before, before_touch)) = self.draft_cell(draft_id, col) else {
            return self.delta(Vec::new(), Vec::new());
        };
        let after_touch = self.touch();
        self.push_undo(UndoOp::DraftCell {
            draft_id,
            col,
            before,
            after: value.clone(),
            before_touch,
            after_touch,
        });
        self.put_draft_cell(draft_id, col, value, after_touch)
    }

    fn draft_cell(&self, draft_id: u64, col: usize) -> Option<(Value, Touch)> {
        let draft = self.drafts.iter().find(|d| d.draft_id == draft_id)?;
        Some((draft.values.get(col)?.clone(), draft.touched))
    }

    fn put_cell_edit(&mut self, row_key: &RowKey, col: usize, edit: Option<CellEdit>) -> TrackerDelta {
        let key = (row_key.clone(), col);
        match edit {
            Some(edit) => self.updates.insert(key, edit),
            None => self.updates.remove(&key),
        };
        self.delta(vec![row_key.clone()], Vec::new())
    }

    fn put_delete_mark(&mut self, row_key: &RowKey, mark: Option<DeleteMark>) -> TrackerDelta {
        match mark {
            Some(mark) => self.deletes.insert(row_key.clone(), mark),
            None => self.deletes.remove(row_key),
        };
        self.delta(vec![row_key.clone()], Vec::new())
    }

    fn put_draft(&mut self, draft: DraftRow) -> TrackerDelta {
        let draft_id = draft.draft_id;
        let visual = VisualChange::InsertDraft {
            draft_id,
            values: draft.values.clone(),
        };
        self.drafts.push(draft);
        self.delta(vec![RowKey::Draft(draft_id)], vec![visual])
    }

    fn remove_draft(&mut self, draft_id: u64) -> TrackerDelta {
        self.drafts.retain(|d| d.draft_id != draft_id);
        self.delta(
            vec![RowKey::Draft(draft_id)],
            vec![VisualChange::RemoveDraft { draft_id }],
        )
    }

    fn put_draft_cell(&mut self, draft_id: u64, col: usize, value: Value, touched: Touch) -> TrackerDelta {
        let Some(draft) = self.drafts.iter_mut().find(|d| d.draft_id == draft_id) else {
            return self.delta(Vec::new(), Vec::new());
        };
        let Some(cell) = draft.values.get_mut(col) else {
            return self.delta(Vec::new(), Vec::new());
        };
        *cell = value.clone();
        draft.touched = touched;
        self.delta(
            vec![RowKey::Draft(draft_id)],
            vec![VisualChange::SetDraftCell { draft_id, col, value }],
        )
    }

    pub fn undo(&mut self) -> Option<TrackerDelta> {
        let op = self.undo.pop_back()?;
        let delta = match &op {
            UndoOp::CellEdit {
                row_key, col, before, ..
            } => self.put_cell_edit(row_key, *col, before.clone()),
            UndoOp::DraftCell {
                draft_id,
                col,
                before,
                before_touch,
                ..
            } => self.put_draft_cell(*draft_id, *col, before.clone(), *before_touch),
            UndoOp::Insert { draft } => self.remove_draft(draft.draft_id),
            UndoOp::Delete { row_key, before, .. } => self.put_delete_mark(row_key, before.clone()),
        };
        self.redo.push_back(op);
        Some(delta)
    }

    pub fn redo(&mut self) -> Option<TrackerDelta> {
        let op = self.redo.pop_back()?;
        let delta = match &op {
            UndoOp::CellEdit {
                row_key, col, after, ..
            } => self.put_cell_edit(row_key, *col, after.clone()),
            UndoOp::DraftCell {
                draft_id,
                col,
                after,
                after_touch,
                ..
            } => self.put_draft_cell(*draft_id, *col, after.clone(), *after_touch),
            UndoOp::Insert { draft } => self.put_draft(draft.clone()),
            UndoOp::Delete { row_key, after, .. } => self.put_delete_mark(row_key, Some(after.clone())),
        };
        self.undo.push_back(op);
        Some(delta)
    }

    #[cfg(test)]
    pub fn can_undo(&self) -> bool {
        !self.undo.is_empty()
    }

    #[cfg(test)]
    pub fn can_redo(&self) -> bool {
        !self.redo.is_empty()
    }

    /// Drop every pending change and the undo history.
    pub fn discard(&mut self) -> TrackerDelta {
        let mut seen = HashSet::new();
        let rows: Vec<RowKey> = self
            .updates
            .keys()
            .map(|(row_key, _)| row_key)
            .chain(self.deletes.keys())
            .cloned()
            .chain(self.drafts.iter().map(|draft| RowKey::Draft(draft.draft_id)))
            .filter(|row_key| seen.insert(row_key.clone()))
            .collect();
        let visual = self
            .drafts
            .iter()
            .map(|draft| VisualChange::RemoveDraft {
                draft_id: draft.draft_id,
            })
            .collect();
        self.drafts.clear();
        self.deletes.clear();
        self.updates.clear();
        self.undo.clear();
        self.redo.clear();
        self.delta(rows, visual)
    }

    pub fn cell_overlay(&self, row_key: &RowKey, col: usize, original: &Value) -> CellOverlay {
        CellOverlay {
            value: self.current_cell_value(row_key, col, original).clone(),
            state: self.cell_state(row_key, col),
            error_flash: self.error_row.as_ref() == Some(row_key),
        }
    }

    fn cell_state(&self, row_key: &RowKey, col: usize) -> CellState {
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
        &self.drafts
    }

    /// Mark the row a failed save points at. The returned generation
    /// goes back to `clear_error_row_if` when the flash ends.
    pub fn flash_error_row(&mut self, key: RowKey) -> u64 {
        self.error_row_gen = self.error_row_gen.wrapping_add(1);
        self.error_row = Some(key);
        self.error_row_gen
    }

    /// Clear the flash unless a newer one has started. Returns whether
    /// it cleared, so the caller knows the row needs a rebind.
    pub fn clear_error_row_if(&mut self, generation: u64) -> bool {
        if self.error_row_gen != generation {
            return false;
        }
        self.error_row = None;
        true
    }

    fn current_cell_value<'a>(&'a self, row_key: &RowKey, col: usize, original: &'a Value) -> &'a Value {
        match self.updates.get(&(row_key.clone(), col)) {
            Some(edit) => &edit.pending,
            None => original,
        }
    }

    /// What the user changed, as the change set a save is planned from.
    ///
    /// One change per row, ordered by when the row was last touched, so
    /// the statements run in the order the user made the edits: a row
    /// deleted and then replaced by a draft with the same unique value
    /// saves, because its DELETE runs first. Rows are named by their
    /// primary key in column order, which is the identity `pk_identity`
    /// describes, so the keys bind straight back. A draft cell the user
    /// left empty asks for the server's default where the column has
    /// one, as does any column the server fills.
    pub fn change_set(&self, columns: &[ColumnInfo]) -> Result<TrackedChanges, BuildSqlError> {
        let mut rows: Vec<(Touch, RowChange, StatementSource)> = Vec::new();
        for draft in &self.drafts {
            let cells = columns
                .iter()
                .zip(&draft.values)
                .map(|(column, value)| draft_cell(column, value))
                .collect();
            rows.push((
                draft.touched,
                RowChange::Insert { cells },
                StatementSource::Insert {
                    draft_id: draft.draft_id,
                },
            ));
        }

        // One UPDATE per row, setting only the cells that moved, so a
        // concurrent edit to a column this user never touched survives.
        let mut per_row = HashMap::new();
        for ((row_key, col), edit) in &self.updates {
            if self.deletes.contains_key(row_key) {
                continue;
            }
            per_row.entry(row_key).or_insert_with(Vec::new).push((*col, edit));
        }
        for (row_key, mut cells) in per_row {
            let RowKey::Persisted(key) = row_key else {
                continue;
            };
            require_key(columns)?;
            cells.sort_by_key(|(col, _)| *col);
            let touched = cells.iter().map(|(_, edit)| edit.touched).max().unwrap_or_default();
            rows.push((
                touched,
                RowChange::Update(RowUpdate {
                    key: key_values(key),
                    assignments: cells
                        .into_iter()
                        .map(|(col, edit)| (col, edit.pending.clone()))
                        .collect(),
                }),
                StatementSource::Update {
                    row_key: row_key.clone(),
                },
            ));
        }

        for (row_key, mark) in &self.deletes {
            let RowKey::Persisted(key) = row_key else {
                continue;
            };
            require_key(columns)?;
            rows.push((
                mark.touched,
                RowChange::Delete { key: key_values(key) },
                StatementSource::Delete {
                    row_key: row_key.clone(),
                },
            ));
        }

        // Every edit takes its own touch, so no two rows share one and
        // the order does not depend on how the maps iterated.
        rows.sort_by_key(|(touched, ..)| *touched);
        let (changes, sources) = rows.into_iter().map(|(_, change, source)| (change, source)).unzip();
        Ok(TrackedChanges {
            changes: ChangeSet { changes },
            sources,
        })
    }
}

/// The tracker's changes in the form a save plans from, with the row
/// each one came from.
#[derive(Debug, Clone, Default)]
pub struct TrackedChanges {
    pub changes: ChangeSet,
    sources: Vec<StatementSource>,
}

impl TrackedChanges {
    /// The grid row behind one change, by its position in `changes`.
    pub fn source(&self, change: usize) -> Option<StatementSource> {
        self.sources.get(change).cloned()
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

fn key_values(key: &[KeyValue]) -> Vec<Value> {
    key.iter().map(|part| part.value().clone()).collect()
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

    fn insert(t: &mut TabChangeTracker, values: Vec<Value>) -> u64 {
        match t.track_insert(values).visual.as_slice() {
            [VisualChange::InsertDraft { draft_id, .. }] => *draft_id,
            other => panic!("an insert adds one draft row: {other:?}"),
        }
    }

    #[test]
    fn cell_edit_creates_modified_state() {
        let mut t = TabChangeTracker::default();
        let key = rk(&[Value::Int(1)]);
        t.track_cell_edit(key.clone(), 1, Value::Text("a".into()), Value::Text("b".into()));
        assert_eq!(t.cell_state(&key, 1), CellState::Modified);
        assert_eq!(t.row_state(&key), RowState::Modified);
        assert_eq!(t.pending_count(), 1);
    }

    #[test]
    fn cell_edit_back_to_original_drops_modification() {
        let mut t = TabChangeTracker::default();
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
        let mut t = TabChangeTracker::default();
        let k1 = insert(&mut t, vec![Value::Null, Value::Null]);
        let k2 = insert(&mut t, vec![Value::Null, Value::Null]);
        assert_ne!(k1, k2);
        assert_eq!(t.drafts().len(), 2);
        assert_eq!(t.pending_count(), 2);
    }

    #[test]
    fn delete_marks_row_pending() {
        let mut t = TabChangeTracker::default();
        let key = rk(&[Value::Int(7)]);
        t.track_delete(key.clone(), vec![Value::Int(7), Value::Text("dave".into())]);
        assert_eq!(t.row_state(&key), RowState::PendingDelete);
        assert_eq!(t.pending_count(), 1);
    }

    #[test]
    fn undo_reverts_cell_edit() {
        let mut t = TabChangeTracker::default();
        let key = rk(&[Value::Int(1)]);
        t.track_cell_edit(key.clone(), 1, Value::Text("a".into()), Value::Text("b".into()));
        let undone = t.undo();
        assert_eq!(undone.map(|delta| delta.rows), Some(vec![key.clone()]));
        assert_eq!(t.cell_state(&key, 1), CellState::Clean);
        assert!(t.can_redo());
    }

    #[test]
    fn redo_reapplies_cell_edit() {
        let mut t = TabChangeTracker::default();
        let key = rk(&[Value::Int(1)]);
        t.track_cell_edit(key.clone(), 1, Value::Text("a".into()), Value::Text("b".into()));
        t.undo();
        t.redo();
        assert_eq!(t.cell_state(&key, 1), CellState::Modified);
    }

    #[test]
    fn undo_stack_caps_at_50() {
        let mut t = TabChangeTracker::default();
        let key = rk(&[Value::Int(1)]);
        for i in 0..100 {
            t.track_cell_edit(key.clone(), 1, Value::Int(i), Value::Int(i + 1));
        }
        assert_eq!(t.undo.len(), UNDO_LIMIT);
    }

    #[test]
    fn clear_removes_all_state() {
        let mut t = TabChangeTracker::default();
        let key = rk(&[Value::Int(1)]);
        t.track_cell_edit(key.clone(), 1, Value::Text("a".into()), Value::Text("b".into()));
        t.track_insert(vec![Value::Null]);
        t.track_delete(rk(&[Value::Int(2)]), vec![Value::Int(2)]);
        t.discard();
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

    fn text(value: &str) -> Value {
        Value::Text(value.into())
    }

    fn edit(t: &mut TabChangeTracker, id: i64, from: &str, to: &str) {
        t.track_cell_edit(rk(&[Value::Int(id)]), 1, text(from), text(to));
    }

    /// The cell as the grid draws it, over a fetched "a".
    fn pending(t: &TabChangeTracker, id: i64) -> Value {
        t.cell_overlay(&rk(&[Value::Int(id)]), 1, &text("a")).value
    }

    /// Each change as a verb and the key or draft it names, which is
    /// what the save order is about.
    fn script(t: &TabChangeTracker, columns: &[ColumnInfo]) -> Vec<String> {
        let tracked = t.change_set(columns).unwrap();
        tracked
            .changes
            .changes
            .iter()
            .enumerate()
            .map(|(index, change)| match (change, tracked.source(index)) {
                (RowChange::Insert { .. }, Some(StatementSource::Insert { draft_id })) => format!("insert {draft_id}"),
                (RowChange::Update(update), _) => format!("update {:?}", update.key),
                (RowChange::Delete { key }, _) => format!("delete {key:?}"),
                (change, source) => panic!("{change:?} came from {source:?}"),
            })
            .collect()
    }

    #[test]
    fn undo_after_a_b_c_restores_b() {
        let mut t = TabChangeTracker::default();
        edit(&mut t, 1, "a", "b");
        edit(&mut t, 1, "a", "c");

        let undone = t.undo();

        assert_eq!(undone.map(|delta| delta.rows), Some(vec![rk(&[Value::Int(1)])]));
        assert_eq!(pending(&t, 1), text("b"));
        assert_eq!(t.cell_state(&rk(&[Value::Int(1)]), 1), CellState::Modified);
        assert_eq!(t.pending_count(), 1);
    }

    #[test]
    fn undo_after_a_b_a_restores_b() {
        let mut t = TabChangeTracker::default();
        edit(&mut t, 1, "a", "b");
        edit(&mut t, 1, "a", "a");
        assert_eq!(t.pending_count(), 0);

        let _ = t.undo();

        assert_eq!(pending(&t, 1), text("b"));
        assert_eq!(t.pending_count(), 1);
    }

    #[test]
    fn redo_after_undo_reapplies_c() {
        let mut t = TabChangeTracker::default();
        edit(&mut t, 1, "a", "b");
        edit(&mut t, 1, "a", "c");
        let _ = t.undo();

        let redone = t.redo();

        assert_eq!(redone.map(|delta| delta.pending_count), Some(1));
        assert_eq!(pending(&t, 1), text("c"));
        let _ = t.undo();
        let _ = t.undo();
        assert_eq!(pending(&t, 1), text("a"));
        assert_eq!(t.pending_count(), 0);
    }

    #[test]
    fn new_edit_after_undo_clears_redo() {
        let mut t = TabChangeTracker::default();
        edit(&mut t, 1, "a", "b");
        edit(&mut t, 1, "a", "c");
        let _ = t.undo();

        edit(&mut t, 1, "a", "d");

        assert!(!t.can_redo());
        assert!(t.redo().is_none());
        assert_eq!(pending(&t, 1), text("d"));
        let _ = t.undo();
        assert_eq!(pending(&t, 1), text("b"));
    }

    #[test]
    fn undo_delete_restores_prior_mark_absence() {
        let mut t = TabChangeTracker::default();
        let marked_twice = rk(&[Value::Int(1)]);
        let marked_once = rk(&[Value::Int(2)]);
        t.track_delete(marked_twice.clone(), vec![Value::Int(1)]);
        t.track_delete(marked_twice.clone(), vec![Value::Int(1)]);
        t.track_delete(marked_once.clone(), vec![Value::Int(2)]);

        let _ = t.undo();
        assert_eq!(t.row_state(&marked_once), RowState::Clean);
        let _ = t.undo();
        assert_eq!(t.row_state(&marked_twice), RowState::PendingDelete);
        let _ = t.undo();
        assert_eq!(t.row_state(&marked_twice), RowState::Clean);
        assert_eq!(t.pending_count(), 0);
    }

    #[test]
    fn draft_cell_undo_restores_previous_draft_value() {
        let mut t = TabChangeTracker::default();
        let draft_id = insert(&mut t, vec![Value::Null, text("a")]);
        let _ = t.apply(TrackerEdit::DraftCell {
            draft_id,
            col: 1,
            value: text("b"),
        });
        let _ = t.apply(TrackerEdit::DraftCell {
            draft_id,
            col: 1,
            value: text("c"),
        });

        let undone = t.undo();

        assert_eq!(
            undone.map(|delta| delta.visual),
            Some(vec![VisualChange::SetDraftCell {
                draft_id,
                col: 1,
                value: text("b")
            }])
        );
        assert_eq!(t.drafts()[0].values[1], text("b"));
        let redone = t.redo().map(|delta| delta.visual);
        assert_eq!(
            redone,
            Some(vec![VisualChange::SetDraftCell {
                draft_id,
                col: 1,
                value: text("c")
            }])
        );
    }

    #[test]
    fn change_set_orders_rows_by_last_touch() {
        let mut t = TabChangeTracker::default();
        let columns = vec![pk_col("id"), data_col("name")];
        edit(&mut t, 1, "a", "b");
        let draft_id = insert(&mut t, vec![Value::Null, text("draft")]);
        t.track_delete(rk(&[Value::Int(3)]), vec![Value::Int(3)]);
        edit(&mut t, 2, "a", "b");
        // Row 1 moves behind everything it was ahead of.
        edit(&mut t, 1, "a", "c");

        assert_eq!(
            script(&t, &columns),
            vec![
                format!("insert {draft_id}"),
                "delete [Int(3)]".to_owned(),
                "update [Int(2)]".to_owned(),
                "update [Int(1)]".to_owned(),
            ]
        );

        // Undo puts the row's touch back with its value.
        let _ = t.undo();
        assert_eq!(script(&t, &columns)[0], "update [Int(1)]");
    }

    #[test]
    fn change_set_places_delete_before_later_insert() {
        let mut t = TabChangeTracker::default();
        let columns = vec![pk_col("id"), data_col("email")];
        t.track_delete(rk(&[Value::Int(1)]), vec![Value::Int(1), text("a")]);
        let draft_id = insert(&mut t, vec![Value::Null, text("a")]);

        let (tracked, plan) = plan(&t, &columns);

        let sql: Vec<&str> = plan.batch.steps.iter().map(|step| step.statement.sql()).collect();
        assert!(sql[0].starts_with("DELETE"), "{sql:?}");
        assert!(sql[1].starts_with("INSERT"), "{sql:?}");
        assert!(matches!(
            plan.origin(1).and_then(|change| tracked.source(change)),
            Some(StatementSource::Insert { draft_id: id }) if id == draft_id
        ));
    }

    #[test]
    fn a_draft_edited_after_a_delete_saves_after_it() {
        let mut t = TabChangeTracker::default();
        let columns = vec![pk_col("id"), data_col("email")];
        let draft_id = insert(&mut t, vec![Value::Null, Value::Null]);
        t.track_delete(rk(&[Value::Int(1)]), vec![Value::Int(1), text("a")]);
        let _ = t.apply(TrackerEdit::DraftCell {
            draft_id,
            col: 1,
            value: text("a"),
        });

        assert_eq!(
            script(&t, &columns),
            vec!["delete [Int(1)]".to_owned(), format!("insert {draft_id}")]
        );
    }

    #[test]
    fn undo_and_redo_of_a_draft_edit_put_its_touch_back() {
        let mut t = TabChangeTracker::default();
        let columns = vec![pk_col("id"), data_col("email")];
        let draft_id = insert(&mut t, vec![Value::Null, Value::Null]);
        t.track_delete(rk(&[Value::Int(1)]), vec![Value::Int(1), text("a")]);
        let _ = t.apply(TrackerEdit::DraftCell {
            draft_id,
            col: 1,
            value: text("a"),
        });
        let edited = vec!["delete [Int(1)]".to_owned(), format!("insert {draft_id}")];
        assert_eq!(script(&t, &columns), edited);

        let _ = t.undo();
        assert_eq!(
            script(&t, &columns),
            vec![format!("insert {draft_id}"), "delete [Int(1)]".to_owned()]
        );

        let _ = t.redo();
        assert_eq!(script(&t, &columns), edited);
    }

    #[test]
    fn undo_and_redo_of_a_cell_edit_put_its_touch_back() {
        let mut t = TabChangeTracker::default();
        let columns = vec![pk_col("id"), data_col("name")];
        edit(&mut t, 1, "a", "b");
        t.track_delete(rk(&[Value::Int(2)]), vec![Value::Int(2), text("a")]);
        edit(&mut t, 1, "a", "c");
        let edited = vec!["delete [Int(2)]".to_owned(), "update [Int(1)]".to_owned()];
        assert_eq!(script(&t, &columns), edited);

        let _ = t.undo();
        assert_eq!(
            script(&t, &columns),
            vec!["update [Int(1)]".to_owned(), "delete [Int(2)]".to_owned()]
        );

        let _ = t.redo();
        assert_eq!(script(&t, &columns), edited);
        assert_eq!(pending(&t, 1), text("c"));
    }

    #[test]
    fn change_set_identical_across_trackers() {
        let columns = vec![pk_col("id"), data_col("name")];
        // Every tracker's maps get their own hash seed, so with this
        // many rows two trackers iterate them in different orders.
        let edit_script = |t: &mut TabChangeTracker| {
            for id in (0..40).rev() {
                match id % 3 {
                    0 => t.track_delete(rk(&[Value::Int(id)]), vec![Value::Int(id)]),
                    _ => t.track_cell_edit(rk(&[Value::Int(id)]), 1, text("a"), text("b")),
                };
            }
            let _ = t.track_insert(vec![Value::Null, text("draft")]);
        };
        let mut first = TabChangeTracker::default();
        let mut second = TabChangeTracker::default();
        edit_script(&mut first);
        edit_script(&mut second);

        let mut edit_order: Vec<String> = (0..40)
            .rev()
            .map(|id| match id % 3 {
                0 => format!("delete [Int({id})]"),
                _ => format!("update [Int({id})]"),
            })
            .collect();
        edit_order.push("insert 0".to_owned());

        assert_eq!(script(&first, &columns), edit_order);
        assert_eq!(script(&second, &columns), edit_order);
    }

    #[test]
    fn deleted_row_emits_only_delete() {
        let mut t = TabChangeTracker::default();
        let columns = vec![pk_col("id"), data_col("name")];
        edit(&mut t, 1, "a", "b");
        t.track_delete(rk(&[Value::Int(1)]), vec![Value::Int(1), text("a")]);

        assert_eq!(script(&t, &columns), vec!["delete [Int(1)]".to_owned()]);

        // Undoing the delete brings the edit back into the save.
        let _ = t.undo();
        assert_eq!(script(&t, &columns), vec!["update [Int(1)]".to_owned()]);
    }

    #[test]
    fn a_failing_step_maps_back_to_the_row_that_made_it() {
        let mut t = TabChangeTracker::default();
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
        let mut t = TabChangeTracker::default();
        let columns = vec![pk_col("a"), pk_col("b"), data_col("name")];
        let key = RowKey::from_pk_values(&[Value::Int(1), Value::Int(2)]).unwrap();
        t.track_cell_edit(key, 2, Value::Text("old".into()), Value::Text("new".into()));

        let tracked = t.change_set(&columns).unwrap();

        assert_eq!(
            tracked.changes.changes,
            vec![RowChange::Update(RowUpdate {
                key: vec![Value::Int(1), Value::Int(2)],
                assignments: vec![(2, Value::Text("new".into()))],
            })]
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
        let mut t = TabChangeTracker::default();
        let mut stamped = data_col("created_at");
        stamped.default = tablepro_core::column::ColumnDefault::Expression(
            tablepro_core::column::SqlExpression::from_catalog_text("now()"),
        );
        let columns = vec![pk_col("id"), data_col("name"), stamped];
        t.track_insert(vec![Value::Null, Value::Text("draft".into()), Value::Null]);

        let tracked = t.change_set(&columns).unwrap();

        assert_eq!(
            tracked.changes.changes,
            vec![RowChange::Insert {
                cells: vec![
                    CellInput::Default,
                    CellInput::Value(Value::Text("draft".into())),
                    CellInput::Default
                ]
            }]
        );
    }

    #[test]
    fn a_table_without_a_primary_key_cannot_save_an_update() {
        let mut t = TabChangeTracker::default();
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
    fn discard_draft_removes_insert_and_clears_undo() {
        let mut t = TabChangeTracker::default();
        let draft_id = insert(&mut t, vec![Value::Null, Value::Text("hi".into())]);
        // Edit the draft so undo stack has a CellEdit on top of Insert.
        t.track_draft_cell_edit(draft_id, 1, Value::Text("edited".into()));
        assert_eq!(t.drafts().len(), 1);
        assert!(t.can_undo());

        let removed = t.discard_draft(draft_id);

        assert_eq!(removed.visual, vec![VisualChange::RemoveDraft { draft_id }]);
        assert!(t.drafts().is_empty(), "draft must be gone");
        assert!(!t.can_undo(), "undo entries scoped to the draft must be cleared");
        assert_eq!(t.pending_count(), 0, "no pending state after discard");
    }

    #[test]
    fn discard_draft_no_op_for_unknown_id() {
        let mut t = TabChangeTracker::default();
        assert_eq!(t.discard_draft(99_999), TrackerDelta::default());
        assert_eq!(t.pending_count(), 0);
    }

    #[test]
    fn discard_draft_leaves_other_drafts_intact() {
        let mut t = TabChangeTracker::default();
        let a = insert(&mut t, vec![Value::Int(1)]);
        let b = insert(&mut t, vec![Value::Int(2)]);
        assert_eq!(t.drafts().len(), 2);
        assert_eq!(t.discard_draft(a).pending_count, 1);
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
        let mut t = TabChangeTracker::default();
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
    fn apply_routes_each_edit_and_reports_the_rows_it_touched() {
        let mut t = TabChangeTracker::default();
        let key = rk(&[Value::Int(1)]);

        let edited = t.apply(TrackerEdit::Cell {
            row_key: key.clone(),
            col: 1,
            original: Value::Text("a".into()),
            value: Value::Text("b".into()),
        });
        let deleted = t.apply(TrackerEdit::Delete {
            row_key: rk(&[Value::Int(2)]),
            original_values: vec![Value::Int(2)],
        });

        assert_eq!(edited.rows, vec![key]);
        assert!(edited.visual.is_empty());
        assert_eq!(edited.pending_count, 1);
        assert_eq!(deleted.rows, vec![rk(&[Value::Int(2)])]);
        assert_eq!(deleted.pending_count, 2);
    }

    #[test]
    fn a_draft_cell_edit_updates_the_draft_row_and_undo_restores_it() {
        let mut t = TabChangeTracker::default();
        let draft_id = insert(&mut t, vec![Value::Null, Value::Text("a".into())]);

        let edited = t.apply(TrackerEdit::DraftCell {
            draft_id,
            col: 1,
            value: Value::Text("b".into()),
        });
        let undone = t.undo();

        assert_eq!(
            edited.visual,
            vec![VisualChange::SetDraftCell {
                draft_id,
                col: 1,
                value: Value::Text("b".into())
            }]
        );
        assert_eq!(
            undone.map(|delta| delta.visual),
            Some(vec![VisualChange::SetDraftCell {
                draft_id,
                col: 1,
                value: Value::Text("a".into())
            }])
        );
        assert_eq!(t.drafts()[0].values[1], Value::Text("a".into()));
    }

    #[test]
    fn a_draft_cell_outside_the_row_changes_nothing() {
        let mut t = TabChangeTracker::default();
        let draft_id = insert(&mut t, vec![Value::Null]);

        let delta = t.apply(TrackerEdit::DraftCell {
            draft_id,
            col: 4,
            value: Value::Int(1),
        });

        assert!(delta.rows.is_empty() && delta.visual.is_empty());
        assert_eq!(delta.pending_count, 1);
    }

    #[test]
    fn undo_and_redo_of_an_insert_remove_and_restore_the_draft_row() {
        let mut t = TabChangeTracker::default();
        let draft_id = insert(&mut t, vec![Value::Int(7)]);

        let undone = t.undo().map(|delta| delta.visual);
        let redone = t.redo().map(|delta| delta.visual);

        assert_eq!(undone, Some(vec![VisualChange::RemoveDraft { draft_id }]));
        assert_eq!(
            redone,
            Some(vec![VisualChange::InsertDraft {
                draft_id,
                values: vec![Value::Int(7)]
            }])
        );
    }

    #[test]
    fn redo_of_a_persisted_cell_edit_leaves_the_fetched_row_alone() {
        let mut t = TabChangeTracker::default();
        let key = rk(&[Value::Int(1)]);
        t.track_cell_edit(key.clone(), 1, Value::Text("a".into()), Value::Text("b".into()));
        let _ = t.undo();

        let redone = t.redo();

        assert_eq!(
            redone.map(|delta| (delta.rows, delta.visual)),
            Some((vec![key], Vec::new()))
        );
    }

    #[test]
    fn discard_drops_every_draft_row_and_reports_each_touched_row_once() {
        let mut t = TabChangeTracker::default();
        let key = rk(&[Value::Int(1)]);
        t.track_cell_edit(key.clone(), 1, Value::Int(1), Value::Int(2));
        t.track_cell_edit(key.clone(), 2, Value::Int(3), Value::Int(4));
        let draft_id = insert(&mut t, vec![Value::Null]);

        let delta = t.discard();

        assert_eq!(delta.pending_count, 0);
        assert_eq!(delta.visual, vec![VisualChange::RemoveDraft { draft_id }]);
        assert_eq!(delta.rows.len(), 2, "{:?}", delta.rows);
        assert!(delta.rows.contains(&key) && delta.rows.contains(&RowKey::Draft(draft_id)));
    }

    #[test]
    fn cell_overlay_shows_the_pending_value_over_the_fetched_one() {
        let mut t = TabChangeTracker::default();
        let key = rk(&[Value::Int(1)]);
        let fetched = Value::Text("a".into());
        t.track_cell_edit(key.clone(), 1, fetched.clone(), Value::Text("b".into()));

        let edited = t.cell_overlay(&key, 1, &fetched);
        let untouched = t.cell_overlay(&key, 0, &Value::Int(1));

        assert_eq!(edited.value, Value::Text("b".into()));
        assert_eq!(edited.state, CellState::Modified);
        assert_eq!(untouched.value, Value::Int(1));
        assert_eq!(untouched.state, CellState::Clean);
    }

    #[test]
    fn an_older_flash_timer_does_not_clear_a_newer_flash() {
        let mut t = TabChangeTracker::default();
        let first = rk(&[Value::Int(1)]);
        let second = RowKey::Draft(3);
        let old = t.flash_error_row(first.clone());
        let new = t.flash_error_row(second.clone());

        assert!(!t.clear_error_row_if(old));
        assert!(t.cell_overlay(&second, 0, &Value::Null).error_flash);
        assert!(!t.cell_overlay(&first, 0, &Value::Null).error_flash);
        assert!(t.clear_error_row_if(new));
        assert!(!t.cell_overlay(&second, 0, &Value::Null).error_flash);
    }
}
