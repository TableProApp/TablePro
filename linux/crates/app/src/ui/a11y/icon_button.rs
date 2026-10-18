use gtk4 as gtk;
use gtk4::prelude::*;

use super::aria_key_shortcuts;
use crate::application::triggers_for;

/// The tooltip names the button and the accessible label says the same,
/// since an icon has no text of its own. The keys go on the accessible
/// node, never in the tooltip, so they are announced in the reader's own
/// words.
pub(crate) fn describe_icon_button(widget: &impl IsA<gtk::Widget>, label: &str, action: Option<&str>) {
    let widget = widget.as_ref();
    widget.set_tooltip_text(Some(label));
    widget.update_property(&[gtk::accessible::Property::Label(label)]);
    if let Some(action) = action {
        announce_key_shortcuts(widget, action);
    }
}

/// The keys of `action`, from the accelerator table, on `widget`.
pub(crate) fn announce_key_shortcuts(widget: &impl IsA<gtk::Accessible>, action: &str) {
    if let Some(keys) = aria_key_shortcuts(triggers_for(action)) {
        widget.update_property(&[gtk::accessible::Property::KeyShortcuts(&keys)]);
    }
}

#[cfg(test)]
mod tests {
    use gtk4::AccessibleProperty;

    use super::*;

    #[gtk4::test]
    fn icon_button_gets_label_tooltip_and_its_actions_keys() {
        let button = gtk::Button::from_icon_name("list-add-symbolic");

        describe_icon_button(&button, "Insert Row", Some("browse.insert-row"));

        assert_eq!(button.tooltip_text().as_deref(), Some("Insert Row"));
        assert!(gtk::test_accessible_has_property(&button, AccessibleProperty::Label));
        assert!(gtk::test_accessible_has_property(
            &button,
            AccessibleProperty::KeyShortcuts
        ));
    }

    #[gtk4::test]
    fn an_action_without_keys_announces_none() {
        let button = gtk::Button::from_icon_name("go-first-symbolic");

        describe_icon_button(&button, "First Page", Some("browse.first-page"));

        assert!(!gtk::test_accessible_has_property(
            &button,
            AccessibleProperty::KeyShortcuts
        ));
    }
}
