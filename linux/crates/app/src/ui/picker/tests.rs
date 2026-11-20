use std::rc::Rc;
use std::time::Duration;

use chrono::{TimeDelta, Utc};
use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_storage::{
    ConnectionGroup, ConnectionGroupName, ConnectionList, ConnectionListState, ConnectionProject,
    ConnectionProjectName, ConnectionStore, SavedConnection, StoragePaths,
};
use uuid::Uuid;

use crate::runtime::AppRuntime;
use crate::services::library_outline::{LibraryItem, LibraryMove, LibrarySection};
use crate::services::saved_connection_list::SavedConnectionList;
use crate::test_support::{
    NestedLibrary, OwnedWindow, descendants, drain_main_context, respond, save_filed, saved_connection, test_runtime,
    wait_until,
};
use crate::ui::delete_connection_dialog;
use crate::ui::library_drag::LibraryDragItem;
use crate::ui::picker::LibraryRow;
use crate::ui::session_window::SessionWindow;
use crate::ui::session_window::tests::{Script, TestWindow};
use crate::ui::welcome_view::WelcomeView;
use crate::ui::{LibraryEdit, SessionWindowInput};

const WAIT: Duration = Duration::from_secs(10);

fn connection(name: &str, group: Option<&str>) -> SavedConnection {
    SavedConnection {
        group_id: group.map(crate::test_support::group_id),
        ..saved_connection(name)
    }
}

fn group(name: &str) -> ConnectionGroup {
    ConnectionGroup::new(ConnectionGroupName::new(name).expect("a group name"), None)
}

// Two pickers on one list, as two windows have.
struct Pickers {
    runtime: AppRuntime,
    store: ConnectionStore,
    list: Rc<SavedConnectionList>,
    views: [WelcomeView; 2],
    _dir: tempfile::TempDir,
}

impl Pickers {
    fn new() -> Self {
        adw::init().expect("libadwaita initialises under the test backend");
        crate::register_test_resources();
        let dir = tempfile::tempdir().expect("a temporary directory");
        let store = ConnectionStore::new(&StoragePaths::under(dir.path(), "tablepro", crate::config::APP_ID));
        let list = SavedConnectionList::follow(&store, std::sync::Arc::new(crate::build_registry()));
        let views = [
            WelcomeView::new(list.clone(), None),
            WelcomeView::new(list.clone(), None),
        ];
        Self {
            runtime: test_runtime(),
            store,
            list,
            views,
            _dir: dir,
        }
    }

    // Off the GTK thread, as the connect dialog and a connect write.
    fn write(&self, write: impl FnOnce(&ConnectionStore) + Send + 'static) {
        let store = self.store.clone();
        let writing = self.runtime.tasks().spawn_blocking_task(move || write(&store));
        crate::test_support::finish_on_main(WAIT, writing)
            .expect("the write to end")
            .expect("the write task");
    }

    fn every_picker(&self, mut shows: impl FnMut(&[(String, Vec<String>)]) -> bool) -> bool {
        self.views.iter().all(|view| shows(&view.sections()))
    }

    fn show(&self, library: ConnectionList) {
        self.list.apply(ConnectionListState::Ready(library));
    }
}

impl Drop for Pickers {
    fn drop(&mut self) {
        for view in &self.views {
            view.shutdown();
        }
        drain_main_context();
    }
}

fn ready<const N: usize>(connections: [SavedConnection; N]) -> ConnectionListState {
    ConnectionListState::Ready(crate::test_support::library(Vec::from(connections), Vec::new()))
}

fn rows(sections: &[(String, Vec<String>)]) -> Vec<String> {
    sections.iter().flat_map(|(_, rows)| rows.clone()).collect()
}

fn section(title: &str, rows: &[&str]) -> (String, Vec<String>) {
    (title.to_owned(), rows.iter().map(|row| (*row).to_owned()).collect())
}

fn tag_names(view: &WelcomeView, title: &str) -> Vec<String> {
    view.node(LibrarySection::Tree, title)
        .unwrap_or_else(|| panic!("no row for {title}"))
        .tags()
        .into_iter()
        .map(|tag| tag.name.as_str().to_owned())
        .collect()
}

fn project(name: &str, order: u32) -> ConnectionProject {
    ConnectionProject {
        order,
        ..ConnectionProject::new(ConnectionProjectName::new(name).expect("a project name"))
    }
}

struct Projects {
    library: ConnectionList,
    acme: ConnectionProject,
    side: ConnectionProject,
}

// Acme: the group Work with w1, and the loose a1, a favourite. Side: s1, opened last. No project: n1.
fn two_projects() -> Projects {
    let (acme, side) = (project("Acme", 0), project("Side", 1));
    let work = ConnectionGroup {
        project_id: Some(acme.id),
        ..group("Work")
    };
    let now = Utc::now();
    let w1 = SavedConnection {
        group_id: Some(work.id),
        last_opened_at: Some(now - TimeDelta::hours(2)),
        ..saved_connection("w1")
    };
    let a1 = SavedConnection {
        project_id: Some(acme.id),
        order: 0,
        ..saved_connection("a1")
    };
    let s1 = SavedConnection {
        project_id: Some(side.id),
        last_opened_at: Some(now),
        order: 1,
        ..saved_connection("s1")
    };
    let n1 = SavedConnection {
        order: 2,
        ..saved_connection("n1")
    };
    let favourites = vec![a1.id, s1.id];
    let library = ConnectionList::new(vec![w1, a1, s1, n1], Vec::new())
        .with_groups(vec![work])
        .with_favorites(favourites)
        .with_projects(vec![acme.clone(), side.clone()]);
    Projects { library, acme, side }
}

