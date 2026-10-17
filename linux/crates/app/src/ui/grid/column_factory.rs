use std::cell::RefCell;
use std::rc::Rc;

use gtk4::prelude::*;
use gtk4::{self as gtk, gio, glib};

use tablepro_core::ColumnInfo;
use tablepro_core::column::{ColumnKind, ResultColumn};

use super::cell_edit::install_edit_triggers;
use super::cell_editability::column_takes_edits;
use super::column_drawing::ColumnDrawing;
use super::column_figures::ColumnFigures;
use super::context_menu::attach_cell_gesture;
use super::grid_attributes::GridAttributes;
use super::grid_columns::GridColumns;
use super::grid_keyboard::GridKeyboard;
use super::grid_menus::{GridMenuInit, GridMenus, install_grid_context_menus};
use super::result_sorters::column_sorter;
use super::row_factory::install_row_factory;
use super::row_state_column::row_state_column;
use super::toggle_cell::ToggleCell;
use super::{GridCell, GridContent, GridMsg, GridSink, RowObject, TabGridContext};

const WIDE_TABLE_THRESHOLD: usize = 8;
/// About 14 characters at the default font size.
const MIN_COLUMN_WIDTH_PX: i32 = 120;

/// How a grid's headers sort its rows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum GridSorting {
    /// The server sorts: a header click sends `SortChanged` and the rows
    /// stay in the order they arrived, which `initial` describes.
    Server { initial: Option<(usize, bool)> },
    /// The grid sorts the rows it holds, each column by its own sorter.
    Client,
}

pub(crate) fn build_column_view(
    content: GridContent,
    schema_columns: &[ColumnInfo],
    sink: GridSink,
    sorting: GridSorting,
    tab_ctx: TabGridContext,
) -> (gtk::ColumnView, gtk::MultiSelection) {
    let GridContent {
        columns: result_columns,
        rows,
    } = content;
    let store = gio::ListStore::new::<RowObject>();
    store.splice(0, 0, &rows);
    let grid_columns = Rc::new(GridColumns::default());
    // A browse page splices its rows into this store, so the columns
    // measure them again before the view binds any of them.
    store.connect_items_changed({
        let grid_columns = grid_columns.clone();
        move |store, _, _, _| grid_columns.measure(store)
    });
    // Tab leaves the grid, and the arrow keys move between cells.
    let column_view = gtk::ColumnView::builder()
        .show_row_separators(true)
        .show_column_separators(true)
        .tab_behavior(gtk::ListTabBehavior::Cell)
        .build();
    let selection = match sorting {
        GridSorting::Client => sorted_selection(store, column_view.sorter()),
        GridSorting::Server { .. } => gtk::MultiSelection::new(Some(store)),
    };
    column_view.set_model(Some(&selection));
    // GTK's own denser rows for a grid of data.
    column_view.add_css_class("data-table");
    install_row_factory(&column_view, tab_ctx.clone());

    let grid_menus = install_grid_context_menus(GridMenuInit {
        column_view: &column_view,
        sink: sink.clone(),
        columns: result_columns.clone(),
        tab_ctx: tab_ctx.clone(),
    });
    GridKeyboard::install(&column_view, grid_menus.clone(), sink.clone());

    // Sharing the viewport by `expand` alone leaves a wide table with 20
    // to 30 px columns that show nothing, so a text column with no saved
    // width starts at a readable minimum there.
    let default_min_width = if result_columns.len() > WIDE_TABLE_THRESHOLD {
        Some(MIN_COLUMN_WIDTH_PX)
    } else {
        None
    };
    let mut columns: Vec<gtk::ColumnViewColumn> = Vec::with_capacity(result_columns.len());
    let mut releases = Vec::with_capacity(result_columns.len() + 1);
    let attributes = Rc::new(GridAttributes::new());
    for (i, column) in result_columns.iter().enumerate() {
        let sorter = match sorting {
            // The server orders the rows, so the column's own sorter
            // only marks the header and must leave them where they are.
            GridSorting::Server { .. } => gtk::CustomSorter::new(|_, _| gtk::Ordering::Equal).upcast(),
            GridSorting::Client => column_sorter(i, column),
        };
        let (col, width_saver) = build_column(ColumnInit {
            info: column,
            idx: i,
            rows: &rows,
            catalog: schema_columns.get(i).cloned(),
            sink: sink.clone(),
            sorter,
            tab_ctx: tab_ctx.clone(),
            default_min_width,
            column_view: column_view.downgrade(),
            grid_menus: grid_menus.clone(),
            grid_columns: grid_columns.clone(),
            attributes: attributes.clone(),
        });
        column_view.append_column(&col);
        releases.push(ColumnRelease {
            column: col.downgrade(),
            width_saver,
        });
        columns.push(col);
    }
    if tab_ctx.tracks_changes() {
        let state_column = row_state_column(tab_ctx.clone());
        column_view.insert_column(0, &state_column);
        releases.push(ColumnRelease {
            column: state_column.downgrade(),
            width_saver: None,
        });
    }
    release_columns_with(&column_view, releases);
    wire_server_sorting(&column_view, columns, sorting, sink);

    (column_view, selection)
}

