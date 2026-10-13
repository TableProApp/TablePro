use std::rc::Rc;

use gtk4::prelude::*;
use gtk4::{self as gtk, glib};

use tablepro_core::column::ResultColumn;
use tablepro_core::{ColumnInfo, QueryResult};

use super::cell_editability::column_takes_edits;
use super::cell_editor_kind::{CellEditorKind, classify_editor_kind, is_bool_type};
use super::column_drawing::ColumnDrawing;
use super::context_menu::{CellMenuTarget, attach_cell_gesture};
use super::grid_menus::{GridMenuInit, GridMenus, install_grid_context_menus};
use super::inline_edit::{install_edit_commit_handler, install_edit_triggers};
use super::{CellEditor, GridCell, GridMsg, GridSink, RowObject, TabGridContext};

const WIDE_TABLE_THRESHOLD: usize = 8;
/// About 14 characters at the default font size.
const MIN_COLUMN_WIDTH_PX: i32 = 120;

pub fn build_column_view(
    result: &QueryResult,
    rows: impl IntoIterator<Item = RowObject>,
    schema_columns: &[ColumnInfo],
    sink: GridSink,
    sort: Option<(usize, bool)>,
    sortable: bool,
    tab_ctx: TabGridContext,
) -> (gtk::ColumnView, gtk::MultiSelection) {
    let store = gtk4::gio::ListStore::new::<RowObject>();
    for row in rows {
        store.append(&row);
    }
    let selection = gtk::MultiSelection::new(Some(store));
    let column_view = gtk::ColumnView::builder()
        .model(&selection)
        .show_row_separators(true)
        .show_column_separators(true)
        .build();

    let grid_menus = install_grid_context_menus(GridMenuInit {
        column_view: &column_view,
        sink: sink.clone(),
        columns: result.columns.clone(),
        truncated: result.truncated,
        tab_ctx: tab_ctx.clone(),
    });

    // Sharing the viewport by `expand` alone leaves a wide table with 20
    // to 30 px columns that show nothing, so a column with no saved width
    // starts at a readable minimum there.
    let default_min_width = if result.columns.len() > WIDE_TABLE_THRESHOLD {
        Some(MIN_COLUMN_WIDTH_PX)
    } else {
        None
    };
    let mut columns: Vec<gtk::ColumnViewColumn> = Vec::with_capacity(result.columns.len());
    for (i, column) in result.columns.iter().enumerate() {
        let col = build_column(ColumnInit {
            info: column,
            idx: i,
            catalog: schema_columns.get(i).cloned(),
            sink: sink.clone(),
            sortable,
            tab_ctx: tab_ctx.clone(),
            default_min_width,
            column_view: column_view.downgrade(),
            grid_menus: grid_menus.clone(),
        });
        column_view.append_column(&col);
        columns.push(col);
    }

    // Applied before the notify handlers are wired, so it does not echo
    // back as a SortChanged.
    if let Some((col_idx, ascending)) = sort
        && let Some(col) = columns.get(col_idx)
    {
        let direction = if ascending {
            gtk::SortType::Ascending
        } else {
            gtk::SortType::Descending
        };
        column_view.sort_by_column(Some(col), direction);
    }

    if sortable
        && let Some(view_sorter) = column_view
            .sorter()
            .and_then(|s| s.downcast::<gtk::ColumnViewSorter>().ok())
    {
        // A second click on the same column flips only
        // `primary-sort-order`, so both notifies are wired. Each sends the
        // sorter's post-click pair, which the receiver drops when it
        // already matches.
        let dispatch = {
            let sink = sink.clone();
            let columns = columns.clone();
            move |sorter: &gtk::ColumnViewSorter| {
                let Some(active) = sorter.primary_sort_column() else {
                    return;
                };
                let ascending = matches!(sorter.primary_sort_order(), gtk::SortType::Ascending);
                if let Some(idx) = columns.iter().position(|col| col == &active) {
                    sink(GridMsg::SortChanged(idx, ascending));
                }
            }
        };
        view_sorter.connect_primary_sort_column_notify({
            let dispatch = dispatch.clone();
            move |sorter| dispatch(sorter)
        });
        view_sorter.connect_primary_sort_order_notify(move |sorter| dispatch(sorter));
    }

    (column_view, selection)
}

