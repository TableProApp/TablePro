use std::cell::RefCell;
use std::rc::Rc;
use std::time::Duration;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gdk, gio, glib};
use libadwaita as adw;
use tablepro_core::DriverError;
use tablepro_core::meta::{ObjectInfo, ObjectKind, SchemaInfo, TableRef};
use tablepro_test_support::FakeReply;

use super::object_key::ObjectKey;
use super::sidebar_event::SidebarEvent;
use super::*;
use crate::test_support::{descendants, drain_main_context, wait_until};
use crate::ui::session_window::tests::{TestWindow, WAIT};
use crate::ui::workspace::WorkspaceTab;
use crate::ui::workspace::tab_spec::{TabSpec, TablePage};

type Events = Rc<RefCell<Vec<SidebarEvent>>>;

fn object(schema: &str, name: &str) -> ObjectInfo {
    ObjectInfo {
        schema: Some(schema.to_owned()),
        name: name.to_owned(),
        kind: ObjectKind::Table,
    }
}

fn public() -> [SchemaInfo; 1] {
    [SchemaInfo {
        name: "public".to_owned(),
        is_default: true,
        is_system: false,
    }]
}

fn table(name: &str) -> TableRef {
    TableRef::new(Some("public".to_owned()), name)
}

fn every_affordance() -> SidebarAffordances {
    SidebarAffordances {
        read_only: false,
        can_create_table: true,
        can_edit_structure: true,
    }
}

/// A sidebar in a window of its own, with what it sent.
struct Shown {
    view: SidebarView,
    events: Events,
    window: gtk::Window,
}

impl Shown {
    fn new(names: &[&str], affordances: SidebarAffordances) -> Self {
        adw::init().expect("libadwaita initialises under the test backend");
        let events = Events::default();
        let sink = events.clone();
        let view = SidebarView::new(move |event| sink.borrow_mut().push(event), affordances);
        let objects: Vec<ObjectInfo> = names.iter().map(|name| object("public", name)).collect();
        view.apply_objects(&objects, &public());
        let window = gtk::Window::new();
        window.set_default_size(300, 400);
        window.set_child(Some(view.widget()));
        window.present();
        drain_main_context();
        Self { view, events, window }
    }

    fn list_view(&self) -> gtk::ListView {
        self.view.inner().list_view.clone()
    }

    fn selection(&self) -> gtk::SingleSelection {
        self.list_view()
            .model()
            .and_downcast::<gtk::SingleSelection>()
            .expect("a single selection")
    }

    fn popover(&self) -> gtk::PopoverMenu {
        self.view.inner().popover.clone()
    }

    fn taken(&self) -> Vec<SidebarEvent> {
        self.events.take()
    }
}

impl Drop for Shown {
    fn drop(&mut self) {
        self.view.shutdown();
        self.window.destroy();
        drain_main_context();
    }
}

/// Each menu item's action and target, sections flattened.
fn menu_items(menu: &gio::MenuModel) -> Vec<(String, Option<glib::Variant>)> {
    let mut found = Vec::new();
    for index in 0..menu.n_items() {
        if let Some(action) = menu
            .item_attribute_value(index, "action", None)
            .and_then(|value| value.get::<String>())
        {
            found.push((action, menu.item_attribute_value(index, "target", None)));
        }
        if let Some(section) = menu.item_link(index, "section") {
            found.extend(menu_items(&section));
        }
    }
    found
}

fn names(count: usize) -> Vec<String> {
    (0..count).map(|index| format!("t{index:05}")).collect()
}

#[gtk4::test]
fn empty_filter_shows_placeholder() {
    let shown = Shown::new(&["orders", "users"], every_affordance());
    let stack = shown.view.widget().clone();
    let status = || {
        stack.visible_child().and_downcast::<adw::StatusPage>().map(|page| {
            (
                page.title().to_string(),
                page.description()
                    .filter(|text| !text.is_empty())
                    .map(|text| text.to_string()),
            )
        })
    };
    assert_eq!(status(), None, "a list with rows shows its placeholder");

    shown.view.set_query("nothing like it");
    assert_eq!(
        status(),
        Some((
            "No Matching Tables".to_owned(),
            Some("Try a different search.".to_owned())
        ))
    );

    shown.view.set_query("");
    shown.view.apply_objects(&[], &public());
    assert_eq!(status(), Some(("No Tables".to_owned(), None)));
}

#[gtk4::test]
fn rows_are_recycled_for_large_catalogs() {
    let owned = names(10_000);
    let borrowed: Vec<&str> = owned.iter().map(String::as_str).collect();
    let shown = Shown::new(&borrowed, every_affordance());
    wait_until(WAIT, || shown.list_view().height() > 0).expect("the list laid out");
    drain_main_context();

    let labels = descendants(&shown.list_view())
        .into_iter()
        .filter(|widget| widget.is::<gtk::Label>())
        .count();

    assert!(labels > 0, "no row was built at all");
    // GtkListView keeps about 200 rows around its viewport, whatever the
    // model holds, and the section header adds a label.
    assert!(labels <= 210, "{labels} labels for 10,000 tables");
}