#[gtk4::test]
fn a_project_narrows_favourites_recent_the_tree_and_the_search_in_every_picker() {
    let pickers = Pickers::new();
    let projects = two_projects();
    pickers.show(projects.library.clone());
    let all = [
        section("Favourites", &["a1", "s1"]),
        section("Recent", &["w1"]),
        section("Connections", &["Work", "  w1", "a1", "s1", "n1"]),
    ];
    wait_until(WAIT, || pickers.every_picker(|sections| sections == all)).expect("every connection");

    pickers.list.set_active_project(Some(projects.acme.id));

    let acme = [
        section("Favourites", &["a1"]),
        section("Recent", &["w1"]),
        section("Connections", &["Work", "  w1", "a1"]),
    ];
    wait_until(WAIT, || pickers.every_picker(|sections| sections == acme)).expect("the project's connections");
    assert_eq!(
        pickers
            .list
            .get(projects.library.connections[2].id)
            .map(|saved| saved.name),
        Some("s1".to_owned()),
        "a connection of another project is gone from the lookup by id"
    );

    let view = &pickers.views[0];
    view.set_search("1");
    assert_eq!(view.sections(), [section("", &["w1", "a1"])]);
    view.set_search("s1");
    assert_eq!(view.visible_page().as_deref(), Some("no-results"));
    let (title, button) = view.status().expect("the status page");
    assert_eq!(title, "No Results in Acme");
    let button = button.expect("Search All Connections");
    assert_eq!(button.label().as_deref(), Some("Search All Connections"));
    assert_eq!(button.action_name().as_deref(), Some("win.project"));
    assert_eq!(
        button.action_target_value().and_then(|target| target.get::<String>()),
        Some(String::new())
    );

    pickers.list.set_active_project(None);
    assert_eq!(
        view.sections(),
        [section("", &["s1"])],
        "the search was lost with the switch"
    );
    view.set_search("nothing has this");
    let (title, button) = view.status().expect("the status page");
    assert_eq!(title, "No Results Found");
    assert!(button.is_none(), "All Connections offers a wider search");
}

#[gtk4::test]
fn an_empty_project_says_so_and_is_not_the_first_run_page() {
    let pickers = Pickers::new();
    let projects = two_projects();
    let empty = project("Empty", 2);
    let library =
        projects
            .library
            .clone()
            .with_projects(vec![projects.acme.clone(), projects.side.clone(), empty.clone()]);
    pickers.show(library);
    let view = &pickers.views[0];

    pickers.list.set_active_project(Some(empty.id));

    assert_eq!(view.visible_page().as_deref(), Some("empty-project"));
    let (title, button) = view.status().expect("the status page");
    assert_eq!(title, "No Connections in Empty");
    let button = button.expect("New Connection");
    assert_eq!(button.label().as_deref(), Some("New Connection"));
    assert_eq!(button.action_name().as_deref(), Some("win.new-connection"));

    pickers.list.set_active_project(Some(projects.side.id));
    assert_eq!(view.visible_page().as_deref(), Some("list"));
    pickers.show(ConnectionList::default());
    assert_eq!(view.visible_page().as_deref(), Some("empty"), "the first-run page");
    assert_eq!(view.status().map(|(title, _)| title).as_deref(), Some("No Connections"));
}

#[gtk4::test]
fn a_deleted_active_project_falls_back_to_all_connections() {
    let pickers = Pickers::new();
    let projects = two_projects();
    pickers.show(projects.library.clone());
    pickers.list.set_active_project(Some(projects.side.id));
    wait_until(WAIT, || pickers.every_picker(|sections| rows(sections) == ["s1", "s1"])).expect("Side's connection");
    assert_eq!(pickers.list.scope().map(|scope| scope.name), Some("Side".to_owned()));

    pickers.show(projects.library.clone().with_projects(vec![projects.acme.clone()]));

    assert_eq!(pickers.list.active_project(), None);
    assert_eq!(pickers.list.scope(), None);
    assert!(
        pickers.every_picker(
            |sections| sections.last() == Some(&section("Connections", &["Work", "  w1", "a1", "s1", "n1"]))
        ),
        "{:?}",
        pickers.views[0].sections()
    );
}

#[gtk4::test]
fn the_switcher_names_the_active_project_and_a_pick_switches_every_list() {
    let test = TestWindow::picker("PickerProjectSwitch");
    let store = test.services.storage.connections().clone();
    let acme = store.create_project_blocking(project("Acme", 0)).expect("the project");
    let picker = test.window.picker_page().expect("the picker page");
    let button = picker.project_button();
    assert_eq!(button.label().as_deref(), Some("All Connections"));
    assert_eq!(button.tooltip_text().as_deref(), Some("Switch Project"));
    crate::test_support::assert_labelled(&button).expect("the switcher's accessible name");
    let state = || {
        test.window
            .action_state("project")
            .and_then(|state| state.get::<String>())
    };
    assert_eq!(state(), Some(String::new()));
    wait_until(WAIT, || test.services.saved_connections.projects().len() == 1).expect("the project in the list");

    gtk::prelude::WidgetExt::activate_action(&test.window, "win.project", Some(&acme.id.to_string().to_variant()))
        .expect("win.project");

    wait_until(WAIT, || button.label().as_deref() == Some("Acme")).expect("the switcher to name the project");
    assert_eq!(test.services.settings.active_project(), Some(acme.id));
    assert_eq!(
        test.services.active_project.get(),
        Some(acme.id),
        "the MCP host reads another project"
    );
    assert_eq!(state(), Some(acme.id.to_string()));
    let view = picker_view(&test.window);
    assert_eq!(view.visible_page().as_deref(), Some("empty-project"));
    assert!(
        test.services.saved_connections.get(test.saved.id).is_some(),
        "a switch dropped a connection from the lookup by id"
    );

    store.delete_project_blocking(acme.id).expect("the delete");
    wait_until(WAIT, || button.label().as_deref() == Some("All Connections")).expect("the fallback");
    assert_eq!(state(), Some(String::new()));
    assert_eq!(view.sections(), [section("Connections", &["Fake"])]);
}

#[gtk4::test]
fn the_switcher_menu_is_a_radio_section_then_new_and_manage() {
    let test = TestWindow::picker("PickerProjectMenu");
    let store = test.services.storage.connections().clone();
    let acme = store.create_project_blocking(project("Acme", 0)).expect("the project");
    wait_until(WAIT, || test.services.saved_connections.projects().len() == 1).expect("the project in the list");
    let picker = test.window.picker_page().expect("the picker page");
    let menu = picker.project_button().menu_model().expect("the switcher's menu");

    assert_eq!(menu.n_items(), 2);
    let read = |section: i32| -> Vec<(String, Option<String>, Option<String>)> {
        let items = menu.item_link(section, "section").expect("a section");
        (0..items.n_items())
            .map(|at| {
                let attribute = |name: &str| {
                    items
                        .item_attribute_value(at, name, None)
                        .and_then(|value| value.get::<String>())
                };
                (
                    attribute("label").unwrap_or_default(),
                    attribute("action"),
                    attribute("target"),
                )
            })
            .collect()
    };
    let radio = |label: &str, target: String| (label.to_owned(), Some("win.project".to_owned()), Some(target));
    assert_eq!(
        read(0),
        [
            radio("All Connections", String::new()),
            radio("Acme", acme.id.to_string())
        ]
    );
    assert_eq!(
        read(1),
        [
            ("_New Project…".to_owned(), Some("win.new-project".to_owned()), None),
            (
                "_Manage Projects…".to_owned(),
                Some("win.manage-projects".to_owned()),
                None
            ),
        ]
    );
    // The same radio section, so the scope is reachable from a session window's main menu.
    let primary = test.app.menu_by_id("project_menu").expect("the Project submenu");
    assert_eq!(
        primary.item_link(0, "section"),
        menu.item_link(0, "section"),
        "the main menu lists other projects"
    );
    for action in ["project", "new-project", "manage-projects"] {
        assert!(test.window.lookup_action(action).is_some(), "win.{action} is missing");
    }
}

