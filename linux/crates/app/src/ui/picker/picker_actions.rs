use std::rc::Rc;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::{gio, glib};
use tablepro_storage::{ConnectionColor, ConnectionGroupName, SavedConnection};
use uuid::Uuid;

use super::connection_menu::{CONNECT, DELETE, DUPLICATE, EDIT, MOVE_TO_GROUP, NEW_GROUP, NONE, PICKER, SET_COLOR};
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
    root.insert_action_group(PICKER, Some(&actions));
}

/// What an action that names only a connection does with it.
#[derive(Debug, Clone, Copy)]
enum OnConnection {
    Connect,
    Edit,
    Delete,
    Duplicate,
    NewGroup,
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
