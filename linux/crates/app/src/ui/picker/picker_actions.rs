use std::rc::Rc;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::{gio, glib};
use tablepro_storage::{ConnectionColor, ConnectionGroup, ConnectionTag, SavedConnection};
use uuid::Uuid;

use super::connection_menu::{
    CHANGE_LIBRARY, CONNECT, DELETE, DELETE_GROUP, DUPLICATE, EDIT, MOVE_TO_GROUP, NEW_GROUP, NEW_GROUP_FOR, NEW_TAG,
    NONE, PICKER, RENAME_GROUP, ROW, ROW_COLOR, ROW_GROUP, ROW_MOVE_DOWN, ROW_MOVE_UP, ROW_PARENT, SET_COLOR,
    SET_FAVOURITE, SET_TAG, tag_action,
};
use crate::runtime::{DeliverInput, InputSender};
use crate::services::library_outline::{LibraryItem, LibraryMove, LibraryOutline, LibrarySection, Step};
use crate::services::saved_connection_editor::GroupChoice;
use crate::services::saved_connection_list::SavedConnectionList;
use crate::ui::{LibraryEdit, SessionWindowInput};

// Read again when a move runs: the list can change while a menu is open.
pub(super) type Outline = Rc<dyn Fn() -> Rc<LibraryOutline>>;

// Each action reads its connection or group again by id, so a menu left from an older list acts on nothing.
pub(crate) fn install_picker_actions(
    root: &impl IsA<gtk::Widget>,
    list: Rc<SavedConnectionList>,
    sender: InputSender<SessionWindowInput>,
) {
    let root = root.as_ref();
    let actions = gio::SimpleActionGroup::new();
    for (name, picked) in [
        (CONNECT, OnConnection::Connect),
        (EDIT, OnConnection::Edit),
        (DELETE, OnConnection::Delete),
        (DUPLICATE, OnConnection::Duplicate),
        (NEW_GROUP_FOR, OnConnection::NewGroup),
        (NEW_TAG, OnConnection::NewTag),
    ] {
        actions.add_action(&connection_action(name, picked, root, &list, &sender));
    }
    for (name, picked) in [
        (NEW_GROUP, OnGroup::NewSubgroup),
        (RENAME_GROUP, OnGroup::Rename),
        (DELETE_GROUP, OnGroup::Delete),
    ] {
        actions.add_action(&group_action(name, picked, root, &list, &sender));
    }
    for (name, picked) in [(SET_COLOR, Setting::Color), (MOVE_TO_GROUP, Setting::Group)] {
        actions.add_action(&setting_action(name, picked, &list, &sender));
    }
    actions.add_action(&set_tag_action(list.clone(), sender.clone()));
    actions.add_action(&set_favourite_action(list.clone(), sender.clone()));
    actions.add_action(&change_library_action(list, sender));
    root.insert_action_group(PICKER, Some(&actions));
}

fn connection_action(
    name: &'static str,
    picked: OnConnection,
    root: &gtk::Widget,
    list: &Rc<SavedConnectionList>,
    sender: &InputSender<SessionWindowInput>,
) -> gio::SimpleAction {
    let action = gio::SimpleAction::new(name, Some(&String::static_variant_type()));
    let (list, sender, root) = (list.clone(), sender.clone(), root.downgrade());
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
                    ask_for_group(root, list.outline(), None, Some(saved.id), sender.clone());
                }
            }
            OnConnection::NewTag => {
                if let Some(root) = root.upgrade() {
                    ask_for_tag(root, saved.id, list.tags().to_vec(), sender.clone());
                }
            }
        }
    });
    action
}

fn group_action(
    name: &'static str,
    picked: OnGroup,
    root: &gtk::Widget,
    list: &Rc<SavedConnectionList>,
    sender: &InputSender<SessionWindowInput>,
) -> gio::SimpleAction {
    let action = gio::SimpleAction::new(name, Some(&String::static_variant_type()));
    let (list, sender, root) = (list.clone(), sender.clone(), root.downgrade());
    action.connect_activate(move |_, target| {
        let target = target.and_then(|target| target.get::<String>());
        let Some(root) = root.upgrade() else {
            return;
        };
        match picked {
            OnGroup::NewSubgroup => {
                let Some(parent) = group_or_none(&list, target.as_deref(), name) else {
                    return;
                };
                let outline = list.outline();
                if !outline.can_create_in(parent) {
                    tracing::warn!(
                        action = name,
                        "a picker action asked for a group deeper than groups nest"
                    );
                    return;
                }
                ask_for_group(root, outline, parent, None, sender.clone());
            }
            OnGroup::Rename => {
                if let Some(group) = group(&list, target.as_deref(), name) {
                    ask_for_rename(root, list.outline(), group, sender.clone());
                }
            }
            OnGroup::Delete => {
                if let Some(group) = group(&list, target.as_deref(), name) {
                    let subgroups = list.outline().has_subgroups(group.id);
                    ask_for_delete(root, group, subgroups, sender.clone());
                }
            }
        }
    });
    action
}

