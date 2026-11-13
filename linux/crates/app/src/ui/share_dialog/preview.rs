use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::{gio, glib};
use tablepro_core::column::ResultColumn;

use crate::i18n::gettext;
use crate::services::grid::{RowSnapshot, display_text};

pub(crate) const PREVIEW_ROWS: usize = 5;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct PreviewCell {
    pub text: String,
    // NULL, a blob's size or an unreadable value: shown dimmed, as the grid shows it.
    pub placeholder: bool,
}

pub(crate) fn preview_cells(columns: &[ResultColumn], rows: &[RowSnapshot]) -> Vec<Vec<PreviewCell>> {
    let mut scratch = String::new();
    rows.iter()
        .take(PREVIEW_ROWS)
        .map(|row| {
            columns
                .iter()
                .enumerate()
                .map(|(index, column)| {
                    let shown = display_text(row.value(index), &column.column_type, &mut scratch);
                    PreviewCell {
                        text: first_line(shown.text),
                        placeholder: shown.placeholder,
                    }
                })
                .collect()
        })
        .collect()
}

// One line per cell, as the grid draws it.
fn first_line(text: &str) -> String {
    match text.split_once(['\n', '\r']) {
        Some((first, _)) => format!("{first}…"),
        None => text.to_owned(),
    }
}

// A sample of what the link carries, so it takes no selection, menu or edit, which a DataGrid would offer.
pub(crate) fn preview_table(columns: &[ResultColumn], rows: &[RowSnapshot]) -> gtk::Widget {
    let store = gio::ListStore::new::<glib::BoxedAnyObject>();
    for row in preview_cells(columns, rows) {
        store.append(&glib::BoxedAnyObject::new(row));
    }
    let view = gtk::ColumnView::builder()
        .model(&gtk::NoSelection::new(Some(store)))
        .reorderable(false)
        .css_classes(["data-table"])
        .build();
    for (index, column) in columns.iter().enumerate() {
        let shown = gtk::ColumnViewColumn::new(Some(&column.name), Some(cell_factory(index)));
        shown.set_resizable(true);
        view.append_column(&shown);
    }
    view.update_property(&[gtk::accessible::Property::Label(&gettext("Rows that will be shared"))]);
    gtk::ScrolledWindow::builder()
        .vscrollbar_policy(gtk::PolicyType::Never)
        .hscrollbar_policy(gtk::PolicyType::Automatic)
        .propagate_natural_height(true)
        .css_classes(["card"])
        .overflow(gtk::Overflow::Hidden)
        .child(&view)
        .build()
        .upcast()
}

fn cell_factory(index: usize) -> gtk::SignalListItemFactory {
    let factory = gtk::SignalListItemFactory::new();
    factory.connect_setup(|_, object| {
        if let Some(item) = object.downcast_ref::<gtk::ColumnViewCell>() {
            let label = gtk::Label::builder()
                .xalign(0.0)
                .ellipsize(gtk::pango::EllipsizeMode::End)
                .max_width_chars(32)
                .single_line_mode(true)
                .build();
            item.set_child(Some(&label));
        }
    });
    factory.connect_bind(move |_, object| {
        let Some(item) = object.downcast_ref::<gtk::ColumnViewCell>() else {
            return;
        };
        let (Some(label), Some(row)) = (
            item.child().and_downcast::<gtk::Label>(),
            item.item().and_downcast::<glib::BoxedAnyObject>(),
        ) else {
            return;
        };
        let row = row.borrow::<Vec<PreviewCell>>();
        let Some(cell) = row.get(index) else {
            return;
        };
        label.set_label(&cell.text);
        if cell.placeholder {
            label.add_css_class("dim-label");
        } else {
            label.remove_css_class("dim-label");
        }
    });
    factory
}

#[cfg(test)]
mod tests {
    use tablepro_core::Value;
    use tablepro_core::column::ColumnType;

    use super::*;

    #[test]
    fn the_preview_takes_five_rows_and_writes_cells_as_the_grid_does() {
        let columns = [
            ResultColumn::new("name", ColumnType::untyped_text("text")),
            ResultColumn::new("note", ColumnType::untyped_text("text")),
        ];
        let rows: Vec<RowSnapshot> = (0..8)
            .map(|index| {
                RowSnapshot::new(
                    vec![Value::Text(format!("row {index}")), Value::Null].into(),
                    vec![(1, Value::Text("first\nsecond".to_owned()))],
                )
            })
            .collect();

        let cells = preview_cells(&columns, &rows);

        assert_eq!(cells.len(), PREVIEW_ROWS);
        assert_eq!(
            cells[4],
            [
                PreviewCell {
                    text: "row 4".to_owned(),
                    placeholder: false
                },
                PreviewCell {
                    text: "first…".to_owned(),
                    placeholder: false
                },
            ]
        );
    }

    #[test]
    fn a_null_cell_is_a_placeholder() {
        let columns = [ResultColumn::new("note", ColumnType::untyped_text("text"))];
        let rows = [RowSnapshot::new(vec![Value::Null].into(), Vec::new())];

        let cells = preview_cells(&columns, &rows);

        assert_eq!(cells[0][0].text, "NULL");
        assert!(cells[0][0].placeholder);
    }
}