#[gtk4::test]
fn manage_projects_opens_one_dialog_per_window_and_follows_the_list() {
    let test = TestWindow::picker("PickerManageProjects");
    let manage = || {
        gtk::prelude::WidgetExt::activate_action(&test.window, "win.manage-projects", None)
            .expect("win.manage-projects");
        wait_until(WAIT, || test.window.manage_projects().is_some()).expect("Manage Projects");
        test.window.manage_projects().expect("Manage Projects")
    };

    let first = manage();
    assert_eq!(first.page().as_deref(), Some("empty"));
    assert!(Rc::ptr_eq(&first, &manage()), "a second ask opened a second dialog");
    test.services
        .storage
        .connections()
        .create_project_blocking(project("Acme", 0))
        .expect("the project");
    wait_until(WAIT, || {
        first.rows() == [("Acme".to_owned(), "No connections".to_owned())]
    })
    .expect("the new project");

    first.dialog.force_close();
    wait_until(WAIT, || test.window.manage_projects().is_none()).expect("the closed dialog to be let go");
}

#[gtk4::test]
fn new_project_makes_it_active_and_what_is_made_next_lands_in_it() {
    let test = TestWindow::picker("PickerNewProject");
    let store = test.services.storage.connections().clone();
    let name = |name: &str| ConnectionProjectName::new(name).expect("a project name");

    test.window
        .send(SessionWindowInput::Library(LibraryEdit::CreateProject {
            name: name("Acme"),
            switch: true,
        }));

    let list = test.services.saved_connections.clone();
    wait_until(WAIT, || list.active_project().is_some()).expect("the new project to be active");
    let acme = list.active_project().expect("the project");
    assert_eq!(acme.name.as_str(), "Acme");
    assert_eq!(test.services.settings.active_project(), Some(acme.id));

    test.window.send(SessionWindowInput::Library(LibraryEdit::CreateGroup {
        parent: None,
        name: ConnectionGroupName::new("Work").expect("a group name"),
        with: None,
    }));
    wait_until(WAIT, || list.outline().groups().len() == 1).expect("the group in the project");
    let work = list.outline().groups()[0].0;
    assert_eq!(list.project_of_group(work), Some(acme.id));

    test.window
        .send(SessionWindowInput::Library(LibraryEdit::MoveToProject {
            item: LibraryItem::Connection(test.saved.id),
            project: Some(acme.id),
        }));
    wait_until(WAIT, || list.project_of(test.saved.id) == Some(acme.id)).expect("the connection to move");
    assert_eq!(
        picker_view(&test.window).sections(),
        [section("Connections", &["Work", "Fake"])]
    );

    test.window
        .send(SessionWindowInput::Library(LibraryEdit::CreateProject {
            name: name("Side"),
            switch: false,
        }));
    wait_until(WAIT, || list.projects().len() == 2).expect("the second project");
    assert_eq!(
        list.active_project().map(|project| project.id),
        Some(acme.id),
        "Manage Projects switched"
    );

    test.window
        .send(SessionWindowInput::Library(LibraryEdit::DeleteProject(acme.id)));
    wait_until(WAIT, || list.active_project().is_none()).expect("the fallback to All Connections");
    let kept = store.list_blocking().expect("the list");
    assert_eq!(kept.connections.len(), 1, "a deleted project took its connection");
    assert_eq!(kept.groups.len(), 1, "a deleted project took its group");
}

#[gtk4::test]
fn move_to_project_is_offered_to_an_ungrouped_connection_and_a_top_level_group_only() {
    let test = TestWindow::picker("PickerMoveToProject");
    let store = test.services.storage.connections().clone();
    let acme = store.create_project_blocking(project("Acme", 0)).expect("the project");
    let work = store.create_group_blocking(group("Work")).expect("the group");
    let nested = store
        .create_group_blocking(ConnectionGroup::new(
            ConnectionGroupName::new("Nested").expect("a group name"),
            Some(work.id),
        ))
        .expect("the subgroup");
    let filed = SavedConnection {
        group_id: Some(work.id),
        ..saved_connection("Filed")
    };
    store.upsert_blocking(filed.clone()).expect("the save");
    let list = test.services.saved_connections.clone();
    wait_until(WAIT, || list.get(filed.id).is_some() && list.projects().len() == 1).expect("the list");
    let outline = list.outline();
    let offered = |menu: gtk::gio::Menu| -> Vec<(String, Option<String>)> {
        super::connection_menu::tests::items(menu.upcast_ref())
            .into_iter()
            .filter(|(_, action, _)| action.as_deref().is_some_and(|action| action.ends_with("-to-project")))
            .map(|(label, _, target)| {
                (
                    label,
                    target
                        .and_then(|target| target.get::<(String, String)>())
                        .map(|(_, project)| project),
                )
            })
            .collect()
    };
    let choices = vec![
        ("_No Project".to_owned(), Some(String::new())),
        ("Acme".to_owned(), Some(acme.id.to_string())),
    ];

    assert_eq!(
        offered(super::connection_menu::connection_menu(
            test.saved.id,
            LibrarySection::Tree,
            &outline,
            &[]
        )),
        choices
    );
    assert_eq!(offered(super::group_menu::group_menu(work.id, &outline)), choices);
    assert!(
        offered(super::connection_menu::connection_menu(
            filed.id,
            LibrarySection::Tree,
            &outline,
            &[]
        ))
        .is_empty(),
        "a grouped connection is offered a project of its own"
    );
    assert!(
        offered(super::group_menu::group_menu(nested.id, &outline)).is_empty(),
        "a subgroup is offered a project of its own"
    );

    let row = picker_row(&test.window, "Work");
    row.activate_action(
        "picker.group-to-project",
        Some(&(work.id.to_string(), acme.id.to_string()).to_variant()),
    )
    .expect("picker.group-to-project");
    wait_until(WAIT, || list.project_of(filed.id) == Some(acme.id)).expect("the group's connection to follow it");
    row.activate_action(
        "picker.connection-to-project",
        Some(&(test.saved.id.to_string(), acme.id.to_string()).to_variant()),
    )
    .expect("picker.connection-to-project");
    wait_until(WAIT, || list.project_of(test.saved.id) == Some(acme.id)).expect("the connection to move");
    row.activate_action(
        "picker.connection-to-project",
        Some(&(test.saved.id.to_string(), String::new()).to_variant()),
    )
    .expect("picker.connection-to-project");
    wait_until(WAIT, || list.project_of(test.saved.id).is_none()).expect("the connection to leave the project");
}

