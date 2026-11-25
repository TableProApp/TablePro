use gtk4 as gtk;
use gtk4::prelude::*;

use super::aria_key_shortcuts;

// An icon has no text of its own, and the keys go on the accessible node so a reader announces them in its own words.
pub(crate) fn describe_icon_button(widget: &impl IsA<gtk::Widget>, label: &str, action: Option<&str>) {
    let widget = widget.as_ref();
    widget.set_tooltip_text(Some(label));
    widget.update_property(&[gtk::accessible::Property::Label(label)]);
    if let Some(action) = action {
        announce_key_shortcuts(widget, action);
    }
}

// The keymap writes the keys again after a shortcut preset change.
pub(crate) fn announce_key_shortcuts(widget: &impl IsA<gtk::Accessible>, action: &str) {
    crate::application::keymap::follow_key_shortcuts(widget.upcast_ref(), Some(action));
}

pub(crate) fn withdraw_key_shortcuts(widget: &impl IsA<gtk::Accessible>) {
    crate::application::keymap::follow_key_shortcuts(widget.upcast_ref(), None);
}

pub(crate) fn write_key_shortcuts(accessible: &gtk::Accessible, triggers: &[String]) {
    let accels: Vec<&str> = triggers.iter().map(String::as_str).collect();
    match aria_key_shortcuts(&accels) {
        Some(keys) => accessible.update_property(&[gtk::accessible::Property::KeyShortcuts(&keys)]),
        None => accessible.reset_property(gtk::AccessibleProperty::KeyShortcuts),
    }
}

#[cfg(test)]
mod tests {
    use gtk4::AccessibleProperty;

    use super::*;

    #[gtk4::test]
    fn icon_button_gets_label_tooltip_and_its_actions_keys() {
        let button = gtk::Button::from_icon_name("list-add-symbolic");

        describe_icon_button(&button, "Insert Row", Some("grid.insert-row"));

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

    #[gtk4::test]
    fn a_button_described_before_a_preset_change_announces_the_keys_in_force() {
        let back = crate::application::keymap::BackToTablePro;
        let button = gtk::Button::from_icon_name("edit-copy-symbolic");
        describe_icon_button(&button, "Duplicate Rows", Some("grid.duplicate-rows"));
        let announces = || gtk::test_accessible_has_property(&button, AccessibleProperty::KeyShortcuts);
        assert!(!announces(), "TablePro gives Duplicate Rows no key");

        crate::application::keymap::apply(&gtk::Application::builder().build(), "tableplus");
        assert!(announces(), "the preset's Ctrl+D was not announced");

        drop(back);
        assert!(!announces(), "the preset's key stayed after TablePro's came back");
    }
}
