use std::path::PathBuf;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::{gdk, gio, glib};
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_session::runtime::Tasks;
use tablepro_storage::{ConnectionColor, SavedConnection};

use super::connection_menu::{
    CONNECT, NONE, PICKER, ROW, ROW_COLOR, ROW_GROUP, ROW_MENU, SET_COLOR, SET_GROUP, color_name, connection_menu,
};
use crate::application::{ShortcutOwner, local_shortcut_controller};
use crate::services::file_location;
use crate::services::saved_connection_object::{SavedConnectionObject, is_sqlite, subtitle_for};
use crate::ui::a11y::describe_icon_button;

/// The row for one saved connection: activating it connects, and its
/// menu holds the rest. `groups` are the list's groups, which the menu
/// offers. `tasks` reads the file a portal path stands for; `None`
/// names the file alone.
pub(crate) fn connection_row(object: &glib::Object, groups: &[String], tasks: Option<&Tasks>) -> gtk::Widget {
    let Some(saved) = object
        .downcast_ref::<SavedConnectionObject>()
        .and_then(SavedConnectionObject::saved)
        .cloned()
    else {
        return adw::ActionRow::new().upcast();
    };
    let row = adw::ActionRow::builder()
        .title(&saved.name)
        .subtitle(subtitle_for(&saved, None))
        // A name is the user's text, never markup.
        .use_markup(false)
        .activatable(true)
        .build();
    row.set_action_target_value(Some(&saved.id.to_string().to_variant()));
    row.set_action_name(Some(&format!("{PICKER}.{CONNECT}")));
    row.add_prefix(&color_tag(saved.color));
    // One menu rather than a button per action: the row gains actions as
    // the app does, and a row of icons stops reading as a row.
    let menu_button = gtk::MenuButton::builder()
        .icon_name(crate::ui::icons::VIEW_MORE)
        .valign(gtk::Align::Center)
        .menu_model(&connection_menu(saved.id, groups))
        .build();
    menu_button.add_css_class("flat");
    describe_icon_button(
        &menu_button,
        &crate::i18n::gettext("Connection Options"),
        Some(&format!("{ROW}.{ROW_MENU}")),
    );
    row.add_suffix(&menu_button);
    row.insert_action_group(ROW, Some(&row_actions(&row, &saved, &menu_button)));
    row.add_controller(local_shortcut_controller(ShortcutOwner::PickerRow));
    row.add_controller(secondary_click(&menu_button));
    if let Some(tasks) = tasks {
        show_host_path(&row, &saved, tasks);
    }
    row.upcast()
}

/// The row's menu, and the colour and group radios ticked at what the
/// connection has. A pick goes to the picker's action with the id.
fn row_actions(row: &adw::ActionRow, saved: &SavedConnection, menu_button: &gtk::MenuButton) -> gio::SimpleActionGroup {
    let actions = gio::SimpleActionGroup::new();
    let menu = gio::SimpleAction::new(ROW_MENU, None);
    let button = menu_button.downgrade();
    menu.connect_activate(move |_, _| {
        if let Some(button) = button.upgrade() {
            button.popup();
        }
    });
    actions.add_action(&menu);
    let current_color = saved.color.map_or(NONE, |color| color.id());
    let current_group = crate::services::saved_connection_order::group_of(saved).unwrap_or(NONE);
    for (name, state, forward) in [
        (ROW_COLOR, current_color, SET_COLOR),
        (ROW_GROUP, current_group, SET_GROUP),
    ] {
        let radio = gio::SimpleAction::new_stateful(name, Some(&String::static_variant_type()), &state.to_variant());
        let (row, id) = (row.downgrade(), saved.id.to_string());
        radio.connect_activate(move |radio, picked| {
            let (Some(row), Some(picked)) = (row.upgrade(), picked.and_then(|value| value.get::<String>())) else {
                return;
            };
            radio.set_state(&picked.to_variant());
            let target = (id.clone(), picked).to_variant();
            if let Err(error) = row.activate_action(&format!("{PICKER}.{forward}"), Some(&target)) {
                tracing::warn!(%error, "a connection row's pick reached no picker");
            }
        });
        actions.add_action(&radio);
    }
    actions
}

