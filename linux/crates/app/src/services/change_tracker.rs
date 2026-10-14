//! Pending row edits for one browse tab. Rows are keyed by primary key
//! so an edit survives sort, filter and paging; the tracker is reached
//! only through `TabTrackerHandle`.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::Arc;

use tablepro_core::dml::BuildSqlError;
use tablepro_core::edit::CellInput;
use tablepro_core::meta::RowIdentity;
use tablepro_core::save::{ChangeSet, RowChange, RowUpdate};
use tablepro_core::{ColumnInfo, Value};

use super::cell_overlay::CellOverlay;
use super::column_relayout::{ColumnRelayout, Misfit};
use super::save_batch::{SaveBatch, SaveTarget};
use super::touch::Touch;
use super::tracker_delta::TrackerDelta;
use super::tracker_edit::TrackerEdit;
use super::undo_op::{DeleteStep, UndoOp};
use crate::workspace::{PendingState, SaveOutcome, SaveRejection, SaveSnapshot, UnknownCause};

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

/// A draft row collected by the tracker, one cell per column. A cell
/// left to the server is `CellInput::Default`, which is not a NULL.
#[derive(Debug, Clone, PartialEq)]
pub struct DraftRow {
    pub draft_id: u64,
    pub cells: Vec<CellInput>,
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

/// The save that is running: where its edits end, and the value it
/// writes to each cell.
#[derive(Debug)]
struct InFlightSave {
    snapshot: SaveSnapshot,
    /// Until the save settles, each of these cells holds either this
    /// value or the one that was fetched, so no later edit to it can be
    /// called a return to the cell's value.
    written: HashMap<(RowKey, usize), Value>,
}

/// A pending change the table's columns no longer have a place for.
/// Saved by its old position it would write another column or row, and
/// dropped it would be lost unseen, so it stays pending and refuses
/// every save until it is discarded.
#[derive(Debug, Clone, PartialEq)]
struct SetAside {
    touched: Touch,
    misfit: Misfit,
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
    /// The table and columns the tab last read, which a save is planned
    /// against. Every column position the tracker holds is one in these.
    target: Option<SaveTarget>,
    set_aside: Vec<SetAside>,
    saving: Option<InFlightSave>,
    /// A save that may have landed. Saving again could apply it twice,
    /// so nothing saves until the tab is reloaded or discarded.
    outcome_unknown: Option<UnknownCause>,
}

impl TabChangeTracker {
    pub fn pending_count(&self) -> usize {
        self.drafts.len() + self.deletes.len() + self.updates.len() + self.set_aside.len()
    }

    /// An edit the running save holds back comes back as a redraw of its
    /// row, so the grid stops showing what was typed into it.
    pub fn apply(&mut self, edit: TrackerEdit) -> TrackerDelta {
        match edit {
            TrackerEdit::DeleteRows { persisted, drafts } => self.delete_rows(persisted, drafts),
            edit if self.edit_is_in_flight(&edit) => self.delta(edit.row_keys()),
            TrackerEdit::Cell {
                row_key,
                col,
                original,
                value,
            } => self.track_cell_edit(row_key, col, original, value),
            TrackerEdit::DraftCell { draft_id, col, input } => self.track_draft_cell_edit(draft_id, col, input),
            TrackerEdit::InsertDraft { cells } => self.track_insert(cells),
        }
    }

    /// An edit that would change what the running save already sent.
    /// An insert or a delete cannot be sent twice, so a draft or a
    /// delete in the save stays as it is until the save settles; a cell
    /// edit is a new value, which the next save writes. A Delete is held
    /// back row by row, so this says whether any of its rows is.
    pub fn edit_is_in_flight(&self, edit: &TrackerEdit) -> bool {
        match edit {
            TrackerEdit::DraftCell { draft_id, .. } => self.draft_in_flight(*draft_id),
            TrackerEdit::Cell { row_key, .. } => self.row_in_flight(row_key),
            TrackerEdit::DeleteRows { persisted, drafts } => {
                persisted.iter().any(|(row_key, _)| self.row_in_flight(row_key))
                    || drafts.iter().any(|draft_id| self.draft_in_flight(*draft_id))
            }
            TrackerEdit::InsertDraft { .. } => false,
        }
    }

    fn draft_in_flight(&self, draft_id: u64) -> bool {
        self.saving.as_ref().is_some_and(|save| {
            self.drafts
                .iter()
                .any(|draft| draft.draft_id == draft_id && save.snapshot.includes(draft.touched))
        })
    }

    fn row_in_flight(&self, row_key: &RowKey) -> bool {
        match row_key {
            RowKey::Draft(draft_id) => self.draft_in_flight(*draft_id),
            RowKey::Persisted(_) => self.saving.as_ref().is_some_and(|save| {
                self.deletes
                    .get(row_key)
                    .is_some_and(|mark| save.snapshot.includes(mark.touched))
            }),
        }
    }

