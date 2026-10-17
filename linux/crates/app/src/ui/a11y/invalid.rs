use gtk4 as gtk;
use gtk4::prelude::*;

/// Flag `field` as holding a mistake, described by `problem`, or clear
/// both. An entry row or a search entry hands the focus to the text
/// field inside it, which is what a screen reader reads, so that field
/// carries them too.
pub(crate) fn show_invalid(field: &impl IsA<gtk::Widget>, problem: Option<&str>) {
    let field = field.as_ref();
    let delegate = field
        .downcast_ref::<gtk::Editable>()
        .and_then(|editable| editable.delegate())
        .map(|delegate| delegate.upcast::<gtk::Widget>());
    for widget in std::iter::once(field).chain(delegate.as_ref()) {
        match problem {
            Some(problem) => {
                widget.update_state(&[gtk::accessible::State::Invalid(gtk::AccessibleInvalidState::True)]);
                widget.update_property(&[gtk::accessible::Property::Description(problem)]);
            }
            None => {
                widget.reset_state(gtk::AccessibleState::Invalid);
                widget.reset_property(gtk::AccessibleProperty::Description);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use gtk4::{AccessibleProperty, AccessibleState};
    use libadwaita as adw;

    use super::*;

    #[gtk4::test]
    fn an_entry_row_flags_its_text_field() {
        adw::init().expect("libadwaita initialises under the test backend");
        let row = adw::EntryRow::builder().title("Name").build();
        let text = row
            .delegate()
            .and_downcast::<gtk::Text>()
            .expect("the row's text field");

        show_invalid(&row, Some("A name is required."));

        for widget in [row.upcast_ref::<gtk::Widget>(), text.upcast_ref()] {
            assert!(gtk::test_accessible_has_state(widget, AccessibleState::Invalid));
            assert!(gtk::test_accessible_has_property(
                widget,
                AccessibleProperty::Description
            ));
        }

        show_invalid(&row, None);

        assert!(!gtk::test_accessible_has_state(&text, AccessibleState::Invalid));
        assert!(!gtk::test_accessible_has_property(
            &text,
            AccessibleProperty::Description
        ));
    }
}
