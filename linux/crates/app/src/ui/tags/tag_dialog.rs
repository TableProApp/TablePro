use gtk4 as gtk;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_storage::{ConnectionColor, ConnectionTag, ConnectionTagName};

use crate::ui::connection_appearance::{color_dot, color_name, dot_classes, leading_factory};

const CANCEL: &str = "cancel";
const SAVE: &str = "save";

/// Ask for a new tag's name and colour. `None` when the user cancels.
pub(crate) async fn ask_new_tag(
    parent: &gtk::Widget,
    existing: &[ConnectionTag],
) -> Option<(ConnectionTagName, ConnectionColor)> {
    let form = TagForm::new(existing, None);
    form.ask(parent).await
}

/// Ask for a tag's new name and colour, filled with what it has.
pub(crate) async fn ask_tag_changes(
    parent: &gtk::Widget,
    existing: &[ConnectionTag],
    tag: &ConnectionTag,
) -> Option<(ConnectionTagName, ConnectionColor)> {
    let form = TagForm::new(existing, Some(tag));
    form.ask(parent).await
}

/// The dialog's rows. Save stays off until the name could be stored and
/// no other tag has it in any case, so the dialog never closes on a name
/// the store then refuses.
pub(super) struct TagForm {
    pub(super) dialog: adw::AlertDialog,
    pub(super) name: adw::EntryRow,
    pub(super) color: adw::ComboRow,
}

impl TagForm {
    pub(super) fn new(existing: &[ConnectionTag], editing: Option<&ConnectionTag>) -> Self {
        let (heading, confirm) = match editing {
            Some(_) => (crate::i18n::gettext("Edit Tag"), crate::i18n::gettext("Save")),
            None => (crate::i18n::gettext("New Tag"), crate::i18n::gettext("Create")),
        };
        let dialog = adw::AlertDialog::new(Some(&heading), None);
        let name = adw::EntryRow::builder()
            .title(crate::i18n::gettext("Name"))
            .activates_default(true)
            .build();
        let color = color_row();
        let picked = editing.map_or_else(|| unused_color(existing), |tag| tag.color);
        color.set_selected(position(picked));
        let rows = gtk::ListBox::builder().selection_mode(gtk::SelectionMode::None).build();
        rows.add_css_class("boxed-list");
        rows.append(&name);
        rows.append(&color);
        dialog.set_extra_child(Some(&rows));
        dialog.add_response(CANCEL, &crate::i18n::gettext("Cancel"));
        dialog.add_response(SAVE, &confirm);
        dialog.set_response_appearance(SAVE, adw::ResponseAppearance::Suggested);
        dialog.set_default_response(Some(SAVE));
        dialog.set_close_response(CANCEL);
        let taken: Vec<ConnectionTagName> = existing
            .iter()
            .filter(|tag| editing.is_none_or(|editing| editing.id != tag.id))
            .map(|tag| tag.name.clone())
            .collect();
        let answering = dialog.downgrade();
        name.connect_changed(move |name| {
            let usable = ConnectionTagName::new(&name.text())
                .is_ok_and(|typed| !taken.iter().any(|held| held.same_name(typed.as_str())));
            if let Some(dialog) = answering.upgrade() {
                dialog.set_response_enabled(SAVE, usable);
            }
        });
        dialog.set_response_enabled(SAVE, false);
        if let Some(tag) = editing {
            name.set_text(tag.name.as_str());
        }
        Self { dialog, name, color }
    }

    async fn ask(self, parent: &gtk::Widget) -> Option<(ConnectionTagName, ConnectionColor)> {
        if crate::workspace::respond(&self.dialog, parent).await != SAVE {
            return None;
        }
        self.answer()
    }

    pub(super) fn answer(&self) -> Option<(ConnectionTagName, ConnectionColor)> {
        let name = ConnectionTagName::new(&self.name.text()).ok()?;
        let color = ConnectionColor::ALL
            .get(usize::try_from(self.color.selected()).ok()?)
            .copied()?;
        Some((name, color))
    }
}

fn position(color: ConnectionColor) -> u32 {
    ConnectionColor::ALL
        .iter()
        .position(|candidate| *candidate == color)
        .and_then(|at| u32::try_from(at).ok())
        .unwrap_or(0)
}

