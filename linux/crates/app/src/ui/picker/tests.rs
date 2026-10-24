use std::rc::Rc;
use std::time::Duration;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_storage::{ConnectionListState, ConnectionStore, SavedConnection, StoragePaths};
use uuid::Uuid;

use crate::runtime::AppRuntime;
use crate::services::saved_connection_list::SavedConnectionList;
use crate::test_support::{descendants, drain_main_context, respond, test_runtime, wait_until};
use crate::ui::delete_connection_dialog;
use crate::ui::session_window::SessionWindow;
use crate::ui::session_window::tests::{Script, TestWindow};
use crate::ui::welcome_view::WelcomeView;

const WAIT: Duration = Duration::from_secs(10);

fn connection(name: &str, group: Option<&str>) -> SavedConnection {
    SavedConnection {
        id: Uuid::new_v4(),
        name: name.to_owned(),
        driver_id: "postgres".to_owned(),
        host: "db".to_owned(),
        port: 5432,
        database: "app".to_owned(),
        username: "postgres".to_owned(),
        tls: tablepro_core::TlsConfig::verify_full(),
        safe_mode: tablepro_core::SafeModeLevel::Off,
        external_access: tablepro_core::ExternalAccess::ReadOnly,
        ai_policy: tablepro_core::AiPolicy::Ask,
        auth_mode: tablepro_core::AuthMode::Password,
        ssh: None,
        last_opened_at: None,
        color: None,
        group: group.map(|group| tablepro_storage::ConnectionGroupName::new(group).expect("a group name")),
        tags: Vec::new(),
        icon: None,
        options: Default::default(),
    }
}

/// One connection store, the list that follows it, and two pickers on
/// that list, as two windows have.
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

    /// Write as the connect dialog and a connect do: off the GTK thread.
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
    ConnectionListState::Ready(tablepro_storage::ConnectionList::new(
        Vec::from(connections),
        Vec::new(),
    ))
}

