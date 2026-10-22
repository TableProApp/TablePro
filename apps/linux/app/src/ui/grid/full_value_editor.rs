use gtk4::prelude::*;
use gtk4::{self as gtk};
use relm4::adw;
use relm4::adw::prelude::*;
use serde_json::value::RawValue;
use tablepro_core::{ColumnInfo, Value};

const MAX_EDIT_BYTES: usize = 1024 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum FullValueKind {
    Text,
    Json,
    JsonText,
    JsonFallbackText,
}

impl FullValueKind {
    fn supports_format(self) -> bool {
        matches!(self, Self::Json)
    }
}

#[derive(Debug, PartialEq, Eq)]
enum PayloadError {
    TooLarge,
    InvalidJson { line: usize, column: usize },
}

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

pub(crate) fn is_json_column(data_type: &str) -> bool {
    ["json", "jsonb"]
        .iter()
        .any(|name| base_type(data_type).eq_ignore_ascii_case(name))
}

pub(crate) fn is_full_value_column(data_type: &str) -> bool {
    is_text_column(data_type) || is_json_column(data_type)
}

fn base_type(data_type: &str) -> &str {
    let normalized = data_type.trim();
    let unwrapped = if normalized.len() >= "nullable(".len()
        && normalized
            .get(.."nullable(".len())
            .is_some_and(|prefix| prefix.eq_ignore_ascii_case("nullable("))
        && normalized.ends_with(')')
    {
        &normalized["nullable(".len()..normalized.len() - 1]
    } else {
        normalized
    };
    unwrapped.split('(').next().unwrap_or_default().trim()
}

pub(super) fn edit_kind(data_type: &str, value: &Value) -> Option<FullValueKind> {
    if is_text_column(data_type) {
        return matches!(value, Value::Text(_) | Value::Null).then_some(FullValueKind::Text);
    }
    if !is_json_column(data_type) {
        return None;
    }
    Some(match value {
        Value::Json(_) => FullValueKind::Json,
        Value::JsonText(_) => FullValueKind::JsonText,
        Value::Text(_) => FullValueKind::JsonFallbackText,
        Value::Null if base_type(data_type).eq_ignore_ascii_case("jsonb") => FullValueKind::Json,
        Value::Null => FullValueKind::JsonText,
        _ => return None,
    })
}

pub(crate) fn can_stage_full_value(column: &ColumnInfo, current: &Value, edited: &Value) -> bool {
    if !super::cell_allows_inline_edit(column, current) {
        return false;
    }
    if is_text_column(&column.data_type) {
        return matches!(current, Value::Text(_) | Value::Null)
            && matches!(edited, Value::Text(text) if text.len() <= MAX_EDIT_BYTES);
    }
    if !is_json_column(&column.data_type) {
        return false;
    }
    json_edit_is_bounded(current, edited)
}

fn json_edit_is_bounded(current: &Value, edited: &Value) -> bool {
    match (current, edited) {
        (Value::JsonText(_), Value::JsonText(text)) | (Value::Text(_), Value::Text(text)) => valid_json_text(text),
        (Value::Json(_), Value::Json(value)) => json_serialized_size(value).is_some_and(|size| size <= MAX_EDIT_BYTES),
        (Value::Null, Value::JsonText(text)) | (Value::Null, Value::Text(text)) => valid_json_text(text),
        (Value::Null, Value::Json(value)) => json_serialized_size(value).is_some_and(|size| size <= MAX_EDIT_BYTES),
        _ => false,
    }
}

fn valid_json_text(text: &str) -> bool {
    text.len() <= MAX_EDIT_BYTES && serde_json::from_str::<Box<RawValue>>(text).is_ok()
}

fn json_serialized_size(value: &serde_json::Value) -> Option<usize> {
    let mut counter = ByteCounter(0);
    serde_json::to_writer(&mut counter, value).ok()?;
    Some(counter.0)
}

struct ByteCounter(usize);