fn setting_action(
    name: &'static str,
    picked: Setting,
    list: &Rc<SavedConnectionList>,
    sender: &InputSender<SessionWindowInput>,
) -> gio::SimpleAction {
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
            Setting::Group => {
                let Some(group) = group_or_none(&list, Some(value.as_str()), name) else {
                    return;
                };
                SessionWindowInput::SetConnectionGroup(saved.id, group.map_or(GroupChoice::None, GroupChoice::Existing))
            }
        };
        sender.deliver(input);
    });
    action
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

fn set_favourite_action(list: Rc<SavedConnectionList>, sender: InputSender<SessionWindowInput>) -> gio::SimpleAction {
    let action = gio::SimpleAction::new(SET_FAVOURITE, Some(&<(String, bool)>::static_variant_type()));
    action.connect_activate(move |_, target| {
        let Some((id, favourite)) = target.and_then(|target| target.get::<(String, bool)>()) else {
            tracing::warn!(action = SET_FAVOURITE, "a picker action came without its target");
            return;
        };
        if let Some(saved) = connection(&list, Some(id), SET_FAVOURITE) {
            sender.deliver(SessionWindowInput::Library(LibraryEdit::SetFavourite(
                saved.id, favourite,
            )));
        }
    });
    action
}

fn change_library_action(list: Rc<SavedConnectionList>, sender: InputSender<SessionWindowInput>) -> gio::SimpleAction {
    let action = gio::SimpleAction::new(
        CHANGE_LIBRARY,
        Some(&<(String, Vec<String>, String, String)>::static_variant_type()),
    );
    action.connect_activate(move |_, target| {
        let Some(change) = target.and_then(LibraryMove::from_variant) else {
            tracing::warn!(action = CHANGE_LIBRARY, "a picker action came without a move");
            return;
        };
        if !names_only_what_the_list_has(&list, &change) {
            tracing::warn!(
                action = CHANGE_LIBRARY,
                ?change,
                "a picker action named what the list no longer has"
            );
            return;
        }
        sender.deliver(SessionWindowInput::Library(LibraryEdit::Change(change)));
    });
    action
}

fn names_only_what_the_list_has(list: &SavedConnectionList, change: &LibraryMove) -> bool {
    let connection = |id: &Uuid| list.get(*id).is_some();
    let group = |id: &Uuid| list.group(*id).is_some();
    match change {
        LibraryMove::Connections {
            ids,
            group: into,
            before,
        } => !ids.is_empty() && ids.iter().all(connection) && into.iter().all(group) && before.iter().all(connection),
        LibraryMove::Groups { ids, parent, before } => {
            !ids.is_empty() && ids.iter().all(group) && parent.iter().all(group) && before.iter().all(group)
        }
        LibraryMove::Favourites { ids, before } => {
            !ids.is_empty() && ids.iter().all(connection) && before.iter().all(connection)
        }
    }
}

pub(crate) fn insert_choice_actions(
    menu: &impl IsA<gtk::Widget>,
    source: &gtk::Widget,
    saved: &SavedConnection,
    section: LibrarySection,
    outline: impl Fn() -> Rc<LibraryOutline> + 'static,
    tags: &[ConnectionTag],
) {
    let actions = choice_actions(source, saved, section, Rc::new(outline), tags);
    menu.insert_action_group(ROW, Some(&actions));
}