#[gtk4::test]
fn single_click_activation_opens_table() {
    let shown = Shown::new(&["a", "b", "c", "d", "e"], every_affordance());

    assert!(shown.list_view().is_single_click_activate());
    shown.list_view().emit_by_name::<()>("activate", &[&3u32]);

    assert_eq!(shown.taken(), [SidebarEvent::Open(table("d"))]);
}

#[gtk4::test]
fn secondary_press_selects_row_and_opens_menu() {
    let shown = Shown::new(&["a", "b", "c", "d", "e", "f", "g"], every_affordance());

    let claimed = shown
        .view
        .inner()
        .pressed(5, gdk::BUTTON_SECONDARY, gdk::ModifierType::empty(), None);

    assert!(claimed, "the row's own click would also run");
    assert_eq!(shown.selection().selected(), 5);
    let popover = shown.popover();
    assert!(popover.is_visible(), "the menu did not open");
    let model = popover.menu_model().expect("a menu model");
    let targets: Vec<Option<ObjectKey>> = menu_items(&model)
        .into_iter()
        .map(|(_, target)| target.as_ref().and_then(ObjectKey::from_variant))
        .collect();
    assert!(
        targets.iter().all(|key| key.as_ref() == Some(&ObjectKey(table("f")))),
        "{targets:?}"
    );
    popover.popdown();
    assert!(shown.taken().is_empty(), "opening the menu opened the table");
}

#[gtk4::test]
fn ctrl_click_and_middle_click_open_a_new_tab() {
    let shown = Shown::new(&["a", "b", "c"], every_affordance());
    let inner = shown.view.inner().clone();

    assert!(inner.pressed(1, gdk::BUTTON_PRIMARY, gdk::ModifierType::CONTROL_MASK, None));
    assert!(!inner.pressed(1, gdk::BUTTON_PRIMARY, gdk::ModifierType::empty(), None));
    assert!(inner.released(2, gdk::BUTTON_MIDDLE));

    assert_eq!(
        shown.taken(),
        [
            SidebarEvent::OpenInNewTab(table("b")),
            SidebarEvent::OpenInNewTab(table("c"))
        ]
    );
}

#[gtk4::test]
fn context_menu_action_carries_object_key() {
    let shown = Shown::new(&["orders", "users"], every_affordance());
    let list_view = shown.list_view();
    let key = ObjectKey(table("users")).to_variant();

    for action in [
        "sidebar.open-in-new-tab",
        "sidebar.edit-structure",
        "sidebar.show-create-table",
        "sidebar.import-csv",
        "sidebar.drop-table",
    ] {
        list_view.activate_action(action, Some(&key)).expect(action);
    }
    list_view
        .activate_action(
            "sidebar.drop-table",
            Some(&(None::<String>, String::new()).to_variant()),
        )
        .expect("the action");
    list_view
        .activate_action("sidebar.drop-table", Some(&ObjectKey(table("gone")).to_variant()))
        .expect("the action");

    assert_eq!(
        shown.taken(),
        [
            SidebarEvent::OpenInNewTab(table("users")),
            SidebarEvent::EditStructure(table("users")),
            SidebarEvent::ShowCreateTable(table("users")),
            SidebarEvent::ImportCsv(table("users")),
            SidebarEvent::DropTable(table("users")),
        ],
        "a table the list no longer has was acted on"
    );
}

#[gtk4::test]
fn a_read_only_connection_refuses_writes_from_a_stale_menu() {
    let shown = Shown::new(
        &["orders"],
        SidebarAffordances {
            read_only: true,
            ..every_affordance()
        },
    );
    let key = ObjectKey(table("orders")).to_variant();

    shown
        .list_view()
        .activate_action("sidebar.drop-table", Some(&key))
        .expect("the action");
    shown
        .list_view()
        .activate_action("sidebar.new-table", Some(&Some("public".to_owned()).to_variant()))
        .expect("the action");

    assert!(shown.taken().is_empty());
}

