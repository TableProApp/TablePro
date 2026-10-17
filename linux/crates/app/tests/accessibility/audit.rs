//! What a screen reader needs from each control the app puts on a page.

use std::fmt;

use gtk4::glib;
use gtk4::prelude::*;
use gtk4::{AccessibleProperty, AccessibleRelation, AccessibleRole};
use libadwaita as adw;
use libadwaita::prelude::*;

/// What a control lacks for a screen reader to name it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Missing {
    /// Neither an accessible label nor a labelled-by relation.
    Label,
    /// A row's title is its name.
    RowTitle,
    /// An entry row's text field is named through its title.
    EntryText,
}

impl fmt::Display for Missing {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Label => "no accessible label or labelled-by relation",
            Self::RowTitle => "an empty row title",
            Self::EntryText => "a text field the row title does not label",
        })
    }
}

/// A control a screen reader reaches and cannot name.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Finding {
    type_name: String,
    css_classes: Vec<String>,
    /// Its id in the template that declares it, or its tooltip.
    hint: Option<String>,
    /// The app's widget it sits in.
    owner: Option<String>,
    missing: Missing,
}

impl fmt::Display for Finding {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.type_name)?;
        for class in &self.css_classes {
            write!(f, ".{class}")?;
        }
        if let Some(hint) = &self.hint {
            write!(f, " “{hint}”")?;
        }
        if let Some(owner) = &self.owner {
            write!(f, " in {owner}")?;
        }
        write!(f, ": {}", self.missing)
    }
}

/// Whether GTK records the accessible properties the checks read, which
/// only its test backend does.
pub fn test_backend_active() -> bool {
    let probe = gtk4::Button::new();
    probe.update_property(&[gtk4::accessible::Property::Label("probe")]);
    gtk4::test_accessible_has_property(&probe, AccessibleProperty::Label)
}

/// The controls at and under `root` that a screen reader reaches and
/// cannot name. A hidden widget, and all it holds, is out of reach.
pub fn audit(root: &impl IsA<gtk4::Widget>) -> Vec<Finding> {
    let mut findings = Vec::new();
    let mut pending = vec![(root.as_ref().clone(), true)];
    while let Some((widget, app_owned)) = pending.pop() {
        if !widget.is_visible() || !widget.is_child_visible() {
            continue;
        }
        if app_owned
            && exposed(&widget)
            && let Some(missing) = judge(&widget)
        {
            findings.push(finding(&widget, missing));
        }
        if is_one_control(&widget) || is_libadwaitas_own(&widget) || hides_its_child(&widget) {
            continue;
        }
        // The preferences dialog's own header is libadwaita's too, its
        // search button named by a tooltip alone; the pages are the app's.
        let app_owned = !widget.is::<adw::PreferencesDialog>() && (app_owned || widget.is::<adw::PreferencesPage>());
        pending.extend(children(&widget).into_iter().map(|child| (child, app_owned)));
    }
    findings
}

/// What libadwaita 1.9 builds inside these it names with a tooltip
/// alone, where the app can neither reach nor name it: a tab's close
/// button and a password row's peek button.
fn is_libadwaitas_own(widget: &gtk4::Widget) -> bool {
    widget.is::<adw::TabBar>() || widget.is::<adw::PasswordEntryRow>()
}

fn finding(widget: &gtk4::Widget, missing: Missing) -> Finding {
    let id = widget
        .buildable_id()
        .map(|id| id.to_string())
        .filter(|id| !id.starts_with("___object_"));
    let mut owner = widget.parent();
    while let Some(parent) = owner
        .as_ref()
        .filter(|parent| !parent.type_().name().starts_with("TablePro"))
    {
        owner = parent.parent();
    }
    Finding {
        type_name: widget.type_().name().to_owned(),
        css_classes: widget.css_classes().iter().map(ToString::to_string).collect(),
        hint: id.or_else(|| widget.tooltip_text().map(|tooltip| tooltip.to_string())),
        owner: owner.map(|owner| owner.type_().name().to_owned()),
        missing,
    }
}

fn exposed(widget: &gtk4::Widget) -> bool {
    !matches!(
        widget.accessible_role(),
        AccessibleRole::None | AccessibleRole::Presentation
    )
}