/// The first colour no tag has yet, so new tags tell themselves apart
/// until the palette runs out.
fn unused_color(existing: &[ConnectionTag]) -> ConnectionColor {
    ConnectionColor::ALL
        .into_iter()
        .find(|color| existing.iter().all(|tag| tag.color != *color))
        .unwrap_or(ConnectionColor::Blue)
}

/// The palette as a combo row, each colour shown as its dot and name.
fn color_row() -> adw::ComboRow {
    let names = gtk::StringList::new(&[]);
    for color in ConnectionColor::ALL {
        names.append(&color_name(color));
    }
    let factory = leading_factory(
        &names,
        || color_dot(None).upcast(),
        |dot, place| {
            let color = place.and_then(|at| ConnectionColor::ALL.get(at).copied());
            dot.set_css_classes(&dot_classes(color));
            dot.set_visible(color.is_some());
        },
    );
    adw::ComboRow::builder()
        .title(crate::i18n::gettext("Colour"))
        .model(&names)
        .factory(&factory)
        .expression(gtk::PropertyExpression::new(
            gtk::StringObject::static_type(),
            None::<gtk::Expression>,
            "string",
        ))
        .build()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tag(name: &str, color: ConnectionColor) -> ConnectionTag {
        ConnectionTag::new(ConnectionTagName::new(name).expect("a tag name"), color)
    }

    #[gtk4::test]
    fn create_waits_for_a_name_no_other_tag_has() {
        let _ = adw::init();
        let production = tag("production", ConnectionColor::Red);

        let form = TagForm::new(std::slice::from_ref(&production), None);

        assert!(!form.dialog.is_response_enabled(SAVE), "an empty name can be created");
        for (typed, usable) in [
            ("   ", false),
            ("production", false),
            (" PRODUCTION ", false),
            ("acme", true),
            (&"x".repeat(ConnectionTagName::MAX_CHARS + 1), false),
        ] {
            form.name.set_text(typed);
            assert_eq!(form.dialog.is_response_enabled(SAVE), usable, "{typed:?}");
        }
        assert_eq!(form.dialog.default_response().as_deref(), Some(SAVE));
        assert_eq!(form.dialog.close_response(), CANCEL);
    }

    #[gtk4::test]
    fn a_new_tag_starts_on_a_colour_no_tag_has() {
        let _ = adw::init();
        let tags = [tag("a", ConnectionColor::Blue), tag("b", ConnectionColor::Teal)];

        let form = TagForm::new(&tags, None);
        form.name.set_text(" acme ");

        assert_eq!(
            form.answer(),
            Some((
                ConnectionTagName::new("acme").expect("a tag name"),
                ConnectionColor::Green
            ))
        );
    }

    #[gtk4::test]
    fn an_edit_starts_from_the_tag_and_may_keep_its_own_name() {
        let _ = adw::init();
        let production = tag("production", ConnectionColor::Red);
        let acme = tag("acme", ConnectionColor::Blue);
        let tags = [production.clone(), acme];

        let form = TagForm::new(&tags, Some(&production));

        assert_eq!(form.name.text(), "production");
        assert!(form.dialog.is_response_enabled(SAVE));
        form.color.set_selected(position(ConnectionColor::Purple));
        form.name.set_text("Production");
        assert!(form.dialog.is_response_enabled(SAVE));
        assert_eq!(
            form.answer(),
            Some((
                ConnectionTagName::new("Production").expect("a tag name"),
                ConnectionColor::Purple
            ))
        );
        form.name.set_text("ACME");
        assert!(!form.dialog.is_response_enabled(SAVE));
    }

    #[gtk4::test]
    fn the_colour_row_lists_the_palette_in_order() {
        let row = color_row();
        let names = row.model().and_downcast::<gtk::StringList>().expect("the names");

        assert_eq!(
            names.n_items(),
            u32::try_from(ConnectionColor::ALL.len()).expect("a count")
        );
        assert_eq!(names.string(0).as_deref(), Some("Blue"));
        assert_eq!(names.string(8).as_deref(), Some("Slate"));
    }
}