// A menu closes before its action runs, so a pick goes to the `picker` action from `source`.
pub(super) fn choice_actions(
    source: &gtk::Widget,
    saved: &SavedConnection,
    section: LibrarySection,
    outline: Outline,
    tags: &[ConnectionTag],
) -> gio::SimpleActionGroup {
    let actions = gio::SimpleActionGroup::new();
    let current_color = saved.color.map_or(NONE, |color| color.id()).to_owned();
    let current_group = saved
        .group_id
        .map_or_else(|| NONE.to_owned(), |group| group.to_string());
    for (name, state, forward) in [
        (ROW_COLOR, current_color, SET_COLOR),
        (ROW_GROUP, current_group, MOVE_TO_GROUP),
    ] {
        actions.add_action(&forwarding_radio(name, &state, source, saved.id, forward));
    }
    for tag in tags {
        actions.add_action(&tag_check(tag.id, saved, source));
    }
    let item = LibraryItem::Connection(saved.id);
    actions.add_action(&step_action(ROW_MOVE_UP, section, item, Step::Up, &outline, source));
    actions.add_action(&step_action(ROW_MOVE_DOWN, section, item, Step::Down, &outline, source));
    actions
}

pub(crate) fn insert_group_actions(
    menu: &impl IsA<gtk::Widget>,
    source: &gtk::Widget,
    group: Uuid,
    outline: impl Fn() -> Rc<LibraryOutline> + 'static,
) {
    let outline: Outline = Rc::new(outline);
    let actions = gio::SimpleActionGroup::new();
    let item = LibraryItem::Group(group);
    actions.add_action(&step_action(
        ROW_MOVE_UP,
        LibrarySection::Tree,
        item,
        Step::Up,
        &outline,
        source,
    ));
    actions.add_action(&step_action(
        ROW_MOVE_DOWN,
        LibrarySection::Tree,
        item,
        Step::Down,
        &outline,
        source,
    ));
    actions.add_action(&parent_radio(group, &outline, source));
    menu.insert_action_group(ROW, Some(&actions));
}

fn forwarding_radio(
    name: &str,
    state: &str,
    source: &gtk::Widget,
    id: Uuid,
    forward: &'static str,
) -> gio::SimpleAction {
    let radio = gio::SimpleAction::new_stateful(name, Some(&String::static_variant_type()), &state.to_variant());
    let (source, id) = (source.downgrade(), id.to_string());
    radio.connect_activate(move |radio, picked| {
        let (Some(source), Some(picked)) = (source.upgrade(), picked.and_then(|value| value.get::<String>())) else {
            return;
        };
        radio.set_state(&picked.to_variant());
        let target = (id.clone(), picked).to_variant();
        if let Err(error) = source.activate_action(&format!("{PICKER}.{forward}"), Some(&target)) {
            tracing::warn!(%error, "a connection's pick reached no picker");
        }
    });
    radio
}

// A check item needs an action of its own: one per tag.
fn tag_check(tag: Uuid, saved: &SavedConnection, source: &gtk::Widget) -> gio::SimpleAction {
    let check = gio::SimpleAction::new_stateful(&tag_action(tag), None, &saved.tags.contains(&tag).to_variant());
    let (source, target) = (source.downgrade(), (saved.id.to_string(), tag.to_string()));
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
    check
}

fn step_action(
    name: &str,
    section: LibrarySection,
    item: LibraryItem,
    step: Step,
    outline: &Outline,
    source: &gtk::Widget,
) -> gio::SimpleAction {
    let action = gio::SimpleAction::new(name, None);
    action.set_enabled(outline().step(section, item, step).is_some());
    let (outline, source) = (outline.clone(), source.downgrade());
    action.connect_activate(move |_, _| {
        let Some(source) = source.upgrade() else {
            return;
        };
        match outline().step(section, item, step) {
            Some(change) => change_library(&source, &change),
            None => tracing::warn!(?item, ?step, "a move had nowhere to go in the list as it is now"),
        }
    });
    action
}

fn parent_radio(group: Uuid, outline: &Outline, source: &gtk::Widget) -> gio::SimpleAction {
    let current = outline()
        .parent_of(LibraryItem::Group(group))
        .flatten()
        .map_or_else(|| NONE.to_owned(), |parent| parent.to_string());
    let radio =
        gio::SimpleAction::new_stateful(ROW_PARENT, Some(&String::static_variant_type()), &current.to_variant());
    let (outline, source) = (outline.clone(), source.downgrade());
    radio.connect_activate(move |radio, picked| {
        let (Some(source), Some(picked)) = (source.upgrade(), picked.and_then(|value| value.get::<String>())) else {
            return;
        };
        let parent = match picked.as_str() {
            NONE => None,
            id => match Uuid::parse_str(id) {
                Ok(id) => Some(id),
                Err(error) => {
                    tracing::warn!(%error, "a group's new parent is not a group id");
                    return;
                }
            },
        };
        if outline().parent_of(LibraryItem::Group(group)) == Some(parent) {
            return;
        }
        radio.set_state(&picked.to_variant());
        change_library(
            &source,
            &LibraryMove::Groups {
                ids: vec![group],
                parent,
                before: None,
            },
        );
    });
    radio
}

