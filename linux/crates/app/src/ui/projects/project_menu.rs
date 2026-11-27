use std::cell::RefCell;
use std::rc::Rc;

use gtk4::gio;
use gtk4::prelude::*;
use uuid::Uuid;

use crate::services::saved_connection_list::{SavedConnectionList, StateObserverId};
use crate::ui::menu_label;

// The submenu of `gtk/menus.ui` the projects are listed in.
pub(crate) const PROJECT_MENU: &str = "project_menu";
// Window actions, so a dialog they open has a window to sit on.
pub(crate) const SWITCH_PROJECT: &str = "project";
pub(crate) const NEW_PROJECT: &str = "new-project";
pub(crate) const MANAGE_PROJECTS: &str = "manage-projects";

const ALL_CONNECTIONS: &str = "";
// Marks the section this module put in the primary menu.
const MARK: &str = "x-tablepro-projects";

pub(crate) fn all_connections() -> String {
    crate::i18n::gettext("All Connections")
}

pub(crate) fn project_target(project: Option<Uuid>) -> String {
    project.map_or_else(|| ALL_CONNECTIONS.to_owned(), |id| id.to_string())
}

// `None` for a target that names neither All Connections nor an id.
pub(crate) fn project_from_target(target: &str) -> Option<Option<Uuid>> {
    if target == ALL_CONNECTIONS {
        return Some(None);
    }
    Uuid::parse_str(target).ok().map(Some)
}

// One radio section for every menu that switches the project, kept to the list's projects.
pub(crate) struct ProjectMenu {
    section: gio::Menu,
    list: Rc<SavedConnectionList>,
    shown: RefCell<Option<Vec<(Uuid, String)>>>,
    observer: RefCell<Option<StateObserverId>>,
}

impl ProjectMenu {
    pub(crate) fn follow(list: Rc<SavedConnectionList>) -> Rc<Self> {
        let menu = Rc::new(Self {
            section: gio::Menu::new(),
            list,
            shown: RefCell::new(None),
            observer: RefCell::new(None),
        });
        let weak = Rc::downgrade(&menu);
        let observer = menu.list.connect_state_changed(move |_| {
            if let Some(menu) = weak.upgrade() {
                menu.refresh();
            }
        });
        menu.observer.replace(Some(observer));
        menu.refresh();
        menu
    }

    pub(crate) fn section(&self) -> gio::Menu {
        self.section.clone()
    }

    // GtkApplication reads `gtk/menus.ui` once, so the primary menu takes the section once too.
    pub(crate) fn attach(&self, app: &gtk4::Application) {
        let Some(menu) = app.menu_by_id(PROJECT_MENU) else {
            tracing::error!("the primary menu has no Project submenu; is gtk/menus.ui in the resources?");
            return;
        };
        // An application outlives the services of a test, so a section left by others goes first.
        let held = (0..menu.n_items()).find(|at| menu.item_attribute_value(*at, MARK, None).is_some());
        if let Some(at) = held {
            if menu.item_link(at, gio::MENU_LINK_SECTION).as_ref() == Some(self.section.upcast_ref()) {
                return;
            }
            menu.remove(at);
        }
        let section = gio::MenuItem::new_section(None, &self.section);
        section.set_attribute_value(MARK, Some(&true.to_variant()));
        menu.prepend_item(&section);
    }

    fn refresh(&self) {
        let wanted: Vec<(Uuid, String)> = self
            .list
            .projects()
            .into_iter()
            .map(|project| (project.id, project.name.as_str().to_owned()))
            .collect();
        if self.shown.borrow().as_ref() == Some(&wanted) {
            return;
        }
        self.section.remove_all();
        self.section.append_item(&radio(&all_connections(), None));
        for (id, name) in &wanted {
            self.section.append_item(&radio(&menu_label(name), Some(*id)));
        }
        self.shown.replace(Some(wanted));
    }
}

impl Drop for ProjectMenu {
    fn drop(&mut self) {
        if let Some(observer) = self.observer.take() {
            self.list.disconnect_state_changed(observer);
        }
    }
}

fn radio(label: &str, project: Option<Uuid>) -> gio::MenuItem {
    let item = gio::MenuItem::new(Some(label), None);
    item.set_action_and_target_value(
        Some(&format!("win.{SWITCH_PROJECT}")),
        Some(&project_target(project).to_variant()),
    );
    item
}

