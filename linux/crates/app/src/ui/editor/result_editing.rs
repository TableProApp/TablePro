use std::cell::{Cell, OnceCell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::Arc;

use gtk4::gio;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use tablepro_core::browse::PageLayout;
use tablepro_core::column::{ColumnDefault, ColumnInfo, ResultColumn};
use tablepro_core::edit::{ResultSource, result_source, result_target, value_for_column};
use tablepro_core::meta::{RowIdentity, TableRef};
use tablepro_core::{TransactionState, Value};

use super::SqlEditor;
use super::run_log::EntryKind;
use super::run_scope::ScopedText;
use crate::application::{ShortcutOwner, local_shortcut_controller};
use crate::services::change_tracker::{RowKey, StatementSource, pk_identity};
use crate::services::grid::{
    EditPolicy, EditRefusal, GridColumn, GridMasks, ResultRefusal, RowKeyBuilder, edit_policy, saving_policy,
};
use crate::services::save_batch::SaveTarget;
use crate::services::tab_tracker_handle::TabTrackerHandle;
use crate::ui::browse_tab::{ColumnFreshness, PendingChangesRequest, load_columns};
use crate::ui::data_grid::{DataGrid, EditRules, RowData};
use crate::ui::discard_alert::confirm_discard;
use crate::ui::result_pane::{ResultGrid, ResultSetView};
use crate::workspace::PendingState;

#[derive(Debug, Clone)]
pub(super) enum ResultEdit {
    Locked(ResultRefusal),
    Checking,
    Editable(Rc<EditTarget>),
}

#[derive(Debug)]
pub(super) struct EditTarget {
    table: TableRef,
    // One per result column, in result order; a column the result can't write back is generated, so no statement names it.
    save_columns: Vec<ColumnInfo>,
    // Which result columns are the table's own, so only their values are retyped.
    traced: Vec<bool>,
    // A value kept as the server's text would bind as text in a copied row.
    copyable: Cell<bool>,
    grid_columns: Arc<[GridColumn]>,
    identity: RowIdentity,
}

#[derive(Debug)]
struct ResultActions {
    save: gio::SimpleAction,
    save_changes: gio::SimpleAction,
    undo: gio::SimpleAction,
    redo: gio::SimpleAction,
}

#[derive(Debug, Default)]
pub struct ResultEditing {
    tracker: OnceCell<TabTrackerHandle>,
    actions: OnceCell<ResultActions>,
    states: RefCell<HashMap<usize, ResultEdit>>,
    // The one result of the run, once its table's columns proved it editable; the tracker holds its target.
    owner: Cell<Option<usize>>,
    // Bumped by every run, so a catalog read for an older one is dropped.
    run: Cell<u64>,
    dirty: Cell<bool>,
    // A result read after a USE in the same run came from a database the tab may have left again.
    moves_database: Cell<bool>,
    // The run that reads a result again after its save; history keeps what the user ran, not this.
    rereading: Cell<bool>,
    quiet_run: Cell<bool>,
    // No row changes while a save runs, so the result read after it loses none.
    saving: Cell<bool>,
}

impl SqlEditor {
    pub(crate) fn save_changes_action(&self) -> Option<gio::SimpleAction> {
        self.imp()
            .editing
            .actions
            .get()
            .map(|actions| actions.save_changes.clone())
    }

    pub(crate) fn attach_row_tracker(&self, tracker: TabTrackerHandle) {
        if self.imp().editing.tracker.set(tracker).is_err() {
            return;
        }
        let results = self.imp().results.get();
        let group = gio::SimpleActionGroup::new();
        let action = |name: &str, act: fn(&SqlEditor)| {
            let action = gio::SimpleAction::new(name, None);
            action.set_enabled(false);
            let editor = self.downgrade();
            action.connect_activate(move |_, _| {
                if let Some(editor) = editor.upgrade() {
                    act(&editor);
                }
            });
            group.add_action(&action);
            action
        };
        let actions = ResultActions {
            save: action("save", SqlEditor::save_rows),
            save_changes: action("save-changes", SqlEditor::save_rows),
            undo: action("undo", |editor| {
                if let Some(grid) = editor.owner_grid() {
                    grid.undo();
                }
            }),
            redo: action("redo", |editor| {
                if let Some(grid) = editor.owner_grid() {
                    grid.redo();
                }
            }),
        };
        results.insert_action_group("results", Some(&group));
        results.add_controller(local_shortcut_controller(ShortcutOwner::EditorResults));
        let _ = self.imp().editing.actions.set(actions);
        let bar = results.pending_bar();
        for request in [
            PendingChangesRequest::Save,
            PendingChangesRequest::Discard,
            PendingChangesRequest::StopSaving,
        ] {
            let editor = self.downgrade();
            bar.connect_request(request, move |_| {
                if let Some(editor) = editor.upgrade() {
                    editor.on_pending_request(request);
                }
            });
        }
    }

    // A value still in a result cell's editor is an unsaved change once the window asks about closing.
    pub(crate) fn commit_result_edit(&self) {
        if let Some(grid) = self.owner_grid() {
            grid.commit_edit();
        }
    }

    fn row_tracker(&self) -> Option<TabTrackerHandle> {
        self.imp().editing.tracker.get().cloned()
    }

    pub(super) fn note_run_moves_database(&self, moves: bool) {
        self.imp().editing.moves_database.set(moves);
    }

    // Called as a run starts: whether it is the read after a save, which history leaves out.
    pub(super) fn starts_quiet_run(&self) {
        let editing = &self.imp().editing;
        editing.quiet_run.set(editing.rereading.get());
    }

    pub(super) fn ends_quiet_run(&self) -> bool {
        self.imp().editing.quiet_run.replace(false)
    }

    // The rows of the last run are about to be replaced, which the caller made sure loses no change.
    pub(super) fn forget_result_edits(&self) {
        let editing = &self.imp().editing;
        editing.run.set(editing.run.get().wrapping_add(1));
        editing.states.borrow_mut().clear();
        editing.owner.set(None);
        if let Some(tracker) = self.row_tracker() {
            let _ = tracker.discard();
        }
        self.refresh_pending_bar();
    }

    // Before a run replaces the results: false when the run has to wait, after asking where it may.
    pub(super) fn results_may_change(&self, then: impl Fn(&Self) + 'static) -> bool {
        let Some(tracker) = self.row_tracker() else {
            return true;
        };
        if let Some(grid) = self.owner_grid() {
            grid.commit_edit();
        }
        if tracker.pending_state() == PendingState::Saving {
            self.emit_by_name::<()>(
                "toast",
                &[&crate::i18n::gettext("Wait for the changes to finish saving")],
            );
            return false;
        }
        let pending = tracker.pending_count();
        if pending == 0 && tracker.pending_state() == PendingState::Clean {
            return true;
        }
        let editor = self.downgrade();
        confirm_discard(
            self,
            pending.max(1),
            move || tracker.pending_state(),
            move || {
                if let Some(editor) = editor.upgrade() {
                    if editor
                        .row_tracker()
                        .is_some_and(|tracker| tracker.pending_state() == PendingState::Saving)
                    {
                        return;
                    }
                    // The run about to start replaces these rows, so they are not read again first.
                    editor.drop_rows();
                    then(&editor);
                }
            },
        );
        false
    }

    pub(super) fn decide_result_edits(&self) {
        if self.row_tracker().is_none() {
            return;
        }
        let imp = self.imp();
        let Some(deps) = self.deps() else {
            return;
        };
        let Some(session) = deps.session.get() else {
            return;
        };
        let grammar = self.grammar();
        // A shell's documents or a key store's replies are not a table's rows; the row details say so already.
        if !grammar.is_sql() {
            return;
        }
        let (results, transaction) = {
            let log = imp.log.borrow();
            let Some(log) = log.as_ref() else {
                return;
            };
            let results: Vec<usize> = log
                .entries()
                .iter()
                .enumerate()
                .filter(|(_, entry)| matches!(entry.kind, EntryKind::ResultSet(_)))
                .map(|(index, _)| index)
                .collect();
            (results, log.transaction())
        };
        // The save runs on the window's connection, so rows read inside the tab's own transaction would be written outside it.
        // These come before any parse: a batch of many SELECTs hands each result the whole batch.
        let common = if session.read_only() {
            Some(ResultRefusal::ReadOnlySession)
        } else if matches!(
            transaction,
            Some(TransactionState::InTransaction | TransactionState::Failed)
        ) || imp.open_transaction.get().is_some()
        {
            Some(ResultRefusal::OpenTransaction)
        } else if transaction != Some(TransactionState::Idle) {
            Some(ResultRefusal::TransactionUnknown)
        } else if self.tab_database().is_some() || imp.editing.moves_database.get() {
            Some(ResultRefusal::OtherDatabase)
        } else if results.len() > 1 {
            Some(ResultRefusal::SeveralResults)
        } else {
            None
        };
        let run = imp.editing.run.get();
        for index in results {
            let state = match common {
                Some(refusal) => ResultEdit::Locked(refusal),
                None => {
                    let source = imp
                        .log
                        .borrow()
                        .as_ref()
                        .and_then(|log| log.result(index))
                        .map(|result| result_source(result.statement.as_str(), grammar, &result.columns));
                    match source {
                        Some(Ok(source)) => {
                            self.read_target_columns(run, index, source);
                            ResultEdit::Checking
                        }
                        Some(Err(lock)) => ResultEdit::Locked(lock.into()),
                        None => ResultEdit::Locked(ResultRefusal::Untraced),
                    }
                }
            };
            imp.editing.states.borrow_mut().insert(index, state);
            self.refresh_result_page(index);
        }
    }

    fn read_target_columns(&self, run: u64, index: usize, source: ResultSource) {
        let Some(deps) = self.deps() else {
            return;
        };
        let Some(session) = deps.session.get() else {
            return;
        };
        let editor = self.downgrade();
        let table = source.table.clone();
        let _read = crate::runtime::spawn_and_deliver(
            &deps.tasks,
            load_columns(session, table, ColumnFreshness::Refetch),
            move |reply| {
                let Some(editor) = editor.upgrade() else {
                    return;
                };
                let catalog = reply.ok().and_then(Result::ok);
                editor.on_target_columns(run, index, &source, catalog.as_deref());
            },
        );
    }

    // The run's one result takes the tracker the moment it proves editable; nothing else can hold it before the next run.
    fn on_target_columns(&self, run: u64, index: usize, source: &ResultSource, catalog: Option<&[ColumnInfo]>) {
        let imp = self.imp();
        if imp.editing.run.get() != run {
            return;
        }
        let state = {
            let mut log = imp.log.borrow_mut();
            let Some(result) = log.as_mut().and_then(|log| log.result_mut(index)) else {
                return;
            };
            match catalog {
                None => ResultEdit::Locked(ResultRefusal::ColumnsUnread),
                Some(catalog) => match result_target(source, &result.columns, catalog) {
                    Err(lock) => ResultEdit::Locked(lock.into()),
                    Ok(target) => {
                        let target = edit_target(&target.table, &result.columns, &target.positions, catalog);
                        match key_masked(&target, &result.masks) {
                            true => ResultEdit::Locked(ResultRefusal::MaskedKey),
                            false => {
                                result.rows = typed_rows(&target, &result.columns, std::mem::take(&mut result.rows));
                                ResultEdit::Editable(Rc::new(target))
                            }
                        }
                    }
                },
            }
        };
        if let (ResultEdit::Editable(target), Some(tracker)) = (&state, self.row_tracker()) {
            let _ = tracker.discard();
            let _ = tracker.set_target(SaveTarget {
                table: target.table.clone(),
                columns: target.save_columns.clone(),
            });
            imp.editing.owner.set(Some(index));
        }
        imp.editing.states.borrow_mut().insert(index, state);
        self.refresh_result_page(index);
    }

    pub(super) fn result_grid(&self, index: usize, view: &ResultSetView) -> Option<ResultGrid> {
        let editing = &self.imp().editing;
        let tracker = self.row_tracker()?;
        let state = editing.states.borrow().get(&index).cloned();
        let target = match state? {
            ResultEdit::Locked(refusal) => return Some(ResultGrid::read_only(view, Some(refusal))),
            ResultEdit::Checking => return Some(ResultGrid::read_only(view, Some(ResultRefusal::Checking))),
            ResultEdit::Editable(target) => target,
        };
        Some(ResultGrid {
            columns: target.grid_columns.clone(),
            masks: view.masks.clone(),
            rows: editable_rows(&target, view),
            rules: Some(EditRules {
                identity: target.identity.clone(),
                policy: self.result_policy(&target),
            }),
            tracker: Some(tracker),
            table: Some(target.table.clone()),
            result_lock: None,
        })
    }

    fn result_policy(&self, target: &EditTarget) -> EditPolicy {
        match self.imp().editing.saving.get() {
            true => saving_policy(),
            false => EditPolicy {
                duplicate: match target.copyable.get() {
                    true => Ok(()),
                    false => Err(EditRefusal::NotCopyable),
                },
                ..edit_policy(false, true, true)
            },
        }
    }

    fn follow_saving(&self, saving: bool) {
        let editing = &self.imp().editing;
        editing.saving.set(saving);
        let target = match editing
            .owner
            .get()
            .and_then(|owner| editing.states.borrow().get(&owner).cloned())
        {
            Some(ResultEdit::Editable(target)) => target,
            _ => return,
        };
        if let Some(grid) = self.owner_grid() {
            grid.edit().set_rules(
                &grid,
                Some(EditRules {
                    identity: target.identity.clone(),
                    policy: self.result_policy(&target),
                }),
            );
            grid.refresh_actions();
            grid.redraw();
        }
    }

    pub(super) fn refresh_result_page(&self, index: usize) {
        let Ok(page) = u32::try_from(index) else {
            return;
        };
        let results = &self.imp().results;
        if results.selected() == Some(page) {
            results.rebuild_page(page);
        } else {
            results.forget_pages(|kept| kept == page);
        }
    }

    // A key column a saved rule now masks names no row, so the result stops editing; its pending changes keep their keys.
    pub(super) fn lock_masked_key(&self, index: usize) {
        let imp = self.imp();
        let masked = {
            let states = imp.editing.states.borrow();
            let Some(ResultEdit::Editable(target)) = states.get(&index) else {
                return;
            };
            let log = imp.log.borrow();
            let Some(result) = log.as_ref().and_then(|log| log.result(index)) else {
                return;
            };
            key_masked(target, &result.masks)
        };
        if masked {
            imp.editing
                .states
                .borrow_mut()
                .insert(index, ResultEdit::Locked(ResultRefusal::MaskedKey));
        }
    }

    pub(super) fn on_rows_pending_changed(&self) {
        self.refresh_pending_bar();
    }

    pub(super) fn refresh_result_actions(&self) {
        let Some(actions) = self.imp().editing.actions.get() else {
            return;
        };
        let tracker = self.row_tracker();
        let grid = self.owner_grid();
        // Held while the run's result edits, whether or not it has changes, so Ctrl+S in the results never saves the file.
        actions.save.set_enabled(self.imp().editing.owner.get().is_some());
        let idle = grid.is_some()
            && tracker
                .as_ref()
                .is_some_and(|tracker| tracker.pending_state() != PendingState::Saving);
        actions.save_changes.set_enabled(
            !self.imp().editing.saving.get()
                && tracker.as_ref().is_some_and(|tracker| {
                    matches!(tracker.pending_state(), PendingState::Clean | PendingState::Unsaved)
                        && (tracker.pending_count() > 0 || grid.as_ref().is_some_and(DataGrid::is_editing))
                }),
        );
        actions
            .undo
            .set_enabled(idle && tracker.as_ref().is_some_and(TabTrackerHandle::can_undo));
        actions
            .redo
            .set_enabled(idle && tracker.as_ref().is_some_and(TabTrackerHandle::can_redo));
    }

    fn refresh_pending_bar(&self) {
        self.refresh_result_actions();
        let bar = self.imp().results.pending_bar();
        let count = self.row_tracker().map_or(0, |tracker| tracker.pending_count());
        if self.imp().editing.dirty.replace(count > 0) != (count > 0) {
            self.emit_by_name::<()>("rows-dirty-changed", &[]);
        }
        if count == 0
            && let Some(grid) = self.owner_grid()
        {
            crate::ui::a11y::pass_focus(&bar, &grid.column_view());
        }
        bar.show_pending(count);
    }

    fn on_pending_request(&self, request: PendingChangesRequest) {
        match request {
            PendingChangesRequest::Save => self.save_rows(),
            PendingChangesRequest::Discard => self.confirm_rows_discard(),
            PendingChangesRequest::StopSaving => self.emit_by_name::<()>("stop-saving-rows", &[]),
        }
    }

    pub(super) fn save_rows(&self) {
        if let Some(grid) = self.owner_grid() {
            grid.commit_edit();
        }
        let unsaved = self
            .row_tracker()
            .is_some_and(|tracker| tracker.pending_state() == PendingState::Unsaved && tracker.pending_count() > 0);
        if unsaved {
            self.emit_by_name::<()>("save-rows", &[]);
        }
    }

    fn confirm_rows_discard(&self) {
        let Some(tracker) = self.row_tracker() else {
            return;
        };
        if let Some(grid) = self.owner_grid() {
            grid.commit_edit();
        }
        let pending = tracker.pending_count();
        if pending == 0 {
            return;
        }
        let editor = self.downgrade();
        confirm_discard(
            self,
            pending,
            move || tracker.pending_state(),
            move || {
                if let Some(editor) = editor.upgrade() {
                    editor.discard_rows();
                }
            },
        );
    }

    // The owner's grid, built or not; the tracker's changes are drawn by no other.
    fn owner_grid(&self) -> Option<DataGrid> {
        let owner = u32::try_from(self.imp().editing.owner.get()?).ok()?;
        self.imp().results.kept_grid(owner)
    }

    // After a save whose outcome is unknown the rows on screen may not be what the table holds, so they are read again.
    fn discard_rows(&self) {
        if self
            .row_tracker()
            .is_some_and(|tracker| tracker.pending_state() == PendingState::Saving)
        {
            return;
        }
        let unknown = self
            .row_tracker()
            .is_some_and(|tracker| matches!(tracker.pending_state(), PendingState::OutcomeUnknown(_)));
        self.drop_rows();
        if unknown {
            self.reread_result();
        }
    }

    fn drop_rows(&self) {
        match self.owner_grid() {
            Some(grid) => {
                grid.discard();
                grid.resync();
            }
            None => {
                if let Some(tracker) = self.row_tracker() {
                    let _ = tracker.discard();
                }
            }
        }
        self.on_rows_pending_changed();
    }

    pub(crate) fn rows_save_started(&self) {
        self.imp().results.pending_bar().show_saving(true);
        self.follow_saving(true);
        self.refresh_result_actions();
    }

    fn rows_save_ended(&self) {
        self.imp().results.pending_bar().show_saving(false);
        self.follow_saving(false);
        self.refresh_pending_bar();
    }

    // The tracker let go of what the save wrote, and nothing changed while it ran, so the statement behind the result
    // runs again for what the server stored.
    pub(crate) fn rows_saved(&self) {
        self.rows_save_ended();
        self.reread_result();
    }

    pub(crate) fn rows_save_failed(&self, failing: Option<StatementSource>) {
        self.rows_save_ended();
        let grid = self.owner_grid();
        if let (Some(source), Some(tracker)) = (failing, self.row_tracker()) {
            let key = match source {
                StatementSource::Insert { draft_id } => RowKey::Draft(draft_id),
                StatementSource::Update { row_key } | StatementSource::Delete { row_key } => row_key,
            };
            let delta = tracker.mark_error_row(key.clone());
            if let Some(grid) = &grid {
                grid.apply_delta(&delta);
                grid.reveal_row(&key);
            }
        }
        if let Some(grid) = grid {
            grid.redraw();
        }
    }

    pub(crate) fn rows_save_unknown(&self) {
        self.rows_save_ended();
        if let Some(grid) = self.owner_grid() {
            grid.redraw();
        }
    }

    pub(crate) fn rows_discarded(&self, reload: bool) {
        if let Some(grid) = self.owner_grid() {
            grid.resync();
        }
        self.on_rows_pending_changed();
        if reload {
            self.reread_result();
        }
    }

    // An ordinary run of the result's statement, with its Stop, its Safe Mode and its result checked again from the start.
    fn reread_result(&self) {
        let imp = self.imp();
        let Some(owner) = imp.editing.owner.get() else {
            return;
        };
        let Some(statement) = imp
            .log
            .borrow()
            .as_ref()
            .and_then(|log| log.result(owner))
            .map(|result| result.statement.as_str().to_owned())
        else {
            return;
        };
        imp.editing.rereading.set(true);
        self.execute(ScopedText {
            text: statement,
            base_char: 0,
        });
        imp.editing.rereading.set(false);
    }
}

fn edit_target(
    table: &TableRef,
    result: &[ResultColumn],
    positions: &[Option<usize>],
    catalog: &[ColumnInfo],
) -> EditTarget {
    let save_columns: Vec<ColumnInfo> = result
        .iter()
        .zip(positions)
        .enumerate()
        .map(
            |(index, (column, position))| match position.and_then(|position| catalog.get(position)) {
                Some(info) => info.clone(),
                None => unwritable(index, column),
            },
        )
        .collect();
    // Every column carries its entry, a computed one generated, so pasting and deleting see the whole row.
    let grid_columns = result
        .iter()
        .zip(&save_columns)
        .enumerate()
        .map(|(index, (column, info))| GridColumn {
            index,
            name: column.name.clone(),
            column_type: column.column_type.clone(),
            catalog: Some(info.clone()),
            addressable: true,
        })
        .collect();
    EditTarget {
        table: table.clone(),
        identity: pk_identity(&save_columns),
        traced: positions.iter().map(Option::is_some).collect(),
        copyable: Cell::new(true),
        save_columns,
        grid_columns,
    }
}

// A NUL can't be in an identifier, so no key lookup by name ever lands on this column.
fn unwritable(index: usize, column: &ResultColumn) -> ColumnInfo {
    ColumnInfo {
        name: format!("\0{index}"),
        column_type: column.column_type.clone(),
        nullable: true,
        primary_key: false,
        is_auto_increment: false,
        is_generated: true,
        partition_scoped: false,
        default: ColumnDefault::None,
        comment: None,
    }
}

// PostgreSQL's editor reads text; keys and copied values have to be the columns' own types.
fn typed_rows(target: &EditTarget, read: &[ResultColumn], rows: Vec<Arc<[Value]>>) -> Vec<Arc<[Value]>> {
    let retyped = |value: &Value| matches!(value, Value::Text(_) | Value::Timestamp(_));
    if !rows.iter().flat_map(|row| row.iter()).any(retyped) {
        return rows;
    }
    rows.into_iter()
        .map(|row| {
            row.iter()
                .zip(read.iter().zip(target.save_columns.iter().zip(&target.traced)))
                .map(|(value, (read, (column, traced)))| match traced {
                    false => value.clone(),
                    true => value_for_column(value, &read.column_type, &column.column_type).unwrap_or_else(|| {
                        target.copyable.set(false);
                        value.clone()
                    }),
                })
                .collect()
        })
        .collect()
}

fn key_masked(target: &EditTarget, masks: &GridMasks) -> bool {
    (0..target.save_columns.len())
        .any(|index| target.traced[index] && target.save_columns[index].primary_key && masks.is_masked(index))
}

// A key value the column's type cannot take, such as a wall-clock TIMESTAMP, shows as read but names no row.
fn editable_rows(target: &EditTarget, view: &ResultSetView) -> Vec<RowData> {
    let width = target.save_columns.len();
    let layout = PageLayout {
        visible: 0..width,
        identity: width..width,
    };
    let keys = RowKeyBuilder::for_page(&target.identity, &target.save_columns, &layout);
    let key_columns: Vec<usize> = (0..width)
        .filter(|index| target.traced[*index] && target.save_columns[*index].primary_key)
        .collect();
    view.rows
        .iter()
        .map(|cells| {
            let bindable = key_columns.iter().all(|index| {
                let (Some(value), Some(read)) = (cells.get(*index), view.columns.get(*index)) else {
                    return false;
                };
                value_for_column(value, &read.column_type, &target.save_columns[*index].column_type).is_some()
            });
            let key = keys
                .as_ref()
                .filter(|_| bindable)
                .and_then(|keys| keys.key_for(cells, &[]));
            RowData::persisted(key, cells.clone())
        })
        .collect()
}

#[cfg(test)]
impl SqlEditor {
    // `Some(None)` once the result edits, `Some(Some(why))` while it does not.
    pub(super) fn result_refusal(&self, index: usize) -> Option<Option<ResultRefusal>> {
        match self.imp().editing.states.borrow().get(&index)? {
            ResultEdit::Locked(refusal) => Some(Some(*refusal)),
            ResultEdit::Checking => Some(Some(ResultRefusal::Checking)),
            ResultEdit::Editable(_) => Some(None),
        }
    }
}
