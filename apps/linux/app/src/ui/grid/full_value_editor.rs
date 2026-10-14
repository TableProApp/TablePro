use gtk4::prelude::*;
use gtk4::{self as gtk};
use relm4::adw;
use relm4::adw::prelude::*;
use tablepro_core::{ColumnInfo, Value};

const MAX_EDIT_BYTES: usize = 1024 * 1024;

pub(crate) fn is_text_column(data_type: &str) -> bool {
    let data_type = data_type.trim().to_ascii_lowercase();
    let base = data_type.split('(').next().unwrap_or_default().trim();
    matches!(
        base,
        "text"
            | "tinytext"
            | "mediumtext"
            | "longtext"
            | "ntext"
            | "citext"
            | "clob"
            | "nclob"
            | "xml"
            | "string"
            | "character varying"
            | "character"
            | "char"
            | "varchar"
            | "nvarchar"
            | "nchar"
    )
}

pub(crate) fn accepts_text_value(data_type: &str, value: &Value) -> bool {
    is_text_column(data_type) && matches!(value, Value::Text(text) if text.len() <= MAX_EDIT_BYTES)
}

pub(crate) fn can_stage_text_value(column: &ColumnInfo, current: &Value, edited: &Value) -> bool {
    accepts_text_value(&column.data_type, edited)
        && matches!(current, Value::Text(_) | Value::Null)
        && super::cell_allows_inline_edit(column, current)
}

pub(super) fn within_edit_budget(size: usize) -> bool {
    size <= MAX_EDIT_BYTES
}

fn text_payload(text: &str) -> Result<Value, ()> {
    if text.len() > MAX_EDIT_BYTES {
        return Err(());
    }
    Ok(Value::Text(text.to_owned()))
}

pub(super) struct EditContext {
    pub(super) row_position: u32,
    pub(super) col_index: usize,
    pub(super) row_key: Vec<Value>,
    pub(super) nullable: bool,
    pub(super) sender: relm4::Sender<super::GridMsg>,
}

struct EditorActions {
    container: gtk::Box,
    apply: gtk::Button,
    cancel: gtk::Button,
    set_null: Option<gtk::Button>,
}

pub(super) fn present(
    parent: &impl IsA<gtk::Widget>,
    column_name: &str,
    initial_text: &str,
    context: EditContext,
) -> adw::Dialog {
    let view = create_text_view(initial_text);
    let actions = create_actions(context.nullable);
    let (content, error) = create_content(&view, &actions.container);
    let dialog = create_dialog(column_name, &content);
    connect_actions(&dialog, &view.buffer(), &error, actions, context);
    dialog.present(Some(parent));
    dialog
}

fn create_text_view(initial_text: &str) -> gtk::TextView {
    let view = gtk::TextView::builder()
        .monospace(true)
        .wrap_mode(gtk::WrapMode::WordChar)
        .top_margin(8)
        .bottom_margin(8)
        .left_margin(12)
        .right_margin(12)
        .build();
    view.buffer().set_text(initial_text);
    view
}

fn create_actions(nullable: bool) -> EditorActions {
    let apply = gtk::Button::with_label(&crate::tr!("Apply"));
    apply.add_css_class("suggested-action");
    let cancel = gtk::Button::with_label(&crate::tr!("Cancel"));
    let container = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(8)
        .halign(gtk::Align::End)
        .build();
    let set_null = nullable.then(|| gtk::Button::with_label(&crate::tr!("Set to NULL")));
    if let Some(button) = &set_null {
        container.append(button);
    }
    container.append(&cancel);
    container.append(&apply);
    EditorActions {
        container,
        apply,
        cancel,
        set_null,
    }
}

fn create_content(view: &gtk::TextView, actions: &gtk::Box) -> (gtk::Box, gtk::Label) {
    let scroller = gtk::ScrolledWindow::builder()
        .child(view)
        .min_content_width(520)
        .min_content_height(320)
        .vexpand(true)
        .build();
    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(12)
        .margin_top(12)
        .margin_bottom(12)
        .margin_start(12)
        .margin_end(12)
        .build();
    content.append(&scroller);
    let error = gtk::Label::builder().xalign(0.0).visible(false).build();
    error.add_css_class("error");
    content.append(&error);
    content.append(actions);
    (content, error)
}

