use std::path::PathBuf;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::{gdk, gio, glib};
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_session::runtime::Tasks;
use tablepro_storage::{ConnectionGroupName, ConnectionTag, SavedConnection};

use super::connection_menu::{
    CONNECT, MOVE_TO_GROUP, NONE, PICKER, ROW, ROW_COLOR, ROW_GROUP, ROW_MENU, SET_COLOR, SET_TAG, connection_menu,
    tag_action,
};
use crate::application::{ShortcutOwner, local_shortcut_controller};
use crate::services::file_location;
use crate::services::saved_connection_object::{SavedConnectionObject, subtitle_for};
use crate::ui::a11y::describe_icon_button;
use crate::ui::connection_appearance::{color_dot, icon_image, tag_pills, tags_description};

/// What every row's menu offers: the list's groups and tags.
#[derive(Debug, Clone, Default)]
pub(crate) struct RowChoices {
    pub groups: Vec<ConnectionGroupName>,
    pub tags: std::sync::Arc<[ConnectionTag]>,
}

/// The row for one saved connection: activating it connects, and its
/// menu holds the rest. `tasks` reads the file a portal path stands
/// for; `None` names the file alone.
pub(crate) fn connection_row(object: &glib::Object, choices: &RowChoices, tasks: Option<&Tasks>) -> gtk::Widget {
    let Some(connection) = object.downcast_ref::<SavedConnectionObject>() else {
        return adw::ActionRow::new().upcast();
    };
    let Some(saved) = connection.saved().cloned() else {
        return adw::ActionRow::new().upcast();
    };
    let file_based = connection.file_based();
    let row = adw::ActionRow::builder()
        .title(&saved.name)
        .subtitle(subtitle_for(&saved, file_based, None))
        // A name is the user's text, never markup.
        .use_markup(false)
        .activatable(true)
        .build();
    row.set_action_target_value(Some(&saved.id.to_string().to_variant()));
    row.set_action_name(Some(&format!("{PICKER}.{CONNECT}")));
    row.add_prefix(&color_dot(saved.color));
    row.add_prefix(&icon_image(saved.icon));
    let carried: Vec<ConnectionTag> = carried_tags(&saved, &choices.tags).into_iter().cloned().collect();
    row.add_suffix(&tag_pills(&carried));
    describe_row(&row, &subtitle_for(&saved, file_based, None), &carried);
    // One menu rather than a button per action: the row gains actions as
    // the app does, and a row of icons stops reading as a row.
    let menu_button = gtk::MenuButton::builder()
        .icon_name(crate::ui::icons::VIEW_MORE)
        .valign(gtk::Align::Center)
        .menu_model(&connection_menu(saved.id, &choices.groups, &choices.tags))
        .build();
    menu_button.add_css_class("flat");
    describe_icon_button(
        &menu_button,
        &crate::i18n::gettext("Connection Options"),
        Some(&format!("{ROW}.{ROW_MENU}")),
    );
    row.add_suffix(&menu_button);
    row.insert_action_group(ROW, Some(&row_actions(&row, &saved, &choices.tags, &menu_button)));
    row.add_controller(local_shortcut_controller(ShortcutOwner::PickerRow));
    row.add_controller(secondary_click(&menu_button));
    if let Some(tasks) = tasks {
        show_host_path(&row, &saved, file_based, carried, tasks);
    }
    row.upcast()
}

/// The tags `saved` carries, in the list's order.
fn carried_tags<'a>(saved: &SavedConnection, tags: &'a [ConnectionTag]) -> Vec<&'a ConnectionTag> {
    tags.iter().filter(|tag| saved.tags.contains(&tag.id)).collect()
}

