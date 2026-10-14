use std::rc::Rc;

use gtk4 as gtk;
use gtk4::gio;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_storage::{ConnectionColor, SavedConnection};
use uuid::Uuid;

use super::connection_menu::{CONNECT, DELETE, DUPLICATE, NEW_GROUP, NONE, PICKER, SET_COLOR, SET_GROUP};
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
                OnConnection::Delete => sender.deliver(SessionWindowInput::DeleteConnection(saved.id)),
                OnConnection::Duplicate => sender.deliver(SessionWindowInput::DuplicateConnection(Box::new(saved))),
                OnConnection::NewGroup => ask_for_group(root.upgrade().as_ref(), saved.id, &sender),
            }
        });
        actions.add_action(&action);
    }
    for (name, picked) in [(SET_COLOR, Setting::Color), (SET_GROUP, Setting::Group)] {
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
            sender.deliver(match picked {
                Setting::Color => SessionWindowInput::SetConnectionColor(saved.id, ConnectionColor::from_id(&value)),
                Setting::Group => {
                    SessionWindowInput::SetConnectionGroup(saved.id, Some(value).filter(|group| group != NONE))
                }
            });
        });
        actions.add_action(&action);
    }
    root.insert_action_group(PICKER, Some(&actions));
}

/// What an action that names only a connection does with it.
#[derive(Debug, Clone, Copy)]
enum OnConnection {
    Connect,
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

/// Ask for a group's name, then file the connection under it.
fn ask_for_group(parent: Option<&gtk::Widget>, id: Uuid, sender: &InputSender<SessionWindowInput>) {
    let dialog = adw::AlertDialog::new(Some(&crate::i18n::gettext("New Group")), None);
    let entry = adw::EntryRow::builder().title(crate::i18n::gettext("Name")).build();
    let group = adw::PreferencesGroup::new();
    group.add(&entry);
    dialog.set_extra_child(Some(&group));
    dialog.add_response("cancel", &crate::i18n::gettext("Cancel"));
    dialog.add_response("add", &crate::i18n::gettext("Add"));
    dialog.set_response_appearance("add", adw::ResponseAppearance::Suggested);
    dialog.set_default_response(Some("add"));
    dialog.set_close_response("cancel");
    let sender = sender.clone();
    dialog.connect_response(Some("add"), move |_, _| {
        let name = entry.text().trim().to_owned();
        if !name.is_empty() {
            sender.deliver(SessionWindowInput::SetConnectionGroup(id, Some(name)));
        }
    });
    dialog.present(parent);
}