fn create_dialog(column_name: &str, content: &gtk::Box) -> adw::Dialog {
    let dialog = adw::Dialog::builder()
        .title(column_name)
        .content_width(720)
        .content_height(520)
        .child(content)
        .build();
    dialog
        .upcast_ref::<gtk::Widget>()
        .update_property(&[gtk::accessible::Property::Label(column_name)]);
    dialog
}

fn connect_actions(
    dialog: &adw::Dialog,
    buffer: &gtk::TextBuffer,
    error: &gtk::Label,
    actions: EditorActions,
    context: EditContext,
) {
    let error_for_change = error.clone();
    buffer.connect_changed(move |_| error_for_change.set_visible(false));
    let dialog_for_cancel = dialog.clone();
    actions.cancel.connect_clicked(move |_| {
        dialog_for_cancel.close();
    });
    if let Some(button) = actions.set_null {
        let null_sender = context.sender.clone();
        let null_row_key = context.row_key.clone();
        let dialog_for_null = dialog.clone();
        button.connect_clicked(move |_| {
            null_sender
                .send(super::GridMsg::SetCellNull {
                    row_position: context.row_position,
                    col_index: context.col_index,
                    row_key: null_row_key.clone(),
                })
                .ok();
            dialog_for_null.close();
        });
    }
    let dialog_for_apply = dialog.clone();
    let error_for_apply = error.clone();
    let buffer = buffer.clone();
    actions.apply.connect_clicked(move |_| {
        let start = buffer.start_iter();
        let end = buffer.end_iter();
        let text = buffer.text(&start, &end, true);
        let Ok(value) = text_payload(text.as_str()) else {
            error_for_apply.set_text(&crate::tr!("Values over 1 MiB cannot be edited in this dialog."));
            error_for_apply.set_visible(true);
            return;
        };
        context
            .sender
            .send(super::GridMsg::CellEditedValue {
                row_position: context.row_position,
                col_index: context.col_index,
                value,
                row_key: context.row_key.clone(),
            })
            .ok();
        dialog_for_apply.close();
    });
}

