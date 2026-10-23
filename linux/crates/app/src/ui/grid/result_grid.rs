use std::sync::Arc;

use gtk4 as gtk;
use tablepro_core::column::ResultColumn;

use super::{GridContent, GridSink, GridSorting, RowObject, TabGridContext, build_column_view};

/// A grid of an editor result, which sorts the rows it holds when a
/// header is clicked.
///
/// The rows reach the view through a `GtkSortListModel` on the view's
/// own sorter, so every selection, copy, menu and export reads the row
/// at its place on screen.
///
/// `in_clause` is false for an engine without SQL, whose rows have no
/// `IN` list to copy as.
pub(crate) fn build_result_grid(
    columns: Arc<[ResultColumn]>,
    rows: Vec<RowObject>,
    sink: GridSink,
    in_clause: bool,
) -> (gtk::ColumnView, gtk::MultiSelection) {
    build_column_view(
        GridContent { columns, rows },
        &[],
        sink,
        GridSorting::Client,
        TabGridContext {
            in_clause,
            ..TabGridContext::default()
        },
    )
}

#[cfg(test)]
mod tests {
    use std::time::{Duration, Instant};

    use gtk4::glib;
    use gtk4::prelude::*;
    use tablepro_core::Value;
    use tablepro_core::column::ColumnInfo;

    use super::*;
    use crate::test_support::{descendants, drain_main_context, wait_until};
    use crate::ui::clipboard::{CopyKind, CopyRequest};
    use crate::ui::grid::test_grid::{Grid, named, recorder};
    use crate::ui::grid::{GridCell, GridMsg};

    const WAIT: Duration = Duration::from_secs(10);

    fn grid(columns: &[ColumnInfo], rows: Vec<Vec<Value>>, sink: GridSink) -> (gtk::ColumnView, gtk::MultiSelection) {
        let rows = rows.into_iter().map(|cells| RowObject::result(cells.into())).collect();
        build_result_grid(
            columns.iter().map(ColumnInfo::result_column).collect(),
            rows,
            sink,
            true,
        )
    }

    fn sort(view: &gtk::ColumnView, column: u32, order: gtk::SortType) {
        let column = view
            .columns()
            .item(column)
            .and_downcast::<gtk::ColumnViewColumn>()
            .expect("the column");
        view.sort_by_column(Some(&column), order);
    }

    /// Column `column` of each row, in the order the view shows them.
    fn shown(selection: &gtk::MultiSelection, column: usize) -> Vec<Value> {
        (0..selection.n_items())
            .filter_map(|position| selection.item(position).and_downcast::<RowObject>())
            .map(|row| row.cell(column).cloned().unwrap_or(Value::Null))
            .collect()
    }

    fn text(value: &str) -> Value {
        Value::Text(value.to_owned())
    }

    #[gtk4::test]
    fn sort_by_column_descending_orders_result_rows() {
        let columns = [named("id", "integer", false), named("name", "text", false)];
        let (view, selection) = grid(
            &columns,
            vec![
                vec![Value::Int(2), text("b")],
                vec![Value::Int(10), text("j")],
                vec![Value::Null, text("none")],
                vec![Value::Int(-1), text("a")],
            ],
            recorder().0,
        );

        sort(&view, 0, gtk::SortType::Descending);

        assert_eq!(
            shown(&selection, 0),
            [Value::Int(10), Value::Int(2), Value::Int(-1), Value::Null]
        );
        assert_eq!(shown(&selection, 1), [text("j"), text("b"), text("a"), text("none")]);
        sort(&view, 0, gtk::SortType::Ascending);
        assert_eq!(
            shown(&selection, 0),
            [Value::Null, Value::Int(-1), Value::Int(2), Value::Int(10)]
        );
    }

    #[gtk4::test]
    fn a_sort_keeps_the_selected_rows_selected() {
        let columns = [named("id", "integer", false)];
        let (view, selection) = grid(
            &columns,
            vec![vec![Value::Int(3)], vec![Value::Int(1)], vec![Value::Int(2)]],
            recorder().0,
        );
        selection.select_item(0, true);
        selection.select_item(1, false);

        sort(&view, 0, gtk::SortType::Ascending);

        let selected: Vec<Value> = (0..selection.n_items())
            .filter(|position| selection.is_selected(*position))
            .filter_map(|position| selection.item(position).and_downcast::<RowObject>())
            .map(|row| row.cell(0).cloned().unwrap_or(Value::Null))
            .collect();
        assert_eq!(selected, [Value::Int(1), Value::Int(3)]);
    }