#[gtk4::test]
fn connect_dialog_save_updates_every_picker() {
    let pickers = Pickers::new();
    let corp = connection("Corp", None);

    pickers.write(move |store| store.upsert_blocking(corp).expect("the save"));

    wait_until(WAIT, || pickers.every_picker(|sections| rows(sections) == ["Corp"]))
        .expect("every picker to list the new connection");
}

#[gtk4::test]
fn a_connect_stamp_moves_the_connection_into_recent_not_within_its_group() {
    let pickers = Pickers::new();
    let (alpha, beta) = (connection("Alpha", Some("Work")), connection("Beta", Some("Work")));
    let stamped = beta.id;
    pickers.write(move |store| {
        save_filed(store, alpha);
        save_filed(store, beta);
    });
    let tree = section("Connections", &["Work", "  Alpha", "  Beta"]);
    wait_until(WAIT, || {
        pickers.every_picker(|sections| sections == [tree.clone()].as_slice())
    })
    .expect("both connections in the group, in the order they were saved");

    pickers.write(move |store| store.touch_last_opened_blocking(stamped).expect("the stamp"));

    let after = [section("Recent", &["Beta"]), tree.clone()];
    wait_until(WAIT, || pickers.every_picker(|sections| sections == after.as_slice()))
        .expect("the connection opened last in Recent, and its group as it was");
    let recent = pickers.views[0]
        .node(LibrarySection::Recent, "Beta")
        .expect("Beta's Recent row");
    assert!(recent.subtitle().ends_with(" · Work"), "{}", recent.subtitle());
}

#[gtk4::test]
fn nested_and_empty_groups_show_in_the_librarys_order() {
    let pickers = Pickers::new();
    let mut library = NestedLibrary::default();
    library.connection("Zeta", None);
    let work = library.group("Work", None);
    let staging = library.group("Staging", Some(work));
    library.group("Empty", Some(staging));
    library.group("Home", None);
    library.connection("W1", Some(work));
    library.connection("S1", Some(staging));
    library.connection("Alpha", None);

    pickers.show(library.list());

    assert_eq!(
        pickers.views[0].sections(),
        [section(
            "Connections",
            &[
                "Work",
                "  Staging",
                "    Empty",
                "    S1",
                "  W1",
                "Home",
                "Zeta",
                "Alpha"
            ]
        )]
    );
    assert_eq!(pickers.views[0].visible_page().as_deref(), Some("list"));
}

#[gtk4::test]
fn favourites_follow_the_librarys_order_and_recent_leaves_them_out() {
    let pickers = Pickers::new();
    let mut library = NestedLibrary::default();
    let work = library.group("Work", None);
    let a = library.connection("a", None);
    library.add(SavedConnection {
        last_opened_at: Some(Utc::now()),
        ..saved_connection("b")
    });
    let c = library.add(SavedConnection {
        last_opened_at: Some(Utc::now() - TimeDelta::hours(1)),
        ..saved_connection("c")
    });
    let d = library.connection("d", Some(work));
    for id in [c, d, a] {
        library.favourite(id);
    }

    pickers.show(library.list());

    assert_eq!(
        pickers.views[0].sections(),
        [
            section("Favourites", &["c", "d", "a"]),
            section("Recent", &["b"]),
            section("Connections", &["Work", "  d", "a", "b", "c"]),
        ]
    );
}

#[gtk4::test]
fn a_connection_outside_the_tree_names_its_groups_path() {
    let pickers = Pickers::new();
    let mut library = NestedLibrary::default();
    let work = library.group("Work", None);
    let staging = library.group("Staging", Some(work));
    let nested = library.connection("nested", Some(staging));
    library.connection("filed", Some(work));
    library.connection("loose", None);
    library.favourite(nested);

    pickers.show(library.list());

    let view = &pickers.views[0];
    assert_eq!(
        view.sections(),
        [
            section("Favourites", &["nested"]),
            section("Connections", &["Work", "  Staging", "    nested", "  filed", "loose"]),
        ]
    );
    let favourite = view
        .node(LibrarySection::Favourites, "nested")
        .expect("the Favourites row");
    let filed = view.node(LibrarySection::Tree, "nested").expect("the tree's row");
    assert!(
        favourite.subtitle().ends_with(" · Work / Staging"),
        "{}",
        favourite.subtitle()
    );
    assert!(!filed.subtitle().contains("Work / Staging"), "{}", filed.subtitle());
    assert!(favourite.favourite() && filed.favourite());
}

#[gtk4::test]
fn an_empty_group_alone_shows_the_list() {
    let pickers = Pickers::new();
    let mut library = NestedLibrary::default();
    library.group("Archive", None);

    pickers.show(library.list());

    let view = &pickers.views[0];
    assert_eq!(view.visible_page().as_deref(), Some("list"));
    assert_eq!(view.sections(), [section("Connections", &["Archive"])]);
}

#[gtk4::test]
fn the_empty_page_shows_only_for_a_list_that_is_read_and_empty() {
    let pickers = Pickers::new();
    let view = &pickers.views[0];
    assert_eq!(
        view.visible_page().as_deref(),
        Some("list"),
        "a loading list offered to add one"
    );

    pickers.list.apply(ready([]));
    assert_eq!(view.visible_page().as_deref(), Some("empty"));

    pickers.list.apply(ready([connection("Corp", None)]));
    assert_eq!(view.visible_page().as_deref(), Some("list"));
}

