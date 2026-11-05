use std::cell::{Cell, OnceCell, RefCell};
use std::collections::{HashMap, HashSet};
use std::rc::Rc;
use std::sync::Arc;

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gio, glib};
use tablepro_core::browse::PageLayout;
use tablepro_core::column::{ColumnDefault, ColumnInfo, ResultColumn};
use tablepro_core::edit::{ResultSource, result_source, result_target, value_for_column};
use tablepro_core::meta::{RowIdentity, TableRef};
use tablepro_core::value::{UndecodableReason, UndecodedValue};
use tablepro_core::{RowLimit, Value};
use tokio_util::sync::CancellationToken;

use super::SqlEditor;
use super::run_log::{EntryKind, RunEvent, RunLog};
use super::script_runner::{RUN_ROW_LIMIT, RunBatch, ScriptRun, run_in_tab};
use crate::application::{ShortcutOwner, local_shortcut_controller};
use crate::services::change_tracker::{RowKey, StatementSource, pk_identity};
use crate::services::grid::{GridColumn, ResultRefusal, RowKeyBuilder, edit_policy};
use crate::services::save_batch::SaveTarget;
use crate::services::tab_tracker_handle::TabTrackerHandle;
use crate::ui::browse_tab::{ColumnFreshness, PendingChangesRequest, load_columns};
use crate::ui::data_grid::{EditRules, RowData};
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
    grid_columns: Arc<[GridColumn]>,
    identity: RowIdentity,
}

#[derive(Debug)]
struct ResultActions {
    save: gio::SimpleAction,
    undo: gio::SimpleAction,
    redo: gio::SimpleAction,
}

#[derive(Debug, Default)]
pub struct ResultEditing {
    tracker: OnceCell<TabTrackerHandle>,
    actions: OnceCell<ResultActions>,
    states: RefCell<HashMap<usize, ResultEdit>>,
    // The result whose target the tracker holds, and that target.
    owner: Cell<Option<usize>>,
    bound: RefCell<Option<Rc<EditTarget>>>,
    built_editable: RefCell<HashSet<usize>>,
    // Bumped by every run, so a catalog read for an older one is dropped.
    run: Cell<u64>,
    rereading: Cell<bool>,
    dirty: Cell<bool>,
    // A result read after a USE in the same run came from a database the tab may have left again.
    moves_database: Cell<bool>,
}

impl SqlEditor {
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

    fn row_tracker(&self) -> Option<TabTrackerHandle> {
        self.imp().editing.tracker.get().cloned()
    }

    pub(super) fn note_run_moves_database(&self, moves: bool) {
        self.imp().editing.moves_database.set(moves);
    }