#[gtk4::test]
fn keyboard_menu_falls_back_to_the_selected_row() {
    let shown = Shown::new(&["a", "b", "c", "d"], every_affordance());
    // Showing the window focuses its first control, which may be a row.
    gtk::prelude::GtkWindowExt::set_focus(&shown.window, None::<&gtk::Widget>);
    shown.selection().set_selected(2);

    shown
        .list_view()
        .activate_action("sidebar.context-menu", None)
        .expect("the action");

    let popover = shown.popover();
    assert!(popover.is_visible(), "the menu did not open");
    let model = popover.menu_model().expect("a menu model");
    let (_, target) = menu_items(&model).into_iter().next().expect("an item");
    assert_eq!(
        target.as_ref().and_then(ObjectKey::from_variant),
        Some(ObjectKey(table("c")))
    );
    assert!(popover.pointing_to().0, "the menu points at nothing");
    popover.popdown();
}

/// The table the open menu acts on, if a menu is open.
fn menu_table(shown: &Shown) -> Option<ObjectKey> {
    let popover = shown.popover();
    if !popover.is_visible() {
        return None;
    }
    let (_, target) = menu_items(&popover.menu_model()?).into_iter().next()?;
    target.as_ref().and_then(ObjectKey::from_variant)
}

/// The name on the row the keyboard is on.
fn focused_name(list_view: &gtk::ListView) -> Option<String> {
    list_view
        .focus_child()
        .and_then(|item| item.first_child())
        .and_then(|row| row.last_child())
        .and_downcast::<gtk::Label>()
        .map(|label| label.label().to_string())
}

/// The scroll marks the row the list focuses next; the grab carries the
/// focus there.
fn focus_row(list_view: &gtk::ListView, position: u32, name: &str) {
    list_view.scroll_to(position, gtk::ListScrollFlags::FOCUS, None);
    list_view.grab_focus();
    wait_until(WAIT, || focused_name(list_view).as_deref() == Some(name)).expect("the row focused");
}

#[gtk4::test]
fn keyboard_menu_opens_for_the_focused_row() {
    let shown = Shown::new(&["a", "b", "c", "d"], every_affordance());
    let list_view = shown.list_view();
    wait_until(WAIT, || list_view.height() > 0).expect("the list laid out");

    // An editor tab in front: no row is selected.
    focus_row(&list_view, 2, "c");
    shown.view.sync_selection(None);
    list_view
        .activate_action("sidebar.context-menu", None)
        .expect("the action");
    assert_eq!(menu_table(&shown), Some(ObjectKey(table("c"))));
    shown.popover().popdown();

    // A table tab in front selects its own row, not the focused one.
    focus_row(&list_view, 2, "c");
    shown.view.sync_selection(Some(&table("a")));
    list_view
        .activate_action("sidebar.context-menu", None)
        .expect("the action");
    assert_eq!(menu_table(&shown), Some(ObjectKey(table("c"))));
    shown.popover().popdown();
}

#[gtk4::test]
fn the_menu_keys_reach_the_context_menu_action() {
    let shown = Shown::new(&["a"], every_affordance());

    let bound = crate::test_support::shortcut_keys::owner_controller(
        &shown.list_view(),
        crate::application::ShortcutOwner::SidebarList,
    )
    .expect("the list's keys");
    let actions: Vec<String> = crate::test_support::shortcut_keys::shortcuts(&bound)
        .into_iter()
        .filter_map(|shortcut| shortcut.action().and_downcast::<gtk::NamedAction>())
        .map(|action| action.action_name().to_string())
        .collect();

    assert_eq!(actions, ["sidebar.context-menu", "sidebar.context-menu"]);
}

/// Each section header's title and whether its New Table button shows.
fn headers(list_view: &gtk::ListView) -> Vec<(String, bool)> {
    descendants(list_view)
        .into_iter()
        .filter(|widget| widget.css_name() == "header")
        .filter_map(|header| {
            let row = header.first_child()?;
            let title = row.first_child().and_downcast::<gtk::Label>()?.label().to_string();
            let add = row.last_child().and_downcast::<gtk::Button>()?;
            Some((title, add.is_visible()))
        })
        .collect()
}

#[gtk4::test]
fn the_new_table_button_follows_the_dialect() {
    let shown = Shown::new(&["orders"], every_affordance());
    wait_until(WAIT, || !headers(&shown.list_view()).is_empty()).expect("a section header");
    assert_eq!(headers(&shown.list_view()), [("public".to_owned(), true)]);
    let button = descendants(&shown.list_view())
        .into_iter()
        .find_map(|widget| widget.downcast::<gtk::Button>().ok())
        .expect("the New Table button");
    assert_eq!(button.tooltip_text().as_deref(), Some("New Table in public…"));
    button.emit_clicked();
    assert_eq!(shown.taken(), [SidebarEvent::NewTable(Some("public".to_owned()))]);

    shown.view.set_affordances(SidebarAffordances {
        can_create_table: false,
        ..every_affordance()
    });
    wait_until(WAIT, || headers(&shown.list_view()) == [("public".to_owned(), false)])
        .expect("the button hidden once the server cannot create tables");
}