fn rows(sections: &[(String, Vec<String>)]) -> Vec<String> {
    sections.iter().flat_map(|(_, rows)| rows.clone()).collect()
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
fn successful_connect_stamp_reorders_every_picker() {
    let pickers = Pickers::new();
    let (first, second) = (connection("Alpha", None), connection("Beta", None));
    let stamped = second.id;
    pickers.write(move |store| {
        store.upsert_blocking(first).expect("the save");
        store.upsert_blocking(second).expect("the save");
    });
    wait_until(WAIT, || {
        pickers.every_picker(|sections| rows(sections) == ["Alpha", "Beta"])
    })
    .expect("both connections, by name");

    pickers.write(move |store| store.touch_last_opened_blocking(stamped).expect("the stamp"));

    wait_until(WAIT, || {
        pickers.every_picker(|sections| rows(sections) == ["Beta", "Alpha"])
    })
    .expect("the connection opened last to lead every picker");
}

#[gtk4::test]
fn picker_renders_one_group_per_section() {
    let pickers = Pickers::new();
    let (loose, a, b, c) = (
        connection("loose", None),
        connection("a", Some("Work")),
        connection("b", Some("Work")),
        connection("c", Some("R&D")),
    );
    pickers.list.apply(ready([loose, a.clone(), b, c]));

    let view = &pickers.views[0];
    assert_eq!(
        view.sections(),
        [
            ("Connections".to_owned(), vec!["loose".to_owned()]),
            ("R&amp;D".to_owned(), vec!["c".to_owned()]),
            ("Work".to_owned(), vec!["a".to_owned(), "b".to_owned()]),
        ]
    );

    pickers.list.apply(ready([a, connection("d", None)]));

    assert_eq!(
        view.sections(),
        [
            ("Connections".to_owned(), vec!["d".to_owned()]),
            ("Work".to_owned(), vec!["a".to_owned()]),
        ],
        "a group with no connection left kept its section"
    );
    pickers.list.apply(ready([connection("e", Some("Work"))]));
    assert_eq!(
        view.sections(),
        [("Work".to_owned(), vec!["e".to_owned()])],
        "an empty ungrouped section stayed"
    );
    pickers.list.apply(ready([connection("f", None)]));
    assert_eq!(
        view.sections(),
        [("Saved Connections".to_owned(), vec!["f".to_owned()])],
        "with no group left the list is not one section among others"
    );
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
fn a_name_is_shown_as_text_not_markup() {
    let pickers = Pickers::new();
    pickers.list.apply(ready([connection("R&D <prod>", None)]));

    let row = descendants(&pickers.views[0])
        .into_iter()
        .find_map(|widget| widget.downcast::<adw::ActionRow>().ok())
        .expect("the row");

    assert!(!row.uses_markup());
    assert_eq!(row.title(), "R&D <prod>");
}

fn picker_row(window: &SessionWindow, name: &str) -> adw::ActionRow {
    let mut found = None;
    wait_until(WAIT, || {
        found = descendants(window)
            .into_iter()
            .filter_map(|widget| widget.downcast::<adw::ActionRow>().ok())
            .find(|row| row.title() == name);
        found.is_some()
    })
    .expect("the connection's row");
    found.expect("the row")
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

    WidgetExt::activate(&row);

    wait_until(WAIT, || !test.connector.calls().is_empty()).expect("the connect");
    assert_eq!(test.connector.calls()[0].request.metadata.id, test.saved.id);
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
    let button = descendants(&row)
        .into_iter()
        .find_map(|widget| widget.downcast::<gtk::MenuButton>().ok())
        .expect("the row's menu button");

    row.activate_action("picker-row.menu", None).expect("picker-row.menu");

    wait_until(WAIT, || button.popover().is_some_and(|popover| popover.is_visible())).expect("the row's menu to open");
    assert_eq!(button.tooltip_text().as_deref(), Some("Connection Options"));
    button.popdown();
}

#[gtk4::test]
fn the_menu_keys_reach_the_row_menu_action() {
    let test = TestWindow::picker("PickerRowKeys");
    let row = picker_row(&test.window, "Fake");

    let bound =
        crate::test_support::shortcut_keys::owner_controller(&row, crate::application::ShortcutOwner::PickerRow)
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
    let row = picker_row(&test.window, "Fake");

    row.activate_action("picker-row.color", Some(&"red".to_variant()))
        .expect("picker-row.color");

    wait_until(WAIT, || {
        test.services
            .saved_connections
            .get(test.saved.id)
            .is_some_and(|saved| saved.color == Some(tablepro_storage::ConnectionColor::Red))
    })
    .expect("the colour saved and shown");
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

    let copy = picker_row(&test.window, "Fake (Copy)");
    // The focus widget of its window, which may not be the active one
    // while other tests run.
    wait_until(WAIT, || copy.is_focus()).expect("the copy to take the focus");
    assert_eq!(test.services.saved_connections.connections().len(), 2);
}

#[gtk4::test]
fn a_group_picked_from_the_row_reaches_the_store() {
    let test = TestWindow::picker("PickerGroup");
    let row = picker_row(&test.window, "Fake");

    row.activate_action("picker-row.group", Some(&"Work".to_variant()))
        .expect("picker-row.group");

    wait_until(WAIT, || {
        test.services
            .saved_connections
            .get(test.saved.id)
            .is_some_and(|saved| saved.group.as_ref().is_some_and(|group| group.as_str() == "Work"))
    })
    .expect("the group saved and shown");
    let row = picker_row(&test.window, "Fake");
    row.activate_action("picker-row.group", Some(&"   ".to_variant()))
        .expect("picker-row.group");
    drain_main_context();
    assert!(
        test.services
            .saved_connections
            .get(test.saved.id)
            .is_some_and(|saved| saved.group.is_some()),
        "a blank group took the connection out of its group"
    );
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

fn pills(view: &WelcomeView, row_title: &str) -> Vec<String> {
    let row = descendants(view)
        .into_iter()
        .filter_map(|widget| widget.downcast::<adw::ActionRow>().ok())
        .find(|row| row.title() == row_title)
        .unwrap_or_else(|| panic!("no row for {row_title}"));
    descendants(&row)
        .into_iter()
        .filter(|widget| widget.has_css_class("tp-tag-pill"))
        .filter_map(|widget| widget.downcast::<gtk::Label>().ok())
        .map(|label| label.label().to_string())
        .collect()
}

/// The issue's "Done means": both tags show, and a search for one lists
/// every connection that has it, in every group.
#[gtk4::test]
fn a_search_for_a_tag_lists_every_connection_that_has_it() {
    let pickers = Pickers::new();
    let (acme, production) = (tag("acme"), tag("production"));
    pickers
        .list
        .apply(ConnectionListState::Ready(tablepro_storage::ConnectionList::new(
            vec![
                tagged("acme-prod", Some("Acme"), &[&production, &acme]),
                tagged("acme-dev", Some("Acme"), &[&acme]),
                tagged("globex-prod", Some("Globex"), &[&production]),
                tagged("scratch", None, &[]),
            ],
            vec![production.clone(), acme.clone()],
        )));
    let view = &pickers.views[0];
    assert_eq!(pills(view, "acme-prod"), ["acme", "production"]);

    view.set_search("production");

    assert_eq!(
        view.sections(),
        [
            ("Acme".to_owned(), vec!["acme-prod".to_owned()]),
            ("Globex".to_owned(), vec!["globex-prod".to_owned()]),
        ]
    );
    assert_eq!(
        rows(&pickers.views[1].sections()).len(),
        4,
        "a search in one window filtered another"
    );
    view.set_search("");
    assert_eq!(rows(&view.sections()).len(), 4);
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
    assert_eq!(view.visible_page().as_deref(), Some("list"));
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
        pickers.views.iter().all(|view| pills(view, "Corp") == ["production"])
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
        pickers.views.iter().all(|view| pills(view, "Corp") == ["prod"])
    })
    .expect("the new name on every row");
    pickers.views[0].set_search("prod");
    assert_eq!(rows(&pickers.views[0].sections()), ["Corp"]);
}

#[gtk4::test]
fn enter_in_the_search_connects_to_the_first_match() {
    let test = TestWindow::picker("PickerSearchEnter");
    // Sorts first, so Enter before the search applies would pick it.
    test.services
        .storage
        .connections()
        .upsert_blocking(connection("Aardvark", None))
        .expect("the save");
    picker_row(&test.window, "Aardvark");
    let (bar, entry) = test.window.picker_search().expect("the picker's search");

    bar.set_search_mode(true);
    entry.set_text("fake");
    entry.emit_activate();

    wait_until(WAIT, || !test.connector.calls().is_empty()).expect("the connect");
    assert_eq!(test.connector.calls()[0].request.metadata.id, test.saved.id);
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
    let mut row = picker_row(&test.window, "Fake");
    wait_until(WAIT, || {
        row = picker_row(&test.window, "Fake");
        row.activate_action(&action, None).is_ok()
    })
    .expect("the row's tag action");

    wait_until(WAIT, || {
        test.services
            .saved_connections
            .get(test.saved.id)
            .is_some_and(|saved| saved.tags == [production.id])
    })
    .expect("the tag saved");
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