fn secondary_click(menu_button: &gtk::MenuButton) -> gtk::GestureClick {
    let gesture = gtk::GestureClick::new();
    gesture.set_button(gdk::BUTTON_SECONDARY);
    let button = menu_button.downgrade();
    gesture.connect_pressed(move |gesture, _, _, _| {
        gesture.set_state(gtk::EventSequenceState::Claimed);
        if let Some(button) = button.upgrade() {
            button.popup();
        }
    });
    gesture
}

/// The colour the user put on this connection, as a dot ahead of the
/// name. Absent rather than grey when there is none, so an untagged list
/// has no decoration in it.
fn color_tag(color: Option<ConnectionColor>) -> gtk::Box {
    let tag = gtk::Box::builder().valign(gtk::Align::Center).build();
    tag.set_css_classes(&tag_classes(color));
    tag.set_visible(color.is_some());
    if let Some(color) = color {
        tag.set_tooltip_text(Some(&color_name(color)));
    }
    tag
}

/// The dot's classes. Set as a whole list rather than added one by one
/// so a colour change never leaves the previous colour's class behind.
pub(super) fn tag_classes(color: Option<ConnectionColor>) -> Vec<&'static str> {
    let mut classes = vec!["tp-connection-tag"];
    if let Some(color) = color {
        classes.push(match color {
            ConnectionColor::Blue => "tp-tag-blue",
            ConnectionColor::Teal => "tp-tag-teal",
            ConnectionColor::Green => "tp-tag-green",
            ConnectionColor::Yellow => "tp-tag-yellow",
            ConnectionColor::Orange => "tp-tag-orange",
            ConnectionColor::Red => "tp-tag-red",
            ConnectionColor::Pink => "tp-tag-pink",
            ConnectionColor::Purple => "tp-tag-purple",
            ConnectionColor::Slate => "tp-tag-slate",
        });
    }
    classes
}

/// A portal path's folder is an id, so the row names the file the
/// portal stands for once it is read.
fn show_host_path(row: &adw::ActionRow, saved: &SavedConnection, tasks: &Tasks) {
    let path = PathBuf::from(&saved.database);
    if !is_sqlite(saved) || !file_location::is_portal_path(&path) {
        return;
    }
    let looking = tasks.spawn_blocking_task(move || file_location::portal_host_path_blocking(&path));
    let (saved, row) = (saved.clone(), row.downgrade());
    glib::spawn_future_local(async move {
        if let (Ok(Some(host)), Some(row)) = (looking.await, row.upgrade()) {
            row.set_subtitle(&subtitle_for(&saved, Some(&host)));
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_connection_with_no_colour_carries_no_colour_class() {
        assert_eq!(tag_classes(None), vec!["tp-connection-tag"]);
    }

    /// A class with no rule behind it paints nothing, and nothing is
    /// exactly what a missing tag looks like.
    #[test]
    fn every_colour_class_has_a_rule_in_the_stylesheet() {
        let css = include_str!("../../../../../data/resources/style.css");

        for color in ConnectionColor::ALL {
            let class = tag_classes(Some(color))[1];
            assert!(
                css.contains(&format!(".tp-connection-tag.{class} {{")),
                "{class} has no rule in style.css"
            );
        }
    }

    #[test]
    fn every_colour_has_a_class_of_its_own() {
        let classes: std::collections::HashSet<&str> = ConnectionColor::ALL
            .into_iter()
            .map(|color| tag_classes(Some(color))[1])
            .collect();

        assert_eq!(classes.len(), ConnectionColor::ALL.len());
    }
}