#[gtk4::test]
fn a_group_stays_open_after_a_reorder() {
    let pickers = Pickers::new();
    let view = &pickers.views[0];
    let window = OwnedWindow::presented(adw::Window::new());
    window.set_content(Some(view));
    let mut library = NestedLibrary::default();
    let work = library.group("Work", None);
    let staging = library.group("Staging", Some(work));
    let home = library.group("Home", None);
    library.connection("s1", Some(staging));
    library.connection("h1", Some(home));
    let list = library.list();
    pickers.show(list.clone());
    wait_until(WAIT, || view.row(LibrarySection::Tree, "Home").is_some()).expect("Home's row");
    view.tree_row("Home").expect("Home's tree row").set_expanded(false);
    assert_eq!(
        view.sections(),
        [section("Connections", &["Work", "  Staging", "    s1", "Home"])]
    );

    let reordered: Vec<ConnectionGroup> = list
        .groups
        .iter()
        .map(|group| ConnectionGroup {
            order: match group.id {
                id if id == home => 0,
                id if id == work => 1,
                _ => group.order,
            },
            ..group.clone()
        })
        .collect();
    pickers.show(ConnectionList::new(list.connections.to_vec(), Vec::new()).with_groups(reordered));

    assert_eq!(
        view.sections(),
        [section("Connections", &["Home", "Work", "  Staging", "    s1"])],
        "a moved group folded, or a folded one opened"
    );
}

fn picker_view(window: &SessionWindow) -> WelcomeView {
    descendants(window)
        .into_iter()
        .find_map(|widget| widget.downcast::<WelcomeView>().ok())
        .expect("the picker")
}

fn picker_row_in(window: &SessionWindow, section: LibrarySection, name: &str) -> LibraryRow {
    let view = picker_view(window);
    let mut found = None;
    wait_until(WAIT, || {
        found = view.row(section, name);
        found.is_some()
    })
    .expect("the connection's row");
    found.expect("the row")
}

fn picker_row(window: &SessionWindow, name: &str) -> LibraryRow {
    picker_row_in(window, LibrarySection::Tree, name)
}

fn expander(row: &LibraryRow) -> gtk::TreeExpander {
    row.parent()
        .and_downcast::<gtk::TreeExpander>()
        .expect("the row's expander")
}

// The row's choices are made as its menu opens, from the list as it is then.
fn open_menu(row: &LibraryRow) -> gtk::MenuButton {
    let button = row.menu_button();
    row.popup_menu();
    wait_until(WAIT, || button.popover().is_some_and(|popover| popover.is_visible())).expect("the row's menu to open");
    button
}

fn focused_title(window: &SessionWindow) -> Option<String> {
    let mut widget = gtk::prelude::GtkWindowExt::focus(window);
    while let Some(current) = widget {
        if let Some(expander) = current.downcast_ref::<gtk::TreeExpander>() {
            return expander
                .child()
                .and_downcast::<LibraryRow>()
                .and_then(|row| row.node())
                .map(|node| node.title());
        }
        widget = current.parent();
    }
    None
}

fn alert_dialogs(window: &SessionWindow) -> Vec<adw::AlertDialog> {
    window
        .dialogs()
        .iter::<glib::Object>()
        .filter_map(|item| item.ok()?.downcast::<adw::AlertDialog>().ok())
        .collect()
}

#[gtk4::test]
fn delete_action_presents_exactly_one_dialog() {
    let test = TestWindow::picker("PickerDelete");
    let row = picker_row(&test.window, "Fake");

    row.activate_action("picker.delete", Some(&test.saved.id.to_string().to_variant()))
        .expect("picker.delete");

    wait_until(WAIT, || test.window.visible_dialog().is_some()).expect("a dialog");
    let shown = test
        .window
        .visible_dialog()
        .and_downcast::<adw::AlertDialog>()
        .expect("an alert");
    assert_eq!(shown.heading().as_deref(), Some("Delete “Fake”?"));
    assert_eq!(
        alert_dialogs(&test.window),
        std::slice::from_ref(&shown),
        "the delete asked twice"
    );

    respond(&shown, delete_connection_dialog::CANCEL);
    wait_until(WAIT, || test.window.visible_dialog().is_none()).expect("the dialog to close");
    drain_main_context();
    assert!(
        test.services.saved_connections.get(test.saved.id).is_some(),
        "Cancel deleted"
    );
    assert!(alert_dialogs(&test.window).is_empty());
}

#[gtk4::test]
fn activating_a_row_connects_to_its_connection() {
    let test = TestWindow::picker("PickerActivate");
    let row = picker_row(&test.window, "Fake");
    let list = row
        .ancestor(gtk::ListView::static_type())
        .and_downcast::<gtk::ListView>()
        .expect("the row's list");
    let position = row.list_item().expect("the row's list item").position();

    list.activate_action("list.activate-item", Some(&position.to_variant()))
        .expect("list.activate-item");

    wait_until(WAIT, || !test.connector.calls().is_empty()).expect("the connect");
    assert_eq!(test.connector.calls()[0].request.metadata.id, test.saved.id);
}

#[gtk4::test]
fn activating_a_group_row_folds_and_opens_it() {
    let test = TestWindow::picker("PickerFold");
    let work = test
        .services
        .storage
        .connections()
        .create_group_blocking(group("Work"))
        .expect("the group");
    test.services
        .storage
        .connections()
        .move_connections_blocking(&[test.saved.id], Some(work.id), None)
        .expect("the move");
    let row = picker_row(&test.window, "Work");
    picker_row(&test.window, "Fake");
    let view = picker_view(&test.window);
    let list = row
        .ancestor(gtk::ListView::static_type())
        .and_downcast::<gtk::ListView>()
        .expect("the row's list");
    let position = row.list_item().expect("the row's list item").position();

    list.activate_action("list.activate-item", Some(&position.to_variant()))
        .expect("list.activate-item");
    assert_eq!(view.sections(), [section("Connections", &["Work"])]);
    list.activate_action("list.activate-item", Some(&position.to_variant()))
        .expect("list.activate-item");

    assert_eq!(view.sections(), [section("Connections", &["Work", "  Fake"])]);
    assert!(test.connector.calls().is_empty(), "a group's row connected");
}

