use gtk4 as gtk;
use libadwaita::{self as adw, prelude::*};
use tablepro_core::Value;

use crate::services::change_tracker::EditStatement;

pub(super) fn preview_text(driver_id: &str, statements: &[EditStatement]) -> String {
    statements
        .iter()
        .map(|(sql, values)| {
            let sql = sql.trim_end_matches(';');
            if values.is_empty() {
                return format!("{sql};");
            }
            let values: Vec<String> = values
                .iter()
                .enumerate()
                .map(|(index, value)| format!("  {}: {}", index + 1, value_text(driver_id, value)))
                .collect();
            format!("{sql};\n-- values, in order\n{}", values.join("\n"))
        })
        .collect::<Vec<_>>()
        .join("\n\n")
}

const MAX_VALUE_CHARS: usize = 200;

fn value_text(driver_id: &str, value: &Value) -> String {
    let text =
        tablepro_core::sql_literal::render_sql_literal(driver_id, value).unwrap_or_else(|_| format!("{value:?}"));
    let total = text.chars().count();
    if total <= MAX_VALUE_CHARS {
        return text;
    }
    let shown: String = text.chars().take(MAX_VALUE_CHARS).collect();
    format!("{shown}… ({} more characters)", total - MAX_VALUE_CHARS)
}

pub(super) fn present(parent: &impl IsA<gtk::Widget>, text: &str) {
    let buffer = gtk::TextBuffer::new(Some(&gtk::TextTagTable::new()));
    buffer.set_text(text);
    let view = gtk::TextView::builder()
        .buffer(&buffer)
        .editable(false)
        .monospace(true)
        .wrap_mode(gtk::WrapMode::WordChar)
        .top_margin(12)
        .bottom_margin(12)
        .left_margin(12)
        .right_margin(12)
        .build();
    let scrolled = gtk::ScrolledWindow::builder().vexpand(true).child(&view).build();
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&adw::HeaderBar::new());
    toolbar.set_content(Some(&scrolled));
    let dialog = adw::Dialog::builder()
        .title(crate::tr!("Pending SQL"))
        .content_width(640)
        .content_height(420)
        .child(&toolbar)
        .build();
    dialog.present(Some(parent));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_statement_is_listed_with_its_values_in_order() {
        let statements: Vec<EditStatement> = vec![
            (
                "UPDATE \"t\" SET \"name\" = $1 WHERE \"id\" = $2".into(),
                vec![Value::Text("it's".into()), Value::Int(7)],
            ),
            ("DELETE FROM \"t\" WHERE \"id\" = $1;".into(), vec![Value::Int(9)]),
        ];
        let text = preview_text("postgres", &statements);
        assert_eq!(
            text,
            "UPDATE \"t\" SET \"name\" = $1 WHERE \"id\" = $2;\n-- values, in order\n  1: 'it''s'\n  2: 7\n\nDELETE FROM \"t\" WHERE \"id\" = $1;\n-- values, in order\n  1: 9"
        );
    }

    #[test]
    fn a_statement_without_values_is_shown_alone() {
        assert_eq!(
            preview_text("sqlite", &[("DELETE FROM t".into(), Vec::new())]),
            "DELETE FROM t;"
        );
    }

    #[test]
    fn a_very_long_value_is_cut_and_says_how_much_is_hidden() {
        let statements: Vec<EditStatement> = vec![("UPDATE t SET note = ?".into(), vec![Value::Text("x".repeat(500))])];
        let text = preview_text("sqlite", &statements);
        assert!(
            text.contains(&format!("{}…", "x".repeat(MAX_VALUE_CHARS - 1))),
            "{text}"
        );
        assert!(text.ends_with("(302 more characters)"), "{text}");
        assert!(text.len() < 400, "{}", text.len());
    }

    #[test]
    fn a_value_the_driver_cannot_render_as_a_literal_still_appears() {
        let statements: Vec<EditStatement> = vec![("UPDATE t SET x = ?".into(), vec![Value::Float(f64::NAN)])];
        assert!(preview_text("sqlite", &statements).contains("1: Float(NaN)"));
    }
}
