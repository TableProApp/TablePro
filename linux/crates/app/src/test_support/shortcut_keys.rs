use std::collections::HashSet;

use gtk4 as gtk;
use gtk4::gdk;
use gtk4::prelude::*;

use super::descendants;
use crate::application::{ShortcutOwner, keypad_twins};

/// A key with its modifiers, keyval lowered as GtkKeyvalTrigger stores it.
pub(crate) type Keystroke = (gdk::Key, gdk::ModifierType);

/// The name GTK gives the controller that runs a widget class's bindings.
const CLASS_SHORTCUTS: &str = "gtk-widget-class-shortcuts";

pub(crate) fn keystroke(accel: &str) -> Keystroke {
    let (key, modifiers) = gtk::accelerator_parse(accel).unwrap_or_else(|| panic!("{accel} does not parse"));
    (key.to_lower(), modifiers)
}

/// `accel` and the keypad twins the table binds beside it.
pub(crate) fn keystrokes_with_twins(accel: &str) -> Vec<Keystroke> {
    let (key, modifiers) = keystroke(accel);
    std::iter::once(key)
        .chain(keypad_twins(key).iter().copied())
        .map(|key| (key.to_lower(), modifiers))
        .collect()
}

pub(crate) fn trigger_keys(trigger: &gtk::ShortcutTrigger) -> Vec<Keystroke> {
    let mut keys = Vec::new();
    collect_trigger_keys(trigger, &mut keys);
    keys
}

fn collect_trigger_keys(trigger: &gtk::ShortcutTrigger, into: &mut Vec<Keystroke>) {
    if let Some(keyval) = trigger.downcast_ref::<gtk::KeyvalTrigger>() {
        into.push((keyval.keyval().to_lower(), keyval.modifiers()));
    } else if let Some(pair) = trigger.downcast_ref::<gtk::AlternativeTrigger>() {
        collect_trigger_keys(&pair.first(), into);
        collect_trigger_keys(&pair.second(), into);
    }
}

pub(crate) fn shortcuts(controller: &gtk::ShortcutController) -> Vec<gtk::Shortcut> {
    (0..controller.n_items())
        .filter_map(|position| controller.item(position).and_downcast::<gtk::Shortcut>())
        .collect()
}

pub(crate) fn shortcut_controllers(widget: &impl IsA<gtk::Widget>) -> Vec<gtk::ShortcutController> {
    let controllers = widget.as_ref().observe_controllers();
    (0..controllers.n_items())
        .filter_map(|position| controllers.item(position).and_downcast::<gtk::ShortcutController>())
        .collect()
}

pub(crate) fn controller_keys(controller: &gtk::ShortcutController) -> Vec<Keystroke> {
    shortcuts(controller)
        .iter()
        .filter_map(gtk::Shortcut::trigger)
        .flat_map(|trigger| trigger_keys(&trigger))
        .collect()
}

/// The controller `local_shortcut_controller` put on `widget` for
/// `owner`, if any.
pub(crate) fn owner_controller(
    widget: &impl IsA<gtk::Widget>,
    owner: ShortcutOwner,
) -> Option<gtk::ShortcutController> {
    let name = crate::application::controller_name(owner);
    shortcut_controllers(widget)
        .into_iter()
        .find(|controller| controller.name().is_some_and(|found| found == name))
}

/// The keys the classes of `widget` bind.
pub(crate) fn class_binding_keys(widget: &impl IsA<gtk::Widget>) -> HashSet<Keystroke> {
    shortcut_controllers(widget)
        .iter()
        .filter(|controller| controller.name().is_some_and(|name| name == CLASS_SHORTCUTS))
        .flat_map(controller_keys)
        .collect()
}

/// The class bindings a key meets on its way up to `owner` from any
/// focusable widget inside it, the owner's own included.
pub(crate) fn class_keys_on_focus_paths(
    owner: &impl IsA<gtk::Widget>,
    skip: impl Fn(&gtk::Widget) -> bool,
) -> HashSet<Keystroke> {
    let owner = owner.as_ref();
    let mut on_path: Vec<gtk::Widget> = vec![owner.clone()];
    for focusable in descendants(owner).into_iter().filter(|widget| widget.is_focusable()) {
        let mut widget = Some(focusable);
        while let Some(current) = widget {
            if &current == owner || on_path.contains(&current) {
                break;
            }
            widget = current.parent();
            on_path.push(current);
        }
    }
    on_path
        .iter()
        .filter(|widget| !skip(widget))
        .flat_map(class_binding_keys)
        .collect()
}