#[gtk4::test]
fn invalid_action_target_is_ignored() {
    let test = TestWindow::picker("PickerInvalid");
    let row = picker_row(&test.window, "Fake");

    for target in ["not an id".to_owned(), Uuid::new_v4().to_string()] {
        row.activate_action("picker.delete", Some(&target.to_variant()))
            .expect("picker.delete");
        row.activate_action("picker.connect", Some(&target.to_variant()))
            .expect("picker.connect");
    }
    drain_main_context();

    assert!(
        test.window.visible_dialog().is_none(),
        "a target that names nothing asked"
    );
    assert_eq!(test.window.page_name(), "picker");
    assert!(
        test.connector.calls().is_empty(),
        "a target that names nothing connected"
    );
}

#[gtk4::test]
fn row_menu_key_opens_menu() {
    let test = TestWindow::picker("PickerRowMenu");
    let row = picker_row(&test.window, "Fake");
    let button = row.menu_button();

    expander(&row)
        .activate_action("picker-row.menu", None)
        .expect("picker-row.menu");

    wait_until(WAIT, || button.popover().is_some_and(|popover| popover.is_visible())).expect("the row's menu to open");
    assert_eq!(button.tooltip_text().as_deref(), Some("Connection Options"));
    button.popdown();
}

#[gtk4::test]
fn the_menu_keys_reach_the_row_menu_action() {
    let test = TestWindow::picker("PickerRowKeys");
    let row = picker_row(&test.window, "Fake");

    let bound = crate::test_support::shortcut_keys::owner_controller(
        &expander(&row),
        crate::application::ShortcutOwner::PickerRow,
    )
    .expect("the row's keys");
    let actions: Vec<String> = crate::test_support::shortcut_keys::shortcuts(&bound)
        .into_iter()
        .filter_map(|shortcut| shortcut.action().and_downcast::<gtk::NamedAction>())
        .map(|action| action.action_name().to_string())
        .collect();

    assert_eq!(actions, ["picker-row.menu", "picker-row.menu"]);
}

#[gtk4::test]
fn a_colour_picked_from_the_row_reaches_the_store() {
    let test = TestWindow::picker("PickerColour");
    let button = open_menu(&picker_row(&test.window, "Fake"));

    button
        .activate_action("picker-row.color", Some(&"red".to_variant()))
        .expect("picker-row.color");

    wait_until(WAIT, || {
        test.services
            .saved_connections
            .get(test.saved.id)
            .is_some_and(|saved| saved.color == Some(tablepro_storage::ConnectionColor::Red))
    })
    .expect("the colour saved and shown");
    button.popdown();
}

#[gtk4::test]
fn move_up_from_a_rows_menu_reaches_the_store() {
    let test = TestWindow::picker("PickerMoveUp");
    let second = connection("Second", None);
    test.services
        .storage
        .connections()
        .upsert_blocking(second.clone())
        .expect("the save");
    let button = open_menu(&picker_row(&test.window, "Second"));

    button
        .activate_action("picker-row.move-up", None)
        .expect("picker-row.move-up");

    let wanted = [
        LibraryItem::Connection(second.id),
        LibraryItem::Connection(test.saved.id),
    ];
    wait_until(WAIT, || {
        test.services.saved_connections.outline().children(None) == wanted
    })
    .expect("Second above Fake in the store");
    button.popdown();
}

#[gtk4::test]
fn a_drop_through_change_library_reaches_the_store() {
    let test = TestWindow::picker("PickerChangeLibrary");
    let work = test
        .services
        .storage
        .connections()
        .create_group_blocking(group("Work"))
        .expect("the group");
    picker_row(&test.window, "Work");
    let change = LibraryMove::Connections {
        ids: vec![test.saved.id],
        group: Some(work.id),
        before: None,
    };

    picker_view(&test.window)
        .activate_action("picker.change-library", Some(&change.to_variant()))
        .expect("picker.change-library");

    wait_until(WAIT, || {
        test.services
            .saved_connections
            .get(test.saved.id)
            .is_some_and(|saved| saved.group_id == Some(work.id))
    })
    .expect("the connection filed in the group");
}

#[gtk4::test]
fn a_connection_dropped_in_the_middle_of_a_group_row_moves_into_it() {
    let test = TestWindow::picker("PickerDropOnGroup");
    let work = test
        .services
        .storage
        .connections()
        .create_group_blocking(group("Work"))
        .expect("the group");
    let row = picker_row(&test.window, "Work");
    let expander = expander(&row);
    let controllers = expander.observe_controllers();
    let target = (0..controllers.n_items())
        .find_map(|at| controllers.item(at).and_downcast::<gtk::DropTarget>())
        .expect("the row's drop target");
    let dragged = LibraryDragItem::new((LibrarySection::Tree, LibraryItem::Connection(test.saved.id)));
    test.window.present();
    wait_until(WAIT, || expander.height() > 0).expect("the row laid out");
    let middle = f64::from(expander.height()) / 2.0;

    let dropped = target.emit_by_name::<bool>("drop", &[&glib::BoxedValue(dragged.to_value()), &0.0_f64, &middle]);

    assert!(dropped, "the group's row refused the connection");
    wait_until(WAIT, || {
        test.services
            .saved_connections
            .get(test.saved.id)
            .is_some_and(|saved| saved.group_id == Some(work.id))
    })
    .expect("the connection filed in the group");
}

#[gtk4::test]
fn unreadable_list_reveals_banner() {
    let test = TestWindow::with_script(
        "PickerUnreadable",
        Script {
            unreadable_list: true,
            ..Script::default()
        },
    );
    let banner = test.window.connection_list_banner().expect("the picker's banner");

    wait_until(WAIT, || banner.is_revealed()).expect("the banner");
    assert_eq!(banner.title(), "Saved connections could not be read");
}

fn connect_dialog(window: &SessionWindow) -> crate::ui::connect_dialog::ConnectDialog {
    let mut shown = None;
    wait_until(WAIT, || {
        shown = window
            .visible_dialog()
            .and_downcast::<crate::ui::connect_dialog::ConnectDialog>();
        shown.is_some()
    })
    .expect("the connect dialog");
    shown.expect("the dialog")
}

#[gtk4::test]
fn edit_opens_the_connect_dialog_on_the_saved_connection() {
    let test = TestWindow::picker("PickerEdit");
    let row = picker_row(&test.window, "Fake");

    row.activate_action("picker.edit", Some(&test.saved.id.to_string().to_variant()))
        .expect("picker.edit");

    let dialog = connect_dialog(&test.window);
    assert_eq!(dialog.editing().map(|saved| saved.id), Some(test.saved.id));
    assert_eq!(dialog.title(), "Edit Connection");
    dialog.close();
}