fn wire_server_sorting(
    column_view: &gtk::ColumnView,
    columns: Vec<gtk::ColumnViewColumn>,
    sorting: GridSorting,
    sink: GridSink,
) {
    // Applied before the notify handlers are wired, so it does not echo
    // back as a SortChanged.
    if let GridSorting::Server {
        initial: Some((col_idx, ascending)),
    } = sorting
        && let Some(col) = columns.get(col_idx)
    {
        let direction = if ascending {
            gtk::SortType::Ascending
        } else {
            gtk::SortType::Descending
        };
        column_view.sort_by_column(Some(col), direction);
    }

    if matches!(sorting, GridSorting::Server { .. })
        && let Some(view_sorter) = column_view
            .sorter()
            .and_then(|s| s.downcast::<gtk::ColumnViewSorter>().ok())
    {
        // A second click on the same column flips only
        // `primary-sort-order`, so both notifies are wired. Each sends the
        // sorter's post-click pair, which the receiver drops when it
        // already matches.
        let dispatch = move |sorter: &gtk::ColumnViewSorter| {
            let Some(active) = sorter.primary_sort_column() else {
                return;
            };
            let ascending = matches!(sorter.primary_sort_order(), gtk::SortType::Ascending);
            if let Some(idx) = columns.iter().position(|col| col == &active) {
                sink(GridMsg::SortChanged(idx, ascending));
            }
        };
        view_sorter.connect_primary_sort_column_notify({
            let dispatch = dispatch.clone();
            move |sorter| dispatch(sorter)
        });
        view_sorter.connect_primary_sort_order_notify(move |sorter| dispatch(sorter));
    }
}

/// A selection over `store` sorted by `sorter`, sorted at once on each
/// click rather than in steps, so the rows never show half sorted and a
/// copy right after a click takes the order on screen.
/// `GtkMultiSelection` follows its selected rows to where a sort puts
/// them.
fn sorted_selection(store: gio::ListStore, sorter: Option<gtk::Sorter>) -> gtk::MultiSelection {
    let sorted = gtk::SortListModel::new(Some(store), sorter);
    sorted.set_incremental(false);
    gtk::MultiSelection::new(Some(sorted))
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
    rows: &'a [RowObject],
    /// `None` for a column the grid knows only from the result set.
    catalog: Option<ColumnInfo>,
    sink: GridSink,
    sorter: gtk::Sorter,
    tab_ctx: TabGridContext,
    default_min_width: Option<i32>,
    column_view: glib::WeakRef<gtk::ColumnView>,
    grid_menus: GridMenus,
    grid_columns: Rc<GridColumns>,
    attributes: Rc<GridAttributes>,
}

