use std::rc::Rc;

use gtk4 as gtk;
use gtk4::prelude::*;

use super::cell_accessibility::row_description;
use super::row_watches::RowWatches;
use super::{RowObject, TabGridContext};

/// Rows never take the focus, so it always lands on a cell and the
/// arrow keys move between cells. Each row tells a screen reader when
/// it is new or marked for deletion.
pub(super) fn install_row_factory(column_view: &gtk::ColumnView, tab_ctx: TabGridContext) {
    let factory = gtk::SignalListItemFactory::new();
    factory.connect_setup(|_, item| {
        if let Some(list_row) = item.downcast_ref::<gtk::ColumnViewRow>() {
            list_row.set_focusable(false);
        }
    });

    let watches: Rc<RowWatches<gtk::ColumnViewRow>> = Rc::default();
    let tab_ctx = Rc::new(tab_ctx);
    {
        let watches = watches.clone();
        factory.connect_bind(move |_, item| {
            let Some(list_row) = item.downcast_ref::<gtk::ColumnViewRow>() else {
                return;
            };
            let Some(row) = list_row.item().and_downcast::<RowObject>() else {
                return;
            };
            let tab_ctx = tab_ctx.clone();
            watches.bind(list_row, row, move |list_row, row| describe(list_row, &tab_ctx, row));
        });
    }
    factory.connect_unbind(move |_, item| {
        let Some(list_row) = item.downcast_ref::<gtk::ColumnViewRow>() else {
            return;
        };
        watches.unbind(list_row);
        list_row.set_property("accessible-description", None::<String>);
    });
    column_view.set_row_factory(Some(&factory));
}

/// Through the property, since the setter takes no NULL to clear it.
fn describe(list_row: &gtk::ColumnViewRow, tab_ctx: &TabGridContext, row: &RowObject) {
    list_row.set_property(
        "accessible-description",
        row_description(tab_ctx.row_pending_state(row)),
    );
}

#[cfg(test)]
mod tests {
    use gtk4 as gtk;
    use gtk4::prelude::*;
    use tablepro_core::Value;
    use tablepro_core::edit::CellInput;

    use crate::services::tracker_edit::TrackerEdit;
    use crate::test_support::wait_until;
    use crate::ui::grid::test_grid::{WAIT, key, two_text_rows};

    #[gtk4::test]
    fn pending_delete_sets_row_widget_description() {
        let grid = two_text_rows();
        let cell = grid.cell_of(1, 1);
        let row = cell.parent().and_then(|cell| cell.parent()).expect("the row widget");
        let described = || gtk::test_accessible_has_property(&row, gtk::AccessibleProperty::Description);
        assert!(gtk::test_accessible_has_role(&row, gtk::AccessibleRole::Row));
        assert!(!described());
        assert!(!row.is_focusable(), "a row took the focus a cell should");

        grid.redraw(&grid.tracker.apply(TrackerEdit::DeleteRows {
            persisted: vec![(key(1), vec![Value::Int(1), Value::Text("A".into())].into())],
            drafts: Vec::new(),
        }));
        assert!(described(), "a row marked for deletion said nothing");

        grid.redraw(&grid.tracker.undo().expect("a delete to undo"));
        assert!(!described(), "a restored row still read as marked");
    }

    #[gtk4::test]
    fn a_new_row_is_described_and_its_cells_are_not() {
        let grid = two_text_rows();
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
        let row = draft.parent().and_then(|cell| cell.parent()).expect("the row widget");
        // A NULL is named whatever the row, so the cell holds a value.
        let draft_id = draft.row().and_then(|row| row.draft_id()).expect("a draft");
        grid.redraw(&grid.tracker.apply(TrackerEdit::DraftCell {
            draft_id,
            col: draft.column(),
            input: CellInput::Value(Value::Text("typed".into())),
        }));

        assert!(gtk::test_accessible_has_property(
            &row,
            gtk::AccessibleProperty::Description
        ));
        assert!(!gtk::test_accessible_has_property(
            &draft,
            gtk::AccessibleProperty::Description
        ));
    }
}
