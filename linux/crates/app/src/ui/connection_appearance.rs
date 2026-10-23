//! How a connection's colour, icon and tags look, wherever they show.

use gtk4 as gtk;
use gtk4::prelude::*;
use tablepro_storage::{ConnectionColor, ConnectionIcon, ConnectionTag};

pub(crate) fn color_name(color: ConnectionColor) -> String {
    match color {
        ConnectionColor::Blue => crate::i18n::gettext("Blue"),
        ConnectionColor::Teal => crate::i18n::gettext("Teal"),
        ConnectionColor::Green => crate::i18n::gettext("Green"),
        ConnectionColor::Yellow => crate::i18n::gettext("Yellow"),
        ConnectionColor::Orange => crate::i18n::gettext("Orange"),
        ConnectionColor::Red => crate::i18n::gettext("Red"),
        ConnectionColor::Pink => crate::i18n::gettext("Pink"),
        ConnectionColor::Purple => crate::i18n::gettext("Purple"),
        ConnectionColor::Slate => crate::i18n::gettext("Slate"),
    }
}

pub(crate) fn color_class(color: ConnectionColor) -> &'static str {
    match color {
        ConnectionColor::Blue => "tp-tag-blue",
        ConnectionColor::Teal => "tp-tag-teal",
        ConnectionColor::Green => "tp-tag-green",
        ConnectionColor::Yellow => "tp-tag-yellow",
        ConnectionColor::Orange => "tp-tag-orange",
        ConnectionColor::Red => "tp-tag-red",
        ConnectionColor::Pink => "tp-tag-pink",
        ConnectionColor::Purple => "tp-tag-purple",
        ConnectionColor::Slate => "tp-tag-slate",
    }
}

/// The dot's classes. Set as a whole list rather than added one by one
/// so a colour change never leaves the previous colour's class behind.
pub(crate) fn dot_classes(color: Option<ConnectionColor>) -> Vec<&'static str> {
    let mut classes = vec!["tp-connection-tag"];
    classes.extend(color.map(color_class));
    classes
}

/// A colour as a dot. Absent rather than grey when there is none, so an
/// untagged list has no decoration in it.
pub(crate) fn color_dot(color: Option<ConnectionColor>) -> gtk::Box {
    let dot = gtk::Box::builder().valign(gtk::Align::Center).build();
    dot.set_css_classes(&dot_classes(color));
    dot.set_visible(color.is_some());
    if let Some(color) = color {
        dot.set_tooltip_text(Some(&color_name(color)));
    }
    dot
}

/// A combo row factory that puts `lead` (an icon or a dot) before each
/// name, set by `show` from the name's place in `names`. The combo shows
/// its pick outside any list position, so the place is looked up.
pub(crate) fn leading_factory(
    names: &gtk::StringList,
    lead: fn() -> gtk::Widget,
    show: fn(&gtk::Widget, Option<usize>),
) -> gtk::SignalListItemFactory {
    let factory = gtk::SignalListItemFactory::new();
    factory.connect_setup(move |_, item| {
        let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
            return;
        };
        let line = gtk::Box::builder().spacing(8).build();
        line.append(&lead());
        line.append(&gtk::Label::builder().xalign(0.0).build());
        item.set_child(Some(&line));
    });
    let names = names.downgrade();
    factory.connect_bind(move |_, item| {
        let (Some(item), Some(names)) = (item.downcast_ref::<gtk::ListItem>(), names.upgrade()) else {
            return;
        };
        let (Some(line), Some(shown)) = (item.child(), item.item()) else {
            return;
        };
        let place = (0..names.n_items())
            .find(|at| names.item(*at).as_ref() == Some(&shown))
            .and_then(|at| usize::try_from(at).ok());
        if let Some(leading) = line.first_child() {
            show(&leading, place);
        }
        if let (Some(label), Some(name)) = (
            line.last_child().and_downcast::<gtk::Label>(),
            shown.downcast_ref::<gtk::StringObject>(),
        ) {
            label.set_label(&name.string());
        }
    });
    factory
}

pub(crate) fn icon_label(icon: ConnectionIcon) -> String {
    match icon {
        ConnectionIcon::Server => crate::i18n::gettext("Server"),
        ConnectionIcon::Computer => crate::i18n::gettext("Computer"),
        ConnectionIcon::Disk => crate::i18n::gettext("Disk"),
        ConnectionIcon::Folder => crate::i18n::gettext("Folder"),
        ConnectionIcon::Home => crate::i18n::gettext("Home"),
        ConnectionIcon::Cloud => crate::i18n::gettext("Cloud"),
        ConnectionIcon::Web => crate::i18n::gettext("Web"),
        ConnectionIcon::Terminal => crate::i18n::gettext("Terminal"),
        ConnectionIcon::Package => crate::i18n::gettext("Package"),
        ConnectionIcon::Lab => crate::i18n::gettext("Lab"),
        ConnectionIcon::Tools => crate::i18n::gettext("Tools"),
        ConnectionIcon::Star => crate::i18n::gettext("Star"),
        ConnectionIcon::Warning => crate::i18n::gettext("Warning"),
        ConnectionIcon::Shield => crate::i18n::gettext("Shield"),
        ConnectionIcon::Lock => crate::i18n::gettext("Lock"),
    }
}