/// How a column's cells are built. A column no row can edit gets the
/// plain label a read-only grid has.
#[derive(Clone, Copy)]
enum CellKind {
    ReadOnly,
    Toggle,
    Text(CellEditorKind),
}

struct ColumnInit<'a> {
    info: &'a ResultColumn,
    idx: usize,
    /// `None` for a column the grid knows only from the result set.
    catalog: Option<ColumnInfo>,
    sink: GridSink,
    sortable: bool,
    tab_ctx: TabGridContext,
    default_min_width: Option<i32>,
    column_view: glib::WeakRef<gtk::ColumnView>,
    grid_menus: GridMenus,
}

fn build_column(init: ColumnInit<'_>) -> gtk::ColumnViewColumn {
    let ColumnInit {
        info,
        idx,
        catalog,
        sink,
        sortable,
        tab_ctx,
        default_min_width,
        column_view,
        grid_menus,
    } = init;
    let factory = gtk::SignalListItemFactory::new();

    let kind = match catalog.as_ref() {
        Some(column) if tab_ctx.editable && column_takes_edits(column, &tab_ctx.identity, false) => {
            if is_bool_type(&info.column_type.name) {
                CellKind::Toggle
            } else {
                CellKind::Text(classify_editor_kind(&info.column_type.name))
            }
        }
        _ => CellKind::ReadOnly,
    };
    let auto_filled = catalog
        .as_ref()
        .is_some_and(|column| column.is_auto_increment || column.is_generated);
    let drawing = Rc::new(ColumnDrawing {
        catalog,
        tab_ctx: tab_ctx.clone(),
        auto_filled,
    });
    let target = CellMenuTarget {
        text_editable: matches!(kind, CellKind::Text(_)),
        accepts_empty: matches!(kind, CellKind::Text(_)) && info.column_type.kind.accepts_empty_string(),
    };

    factory.connect_setup(move |_, item| {
        let Some(cell) = item.downcast_ref::<gtk::ColumnViewCell>() else {
            return;
        };
        let grid_cell = GridCell::new();
        grid_cell.attach(cell, idx);
        grid_cell.set_drawing(drawing.clone());
        match kind {
            CellKind::ReadOnly => setup_readonly_cell(&grid_cell),
            CellKind::Toggle => setup_toggle_cell(&grid_cell, sink.clone()),
            CellKind::Text(editor_kind) => setup_editable_cell(&grid_cell, sink.clone(), editor_kind),
        }
        attach_cell_gesture(&grid_cell, &column_view, target, &grid_menus);
        cell.set_child(Some(&grid_cell));
    });

    factory.connect_bind(|_, item| {
        let Some(cell) = item.downcast_ref::<gtk::ColumnViewCell>() else {
            return;
        };
        if let (Some(row), Some(grid_cell)) = (
            cell.item().and_downcast::<RowObject>(),
            cell.child().and_downcast::<GridCell>(),
        ) {
            grid_cell.bind(&row);
        }
    });

    factory.connect_unbind(|_, item| {
        if let Some(grid_cell) = item
            .downcast_ref::<gtk::ColumnViewCell>()
            .and_then(|cell| cell.child())
            .and_downcast::<GridCell>()
        {
            grid_cell.unbind();
        }
    });

    let column = gtk::ColumnViewColumn::builder()
        .title(&info.name)
        .factory(&factory)
        .resizable(true)
        .expand(true)
        .build();
    if sortable {
        let dummy = gtk::CustomSorter::new(|_, _| gtk::Ordering::Equal);
        column.set_sorter(Some(&dummy));
    }
    if let Some(widths) = tab_ctx.column_widths.clone() {
        if let Some(saved) = widths.width(&info.name) {
            column.set_fixed_width(saved);
        } else if let Some(min) = default_min_width {
            column.set_fixed_width(min);
        }
        let column_name = info.name.clone();
        column.connect_fixed_width_notify(move |column| {
            widths.record(&column_name, column.fixed_width());
        });
    } else if let Some(min) = default_min_width {
        // Editor results remember no widths, but can be just as wide.
        column.set_fixed_width(min);
    }
    column
}