fn build_column(init: ColumnInit<'_>) -> (gtk::ColumnViewColumn, Option<glib::SignalHandlerId>) {
    let ColumnInit {
        info,
        idx,
        rows,
        catalog,
        sink,
        sorter,
        tab_ctx,
        default_min_width,
        column_view,
        grid_menus,
        grid_columns,
        attributes,
    } = init;
    let factory = gtk::SignalListItemFactory::new();

    let kind = CellKind::for_column(catalog.as_ref(), &tab_ctx);
    let auto_filled = catalog
        .as_ref()
        .is_some_and(|column| column.is_auto_increment || column.is_generated);
    let figures = ColumnFigures::default();
    figures.measure(&info.column_type, idx, rows);
    let drawing = Rc::new(ColumnDrawing {
        catalog,
        column_type: info.column_type.clone(),
        tab_ctx: tab_ctx.clone(),
        auto_filled,
        attributes,
        figures,
    });

    let setup_drawing = drawing.clone();
    let setup_columns = grid_columns.clone();
    let setup_name = info.name.clone();
    factory.connect_setup(move |_, item| {
        let Some(cell) = item.downcast_ref::<gtk::ColumnViewCell>() else {
            return;
        };
        // The focus lands on the cell, never inside it, so every key
        // the grid answers sees the same widget. Set through the
        // property: `ListItemExt::set_focusable` sets the GtkListItem
        // field, which the column view's cell widget never reads.
        cell.set_property("focusable", true);
        let grid_cell = GridCell::new();
        grid_cell.attach(cell, idx);
        grid_cell.set_drawing(setup_drawing.clone());
        grid_cell.set_sink(sink.clone());
        grid_cell.set_columns(setup_columns.clone());
        match kind {
            CellKind::ReadOnly => grid_cell.set_content(&text_display(&setup_drawing.figures)),
            CellKind::Toggle => ToggleCell::setup(&grid_cell, &setup_name),
            CellKind::Text => {
                grid_cell.set_content(&text_display(&setup_drawing.figures));
                install_edit_triggers(&grid_cell);
            }
        }
        attach_cell_gesture(&grid_cell, &column_view, &grid_menus);
        cell.set_child(Some(&grid_cell));
    });
    bind_rows_to_cells(&factory);

    let column = gtk::ColumnViewColumn::builder()
        .title(&info.name)
        .factory(&factory)
        .resizable(true)
        .expand(true)
        .build();
    column.set_sorter(Some(&sorter));
    // A number column is as wide as its widest number already.
    let default_min_width = default_min_width.filter(|_| !drawing.figures.numbers());
    let width_saver = size_column(&column, &info.name, &tab_ctx, default_min_width);
    grid_columns.push(idx, &column, drawing, default_min_width);
    (column, width_saver)
}

struct ColumnRelease {
    column: glib::WeakRef<gtk::ColumnViewColumn>,
    width_saver: Option<glib::SignalHandlerId>,
}

// GTK 4.22 leaks a reference to the column next to the focus column when
// the view removes the focus column, so a column can outlive its view.
// Its factory and width saver must not keep the grid alive with it.
fn release_columns_with(column_view: &gtk::ColumnView, releases: Vec<ColumnRelease>) {
    let releases = RefCell::new(releases);
    column_view.connect_destroy(move |_| {
        for release in releases.take() {
            let Some(column) = release.column.upgrade() else {
                continue;
            };
            if let Some(handler) = release.width_saver {
                column.disconnect(handler);
            }
            column.set_factory(None::<&gtk::ListItemFactory>);
        }
    });
}

impl CellKind {
    fn for_column(catalog: Option<&ColumnInfo>, tab_ctx: &TabGridContext) -> CellKind {
        match catalog {
            Some(column) if tab_ctx.editable && column_takes_edits(column, &tab_ctx.identity, false) => {
                match column.column_type.kind {
                    ColumnKind::Bool(_) => CellKind::Toggle,
                    _ => CellKind::Text,
                }
            }
            _ => CellKind::ReadOnly,
        }
    }
}

fn bind_rows_to_cells(factory: &gtk::SignalListItemFactory) {
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
}

/// The width the tab saved for the column, or `default_min_width`, and
/// every later drag saved back.
fn size_column(
    column: &gtk::ColumnViewColumn,
    name: &str,
    tab_ctx: &TabGridContext,
    default_min_width: Option<i32>,
) -> Option<glib::SignalHandlerId> {
    if let Some(widths) = tab_ctx.column_widths.clone() {
        if let Some(saved) = widths.width(name) {
            column.set_fixed_width(saved);
        } else if let Some(min) = default_min_width {
            column.set_fixed_width(min);
        }
        let column_name = name.to_owned();
        Some(column.connect_fixed_width_notify(move |column| {
            widths.record(&column_name, column.fixed_width());
        }))
    } else {
        if let Some(min) = default_min_width {
            // Editor results remember no widths, but can be just as wide.
            column.set_fixed_width(min);
        }
        None
    }
}