    #[gtk4::test]
    fn text_column_sorts_with_unicode_collation() {
        let columns = [named("name", "text", false)];
        let names = ["f", "é", "e", "E"];
        let mut rows: Vec<Vec<Value>> = names.iter().map(|name| vec![text(name)]).collect();
        rows.insert(2, vec![Value::Null]);
        let (view, selection) = grid(&columns, rows, recorder().0);

        sort(&view, 0, gtk::SortType::Ascending);

        // The order is the locale's: whatever it is, it is the order of
        // the collation keys GLib builds for it, with NULL first. The
        // sorter ignores case, as GtkStringSorter does by default, so
        // `e` and `E` tie and keep their row order.
        let mut collated = names.to_vec();
        collated.sort_by_key(|name| glib::CollationKey::from(glib::casefold(name).as_str()));
        let mut expected = vec![Value::Null];
        expected.extend(collated.iter().map(|name| text(name)));
        assert_eq!(shown(&selection, 0), expected);
        let key = |name: &str| glib::CollationKey::from(glib::casefold(name).as_str());
        if key("e") < key("é") && key("é") < key("f") {
            let order: Vec<Value> = shown(&selection, 0)
                .into_iter()
                .filter(|value| *value != text("E"))
                .collect();
            assert_eq!(order, [Value::Null, text("e"), text("é"), text("f")]);
        }
        sort(&view, 0, gtk::SortType::Descending);
        assert_eq!(
            shown(&selection, 0).last(),
            Some(&Value::Null),
            "NULL is not last descending"
        );
    }

    #[gtk4::test]
    fn a_text_column_orders_its_numbers_before_its_text() {
        let mut column = named("tag", "nvarchar(20)", false);
        column.column_type.dynamic_storage = false;
        let (view, selection) = grid(
            &[column],
            vec![
                vec![Value::Int(10)],
                vec![text("b")],
                vec![Value::Int(9)],
                vec![Value::Null],
                vec![text("a")],
            ],
            recorder().0,
        );

        sort(&view, 0, gtk::SortType::Ascending);

        assert_eq!(
            shown(&selection, 0),
            [Value::Null, Value::Int(9), Value::Int(10), text("a"), text("b")]
        );
    }

    #[gtk4::test]
    fn text_column_sorter_is_string_sorter_with_unicode_collation() {
        let (view, _selection) = grid(&[named("name", "varchar(20)", false)], Vec::new(), recorder().0);
        let column = view
            .columns()
            .item(0)
            .and_downcast::<gtk::ColumnViewColumn>()
            .expect("the column");

        let sorter = column
            .sorter()
            .and_downcast::<gtk::MultiSorter>()
            .expect("a text column sorts in steps");
        let collating = sorter
            .item(sorter.n_items() - 1)
            .and_downcast::<gtk::StringSorter>()
            .expect("the last step collates the text");
        assert_eq!(collating.collation(), gtk::Collation::Unicode);
        assert!(
            sorter.item(0).and_downcast::<gtk::CustomSorter>().is_some(),
            "NULL is not placed first"
        );
    }

    #[gtk4::test]
    fn sorting_10k_text_rows_finishes_within_one_second() {
        let rows = (0..10_000_u64)
            .map(|row| vec![text(&format!("name {:05}", row * 7_919 % 10_000))])
            .collect();
        let (view, selection) = grid(&[named("name", "text", false)], rows, recorder().0);

        let started = Instant::now();
        sort(&view, 0, gtk::SortType::Ascending);
        let count = selection.n_items();
        let elapsed = started.elapsed();

        assert_eq!(count, 10_000);
        assert!(elapsed < Duration::from_secs(1), "sorting took {elapsed:?}");
        assert_eq!(shown(&selection, 0)[0], text("name 00000"));
        assert_eq!(shown(&selection, 0)[9_999], text("name 09999"));
    }

    /// PostgreSQL's editor reads columns with no type, holding the
    /// server's text.
    #[gtk4::test]
    fn untyped_numbers_line_up_as_the_browse_grid_lines_them_up() {
        let untyped = |name: &str| ResultColumn::new(name, tablepro_core::column::ColumnType::untyped_text("text"));
        let columns: Arc<[ResultColumn]> = ["id", "category", "products", "avg_price"].map(untyped).into();
        let rows = vec![
            RowObject::result(vec![text("1"), text("Coffee"), text("7"), text("23.79")].into()),
            RowObject::result(vec![text("2"), text("Tea"), Value::Null, text("10.58")].into()),
        ];
        let (view, _selection) = build_result_grid(columns, rows, recorder().0, true);
        let window = gtk::Window::new();
        window.set_child(Some(&view));
        window.present();
        let result = |column: usize| {
            descendants(&view)
                .into_iter()
                .filter_map(|widget| widget.downcast::<GridCell>().ok())
                .find(|cell| cell.position() == Some(0) && cell.column() == column && cell.row().is_some())
                .and_then(|cell| cell.display())
        };
        wait_until(WAIT, || (0..4).all(|column| result(column).is_some())).expect("the result is drawn");
        let browse = Grid::open(
            vec![
                named("id", "integer", true),
                named("category", "text", false),
                named("products", "bigint", false),
                named("avg_price", "numeric", false),
            ],
            vec![vec![
                Value::Int(1),
                text("Coffee"),
                Value::Int(7),
                Value::Decimal("23.79".parse().expect("a decimal")),
            ]],
        );

        for column in 0..4 {
            let shown = result(column).expect("a result cell");
            let typed = browse.cell_of(1, column).display().expect("a browse cell");
            assert_eq!(shown.xalign(), typed.xalign(), "column {column}");
            assert_eq!(
                shown.has_css_class("numeric"),
                typed.has_css_class("numeric"),
                "column {column}"
            );
        }
        assert_eq!(result(2).map(|display| display.xalign()), Some(1.0));
        assert_eq!(result(1).map(|display| display.xalign()), Some(0.0));
        window.close();
    }