#[gtk4::test]
fn duplicate_focuses_the_new_row() {
    let test = TestWindow::picker("PickerDuplicate");
    let row = picker_row(&test.window, "Fake");

    row.activate_action("picker.duplicate", Some(&test.saved.id.to_string().to_variant()))
        .expect("picker.duplicate");

    picker_row(&test.window, "Fake (Copy)");
    // The focus widget of its window, which may not be the active one while other tests run.
    wait_until(WAIT, || focused_title(&test.window).as_deref() == Some("Fake (Copy)"))
        .expect("the copy to take the focus");
    assert_eq!(test.services.saved_connections.connections().len(), 2);
}

#[gtk4::test]
fn a_group_picked_from_the_row_reaches_the_store() {
    let test = TestWindow::picker("PickerGroup");
    let work = test
        .services
        .storage
        .connections()
        .create_group_blocking(group("Work"))
        .expect("the group");
    picker_row(&test.window, "Work");
    let button = open_menu(&picker_row(&test.window, "Fake"));

    button
        .activate_action("picker-row.group", Some(&work.id.to_string().to_variant()))
        .expect("picker-row.group");

    wait_until(WAIT, || {
        test.services
            .saved_connections
            .get(test.saved.id)
            .is_some_and(|saved| saved.group_id == Some(work.id))
    })
    .expect("the group saved and shown");
    button.popdown();
    let button = open_menu(&picker_row(&test.window, "Fake"));
    for unknown in ["   ", "Work"] {
        button
            .activate_action("picker-row.group", Some(&unknown.to_variant()))
            .expect("picker-row.group");
    }
    drain_main_context();
    assert!(
        test.services
            .saved_connections
            .get(test.saved.id)
            .is_some_and(|saved| saved.group_id == Some(work.id)),
        "a target that names no group took the connection out of its group"
    );
    button.popdown();
}

fn tag(name: &str) -> tablepro_storage::ConnectionTag {
    tablepro_storage::ConnectionTag::new(
        tablepro_storage::ConnectionTagName::new(name).expect("a tag name"),
        tablepro_storage::ConnectionColor::Red,
    )
}

fn tagged(name: &str, group: Option<&str>, tags: &[&tablepro_storage::ConnectionTag]) -> SavedConnection {
    SavedConnection {
        tags: tags.iter().map(|tag| tag.id).collect(),
        ..connection(name, group)
    }
}

// The issue's "Done means": both tags show, and a search for one lists every connection that has it.
#[gtk4::test]
fn a_search_for_a_tag_lists_every_connection_that_has_it() {
    let pickers = Pickers::new();
    let (acme, production) = (tag("acme"), tag("production"));
    pickers
        .list
        .apply(ConnectionListState::Ready(crate::test_support::library(
            vec![
                tagged("acme-prod", Some("Acme"), &[&production, &acme]),
                tagged("acme-dev", Some("Acme"), &[&acme]),
                tagged("globex-prod", Some("Globex"), &[&production]),
                tagged("scratch", None, &[]),
            ],
            vec![production.clone(), acme.clone()],
        )));
    let view = &pickers.views[0];
    assert_eq!(tag_names(view, "acme-prod"), ["acme", "production"]);

    view.set_search("production");

    assert_eq!(view.sections(), [section("", &["acme-prod", "globex-prod"])]);
    let everything = section(
        "Connections",
        &[
            "Acme",
            "  acme-prod",
            "  acme-dev",
            "Globex",
            "  globex-prod",
            "scratch",
        ],
    );
    assert_eq!(
        pickers.views[1].sections(),
        std::slice::from_ref(&everything),
        "a search in one window filtered another"
    );
    view.set_search("");
    assert_eq!(view.sections(), [everything]);
}

#[gtk4::test]
fn a_search_finds_a_connection_by_a_word_of_its_group_path_and_shows_the_path() {
    let pickers = Pickers::new();
    let mut library = NestedLibrary::default();
    let work = library.group("Work", None);
    let staging = library.group("Staging", Some(work));
    library.connection("api", Some(staging));
    library.connection("web", None);
    pickers.show(library.list());
    let view = &pickers.views[0];

    view.set_search("staging");

    assert_eq!(view.visible_page().as_deref(), Some("found"));
    assert_eq!(view.sections(), [section("", &["api"])]);
    let found = view.found_node("api").expect("the found row");
    assert!(found.subtitle().ends_with(" · Work / Staging"), "{}", found.subtitle());
    view.set_search("work api");
    assert_eq!(rows(&view.sections()), ["api"]);
}

#[gtk4::test]
fn a_search_that_matches_nothing_says_so() {
    let pickers = Pickers::new();
    pickers.list.apply(ready([connection("Corp", None)]));
    let view = &pickers.views[0];

    view.set_search("nothing-like-it");
    assert_eq!(view.visible_page().as_deref(), Some("no-results"));
    assert!(view.sections().is_empty());

    pickers
        .list
        .apply(ready([connection("Corp", None), connection("nothing-like-it", None)]));
    assert_eq!(view.visible_page().as_deref(), Some("found"));
    assert_eq!(rows(&view.sections()), ["nothing-like-it"]);
}

#[gtk4::test]
fn a_renamed_tag_reaches_every_row_and_the_search() {
    let pickers = Pickers::new();
    let production = pickers
        .store
        .create_tag_blocking(
            tablepro_storage::ConnectionTagName::new("production").expect("a tag name"),
            tablepro_storage::ConnectionColor::Red,
        )
        .expect("the tag");
    let corp = tagged("Corp", None, &[&production]);
    pickers.write(move |store| store.upsert_blocking(corp).expect("the save"));
    wait_until(WAIT, || {
        pickers
            .views
            .iter()
            .all(|view| view.node(LibrarySection::Tree, "Corp").is_some() && tag_names(view, "Corp") == ["production"])
    })
    .expect("the tag on every row");

    pickers.write(move |store| {
        store
            .update_tag_blocking(tablepro_storage::ConnectionTag {
                name: tablepro_storage::ConnectionTagName::new("prod").expect("a tag name"),
                ..production
            })
            .expect("the rename");
    });

    wait_until(WAIT, || {
        pickers.views.iter().all(|view| tag_names(view, "Corp") == ["prod"])
    })
    .expect("the new name on every row");
    pickers.views[0].set_search("prod");
    assert_eq!(rows(&pickers.views[0].sections()), ["Corp"]);
}