/// Every cell but a check box draws its value in an Inscription, which
/// lays out only what fits and offers no text selection of its own.
fn text_display(figures: &ColumnFigures) -> gtk::Inscription {
    let display = gtk::Inscription::new(None);
    display.set_hexpand(true);
    display.set_text_overflow(gtk::InscriptionOverflow::EllipsizeEnd);
    display.set_margin_start(8);
    display.set_margin_end(8);
    display.add_css_class("tp-cell-text");
    figures.apply(&display, "", true);
    display
}

#[cfg(test)]
mod tests {
    use gtk4::prelude::*;
    use gtk4::{self as gtk, glib};

    use tablepro_core::Value;
    use tablepro_core::edit::CellInput;

    use super::{GridSorting, build_column_view};
    use crate::services::change_tracker::RowKey;
    use crate::services::tab_tracker_handle::TabTrackerHandle;
    use crate::services::tracker_edit::TrackerEdit;
    use crate::test_support::{OwnedWindow, descendants, drain_main_context, first_descendant_of_type, wait_until};
    use crate::ui::grid::cell_editability::column_takes_edits;
    use crate::ui::grid::display_text::editable_null_sentinel;
    use crate::ui::grid::test_grid::{
        Grid, WAIT, col, content, display_text, edited_rows, flag_rows, key, keyed_by_id, named, persisted, recorder,
        text, tracked, two_text_rows, type_into,
    };
    use crate::ui::grid::{CellPreset, ColumnWidthBinding, GridCell, GridMsg, RowObject, TabGridContext, begin_edit};

    #[gtk4::test]
    fn f004_edit_after_draft_insert_targets_edited_row() {
        let grid = two_text_rows();
        grid.insert_draft();

        let cell = grid.focus(2, 1);
        assert_eq!(cell.row().and_then(|row| row.key().cloned()), Some(key(2)));
        assert_eq!(cell.column(), 1);
        let editor = type_into(&cell, "renamed");
        editor.emit_activate();

        assert_eq!(
            edited_rows(&grid.take_messages()),
            vec![(Some(key(2)), 1, text("renamed"))]
        );
    }