impl std::io::Write for ByteCounter {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.0 = self
            .0
            .checked_add(bytes.len())
            .ok_or_else(|| std::io::Error::other("serialized JSON size overflow"))?;
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

fn full_value_payload(kind: FullValueKind, text: &str) -> Result<Value, PayloadError> {
    if text.len() > MAX_EDIT_BYTES {
        return Err(PayloadError::TooLarge);
    }
    match kind {
        FullValueKind::Text => Ok(Value::Text(text.to_owned())),
        FullValueKind::Json => serde_json::from_str(text).map(Value::Json).map_err(invalid_json_error),
        FullValueKind::JsonText => {
            serde_json::from_str::<Box<RawValue>>(text).map_err(invalid_json_error)?;
            Ok(Value::JsonText(text.to_owned()))
        }
        FullValueKind::JsonFallbackText => {
            serde_json::from_str::<Box<RawValue>>(text).map_err(invalid_json_error)?;
            Ok(Value::Text(text.to_owned()))
        }
    }
}

fn format_json_text(text: &str) -> Result<String, serde_json::Error> {
    serde_json::from_str::<serde_json::Value>(text).and_then(|value| serde_json::to_string_pretty(&value))
}

fn invalid_json_error(error: serde_json::Error) -> PayloadError {
    PayloadError::InvalidJson {
        line: error.line(),
        column: error.column(),
    }
}

pub(super) fn within_edit_budget(size: usize) -> bool {
    size <= MAX_EDIT_BYTES
}

pub(super) struct EditContext {
    pub(super) row_position: u32,
    pub(super) col_index: usize,
    pub(super) row_key: Vec<Value>,
    pub(super) nullable: bool,
    pub(super) kind: FullValueKind,
    pub(super) sender: relm4::Sender<super::GridMsg>,
}

struct EditorActions {
    container: gtk::Box,
    apply: gtk::Button,
    cancel: gtk::Button,
    set_null: Option<gtk::Button>,
    format: Option<gtk::Button>,
}

pub(super) fn present(
    parent: &impl IsA<gtk::Widget>,
    column_name: &str,
    initial_text: &str,
    context: EditContext,
) -> adw::Dialog {
    let view = create_text_view(initial_text);
    let actions = create_actions(context.nullable, context.kind.supports_format());
    let (content, error) = create_content(&view, &actions.container);
    let dialog = create_dialog(column_name, &content);
    connect_actions(&dialog, &view.buffer(), &error, actions, &context);
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

fn create_actions(nullable: bool, is_json: bool) -> EditorActions {
    let apply = gtk::Button::with_label(&crate::tr!("Apply"));
    apply.add_css_class("suggested-action");
    let cancel = gtk::Button::with_label(&crate::tr!("Cancel"));
    let format = is_json.then(|| gtk::Button::with_label(&crate::tr!("Format JSON")));
    let container = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(8)
        .halign(gtk::Align::End)
        .build();
    let set_null = nullable.then(|| gtk::Button::with_label(&crate::tr!("Set to NULL")));
    if let Some(button) = &set_null {
        container.append(button);
    }
    if let Some(button) = &format {
        container.append(button);
    }
    container.append(&cancel);
    container.append(&apply);
    EditorActions {
        container,
        apply,
        cancel,
        set_null,
        format,
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
    context: &EditContext,
) {
    let error_for_change = error.clone();
    buffer.connect_changed(move |_| error_for_change.set_visible(false));
    connect_cancel(&actions.cancel, dialog);
    connect_set_null(actions.set_null, dialog, context);
    connect_format(actions.format, buffer, error);
    connect_apply(&actions.apply, dialog, buffer, error, context);
}

fn connect_cancel(button: &gtk::Button, dialog: &adw::Dialog) {
    let dialog = dialog.clone();
    button.connect_clicked(move |_| {
        dialog.close();
    });
}

fn connect_set_null(button: Option<gtk::Button>, dialog: &adw::Dialog, context: &EditContext) {
    let Some(button) = button else { return };
    let sender = context.sender.clone();
    let row_key = context.row_key.clone();
    let row_position = context.row_position;
    let col_index = context.col_index;
    let dialog = dialog.clone();
    button.connect_clicked(move |_| {
        sender
            .send(super::GridMsg::SetCellNull {
                row_position,
                col_index,
                row_key: row_key.clone(),
            })
            .ok();
        dialog.close();
    });
}

fn connect_format(button: Option<gtk::Button>, buffer: &gtk::TextBuffer, error: &gtk::Label) {
    let Some(button) = button else { return };
    let buffer = buffer.clone();
    let error = error.clone();
    button.connect_clicked(move |_| {
        let text = buffer.text(&buffer.start_iter(), &buffer.end_iter(), true);
        match format_json_text(text.as_str()) {
            Ok(formatted) => buffer.set_text(&formatted),
            Err(json_error) => show_json_error(&error, json_error.line(), json_error.column()),
        }
    });
}

fn connect_apply(
    button: &gtk::Button,
    dialog: &adw::Dialog,
    buffer: &gtk::TextBuffer,
    error: &gtk::Label,
    context: &EditContext,
) {
    let dialog = dialog.clone();
    let buffer = buffer.clone();
    let error = error.clone();
    let context = EditContext {
        row_position: context.row_position,
        col_index: context.col_index,
        row_key: context.row_key.clone(),
        nullable: context.nullable,
        kind: context.kind,
        sender: context.sender.clone(),
    };
    button.connect_clicked(move |_| {
        let text = buffer.text(&buffer.start_iter(), &buffer.end_iter(), true);
        let value = match full_value_payload(context.kind, text.as_str()) {
            Ok(value) => value,
            Err(payload_error) => {
                show_payload_error(&error, payload_error);
                return;
            }
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
        dialog.close();
    });
}

fn show_payload_error(label: &gtk::Label, error: PayloadError) {
    match error {
        PayloadError::TooLarge => label.set_text(&crate::tr!("Values over 1 MiB cannot be edited in this dialog.")),
        PayloadError::InvalidJson { line, column } => show_json_error(label, line, column),
    }
    label.set_visible(true);
}

fn show_json_error(label: &gtk::Label, line: usize, column: usize) {
    label.set_text(&format!(
        "{} {}, {} {}.",
        crate::tr!("Invalid JSON at line"),
        line,
        crate::tr!("column"),
        column
    ));
    label.set_visible(true);
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
        assert_eq!(
            full_value_payload(FullValueKind::Text, ""),
            Ok(Value::Text(String::new()))
        );
        assert_eq!(
            full_value_payload(FullValueKind::Text, "first\r\nsecond  \n"),
            Ok(Value::Text("first\r\nsecond  \n".into()))
        );
    }

    #[test]
    fn text_payload_refuses_values_above_the_edit_budget() {
        assert_eq!(
            full_value_payload(FullValueKind::Text, &"x".repeat(MAX_EDIT_BYTES + 1)),
            Err(PayloadError::TooLarge)
        );
        assert!(full_value_payload(FullValueKind::Text, &"x".repeat(MAX_EDIT_BYTES)).is_ok());
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
    fn text_editor_staging_enforces_the_size_budget() {
        let column = ColumnInfo {
            name: "notes".into(),
            data_type: "varchar(40)".into(),
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
        assert!(is_text_column(&column.data_type));
        assert!(can_stage_full_value(
            &column,
            &Value::Text("before".into()),
            &Value::Text("x".repeat(MAX_EDIT_BYTES))
        ));
        assert!(!can_stage_full_value(
            &column,
            &Value::Text("before".into()),
            &Value::Text("x".repeat(MAX_EDIT_BYTES + 1))
        ));
        assert!(!is_text_column("jsonb"));
    }

    #[test]
    fn full_value_editor_accepts_exact_json_text_and_json_carriers() {
        let column = ColumnInfo {
            name: "payload".into(),
            data_type: "json".into(),
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
        let original = Value::JsonText(r#"{ "b": 1, "a": 2, "b": 3 }"#.into());
        let edited = Value::JsonText(r#"{ "b": 4, "a": 5, "b": 6 }"#.into());
        assert!(can_stage_full_value(&column, &original, &edited));
        assert!(can_stage_full_value(
            &column,
            &Value::Json(Box::new(serde_json::json!({"before": 1}))),
            &Value::Json(Box::new(serde_json::json!({"after": 2})))
        ));
        assert!(can_stage_full_value(
            &column,
            &Value::Text(r#"{"before":1}"#.into()),
            &Value::Text(r#"{"after":2}"#.into())
        ));
        assert!(!can_stage_full_value(
            &column,
            &original,
            &Value::JsonText("{invalid".into())
        ));
        assert!(!can_stage_full_value(
            &column,
            &Value::Null,
            &Value::JsonText("x".repeat(MAX_EDIT_BYTES + 1))
        ));
    }

    #[test]
    fn json_column_and_value_kind_detection_preserves_carrier_identity() {
        assert!(is_full_value_column("JSON"));
        assert!(is_full_value_column("Nullable(JSONB)"));
        assert!(is_json_column("Nullable(JSONB)"));
        assert_eq!(
            edit_kind("json", &Value::JsonText("{}".into())),
            Some(FullValueKind::JsonText)
        );
        assert_eq!(
            edit_kind("jsonb", &Value::Json(Box::new(serde_json::json!({})))),
            Some(FullValueKind::Json)
        );
        assert_eq!(edit_kind("json", &Value::Null), Some(FullValueKind::JsonText));
        assert_eq!(edit_kind("jsonb", &Value::Null), Some(FullValueKind::Json));
        assert_eq!(
            edit_kind("json", &Value::Text("{}".into())),
            Some(FullValueKind::JsonFallbackText)
        );
        assert!(!FullValueKind::JsonText.supports_format());
        assert!(FullValueKind::Json.supports_format());
    }

    #[test]
    fn json_payload_keeps_source_text_and_semantic_json_distinct() {
        let source = "{ \"n\": 900719925474099312345, \"k\": 1, \"k\": 2 }";
        assert_eq!(
            full_value_payload(FullValueKind::JsonText, source),
            Ok(Value::JsonText(source.into()))
        );
        assert!(matches!(
            full_value_payload(FullValueKind::Json, source),
            Ok(Value::Json(_))
        ));
        assert_eq!(
            full_value_payload(FullValueKind::JsonFallbackText, "null"),
            Ok(Value::Text("null".into()))
        );
        assert!(matches!(
            full_value_payload(FullValueKind::Json, "null"),
            Ok(Value::Json(value)) if value.is_null()
        ));
        assert!(matches!(
            full_value_payload(FullValueKind::JsonText, "null"),
            Ok(Value::JsonText(value)) if value == "null"
        ));
        assert!(matches!(
            full_value_payload(FullValueKind::JsonText, "{invalid"),
            Err(PayloadError::InvalidJson { .. })
        ));
    }

    #[test]
    fn formatting_json_is_explicit_and_preserves_large_number_lexemes() {
        let formatted = format_json_text(r#"{"value":900719925474099312345,"items":[1,2]}"#).unwrap();
        assert_eq!(
            formatted,
            "{\n  \"value\": 900719925474099312345,\n  \"items\": [\n    1,\n    2\n  ]\n}"
        );
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
        assert!(can_stage_full_value(&column, &Value::Null, &Value::Text("".into())));
        assert!(!can_stage_full_value(
            &column,
            &Value::Int(1),
            &Value::Text("new".into())
        ));
        assert!(!can_stage_full_value(
            &column,
            &Value::Text("old".into()),
            &Value::Int(2)
        ));
        let mut key_column = column;
        key_column.primary_key = true;
        assert!(!can_stage_full_value(
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
                kind: FullValueKind::Text,
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
    fn invalid_json_stages_nothing_and_valid_apply_keeps_json_typed() {
        gtk::init().unwrap();
        adw::init().unwrap();
        let parent = adw::Window::new();
        parent.present();
        let (sender, receiver) = relm4::channel::<super::super::GridMsg>();
        let dialog = present(
            &parent,
            "payload",
            r#"{"before":1}"#,
            EditContext {
                row_position: 2,
                col_index: 1,
                row_key: vec![Value::Int(9)],
                nullable: true,
                kind: FullValueKind::Json,
                sender,
            },
        );
        let root = dialog.child().unwrap().upcast_ref::<gtk::Widget>().clone();
        let buffer = text_view(&root).buffer();
        assert!(button(&root, &crate::tr!("Format JSON")).is_sensitive());
        buffer.set_text("{invalid");
        button(&root, &crate::tr!("Apply")).emit_clicked();
        assert!(receiver.recv().now_or_never().flatten().is_none());
        buffer.set_text(r#"{"after":2}"#);
        button(&root, &crate::tr!("Apply")).emit_clicked();
        assert!(matches!(
            receiver.recv().now_or_never().flatten(),
            Some(super::super::GridMsg::CellEditedValue {
                row_position: 2,
                col_index: 1,
                value: Value::Json(value),
                row_key,
            }) if value["after"] == 2 && row_key == vec![Value::Int(9)]
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
                kind: FullValueKind::Text,
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
                kind: FullValueKind::Text,
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