#[gtk4::test]
fn enter_in_the_search_connects_to_the_first_match() {
    let test = TestWindow::picker("PickerSearchEnter");
    let store = test.services.storage.connections();
    // A favourite leads the list, so Enter before the search applies would pick it.
    let aardvark = connection("Aardvark", None);
    store.upsert_blocking(aardvark.clone()).expect("the save");
    store
        .add_favorites_blocking(&[aardvark.id], None)
        .expect("the favourite");
    picker_row_in(&test.window, LibrarySection::Favourites, "Aardvark");
    let (bar, entry) = test.window.picker_search().expect("the picker's search");

    bar.set_search_mode(true);
    entry.set_text("fake");
    entry.emit_activate();

    wait_until(WAIT, || !test.connector.calls().is_empty()).expect("the connect");
    assert_eq!(test.connector.calls()[0].request.metadata.id, test.saved.id);
}

#[gtk4::test]
fn enter_with_no_search_skips_a_connection_in_a_folded_group() {
    let test = TestWindow::picker("PickerEnterFolded");
    let store = test.services.storage.connections();
    crate::test_support::save_filed(store, connection("Hidden", Some("Work")));
    picker_row(&test.window, "Hidden");
    let work = picker_row(&test.window, "Work");
    expander(&work)
        .activate_action("listitem.collapse", None)
        .expect("the group folds");
    let (_, entry) = test.window.picker_search().expect("the picker's search");

    entry.emit_activate();

    wait_until(WAIT, || !test.connector.calls().is_empty()).expect("the connect");
    assert_eq!(test.connector.calls()[0].request.metadata.id, test.saved.id);
}

#[gtk4::test]
fn the_keyboard_lands_on_the_row_not_its_menu_button() {
    let test = TestWindow::picker("PickerRowFocus");
    test.window.present();
    let row = picker_row(&test.window, "Fake");
    let expander = expander(&row);
    wait_until(WAIT, || expander.height() > 0).expect("the row laid out");

    expander.grab_focus();

    assert!(expander.has_focus(), "the focus went inside the row");
}

#[gtk4::test]
fn closing_the_search_shows_every_connection_again() {
    let test = TestWindow::picker("PickerSearchClose");
    picker_row(&test.window, "Fake");
    let (bar, entry) = test.window.picker_search().expect("the picker's search");
    bar.set_search_mode(true);
    entry.set_text("nothing-like-it");

    bar.set_search_mode(false);

    assert_eq!(entry.text(), "");
    picker_row(&test.window, "Fake");
}

#[gtk4::test]
fn ctrl_f_belongs_to_the_picker_page() {
    let test = TestWindow::picker("PickerSearchKeys");
    let (bar, entry) = test.window.picker_search().expect("the picker's search");
    let page = bar
        .ancestor(crate::ui::session_window::PickerPage::static_type())
        .expect("the picker page");

    let bound =
        crate::test_support::shortcut_keys::owner_controller(&page, crate::application::ShortcutOwner::PickerPage)
            .expect("the page's keys");
    let actions: Vec<String> = crate::test_support::shortcut_keys::shortcuts(&bound)
        .into_iter()
        .filter_map(|shortcut| shortcut.action().and_downcast::<gtk::NamedAction>())
        .map(|action| action.action_name().to_string())
        .collect();
    assert_eq!(actions, ["picker-page.search"]);

    page.activate_action("picker-page.search", None)
        .expect("picker-page.search");
    assert!(bar.is_search_mode());
    drop(entry);
}

#[gtk4::test]
fn a_tag_ticked_in_the_row_menu_reaches_the_store_and_the_row() {
    let test = TestWindow::picker("PickerTag");
    let store = test.services.storage.connections().clone();
    let production = store
        .create_tag_blocking(
            tablepro_storage::ConnectionTagName::new("production").expect("a tag name"),
            tablepro_storage::ConnectionColor::Red,
        )
        .expect("the tag");
    let action = format!("picker-row.tag-{}", production.id);
    wait_until(WAIT, || {
        test.services
            .saved_connections
            .tags()
            .iter()
            .any(|held| held.id == production.id)
    })
    .expect("the tag in the list");
    let button = open_menu(&picker_row(&test.window, "Fake"));

    button.activate_action(&action, None).expect(&action);

    wait_until(WAIT, || {
        test.services
            .saved_connections
            .get(test.saved.id)
            .is_some_and(|saved| saved.tags == [production.id])
    })
    .expect("the tag saved");
    let view = picker_view(&test.window);
    wait_until(WAIT, || tag_names(&view, "Fake") == ["production"]).expect("the tag on the row");
    button.popdown();
}

#[gtk4::test]
fn manage_tags_opens_once_per_window_and_deletes_a_tag_from_every_connection() {
    let test = TestWindow::picker("PickerManageTags");
    let store = test.services.storage.connections().clone();
    let production = store
        .create_tag_blocking(
            tablepro_storage::ConnectionTagName::new("production").expect("a tag name"),
            tablepro_storage::ConnectionColor::Red,
        )
        .expect("the tag");
    store
        .update_blocking(test.saved.id, |entry| entry.tags = vec![production.id])
        .expect("the update");
    picker_row(&test.window, "Fake");

    gtk::prelude::WidgetExt::activate_action(&test.window, "win.manage-tags", None).expect("win.manage-tags");
    wait_until(WAIT, || test.window.manage_tags().is_some()).expect("the dialog");
    let manage = test.window.manage_tags().expect("the dialog");
    wait_until(WAIT, || {
        manage.rows() == [("production".to_owned(), "1 connection".to_owned())]
    })
    .expect("the tag's row");
    gtk::prelude::WidgetExt::activate_action(&test.window, "win.manage-tags", None).expect("win.manage-tags");
    drain_main_context();
    assert!(
        std::rc::Rc::ptr_eq(&manage, &test.window.manage_tags().expect("the dialog")),
        "a second ask opened a second dialog"
    );

    test.window
        .send(crate::ui::SessionWindowInput::DeleteTag(production.id));

    wait_until(WAIT, || manage.rows().is_empty()).expect("the row to go");
    assert!(
        test.services
            .saved_connections
            .get(test.saved.id)
            .is_some_and(|saved| saved.tags.is_empty())
    );
}
