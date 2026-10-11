use gtk4 as gtk;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;

use tablepro_core::Value;

use super::display::{readonly_null_sentinel, value_to_full_edit_text};

const MAX_VIEW_BYTES: usize = 1 << 20;
const HEX_ROW_BYTES: usize = 16;
const HEX_MAX_BYTES: usize = 16 * 1024;

pub(super) fn body(value: &Value) -> String {
    let text = match value {
        Value::Null => readonly_null_sentinel(),
        Value::Bytes(bytes) if is_binary(bytes) => hex_dump(bytes),
        Value::Json(json) => serde_json::to_string_pretty(json).unwrap_or_else(|_| json.to_string()),
        other => pretty_if_json(value_to_full_edit_text(other)),
    };
    capped(text)
}

fn is_binary(bytes: &[u8]) -> bool {
    std::str::from_utf8(bytes).map_or(true, |text| text.contains('\0'))
}

fn pretty_if_json(text: String) -> String {
    let trimmed = text.trim_start();
    if !(trimmed.starts_with('{') || trimmed.starts_with('[')) {
        return text;
    }
    serde_json::from_str::<serde_json::Value>(&text)
        .ok()
        .and_then(|json| serde_json::to_string_pretty(&json).ok())
        .unwrap_or(text)
}

fn hex_dump(bytes: &[u8]) -> String {
    let shown = &bytes[..bytes.len().min(HEX_MAX_BYTES)];
    let mut out = String::new();
    for (row, chunk) in shown.chunks(HEX_ROW_BYTES).enumerate() {
        let mut hex = String::new();
        for (index, byte) in chunk.iter().enumerate() {
            if index == HEX_ROW_BYTES / 2 {
                hex.push(' ');
            }
            hex.push_str(&format!("{byte:02x} "));
        }
        let ascii: String = chunk
            .iter()
            .map(|byte| {
                if byte.is_ascii_graphic() || *byte == b' ' {
                    *byte as char
                } else {
                    '.'
                }
            })
            .collect();
        out.push_str(&format!("{:08x}  {hex:<49} |{ascii}|\n", row * HEX_ROW_BYTES));
    }
    if shown.len() < bytes.len() {
        out.push_str(
            &crate::tr!("Showing the first {shown} of {total} bytes.")
                .replace("{shown}", &shown.len().to_string())
                .replace("{total}", &bytes.len().to_string()),
        );
    }
    out
}

fn capped(text: String) -> String {
    if text.len() <= MAX_VIEW_BYTES {
        return text;
    }
    let mut end = MAX_VIEW_BYTES;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    let note = crate::tr!("Showing the first {shown} of {total} bytes. Copy value copies the whole value.")
        .replace("{shown}", &end.to_string())
        .replace("{total}", &text.len().to_string());
    format!("{}\n\n{note}", &text[..end])
}

pub(crate) fn present(parent: &impl IsA<gtk::Widget>, column: &str, value: &Value, copy_text: String) {
    let view = gtk::TextView::builder()
        .editable(false)
        .cursor_visible(false)
        .monospace(true)
        .wrap_mode(gtk::WrapMode::WordChar)
        .top_margin(8)
        .bottom_margin(8)
        .left_margin(12)
        .right_margin(12)
        .build();
    view.buffer().set_text(&body(value));
    let scroller = gtk::ScrolledWindow::builder().child(&view).vexpand(true).build();

    let copy = gtk::Button::with_label(&crate::tr!("Copy value"));
    copy.add_css_class("suggested-action");
    copy.connect_clicked(move |button| button.clipboard().set_text(&copy_text));
    let header = adw::HeaderBar::new();
    header.pack_end(&copy);
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&header);
    toolbar.set_content(Some(&scroller));

    let dialog = adw::Dialog::builder()
        .title(column)
        .content_width(640)
        .content_height(480)
        .child(&toolbar)
        .build();
    dialog
        .upcast_ref::<gtk::Widget>()
        .update_property(&[gtk::accessible::Property::Label(column)]);
    dialog.present(Some(parent));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_text_is_pretty_printed_and_plain_text_is_left_alone() {
        assert_eq!(body(&Value::Text(r#"{"a":1}"#.into())), "{\n  \"a\": 1\n}");
        assert_eq!(body(&Value::Text("{not json".into())), "{not json");
        assert_eq!(body(&Value::Text("hello".into())), "hello");
    }

    #[test]
    fn a_json_value_is_pretty_printed() {
        assert_eq!(body(&Value::Json(serde_json::json!([1, 2]))), "[\n  1,\n  2\n]");
    }

    #[test]
    fn null_reads_as_null() {
        assert_eq!(body(&Value::Null), readonly_null_sentinel());
    }

    #[test]
    fn binary_bytes_show_a_hex_dump_and_utf8_bytes_show_text() {
        let dump = body(&Value::Bytes(vec![0x00, 0x41, 0xff]));
        assert!(dump.starts_with("00000000  00 41 ff "));
        assert!(dump.trim_end().ends_with("|.A.|"));
        assert_eq!(body(&Value::Bytes(b"plain".to_vec())), "plain");
    }

    #[test]
    fn a_long_hex_dump_says_how_much_it_shows() {
        let dump = body(&Value::Bytes(vec![0u8; MAX_VIEW_BYTES]));
        assert!(dump.contains("Showing the first 16384 of 1048576 bytes."));
    }

    #[test]
    fn oversized_text_is_cut_on_a_character_boundary_with_a_note() {
        let text = "é".repeat(MAX_VIEW_BYTES);
        let shown = body(&Value::Text(text));
        assert!(shown.contains("Showing the first"));
        assert!(shown.len() < MAX_VIEW_BYTES + 200);
    }

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn the_viewer_dialog_builds_and_shows_the_full_value() {
        gtk::init().unwrap();
        adw::init().unwrap();
        let window = adw::Window::new();
        window.present();
        present(&window, "payload", &Value::Text(r#"{"a":1}"#.into()), "{}".into());
        let dialogs = window.observe_children().n_items();
        assert!(dialogs >= 1);
        window.close();
    }
}