    // The rows of the last run are about to be replaced, which the caller made sure loses no change.
    pub(super) fn forget_result_edits(&self) {
        let editing = &self.imp().editing;
        editing.run.set(editing.run.get().wrapping_add(1));
        editing.states.borrow_mut().clear();
        editing.built_editable.borrow_mut().clear();
        editing.owner.set(None);
        editing.bound.replace(None);
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
        if let Some(grid) = self.imp().results.shown_grid() {
            grid.commit_edit();
        }
        if self.imp().editing.rereading.get() || tracker.pending_state() == PendingState::Saving {
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
        confirm_discard(self, pending.max(1), move || {
            if let Some(editor) = editor.upgrade() {
                editor.discard_rows();
                then(&editor);
            }
        });
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
        let common = if session.read_only() {
            Some(ResultRefusal::ReadOnlySession)
        } else if imp.open_transaction.get().is_some() {
            Some(ResultRefusal::OpenTransaction)
        } else if self.tab_database().is_some() || imp.editing.moves_database.get() {
            Some(ResultRefusal::OtherDatabase)
        } else {
            None
        };
        let grammar = self.grammar();
        // A shell's documents or a key store's replies are not a table's rows; the row details say so already.
        if !grammar.is_sql() {
            return;
        }
        let mut checks = Vec::new();
        {
            let log = imp.log.borrow();
            let Some(log) = log.as_ref() else {
                return;
            };
            let mut states = imp.editing.states.borrow_mut();
            for (index, entry) in log.entries().iter().enumerate() {
                let EntryKind::ResultSet(result) = &entry.kind else {
                    continue;
                };
                let state = match common {
                    Some(refusal) => ResultEdit::Locked(refusal),
                    None => match result_source(result.statement.as_str(), grammar, &result.columns) {
                        Ok(source) => {
                            checks.push((index, source));
                            ResultEdit::Checking
                        }
                        Err(lock) => ResultEdit::Locked(lock.into()),
                    },
                };
                states.insert(index, state);
            }
        }
        let run = imp.editing.run.get();
        for (index, source) in checks {
            self.read_target_columns(run, index, source);
        }
        self.sync_shown_page();
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
                        result.rows = typed_rows(&target, &result.columns, std::mem::take(&mut result.rows));
                        ResultEdit::Editable(Rc::new(target))
                    }
                },
            }
        };
        let state = self.keep_tracker_on(index, state);
        imp.editing.states.borrow_mut().insert(index, state);
        self.refresh_result_page(index);
    }

    // The result read again after a save can name another table or other columns; the tracker follows only while it
    // holds nothing, since its changes were made on the rows read before.
    fn keep_tracker_on(&self, index: usize, state: ResultEdit) -> ResultEdit {
        let editing = &self.imp().editing;
        let (ResultEdit::Editable(target), Some(tracker)) = (&state, self.row_tracker()) else {
            return state;
        };
        if editing.owner.get() != Some(index) {
            return state;
        }
        let same = editing
            .bound
            .borrow()
            .as_ref()
            .is_some_and(|bound| bound.table == target.table && bound.save_columns == target.save_columns);
        if same {
            return state;
        }
        if tracker.pending_count() == 0 && tracker.pending_state() == PendingState::Clean {
            self.bind_tracker(&tracker, target);
            return state;
        }
        ResultEdit::Locked(ResultRefusal::ColumnsChanged)
    }

    fn bind_tracker(&self, tracker: &TabTrackerHandle, target: &Rc<EditTarget>) {
        let _ = tracker.discard();
        let _ = tracker.set_target(SaveTarget {
            table: target.table.clone(),
            columns: target.save_columns.clone(),
        });
        self.imp().editing.bound.replace(Some(target.clone()));
    }

    pub(super) fn result_grid(&self, index: usize, view: &ResultSetView) -> Option<ResultGrid> {
        let editing = &self.imp().editing;
        let tracker = self.row_tracker()?;
        let state = editing.states.borrow().get(&index).cloned();
        editing.built_editable.borrow_mut().remove(&index);
        let target = match state? {
            ResultEdit::Locked(refusal) => return Some(ResultGrid::read_only(view, Some(refusal))),
            ResultEdit::Checking => return Some(ResultGrid::read_only(view, Some(ResultRefusal::Checking))),
            ResultEdit::Editable(target) => target,
        };
        if editing.owner.get() != Some(index) {
            return Some(ResultGrid::read_only(view, Some(ResultRefusal::OtherResult)));
        }
        editing.built_editable.borrow_mut().insert(index);
        Some(ResultGrid {
            columns: target.grid_columns.clone(),
            rows: editable_rows(&target, view),
            rules: Some(EditRules {
                identity: target.identity.clone(),
                policy: edit_policy(false, true, true),
            }),
            tracker: Some(tracker),
            table: Some(target.table.clone()),
            result_lock: None,
        })
    }

    // Before a result's page shows: an editable result takes the tracker when no other result holds changes.
    pub(super) fn on_result_shown(&self, index: u32) {
        let Ok(index) = usize::try_from(index) else {
            return;
        };
        let Some(tracker) = self.row_tracker() else {
            return;
        };
        let editing = &self.imp().editing;
        let target = match editing.states.borrow().get(&index) {
            Some(ResultEdit::Editable(target)) => target.clone(),
            _ => return,
        };
        let clean = tracker.pending_state() == PendingState::Clean && tracker.pending_count() == 0;
        let owner = editing.owner.get();
        if owner == Some(index) || !clean {
            // A page built for another owner, or before this one owned the tracker, is stale.
            let stale = (owner == Some(index)) != editing.built_editable.borrow().contains(&index);
            if stale {
                self.imp().results.forget_pages(|page| page as usize == index);
            }
            return;
        }
        self.bind_tracker(&tracker, &target);
        editing.owner.set(Some(index));
        let built: Vec<usize> = editing.built_editable.borrow().iter().copied().collect();
        self.imp().results.forget_pages(|page| {
            let page = page as usize;
            page == index || built.contains(&page)
        });
        editing.built_editable.borrow_mut().clear();
    }

    fn refresh_result_page(&self, index: usize) {
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

    // Who owns the tracker can change only while it is clean, which a save, a discard or an undo brings back.
    pub(super) fn sync_shown_page(&self) {
        let results = &self.imp().results;
        if let Some(page) = results.selected() {
            results.rebuild_page(page);
        }
        self.refresh_pending_bar();
    }

    pub(super) fn on_rows_pending_changed(&self) {
        self.refresh_pending_bar();
        let Some(tracker) = self.row_tracker() else {
            return;
        };
        let clean = tracker.pending_count() == 0 && tracker.pending_state() == PendingState::Clean;
        let shown = self
            .imp()
            .results
            .selected()
            .and_then(|page| usize::try_from(page).ok());
        if clean && shown.is_some() && shown != self.imp().editing.owner.get() {
            self.sync_shown_page();
        }
    }

    pub(super) fn refresh_result_actions(&self) {
        let Some(actions) = self.imp().editing.actions.get() else {
            return;
        };
        let tracker = self.row_tracker();
        let grid = self.owner_grid();
        let unsaved = tracker
            .as_ref()
            .is_some_and(|tracker| tracker.pending_state() == PendingState::Unsaved);
        let editing = grid.as_ref().is_some_and(crate::ui::data_grid::DataGrid::is_editing);
        actions.save.set_enabled(unsaved || editing);
        let idle = grid.is_some()
            && tracker
                .as_ref()
                .is_some_and(|tracker| tracker.pending_state() != PendingState::Saving);
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
            && let Some(grid) = self.imp().results.shown_grid()
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
        if let Some(grid) = self.imp().results.shown_grid() {
            grid.commit_edit();
        }
        if self.row_tracker().is_some_and(|tracker| tracker.pending_count() > 0) {
            self.emit_by_name::<()>("save-rows", &[]);
        }
    }

    fn confirm_rows_discard(&self) {
        let Some(tracker) = self.row_tracker() else {
            return;
        };
        if let Some(grid) = self.imp().results.shown_grid() {
            grid.commit_edit();
        }
        let pending = tracker.pending_count();
        if pending == 0 {
            return;
        }
        let editor = self.downgrade();
        confirm_discard(self, pending, move || {
            if let Some(editor) = editor.upgrade() {
                editor.discard_rows();
            }
        });
    }

    // The grid on screen when it is the one the tracker's changes belong to.
    fn owner_grid(&self) -> Option<crate::ui::data_grid::DataGrid> {
        let editing = &self.imp().editing;
        let owner = editing.owner.get()?;
        let shown = usize::try_from(self.imp().results.selected()?).ok()?;
        (shown == owner && editing.built_editable.borrow().contains(&owner))
            .then(|| self.imp().results.shown_grid())
            .flatten()
    }

    fn discard_rows(&self) {
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
        if let Some(grid) = self.owner_grid() {
            grid.redraw();
        }
    }

    fn rows_save_ended(&self) {
        self.imp().results.pending_bar().show_saving(false);
    }

    // The tracker let go of what the save wrote; the statement behind the result is read again for what the server stored.
    pub(crate) fn rows_saved(&self) {
        self.rows_save_ended();
        self.refresh_pending_bar();
        if let Some(index) = self.imp().editing.owner.get() {
            self.reread_result(index);
        }
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
        if let (true, Some(index)) = (reload, self.imp().editing.owner.get()) {
            self.reread_result(index);
        }
    }

    fn reread_result(&self, index: usize) {
        let imp = self.imp();
        let Some(deps) = self.deps() else {
            return;
        };
        let Some(session) = deps.session.get() else {
            return;
        };
        let Some(statement) = imp
            .log
            .borrow()
            .as_ref()
            .and_then(|log| log.result(index))
            .map(|result| result.statement.clone())
        else {
            return;
        };
        imp.editing.rereading.set(true);
        imp.results.set_running(true);
        let run = ScriptRun {
            batches: vec![RunBatch {
                text: statement.as_str().to_owned(),
                repeat: 1,
                error_base: 0,
                refused: false,
            }],
            policy: tablepro_core::sql_syntax::script::BatchErrorPolicy::StopScript,
            statement_timeout: session
                .workspace_settings()
                .editor_timeout
                .resolve(deps.settings.query_timeout()),
            row_limit: RowLimit::EDITOR_DEFAULT,
            run_row_limit: RUN_ROW_LIMIT,
        };
        let (events, mut received) = tokio::sync::mpsc::channel(8);
        drop(deps.tasks.spawn_task(run_in_tab(
            session,
            imp.slot.clone(),
            run,
            deps.close_timeout,
            CancellationToken::new(),
            events,
        )));
        let editor = self.downgrade();
        let reread_run = imp.editing.run.get();
        glib::spawn_future_local(async move {
            let mut log = RunLog::new(vec![statement], Vec::new());
            while let Some(event) = received.recv().await {
                let finished = matches!(event, RunEvent::Finished);
                log.apply(event);
                if finished {
                    break;
                }
            }
            if let Some(editor) = editor.upgrade() {
                editor.on_reread(reread_run, index, log.first_result());
            }
        });
    }

    fn on_reread(&self, run: u64, index: usize, result: Option<ResultSetView>) {
        let imp = self.imp();
        imp.editing.rereading.set(false);
        imp.results.set_running(self.is_running());
        if imp.editing.run.get() != run {
            return;
        }
        let target = match imp.editing.states.borrow().get(&index) {
            Some(ResultEdit::Editable(target)) => Some(target.clone()),
            _ => None,
        };
        let read = {
            let mut log = imp.log.borrow_mut();
            let shown = log.as_mut().and_then(|log| log.result_mut(index));
            match (shown, result) {
                // The same columns from the same table: the rows change in place, and the grid keeps its place.
                (Some(shown), Some(result)) if target.is_some() && shown.columns == result.columns => {
                    if let Some(target) = &target {
                        shown.rows = typed_rows(target, &result.columns, result.rows);
                        shown.summary = result.summary;
                    }
                    None
                }
                (Some(shown), Some(result)) => {
                    let columns: Arc<[ResultColumn]> = result.columns.clone();
                    let source = result_source(shown.statement.as_str(), self.grammar(), &columns);
                    shown.columns = result.columns;
                    shown.rows = result.rows;
                    shown.summary = result.summary;
                    Some(Some(source))
                }
                _ => Some(None),
            }
        };
        let Some(read) = read else {
            if let (Some(target), Some(grid)) = (target, self.owner_grid()) {
                let rows = imp
                    .log
                    .borrow()
                    .as_ref()
                    .and_then(|log| log.result(index))
                    .map(|view| editable_rows(&target, view));
                if let Some(rows) = rows {
                    grid.replace_rows(rows, 0);
                }
            }
            return;
        };
        let state = match read {
            Some(Ok(source)) => {
                self.read_target_columns(run, index, source);
                ResultEdit::Checking
            }
            Some(Err(lock)) => ResultEdit::Locked(lock.into()),
            None => ResultEdit::Locked(ResultRefusal::ColumnsChanged),
        };
        imp.editing.states.borrow_mut().insert(index, state);
        self.refresh_result_page(index);
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
    let grid_columns = result
        .iter()
        .zip(positions)
        .enumerate()
        .map(|(index, (column, position))| GridColumn {
            index,
            name: column.name.clone(),
            column_type: column.column_type.clone(),
            catalog: position.and_then(|position| catalog.get(position)).cloned(),
            addressable: true,
        })
        .collect();
    EditTarget {
        table: table.clone(),
        identity: pk_identity(&save_columns),
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
    if !rows
        .iter()
        .flat_map(|row| row.iter())
        .any(|value| matches!(value, Value::Text(_)))
    {
        return rows;
    }
    rows.into_iter()
        .map(|row| {
            row.iter()
                .zip(read.iter().zip(&target.save_columns))
                .map(|(value, (read, column))| match column.is_generated {
                    true => value.clone(),
                    false => match value_for_column(value, &read.column_type, &column.column_type) {
                        Some(typed) => typed,
                        None if column.primary_key => Value::Undecodable(Box::new(UndecodedValue {
                            type_name: column.column_type.name.clone(),
                            reason: UndecodableReason::InvalidEncoding,
                        })),
                        None => value.clone(),
                    },
                })
                .collect()
        })
        .collect()
}

fn editable_rows(target: &EditTarget, view: &ResultSetView) -> Vec<RowData> {
    let width = target.save_columns.len();
    let layout = PageLayout {
        visible: 0..width,
        identity: width..width,
    };
    let keys = RowKeyBuilder::for_page(&target.identity, &target.save_columns, &layout);
    view.rows
        .iter()
        .map(|cells| {
            let key = keys.as_ref().and_then(|keys| keys.key_for(cells, &[]));
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
