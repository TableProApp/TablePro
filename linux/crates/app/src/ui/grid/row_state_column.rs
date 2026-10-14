use std::rc::Rc;

use gtk4 as gtk;
use gtk4::prelude::*;

use super::row_state_icon::row_state_icon;
use super::row_watches::RowWatches;
use super::{RowObject, TabGridContext};

/// Not a result column, so it has no name in the table, no saved width
/// and no place in a copy or an export.
pub(crate) const ROW_STATE_COLUMN_ID: &str = "tp-row-state";
/// One symbolic icon and its padding.
const ROW_STATE_COLUMN_WIDTH: i32 = 28;

/// A narrow first column that shows each row's pending change as an
/// icon, so the change reads without its tint, as a diff gutter marks a
/// line.
pub(super) fn row_state_column(tab_ctx: TabGridContext) -> gtk::ColumnViewColumn {
    let factory = gtk::SignalListItemFactory::new();
    factory.connect_setup(|_, item| {
        let Some(cell) = item.downcast_ref::<gtk::ColumnViewCell>() else {
            return;
        };
        // The row's own description names the state, so the icon would
        // say it twice.
        let image = gtk::Image::builder()
            .accessible_role(gtk::AccessibleRole::Presentation)
            .build();
        cell.set_property("focusable", false);
        cell.set_child(Some(&image));
    });

    let watches: Rc<RowWatches<gtk::ColumnViewCell>> = Rc::default();
    let tab_ctx = Rc::new(tab_ctx);
    {
        let watches = watches.clone();
        factory.connect_bind(move |_, item| {
            let Some(cell) = item.downcast_ref::<gtk::ColumnViewCell>() else {
                return;
            };
            let Some(row) = cell.item().and_downcast::<RowObject>() else {
                return;
            };
            let tab_ctx = tab_ctx.clone();
            watches.bind(cell, row, move |cell, row| {
                if let Some(image) = cell.child().and_downcast::<gtk::Image>() {
                    show_state(&image, &tab_ctx, row);
                }
            });
        });
    }
    factory.connect_unbind(move |_, item| {
        if let Some(cell) = item.downcast_ref::<gtk::ColumnViewCell>() {
            watches.unbind(cell);
        }
    });

    gtk::ColumnViewColumn::builder()
        .id(ROW_STATE_COLUMN_ID)
        .factory(&factory)
        .fixed_width(ROW_STATE_COLUMN_WIDTH)
        .resizable(false)
        .build()
}

fn show_state(image: &gtk::Image, tab_ctx: &TabGridContext, row: &RowObject) {
    let shown = row_state_icon(tab_ctx.row_pending_state(row));
    image.set_icon_name(shown.as_ref().map(|(icon, _)| *icon));
    image.set_tooltip_text(shown.as_ref().map(|(_, text)| text.as_str()));
}

/// The view's columns that show the result's, in the view's order.
pub(crate) fn data_columns(view: &gtk::ColumnView) -> Vec<gtk::ColumnViewColumn> {
    let columns = view.columns();
    (0..columns.n_items())
        .filter_map(|position| columns.item(position).and_downcast::<gtk::ColumnViewColumn>())
        .filter(|column| column.id().is_none_or(|id| id.as_str() != ROW_STATE_COLUMN_ID))
        .collect()
}

#[cfg(test)]
mod tests {
    use gtk4 as gtk;
    use gtk4::prelude::*;
    use tablepro_core::Value;

    use super::{ROW_STATE_COLUMN_ID, data_columns};
    use crate::services::tab_tracker_handle::TabTrackerHandle;
    use crate::services::tracker_edit::TrackerEdit;
    use crate::test_support::{first_descendant_of_type, wait_until};
    use crate::ui::grid::test_grid::{WAIT, content, key, named, persisted, recorder, tracked, two_text_rows};
    use crate::ui::grid::{ColumnWidthBinding, GridCell, GridMsg, GridSorting, RowObject, build_column_view};

    /// The state icon in the row `cell` is in.
    fn state_icon(cell: &GridCell) -> gtk::Image {
        let row = cell.parent().and_then(|cell| cell.parent()).expect("the row widget");
        first_descendant_of_type::<gtk::Image>(&row).expect("the row's state icon")
    }

    fn shown(image: &gtk::Image) -> (Option<String>, Option<String>) {
        (
            image.icon_name().map(|name| name.to_string()),
            image.tooltip_text().map(|text| text.to_string()),
        )
    }

    fn state(icon: &str, text: &str) -> (Option<String>, Option<String>) {
        (Some(icon.to_owned()), Some(text.to_owned()))
    }