fn judge(widget: &gtk4::Widget) -> Option<Missing> {
    if let Some(row) = widget.downcast_ref::<adw::PreferencesRow>() {
        return judge_row(row);
    }
    let needs_name = match button_face(widget) {
        Some(face) => face == ButtonFace::Bare,
        None => is_field(widget),
    };
    (needs_name && !named(widget)).then_some(Missing::Label)
}

fn judge_row(row: &adw::PreferencesRow) -> Option<Missing> {
    // A row whose controls are its content names itself instead.
    if row.title().is_empty()
        && !gtk4::test_accessible_has_property(row.upcast_ref::<gtk4::Widget>(), AccessibleProperty::Label)
    {
        return Some(Missing::RowTitle);
    }
    if !row.is::<adw::EntryRow>() {
        return None;
    }
    let labelled = descendants(row.upcast_ref())
        .into_iter()
        .find(|widget| widget.is::<gtk4::Text>())
        .is_some_and(|text| gtk4::test_accessible_has_relation(&text, AccessibleRelation::LabelledBy));
    (!labelled).then_some(Missing::EntryText)
}

fn named(widget: &gtk4::Widget) -> bool {
    gtk4::test_accessible_has_property(widget, AccessibleProperty::Label)
        || gtk4::test_accessible_has_relation(widget, AccessibleRelation::LabelledBy)
}

/// A field a user types in, picks from or switches, which shows no name
/// of its own. A text view that never takes the focus is text on the
/// page rather than a field.
fn is_field(widget: &gtk4::Widget) -> bool {
    widget.is::<gtk4::Entry>()
        || widget.is::<gtk4::PasswordEntry>()
        || widget.is::<gtk4::SearchEntry>()
        || widget.is::<gtk4::SpinButton>()
        || widget.is::<gtk4::DropDown>()
        || widget.is::<gtk4::Switch>()
        || widget.is::<gtk4::Scale>()
        || (widget.is::<gtk4::TextView>() && widget.is_focusable())
        || widget
            .downcast_ref::<gtk4::CheckButton>()
            .is_some_and(|check| check.label().is_none_or(|label| label.is_empty()) && check.child().is_none())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ButtonFace {
    /// A label, or content of its own, which is taken to carry text.
    Text,
    /// An icon, or nothing at all.
    Bare,
}

fn button_face(widget: &gtk4::Widget) -> Option<ButtonFace> {
    let face = |label: Option<glib::GString>, child: Option<gtk4::Widget>| {
        let text =
            label.is_some_and(|label| !label.is_empty()) || child.is_some_and(|child| !child.is::<gtk4::Image>());
        if text { ButtonFace::Text } else { ButtonFace::Bare }
    };
    if let Some(button) = widget.downcast_ref::<gtk4::Button>() {
        return Some(face(button.label(), button.child()));
    }
    if let Some(button) = widget.downcast_ref::<gtk4::MenuButton>() {
        return Some(face(button.label(), button.child()));
    }
    if let Some(button) = widget.downcast_ref::<adw::SplitButton>() {
        return Some(face(button.label(), button.child()));
    }
    widget.is::<adw::TabButton>().then_some(ButtonFace::Bare)
}

/// A control GTK or libadwaita builds from parts, which a screen reader
/// meets as one and names through it.
fn is_one_control(widget: &gtk4::Widget) -> bool {
    widget.is::<gtk4::MenuButton>()
        || widget.is::<adw::SplitButton>()
        || widget.is::<adw::TabButton>()
        || widget.is::<gtk4::Entry>()
        || widget.is::<gtk4::PasswordEntry>()
        || widget.is::<gtk4::SearchEntry>()
        || widget.is::<gtk4::SpinButton>()
        || widget.is::<gtk4::DropDown>()
}

fn hides_its_child(widget: &gtk4::Widget) -> bool {
    widget
        .downcast_ref::<gtk4::Revealer>()
        .is_some_and(|revealer| !revealer.reveals_child())
}

fn children(widget: &gtk4::Widget) -> Vec<gtk4::Widget> {
    let mut found = Vec::new();
    let mut child = widget.first_child();
    while let Some(widget) = child {
        child = widget.next_sibling();
        found.push(widget);
    }
    found
}

pub fn descendants(root: &gtk4::Widget) -> Vec<gtk4::Widget> {
    let mut found = Vec::new();
    let mut pending = children(root);
    while let Some(widget) = pending.pop() {
        pending.extend(children(&widget));
        found.push(widget);
    }
    found
}