/// The row's description: where it connects, then its tags. libadwaita
/// describes a row by its subtitle label, and GTK reads a described-by
/// relation before the description property, so the row drops the
/// relation and says both itself.
fn describe_row(row: &adw::ActionRow, subtitle: &str, tags: &[ConnectionTag]) {
    let Some(tags) = tags_description(tags) else {
        return;
    };
    let row = row.upcast_ref::<gtk::Widget>();
    row.reset_relation(gtk::AccessibleRelation::DescribedBy);
    let description = crate::i18n::gettext_f("{subtitle}. {tags}", &[("subtitle", subtitle), ("tags", &tags)]);
    row.update_property(&[gtk::accessible::Property::Description(&description)]);
}

/// The row's menu, and the colour, group and tag items ticked at what
/// the connection has. A pick goes to the picker's action with the id.
fn row_actions(
    row: &adw::ActionRow,
    saved: &SavedConnection,
    tags: &[ConnectionTag],
    menu_button: &gtk::MenuButton,
) -> gio::SimpleActionGroup {
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
    let current_group = saved.group.as_ref().map_or(NONE, ConnectionGroupName::as_str);
    for (name, state, forward) in [
        (ROW_COLOR, current_color, SET_COLOR),
        (ROW_GROUP, current_group, MOVE_TO_GROUP),
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
    // A check item needs an action of its own: one per tag.
    for tag in tags {
        let check =
            gio::SimpleAction::new_stateful(&tag_action(tag.id), None, &saved.tags.contains(&tag.id).to_variant());
        let (row, target) = (row.downgrade(), (saved.id.to_string(), tag.id.to_string()));
        check.connect_activate(move |check, _| {
            let Some(row) = row.upgrade() else {
                return;
            };
            let carried = !check.state().and_then(|state| state.get::<bool>()).unwrap_or(false);
            check.set_state(&carried.to_variant());
            let target = (target.0.clone(), target.1.clone(), carried).to_variant();
            if let Err(error) = row.activate_action(&format!("{PICKER}.{SET_TAG}"), Some(&target)) {
                tracing::warn!(%error, "a connection row's tag reached no picker");
            }
        });
        actions.add_action(&check);
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

/// A portal path's folder is an id, so the row names the file the
/// portal stands for once it is read.
fn show_host_path(
    row: &adw::ActionRow,
    saved: &SavedConnection,
    file_based: bool,
    tags: Vec<ConnectionTag>,
    tasks: &Tasks,
) {
    let path = PathBuf::from(&saved.database);
    if !file_based || !file_location::is_portal_path(&path) {
        return;
    }
    let looking = tasks.spawn_blocking_task(move || file_location::portal_host_path_blocking(&path));
    let (saved, row) = (saved.clone(), row.downgrade());
    glib::spawn_future_local(async move {
        if let (Ok(Some(host)), Some(row)) = (looking.await, row.upgrade()) {
            let subtitle = subtitle_for(&saved, true, Some(&host));
            row.set_subtitle(&subtitle);
            describe_row(&row, &subtitle, &tags);
        }
    });
}

#[cfg(test)]
mod tests {
    use gtk4::AccessibleRelation;
    use tablepro_storage::{ConnectionColor, ConnectionIcon, ConnectionTagName};
    use uuid::Uuid;

    use super::*;

    fn saved(tags: &[&ConnectionTag], icon: Option<ConnectionIcon>) -> SavedConnection {
        SavedConnection {
            id: Uuid::new_v4(),
            name: "acme-prod".to_owned(),
            driver_id: "postgres".to_owned(),
            host: "db".to_owned(),
            port: 5432,
            database: "app".to_owned(),
            username: "app".to_owned(),
            tls: tablepro_core::TlsConfig::verify_full(),
            safe_mode: tablepro_core::SafeModeLevel::Off,
            external_access: tablepro_core::ExternalAccess::ReadOnly,
            ai_policy: tablepro_core::AiPolicy::Ask,
            auth_mode: tablepro_core::AuthMode::Password,
            ssh: None,
            last_opened_at: None,
            color: Some(ConnectionColor::Red),
            group: None,
            tags: tags.iter().map(|tag| tag.id).collect(),
            icon,
            options: Default::default(),
        }
    }

    fn tag(name: &str, color: ConnectionColor) -> ConnectionTag {
        ConnectionTag::new(ConnectionTagName::new(name).expect("a tag name"), color)
    }

    fn row_for(saved: SavedConnection, tags: Vec<ConnectionTag>) -> adw::ActionRow {
        let object = SavedConnectionObject::new(saved, false);
        let choices = RowChoices {
            groups: Vec::new(),
            tags: tags.into(),
        };
        connection_row(object.upcast_ref(), &choices, None)
            .downcast::<adw::ActionRow>()
            .expect("an action row")
    }

    fn labels(row: &adw::ActionRow) -> Vec<String> {
        crate::test_support::descendants(row)
            .into_iter()
            .filter(|widget| widget.has_css_class("tp-tag-pill"))
            .filter_map(|widget| widget.downcast::<gtk::Label>().ok())
            .map(|label| label.label().to_string())
            .collect()
    }

    #[gtk4::test]
    fn the_row_shows_its_tags_after_the_name_and_says_them() {
        let (acme, production, other) = (
            tag("acme", ConnectionColor::Blue),
            tag("production", ConnectionColor::Red),
            tag("staging", ConnectionColor::Yellow),
        );
        let row = row_for(
            saved(&[&production, &acme], None),
            vec![acme.clone(), production.clone(), other],
        );

        assert_eq!(labels(&row), ["acme", "production"]);
        let row = row.upcast_ref::<gtk::Widget>();
        assert!(!gtk::test_accessible_has_relation(row, AccessibleRelation::DescribedBy));
        assert!(gtk::test_accessible_has_property(
            row,
            gtk::AccessibleProperty::Description
        ));
    }

    #[gtk4::test]
    fn a_row_without_tags_keeps_the_subtitle_as_its_description() {
        let row = row_for(saved(&[], None), vec![tag("acme", ConnectionColor::Blue)]);

        assert!(labels(&row).is_empty());
        let row = row.upcast_ref::<gtk::Widget>();
        assert!(gtk::test_accessible_has_relation(row, AccessibleRelation::DescribedBy));
        assert!(!gtk::test_accessible_has_property(
            row,
            gtk::AccessibleProperty::Description
        ));
    }

    #[gtk4::test]
    fn the_icon_sits_in_the_prefix_beside_the_colour() {
        let with = row_for(saved(&[], Some(ConnectionIcon::Cloud)), Vec::new());
        let without = row_for(saved(&[], None), Vec::new());
        let icon = |row: &adw::ActionRow| {
            crate::test_support::descendants(row)
                .into_iter()
                .filter_map(|widget| widget.downcast::<gtk::Image>().ok())
                .find(|image| {
                    image.is_visible()
                        && image
                            .icon_name()
                            .is_some_and(|name| name.as_str() != crate::ui::icons::VIEW_MORE)
                })
                .and_then(|image| image.icon_name())
                .map(|name| name.to_string())
        };

        assert_eq!(
            icon(&with).as_deref(),
            Some(crate::ui::icons::connection_icon(ConnectionIcon::Cloud))
        );
        assert_eq!(icon(&without), None);
    }

    #[gtk4::test]
    fn the_tag_items_are_ticked_at_the_tags_the_connection_has() {
        let (acme, production) = (
            tag("acme", ConnectionColor::Blue),
            tag("production", ConnectionColor::Red),
        );
        let saved = saved(&[&production], None);
        let group = row_actions(
            &adw::ActionRow::new(),
            &saved,
            &[acme.clone(), production.clone()],
            &gtk::MenuButton::new(),
        );
        let state = |tag: &ConnectionTag| {
            group
                .lookup_action(&tag_action(tag.id))
                .and_then(|action| action.state())
                .and_then(|state| state.get::<bool>())
        };

        assert_eq!(state(&production), Some(true));
        assert_eq!(state(&acme), Some(false));
    }
}