fn setup_editable_cell(grid_cell: &GridCell, sink: GridSink, editor_kind: CellEditorKind) {
    let editor = CellEditor::new();
    editor.set_hexpand(true);
    editor.set_margin_start(8);
    editor.set_margin_end(8);
    grid_cell.set_content(&editor);
    install_edit_commit_handler(grid_cell, sink.clone());
    install_edit_triggers(grid_cell, sink, editor_kind);
}

fn setup_toggle_cell(grid_cell: &GridCell, sink: GridSink) {
    let checkbox = gtk::CheckButton::builder()
        .halign(gtk::Align::Start)
        .valign(gtk::Align::Center)
        .margin_start(8)
        .margin_end(8)
        .build();
    grid_cell.set_content(&checkbox);
    // The cell owns the check button, so the handler finds the cell
    // through its parent rather than holding it.
    checkbox.connect_toggled(move |checkbox| {
        let Some(grid_cell) = checkbox.parent().and_downcast::<GridCell>() else {
            return;
        };
        if grid_cell.toggle_suppressed() || grid_cell.lock().is_some() {
            return;
        }
        let Some(row) = grid_cell.row() else {
            return;
        };
        let input = if checkbox.is_active() { "true" } else { "false" };
        sink(GridMsg::CellEdited {
            row,
            column: grid_cell.column(),
            input: input.to_owned(),
        });
    });
}