    #[gtk4::test]
    fn f004_menu_set_null_after_draft_removal_targets_clicked_row() {
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
    fn a_text_with_a_nul_draws_and_refuses_an_editor() {
        let grid = Grid::open(
            vec![named("id", "integer", true), named("name", "text", false)],
            vec![vec![Value::Int(1), Value::Text("a\0b".into())]],
        );
        let cell = grid.cell_of(1, 1);
        assert_eq!(display_text(&cell), "a\u{2400}b");

        begin_edit(&cell);

        assert!(
            cell.inline_text().is_none(),
            "an editor opened on a value it cannot hold"
        );
        assert!(
            matches!(grid.take_messages().as_slice(), [GridMsg::ShowToast(_)]),
            "the refusal was not explained"
        );
    }

    #[gtk4::test]
    fn opening_a_boolean_cell_writes_nothing() {
        let grid = flag_rows();
        let cell = grid.cell_of(1, 1);

        begin_edit(&cell);

        assert!(grid.take_messages().is_empty(), "opening the cell flipped it");
        assert!(!cell.check_button().expect("a check button").is_active());
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
        let (sink, _messages) = recorder();
        let context = TabGridContext {
            editable: true,
            column_widths: Some(width_binding(&runtime.tasks(), &root)),
            ..TabGridContext::default()
        };
        let (view, selection) = build_column_view(
            content(&columns, persisted(&rows)),
            &columns,
            sink,
            GridSorting::Server {
                initial: Some((0, true)),
            },
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

    #[gtk4::test]
    fn a_column_left_behind_by_its_view_lets_go_of_the_grid() {
        let columns = vec![named("id", "integer", true), named("name", "text", false)];
        let rows = vec![vec![Value::Int(7), Value::Text("a".into())]];
        let tracker = TabTrackerHandle::default();
        let (sink, messages) = recorder();
        let (view, selection) = build_column_view(
            content(&columns, persisted(&rows)),
            &columns,
            sink,
            GridSorting::Server { initial: None },
            tracked(&tracker),
        );
        let window = OwnedWindow::presented(gtk::Window::new());
        window.set_child(Some(&view));
        // GTK 4.22 leaks the column after the focus column as the view
        // removes its columns from the first.
        let id = crate::ui::grid::data_columns(&view)
            .into_iter()
            .next()
            .expect("the id column");
        wait_until(WAIT, || descendants(&view).iter().any(|widget| widget.is::<GridCell>()))
            .expect("the cells are drawn");
        view.scroll_to(0, Some(&id), gtk::ListScrollFlags::FOCUS, None);
        view.grab_focus();
        wait_until(WAIT, || {
            gtk::prelude::GtkWindowExt::focus(&*window)
                .and_then(|focus| GridCell::from_focus(&focus))
                .is_some_and(|cell| cell.column() == 0)
        })
        .expect("the id cell takes the focus");

        drop(id);
        drop(window);
        drop((view, selection));
        drain_main_context();

        assert_eq!(
            std::rc::Rc::strong_count(&messages),
            1,
            "a column the view left behind kept the grid's sink"
        );
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
        let tracker = TabTrackerHandle::default();
        let (sink, _messages) = recorder();
        let (view, selection) = build_column_view(
            content(&columns, persisted(&rows)),
            &columns,
            sink,
            GridSorting::Server { initial: None },
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

    #[gtk4::test]
    fn column_view_carries_data_table_class() {
        let grid = two_text_rows();

        assert!(grid.view.has_css_class("data-table"));
    }

    #[gtk4::test]
    fn numeric_column_cells_align_end_with_numeric_class() {
        let grid = Grid::open(
            vec![
                named("id", "integer", true),
                named("name", "text", false),
                named("price", "numeric(10,2)", false),
            ],
            vec![vec![
                Value::Int(1),
                Value::Text("tea".into()),
                Value::Decimal("4.5".parse().expect("a decimal")),
            ]],
        );
        let display = |column| grid.cell_of(1, column).display().expect("a text cell");

        for column in [0, 2] {
            assert_eq!(display(column).xalign(), 1.0, "column {column}");
            assert!(display(column).has_css_class("numeric"), "column {column}");
        }
        assert_eq!(display(1).xalign(), 0.0);
        assert!(!display(1).has_css_class("numeric"));
        assert_eq!(display_text(&grid.cell_of(1, 2)), "4.50", "the column's scale");
    }

    #[gtk4::test]
    fn pending_delete_row_uses_shared_strikethrough_attributes() {
        let grid = two_text_rows();
        let attributes = |id, column| {
            grid.cell_of(id, column)
                .display()
                .and_then(|display| display.attributes())
                .map(|attrs| attrs.as_ptr())
        };
        assert_eq!(attributes(1, 1), None, "plain text carries no attributes");

        grid.redraw(&grid.tracker.apply(TrackerEdit::DeleteRows {
            persisted: vec![(key(1), vec![Value::Int(1), Value::Text("A".into())].into())],
            drafts: Vec::new(),
        }));

        let struck = attributes(1, 0).expect("the deleted row's text is struck through");
        assert_eq!(attributes(1, 1), Some(struck), "each cell built its own list");
        assert_eq!(attributes(2, 1), None);
    }

    #[gtk4::test]
    fn a_null_placeholder_is_italic_and_a_locked_one_dimmed() {
        let grid = name_rows(Value::Null);
        let name = grid.cell_of(1, 1).display().expect("a text cell");

        assert_eq!(name.text().as_deref(), Some(editable_null_sentinel().as_str()));
        assert!(name.attributes().is_some(), "a placeholder reads like a value");
        assert!(!name.has_css_class("dimmed"), "an editable NULL was dimmed");
        assert!(name.tooltip_text().is_none());
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
