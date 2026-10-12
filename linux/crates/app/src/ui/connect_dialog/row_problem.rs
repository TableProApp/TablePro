use gtk4::prelude::*;

/// Mark a row as holding a mistake, or clear the mark.
///
/// The red style alone says nothing to a screen reader, so the row is
/// also flagged invalid and carries the sentence as its tooltip.
pub fn show_problem(row: &impl IsA<gtk4::Widget>, problem: Option<&str>) {
    let row = row.as_ref();
    match problem {
        Some(message) => {
            row.add_css_class("error");
            row.set_tooltip_text(Some(message));
            row.update_state(&[gtk4::accessible::State::Invalid(gtk4::AccessibleInvalidState::True)]);
        }
        None => {
            row.remove_css_class("error");
            row.set_tooltip_text(None);
            row.reset_state(gtk4::AccessibleState::Invalid);
        }
    }
}
