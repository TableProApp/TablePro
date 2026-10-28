use std::rc::Rc;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::{gio, glib};
use tablepro_storage::{ConnectionColor, ConnectionGroupName, ConnectionTag, SavedConnection};
use uuid::Uuid;

use super::connection_menu::{
    CONNECT, DELETE, DUPLICATE, EDIT, MOVE_TO_GROUP, NEW_GROUP, NEW_TAG, NONE, PICKER, ROW, ROW_COLOR, ROW_GROUP,
    SET_COLOR, SET_TAG, tag_action,
};
use crate::runtime::{DeliverInput, InputSender};
use crate::services::saved_connection_list::SavedConnectionList;
use crate::ui::SessionWindowInput;

/// The `picker` actions on `root`, which every row and menu inside it
/// reach. Each names a connection by id, read again from the list at the
/// moment it runs, so a row or a menu left over from an older list acts
/// on nothing rather than on another connection.
pub(crate) fn install_picker_actions(
    root: &impl IsA<gtk::Widget>,
    list: Rc<SavedConnectionList>,
    sender: InputSender<SessionWindowInput>,
) {
    let actions = gio::SimpleActionGroup::new();
    let by_id = [
        (CONNECT, OnConnection::Connect),
        (EDIT, OnConnection::Edit),
        (DELETE, OnConnection::Delete),
        (DUPLICATE, OnConnection::Duplicate),
        (NEW_GROUP, OnConnection::NewGroup),
        (NEW_TAG, OnConnection::NewTag),
    ];
    for (name, picked) in by_id {
        let action = gio::SimpleAction::new(name, Some(&String::static_variant_type()));
        let (list, sender, root) = (list.clone(), sender.clone(), root.as_ref().downgrade());
        action.connect_activate(move |_, target| {
            let Some(saved) = connection(&list, target.and_then(|target| target.get::<String>()), name) else {
                return;
            };
            match picked {
                OnConnection::Connect => sender.deliver(SessionWindowInput::OpenSaved(Box::new(saved))),
                OnConnection::Edit => sender.deliver(SessionWindowInput::EditSavedConnection(saved.id)),
                OnConnection::Delete => sender.deliver(SessionWindowInput::DeleteConnection(saved.id)),
                OnConnection::Duplicate => sender.deliver(SessionWindowInput::DuplicateConnection(saved.id)),
                OnConnection::NewGroup => {
                    if let Some(root) = root.upgrade() {
                        ask_for_group(root, saved.id, list.groups(), sender.clone());
                    }
                }
                OnConnection::NewTag => {
                    if let Some(root) = root.upgrade() {
                        ask_for_tag(root, saved.id, list.tags().to_vec(), sender.clone());
                    }
                }
            }
        });
        actions.add_action(&action);
    }
    for (name, picked) in [(SET_COLOR, Setting::Color), (MOVE_TO_GROUP, Setting::Group)] {
        let action = gio::SimpleAction::new(name, Some(&<(String, String)>::static_variant_type()));
        let (list, sender) = (list.clone(), sender.clone());
        action.connect_activate(move |_, target| {
            let Some((id, value)) = target.and_then(|target| target.get::<(String, String)>()) else {
                tracing::warn!(action = name, "a picker action came without its target");
                return;
            };
            let Some(saved) = connection(&list, Some(id), name) else {
                return;
            };
            let input = match picked {
                Setting::Color => SessionWindowInput::SetConnectionColor(saved.id, ConnectionColor::from_id(&value)),
                Setting::Group => match group_named(&value) {
                    Ok(group) => SessionWindowInput::SetConnectionGroup(saved.id, group),
                    Err(error) => {
                        tracing::warn!(action = name, %error, "a picker action named a group that cannot be saved");
                        return;
                    }
                },
            };
            sender.deliver(input);
        });
        actions.add_action(&action);
    }
    actions.add_action(&set_tag_action(list, sender));
    root.insert_action_group(PICKER, Some(&actions));
}