    fn delta(&self, changed: Vec<RowKey>) -> TrackerDelta {
        TrackerDelta {
            changed,
            pending_count: self.pending_count(),
            ..TrackerDelta::default()
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
        let key = (row_key.clone(), col);
        let before = self.updates.get(&key).cloned();
        let in_flight = self.is_being_written(&key);
        let original = before.as_ref().map_or(original, |edit| edit.original.clone());
        let after = (in_flight || value != original).then(|| CellEdit {
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

    fn track_insert(&mut self, cells: Vec<CellInput>) -> TrackerDelta {
        let draft = DraftRow {
            draft_id: self.next_draft_id,
            cells,
            touched: self.touch(),
        };
        self.next_draft_id += 1;
        self.push_undo(UndoOp::Insert { draft: draft.clone() });
        self.put_draft(draft)
    }

    /// Marks the saved rows and drops the drafts. The marks are one undo
    /// step; a row the running save is deleting already is held back and
    /// only drawn again.
    fn delete_rows(&mut self, persisted: Vec<(RowKey, Arc<[Value]>)>, drafts: Vec<u64>) -> TrackerDelta {
        let mut changed = Vec::new();
        let mut removed_drafts = Vec::new();
        for draft_id in drafts {
            if !self.draft_in_flight(draft_id) && self.drop_draft(draft_id) {
                removed_drafts.push(draft_id);
            }
            changed.push(RowKey::Draft(draft_id));
        }
        let mut steps = Vec::new();
        for (row_key, original) in persisted {
            changed.push(row_key.clone());
            if self.row_in_flight(&row_key) {
                continue;
            }
            let after = DeleteMark {
                original_values: original.to_vec(),
                touched: self.touch(),
            };
            let before = self.deletes.insert(row_key.clone(), after.clone());
            steps.push(DeleteStep { row_key, before, after });
        }
        if !steps.is_empty() {
            self.push_undo(UndoOp::Delete { steps });
        }
        dedup(&mut changed);
        TrackerDelta {
            removed_drafts,
            ..self.delta(changed)
        }
    }

    // The draft's undo and redo entries go with it, so Ctrl+Z cannot
    // bring it back half-edited.
    fn drop_draft(&mut self, draft_id: u64) -> bool {
        let before = self.drafts.len();
        self.drafts.retain(|d| d.draft_id != draft_id);
        if self.drafts.len() == before {
            return false;
        }
        self.updates
            .retain(|(k, _), _| !matches!(k, RowKey::Draft(id) if *id == draft_id));
        self.deletes
            .retain(|k, _| !matches!(k, RowKey::Draft(id) if *id == draft_id));
        self.undo.retain(|op| !op.is_about_draft(draft_id));
        self.redo.retain(|op| !op.is_about_draft(draft_id));
        true
    }

    fn track_draft_cell_edit(&mut self, draft_id: u64, col: usize, input: CellInput) -> TrackerDelta {
        let Some((before, before_touch)) = self.draft_cell(draft_id, col) else {
            return self.delta(Vec::new());
        };
        let after_touch = self.touch();
        self.push_undo(UndoOp::DraftCell {
            draft_id,
            col,
            before,
            after: input.clone(),
            before_touch,
            after_touch,
        });
        self.put_draft_cell(draft_id, col, input, after_touch)
    }

    fn draft_cell(&self, draft_id: u64, col: usize) -> Option<(CellInput, Touch)> {
        let draft = self.drafts.iter().find(|d| d.draft_id == draft_id)?;
        Some((draft.cells.get(col)?.clone(), draft.touched))
    }

    fn is_being_written(&self, cell: &(RowKey, usize)) -> bool {
        self.saving.as_ref().is_some_and(|save| save.written.contains_key(cell))
    }

    fn put_cell_edit(&mut self, row_key: &RowKey, col: usize, edit: Option<CellEdit>) -> TrackerDelta {
        let key = (row_key.clone(), col);
        // An edit equal to the fetched value is kept only while a save
        // writes the cell. Undo and redo wait for the save, so they find
        // such an edit no longer changing anything.
        let edit = edit.filter(|edit| edit.pending != edit.original || self.is_being_written(&key));
        match edit {
            Some(edit) => self.updates.insert(key, edit),
            None => self.updates.remove(&key),
        };
        self.delta(vec![row_key.clone()])
    }

    /// Undo puts each step's `before` back, last step first; redo puts
    /// each `after` back in order.
    fn put_delete_marks(&mut self, steps: &[DeleteStep], undo: bool) -> TrackerDelta {
        let mut put = |row_key: &RowKey, mark: Option<DeleteMark>| match mark {
            Some(mark) => self.deletes.insert(row_key.clone(), mark),
            None => self.deletes.remove(row_key),
        };
        if undo {
            for step in steps.iter().rev() {
                put(&step.row_key, step.before.clone());
            }
        } else {
            for step in steps {
                put(&step.row_key, Some(step.after.clone()));
            }
        }
        self.delta(steps.iter().map(|step| step.row_key.clone()).collect())
    }

    fn put_draft(&mut self, draft: DraftRow) -> TrackerDelta {
        let draft_id = draft.draft_id;
        self.drafts.push(draft);
        TrackerDelta {
            inserted_drafts: vec![draft_id],
            ..self.delta(vec![RowKey::Draft(draft_id)])
        }
    }

    fn remove_draft(&mut self, draft_id: u64) -> TrackerDelta {
        self.drafts.retain(|d| d.draft_id != draft_id);
        TrackerDelta {
            removed_drafts: vec![draft_id],
            ..self.delta(vec![RowKey::Draft(draft_id)])
        }
    }

    fn put_draft_cell(&mut self, draft_id: u64, col: usize, input: CellInput, touched: Touch) -> TrackerDelta {
        let Some(draft) = self.drafts.iter_mut().find(|d| d.draft_id == draft_id) else {
            return self.delta(Vec::new());
        };
        let Some(cell) = draft.cells.get_mut(col) else {
            return self.delta(Vec::new());
        };
        *cell = input;
        draft.touched = touched;
        self.delta(vec![RowKey::Draft(draft_id)])
    }

    /// Nothing while a save runs: stepping back through edits the save
    /// already sent would show a state the database is not left in.
    pub fn undo(&mut self) -> Option<TrackerDelta> {
        if self.saving.is_some() {
            return None;
        }
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
            UndoOp::Delete { steps } => self.put_delete_marks(steps, true),
        };
        self.redo.push_back(op);
        Some(delta)
    }

    pub fn redo(&mut self) -> Option<TrackerDelta> {
        if self.saving.is_some() {
            return None;
        }
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
            UndoOp::Delete { steps } => self.put_delete_marks(steps, false),
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

    /// Drop every pending change and the undo history. A save whose
    /// outcome was unknown is resolved: the tab reads the table again.
    pub fn discard(&mut self) -> TrackerDelta {
        self.outcome_unknown = None;
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
        let removed_drafts = self.drafts.iter().map(|draft| draft.draft_id).collect();
        self.drafts.clear();
        self.deletes.clear();
        self.updates.clear();
        self.set_aside.clear();
        self.undo.clear();
        self.redo.clear();
        TrackerDelta {
            removed_drafts,
            ..self.delta(rows)
        }
    }

    pub fn cell_overlay(&self, row_key: &RowKey, col: usize, original: &Value) -> CellOverlay {
        CellOverlay {
            value: self.current_cell_value(row_key, col, original),
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
    /// it cleared, so the caller knows the row needs a redraw.
    pub fn clear_error_row_if(&mut self, generation: u64) -> bool {
        if self.error_row_gen != generation {
            return false;
        }
        self.error_row = None;
        true
    }

    /// A draft's cells live only here, so for a draft `original` is
    /// what an out-of-range column reads as, and a cell left to the
    /// server reads as NULL.
    fn current_cell_value(&self, row_key: &RowKey, col: usize, original: &Value) -> Value {
        if let RowKey::Draft(draft_id) = row_key {
            return match self.draft_input(*draft_id, col) {
                Some(CellInput::Value(value)) => value,
                Some(CellInput::Default) => Value::Null,
                None => original.clone(),
            };
        }
        match self.updates.get(&(row_key.clone(), col)) {
            Some(edit) => edit.pending.clone(),
            None => original.clone(),
        }
    }

    /// A draft's values, with a cell left to the server as NULL.
    pub fn draft_values(&self, draft_id: u64) -> Option<Vec<Value>> {
        self.drafts
            .iter()
            .find(|draft| draft.draft_id == draft_id)
            .map(|draft| {
                draft
                    .cells
                    .iter()
                    .map(|input| input.value().cloned().unwrap_or(Value::Null))
                    .collect()
            })
    }

    pub fn draft_input(&self, draft_id: u64, col: usize) -> Option<CellInput> {
        self.drafts
            .iter()
            .find(|draft| draft.draft_id == draft_id)
            .and_then(|draft| draft.cells.get(col))
            .cloned()
    }

    /// A draft's cells as its INSERT carries them.
    pub fn draft_cells(&self, draft_id: u64, columns: &[ColumnInfo]) -> Option<Vec<CellInput>> {
        self.drafts
            .iter()
            .find(|draft| draft.draft_id == draft_id)
            .map(|draft| insert_cells(columns, draft))
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
            rows.push((
                draft.touched,
                RowChange::Insert {
                    cells: insert_cells(columns, draft),
                },
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

    /// Columns read again move every pending change to the column of
    /// the same name. A change they have no place for is set aside.
    pub(crate) fn set_target(&mut self, target: SaveTarget) -> TrackerDelta {
        let columns = target.columns.clone();
        match self.target.replace(target) {
            Some(previous) if previous.columns != columns => {
                self.relayout(&ColumnRelayout::new(&previous.columns, &columns))
            }
            _ => self.delta(Vec::new()),
        }
    }

    fn relayout(&mut self, layout: &ColumnRelayout<'_>) -> TrackerDelta {
        let mut rows = Vec::new();
        let mut removed_drafts = Vec::new();
        let set_aside = self.set_aside.len();
        for ((row_key, col), edit) in std::mem::take(&mut self.updates) {
            match layout.key(&row_key).and_then(|()| layout.cell(col, &edit.pending)) {
                Ok(moved) => {
                    self.updates.insert((row_key.clone(), moved), edit);
                }
                Err(misfit) => self.set_aside.push(SetAside {
                    touched: edit.touched,
                    misfit,
                }),
            }
            rows.push(row_key);
        }
        for (row_key, mut mark) in std::mem::take(&mut self.deletes) {
            match layout.key(&row_key) {
                Ok(()) => {
                    mark.original_values = layout.fetched(&mark.original_values);
                    self.deletes.insert(row_key.clone(), mark);
                }
                Err(misfit) => self.set_aside.push(SetAside {
                    touched: mark.touched,
                    misfit,
                }),
            }
            rows.push(row_key);
        }
        for mut draft in std::mem::take(&mut self.drafts) {
            match layout.draft(&draft.cells) {
                Ok(cells) => {
                    draft.cells = cells;
                    self.drafts.push(draft);
                }
                Err(misfit) => {
                    removed_drafts.push(draft.draft_id);
                    self.set_aside.push(SetAside {
                        touched: draft.touched,
                        misfit,
                    });
                }
            }
        }
        if let Some(save) = self.saving.as_mut() {
            save.written = std::mem::take(&mut save.written)
                .into_iter()
                .filter_map(|((row_key, col), value)| {
                    layout.key(&row_key).ok()?;
                    Some(((row_key, layout.position(col)?), value))
                })
                .collect();
        }
        let undo: Option<VecDeque<UndoOp>> = self.undo.iter().map(|op| op.relayout(layout)).collect();
        let redo: Option<VecDeque<UndoOp>> = self.redo.iter().map(|op| op.relayout(layout)).collect();
        match (self.set_aside.len() == set_aside, undo, redo) {
            (true, Some(undo), Some(redo)) => {
                self.undo = undo;
                self.redo = redo;
            }
            // A step back would bring a change to a place it no longer has.
            _ => {
                self.undo.clear();
                self.redo.clear();
            }
        }
        dedup(&mut rows);
        TrackerDelta {
            removed_drafts,
            ..self.delta(rows)
        }
    }

    /// Why the changes set aside cannot be saved, the key first since
    /// it strands every edited row.
    fn set_aside_rejection(&self) -> Option<SaveRejection> {
        if self.set_aside.is_empty() {
            return None;
        }
        if self.set_aside.iter().any(|change| change.misfit == Misfit::Key) {
            return Some(SaveRejection::KeyChanged);
        }
        let mut columns: Vec<String> = Vec::new();
        for change in &self.set_aside {
            if let Misfit::Columns(names) = &change.misfit {
                for name in names {
                    if !columns.contains(name) {
                        columns.push(name.clone());
                    }
                }
            }
        }
        Some(SaveRejection::ColumnsChanged(columns))
    }

    pub(crate) fn pending_state(&self) -> PendingState {
        if let Some(cause) = &self.outcome_unknown {
            return PendingState::OutcomeUnknown(cause.clone());
        }
        if self.saving.is_some() {
            return PendingState::Saving;
        }
        match self.pending_count() {
            0 => PendingState::Clean,
            _ => PendingState::Unsaved,
        }
    }

    /// Take what Save writes, and hold it as in flight until it settles.
    /// `None` when there is nothing to save.
    pub(crate) fn begin_save(&mut self) -> Result<Option<SaveBatch>, SaveRejection> {
        if self.outcome_unknown.is_some() {
            return Err(SaveRejection::OutcomeUnknown);
        }
        if self.saving.is_some() {
            return Err(SaveRejection::AlreadySaving);
        }
        if let Some(rejection) = self.set_aside_rejection() {
            return Err(rejection);
        }
        if self.pending_count() == 0 {
            return Ok(None);
        }
        let Some(target) = self.target.clone() else {
            return Err(SaveRejection::ColumnsNotRead);
        };
        let changes = self.change_set(&target.columns).map_err(SaveRejection::Build)?;
        if changes.changes.is_empty() {
            return Ok(None);
        }
        let snapshot = SaveSnapshot(self.next_touch);
        let written = self
            .updates
            .iter()
            .filter(|((row_key, _), _)| matches!(row_key, RowKey::Persisted(_)) && !self.deletes.contains_key(row_key))
            .map(|(cell, edit)| (cell.clone(), edit.pending.clone()))
            .collect();
        self.saving = Some(InFlightSave { snapshot, written });
        Ok(Some(SaveBatch {
            table: target.table,
            columns: target.columns,
            changes,
            snapshot,
        }))
    }

    /// End the save `snapshot` began. A commit drops what it wrote and
    /// keeps every edit made while it ran, now measured against what the
    /// save wrote; a rollback keeps everything, measured against what was
    /// fetched; an unknown outcome keeps everything and refuses the next
    /// save.
    pub(crate) fn settle_save(&mut self, outcome: &SaveOutcome, snapshot: SaveSnapshot) -> TrackerDelta {
        let written = self
            .saving
            .take_if(|save| save.snapshot == snapshot)
            .map(|save| save.written)
            .unwrap_or_default();
        match outcome {
            SaveOutcome::Committed { .. } => {
                let mut delta = self.drop_saved(snapshot);
                delta.changed.extend(self.rebase(written, true));
                dedup(&mut delta.changed);
                delta.pending_count = self.pending_count();
                delta
            }
            SaveOutcome::RolledBack(_) => {
                let rows = self.rebase(written, false);
                self.delta(rows)
            }
            SaveOutcome::Unknown(cause) => {
                self.mark_outcome_unknown(cause.clone());
                self.delta(Vec::new())
            }
        }
    }

    pub(crate) fn mark_outcome_unknown(&mut self, cause: UnknownCause) {
        self.outcome_unknown = Some(cause);
    }

    /// Edits made to cells a settled save wrote. After a commit the cell
    /// holds what the save wrote, which becomes the value an edit is
    /// measured against; after a rollback it still holds what was
    /// fetched. Either way an edit back to that value is no change.
    fn rebase(&mut self, written: HashMap<(RowKey, usize), Value>, committed: bool) -> Vec<RowKey> {
        let mut rows = Vec::new();
        for (cell, value) in written {
            let Some(edit) = self.updates.get_mut(&cell) else {
                continue;
            };
            if committed {
                edit.original = value;
            }
            if edit.pending == edit.original {
                self.updates.remove(&cell);
                rows.push(cell.0);
            }
        }
        dedup(&mut rows);
        rows
    }

    fn drop_saved(&mut self, snapshot: SaveSnapshot) -> TrackerDelta {
        let mut rows = Vec::new();
        let mut removed_drafts = Vec::new();
        self.updates.retain(|(row_key, _), edit| {
            let saved = snapshot.includes(edit.touched);
            if saved {
                rows.push(row_key.clone());
            }
            !saved
        });
        self.deletes.retain(|row_key, mark| {
            let saved = snapshot.includes(mark.touched);
            if saved {
                rows.push(row_key.clone());
            }
            !saved
        });
        self.set_aside.retain(|change| !snapshot.includes(change.touched));
        self.drafts.retain(|draft| {
            let saved = snapshot.includes(draft.touched);
            if saved {
                rows.push(RowKey::Draft(draft.draft_id));
                removed_drafts.push(draft.draft_id);
            }
            !saved
        });
        // The history describes edits against rows as they were read,
        // and the saved ones are now the rows themselves.
        self.undo.clear();
        self.redo.clear();
        dedup(&mut rows);
        TrackerDelta {
            removed_drafts,
            ..self.delta(rows)
        }
    }
}

fn dedup(rows: &mut Vec<RowKey>) {
    let mut seen = HashSet::new();
    rows.retain(|row_key| seen.insert(row_key.clone()));
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

/// A column the server always fills is left to it whatever the draft
/// holds: SQL Server IDENTITY and PostgreSQL GENERATED ALWAYS refuse a
/// value.
fn insert_cells(columns: &[ColumnInfo], draft: &DraftRow) -> Vec<CellInput> {
    columns
        .iter()
        .zip(&draft.cells)
        .map(
            |(column, input)| match column.is_auto_increment || column.is_generated {
                true => CellInput::Default,
                false => input.clone(),
            },
        )
        .collect()
}

/// What a new row holds in `column` until the user types: the server's
/// value where it has one, else NULL.
pub fn new_draft_cell(column: &ColumnInfo) -> CellInput {
    match column.is_auto_increment || column.is_generated || !column.default.is_none() {
        true => CellInput::Default,
        false => CellInput::Value(Value::Null),
    }
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
        match t
            .track_insert(values.into_iter().map(CellInput::Value).collect())
            .inserted_drafts
            .as_slice()
        {
            [draft_id] => *draft_id,
            other => panic!("an insert adds one draft row: {other:?}"),
        }
    }

    fn delete(t: &mut TabChangeTracker, row_key: RowKey, original: Vec<Value>) -> TrackerDelta {
        t.apply(TrackerEdit::DeleteRows {
            persisted: vec![(row_key, original.into())],
            drafts: Vec::new(),
        })
    }

    fn drop_drafts(t: &mut TabChangeTracker, drafts: Vec<u64>) -> TrackerDelta {
        t.apply(TrackerEdit::DeleteRows {
            persisted: Vec::new(),
            drafts,
        })
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
        delete(&mut t, key.clone(), vec![Value::Int(7), Value::Text("dave".into())]);
        assert_eq!(t.row_state(&key), RowState::PendingDelete);
        assert_eq!(t.pending_count(), 1);
    }

    #[test]
    fn undo_reverts_cell_edit() {
        let mut t = TabChangeTracker::default();
        let key = rk(&[Value::Int(1)]);
        t.track_cell_edit(key.clone(), 1, Value::Text("a".into()), Value::Text("b".into()));
        let undone = t.undo();
        assert_eq!(undone.map(|delta| delta.changed), Some(vec![key.clone()]));
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
        t.track_insert(vec![Value::Null].into_iter().map(CellInput::Value).collect());
        delete(&mut t, rk(&[Value::Int(2)]), vec![Value::Int(2)]);
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

        assert_eq!(undone.map(|delta| delta.changed), Some(vec![rk(&[Value::Int(1)])]));
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
        delete(&mut t, marked_twice.clone(), vec![Value::Int(1)]);
        delete(&mut t, marked_twice.clone(), vec![Value::Int(1)]);
        delete(&mut t, marked_once.clone(), vec![Value::Int(2)]);

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
            input: CellInput::Value(text("b")),
        });
        let _ = t.apply(TrackerEdit::DraftCell {
            draft_id,
            col: 1,
            input: CellInput::Value(text("c")),
        });

        let undone = t.undo();

        assert_eq!(undone.map(|delta| delta.changed), Some(vec![RowKey::Draft(draft_id)]));
        assert_eq!(t.drafts()[0].cells[1], CellInput::Value(text("b")));
        let redone = t.redo().map(|delta| delta.changed);
        assert_eq!(redone, Some(vec![RowKey::Draft(draft_id)]));
        assert_eq!(t.drafts()[0].cells[1], CellInput::Value(text("c")));
    }

    #[test]
    fn change_set_orders_rows_by_last_touch() {
        let mut t = TabChangeTracker::default();
        let columns = vec![pk_col("id"), data_col("name")];
        edit(&mut t, 1, "a", "b");
        let draft_id = insert(&mut t, vec![Value::Null, text("draft")]);
        delete(&mut t, rk(&[Value::Int(3)]), vec![Value::Int(3)]);
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
        delete(&mut t, rk(&[Value::Int(1)]), vec![Value::Int(1), text("a")]);
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
        delete(&mut t, rk(&[Value::Int(1)]), vec![Value::Int(1), text("a")]);
        let _ = t.apply(TrackerEdit::DraftCell {
            draft_id,
            col: 1,
            input: CellInput::Value(text("a")),
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
        delete(&mut t, rk(&[Value::Int(1)]), vec![Value::Int(1), text("a")]);
        let _ = t.apply(TrackerEdit::DraftCell {
            draft_id,
            col: 1,
            input: CellInput::Value(text("a")),
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
        delete(&mut t, rk(&[Value::Int(2)]), vec![Value::Int(2), text("a")]);
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
                    0 => delete(t, rk(&[Value::Int(id)]), vec![Value::Int(id)]),
                    _ => t.track_cell_edit(rk(&[Value::Int(id)]), 1, text("a"), text("b")),
                };
            }
            let _ = t.track_insert(
                vec![Value::Null, text("draft")]
                    .into_iter()
                    .map(CellInput::Value)
                    .collect(),
            );
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
        delete(&mut t, rk(&[Value::Int(1)]), vec![Value::Int(1), text("a")]);

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
        t.track_insert(
            vec![Value::Null, Value::Text("draft".into())]
                .into_iter()
                .map(CellInput::Value)
                .collect(),
        );
        delete(
            &mut t,
            doomed.clone(),
            vec![Value::Int(9), Value::Text("doomed".into())],
        );

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
        let mut cells: Vec<CellInput> = columns.iter().map(new_draft_cell).collect();
        cells[1] = CellInput::Value(Value::Text("draft".into()));
        let draft_id = match t.track_insert(cells).inserted_drafts.as_slice() {
            [draft_id] => *draft_id,
            other => panic!("an insert adds one draft row: {other:?}"),
        };

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

        // NULL set on purpose is not the default.
        let _ = t.apply(TrackerEdit::DraftCell {
            draft_id,
            col: 2,
            input: CellInput::Value(Value::Null),
        });
        assert_eq!(
            t.draft_cells(draft_id, &columns).map(|cells| cells[2].clone()),
            Some(CellInput::Value(Value::Null))
        );
    }

    #[test]
    fn a_draft_leaves_an_auto_increment_column_to_the_server() {
        let mut t = TabChangeTracker::default();
        let columns = vec![pk_col("id"), data_col("name")];
        let draft_id = insert(&mut t, vec![Value::Int(42), Value::Text("draft".into())]);

        let tracked = t.change_set(&columns).unwrap();

        let expected = vec![CellInput::Default, CellInput::Value(Value::Text("draft".into()))];
        assert_eq!(
            tracked.changes.changes,
            vec![RowChange::Insert {
                cells: expected.clone()
            }]
        );
        assert_eq!(t.draft_cells(draft_id, &columns), Some(expected));
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
        t.track_draft_cell_edit(draft_id, 1, CellInput::Value(Value::Text("edited".into())));
        assert_eq!(t.drafts().len(), 1);
        assert!(t.can_undo());

        let removed = drop_drafts(&mut t, vec![draft_id]);

        assert_eq!(removed.removed_drafts, vec![draft_id]);
        assert!(t.drafts().is_empty(), "draft must be gone");
        assert!(!t.can_undo(), "undo entries scoped to the draft must be cleared");
        assert_eq!(t.pending_count(), 0, "no pending state after discard");
    }

    #[test]
    fn discard_draft_no_op_for_unknown_id() {
        let mut t = TabChangeTracker::default();
        let delta = drop_drafts(&mut t, vec![99_999]);

        assert!(delta.removed_drafts.is_empty());
        assert_eq!(delta.pending_count, 0);
        assert!(!t.can_undo());
    }

    #[test]
    fn discard_draft_leaves_other_drafts_intact() {
        let mut t = TabChangeTracker::default();
        let a = insert(&mut t, vec![Value::Int(1)]);
        let b = insert(&mut t, vec![Value::Int(2)]);
        assert_eq!(t.drafts().len(), 2);
        assert_eq!(drop_drafts(&mut t, vec![a]).pending_count, 1);
        assert_eq!(t.drafts().len(), 1);
        assert_eq!(t.drafts()[0].draft_id, b);
        // The remaining draft is still undoable on its own.
        assert!(t.can_undo());
    }

    #[test]
    fn one_delete_over_many_rows_is_one_undo_step() {
        let mut t = TabChangeTracker::default();
        let earlier = rk(&[Value::Int(9)]);
        delete(&mut t, earlier.clone(), vec![Value::Int(9)]);
        let keys: Vec<RowKey> = (10..70).map(|id| rk(&[Value::Int(id)])).collect();
        let draft_id = insert(&mut t, vec![Value::Null]);

        let deleted = t.apply(TrackerEdit::DeleteRows {
            persisted: keys
                .iter()
                .map(|key| (key.clone(), vec![Value::Int(0)].into()))
                .collect(),
            drafts: vec![draft_id],
        });
        assert_eq!(deleted.removed_drafts, vec![draft_id]);
        assert_eq!(deleted.changed.len(), 61);
        assert_eq!(t.pending_count(), 61);

        let undone = t.undo().expect("the delete to undo");
        assert_eq!(undone.changed, keys, "the undo left some of the rows marked");
        assert_eq!(t.pending_count(), 1);
        assert_eq!(t.row_state(&earlier), RowState::PendingDelete);
        let _ = t.redo();
        assert!(keys.iter().all(|key| t.row_state(key) == RowState::PendingDelete));
    }

    #[test]
    fn a_delete_during_a_save_holds_back_only_the_rows_in_it() {
        let columns = vec![pk_col("id"), data_col("name")];
        let mut t = saving_on(columns);
        let saved_draft = insert(&mut t, vec![Value::Null, text("a")]);
        let _batch = t.begin_save().unwrap().unwrap();
        let new_draft = insert(&mut t, vec![Value::Null, text("b")]);
        let edit = TrackerEdit::DeleteRows {
            persisted: vec![(rk(&[Value::Int(1)]), vec![Value::Int(1)].into())],
            drafts: vec![saved_draft, new_draft],
        };
        assert!(t.edit_is_in_flight(&edit));

        let delta = t.apply(edit);

        assert_eq!(delta.removed_drafts, vec![new_draft]);
        assert!(
            delta.changed.contains(&RowKey::Draft(saved_draft)),
            "the held draft is not drawn again"
        );
        assert_eq!(t.drafts().len(), 1);
        assert_eq!(t.row_state(&rk(&[Value::Int(1)])), RowState::PendingDelete);
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
        let deleted = delete(&mut t, rk(&[Value::Int(2)]), vec![Value::Int(2)]);

        assert_eq!(edited.changed, vec![key]);
        assert!(edited.inserted_drafts.is_empty() && edited.removed_drafts.is_empty());
        assert_eq!(edited.pending_count, 1);
        assert_eq!(deleted.changed, vec![rk(&[Value::Int(2)])]);
        assert_eq!(deleted.pending_count, 2);
    }

    #[test]
    fn a_draft_cell_edit_updates_the_draft_row_and_undo_restores_it() {
        let mut t = TabChangeTracker::default();
        let draft_id = insert(&mut t, vec![Value::Null, Value::Text("a".into())]);

        let edited = t.apply(TrackerEdit::DraftCell {
            draft_id,
            col: 1,
            input: CellInput::Value(Value::Text("b".into())),
        });
        let undone = t.undo();

        assert_eq!(edited.changed, vec![RowKey::Draft(draft_id)]);
        assert!(edited.inserted_drafts.is_empty() && edited.removed_drafts.is_empty());
        assert_eq!(undone.map(|delta| delta.changed), Some(vec![RowKey::Draft(draft_id)]));
        assert_eq!(t.drafts()[0].cells[1], CellInput::Value(Value::Text("a".into())));
    }

    #[test]
    fn a_draft_cell_reads_from_the_tracker() {
        let mut t = TabChangeTracker::default();
        let draft_id = insert(&mut t, vec![Value::Null, Value::Text("a".into())]);
        let _ = t.apply(TrackerEdit::DraftCell {
            draft_id,
            col: 1,
            input: CellInput::Value(Value::Text("b".into())),
        });

        let overlay = t.cell_overlay(&RowKey::Draft(draft_id), 1, &Value::Null);

        assert_eq!(overlay.value, Value::Text("b".into()));
        assert_eq!(overlay.state, CellState::InsertDraft);
        assert_eq!(
            t.cell_overlay(&RowKey::Draft(draft_id), 9, &Value::Null).value,
            Value::Null
        );
    }

    #[test]
    fn a_draft_cell_outside_the_row_changes_nothing() {
        let mut t = TabChangeTracker::default();
        let draft_id = insert(&mut t, vec![Value::Null]);

        let delta = t.apply(TrackerEdit::DraftCell {
            draft_id,
            col: 4,
            input: CellInput::Value(Value::Int(1)),
        });

        assert_eq!(
            delta,
            TrackerDelta {
                pending_count: 1,
                ..TrackerDelta::default()
            }
        );
        assert_eq!(delta.pending_count, 1);
    }

    #[test]
    fn undo_and_redo_of_an_insert_remove_and_restore_the_draft_row() {
        let mut t = TabChangeTracker::default();
        let draft_id = insert(&mut t, vec![Value::Int(7)]);

        let undone = t.undo().expect("the insert to undo");
        let redone = t.redo().expect("the insert to redo");

        assert_eq!(
            (undone.inserted_drafts, undone.removed_drafts),
            (Vec::new(), vec![draft_id])
        );
        assert_eq!(
            (redone.inserted_drafts, redone.removed_drafts),
            (vec![draft_id], Vec::new())
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
            redone.map(|delta| (delta.changed, delta.inserted_drafts, delta.removed_drafts)),
            Some((vec![key], Vec::new(), Vec::new()))
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
        assert_eq!(delta.removed_drafts, vec![draft_id]);
        assert_eq!(delta.changed.len(), 2, "{:?}", delta.changed);
        assert!(delta.changed.contains(&key) && delta.changed.contains(&RowKey::Draft(draft_id)));
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

    fn saving_on(columns: Vec<ColumnInfo>) -> TabChangeTracker {
        let mut t = TabChangeTracker::default();
        let _ = t.set_target(SaveTarget {
            table: tablepro_core::meta::TableRef::unqualified("t"),
            columns,
        });
        t
    }

    fn committed() -> SaveOutcome {
        SaveOutcome::Committed { rows: Some(1) }
    }

    fn rolled_back() -> SaveOutcome {
        SaveOutcome::RolledBack(crate::workspace::RollbackCause::Driver(
            tablepro_core::DriverError::server("no"),
        ))
    }

    /// Each UPDATE's assignments, by column name.
    fn assignments(t: &TabChangeTracker, columns: &[ColumnInfo]) -> Vec<(String, Value)> {
        t.change_set(columns)
            .unwrap()
            .changes
            .changes
            .into_iter()
            .flat_map(|change| match change {
                RowChange::Update(update) => update.assignments,
                other => panic!("only updates were made: {other:?}"),
            })
            .map(|(col, value)| (columns[col].name.clone(), value))
            .collect()
    }

    #[test]
    fn a_return_to_the_fetched_value_during_a_save_is_written_after_it() {
        let columns = vec![pk_col("id"), data_col("name")];
        let mut t = saving_on(columns.clone());
        edit(&mut t, 1, "a", "b");
        let batch = t.begin_save().unwrap().unwrap();
        edit(&mut t, 1, "a", "c");
        edit(&mut t, 1, "a", "a");

        let _ = t.settle_save(&committed(), batch.snapshot);

        // The save left b in the database, so the a typed while it ran
        // is a change.
        assert_eq!(assignments(&t, &columns), vec![("name".to_owned(), text("a"))]);
        assert_eq!(t.cell_state(&rk(&[Value::Int(1)]), 1), CellState::Modified);
    }

    #[test]
    fn a_return_to_the_fetched_value_during_a_save_that_rolls_back_is_no_change() {
        let columns = vec![pk_col("id"), data_col("name")];
        let mut t = saving_on(columns.clone());
        edit(&mut t, 1, "a", "b");
        let batch = t.begin_save().unwrap().unwrap();
        edit(&mut t, 1, "a", "c");
        edit(&mut t, 1, "a", "a");

        let delta = t.settle_save(&rolled_back(), batch.snapshot);

        assert_eq!(delta.pending_count, 0);
        assert_eq!(t.pending_count(), 0);
        assert_eq!(delta.changed, vec![rk(&[Value::Int(1)])]);
    }

    #[test]
    fn an_edit_that_outlives_a_save_is_measured_against_what_it_wrote() {
        let columns = vec![pk_col("id"), data_col("name")];
        let mut t = saving_on(columns.clone());
        edit(&mut t, 1, "a", "b");
        let batch = t.begin_save().unwrap().unwrap();
        edit(&mut t, 1, "a", "c");
        let _ = t.settle_save(&committed(), batch.snapshot);

        // The page read after the commit holds b.
        edit(&mut t, 1, "b", "a");
        assert_eq!(assignments(&t, &columns), vec![("name".to_owned(), text("a"))]);

        edit(&mut t, 1, "b", "b");
        assert_eq!(t.pending_count(), 0, "a return to what the save wrote stayed pending");
    }

    fn retarget(t: &mut TabChangeTracker, columns: &[ColumnInfo]) {
        let _ = t.set_target(SaveTarget {
            table: tablepro_core::meta::TableRef::unqualified("t"),
            columns: columns.to_vec(),
        });
    }

    fn rejection(t: &mut TabChangeTracker) -> String {
        match t.begin_save() {
            Err(rejection) => rejection.message(),
            Ok(batch) => panic!("the save went ahead: {batch:?}"),
        }
    }

    #[test]
    fn an_edit_follows_its_column_when_another_is_dropped() {
        let before = vec![pk_col("id"), data_col("nickname"), data_col("name"), data_col("email")];
        let after = vec![pk_col("id"), data_col("name"), data_col("email")];
        let mut t = saving_on(before);
        t.track_cell_edit(rk(&[Value::Int(1)]), 2, text("Ada"), text("Grace"));

        retarget(&mut t, &after);

        assert_eq!(assignments(&t, &after), vec![("name".to_owned(), text("Grace"))]);
        assert_eq!(pending_at(&t, 1, 1), text("Grace"));
        assert_eq!(t.cell_state(&rk(&[Value::Int(1)]), 2), CellState::Clean);
    }

    #[test]
    fn a_draft_follows_its_columns_when_one_is_added_and_one_dropped() {
        let before = vec![pk_col("id"), data_col("nickname"), data_col("name")];
        let after = vec![pk_col("id"), data_col("name"), data_col("email")];
        let mut t = saving_on(before);
        let draft_id = insert(&mut t, vec![Value::Null, Value::Null, text("Ada")]);

        retarget(&mut t, &after);

        assert_eq!(
            t.draft_values(draft_id),
            Some(vec![Value::Null, text("Ada"), Value::Null])
        );
    }

    #[test]
    fn an_edit_to_a_dropped_column_refuses_the_save() {
        let before = vec![pk_col("id"), data_col("nickname"), data_col("name")];
        let after = vec![pk_col("id"), data_col("name")];
        let mut t = saving_on(before);
        t.track_cell_edit(rk(&[Value::Int(1)]), 1, text("ada"), text("countess"));
        edit(&mut t, 2, "Grace", "Hopper");

        retarget(&mut t, &after);

        assert!(rejection(&mut t).contains("nickname"));
        assert_eq!(t.pending_count(), 2, "an edit nothing can save was dropped");
        assert_eq!(t.pending_state(), PendingState::Unsaved);
    }

    #[test]
    fn a_draft_with_a_value_in_a_dropped_column_refuses_the_save() {
        let before = vec![pk_col("id"), data_col("nickname"), data_col("name")];
        let after = vec![pk_col("id"), data_col("name")];
        let mut t = saving_on(before);
        let _ = insert(&mut t, vec![Value::Null, text("ada"), text("Ada")]);

        retarget(&mut t, &after);

        assert!(rejection(&mut t).contains("nickname"));
        assert_eq!(t.pending_count(), 1);
    }

    #[test]
    fn an_edit_that_no_longer_fits_a_retyped_column_refuses_the_save() {
        let before = vec![pk_col("id"), test_column("score", "text")];
        let after = vec![pk_col("id"), test_column("score", "integer")];
        let mut t = saving_on(before);
        t.track_cell_edit(rk(&[Value::Int(1)]), 1, text("1"), text("high"));

        retarget(&mut t, &after);

        assert!(rejection(&mut t).contains("score"));
    }

    #[test]
    fn an_edit_that_still_fits_a_retyped_column_saves() {
        let before = vec![pk_col("id"), test_column("score", "integer")];
        let after = vec![pk_col("id"), test_column("score", "bigint")];
        let mut t = saving_on(before);
        t.track_cell_edit(rk(&[Value::Int(1)]), 1, Value::Int(1), Value::Int(2));

        retarget(&mut t, &after);

        assert_eq!(assignments(&t, &after), vec![("score".to_owned(), Value::Int(2))]);
        assert!(t.begin_save().is_ok_and(|batch| batch.is_some()));
    }

    #[test]
    fn a_new_primary_key_refuses_edits_to_rows_named_by_the_old_one() {
        let before = vec![pk_col("id"), test_column("legacy_id", "integer"), data_col("name")];
        let mut legacy_key = test_column("legacy_id", "integer");
        legacy_key.primary_key = true;
        let mut plain_id = test_column("id", "integer");
        plain_id.nullable = false;
        let after = vec![plain_id, legacy_key, data_col("name")];
        let mut t = saving_on(before);
        t.track_cell_edit(rk(&[Value::Int(1)]), 2, text("Ada"), text("Grace"));
        delete(
            &mut t,
            rk(&[Value::Int(2)]),
            vec![Value::Int(2), Value::Int(9), text("Bob")],
        );

        retarget(&mut t, &after);

        assert_eq!(t.begin_save().err(), Some(SaveRejection::KeyChanged));
        assert_eq!(t.pending_count(), 2);
    }

    #[test]
    fn undo_after_a_column_is_dropped_steps_back_on_the_moved_column() {
        let before = vec![pk_col("id"), data_col("nickname"), data_col("name")];
        let after = vec![pk_col("id"), data_col("name")];
        let mut t = saving_on(before);
        t.track_cell_edit(rk(&[Value::Int(1)]), 2, text("Ada"), text("Grace"));
        t.track_cell_edit(rk(&[Value::Int(1)]), 2, text("Ada"), text("Hopper"));
        retarget(&mut t, &after);

        let _ = t.undo();

        assert_eq!(assignments(&t, &after), vec![("name".to_owned(), text("Grace"))]);
        let _ = t.redo();
        assert_eq!(assignments(&t, &after), vec![("name".to_owned(), text("Hopper"))]);
    }

    #[test]
    fn discard_drops_an_edit_the_columns_left_behind() {
        let before = vec![pk_col("id"), data_col("nickname")];
        let after = vec![pk_col("id")];
        let mut t = saving_on(before);
        t.track_cell_edit(rk(&[Value::Int(1)]), 1, text("ada"), text("countess"));
        retarget(&mut t, &after);

        let _ = t.discard();

        assert_eq!(t.pending_count(), 0);
        assert!(matches!(t.begin_save(), Ok(None)));
    }

    /// The cell as the grid draws it at `col`, over a fetched "Ada".
    fn pending_at(t: &TabChangeTracker, id: i64, col: usize) -> Value {
        t.cell_overlay(&rk(&[Value::Int(id)]), col, &text("Ada")).value
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
