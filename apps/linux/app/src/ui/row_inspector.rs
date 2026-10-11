use relm4::adw;
use relm4::gtk::{self, prelude::*};

use tablepro_core::{ColumnInfo, Value};

use super::grid::value_to_display_text;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct InspectorField {
    pub name: String,
    pub data_type: String,
    pub text: String,
    pub is_null: bool,
}

pub(crate) fn inspector_fields(columns: &[ColumnInfo], cells: &[Value]) -> Vec<InspectorField> {
    columns
        .iter()
        .enumerate()
        .map(|(index, column)| {
            let value = cells.get(index);
            InspectorField {
                name: column.name.clone(),
                data_type: column.data_type.clone(),
                text: match value {
                    None => crate::tr!("Not fetched"),
                    Some(Value::Undecodable(kind)) if kind == "not fetched" => crate::tr!("Not fetched"),
                    Some(value) => value_to_display_text(value),
                },
                is_null: matches!(value, Some(Value::Null)),
            }
        })
        .collect()
}

pub(crate) fn inspector_fields_for_row(
    columns: &[ColumnInfo],
    row: &crate::ui::row_object::RowObject,
) -> Vec<InspectorField> {
    let mut fields = inspector_fields(columns, &row.cells_clone());
    for (index, field) in fields.iter_mut().enumerate() {
        if let Some(preview) = row.cell_preview(index) {
            field.text = crate::ui::grid::preview_to_display_text(&preview);
        }
    }
    fields
}

#[derive(Clone)]
pub(crate) struct RowInspector {
    split: adw::OverlaySplitView,
    list: gtk::ListBox,
    stack: gtk::Stack,
}

impl RowInspector {
    pub(crate) fn new(content: &impl IsA<gtk::Widget>) -> Self {
        let list = gtk::ListBox::builder()
            .selection_mode(gtk::SelectionMode::None)
            .css_classes(["boxed-list"])
            .margin_top(12)
            .margin_bottom(12)
            .margin_start(12)
            .margin_end(12)
            .build();
        let placeholder = adw::StatusPage::builder()
            .title(crate::tr!("No row selected"))
            .description(crate::tr!("Select one row to see every column."))
            .icon_name("view-list-symbolic")
            .build();
        let stack = gtk::Stack::new();
        stack.add_named(&placeholder, Some("empty"));
        stack.add_named(
            &gtk::ScrolledWindow::builder().child(&list).vexpand(true).build(),
            Some("fields"),
        );
        stack.set_visible_child_name("empty");
        let split = adw::OverlaySplitView::builder()
            .sidebar_position(gtk::PackType::End)
            .show_sidebar(false)
            .collapsed(false)
            .min_sidebar_width(280.0)
            .max_sidebar_width(520.0)
            .sidebar(&stack)
            .content(content)
            .build();
        Self { split, list, stack }
    }

    pub(crate) fn widget(&self) -> &adw::OverlaySplitView {
        &self.split
    }

    pub(crate) fn set_visible(&self, visible: bool) {
        self.split.set_show_sidebar(visible);
    }

    #[cfg(test)]
    fn is_visible(&self) -> bool {
        self.split.shows_sidebar()
    }

    pub(crate) fn show_row(&self, fields: Option<Vec<InspectorField>>) {
        while let Some(child) = self.list.first_child() {
            self.list.remove(&child);
        }
        let Some(fields) = fields else {
            self.stack.set_visible_child_name("empty");
            return;
        };
        for field in fields {
            self.list.append(&field_row(&field));
        }
        self.stack.set_visible_child_name("fields");
    }

    #[cfg(test)]
    fn rows(&self) -> usize {
        let mut count = 0;
        let mut next = self.list.first_child();
        while let Some(child) = next {
            count += 1;
            next = child.next_sibling();
        }
        count
    }

    #[cfg(test)]
    fn showing_placeholder(&self) -> bool {
        self.stack.visible_child_name().as_deref() == Some("empty")
    }
}

fn field_row(field: &InspectorField) -> adw::ActionRow {
    let row = adw::ActionRow::builder()
        .title(format!("{} \u{b7} {}", field.name, field.data_type))
        .subtitle(&field.text)
        .subtitle_lines(0)
        .subtitle_selectable(true)
        .build();
    row.add_css_class("property");
    if field.is_null {
        row.add_css_class("dim-label");
    }
    row
}

#[cfg(test)]
mod tests {
    use super::*;

    fn column(name: &str, data_type: &str) -> ColumnInfo {
        ColumnInfo {
            name: name.into(),
            data_type: data_type.into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        }
    }

    #[test]
    fn every_column_distinguishes_sql_null_from_a_missing_value() {
        let columns = [column("id", "int"), column("name", "text"), column("extra", "text")];
        let fields = inspector_fields(&columns, &[Value::Int(7), Value::Null]);
        assert_eq!(fields.len(), 3);
        assert_eq!((fields[0].name.as_str(), fields[0].text.as_str()), ("id", "7"));
        assert!(fields[1].is_null);
        assert!(!fields[2].is_null);
        assert_eq!(fields[2].text, "Not fetched");
        assert_eq!(fields[1].data_type, "text");
    }

    #[test]
    fn long_value_inspection_shows_the_sample_and_native_byte_count() {
        let columns = [column("id", "int"), column("note", "text")];
        let row = crate::ui::row_object::RowObject::new(vec![Value::Int(7), Value::Text("a".repeat(9000))]);
        row.preview_long_values(&[0]);

        let fields = inspector_fields_for_row(&columns, &row);
        assert!(fields[1].text.starts_with(&"a".repeat(8192)));
        assert!(fields[1].text.ends_with("9000 bytes total)"));
    }

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn the_inspector_lists_a_row_and_returns_to_its_placeholder() {
        relm4::adw::init().unwrap();
        let inspector = RowInspector::new(&gtk::Box::new(gtk::Orientation::Vertical, 0));
        assert!(!inspector.is_visible());
        assert!(inspector.showing_placeholder());
        let columns = [column("id", "int"), column("note", "text")];
        inspector.show_row(Some(inspector_fields(
            &columns,
            &[Value::Int(1), Value::Text("hi".into())],
        )));
        assert_eq!(inspector.rows(), 2);
        assert!(!inspector.showing_placeholder());
        inspector.show_row(None);
        assert_eq!(inspector.rows(), 0);
        assert!(inspector.showing_placeholder());
        inspector.set_visible(true);
        assert!(inspector.is_visible());
    }
}