pub(super) fn present_too_large(parent: &impl IsA<gtk::Widget>) {
    let dialog = adw::AlertDialog::new(
        Some(&crate::tr!("Value is too large to edit")),
        Some(&crate::tr!("Values over 1 MiB cannot be edited in this dialog.")),
    );
    dialog.add_response("close", &crate::tr!("Close"));
    dialog.set_close_response("close");
    dialog.present(Some(parent));
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures::FutureExt;

    #[test]
    fn text_payload_preserves_empty_and_multiline_values_exactly() {
        assert_eq!(text_payload(""), Ok(tablepro_core::Value::Text(String::new())));
        assert_eq!(
            text_payload("first\r\nsecond  \n"),
            Ok(tablepro_core::Value::Text("first\r\nsecond  \n".into()))
        );
    }

    #[test]
    fn text_payload_refuses_values_above_the_edit_budget() {
        assert_eq!(text_payload(&"x".repeat(MAX_EDIT_BYTES + 1)), Err(()));
        assert!(text_payload(&"x".repeat(MAX_EDIT_BYTES)).is_ok());
    }

    #[test]
    fn text_column_detection_excludes_json_and_typed_values() {
        for data_type in ["text", "varchar(100)", "character varying(255)", "ntext"] {
            assert!(is_text_column(data_type));
        }
        for data_type in ["jsonb", "uuid", "decimal(20, 4)", "integer", "uuid[]"] {
            assert!(!is_text_column(data_type));
        }
    }

    #[test]
    fn only_bounded_text_values_from_text_columns_can_be_staged() {
        assert!(accepts_text_value("text", &Value::Text(String::new())));
        assert!(accepts_text_value(
            "varchar(40)",
            &Value::Text("multiline\r\nvalue".into())
        ));
        assert!(!accepts_text_value("jsonb", &Value::Text("{}".into())));
        assert!(!accepts_text_value("text", &Value::Null));
        assert!(!accepts_text_value(
            "text",
            &Value::Text("x".repeat(MAX_EDIT_BYTES + 1))
        ));
    }

    #[test]
    fn staging_rejects_noneditable_cells_and_nontext_values() {
        let column = ColumnInfo {
            name: "notes".into(),
            data_type: "text".into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            comment: None,
            default_value: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        };
        assert!(can_stage_text_value(&column, &Value::Null, &Value::Text("".into())));
        assert!(!can_stage_text_value(
            &column,
            &Value::Int(1),
            &Value::Text("new".into())
        ));
        assert!(!can_stage_text_value(
            &column,
            &Value::Text("old".into()),
            &Value::Int(2)
        ));
        let mut key_column = column;
        key_column.primary_key = true;
        assert!(!can_stage_text_value(
            &key_column,
            &Value::Text("old".into()),
            &Value::Text("new".into())
        ));
    }

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn applying_empty_text_stages_empty_text_without_converting_it_to_null() {
        gtk::init().unwrap();
        adw::init().unwrap();
        let parent = adw::Window::new();
        parent.present();
        let (sender, receiver) = relm4::channel::<super::super::GridMsg>();
        let dialog = present(
            &parent,
            "notes",
            "before",
            EditContext {
                row_position: 4,
                col_index: 2,
                row_key: vec![Value::Int(7)],
                nullable: true,
                sender,
            },
        );
        text_view(dialog.child().unwrap().upcast_ref()).buffer().set_text("");
        button(dialog.child().unwrap().upcast_ref(), &crate::tr!("Apply")).emit_clicked();
        assert!(matches!(
            receiver.recv().now_or_never().flatten(),
            Some(super::super::GridMsg::CellEditedValue {
                row_position: 4,
                col_index: 2,
                value: Value::Text(text),
                row_key,
            }) if text.is_empty() && row_key == vec![Value::Int(7)]
        ));
        parent.close();
    }

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn set_null_stages_null_and_cancel_stages_nothing() {
        gtk::init().unwrap();
        adw::init().unwrap();
        let parent = adw::Window::new();
        parent.present();
        let (sender, receiver) = relm4::channel::<super::super::GridMsg>();
        let dialog = present(
            &parent,
            "notes",
            "before",
            EditContext {
                row_position: 1,
                col_index: 0,
                row_key: vec![Value::Int(3)],
                nullable: true,
                sender,
            },
        );
        button(dialog.child().unwrap().upcast_ref(), &crate::tr!("Set to NULL")).emit_clicked();
        assert!(matches!(
            receiver.recv().now_or_never().flatten(),
            Some(super::super::GridMsg::SetCellNull {
                row_position: 1,
                col_index: 0,
                row_key,
            }) if row_key == vec![Value::Int(3)]
        ));
        let (sender, receiver) = relm4::channel::<super::super::GridMsg>();
        let dialog = present(
            &parent,
            "notes",
            "before",
            EditContext {
                row_position: 1,
                col_index: 0,
                row_key: vec![Value::Int(3)],
                nullable: true,
                sender,
            },
        );
        button(dialog.child().unwrap().upcast_ref(), &crate::tr!("Cancel")).emit_clicked();
        assert!(receiver.recv().now_or_never().flatten().is_none());
        parent.close();
    }

    fn button(root: &gtk::Widget, label: &str) -> gtk::Button {
        descendants(root)
            .into_iter()
            .filter_map(|widget| widget.downcast::<gtk::Button>().ok())
            .find(|button| button.label().as_deref() == Some(label))
            .unwrap()
    }

    fn text_view(root: &gtk::Widget) -> gtk::TextView {
        descendants(root)
            .into_iter()
            .find_map(|widget| widget.downcast::<gtk::TextView>().ok())
            .unwrap()
    }

    fn descendants(root: &gtk::Widget) -> Vec<gtk::Widget> {
        let mut pending = vec![root.clone()];
        let mut widgets = Vec::new();
        while let Some(widget) = pending.pop() {
            let mut child = widget.first_child();
            while let Some(next) = child {
                child = next.next_sibling();
                pending.push(next);
            }
            widgets.push(widget);
        }
        widgets
    }
}
