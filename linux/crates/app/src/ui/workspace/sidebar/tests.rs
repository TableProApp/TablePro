use std::cell::RefCell;
use std::rc::Rc;
use std::time::Duration;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gdk, gio, glib};
use libadwaita as adw;
use tablepro_core::DriverError;
use tablepro_core::meta::{ObjectInfo, ObjectKind, ObjectScope, SchemaInfo, TableRef};
use tablepro_test_support::FakeReply;

use super::object_key::ObjectKey;
use super::sidebar_event::SidebarEvent;
use super::*;
use crate::test_support::{descendants, drain_main_context, test_runtime, wait_until};
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

fn schema(name: &str, is_default: bool) -> SchemaInfo {
    SchemaInfo {
        name: name.to_owned(),
        is_default,
        is_system: false,
    }
}

fn public() -> [SchemaInfo; 1] {
    [schema("public", true)]
}

fn table(name: &str) -> TableRef {
    TableRef::new(Some("public".to_owned()), name)
}

fn every_affordance() -> SidebarAffordances {
    SidebarAffordances {
        read_only: false,
        can_create_table: true,
        can_edit_structure: true,
        speaks_sql: true,
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
        let view = SidebarView::new(move |event| sink.borrow_mut().push(event), affordances, None);
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

/// The placeholder's title and description, when it shows.
fn placeholder(view: &SidebarView) -> Option<(String, Option<String>)> {
    view.widget()
        .visible_child()
        .and_downcast::<adw::StatusPage>()
        .map(|page| {
            (
                page.title().to_string(),
                page.description()
                    .filter(|text| !text.is_empty())
                    .map(|text| text.to_string()),
            )
        })
}

#[gtk4::test]
fn empty_filter_shows_placeholder() {
    let shown = Shown::new(&["orders", "users"], every_affordance());
    assert_eq!(placeholder(&shown.view), None, "a list with rows shows its placeholder");

    shown.view.set_query("nothing like it");
    assert_eq!(
        placeholder(&shown.view),
        Some((
            "No Matching Tables".to_owned(),
            Some("Try a different search.".to_owned())
        ))
    );

    shown.view.set_query("");
    shown.view.apply_objects(&[], &public());
    assert_eq!(placeholder(&shown.view), Some(("No Tables".to_owned(), None)));
}

#[gtk4::test]
fn clearing_a_search_over_an_emptied_list_says_there_are_no_tables() {
    let shown = Shown::new(&["orders"], every_affordance());
    shown.view.set_query("zzz");
    // An empty list under a search that matched nothing: no row changes.
    shown.view.apply_objects(&[], &public());

    shown.view.set_query("");

    assert_eq!(placeholder(&shown.view), Some(("No Tables".to_owned(), None)));
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
fn a_search_makes_only_the_rows_it_shows() {
    let owned = names(10_000);
    let borrowed: Vec<&str> = owned.iter().map(String::as_str).collect();
    let shown = Shown::new(&borrowed, every_affordance());
    wait_until(WAIT, || shown.list_view().height() > 0).expect("the list laid out");
    shown.view.sync_selection(Some(&table("t09999")));

    for query in ["t0", "9", "t09", ""] {
        shown.view.set_query(query);
        drain_main_context();
    }

    assert_eq!(shown.view.selected_table(), Some(table("t09999")));
    // GtkListView keeps about 200 rows around its viewport; a list that
    // made one per table would reach 10,000.
    assert!(
        shown.view.made() <= 1_000,
        "{} rows made for 10,000 tables",
        shown.view.made()
    );
}

#[gtk4::test]
fn a_list_and_its_searches_are_worked_out_off_the_gtk_thread() {
    adw::init().expect("libadwaita initialises under the test backend");
    let runtime = test_runtime();
    let view = SidebarView::new(|_| {}, every_affordance(), Some(runtime.tasks()));
    let objects: Vec<ObjectInfo> = names(20_000).iter().map(|name| object("public", name)).collect();

    view.show(SidebarIndex::build(&objects, &public()));
    assert_eq!(view.shown(), 0, "the GTK thread worked out the list's rows");
    wait_until(WAIT, || view.shown() == 20_000).expect("the list's rows");
    view.sync_selection(Some(&table("t19999")));
    for query in ["t1", "t19", "t19999"] {
        view.set_query(query);
    }

    assert_eq!(view.shown(), 20_000, "the GTK thread worked out a search's rows");
    wait_until(WAIT, || view.shown() == 1).expect("the last search's rows");
    assert_eq!(
        view.selected_table(),
        Some(table("t19999")),
        "the selection did not come back"
    );
    view.shutdown();
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
    assert!(!inner.pressed(2, gdk::BUTTON_MIDDLE, gdk::ModifierType::empty(), None));
    assert!(inner.released(gdk::BUTTON_MIDDLE));

    assert_eq!(
        shown.taken(),
        [
            SidebarEvent::OpenInNewTab(table("b")),
            SidebarEvent::OpenInNewTab(table("c"))
        ]
    );
}

#[gtk4::test]
fn a_middle_click_opens_the_table_it_was_pressed_on() {
    let shown = Shown::new(&["a", "b", "c"], every_affordance());
    let inner = shown.view.inner().clone();
    assert!(
        !inner.released(gdk::BUTTON_MIDDLE),
        "a release with no press opened a table"
    );

    inner.pressed(1, gdk::BUTTON_MIDDLE, gdk::ModifierType::empty(), None);
    // A refresh lands between the press and the release, and binds the
    // pressed row to another table.
    shown.view.apply_objects(
        &[
            object("public", "a"),
            object("public", "aa"),
            object("public", "b"),
            object("public", "c"),
        ],
        &public(),
    );

    assert!(inner.released(gdk::BUTTON_MIDDLE));
    assert_eq!(shown.taken(), [SidebarEvent::OpenInNewTab(table("b"))]);
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
        .and_then(|row| row.first_child())
        .and_then(|icon| icon.next_sibling())
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
fn a_row_tells_a_screen_reader_its_kind() {
    let shown = Shown::new(&[], every_affordance());
    shown.view.apply_objects(
        &[
            object("public", "orders"),
            ObjectInfo {
                schema: Some("public".to_owned()),
                name: "totals".to_owned(),
                kind: ObjectKind::View,
            },
        ],
        &public(),
    );

    wait_until(WAIT, || shown.view.row_descriptions().len() == 2).expect("both rows bound");
    assert_eq!(
        shown.view.row_descriptions(),
        [
            ("orders".to_owned(), "Table".to_owned()),
            ("totals".to_owned(), "View".to_owned())
        ]
    );
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
    let button = crate::test_support::find_by_action_name(&shown.list_view(), "sidebar.new-table")
        .and_downcast::<gtk::Button>()
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

/// Every engine draws a diagram, so the button stays where New Table
/// goes away.
#[gtk4::test]
fn each_schema_heading_shows_its_er_diagram() {
    let shown = Shown::new(&["orders"], every_affordance());
    wait_until(WAIT, || !headers(&shown.list_view()).is_empty()).expect("a section header");
    let button = crate::test_support::find_by_action_name(&shown.list_view(), "sidebar.show-schema-diagram")
        .and_downcast::<gtk::Button>()
        .expect("the ER Diagram button");
    assert_eq!(button.tooltip_text().as_deref(), Some("Show ER Diagram of public"));
    crate::test_support::assert_labelled(&button).expect("the ER Diagram button is named");

    button.emit_clicked();

    assert_eq!(shown.taken(), [SidebarEvent::ShowDiagram(Some("public".to_owned()))]);
    shown.view.set_affordances(SidebarAffordances {
        can_create_table: false,
        ..every_affordance()
    });
    wait_until(WAIT, || headers(&shown.list_view()) == [("public".to_owned(), false)]).expect("New Table hidden");
    let button = crate::test_support::find_by_action_name(&shown.list_view(), "sidebar.show-schema-diagram")
        .expect("the ER Diagram button");
    assert!(button.is_visible());
}

#[gtk4::test]
fn a_heading_of_keys_offers_no_er_diagram() {
    let shown = Shown::new(&[], every_affordance());
    shown.view.hold_keys();
    let key = ObjectInfo {
        schema: None,
        name: "user:1".to_owned(),
        kind: ObjectKind::Key(tablepro_core::meta::KeyKind::Hash),
    };
    shown.view.show_keys(
        super::sidebar_index::SidebarIndex::keys(&[key], "db0".to_owned()),
        false,
    );
    wait_until(WAIT, || !headers(&shown.list_view()).is_empty()).expect("the keys' heading");

    let button = crate::test_support::find_by_action_name(&shown.list_view(), "sidebar.show-schema-diagram")
        .expect("the heading's ER Diagram button");

    assert!(!button.is_visible(), "keys have no diagram");
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
            filter: crate::ui::browse_tab::TableFilter::Remembered,
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
    let session = workspace
        .read(|model| model.context.active.get())
        .flatten()
        .expect("the session");
    let listed = session.catalog().subscribe(ObjectScope::AllSchemas).borrow().clone();
    assert!(listed.generation > 0, "every schema's list was never asked for");
    assert_eq!(listed.objects.len(), 2);
}

#[gtk4::test]
fn catalog_error_keeps_list_and_shows_why_until_a_read_lands() {
    let test = TestWindow::connected_with("SidebarCatalogError", |script| {
        script.list_objects.once(FakeReply::ok(vec![
            object("public", "orders"),
            object("public", "users"),
        ]));
        for _ in 0..2 {
            script
                .list_objects
                .once(FakeReply::err(DriverError::Protocol("catalog gone".to_owned())));
        }
        for _ in 0..3 {
            script.list_objects.once(FakeReply::ok(vec![
                object("public", "orders"),
                object("public", "users"),
                object("public", "carts"),
            ]));
        }
    });
    let workspace = test.workspace();
    wait_until(WAIT, || workspace.read(|model| model.sidebar.shown()) == Some(2)).expect("the tables listed");
    let banner = workspace.imp().catalog_banner.get();
    assert!(!banner.is_revealed(), "a banner before anything failed");

    WidgetExt::activate_action(&test.window, "win.refresh-tables", None).expect("win.refresh-tables");

    wait_until(WAIT, || banner.is_revealed()).expect("a banner for the failed refresh");
    assert!(
        banner.title().starts_with("Could not refresh the table list: "),
        "{}",
        banner.title()
    );
    assert_eq!(banner.action_name().as_deref(), Some("win.refresh-tables"));
    assert_eq!(
        workspace.read(|model| model.sidebar.shown()),
        Some(2),
        "the failure emptied the list"
    );

    WidgetExt::activate_action(&test.window, "win.refresh-tables", None).expect("the banner's Retry");

    wait_until(WAIT, || workspace.read(|model| model.sidebar.shown()) == Some(3)).expect("the list read again");
    assert!(!banner.is_revealed(), "the banner stayed after a read landed");
}

#[gtk4::test]
fn the_refresh_button_reads_the_tables_again() {
    let test = TestWindow::connected_with("SidebarRefresh", |script| {
        script.list_objects.once(FakeReply::ok(vec![object("public", "users")]));
        for _ in 0..3 {
            script.list_objects.once(FakeReply::ok(vec![
                object("public", "users"),
                object("public", "orders"),
            ]));
        }
    });
    let workspace = test.workspace();
    wait_until(WAIT, || workspace.read(|model| model.sidebar.shown()) == Some(1)).expect("the table listed");
    let button = workspace.imp().refresh_tables_button.get();
    assert_eq!(button.action_name().as_deref(), Some("win.refresh-tables"));
    crate::test_support::assert_labelled(&button).expect("the refresh button is named");

    button.emit_clicked();

    wait_until(WAIT, || workspace.read(|model| model.sidebar.shown()) == Some(2)).expect("the new table listed");
}

#[gtk4::test]
fn ddl_run_in_the_editor_reads_the_tables_again() {
    use tablepro_core::EditorSession;
    use tablepro_test_support::{FakeEditorSession, FakeRun, Replies};

    let mut runs = Replies::default();
    runs.always(FakeRun::completed(Vec::new()));
    let editor_session: std::sync::Arc<dyn EditorSession> = std::sync::Arc::new(FakeEditorSession::new(runs));
    let test = TestWindow::connected_with("SidebarEditorDdl", |script| {
        script.open_editor_session.always(FakeReply::ok(editor_session));
        script.list_objects.once(FakeReply::ok(vec![object("public", "users")]));
        for _ in 0..3 {
            script.list_objects.once(FakeReply::ok(vec![
                object("public", "users"),
                object("public", "orders"),
            ]));
        }
    });
    let workspace = test.workspace();
    wait_until(WAIT, || workspace.read(|model| model.sidebar.shown()) == Some(1)).expect("the table listed");
    workspace.with_model(|model| model.open_editor_tab(Some("CREATE TABLE orders (id int)".to_owned())));
    let editor = crate::ui::session_window::tests::editors(&test.window)
        .pop()
        .expect("the editor tab");

    editor.run();

    wait_until(WAIT, || workspace.read(|model| model.sidebar.shown()) == Some(2))
        .expect("the created table listed without a reconnect");
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

    let listed = || session.catalog().subscribe(ObjectScope::AllSchemas).borrow().clone();
    let before = listed().generation;

    // What a reconnect does once the new connection read its catalog.
    session.catalog().commit(Vec::new(), vec![object("public", "users")]);

    wait_until(Duration::from_secs(10), || {
        workspace.read(|model| model.sidebar.shown()) == Some(2)
    })
    .expect("every schema's list read again");
    assert!(listed().generation > before, "every schema's list was not read again");
    assert_eq!(listed().objects.len(), 2);
}

#[gtk4::test]
fn a_reconnect_names_tabs_by_its_schemas_when_the_list_fails() {
    let test = TestWindow::connected_with("SidebarReconnectNaming", |script| {
        script.list_objects.once(FakeReply::ok(vec![object("public", "users")]));
        script
            .list_objects
            .once(FakeReply::err(DriverError::Protocol("catalog gone".to_owned())));
    });
    let workspace = test.workspace();
    wait_until(WAIT, || workspace.read(|model| model.sidebar.shown()) == Some(1)).expect("the table listed");
    let naming = || workspace.read(|model| model.naming.get());
    assert_eq!(naming(), Some(TableNaming::Bare));
    let session = workspace
        .read(|model| model.context.active.get())
        .flatten()
        .expect("the session");
    let banner = workspace.imp().catalog_banner.get();

    session.catalog().commit(
        vec![schema("public", true), schema("sales", false)],
        vec![object("public", "users")],
    );

    wait_until(WAIT, || banner.is_revealed()).expect("the list read to fail");
    wait_until(WAIT, || naming() == Some(TableNaming::SchemaQualified))
        .expect("the reconnect's schemas never named the tabs");
    assert_eq!(
        workspace.read(|model| model.sidebar.shown()),
        Some(1),
        "the failure emptied the list"
    );
}