#[gtk4::test]
fn sync_selection_follows_the_tab_and_survives_a_new_list() {
    let shown = Shown::new(&["orders", "users"], every_affordance());

    shown.view.sync_selection(Some(&table("users")));
    assert_eq!(shown.selection().selected(), 1);
    shown.view.apply_objects(
        &[
            object("public", "accounts"),
            object("public", "orders"),
            object("public", "users"),
        ],
        &public(),
    );
    assert_eq!(shown.selection().selected(), 2, "the new list dropped the selection");

    shown.view.sync_selection(None);
    assert_eq!(shown.selection().selected(), gtk::INVALID_LIST_POSITION);
}

fn sidebar_selected(workspace: &crate::ui::workspace::Workspace) -> Option<TableRef> {
    workspace.read(|model| model.sidebar.selected_table()).flatten()
}

#[gtk4::test]
fn sync_selection_selects_matching_row_and_clears_for_editor() {
    let test = TestWindow::connected_with("SidebarSync", |script| {
        script.list_objects.once(FakeReply::ok(vec![
            object("public", "orders"),
            object("public", "users"),
        ]));
    });
    let workspace = test.workspace();
    wait_until(WAIT, || workspace.read(|model| model.sidebar.shown()) == Some(2)).expect("the tables listed");

    workspace.with_model(|model| {
        model.open_tab(TabSpec::Table {
            table: table("users"),
            page: TablePage::first(100),
        })
    });
    wait_until(WAIT, || sidebar_selected(&workspace) == Some(table("users"))).expect("the table's row selected");

    WidgetExt::activate_action(&test.window, "win.new-editor-tab", None).expect("win.new-editor-tab");
    wait_until(WAIT, || {
        workspace
            .read(|model| {
                let tabs = model.workspace_tabs.borrow();
                model
                    .selected_workspace_tab_id()
                    .and_then(|id| tabs.get(&id).map(|tab| matches!(tab, WorkspaceTab::Editor(_))))
            })
            .flatten()
            == Some(true)
    })
    .expect("the editor in front");
    wait_until(WAIT, || sidebar_selected(&workspace).is_none()).expect("no row selected for the editor");
}

#[gtk4::test]
fn sidebar_lists_every_schema_after_the_connect() {
    let test = TestWindow::connected_with("SidebarAllSchemas", |script| {
        script.list_objects.once(FakeReply::ok(vec![
            object("public", "users"),
            object("sales", "orders"),
        ]));
    });
    let workspace = test.workspace();

    wait_until(WAIT, || workspace.read(|model| model.sidebar.shown()) == Some(2))
        .expect("the second schema's table listed");
}

#[gtk4::test]
fn catalog_error_keeps_list_and_toasts() {
    let test = TestWindow::connected_with("SidebarCatalogError", |script| {
        script.list_objects.once(FakeReply::ok(vec![
            object("public", "orders"),
            object("public", "users"),
        ]));
        script
            .list_objects
            .once(FakeReply::err(DriverError::Protocol("catalog gone".to_owned())));
    });
    let workspace = test.workspace();
    wait_until(WAIT, || workspace.read(|model| model.sidebar.shown()) == Some(2)).expect("the tables listed");
    let toasts_before = toast_count(&workspace);

    let input = workspace.input().expect("the workspace's input");
    input.deliver(WorkspaceInput::SchemaChanged {
        schema: Some("public".to_owned()),
        table: None,
    });

    wait_until(WAIT, || toast_count(&workspace) > toasts_before).expect("a toast for the failed refresh");
    assert_eq!(
        workspace.read(|model| model.sidebar.shown()),
        Some(2),
        "the failure emptied the list"
    );
}

fn toast_count(workspace: &crate::ui::workspace::Workspace) -> usize {
    descendants(&workspace.imp().toast_overlay.get())
        .into_iter()
        .filter(|widget| widget.css_name() == "toast")
        .count()
}

#[gtk4::test]
fn a_reconnect_reads_every_schema_again() {
    let test = TestWindow::connected_with("SidebarReconnect", |script| {
        script.list_objects.once(FakeReply::ok(vec![object("public", "users")]));
        script.list_objects.once(FakeReply::ok(vec![
            object("public", "users"),
            object("sales", "orders"),
        ]));
    });
    let workspace = test.workspace();
    wait_until(WAIT, || workspace.read(|model| model.sidebar.shown()) == Some(1)).expect("the table listed");
    let session = workspace
        .read(|model| model.context.active.get())
        .flatten()
        .expect("the session");

    // What a reconnect does once the new connection read its catalog.
    session.catalog().commit(Vec::new(), vec![object("public", "users")]);

    wait_until(Duration::from_secs(10), || {
        workspace.read(|model| model.sidebar.shown()) == Some(2)
    })
    .expect("every schema's list read again");
}