fn change_library(source: &gtk::Widget, change: &LibraryMove) {
    if let Err(error) = source.activate_action(&format!("{PICKER}.{CHANGE_LIBRARY}"), Some(&change.to_variant())) {
        tracing::warn!(%error, "a move reached no picker");
    }
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

#[derive(Debug, Clone, Copy)]
enum OnGroup {
    NewSubgroup,
    Rename,
    Delete,
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

fn group(list: &SavedConnectionList, target: Option<&str>, action: &str) -> Option<ConnectionGroup> {
    let Some(id) = target.and_then(|target| Uuid::parse_str(target).ok()) else {
        tracing::warn!(action, "a picker action came without a group id");
        return None;
    };
    let group = list.group(id);
    if group.is_none() {
        tracing::warn!(action, %id, "a picker action named a group the list no longer has");
    }
    group
}

// The empty target is the top level, or no group.
fn group_or_none(list: &SavedConnectionList, target: Option<&str>, action: &str) -> Option<Option<Uuid>> {
    match target {
        Some(NONE) => Some(None),
        target => group(list, target, action).map(|group| Some(group.id)),
    }
}

fn ask_for_group(
    root: gtk::Widget,
    outline: Rc<LibraryOutline>,
    parent: Option<Uuid>,
    with: Option<Uuid>,
    sender: InputSender<SessionWindowInput>,
) {
    glib::spawn_future_local(async move {
        if let Some(name) = super::new_group_dialog::ask_group_name(&root, &outline, parent).await {
            sender.deliver(SessionWindowInput::Library(LibraryEdit::CreateGroup {
                parent,
                name,
                with,
            }));
        }
    });
}

fn ask_for_rename(
    root: gtk::Widget,
    outline: Rc<LibraryOutline>,
    group: ConnectionGroup,
    sender: InputSender<SessionWindowInput>,
) {
    glib::spawn_future_local(async move {
        if let Some(name) = super::rename_group_dialog::ask_group_rename(&root, &outline, &group).await {
            sender.deliver(SessionWindowInput::Library(LibraryEdit::RenameGroup(group.id, name)));
        }
    });
}

fn ask_for_delete(root: gtk::Widget, group: ConnectionGroup, subgroups: bool, sender: InputSender<SessionWindowInput>) {
    glib::spawn_future_local(async move {
        if super::delete_group_dialog::ask_delete_group(&root, group.name.as_str(), subgroups).await {
            sender.deliver(SessionWindowInput::Library(LibraryEdit::DeleteGroup(group.id)));
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
    use std::sync::Arc;
    use std::time::Duration;

    use libadwaita as adw;
    use libadwaita::prelude::*;
    use tablepro_core::DriverRegistry;
    use tablepro_storage::{ConnectionList, ConnectionListState, ConnectionStore, StoragePaths};
    use tokio::sync::mpsc::UnboundedReceiver;

    use super::*;
    use crate::test_support::{OwnedWindow, drain_main_context, wait_until};
    use crate::ui::picker::connection_menu::tests::{group, saved};

    const WAIT: Duration = Duration::from_secs(10);

    fn library(connections: Vec<SavedConnection>, groups: Vec<ConnectionGroup>) -> ConnectionList {
        ConnectionList::new(connections, Vec::<ConnectionTag>::new()).with_groups(groups)
    }

    struct Picker {
        window: OwnedWindow<adw::Window>,
        root: gtk::Box,
        list: Rc<SavedConnectionList>,
        received: UnboundedReceiver<SessionWindowInput>,
        _dir: tempfile::TempDir,
    }

    impl Picker {
        fn new(library: ConnectionList) -> Self {
            adw::init().expect("libadwaita initialises under the test backend");
            let dir = tempfile::tempdir().expect("a temporary directory");
            let store = ConnectionStore::new(&StoragePaths::under(dir.path(), "tablepro", crate::config::APP_ID));
            let list = SavedConnectionList::follow(&store, Arc::new(DriverRegistry::new()));
            list.apply(ConnectionListState::Ready(library));
            let (sender, received) = crate::runtime::input_queue::<SessionWindowInput>();
            let root = gtk::Box::new(gtk::Orientation::Vertical, 0);
            install_picker_actions(&root, list.clone(), sender);
            let window = OwnedWindow::presented(adw::Window::new());
            window.set_content(Some(&root));
            Self {
                window,
                root,
                list,
                received,
                _dir: dir,
            }
        }

        fn run(&self, action: &str, target: Option<&glib::Variant>) {
            WidgetExt::activate_action(&self.root, action, target).expect(action);
        }

        fn sent(&mut self) -> Option<SessionWindowInput> {
            drain_main_context();
            self.received.try_recv().ok()
        }

        fn wait_sent(&mut self) -> SessionWindowInput {
            let mut sent = None;
            wait_until(WAIT, || {
                sent = self.received.try_recv().ok();
                sent.is_some()
            })
            .expect("an input");
            sent.expect("an input")
        }

        fn dialog(&self) -> adw::AlertDialog {
            let mut shown = None;
            wait_until(WAIT, || {
                shown = crate::workspace::visible_alert(&*self.window);
                shown.is_some()
            })
            .expect("a dialog");
            shown.expect("a dialog")
        }

        fn outline(&self) -> Outline {
            let list = self.list.clone();
            Rc::new(move || list.outline())
        }
    }

    fn name_row(dialog: &adw::AlertDialog) -> adw::EntryRow {
        crate::test_support::descendants(dialog)
            .into_iter()
            .find_map(|widget| widget.downcast::<adw::EntryRow>().ok())
            .expect("the name row")
    }

    fn id_target(id: Uuid) -> glib::Variant {
        id.to_string().to_variant()
    }

    #[gtk4::test]
    fn a_group_pick_names_the_group_by_id_and_an_empty_one_is_no_group() {
        let work = group("Work", None);
        let saved = saved(None);
        let mut picker = Picker::new(library(vec![saved.clone()], vec![work.clone()]));
        let pick = |group: &str| (saved.id.to_string(), group.to_owned()).to_variant();
        let stranger = Uuid::new_v4().to_string();

        picker.run("picker.move-to-group", Some(&pick(work.id.to_string().as_str())));
        assert!(matches!(
            picker.sent(),
            Some(SessionWindowInput::SetConnectionGroup(id, GroupChoice::Existing(group))) if id == saved.id && group == work.id
        ));
        picker.run("picker.move-to-group", Some(&pick(NONE)));
        assert!(matches!(
            picker.sent(),
            Some(SessionWindowInput::SetConnectionGroup(id, GroupChoice::None)) if id == saved.id
        ));
        for unknown in ["Work", "   ", stranger.as_str()] {
            picker.run("picker.move-to-group", Some(&pick(unknown)));
            assert!(picker.sent().is_none(), "{unknown:?} named a group");
        }
    }

    #[gtk4::test]
    fn a_move_naming_what_the_list_lacks_does_nothing() {
        let work = group("Work", None);
        let saved = saved(None);
        let mut picker = Picker::new(library(vec![saved.clone()], vec![work.clone()]));
        let known = LibraryMove::Connections {
            ids: vec![saved.id],
            group: Some(work.id),
            before: None,
        };

        picker.run("picker.change-library", Some(&known.to_variant()));
        match picker.sent() {
            Some(SessionWindowInput::Library(LibraryEdit::Change(change))) => assert_eq!(change, known),
            other => panic!("the move was not sent: {other:?}"),
        }
        for unknown in [
            LibraryMove::Connections {
                ids: vec![Uuid::new_v4()],
                group: None,
                before: None,
            },
            LibraryMove::Connections {
                ids: vec![saved.id],
                group: Some(Uuid::new_v4()),
                before: None,
            },
            LibraryMove::Groups {
                ids: vec![work.id],
                parent: Some(Uuid::new_v4()),
                before: None,
            },
            LibraryMove::Favourites {
                ids: vec![saved.id],
                before: Some(Uuid::new_v4()),
            },
            LibraryMove::Groups {
                ids: Vec::new(),
                parent: None,
                before: None,
            },
        ] {
            picker.run("picker.change-library", Some(&unknown.to_variant()));
            assert!(picker.sent().is_none(), "{unknown:?} was sent");
        }
    }

    #[gtk4::test]
    fn set_favourite_sends_the_connection_and_the_state() {
        let saved = saved(None);
        let mut picker = Picker::new(library(vec![saved.clone()], Vec::new()));

        picker.run("picker.set-favourite", Some(&(saved.id.to_string(), true).to_variant()));
        assert!(
            matches!(picker.sent(), Some(SessionWindowInput::Library(LibraryEdit::SetFavourite(id, true))) if id == saved.id)
        );
        picker.run(
            "picker.set-favourite",
            Some(&(saved.id.to_string(), false).to_variant()),
        );
        assert!(
            matches!(picker.sent(), Some(SessionWindowInput::Library(LibraryEdit::SetFavourite(id, false))) if id == saved.id)
        );
        picker.run(
            "picker.set-favourite",
            Some(&(Uuid::new_v4().to_string(), true).to_variant()),
        );
        assert!(picker.sent().is_none(), "a connection the list lacks was sent");
    }

    #[gtk4::test]
    fn move_up_and_down_are_on_where_a_step_exists_and_reach_the_picker() {
        let (first, second) = (saved(None), saved(None));
        let mut picker = Picker::new(library(vec![first.clone(), second], Vec::new()));
        let actions = choice_actions(
            picker.root.upcast_ref::<gtk::Widget>(),
            &first,
            LibrarySection::Tree,
            picker.outline(),
            &[],
        );
        let enabled = |name: &str| actions.lookup_action(name).is_some_and(|action| action.is_enabled());

        assert!(!enabled(ROW_MOVE_UP), "the first connection can move up");
        assert!(enabled(ROW_MOVE_DOWN));
        actions.activate_action(ROW_MOVE_DOWN, None);

        let expected = picker
            .list
            .outline()
            .step(LibrarySection::Tree, LibraryItem::Connection(first.id), Step::Down);
        assert!(expected.is_some());
        match picker.sent() {
            Some(SessionWindowInput::Library(LibraryEdit::Change(change))) => assert_eq!(Some(change), expected),
            other => panic!("the move was not sent: {other:?}"),
        }
    }

    #[gtk4::test]
    fn a_move_reads_the_list_as_it_is_when_it_runs() {
        let (first, second) = (saved(None), saved(None));
        let mut picker = Picker::new(library(vec![first.clone(), second.clone()], Vec::new()));
        let actions = choice_actions(
            picker.root.upcast_ref::<gtk::Widget>(),
            &first,
            LibrarySection::Tree,
            picker.outline(),
            &[],
        );
        let moved = SavedConnection {
            order: 1,
            ..first.clone()
        };
        let stays = SavedConnection { order: 0, ..second };
        picker
            .list
            .apply(ConnectionListState::Ready(library(vec![stays, moved], Vec::new())));

        actions.activate_action(ROW_MOVE_DOWN, None);

        assert!(
            picker.sent().is_none(),
            "the move used the list from when the menu opened"
        );
    }

    #[gtk4::test]
    fn a_group_moves_to_the_parent_picked_and_not_to_the_one_it_has() {
        let work = group("Work", None);
        let archive = group("Archive", None);
        let mut picker = Picker::new(library(Vec::new(), vec![work.clone(), archive.clone()]));
        let menu = gtk::Box::new(gtk::Orientation::Vertical, 0);
        let list = picker.list.clone();
        insert_group_actions(&menu, picker.root.upcast_ref::<gtk::Widget>(), archive.id, move || {
            list.outline()
        });

        WidgetExt::activate_action(&menu, "picker-row.parent", Some(&NONE.to_variant())).expect("picker-row.parent");
        assert!(picker.sent().is_none(), "a group was moved where it already is");
        WidgetExt::activate_action(&menu, "picker-row.parent", Some(&id_target(work.id))).expect("picker-row.parent");

        match picker.sent() {
            Some(SessionWindowInput::Library(LibraryEdit::Change(change))) => assert_eq!(
                change,
                LibraryMove::Groups {
                    ids: vec![archive.id],
                    parent: Some(work.id),
                    before: None,
                }
            ),
            other => panic!("the move was not sent: {other:?}"),
        }
    }

    #[gtk4::test]
    fn rename_group_asks_then_sends_the_new_name() {
        let work = group("Work", None);
        let mut picker = Picker::new(library(Vec::new(), vec![work.clone()]));

        picker.run("picker.rename-group", Some(&id_target(work.id)));
        let dialog = picker.dialog();
        assert_eq!(dialog.heading().as_deref(), Some("Rename Group"));
        name_row(&dialog).set_text("Office");
        crate::test_support::respond(&dialog, "rename");

        assert!(matches!(
            picker.wait_sent(),
            SessionWindowInput::Library(LibraryEdit::RenameGroup(id, name)) if id == work.id && name.as_str() == "Office"
        ));
    }

    #[gtk4::test]
    fn delete_group_asks_then_sends_the_delete() {
        let work = group("Work", None);
        let staging = group("Staging", Some(work.id));
        let mut picker = Picker::new(library(Vec::new(), vec![work.clone(), staging]));

        picker.run("picker.delete-group", Some(&id_target(work.id)));
        let dialog = picker.dialog();
        assert_eq!(dialog.heading().as_deref(), Some("Delete “Work”?"));
        assert!(
            dialog.body().contains("groups inside it"),
            "the subgroups going too is not said: {}",
            dialog.body()
        );
        crate::test_support::respond(&dialog, "delete");

        assert!(
            matches!(picker.wait_sent(), SessionWindowInput::Library(LibraryEdit::DeleteGroup(id)) if id == work.id)
        );
    }

    #[gtk4::test]
    fn new_subgroup_asks_for_a_name_under_its_parent() {
        let work = group("Work", None);
        let mut picker = Picker::new(library(Vec::new(), vec![work.clone()]));

        picker.run("picker.new-group", Some(&id_target(work.id)));
        let dialog = picker.dialog();
        assert_eq!(dialog.heading().as_deref(), Some("New Subgroup"));
        name_row(&dialog).set_text("Staging");
        crate::test_support::respond(&dialog, "create");

        assert!(matches!(
            picker.wait_sent(),
            SessionWindowInput::Library(LibraryEdit::CreateGroup { parent: Some(parent), name, with: None })
                if parent == work.id && name.as_str() == "Staging"
        ));
    }

    #[gtk4::test]
    fn an_empty_target_asks_for_a_top_level_group() {
        let mut picker = Picker::new(library(Vec::new(), Vec::new()));

        picker.run("picker.new-group", Some(&NONE.to_variant()));
        let dialog = picker.dialog();
        assert_eq!(dialog.heading().as_deref(), Some("New Group"));
        name_row(&dialog).set_text("Archive");
        crate::test_support::respond(&dialog, "create");

        assert!(matches!(
            picker.wait_sent(),
            SessionWindowInput::Library(LibraryEdit::CreateGroup { parent: None, name, with: None }) if name.as_str() == "Archive"
        ));
    }

    #[gtk4::test]
    fn new_group_for_a_connection_files_it_in_a_new_top_level_group() {
        let work = group("Work", None);
        let saved = saved(Some(work.id));
        let mut picker = Picker::new(library(vec![saved.clone()], vec![work]));

        picker.run("picker.new-group-for", Some(&id_target(saved.id)));
        let dialog = picker.dialog();
        assert_eq!(dialog.heading().as_deref(), Some("New Group"));
        name_row(&dialog).set_text("Archive");
        crate::test_support::respond(&dialog, "create");

        assert!(matches!(
            picker.wait_sent(),
            SessionWindowInput::Library(LibraryEdit::CreateGroup { parent: None, name, with: Some(with) })
                if with == saved.id && name.as_str() == "Archive"
        ));
    }

    #[gtk4::test]
    fn a_group_the_list_lacks_asks_nothing() {
        let mut picker = Picker::new(library(Vec::new(), Vec::new()));

        for action in ["picker.new-group", "picker.rename-group", "picker.delete-group"] {
            picker.run(action, Some(&id_target(Uuid::new_v4())));
        }
        picker.run("picker.new-group-for", Some(&id_target(Uuid::new_v4())));

        assert!(picker.sent().is_none());
        assert!(
            crate::workspace::visible_alert(&*picker.window).is_none(),
            "a dialog asked"
        );
    }
}
