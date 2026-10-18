use gtk4::prelude::*;

/// Mark a row as holding a mistake, or clear the mark.
///
/// The red style alone says nothing to a screen reader, so the row, and
/// the field inside it that takes the focus, are flagged invalid and
/// carry the sentence.
pub fn show_problem(row: &impl IsA<gtk4::Widget>, problem: Option<&str>) {
    let row = row.as_ref();
    match problem {
        Some(message) => {
            row.add_css_class("error");
            row.set_tooltip_text(Some(message));
        }
        None => {
            row.remove_css_class("error");
            row.set_tooltip_text(None);
        }
    }
    crate::ui::a11y::show_invalid(row, problem);
}
