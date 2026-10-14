use gtk4::prelude::*;
use gtk4::{AccessibleProperty, AccessibleRelation, AccessibleRole, glib};
use libadwaita as adw;

use crate::test_support::descendants;

/// What a button shows, which decides whether only an accessible label
/// can name it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ButtonFace {
    NotAButton,
    /// A label, or content of its own, which is taken to carry text.
    Text,
    Icon,
    /// Neither yet: the code gives it one.
    Empty,
}

pub(crate) fn button_face(widget: &gtk4::Widget) -> ButtonFace {
    let face = |label: Option<glib::GString>, child: Option<gtk4::Widget>, icon: Option<glib::GString>| match (
        label.is_some_and(|label| !label.is_empty()),
        child,
        icon,
    ) {
        (true, ..) => ButtonFace::Text,
        (false, Some(child), _) if child.is::<gtk4::Image>() => ButtonFace::Icon,
        (false, Some(_), _) => ButtonFace::Text,
        (false, None, Some(_)) => ButtonFace::Icon,
        (false, None, None) => ButtonFace::Empty,
    };
    if let Some(button) = widget.downcast_ref::<gtk4::Button>() {
        return face(button.label(), button.child(), button.icon_name());
    }
    if let Some(button) = widget.downcast_ref::<gtk4::MenuButton>() {
        return face(button.label(), button.child(), button.icon_name());
    }
    if let Some(button) = widget.downcast_ref::<adw::SplitButton>() {
        return face(button.label(), button.child(), button.icon_name());
    }
    if widget.is::<adw::TabButton>() {
        return ButtonFace::Icon;
    }
    ButtonFace::NotAButton
}

pub(crate) fn is_icon_only(widget: &gtk4::Widget) -> bool {
    button_face(widget) == ButtonFace::Icon
}

pub(crate) fn has_accessible_label(widget: &gtk4::Widget) -> bool {
    gtk4::test_accessible_has_property(widget, AccessibleProperty::Label)
        || gtk4::test_accessible_has_relation(widget, AccessibleRelation::LabelledBy)
}

/// The icon-only buttons under `root` a screen reader reaches and cannot
/// name, each as its type and tooltip. The button inside a menu, split
/// or tab button is left out, since the outer one is the control.
pub(crate) fn unlabelled_icon_buttons(root: &impl IsA<gtk4::Widget>) -> Vec<String> {
    let root = root.as_ref();
    descendants(root)
        .into_iter()
        .filter(|widget| is_icon_only(widget) && !has_accessible_label(widget) && reachable(widget, root))
        .filter(|widget| {
            !matches!(
                widget.accessible_role(),
                AccessibleRole::None | AccessibleRole::Presentation
            )
        })
        .filter(|widget| {
            !widget.parent().is_some_and(|parent| {
                parent.is::<gtk4::MenuButton>() || parent.is::<adw::SplitButton>() || parent.is::<adw::TabButton>()
            })
        })
        .map(|widget| format!("{} {:?}", widget.type_().name(), widget.tooltip_text()))
        .collect()
}

/// Whether a screen reader reaches `widget`: it and every widget above
/// it up to `root` is shown, and every revealer on the way reveals.
fn reachable(widget: &gtk4::Widget, root: &gtk4::Widget) -> bool {
    let mut current = widget.clone();
    while &current != root {
        if !current.is_visible() || !current.is_child_visible() {
            return false;
        }
        let Some(parent) = current.parent() else {
            return true;
        };
        if &parent != root
            && parent
                .downcast_ref::<gtk4::Revealer>()
                .is_some_and(|revealer| !revealer.reveals_child())
        {
            return false;
        }
        current = parent;
    }
    true
}

/// The tooltips under `root` that spell out a key, which belongs on the
/// accessible node, where a screen reader says it in its own words.
pub(crate) fn tooltips_with_keys(root: &impl IsA<gtk4::Widget>) -> Vec<String> {
    descendants(root)
        .into_iter()
        .filter_map(|widget| widget.tooltip_text())
        .map(|tooltip| tooltip.to_string())
        .filter(|tooltip| tooltip.contains("Ctrl+"))
        .collect()
}