// The picker's switcher: the projects, then what makes and manages them, in a section of their own.
pub(crate) fn switcher_menu(projects: &gio::Menu) -> gio::Menu {
    let menu = gio::Menu::new();
    menu.append_section(None, projects);
    let actions = gio::Menu::new();
    actions.append(
        Some(&crate::i18n::gettext("_New Project…")),
        Some(&format!("win.{NEW_PROJECT}")),
    );
    actions.append(
        Some(&crate::i18n::gettext("_Manage Projects…")),
        Some(&format!("win.{MANAGE_PROJECTS}")),
    );
    menu.append_section(None, &actions);
    menu
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use tablepro_storage::{
        ConnectionList, ConnectionListState, ConnectionProject, ConnectionProjectName, ConnectionStore, StoragePaths,
    };

    use super::*;
    use crate::test_support::assert_access_keys;

    fn project(name: &str, order: u32) -> ConnectionProject {
        ConnectionProject {
            order,
            ..ConnectionProject::new(ConnectionProjectName::new(name).expect("a project name"))
        }
    }

    fn list() -> (Rc<SavedConnectionList>, tempfile::TempDir) {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let store = ConnectionStore::new(&StoragePaths::under(dir.path(), "tablepro", crate::config::APP_ID));
        (
            SavedConnectionList::follow(&store, Arc::new(crate::build_registry())),
            dir,
        )
    }

    fn ready(projects: Vec<ConnectionProject>) -> ConnectionListState {
        ConnectionListState::Ready(ConnectionList::default().with_projects(projects))
    }

    fn items(menu: &gio::Menu) -> Vec<(String, Option<String>, Option<String>)> {
        (0..menu.n_items())
            .map(|at| {
                let read = |attribute: &str| {
                    menu.item_attribute_value(at, attribute, None)
                        .and_then(|value| value.get::<String>())
                };
                (
                    read(gio::MENU_ATTRIBUTE_LABEL).unwrap_or_default(),
                    read(gio::MENU_ATTRIBUTE_ACTION),
                    read(gio::MENU_ATTRIBUTE_TARGET),
                )
            })
            .collect()
    }

    #[gtk4::test]
    fn the_section_lists_all_connections_then_the_projects_in_order_and_follows_the_list() {
        let (list, _dir) = list();
        let (acme, side) = (project("Acme", 1), project("side_gig", 0));
        let menu = ProjectMenu::follow(list.clone());
        assert_eq!(
            items(&menu.section()),
            [(
                "All Connections".to_owned(),
                Some("win.project".to_owned()),
                Some(String::new())
            )],
            "a list not read yet offers no way back to every connection"
        );

        list.apply(ready(vec![acme.clone(), side.clone()]));

        assert_eq!(
            items(&menu.section()),
            [
                (
                    "All Connections".to_owned(),
                    Some("win.project".to_owned()),
                    Some(String::new())
                ),
                (
                    "side__gig".to_owned(),
                    Some("win.project".to_owned()),
                    Some(side.id.to_string())
                ),
                (
                    "Acme".to_owned(),
                    Some("win.project".to_owned()),
                    Some(acme.id.to_string())
                ),
            ]
        );
        list.apply(ready(vec![acme]));
        assert_eq!(items(&menu.section()).len(), 2, "a deleted project stayed in the menu");
    }

    #[gtk4::test]
    fn the_switcher_keeps_the_projects_apart_from_its_actions() {
        let (list, _dir) = list();
        let projects = ProjectMenu::follow(list);

        let menu = switcher_menu(&projects.section());

        assert_eq!(menu.n_items(), 2);
        assert_eq!(
            menu.item_link(0, gio::MENU_LINK_SECTION),
            Some(projects.section().upcast())
        );
        let actions = menu
            .item_link(1, gio::MENU_LINK_SECTION)
            .and_downcast::<gio::Menu>()
            .expect("the actions");
        assert_eq!(
            items(&actions),
            [
                ("_New Project…".to_owned(), Some("win.new-project".to_owned()), None),
                (
                    "_Manage Projects…".to_owned(),
                    Some("win.manage-projects".to_owned()),
                    None
                ),
            ]
        );
        // A project's name is the user's text, so only the actions have access keys.
        assert_access_keys(&actions);
    }

    #[test]
    fn a_target_reads_back_as_the_project_it_names() {
        let id = Uuid::new_v4();

        assert_eq!(project_from_target(&project_target(None)), Some(None));
        assert_eq!(project_from_target(&project_target(Some(id))), Some(Some(id)));
        assert_eq!(project_from_target("not an id"), None);
    }
}