    #[gtk4::test]
    fn the_cell_menu_sorts_the_results_and_restores_their_order() {
        let columns = [named("id", "integer", false), named("name", "text", false)];
        let (view, selection) = grid(
            &columns,
            vec![
                vec![Value::Int(2), text("b")],
                vec![Value::Int(3), text("c")],
                vec![Value::Int(1), text("a")],
            ],
            recorder().0,
        );
        let window = gtk::Window::new();
        window.set_default_size(600, 400);
        window.set_child(Some(&view));
        window.present();
        let cell = || {
            descendants(&view)
                .into_iter()
                .filter_map(|widget| widget.downcast::<GridCell>().ok())
                .find(|cell| cell.position() == Some(0) && cell.column() == 0 && cell.row().is_some())
        };
        wait_until(WAIT, || cell().is_some()).expect("the cells are drawn");
        let open_menu = || {
            let cell = cell().expect("the first row's cell");
            let controllers = cell.observe_controllers();
            let gesture = (0..controllers.n_items())
                .filter_map(|index| controllers.item(index).and_downcast::<gtk::GestureClick>())
                .find(|gesture| gesture.button() == 3)
                .expect("a cell answers a right-click");
            gesture.emit_by_name::<()>("pressed", &[&1i32, &1.0f64, &1.0f64]);
        };

        open_menu();
        view.activate_action("cell.sort-descending", None)
            .expect("the menu's Sort Descending");
        assert_eq!(shown(&selection, 0), [Value::Int(3), Value::Int(2), Value::Int(1)]);

        open_menu();
        view.activate_action("cell.clear-sort", None)
            .expect("the menu's Clear Sort");
        assert_eq!(shown(&selection, 0), [Value::Int(2), Value::Int(3), Value::Int(1)]);
        window.close();
    }

    #[gtk4::test]
    fn copy_after_sort_copies_displayed_row() {
        let columns = [named("id", "integer", false), named("name", "text", false)];
        let (sink, messages) = recorder();
        let (view, _selection) = grid(
            &columns,
            vec![
                vec![Value::Int(3), text("c")],
                vec![Value::Int(1), text("a")],
                vec![Value::Int(2), text("b")],
            ],
            sink,
        );
        let window = gtk::Window::new();
        window.set_default_size(600, 400);
        window.set_child(Some(&view));
        window.present();
        sort(&view, 0, gtk::SortType::Ascending);
        let first_cell = || {
            descendants(&view)
                .into_iter()
                .filter_map(|widget| widget.downcast::<GridCell>().ok())
                .find(|cell| cell.position() == Some(0) && cell.column() == 1)
        };
        wait_until(WAIT, || first_cell().is_some_and(|cell| cell.row().is_some())).expect("the cells are drawn");
        let cell = first_cell().expect("the first row's cell");
        let gesture = {
            let controllers = cell.observe_controllers();
            (0..controllers.n_items())
                .filter_map(|index| controllers.item(index).and_downcast::<gtk::GestureClick>())
                .find(|gesture| gesture.button() == 3)
                .expect("a cell answers a right-click")
        };

        gesture.emit_by_name::<()>("pressed", &[&1i32, &1.0f64, &1.0f64]);
        view.activate_action("cell.copy", None).expect("the menu's Copy");
        drain_main_context();

        let copied: Vec<(Vec<Value>, CopyKind)> = messages
            .borrow()
            .iter()
            .filter_map(|msg| match msg {
                GridMsg::Copy(CopyRequest::Rows { rows, kind, .. }) => {
                    Some((rows.iter().flat_map(|row| row.to_values()).collect(), *kind))
                }
                _ => None,
            })
            .collect();
        assert_eq!(copied, [(vec![Value::Int(1), text("a")], CopyKind::Value(1))]);
        window.close();
    }
}