fn setup_readonly_cell(grid_cell: &GridCell) {
    let label = gtk::Label::builder()
        .xalign(0.0)
        .hexpand(true)
        .selectable(true)
        .ellipsize(gtk::pango::EllipsizeMode::End)
        .margin_start(8)
        .margin_end(8)
        .build();
    grid_cell.set_content(&label);
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::rc::Rc;
    use std::time::Duration;

    use gtk4::prelude::*;
    use gtk4::{self as gtk, gio, glib};

    use tablepro_core::meta::RowIdentity;
    use tablepro_core::{ColumnInfo, QueryResult, Value};

    use super::build_column_view;
    use crate::services::change_tracker::RowKey;
    use crate::services::tab_tracker_handle::TabTrackerHandle;
    use crate::services::tracker_delta::{TrackerDelta, VisualChange};
    use crate::services::tracker_edit::TrackerEdit;
    use crate::test_support::{descendants, drain_main_context, wait_until};
    use crate::ui::grid::cell_editability::column_takes_edits;
    use crate::ui::grid::display_text::editable_null_sentinel;
    use crate::ui::grid::{
        CellEditor, CellPreset, ColumnWidthBinding, GridCell, GridMsg, GridSink, RowObject, TabGridContext,
        enter_edit_mode,
    };

    const WAIT: Duration = Duration::from_secs(5);

    #[expect(
        clippy::disallowed_methods,
        reason = "a test fixture stands in for the catalogue, which is where this text comes from in production"
    )]
    fn col(data_type: &str, primary_key: bool) -> ColumnInfo {
        let kind = tablepro_core::column::classify_type_name(data_type);
        ColumnInfo {
            name: "x".into(),
            column_type: tablepro_core::column::ColumnType {
                name: data_type.to_owned(),
                dynamic_storage: tablepro_core::column::has_dynamic_storage(&kind),
                kind,
                catalog: Some(tablepro_core::column::CatalogType {
                    declaration: tablepro_core::column::SqlTypeExpr::from_catalog_text(data_type),
                    cast_target: tablepro_core::column::SqlTypeExpr::from_catalog_text(data_type),
                }),
                read_form: tablepro_core::column::ReadForm::Native,
            },
            nullable: true,
            primary_key,
            is_auto_increment: false,
            is_generated: false,
            default: tablepro_core::column::ColumnDefault::None,
            comment: None,
        }
    }

    fn named(name: &str, data_type: &str, primary_key: bool) -> ColumnInfo {
        let mut column = col(data_type, primary_key);
        column.name = name.to_owned();
        column
    }

    fn key(id: i64) -> RowKey {
        RowKey::from_pk_values(&[Value::Int(id)]).expect("a key")
    }

    fn keyed_by_id() -> RowIdentity {
        RowIdentity::UniqueKey {
            columns: vec!["id".to_owned()],
        }
    }

    fn tracked(tracker: &TabTrackerHandle) -> TabGridContext {
        TabGridContext {
            tracker: Some(tracker.clone()),
            editable: true,
            identity: keyed_by_id(),
            column_widths: None,
        }
    }

    /// Persisted rows keyed by their first cell, as a browse page is.
    fn persisted(rows: &[Vec<Value>]) -> Vec<RowObject> {
        rows.iter()
            .map(|cells| {
                let id = cells.first().cloned().unwrap_or(Value::Null);
                RowObject::persisted(RowKey::from_pk_values(&[id]), cells.clone().into())
            })
            .collect()
    }

    fn recorder() -> (GridSink, Rc<RefCell<Vec<GridMsg>>>) {
        let messages = Rc::new(RefCell::new(Vec::new()));
        let log = messages.clone();
        (Rc::new(move |msg| log.borrow_mut().push(msg)), messages)
    }

    struct Grid {
        window: gtk::Window,
        view: gtk::ColumnView,
        store: gio::ListStore,
        tracker: TabTrackerHandle,
        messages: Rc<RefCell<Vec<GridMsg>>>,
    }

    impl Grid {
        /// Two rows, A (id 1) and B (id 2), in a grid that edits them.
        fn open(columns: Vec<ColumnInfo>, rows: Vec<Vec<Value>>) -> Self {
            let result = QueryResult::new(
                columns.iter().map(ColumnInfo::result_column).collect::<Vec<_>>(),
                rows.clone(),
            );
            let tracker = TabTrackerHandle::default();
            let (sink, messages) = recorder();
            let (view, selection) = build_column_view(
                &result,
                persisted(&rows),
                &columns,
                sink,
                None,
                false,
                tracked(&tracker),
            );
            let store = selection
                .model()
                .and_downcast::<gio::ListStore>()
                .expect("a list store");
            let window = gtk::Window::new();
            window.set_default_size(600, 400);
            window.set_child(Some(&view));
            window.present();
            let grid = Self {
                window,
                view,
                store,
                tracker,
                messages,
            };
            wait_until(WAIT, || grid.cells().len() == columns.len() * rows.len()).expect("the cells are drawn");
            grid
        }

        fn cells(&self) -> Vec<GridCell> {
            descendants(&self.view)
                .into_iter()
                .filter_map(|widget| widget.downcast::<GridCell>().ok())
                .filter(|cell| cell.row().is_some())
                .collect()
        }

        /// The cell that shows `column` of the row named `id`.
        fn cell_of(&self, id: i64, column: usize) -> GridCell {
            self.cells()
                .into_iter()
                .find(|cell| cell.column() == column && cell.row().is_some_and(|row| row.key() == Some(&key(id))))
                .expect("the row's cell is drawn")
        }

        fn insert_draft(&self) {
            let delta = self.tracker.apply(TrackerEdit::Insert {
                values: vec![Value::Null, Value::Null],
            });
            let Some(VisualChange::InsertDraft { draft_id }) = delta.visual.into_iter().next() else {
                panic!("an insert adds a draft row");
            };
            self.store.insert(0, &RowObject::draft(draft_id));
            drain_main_context();
        }

        fn column(&self, index: u32) -> gtk::ColumnViewColumn {
            self.view
                .columns()
                .item(index)
                .and_downcast::<gtk::ColumnViewColumn>()
                .expect("a column")
        }

        fn take_messages(&self) -> Vec<GridMsg> {
            self.messages.take()
        }

        /// What the tab does with a tracker change.
        fn redraw(&self, delta: &TrackerDelta) {
            for position in 0..self.store.n_items() {
                if let Some(row) = self.store.item(position).and_downcast::<RowObject>()
                    && row.id().tracker_key().is_some_and(|key| delta.rows.contains(&key))
                {
                    row.bump_revision();
                }
            }
        }
    }

    impl Drop for Grid {
        fn drop(&mut self) {
            self.window.destroy();
            drain_main_context();
        }
    }

    fn two_text_rows() -> Grid {
        Grid::open(
            vec![named("id", "integer", true), named("name", "text", false)],
            vec![
                vec![Value::Int(1), Value::Text("A".into())],
                vec![Value::Int(2), Value::Text("B".into())],
            ],
        )
    }

    fn type_into(cell: &GridCell, text: &str) -> CellEditor {
        enter_edit_mode(cell);
        let editor = cell.editor().expect("a text cell");
        assert!(editor.is_editing(), "the cell did not open for editing");
        editor.entry().set_text(text);
        editor
    }

    fn edited_rows(messages: &[GridMsg]) -> Vec<(Option<RowKey>, usize, String)> {
        messages
            .iter()
            .filter_map(|msg| match msg {
                GridMsg::CellEdited { row, column, input } => Some((row.key().cloned(), *column, input.clone())),
                _ => None,
            })
            .collect()
    }

    /// Without focusable cells, which come with the grid's keyboard
    /// model, a grid cell takes the focus through its open editor.
    #[gtk4::test]
    fn edit_after_draft_insert_targets_edited_row() {
        let grid = two_text_rows();
        grid.insert_draft();
        grid.view
            .scroll_to(2, Some(&grid.column(1)), gtk::ListScrollFlags::FOCUS, None);

        let editor = type_into(&grid.cell_of(2, 1), "renamed");
        let mut focused = None;
        wait_until(WAIT, || {
            focused = gtk::prelude::GtkWindowExt::focus(&grid.window).and_then(|focus| GridCell::from_focus(&focus));
            focused.is_some()
        })
        .expect("the focused editor resolves to its grid cell");
        let cell = focused.expect("a focused cell");
        assert_eq!(cell.row().and_then(|row| row.key().cloned()), Some(key(2)));
        editor.stop_editing(true);

        assert_eq!(
            edited_rows(&grid.take_messages()),
            vec![(Some(key(2)), 1, "renamed".to_owned())]
        );
    }

    #[gtk4::test]
    fn menu_set_null_after_draft_removal_targets_clicked_row() {
        let grid = two_text_rows();
        grid.insert_draft();
        let cell = grid.cell_of(2, 1);
        let gesture = menu_gesture(cell.upcast_ref()).expect("a cell answers a right-click");
        gesture.emit_by_name::<()>("pressed", &[&1i32, &1.0f64, &1.0f64]);

        grid.store.remove(0);
        drain_main_context();
        grid.view
            .activate_action("cell.set-null", None)
            .expect("the menu's Set NULL");

        let set: Vec<(Option<RowKey>, usize, CellPreset)> = grid
            .take_messages()
            .iter()
            .filter_map(|msg| match msg {
                GridMsg::SetCellValue { row, column, preset } => Some((row.key().cloned(), *column, *preset)),
                _ => None,
            })
            .collect();
        assert_eq!(set, vec![(Some(key(2)), 1, CellPreset::Null)]);
    }

    #[gtk4::test]
    fn edit_started_before_rows_shift_commits_to_original_row() {
        let grid = two_text_rows();
        let cell = grid.cell_of(2, 1);
        let editor = type_into(&cell, "renamed");

        grid.insert_draft();
        editor.stop_editing(true);

        assert_eq!(
            edited_rows(&grid.take_messages()),
            vec![(Some(key(2)), 1, "renamed".to_owned())]
        );
    }

    #[gtk4::test]
    fn toggle_after_draft_insert_targets_toggled_row() {
        let grid = Grid::open(
            vec![named("id", "integer", true), named("flag", "boolean", false)],
            vec![
                vec![Value::Int(1), Value::Bool(true)],
                vec![Value::Int(2), Value::Bool(false)],
            ],
        );
        grid.insert_draft();
        let toggle = grid
            .cell_of(2, 1)
            .content()
            .and_then(|content| content.downcast_ref::<gtk::CheckButton>().cloned())
            .expect("a check button");

        toggle.set_active(true);

        assert_eq!(
            edited_rows(&grid.take_messages()),
            vec![(Some(key(2)), 1, "true".to_owned())]
        );
    }

    #[gtk4::test]
    fn a_saved_rows_key_is_locked_and_a_drafts_is_not() {
        let grid = two_text_rows();
        grid.insert_draft();
        let draft_key_cell = grid
            .cells()
            .into_iter()
            .find(|cell| cell.column() == 0 && cell.row().is_some_and(|row| row.draft_id().is_some()))
            .expect("the draft's key cell");

        assert!(
            grid.cell_of(1, 0).lock().is_some(),
            "a saved row's key was offered for editing"
        );
        assert!(grid.cell_of(1, 1).lock().is_none());
        assert!(draft_key_cell.lock().is_none(), "a draft could not set its own key");

        enter_edit_mode(&grid.cell_of(1, 0));
        assert!(!grid.cell_of(1, 0).editor().expect("a text cell").is_editing());
    }

    fn label_of(cell: &GridCell) -> gtk::Label {
        descendants(cell)
            .into_iter()
            .find_map(|widget| widget.downcast::<gtk::Label>().ok())
            .expect("a cell draws its value in a label")
    }

    #[gtk4::test]
    fn a_locked_key_cell_keeps_its_text_selectable() {
        let grid = two_text_rows();
        grid.insert_draft();
        let draft_key_cell = grid
            .cells()
            .into_iter()
            .find(|cell| cell.column() == 0 && cell.row().is_some_and(|row| row.draft_id().is_some()))
            .expect("the draft's key cell");

        assert!(
            label_of(&grid.cell_of(1, 0)).is_selectable(),
            "a saved row's key cannot be selected"
        );
        assert!(!label_of(&draft_key_cell).is_selectable());
        assert!(!label_of(&grid.cell_of(1, 1)).is_selectable());
    }

    #[gtk4::test]
    fn a_revision_bump_draws_the_pending_value_in_the_same_cell() {
        let grid = two_text_rows();
        let cell = grid.cell_of(1, 1);
        let delta = grid.tracker.apply(TrackerEdit::Cell {
            row_key: key(1),
            col: 1,
            original: Value::Text("A".into()),
            value: Value::Text("new".into()),
        });

        grid.store
            .item(0)
            .and_downcast::<RowObject>()
            .expect("a row")
            .bump_revision();

        assert_eq!(delta.pending_count, 1);
        assert_eq!(cell.editor().expect("a text cell").text(), "new");
        assert!(
            cell.content()
                .is_some_and(|content| content.has_css_class("tp-cell-modified"))
        );
    }

    #[gtk4::test]
    fn an_edit_in_progress_keeps_its_text_when_the_row_is_drawn_again() {
        let grid = two_text_rows();
        let cell = grid.cell_of(2, 1);
        let editor = type_into(&cell, "typed");
        let row = cell.row().expect("a bound row");

        row.bump_revision();
        editor.stop_editing(false);

        assert_eq!(editor.text(), "B", "Escape did not go back to the row's value");
        type_into(&cell, "typed");
        row.bump_revision();
        assert_eq!(editor.entry().text(), "typed", "the redraw overwrote what was typed");
    }

    #[gtk4::test]
    fn unbind_disconnects_revision_handler() {
        let grid = two_text_rows();
        let cell = grid.cell_of(2, 1);
        let row = cell.row().expect("a bound row");
        let bound_renders = cell.render_count();
        row.bump_revision();
        assert_eq!(cell.render_count(), bound_renders + 1, "a bound cell did not redraw");

        cell.unbind();
        row.bump_revision();

        assert_eq!(
            cell.render_count(),
            bound_renders + 1,
            "a cell drew again for a row it no longer shows"
        );
    }

    fn name_rows(first: Value) -> Grid {
        Grid::open(
            vec![named("id", "integer", true), named("name", "text", false)],
            vec![vec![Value::Int(1), first], vec![Value::Int(2), Value::Text("B".into())]],
        )
    }

    /// Row 1's name edited from `from` to `to`, its editor opened on
    /// `to`, then the edit undone under the open editor.
    fn undo_under_open_editor(from: Value, to: Value) -> (Grid, GridCell, CellEditor) {
        let grid = name_rows(from.clone());
        let cell = grid.cell_of(1, 1);
        grid.redraw(&grid.tracker.apply(TrackerEdit::Cell {
            row_key: key(1),
            col: 1,
            original: from,
            value: to,
        }));
        enter_edit_mode(&cell);
        let editor = cell.editor().expect("a text cell");
        assert!(editor.is_editing(), "the cell did not open for editing");

        grid.redraw(&grid.tracker.undo().expect("an edit to undo"));

        (grid, cell, editor)
    }

    #[gtk4::test]
    fn escape_after_an_undo_under_the_editor_sends_nothing() {
        let (grid, cell, editor) = undo_under_open_editor(Value::Text("A".into()), Value::Text("X".into()));
        assert!(
            !editor.is_editing(),
            "the editor stayed open on a value the row no longer has"
        );

        editor.stop_editing(false);
        cell.unbind();

        assert_eq!(edited_rows(&grid.take_messages()), vec![]);
        assert_eq!(editor.text(), "A");
        assert_eq!(grid.tracker.pending_count(), 0);
    }

    #[gtk4::test]
    fn escape_after_undoing_an_edit_of_null_sends_nothing() {
        let (grid, _cell, editor) = undo_under_open_editor(Value::Null, Value::Text("hello".into()));

        editor.stop_editing(false);

        assert_eq!(edited_rows(&grid.take_messages()), vec![]);
        assert_eq!(editor.text().as_str(), editable_null_sentinel());
    }

    #[gtk4::test]
    fn enter_after_an_undo_under_the_editor_shows_the_undone_value() {
        let (grid, _cell, editor) = undo_under_open_editor(Value::Text("A".into()), Value::Text("X".into()));

        editor.stop_editing(true);

        assert_eq!(edited_rows(&grid.take_messages()), vec![]);
        assert_eq!(editor.text(), "A", "the cell shows an edit the tracker no longer has");
    }

    #[gtk4::test]
    fn escape_on_a_null_cell_drawn_again_under_its_editor_sends_nothing() {
        let grid = name_rows(Value::Null);
        let cell = grid.cell_of(1, 1);
        enter_edit_mode(&cell);
        let editor = cell.editor().expect("a text cell");

        cell.row().expect("a bound row").bump_revision();
        assert!(editor.is_editing(), "a redraw of the same value closed the editor");
        editor.stop_editing(false);

        assert_eq!(edited_rows(&grid.take_messages()), vec![]);
    }

    fn width_binding(tasks: &tablepro_session::runtime::Tasks, root: &tempfile::TempDir) -> ColumnWidthBinding {
        ColumnWidthBinding {
            store: crate::persistence::ColumnWidthStore::load(root.path().join("column-widths.json"), tasks),
            connection_id: uuid::Uuid::new_v4(),
            schema: None,
            table: "t".to_owned(),
        }
    }

    #[gtk4::test]
    fn column_freed_with_column_view() {
        let runtime = crate::test_support::test_runtime();
        let root = tempfile::tempdir().expect("tempdir");
        let columns = vec![named("name", "text", false)];
        let rows = vec![vec![Value::Text("a".into())]];
        let result = QueryResult::new(
            columns.iter().map(ColumnInfo::result_column).collect::<Vec<_>>(),
            rows.clone(),
        );
        let (sink, _messages) = recorder();
        let context = TabGridContext {
            editable: true,
            column_widths: Some(width_binding(&runtime.tasks(), &root)),
            ..TabGridContext::default()
        };
        let (view, selection) = build_column_view(
            &result,
            persisted(&rows),
            &columns,
            sink,
            Some((0, true)),
            true,
            context,
        );
        let column = view
            .columns()
            .item(0)
            .and_downcast::<gtk::ColumnViewColumn>()
            .expect("a column")
            .downgrade();
        let view_ref = view.downgrade();

        drop((view, selection));
        drain_main_context();

        assert!(column.upgrade().is_none(), "the column outlived its column view");
        assert!(view_ref.upgrade().is_none(), "the column view outlived its owner");
    }

    fn menu_gesture(cell: &gtk::Widget) -> Option<gtk::GestureClick> {
        let controllers = cell.observe_controllers();
        (0..controllers.n_items())
            .filter_map(|index| controllers.item(index).and_downcast::<gtk::GestureClick>())
            .find(|gesture| gesture.button() == 3)
    }

    #[gtk4::test]
    fn cells_freed_with_column_view() {
        let columns = vec![
            named("id", "integer", true),
            named("name", "text", false),
            named("flag", "boolean", false),
        ];
        let rows = vec![vec![Value::Int(7), Value::Text("a".into()), Value::Bool(true)]];
        let result = QueryResult::new(
            columns.iter().map(ColumnInfo::result_column).collect::<Vec<_>>(),
            rows.clone(),
        );
        let tracker = TabTrackerHandle::default();
        let (sink, _messages) = recorder();
        let (view, selection) = build_column_view(
            &result,
            persisted(&rows),
            &columns,
            sink,
            None,
            false,
            tracked(&tracker),
        );
        let window = gtk::Window::new();
        window.set_child(Some(&view));
        window.present();
        let cells = || -> Vec<GridCell> {
            descendants(&view)
                .into_iter()
                .filter_map(|widget| widget.downcast::<GridCell>().ok())
                .filter(|cell| cell.row().is_some())
                .collect()
        };
        wait_until(WAIT, || cells().len() == 3).expect("the key, text and bool cells are drawn");
        // A right-click is what fills the menu's target, so it has to be
        // in the picture too.
        for cell in cells() {
            let gesture = menu_gesture(cell.upcast_ref()).expect("a cell answers a right-click");
            gesture.emit_by_name::<()>("pressed", &[&1i32, &1.0f64, &1.0f64]);
        }
        let freed: Vec<glib::WeakRef<GridCell>> = cells().iter().map(ObjectExt::downgrade).collect();

        window.destroy();
        drop(window);
        drop((view, selection));
        drain_main_context();

        let alive = freed.iter().filter(|cell| cell.upgrade().is_some()).count();
        assert_eq!(alive, 0, "cells outlived their column view");
    }

    #[test]
    fn only_columns_with_an_empty_value_accept_an_empty_string() {
        // Clearing a text cell stores the empty string; clearing a
        // number or a date can only mean NULL.
        for text in ["text", "VARCHAR(255)", "char(3)", "longtext"] {
            assert!(
                col(text, false).column_type.kind.accepts_empty_string(),
                "{text} should accept an empty string"
            );
        }
        for other in [
            "integer",
            "bigint",
            "numeric(10,2)",
            "date",
            "timestamp",
            "uuid",
            "boolean",
        ] {
            assert!(
                !col(other, false).column_type.kind.accepts_empty_string(),
                "{other} should not accept an empty string"
            );
        }
    }

    #[test]
    fn a_blob_is_never_editable_whatever_the_engine_calls_it() {
        let identity = keyed_by_id();
        for name in [
            "BYTEA",
            "blob",
            "LONGBLOB",
            "mediumblob",
            "tinyblob",
            "VARBINARY",
            "binary",
        ] {
            assert!(
                !column_takes_edits(&col(name, false), &identity, false),
                "{name} was offered as an editable cell"
            );
        }
        assert!(column_takes_edits(&col("text", false), &identity, false));
        assert!(column_takes_edits(&col("integer", false), &identity, false));
    }
}