/// Put on `menu` the colour, group and tag choices `connection_menu`
/// names for `saved`, ticked at what it has now. A pick goes to the
/// `picker` action with the connection's id, from `source`, which sits
/// where the `picker` actions reach: a menu closes before its action
/// runs.
pub(crate) fn insert_choice_actions(
    menu: &impl IsA<gtk::Widget>,
    source: &gtk::Widget,
    saved: &SavedConnection,
    tags: &[ConnectionTag],
) {
    let actions = gio::SimpleActionGroup::new();
    let current_color = saved.color.map_or(NONE, |color| color.id());
    let current_group = saved.group.as_ref().map_or(NONE, ConnectionGroupName::as_str);
    for (name, state, forward) in [
        (ROW_COLOR, current_color, SET_COLOR),
        (ROW_GROUP, current_group, MOVE_TO_GROUP),
    ] {
        let radio = gio::SimpleAction::new_stateful(name, Some(&String::static_variant_type()), &state.to_variant());
        let (source, id) = (source.downgrade(), saved.id.to_string());
        radio.connect_activate(move |radio, picked| {
            let (Some(source), Some(picked)) = (source.upgrade(), picked.and_then(|value| value.get::<String>()))
            else {
                return;
            };
            radio.set_state(&picked.to_variant());
            let target = (id.clone(), picked).to_variant();
            if let Err(error) = source.activate_action(&format!("{PICKER}.{forward}"), Some(&target)) {
                tracing::warn!(%error, "a connection's pick reached no picker");
            }
        });
        actions.add_action(&radio);
    }
    for tag in tags {
        let check =
            gio::SimpleAction::new_stateful(&tag_action(tag.id), None, &saved.tags.contains(&tag.id).to_variant());
        let (source, target) = (source.downgrade(), (saved.id.to_string(), tag.id.to_string()));
        check.connect_activate(move |check, _| {
            let Some(source) = source.upgrade() else {
                return;
            };
            let carried = !check.state().and_then(|state| state.get::<bool>()).unwrap_or(false);
            check.set_state(&carried.to_variant());
            let target = (target.0.clone(), target.1.clone(), carried).to_variant();
            if let Err(error) = source.activate_action(&format!("{PICKER}.{SET_TAG}"), Some(&target)) {
                tracing::warn!(%error, "a connection's tag reached no picker");
            }
        });
        actions.add_action(&check);
    }
    menu.insert_action_group(ROW, Some(&actions));
}

/// Takes the connection's id, the tag's id and whether the connection
/// now carries it.
fn set_tag_action(list: Rc<SavedConnectionList>, sender: InputSender<SessionWindowInput>) -> gio::SimpleAction {
    let action = gio::SimpleAction::new(SET_TAG, Some(&<(String, String, bool)>::static_variant_type()));
    action.connect_activate(move |_, target| {
        let Some((id, tag, carried)) = target.and_then(|target| target.get::<(String, String, bool)>()) else {
            tracing::warn!(action = SET_TAG, "a picker action came without its target");
            return;
        };
        let Some(saved) = connection(&list, Some(id), SET_TAG) else {
            return;
        };
        let Some(tag) = Uuid::parse_str(&tag)
            .ok()
            .filter(|tag| list.tags().iter().any(|held| held.id == *tag))
        else {
            tracing::warn!(action = SET_TAG, "a picker action named a tag the list no longer has");
            return;
        };
        sender.deliver(SessionWindowInput::SetConnectionTag(saved.id, tag, carried));
    });
    action
}

/// What an action that names only a connection does with it.
#[derive(Debug, Clone, Copy)]
enum OnConnection {
    Connect,
    Edit,
    Delete,
    Duplicate,
    NewGroup,
    NewTag,
}

/// What an action that names a connection and a value sets.
#[derive(Debug, Clone, Copy)]
enum Setting {
    Color,
    Group,
}

/// The group a radio target names. The empty target is no group.
fn group_named(value: &str) -> Result<Option<ConnectionGroupName>, tablepro_storage::GroupNameError> {
    if value == NONE {
        return Ok(None);
    }
    ConnectionGroupName::new(value).map(Some)
}

/// The connection a target names, or `None`, with a warning, for a
/// target that is not an id or names a connection the list no longer
/// has.
fn connection(list: &SavedConnectionList, target: Option<String>, action: &str) -> Option<SavedConnection> {
    let Some(id) = target.as_deref().and_then(|target| Uuid::parse_str(target).ok()) else {
        tracing::warn!(action, "a picker action came without a connection id");
        return None;
    };
    let saved = list.get(id);
    if saved.is_none() {
        tracing::warn!(action, %id, "a picker action named a connection the list no longer has");
    }
    saved
}

/// Ask for a new group's name, then file the connection under it.
fn ask_for_group(
    parent: gtk::Widget,
    id: Uuid,
    existing: Vec<ConnectionGroupName>,
    sender: InputSender<SessionWindowInput>,
) {
    glib::spawn_future_local(async move {
        if let Some(group) = super::new_group_dialog::ask_group_name(&parent, &existing).await {
            sender.deliver(SessionWindowInput::SetConnectionGroup(id, Some(group)));
        }
    });
}

/// Ask for a new tag's name and colour, then make it and put it on the
/// connection.
fn ask_for_tag(parent: gtk::Widget, id: Uuid, existing: Vec<ConnectionTag>, sender: InputSender<SessionWindowInput>) {
    glib::spawn_future_local(async move {
        if let Some((name, color)) = crate::ui::tags::ask_new_tag(&parent, &existing).await {
            sender.deliver(SessionWindowInput::CreateTag {
                name,
                color,
                on: Some(id),
            });
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_empty_radio_target_is_no_group_and_a_blank_one_is_refused() {
        assert_eq!(group_named(NONE), Ok(None));
        assert_eq!(
            group_named(" Work ").map(|group| group.map(String::from)),
            Ok(Some("Work".to_owned()))
        );
        assert!(group_named("   ").is_err());
    }
}