    #[gtk4::test]
    fn row_state_column_reflects_each_state() {
        let grid = two_text_rows();
        let first = state_icon(&grid.cell_of(1, 1));
        let first_row = grid.cell_of(1, 1).row().expect("a bound row");
        assert_eq!(shown(&first), (None, None));
        assert!(gtk::test_accessible_has_role(&first, gtk::AccessibleRole::Presentation));
        assert!(
            !first.parent().is_some_and(|cell| cell.is_focusable()),
            "the state cell took the focus a data cell should"
        );

        grid.redraw(&grid.tracker.apply(TrackerEdit::Cell {
            row_key: key(1),
            col: 1,
            original: Value::Text("A".into()),
            value: Value::Text("edited".into()),
        }));
        assert_eq!(shown(&first), state("document-edit-symbolic", "Modified"));

        let generation = grid.tracker.flash_error_row(key(1)).generation;
        first_row.bump_revision();
        assert_eq!(shown(&first), state("dialog-error-symbolic", "Not saved"));
        assert!(grid.tracker.clear_error_row_if(generation));
        first_row.bump_revision();
        assert_eq!(shown(&first), state("document-edit-symbolic", "Modified"));

        grid.redraw(&grid.tracker.apply(TrackerEdit::DeleteRows {
            persisted: vec![(key(2), vec![Value::Int(2), Value::Text("B".into())].into())],
            drafts: Vec::new(),
        }));
        assert_eq!(
            shown(&state_icon(&grid.cell_of(2, 1))),
            state("edit-delete-symbolic", "Marked for deletion")
        );

        grid.insert_draft();
        let mut draft = None;
        wait_until(WAIT, || {
            draft = grid
                .cells()
                .into_iter()
                .find(|cell| cell.row().is_some_and(|row| row.draft_id().is_some()));
            draft.is_some()
        })
        .expect("the draft is drawn");
        let draft = draft.expect("the draft's cell");
        assert_eq!(shown(&state_icon(&draft)), state("list-add-symbolic", "New row"));

        grid.redraw(&grid.tracker.discard());
        assert_eq!(shown(&state_icon(&grid.cell_of(1, 1))), (None, None));
    }

    /// The second row, since the first holds the focus, and a focused
    /// row taken out of the list trips GTK 4.22.
    #[gtk4::test]
    fn an_unbound_state_icon_stops_following_its_row() {
        let grid = two_text_rows();
        let icon = state_icon(&grid.cell_of(2, 1));
        let row: RowObject = grid.cell_of(2, 1).row().expect("a bound row");

        grid.store.remove(1);
        crate::test_support::drain_main_context();
        let _ = grid.tracker.apply(TrackerEdit::Cell {
            row_key: key(2),
            col: 1,
            original: Value::Text("B".into()),
            value: Value::Text("edited".into()),
        });
        row.bump_revision();

        assert_eq!(icon.icon_name(), None, "a recycled icon drew a row it no longer shows");
    }

    #[gtk4::test]
    fn row_state_column_is_excluded_from_widths_and_sorting() {
        let runtime = crate::test_support::test_runtime();
        let root = tempfile::tempdir().expect("tempdir");
        let widths = ColumnWidthBinding {
            store: crate::persistence::ColumnWidthStore::load(root.path().join("column-widths.json"), &runtime.tasks()),
            connection_id: uuid::Uuid::new_v4(),
            schema: None,
            table: "t".to_owned(),
        };
        let columns = vec![named("id", "integer", true), named("name", "text", false)];
        let rows = vec![vec![Value::Int(1), Value::Text("A".into())]];
        let (sink, messages) = recorder();
        let tracker = TabTrackerHandle::default();
        let (view, _selection) = build_column_view(
            content(&columns, persisted(&rows)),
            &columns,
            sink,
            GridSorting::Server { initial: None },
            crate::ui::grid::TabGridContext {
                column_widths: Some(widths.clone()),
                ..tracked(&tracker)
            },
        );
        let state = view
            .columns()
            .item(0)
            .and_downcast::<gtk::ColumnViewColumn>()
            .expect("the state column");
        let data = data_columns(&view);

        assert_eq!(
            state.id().map(|id| id.to_string()).as_deref(),
            Some(ROW_STATE_COLUMN_ID)
        );
        assert!(!state.is_resizable());
        assert!(state.sorter().is_none());
        assert_eq!(state.fixed_width(), 28);
        assert_eq!(state.title(), None);
        let titles: Vec<String> = data
            .iter()
            .filter_map(|column| column.title().map(|title| title.to_string()))
            .collect();
        assert_eq!(titles, ["id", "name"]);

        state.set_fixed_width(60);
        data[1].set_fixed_width(200);
        assert_eq!(widths.width(ROW_STATE_COLUMN_ID), None);
        assert_eq!(widths.width("name"), Some(200));

        view.sort_by_column(Some(&data[0]), gtk::SortType::Descending);
        assert!(
            messages
                .borrow()
                .iter()
                .any(|msg| matches!(msg, GridMsg::SortChanged(0, false))),
            "a sort by the first data column named another"
        );
    }

    #[gtk4::test]
    fn a_grid_without_edits_has_no_state_column() {
        let columns = vec![named("id", "integer", true)];
        let (sink, _messages) = recorder();
        let (view, _selection) = build_column_view(
            content(&columns, persisted(&[vec![Value::Int(1)]])),
            &columns,
            sink,
            GridSorting::Client,
            crate::ui::grid::TabGridContext::default(),
        );

        assert_eq!(view.columns().n_items(), 1);
        assert_eq!(data_columns(&view).len(), 1);
    }
}
