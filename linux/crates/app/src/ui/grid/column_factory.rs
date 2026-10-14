use std::rc::Rc;

use gtk4::prelude::*;
use gtk4::{self as gtk, glib};

use tablepro_core::column::{ColumnKind, ResultColumn};
use tablepro_core::{ColumnInfo, QueryResult};

use super::cell_edit::install_edit_triggers;
use super::cell_editability::column_takes_edits;
use super::column_drawing::ColumnDrawing;
use super::context_menu::attach_cell_gesture;
use super::grid_menus::{GridMenuInit, GridMenus, install_grid_context_menus};
use super::toggle_cell::ToggleCell;
use super::{GridCell, GridMsg, GridSink, RowObject, TabGridContext};

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

/// How a column's cells are built. Editors are made when an edit
/// opens, so only the display is chosen here.
#[derive(Clone, Copy)]
enum CellKind {
    /// Drawn and never edited, so it takes no edit triggers.
    ReadOnly,
    Toggle,
    Text,
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
            match column.column_type.kind {
                ColumnKind::Bool(_) => CellKind::Toggle,
                _ => CellKind::Text,
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

    factory.connect_setup(move |_, item| {
        let Some(cell) = item.downcast_ref::<gtk::ColumnViewCell>() else {
            return;
        };
        let grid_cell = GridCell::new();
        grid_cell.attach(cell, idx);
        grid_cell.set_drawing(drawing.clone());
        grid_cell.set_sink(sink.clone());
        match kind {
            CellKind::ReadOnly => grid_cell.set_content(&text_display()),
            CellKind::Toggle => ToggleCell::setup(&grid_cell),
            CellKind::Text => {
                grid_cell.set_content(&text_display());
                install_edit_triggers(&grid_cell);
            }
        }
        attach_cell_gesture(&grid_cell, &column_view, &grid_menus);
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

/// Every cell but a check box draws its value in an Inscription, which
/// lays out only what fits and offers no text selection of its own.
fn text_display() -> gtk::Inscription {
    let display = gtk::Inscription::new(None);
    display.set_xalign(0.0);
    display.set_hexpand(true);
    display.set_text_overflow(gtk::InscriptionOverflow::EllipsizeEnd);
    display.set_margin_start(8);
    display.set_margin_end(8);
    display.add_css_class("tp-cell-text");
    display
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::rc::Rc;
    use std::time::Duration;

    use gtk4::prelude::*;
    use gtk4::{self as gtk, gio, glib};

    use tablepro_core::edit::CellInput;
    use tablepro_core::meta::RowIdentity;
    use tablepro_core::{ColumnInfo, QueryResult, Value};

    use super::build_column_view;
    use crate::services::change_tracker::RowKey;
    use crate::services::tab_tracker_handle::TabTrackerHandle;
    use crate::services::tracker_delta::TrackerDelta;
    use crate::services::tracker_edit::TrackerEdit;
    use crate::test_support::{descendants, drain_main_context, first_descendant_of_type, wait_until};
    use crate::ui::grid::cell_editability::column_takes_edits;
    use crate::ui::grid::display_text::editable_null_sentinel;
    use crate::ui::grid::{
        CellPreset, ColumnWidthBinding, GridCell, GridMsg, GridSink, RowObject, TabGridContext, begin_edit,
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
            let delta = self.tracker.apply(TrackerEdit::InsertDrafts {
                rows: vec![vec![CellInput::Value(Value::Null), CellInput::Value(Value::Null)]],
            });
            let Some(draft_id) = delta.inserted_drafts.into_iter().next() else {
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
                    && row.id().tracker_key().is_some_and(|key| delta.changed.contains(&key))
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

    /// Open the cell's one-line editor and type `text` over its value.
    fn type_into(cell: &GridCell, text: &str) -> gtk::Text {
        begin_edit(cell);
        let editor = cell.inline_text().expect("the cell did not open for editing");
        editor.set_text(text);
        editor
    }

    fn display_text(cell: &GridCell) -> String {
        cell.display()
            .and_then(|display| display.text())
            .map(|text| text.to_string())
            .unwrap_or_default()
    }

    /// Each edit the grid sent, as the row, the column and the value.
    fn edited_rows(messages: &[GridMsg]) -> Vec<(Option<RowKey>, usize, CellInput)> {
        messages
            .iter()
            .filter_map(|msg| match msg {
                GridMsg::Edit { row, column, edit } => {
                    let input = match edit {
                        TrackerEdit::Cell { value, .. } => CellInput::Value(value.clone()),
                        TrackerEdit::DraftCell { input, .. } => input.clone(),
                        other => panic!("a cell commit made {other:?}"),
                    };
                    Some((row.key().cloned(), *column, input))
                }
                _ => None,
            })
            .collect()
    }

    fn text(value: &str) -> CellInput {
        CellInput::Value(Value::Text(value.to_owned()))
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
        editor.emit_activate();

        assert_eq!(
            edited_rows(&grid.take_messages()),
            vec![(Some(key(2)), 1, text("renamed"))]
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
            .expect("the menu's Set to NULL");

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
        editor.emit_activate();

        assert_eq!(
            edited_rows(&grid.take_messages()),
            vec![(Some(key(2)), 1, text("renamed"))]
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
        let toggle = grid.cell_of(2, 1).check_button().expect("a check button");

        toggle.set_active(true);

        assert_eq!(
            edited_rows(&grid.take_messages()),
            vec![(Some(key(2)), 1, CellInput::Value(Value::Bool(true)))]
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

        begin_edit(&grid.cell_of(1, 0));
        assert!(!grid.cell_of(1, 0).is_editing());
        begin_edit(&draft_key_cell);
        assert!(draft_key_cell.inline_text().is_some());
    }

    #[gtk4::test]
    fn locked_cells_draw_in_an_inscription_with_no_label() {
        let grid = two_text_rows();
        let locked = grid.cell_of(1, 0);

        assert!(
            locked.display().is_some(),
            "a locked cell does not draw in an Inscription"
        );
        assert!(
            descendants(&locked).iter().all(|widget| !widget.is::<gtk::Label>()),
            "a locked cell carries a label, whose own menu takes Shift+F10"
        );
        assert_eq!(display_text(&locked), "1");
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
        assert_eq!(display_text(&cell), "new");
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

        assert_eq!(editor.text(), "typed", "the redraw overwrote what was typed");
        cell.cancel_edit();
        assert_eq!(display_text(&cell), "B", "Escape did not go back to the row's value");
        assert!(cell.inline_text().is_none());
        assert_eq!(edited_rows(&grid.take_messages()), vec![]);
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
    fn undo_under_open_editor(from: Value, to: Value) -> (Grid, GridCell) {
        let grid = name_rows(from.clone());
        let cell = grid.cell_of(1, 1);
        grid.redraw(&grid.tracker.apply(TrackerEdit::Cell {
            row_key: key(1),
            col: 1,
            original: from,
            value: to,
        }));
        begin_edit(&cell);
        assert!(cell.inline_text().is_some(), "the cell did not open for editing");

        grid.redraw(&grid.tracker.undo().expect("an edit to undo"));

        (grid, cell)
    }

    #[gtk4::test]
    fn escape_after_an_undo_under_the_editor_sends_nothing() {
        let (grid, cell) = undo_under_open_editor(Value::Text("A".into()), Value::Text("X".into()));
        assert!(
            !cell.is_editing(),
            "the editor stayed open on a value the row no longer has"
        );

        cell.cancel_edit();
        cell.unbind();

        assert_eq!(edited_rows(&grid.take_messages()), vec![]);
        assert_eq!(display_text(&cell), "A");
        assert_eq!(grid.tracker.pending_count(), 0);
    }

    #[gtk4::test]
    fn escape_after_undoing_an_edit_of_null_sends_nothing() {
        let (grid, cell) = undo_under_open_editor(Value::Null, Value::Text("hello".into()));

        cell.cancel_edit();

        assert_eq!(edited_rows(&grid.take_messages()), vec![]);
        assert_eq!(display_text(&cell), editable_null_sentinel());
    }

    #[gtk4::test]
    fn escape_on_a_null_cell_drawn_again_under_its_editor_sends_nothing() {
        let grid = name_rows(Value::Null);
        let cell = grid.cell_of(1, 1);
        begin_edit(&cell);

        cell.row().expect("a bound row").bump_revision();
        assert!(cell.is_editing(), "a redraw of the same value closed the editor");
        cell.cancel_edit();

        assert_eq!(edited_rows(&grid.take_messages()), vec![]);
    }

    #[gtk4::test]
    fn a_null_text_cell_left_as_it_opened_stays_null() {
        let grid = name_rows(Value::Null);
        let cell = grid.cell_of(1, 1);

        let editor = type_into(&cell, "");

        assert_eq!(
            editor.placeholder_text().unwrap_or_default(),
            "",
            "a text column keeps the empty string, so empty means nothing more"
        );
        editor.emit_activate();
        assert_eq!(edited_rows(&grid.take_messages()), vec![]);
    }

    /// Past the length the grid cuts a cell's text at.
    fn long_text() -> String {
        format!("tpyo{}", "x".repeat(60_000))
    }

    fn source_view(cell: &GridCell) -> Option<sourceview5::View> {
        first_descendant_of_type::<sourceview5::View>(cell)
    }

    fn buffer_text(view: &sourceview5::View) -> String {
        let buffer = view.buffer();
        buffer.text(&buffer.start_iter(), &buffer.end_iter(), true).to_string()
    }

    fn save_button(cell: &GridCell) -> gtk::Button {
        descendants(cell)
            .into_iter()
            .filter_map(|widget| widget.downcast::<gtk::Button>().ok())
            .find(|button| button.has_css_class("suggested-action"))
            .expect("the Save button")
    }

    #[gtk4::test]
    fn editing_a_long_text_starts_from_the_whole_value() {
        let grid = name_rows(Value::Text(long_text()));
        let cell = grid.cell_of(1, 1);

        begin_edit(&cell);

        assert!(cell.inline_text().is_none(), "a long text opened in a one-line field");
        let opened = buffer_text(&source_view(&cell).expect("the multi-line editor"));
        assert_eq!(opened.len(), long_text().len(), "the editor opened on the cut text");
        assert_eq!(opened, long_text());
    }

    #[gtk4::test]
    fn a_long_text_saved_from_its_editor_sends_the_whole_value() {
        let grid = name_rows(Value::Text(long_text()));
        let cell = grid.cell_of(1, 1);
        begin_edit(&cell);
        let fixed = long_text().replacen("tpyo", "typo", 1);
        let view = source_view(&cell).expect("the multi-line editor");

        view.buffer().set_text(&fixed);
        save_button(&cell).emit_clicked();

        assert_eq!(
            edited_rows(&grid.take_messages()),
            vec![(Some(key(1)), 1, text(&fixed))]
        );
        assert!(!cell.is_editing());
        assert!(display_text(&cell).len() < 20_000, "the cell drew the whole value");
    }

    #[gtk4::test]
    fn a_text_that_reads_as_the_null_sentinel_opens_as_itself() {
        let grid = name_rows(Value::Text(editable_null_sentinel()));
        let cell = grid.cell_of(1, 1);

        let opened = cell_editor_text(&cell);

        assert_eq!(opened, Some(editable_null_sentinel()));
    }

    fn cell_editor_text(cell: &GridCell) -> Option<String> {
        begin_edit(cell);
        cell.inline_text().map(|editor| editor.text().to_string())
    }

    #[gtk4::test]
    fn a_blob_in_a_text_column_does_not_open_on_its_placeholder() {
        let grid = name_rows(Value::Bytes(vec![1, 2, 3]));
        let cell = grid.cell_of(1, 1);

        begin_edit(&cell);

        assert!(!cell.is_editing(), "the editor opened on the size placeholder");
        assert!(
            grid.take_messages()
                .iter()
                .any(|msg| matches!(msg, GridMsg::ShowToast(_))),
            "the cell did not say why it would not open"
        );
    }

    /// A closed editor popover must leave nothing holding its cell.
    #[gtk4::test]
    fn a_closed_popover_editor_frees_its_cell() {
        let grid = Grid::open(
            vec![
                named("id", "integer", true),
                named("doc", "jsonb", false),
                named("day", "date", false),
            ],
            vec![vec![
                Value::Int(1),
                Value::Json(tablepro_core::value::JsonText::parse("[1]".to_owned()).expect("json")),
                Value::Date(tablepro_core::value::Temporal::Finite(
                    chrono::NaiveDate::from_ymd_opt(2026, 9, 15).expect("a date"),
                )),
            ]],
        );
        for column in [1, 2] {
            let cell = grid.cell_of(1, column);
            begin_edit(&cell);
            let popover = first_descendant_of_type::<gtk::Popover>(&cell).expect("the editor popover");
            assert!(cell.is_editing());

            popover.popdown();
            wait_until(WAIT, || popover.parent().is_none()).expect("the popover closes");

            assert!(!cell.is_editing(), "column {column} left its popover in the cell");
        }
        assert_eq!(edited_rows(&grid.take_messages()), vec![]);
        let freed: Vec<glib::WeakRef<GridCell>> = grid.cells().iter().map(ObjectExt::downgrade).collect();

        drop(grid);

        assert!(
            freed.iter().all(|cell| cell.upgrade().is_none()),
            "an editor popover kept its cell alive"
        );
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
        // A right-click is what fills the menu's target, and an open
        // editor is another hold on a cell, so both are in the picture.
        for cell in cells() {
            let gesture = menu_gesture(cell.upcast_ref()).expect("a cell answers a right-click");
            gesture.emit_by_name::<()>("pressed", &[&1i32, &1.0f64, &1.0f64]);
        }
        if let Some(name) = cells().into_iter().find(|cell| cell.column() == 1) {
            begin_edit(&name);
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