/// The connection's icon, which only decorates: the row and the title
/// beside it already name the connection.
pub(crate) fn icon_image(icon: Option<ConnectionIcon>) -> gtk::Image {
    let image = gtk::Image::builder()
        .valign(gtk::Align::Center)
        .accessible_role(gtk::AccessibleRole::Presentation)
        .build();
    show_icon(&image, icon);
    image
}

pub(crate) fn show_icon(image: &gtk::Image, icon: Option<ConnectionIcon>) {
    image.set_icon_name(icon.map(crate::ui::icons::connection_icon));
    image.set_visible(icon.is_some());
}

/// A tag as a pill, tinted with its colour, its name in the text colour
/// so it reads in both styles.
pub(crate) fn tag_pill(tag: &ConnectionTag) -> gtk::Label {
    let pill = gtk::Label::builder()
        .label(tag.name.as_str())
        .ellipsize(gtk::pango::EllipsizeMode::End)
        .max_width_chars(16)
        .valign(gtk::Align::Center)
        .tooltip_text(tag.name.as_str())
        .build();
    pill.set_css_classes(&["tp-tag-pill", "caption", color_class(tag.color)]);
    pill
}

/// The tags in a row: the screen reader hears them in the row's
/// description, so the pills themselves stay out of its way.
pub(crate) fn tag_pills<'a>(tags: impl IntoIterator<Item = &'a ConnectionTag>) -> gtk::Box {
    let pills = gtk::Box::builder()
        .spacing(4)
        .valign(gtk::Align::Center)
        .accessible_role(gtk::AccessibleRole::Presentation)
        .build();
    for tag in tags {
        let pill = tag_pill(tag);
        pill.update_state(&[gtk::accessible::State::Hidden(true)]);
        pills.append(&pill);
    }
    pills.set_visible(pills.first_child().is_some());
    pills
}

/// "Tags: production, acme", or nothing for a connection with none.
pub(crate) fn tags_description<'a>(tags: impl IntoIterator<Item = &'a ConnectionTag>) -> Option<String> {
    let names: Vec<&str> = tags.into_iter().map(|tag| tag.name.as_str()).collect();
    if names.is_empty() {
        return None;
    }
    Some(crate::i18n::gettext_f(
        "Tags: {tags}",
        &[("tags", &names.join(&crate::i18n::pgettext("list separator", ", ")))],
    ))
}

#[cfg(test)]
mod tests {
    use tablepro_storage::ConnectionTagName;

    use super::*;

    fn tag(name: &str, color: ConnectionColor) -> ConnectionTag {
        ConnectionTag::new(ConnectionTagName::new(name).expect("a tag name"), color)
    }

    #[test]
    fn a_connection_with_no_colour_carries_no_colour_class() {
        assert_eq!(dot_classes(None), vec!["tp-connection-tag"]);
    }

    /// A class with no rule behind it paints nothing, and nothing is
    /// exactly what a missing tag looks like.
    #[test]
    fn every_colour_class_has_a_dot_and_a_pill_rule_in_the_stylesheet() {
        let css = include_str!("../../../../data/resources/style.css");

        for color in ConnectionColor::ALL {
            let class = color_class(color);
            for widget in ["tp-connection-tag", "tp-tag-pill"] {
                assert!(
                    css.contains(&format!(".{widget}.{class} {{")),
                    "{widget}.{class} has no rule in style.css"
                );
            }
        }
    }

    #[test]
    fn every_colour_has_a_class_of_its_own() {
        let classes: std::collections::HashSet<&str> = ConnectionColor::ALL.into_iter().map(color_class).collect();

        assert_eq!(classes.len(), ConnectionColor::ALL.len());
    }

    #[test]
    fn every_icon_has_a_label_of_its_own() {
        let labels: std::collections::HashSet<String> = ConnectionIcon::ALL.into_iter().map(icon_label).collect();

        assert_eq!(labels.len(), ConnectionIcon::ALL.len());
    }

    #[test]
    fn the_description_names_each_tag_in_order() {
        let (production, acme) = (
            tag("production", ConnectionColor::Red),
            tag("acme", ConnectionColor::Blue),
        );

        assert_eq!(
            tags_description([&production, &acme]).as_deref(),
            Some("Tags: production, acme")
        );
        assert_eq!(tags_description([]), None);
    }

    #[gtk4::test]
    fn pills_show_each_name_and_colour_and_hide_from_the_screen_reader() {
        let (production, acme) = (
            tag("production", ConnectionColor::Red),
            tag("acme", ConnectionColor::Blue),
        );

        let pills = tag_pills([&production, &acme]);

        let shown: Vec<(String, bool)> = crate::test_support::descendants(&pills)
            .into_iter()
            .filter_map(|widget| widget.downcast::<gtk::Label>().ok())
            .map(|label| {
                (
                    label.label().to_string(),
                    label.has_css_class(color_class(ConnectionColor::Red)),
                )
            })
            .collect();
        assert_eq!(shown, [("production".to_owned(), true), ("acme".to_owned(), false)]);
        assert!(pills.is_visible());
        assert!(!tag_pills([]).is_visible());
    }
}
