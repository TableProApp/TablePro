use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gdk, gio, glib};
use libadwaita as adw;
use tablepro_core::meta::{KeyKind, ObjectInfo, ObjectKind, ObjectScope, SchemaInfo, TableRef};
use tablepro_core::{DriverError, DriverRegistry};
use tablepro_session::SessionKey;
use tablepro_storage::{
    ConnectionColor, ConnectionGroupName, ConnectionStore, ConnectionTagName, SavedConnection, StoragePaths,
};
use tablepro_test_support::FakeReply;
use uuid::Uuid;

use super::connection_tree::{Pane, TreeInner, Which};
use super::object_key::ObjectKey;
use super::sidebar_event::SidebarEvent;
use super::sidebar_object::SidebarObject;
use super::tree_node::TreeNode;
use super::tree_row::TreeRow;
use super::*;
use crate::services::saved_connection_list::SavedConnectionList;
use crate::test_support::{descendants, drain_main_context, test_runtime, wait_until};
use crate::ui::session_window::tests::{TestWindow, WAIT};
use crate::ui::workspace::WorkspaceTab;
use crate::ui::workspace::tab_spec::{TabSpec, TablePage};

/// How many tables `view` lists, searched for or not.
pub(crate) fn listed(view: &SidebarView) -> u32 {
    count_rows(&view.schemas(), TreeNode::children)
}

/// How many tables the search found in `view`.
pub(crate) fn found(view: &SidebarView) -> u32 {
    count_rows(&view.schemas(), TreeNode::found)
}

fn count_rows(schemas: &gio::ListModel, rows: fn(&TreeNode) -> Option<gio::ListModel>) -> u32 {
    (0..schemas.n_items())
        .filter_map(|at| schemas.item(at).and_downcast::<TreeNode>())
        .filter_map(|node| rows(&node))
        .map(|list| list.n_items())
        .sum()
}

/// How many rows the lists of what the search found made.
fn made_found(view: &SidebarView) -> usize {
    let schemas = view.schemas();
    (0..schemas.n_items())
        .filter_map(|at| schemas.item(at).and_downcast::<TreeNode>())
        .filter_map(|node| node.found_rows())
        .map(|list| list.imp().objects.borrow().iter().flatten().count())
        .sum()
}

/// How many row widgets the list `list_view` built.
fn built(list_view: &gtk::ListView) -> usize {
    descendants(list_view)
        .into_iter()
        .filter(|widget| widget.is::<TreeRow>())
        .count()
}

type Events = Rc<RefCell<Vec<SidebarEvent>>>;

/// The window and picker actions the tree fired, with their targets.
type Fired = Rc<RefCell<Vec<(String, Option<String>)>>>;

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

fn names(count: usize) -> Vec<String> {
    (0..count).map(|index| format!("t{index:05}")).collect()
}

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
        group: group.map(|group| ConnectionGroupName::new(group).expect("a group name")),
        tags: Vec::new(),
        icon: None,
        options: Default::default(),
    }
}

/// A session's sidebar listing `objects`, with what it sent.
fn session(objects: &[ObjectInfo], affordances: SidebarAffordances) -> (SidebarView, Events) {
    let events = Events::default();
    let sink = events.clone();
    let view = SidebarView::new(move |event| sink.borrow_mut().push(event), affordances, None);
    view.show(SidebarIndex::build(objects, &public()));
    (view, events)
}

fn tables(view: &SidebarView, names: &[&str]) {
    let objects: Vec<ObjectInfo> = names.iter().map(|name| object("public", name)).collect();
    view.show(SidebarIndex::build(&objects, &public()));
}

/// The tree in a window of its own, over a store of saved connections,
/// with the window's and the picker's actions recording what reached
/// them.
struct Shown {
    _dir: tempfile::TempDir,
    store: ConnectionStore,
    list: Rc<SavedConnectionList>,
    tree: ConnectionTree,
    entry: gtk::SearchEntry,
    window: gtk::ApplicationWindow,
    fired: Fired,
}

impl Shown {
    fn new(connections: &[SavedConnection]) -> Self {
        adw::init().expect("libadwaita initialises under the test backend");
        let dir = tempfile::tempdir().expect("a temporary directory");
        let store = ConnectionStore::new(&StoragePaths::under(dir.path(), "tablepro", crate::config::APP_ID));
        let list = SavedConnectionList::follow(&store, Arc::new(DriverRegistry::new()));
        for saved in connections {
            store.upsert_blocking(saved.clone()).expect("save the connection");
        }
        wait_until(WAIT, || list.model().n_items() as usize == connections.len()).expect("the list to have them");
        let tree = ConnectionTree::new(list.clone());
        let entry = gtk::SearchEntry::new();
        entry.set_search_delay(0);
        tree.follow_search(&entry);
        let fired = Fired::default();
        let window = gtk::ApplicationWindow::builder()
            .default_width(300)
            .default_height(600)
            .build();
        for name in [
            "show-session",
            "disconnect-session",
            "stop-connecting",
            "new-query-in",
            "refresh-in",
            "show-connect-failure",
            "forget-connect-failure",
        ] {
            window.add_action(&recording(name, &fired, "win"));
        }
        let picker = gio::SimpleActionGroup::new();
        picker.add_action(&recording("connect", &fired, "picker"));
        let content = gtk::Box::new(gtk::Orientation::Vertical, 0);
        content.insert_action_group("picker", Some(&picker));
        content.append(&entry);
        content.append(&tree.widget());
        window.set_child(Some(&content));
        window.present();
        drain_main_context();
        Self {
            _dir: dir,
            store,
            list,
            tree,
            entry,
            window,
            fired,
        }
    }

    fn inner(&self) -> &TreeInner {
        &self.tree.inner
    }

    /// The list on screen.
    fn pane(&self) -> &Pane {
        let inner = self.inner();
        match self.which() {
            Which::Found => &inner.found,
            Which::Tree => &inner.tree,
        }
    }

    /// Which list shows.
    fn which(&self) -> Which {
        if self.inner().root.visible_child_name().as_deref() == Some("found") {
            Which::Found
        } else {
            Which::Tree
        }
    }

    /// Each row's name, in order, of the list on screen.
    fn rows(&self) -> Vec<String> {
        let selection = &self.pane().selection;
        (0..selection.n_items())
            .filter_map(|position| selection.item(position))
            .filter_map(|item| item_title(&item))
            .collect()
    }

    /// The tree's row named `name`.
    fn row(&self, name: &str) -> gtk::TreeListRow {
        let rows = &self.inner().rows;
        (0..rows.n_items())
            .filter_map(|position| rows.row(position))
            .find(|row| item_title(row.upcast_ref()).as_deref() == Some(name))
            .unwrap_or_else(|| panic!("no row named {name}: {:?}", self.rows()))
    }

    /// Where the list on screen shows `name`.
    fn position(&self, name: &str) -> u32 {
        let rows = self.rows();
        let at = rows
            .iter()
            .position(|row| row == name)
            .unwrap_or_else(|| panic!("no row named {name}: {rows:?}"));
        u32::try_from(at).unwrap_or(u32::MAX)
    }

    fn selected(&self) -> Option<String> {
        self.pane().selection.selected_item().and_then(|item| item_title(&item))
    }

    /// Open the menu of the row named `name` in the list on screen.
    fn menu(&self, name: &str) {
        self.inner().popup_menu(self.which(), self.position(name), None);
    }

    /// The headings over the sections of what the search finds.
    fn headings(&self) -> Vec<String> {
        descendants(&self.inner().found.list_view)
            .into_iter()
            .filter(|widget| widget.css_name() == "header" && widget.is_mapped())
            .filter_map(|header| header.first_child().and_downcast::<gtk::Label>())
            .map(|title| title.label().to_string())
            .collect()
    }

    fn says_nothing_found(&self) -> bool {
        self.inner().root.visible_child_name().as_deref() == Some("nothing")
    }

    fn open(&self, saved: &SavedConnection, view: &SidebarView) -> SessionKey {
        let key = SessionKey::Saved(saved.id);
        self.tree.add_session(&key, &saved.name, view);
        key
    }

    /// What typing `text` sends once the user pauses.
    fn search(&self, text: &str) {
        self.entry.set_text(text);
        self.entry.emit_by_name::<()>("search-changed", &[]);
    }

    fn activate(&self, name: &str) {
        let position = self.position(name);
        self.pane().list_view.emit_by_name::<()>("activate", &[&position]);
    }

    fn fired(&self) -> Vec<(String, Option<String>)> {
        self.fired.take()
    }

    fn popover(&self) -> gtk::PopoverMenu {
        self.inner().popover.clone()
    }

    /// The bound row widget showing `name`.
    fn row_widget(&self, name: &str) -> TreeRow {
        wait_until(WAIT, || bound_row(&self.pane().list_view, name).is_some()).expect("the row on screen");
        bound_row(&self.pane().list_view, name).unwrap_or_else(|| panic!("{name} is not on screen"))
    }

    fn write(&self, saved: &SavedConnection) {
        self.store.upsert_blocking(saved.clone()).expect("the write");
        wait_until(WAIT, || self.list.get(saved.id).as_ref() == Some(saved)).expect("the list to publish it");
        drain_main_context();
    }
}

impl Drop for Shown {
    fn drop(&mut self) {
        self.tree.shutdown();
        self.window.destroy();
        drain_main_context();
    }
}

fn recording(name: &'static str, fired: &Fired, group: &'static str) -> gio::SimpleAction {
    let action = gio::SimpleAction::new(name, Some(glib::VariantTy::STRING));
    let sink = fired.clone();
    action.connect_activate(move |_, target| {
        sink.borrow_mut().push((
            format!("{group}.{name}"),
            target.and_then(|target| target.get::<String>()),
        ));
    });
    action
}

/// The name of a row's table or node, under the tree's row or as the
/// search's list holds it.
fn item_title(item: &glib::Object) -> Option<String> {
    let item = match item.downcast_ref::<gtk::TreeListRow>() {
        Some(row) => row.item()?,
        None => item.clone(),
    };
    if let Some(object) = item.downcast_ref::<SidebarObject>() {
        return Some(object.name());
    }
    item.downcast_ref::<TreeNode>().map(TreeNode::title)
}

fn bound_row(list_view: &gtk::ListView, name: &str) -> Option<TreeRow> {
    descendants(list_view)
        .into_iter()
        .filter_map(|widget| widget.downcast::<TreeRow>().ok())
        .find(|row| row.imp().name.label() == name && row.is_mapped())
}

fn target(key: &SessionKey) -> Option<String> {
    crate::ui::session_target::to_variant(key).get::<String>()
}

/// Each menu item's action and target, sections and submenus flattened.
fn menu_items(menu: &gio::MenuModel) -> Vec<(String, Option<glib::Variant>)> {
    let mut found = Vec::new();
    for index in 0..menu.n_items() {
        if let Some(action) = menu
            .item_attribute_value(index, "action", None)
            .and_then(|value| value.get::<String>())
        {
            found.push((action, menu.item_attribute_value(index, "target", None)));
        }
        for link in ["section", "submenu"] {
            if let Some(linked) = menu.item_link(index, link) {
                found.extend(menu_items(&linked));
            }
        }
    }
    found
}

fn menu_actions(popover: &gtk::PopoverMenu) -> Vec<String> {
    popover
        .menu_model()
        .map(|menu| menu_items(&menu).into_iter().map(|(action, _)| action).collect())
        .unwrap_or_default()
}

/// The table the open menu acts on, if a menu is open.
fn menu_table(popover: &gtk::PopoverMenu) -> Option<ObjectKey> {
    if !popover.is_visible() {
        return None;
    }
    let (_, target) = menu_items(&popover.menu_model()?).into_iter().next()?;
    target.as_ref().and_then(ObjectKey::from_variant)
}

#[gtk4::test]
fn the_tree_lists_connections_as_the_picker_groups_them() {
    let shown = Shown::new(&[
        connection("Alpha", Some("Work")),
        connection("zeta", None),
        connection("Beta", None),
        connection("Gamma", Some("Home")),
        connection("Delta", Some("work")),
    ]);

    assert_eq!(shown.rows(), ["Beta", "zeta", "Home", "Work", "work"]);
    shown.activate("Work");
    assert_eq!(shown.rows(), ["Beta", "zeta", "Home", "Work", "Alpha", "work"]);
    assert!(
        !shown.row("Beta").is_expandable(),
        "a closed connection has an expander"
    );
}

#[gtk4::test]
fn a_store_write_keeps_the_other_open_connections_open() {
    let (alpha, beta, gamma) = (
        connection("Alpha", None),
        connection("Beta", None),
        connection("Gamma", None),
    );
    let shown = Shown::new(&[alpha.clone(), beta.clone(), gamma.clone()]);
    let (beta_view, _) = session(
        &[object("public", "orders"), object("sales", "leads")],
        every_affordance(),
    );
    let (gamma_view, _) = session(&[object("public", "users")], every_affordance());
    shown.open(&beta, &beta_view);
    shown.open(&gamma, &gamma_view);
    shown.row("public").set_expanded(true);
    shown.row("sales").set_expanded(true);
    let before = shown.rows();
    assert!(before.contains(&"leads".to_owned()), "{before:?}");

    let mut stamped = alpha.clone();
    stamped.last_opened_at = Some(chrono::Utc::now());
    shown.write(&stamped);
    assert_eq!(shown.rows(), before, "the stamp folded a connection after it");

    let mut renamed = beta.clone();
    renamed.name = "Zulu".to_owned();
    shown.write(&renamed);
    let after = shown.rows();
    assert_eq!(after.first().map(String::as_str), Some("Alpha"));
    let zulu = after.iter().position(|name| name == "Zulu").expect("the renamed row");
    assert_eq!(
        after[zulu..],
        ["Zulu", "public", "orders", "sales", "leads"],
        "the moved row came back folded"
    );
}

#[gtk4::test]
fn a_connection_shows_its_colour() {
    let mut red = connection("Production", None);
    red.color = Some(ConnectionColor::Red);
    let shown = Shown::new(&[red.clone(), connection("Staging", None)]);

    let icon = shown.row_widget("Production").imp().icon.clone();
    assert!(icon.has_css_class("tp-connection-icon") && icon.has_css_class("tp-tag-red"));
    assert!(
        !shown
            .row_widget("Staging")
            .imp()
            .icon
            .has_css_class("tp-connection-icon")
    );

    let mut blue = red;
    blue.color = Some(ConnectionColor::Blue);
    shown.write(&blue);
    assert!(icon.has_css_class("tp-tag-blue") && !icon.has_css_class("tp-tag-red"));
}

#[gtk4::test]
fn a_search_finds_connections_by_tag_host_and_group() {
    let shown = Shown::new(&[connection("Delta", None)]);
    let tag = shown
        .store
        .create_tag_blocking(
            ConnectionTagName::new("production").expect("a tag name"),
            ConnectionColor::Red,
        )
        .expect("the tag");
    let mut tagged = connection("Alpha", None);
    tagged.tags = vec![tag.id];
    let mut hosted = connection("Beta", None);
    hosted.host = "db.acme.example".to_owned();
    for saved in [tagged, hosted, connection("Gamma", Some("Clients"))] {
        shown.write(&saved);
    }

    shown.search("PRODUCTION");
    assert_eq!(shown.rows(), ["Alpha"]);
    shown.search("acme");
    assert_eq!(shown.rows(), ["Beta"]);
    shown.search("clients");
    assert_eq!(shown.rows(), ["Gamma"]);
    assert_eq!(shown.headings(), ["Connections"]);
    shown.search("nothing like it");
    assert!(shown.says_nothing_found());
}

#[gtk4::test]
fn a_search_lists_the_tables_it_finds_under_their_schema_and_connection() {
    let alpha = connection("Alpha", None);
    let shown = Shown::new(&[alpha.clone(), connection("Beta", None)]);
    let (view, _) = session(
        &[object("public", "orders"), object("public", "users")],
        every_affordance(),
    );
    shown.open(&alpha, &view);
    assert_eq!(shown.rows(), ["Alpha", "public", "orders", "users", "Beta"]);

    shown.search("ord");

    wait_until(WAIT, || shown.rows() == ["orders"]).expect("only the table it finds");
    wait_until(WAIT, || shown.headings() == ["public (Alpha)"]).expect("the table's schema and connection");
    shown.search("alpha");
    assert_eq!(shown.rows(), ["Alpha"], "a table counted as a connection");
}

#[gtk4::test]
fn a_session_joining_under_a_search_lists_only_what_it_finds() {
    let alpha = connection("Alpha", None);
    let shown = Shown::new(&[alpha.clone(), connection("Beta", None)]);
    shown.search("ord");
    assert!(shown.says_nothing_found(), "a connection named so");

    let (view, _) = session(
        &[object("public", "orders"), object("public", "users")],
        every_affordance(),
    );
    shown.open(&alpha, &view);

    assert_eq!(shown.rows(), ["orders"]);
    assert!(!shown.says_nothing_found());
}

#[gtk4::test]
fn the_search_list_opens_and_offers_the_menus_of_what_it_finds() {
    let (alpha, beta) = (connection("Alpha", None), connection("Orders Archive", None));
    let shown = Shown::new(&[alpha.clone(), beta.clone()]);
    let (view, events) = session(
        &[object("public", "orders"), object("public", "users")],
        every_affordance(),
    );
    let key = shown.open(&alpha, &view);
    shown.tree.select(Some(&key), Some(&table("orders")));

    shown.search("ord");
    assert_eq!(shown.rows(), ["Orders Archive", "orders"]);
    assert_eq!(
        shown.selected().as_deref(),
        Some("orders"),
        "the table in front lost its row"
    );
    gtk::prelude::GtkWindowExt::set_focus(&shown.window, None::<&gtk::Widget>);
    WidgetExt::activate_action(&shown.tree.widget(), "tree.context-menu", None).expect("the action");
    assert_eq!(menu_table(&shown.popover()), Some(ObjectKey(table("orders"))));
    shown.popover().popdown();
    shown.menu("Orders Archive");
    assert!(menu_actions(&shown.popover()).contains(&"picker.connect".to_owned()));
    shown.popover().popdown();
    let inner = shown.inner();
    assert!(inner.pressed(
        Which::Found,
        shown.position("orders"),
        gdk::BUTTON_PRIMARY,
        gdk::ModifierType::CONTROL_MASK,
        None
    ));
    shown.activate("orders");
    shown.activate("Orders Archive");

    assert_eq!(
        events.take(),
        [
            SidebarEvent::OpenInNewTab(table("orders")),
            SidebarEvent::Open(table("orders"))
        ]
    );
    assert_eq!(
        shown.fired(),
        [("picker.connect".to_owned(), Some(beta.id.to_string()))]
    );
}

#[gtk4::test]
fn clearing_a_search_shows_the_rows_as_they_were() {
    let alpha = connection("Alpha", Some("Work"));
    let shown = Shown::new(&[alpha.clone(), connection("Beta", None)]);
    let (view, _) = session(
        &[
            object("public", "orders"),
            object("sales", "leads"),
            object("audit", "log"),
        ],
        every_affordance(),
    );
    shown.open(&alpha, &view);
    shown.row("public").set_expanded(true);
    shown.row("sales").set_expanded(true);
    let before = shown.rows();

    shown.search("ord");
    assert_eq!(shown.rows(), ["orders"]);
    shown.search("");

    assert_eq!(shown.rows(), before, "the search folded a row it had hidden");
}

#[gtk4::test]
fn an_open_connection_with_nothing_to_list_says_so() {
    let alpha = connection("Alpha", None);
    let shown = Shown::new(std::slice::from_ref(&alpha));
    let (view, _) = session(&[], every_affordance());

    shown.open(&alpha, &view);

    assert_eq!(shown.rows(), ["Alpha", "No Tables"]);
    let placeholder = shown.row("No Tables");
    shown
        .pane()
        .list_view
        .emit_by_name::<()>("activate", &[&placeholder.position()]);
    assert!(shown.fired().is_empty());
    tables(&view, &["orders"]);
    assert_eq!(
        shown.rows(),
        ["Alpha", "public", "orders"],
        "a lone schema stays folded"
    );
}

#[gtk4::test]
fn clearing_a_search_over_an_emptied_list_says_there_are_no_tables() {
    let alpha = connection("Alpha", None);
    let shown = Shown::new(std::slice::from_ref(&alpha));
    let (view, _) = session(&[object("public", "orders")], every_affordance());
    shown.open(&alpha, &view);

    shown.search("alp");
    assert_eq!(shown.rows(), ["Alpha"]);
    tables(&view, &[]);
    shown.search("");

    assert_eq!(shown.rows(), ["Alpha", "No Tables"]);
}

#[gtk4::test]
fn a_list_of_collections_or_keys_says_so_when_it_is_empty() {
    let (documents, keys) = (connection("Docs", None), connection("Cache", None));
    let shown = Shown::new(&[documents.clone(), keys.clone()]);
    let (collections, _) = session(&[], every_affordance());
    collections.hold_collections();
    let (listing, _) = session(&[], every_affordance());
    listing.hold_keys(|| {});
    tables(&collections, &[]);
    listing.show_keys(SidebarIndex::keys(&[], "Database 0".to_owned()), false);

    shown.open(&documents, &collections);
    shown.open(&keys, &listing);

    assert_eq!(shown.rows(), ["Cache", "No Keys", "Docs", "No Collections"]);
}

#[gtk4::test]
fn a_key_row_shows_its_type_beside_its_name() {
    let cache = connection("Cache", None);
    let shown = Shown::new(std::slice::from_ref(&cache));
    let (view, _) = session(&[], every_affordance());
    view.hold_keys(|| {});
    let key = |name: &str, kind| ObjectInfo {
        schema: None,
        name: name.to_owned(),
        kind: ObjectKind::Key(kind),
    };
    view.show_keys(
        SidebarIndex::keys(
            &[key("user:1", KeyKind::Hash), key("queue", KeyKind::List)],
            "Database 0".to_owned(),
        ),
        false,
    );

    shown.open(&cache, &view);

    assert_eq!(
        shown.rows(),
        ["Cache", "Database 0", "queue", "user:1"],
        "a lone database stays folded"
    );
    let row = shown.row_widget("user:1");
    assert!(row.imp().kind.is_visible());
    assert_eq!(row.imp().kind.label(), "Hash");
    assert!(!shown.row_widget("Database 0").imp().kind.is_visible());
}

#[gtk4::test]
fn a_row_tells_a_screen_reader_its_kind() {
    let alpha = connection("Alpha", None);
    let shown = Shown::new(&[alpha.clone(), connection("Beta", None)]);
    let (view, _) = session(
        &[
            object("public", "orders"),
            ObjectInfo {
                kind: ObjectKind::View,
                ..object("public", "totals")
            },
        ],
        every_affordance(),
    );
    shown.open(&alpha, &view);
    shown.row("public").set_expanded(true);

    let description = |name: &str| {
        let row = shown.row_widget(name);
        let item = row.imp().item.upgrade().expect("the row's item");
        item.property::<Option<String>>("accessible-description")
    };
    assert_eq!(description("orders").as_deref(), Some("Table"));
    assert_eq!(description("totals").as_deref(), Some("View"));
    assert_eq!(description("public").as_deref(), Some("Schema"));
    assert_eq!(description("Alpha").as_deref(), Some("Connection, connected"));
    assert_eq!(description("Beta").as_deref(), Some("Connection"));
}

#[gtk4::test]
fn rows_are_recycled_for_large_catalogs() {
    let alpha = connection("Alpha", None);
    let shown = Shown::new(std::slice::from_ref(&alpha));
    let owned = names(10_000);
    let borrowed: Vec<&str> = owned.iter().map(String::as_str).collect();
    let (view, _) = session(&[], every_affordance());
    tables(&view, &borrowed);
    shown.open(&alpha, &view);
    wait_until(WAIT, || shown.pane().list_view.height() > 0).expect("the list laid out");
    drain_main_context();

    let rows = built(&shown.pane().list_view);

    assert!(rows > 0, "no row was built at all");
    // GtkListView keeps about 200 rows around its viewport, whatever the
    // model holds.
    assert!(rows <= 210, "{rows} rows for 10,000 tables");
}

/// The tree opens a schema through GtkTreeListModel, which reads every
/// table of it; what the search finds is a flat list, which reads only
/// the rows on screen.
#[gtk4::test]
fn a_search_over_an_open_schema_of_50000_tables_makes_only_the_rows_on_screen() {
    let alpha = connection("Alpha", None);
    let shown = Shown::new(std::slice::from_ref(&alpha));
    let owned = names(50_000);
    let borrowed: Vec<&str> = owned.iter().map(String::as_str).collect();
    let (view, _) = session(&[], every_affordance());
    tables(&view, &borrowed);
    let key = shown.open(&alpha, &view);
    wait_until(WAIT, || shown.pane().list_view.height() > 0).expect("the tree laid out");
    assert!(
        built(&shown.inner().tree.list_view) <= 210,
        "the tree built a row per table"
    );
    shown.tree.select(Some(&key), Some(&table("t49999")));

    for (query, matching) in [("t", 50_000), ("t0", 10_000), ("t4", 10_000), ("t49", 1_000)] {
        shown.search(query);
        let list_view = shown.inner().found.list_view.clone();
        wait_until(WAIT, || list_view.is_mapped() && built(&list_view) > 0).expect("the results on screen");
        drain_main_context();

        assert_eq!(found(&view), matching, "{query}");
        assert!(built(&list_view) <= 210, "{} rows built for {query}", built(&list_view));
        // GtkListView keeps about 200 rows around its viewport; a list
        // that made one per table found would make thousands.
        let made = made_found(&view);
        assert!(made <= 250, "{made} rows made for {query}");
    }

    assert_eq!(
        shown.selected().as_deref(),
        Some("t49999"),
        "the selection left the table in front"
    );
    shown.search("");
    assert_eq!(shown.selected().as_deref(), Some("t49999"));
}

/// GtkListView rebuilds the rows around its scroll position on every
/// change, so a search over many schemas takes rows out of what it
/// finds once and puts rows in once, not once per schema.
#[gtk4::test]
fn a_search_over_a_hundred_schemas_changes_what_it_finds_twice() {
    let alpha = connection("Alpha", None);
    let shown = Shown::new(std::slice::from_ref(&alpha));
    let schemas: Vec<SchemaInfo> = (0..100).map(|at| schema(&format!("tenant_{at:03}"), at == 0)).collect();
    let objects: Vec<ObjectInfo> = schemas
        .iter()
        .flat_map(|schema| ["kiwi", "kumquat", "yuzu"].map(|name| object(&schema.name, name)))
        .collect();
    let view = SidebarView::new(|_| {}, every_affordance(), None);
    view.show(SidebarIndex::build(&objects, &schemas));
    shown.open(&alpha, &view);
    shown.search("k");
    let list_view = shown.inner().found.list_view.clone();
    wait_until(WAIT, || list_view.is_mapped() && built(&list_view) > 0).expect("the results on screen");
    let seen = Rc::new(RefCell::new(Vec::new()));
    let log = seen.clone();
    shown
        .inner()
        .results
        .connect_items_changed(move |_, position, removed, added| {
            log.borrow_mut().push((position, removed, added));
        });

    shown.search("ki");

    assert_eq!(found(&view), 100);
    assert_eq!(*seen.borrow(), [(0, 200, 0), (0, 0, 100)]);
}

#[gtk4::test]
fn a_list_and_its_searches_are_worked_out_off_the_gtk_thread() {
    adw::init().expect("libadwaita initialises under the test backend");
    let runtime = test_runtime();
    let view = SidebarView::new(|_| {}, every_affordance(), Some(runtime.tasks()));
    let objects: Vec<ObjectInfo> = names(20_000).iter().map(|name| object("public", name)).collect();

    view.show(SidebarIndex::build(&objects, &public()));
    assert_eq!(listed(&view), 0, "the GTK thread worked out the list's rows");
    wait_until(WAIT, || listed(&view) == 20_000).expect("the list's rows");
    for query in ["t1", "t19", "t19999"] {
        view.set_query(query);
    }

    assert!(!view.settled(), "the GTK thread worked out a search's rows");
    wait_until(WAIT, || view.settled()).expect("the last search's rows");
    assert_eq!(found(&view), 1);
    assert_eq!(listed(&view), 20_000, "a search changed the session's tables");
    view.shutdown();
}

#[gtk4::test]
fn activating_a_table_opens_it() {
    let alpha = connection("Alpha", None);
    let shown = Shown::new(std::slice::from_ref(&alpha));
    let (view, events) = session(&[object("public", "a"), object("public", "d")], every_affordance());
    shown.open(&alpha, &view);

    assert!(shown.pane().list_view.is_single_click_activate());
    shown.activate("d");

    assert_eq!(events.take(), [SidebarEvent::Open(table("d"))]);
}

#[gtk4::test]
fn activating_a_closed_connection_connects_and_an_open_one_comes_forward_as_it_is() {
    let (alpha, beta) = (connection("Alpha", None), connection("Beta", None));
    let shown = Shown::new(&[alpha.clone(), beta.clone()]);
    let (view, _) = session(&[object("public", "orders")], every_affordance());
    let key = shown.open(&alpha, &view);

    shown.activate("Beta");
    shown.activate("Alpha");

    assert_eq!(
        shown.fired(),
        [
            ("picker.connect".to_owned(), Some(beta.id.to_string())),
            ("win.show-session".to_owned(), target(&key)),
        ]
    );
    assert!(shown.row("Alpha").is_expanded(), "bringing Alpha forward folded it");
}

#[gtk4::test]
fn an_open_connection_offers_to_disconnect_from_its_row() {
    let alpha = connection("Alpha", None);
    let shown = Shown::new(&[alpha.clone(), connection("Beta", None)]);
    let (view, _) = session(&[object("public", "orders")], every_affordance());
    let key = shown.open(&alpha, &view);

    let eject = shown.row_widget("Alpha").imp().eject.clone();
    assert!(eject.is_visible());
    assert!(!shown.row_widget("Beta").imp().eject.is_visible());
    crate::test_support::assert_labelled(&eject).expect("the Disconnect button is named");
    eject.emit_clicked();
    drain_main_context();

    assert_eq!(shown.fired(), [("win.disconnect-session".to_owned(), target(&key))]);
}

#[gtk4::test]
fn a_connect_shows_a_spinner_and_offers_to_stop() {
    let alpha = connection("Alpha", None);
    let shown = Shown::new(std::slice::from_ref(&alpha));
    let unsaved = SessionKey::Saved(Uuid::new_v4());
    let alpha_key = SessionKey::Saved(alpha.id);

    shown.tree.set_connects(&[
        (alpha_key.clone(), "Alpha".to_owned()),
        (unsaved.clone(), "From the Dialog".to_owned()),
    ]);

    assert_eq!(shown.rows(), ["Alpha", "From the Dialog"]);
    assert!(shown.row_widget("From the Dialog").imp().spinner.is_visible());
    shown.menu("From the Dialog");
    let popover = shown.popover();
    assert!(popover.is_visible());
    let items = popover.menu_model().map(|menu| menu_items(&menu)).unwrap_or_default();
    assert_eq!(items.len(), 1, "{items:?}");
    assert_eq!(items[0].0, "win.stop-connecting");
    assert_eq!(
        items[0].1.as_ref().and_then(|target| target.get::<String>()),
        target(&unsaved)
    );
    popover.popdown();
    shown.activate("Alpha");
    assert!(shown.fired().is_empty(), "a connecting row connected again");

    shown.tree.set_connects(&[]);
    assert_eq!(shown.rows(), ["Alpha"], "a stopped connect left its row");
    assert!(!shown.row_widget("Alpha").imp().spinner.is_visible());
}

#[gtk4::test]
fn a_failed_connect_leaves_nothing_open_and_says_why() {
    let alpha = connection("Alpha", None);
    let shown = Shown::new(std::slice::from_ref(&alpha));
    let key = SessionKey::Saved(alpha.id);
    shown.tree.set_connects(&[(key.clone(), "Alpha".to_owned())]);

    shown.tree.set_connects(&[]);
    shown.tree.set_failure(&key, Some(("Alpha", "Connection refused")));

    let row = shown.row("Alpha");
    assert!(!row.is_expandable() && !row.is_expanded());
    let widget = shown.row_widget("Alpha");
    assert!(widget.imp().problem.is_visible());
    assert_eq!(
        widget.imp().problem.tooltip_text().as_deref(),
        Some("Connection refused")
    );
    shown.menu("Alpha");
    let actions = menu_actions(&shown.popover());
    assert_eq!(
        actions[..2],
        ["picker.connect", "win.show-connect-failure"],
        "{actions:?}"
    );
    shown.popover().popdown();

    shown.tree.set_failure(&key, None);
    assert!(!widget.imp().problem.is_visible());
}

/// A failed connect no saved connection names, a file or one typed in
/// the connect dialog, keeps a row of its own, which says why and goes
/// once the window lets the failure go.
#[gtk4::test]
fn a_failed_connect_with_no_saved_connection_keeps_a_row_until_let_go() {
    let alpha = connection("Alpha", None);
    let shown = Shown::new(std::slice::from_ref(&alpha));
    let key = SessionKey::File("file:///srv/shop.db".to_owned());

    shown.tree.set_failure(&key, Some(("shop.db", "No such file")));

    assert_eq!(shown.rows(), ["Alpha", "shop.db"], "the failure has no row");
    shown.menu("shop.db");
    let actions = menu_actions(&shown.popover());
    assert_eq!(
        actions,
        ["win.show-connect-failure", "win.forget-connect-failure"],
        "{actions:?}"
    );
    shown.popover().popdown();
    shown.activate("shop.db");
    assert_eq!(
        shown.fired(),
        [(
            "win.show-connect-failure".to_owned(),
            Some("file:file:///srv/shop.db".to_owned())
        )],
        "activating the row did not say why"
    );

    shown.tree.set_failure(&key, None);
    assert_eq!(shown.rows(), ["Alpha"], "a failure let go left its row");
}

#[gtk4::test]
fn a_lost_session_says_so_on_its_row() {
    let alpha = connection("Alpha", None);
    let shown = Shown::new(std::slice::from_ref(&alpha));
    let (view, _) = session(&[object("public", "orders")], every_affordance());
    let key = shown.open(&alpha, &view);
    let widget = shown.row_widget("Alpha");

    shown.tree.set_session_state(&key, SessionRowState::Busy);
    assert!(widget.imp().spinner.is_visible() && !widget.imp().eject.is_visible());
    shown
        .tree
        .set_session_state(&key, SessionRowState::Trouble("The server went away".to_owned()));
    assert!(widget.imp().problem.is_visible() && !widget.imp().spinner.is_visible());
    assert_eq!(
        widget.imp().problem.tooltip_text().as_deref(),
        Some("The server went away")
    );
    shown.tree.set_session_state(&key, SessionRowState::Ready);
    assert!(widget.imp().eject.is_visible() && !widget.imp().problem.is_visible());
}

#[gtk4::test]
fn a_closed_session_lists_nothing_and_leaves_the_others_open() {
    let (alpha, beta) = (connection("Alpha", None), connection("Beta", None));
    let shown = Shown::new(&[alpha.clone(), beta.clone()]);
    let (alpha_view, _) = session(&[object("public", "orders")], every_affordance());
    let (beta_view, _) = session(&[object("public", "users")], every_affordance());
    let key = shown.open(&alpha, &alpha_view);
    shown.open(&beta, &beta_view);
    shown.tree.select(Some(&key), Some(&table("orders")));

    shown.tree.remove_session(&key);

    assert_eq!(shown.rows(), ["Alpha", "Beta", "public", "users"]);
    assert!(!shown.row("Alpha").is_expandable());
    assert_eq!(shown.selected(), None, "the closed session kept its row selected");
}

#[gtk4::test]
fn a_file_no_saved_connection_names_has_a_row_of_its_own() {
    let shown = Shown::new(&[connection("Alpha", None)]);
    let key = SessionKey::File("file:///home/me/sales.db".to_owned());
    let (view, _) = session(&[object("main", "orders")], every_affordance());

    shown.tree.add_session(&key, "sales.db", &view);

    assert_eq!(
        shown.rows(),
        ["Alpha", "sales.db", "main", "orders"],
        "a lone schema stays folded"
    );
    shown.search("sales");
    assert_eq!(shown.rows()[0], "sales.db");
    shown.search("");
    shown.tree.remove_session(&key);
    assert_eq!(shown.rows(), ["Alpha"]);
}

#[gtk4::test]
fn the_tree_selects_the_table_in_front_or_its_connection() {
    let alpha = connection("Alpha", Some("Work"));
    let shown = Shown::new(&[alpha.clone(), connection("Beta", None)]);
    let (view, _) = session(
        &[
            object("public", "orders"),
            object("public", "users"),
            object("sales", "leads"),
        ],
        every_affordance(),
    );
    let key = shown.open(&alpha, &view);
    shown.row("Work").set_expanded(false);

    shown.tree.select(Some(&key), None);
    assert_eq!(
        shown.selected().as_deref(),
        Some("Alpha"),
        "the group was not opened to the connection"
    );

    shown.tree.select(Some(&key), Some(&table("users")));
    assert_eq!(shown.selected().as_deref(), Some("users"));

    shown.tree.select(Some(&SessionKey::Saved(Uuid::new_v4())), None);
    assert_eq!(
        shown.selected(),
        None,
        "a connection the tree lacks kept a row selected"
    );
}

#[gtk4::test]
fn the_selection_follows_the_tab_and_survives_a_new_list() {
    let alpha = connection("Alpha", None);
    let shown = Shown::new(std::slice::from_ref(&alpha));
    let (view, _) = session(
        &[object("public", "orders"), object("public", "users")],
        every_affordance(),
    );
    let key = shown.open(&alpha, &view);

    shown.tree.select(Some(&key), Some(&table("users")));
    tables(&view, &["accounts", "orders", "users"]);
    assert_eq!(
        shown.selected().as_deref(),
        Some("users"),
        "the new list dropped the selection"
    );

    shown.row("public").set_expanded(false);
    shown.tree.select(Some(&key), Some(&table("users")));
    assert_eq!(
        shown.selected().as_deref(),
        Some("Alpha"),
        "the same tab opened a row the user folded"
    );

    shown.tree.select(None, None);
    assert_eq!(shown.selected(), None, "no tab, yet a row selected");
}

#[gtk4::test]
fn secondary_press_selects_the_row_and_opens_its_menu() {
    let alpha = connection("Alpha", None);
    let shown = Shown::new(std::slice::from_ref(&alpha));
    let (view, events) = session(
        &["a", "b", "c", "d", "e", "f"].map(|name| object("public", name)),
        every_affordance(),
    );
    shown.open(&alpha, &view);
    let position = shown.position("f");

    let claimed = shown.inner().pressed(
        Which::Tree,
        position,
        gdk::BUTTON_SECONDARY,
        gdk::ModifierType::empty(),
        None,
    );

    assert!(claimed, "the row's own click would also run");
    assert_eq!(shown.selected().as_deref(), Some("f"));
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
    WidgetExt::activate_action(
        &popover,
        "sidebar.open-in-new-tab",
        Some(&ObjectKey(table("f")).to_variant()),
    )
    .expect("the session's actions reach the menu");
    popover.popdown();
    assert_eq!(events.take(), [SidebarEvent::OpenInNewTab(table("f"))]);
}

#[gtk4::test]
fn ctrl_click_and_middle_click_open_a_new_tab() {
    let alpha = connection("Alpha", None);
    let shown = Shown::new(std::slice::from_ref(&alpha));
    let (view, events) = session(&["a", "b", "c"].map(|name| object("public", name)), every_affordance());
    shown.open(&alpha, &view);
    let inner = shown.inner();

    let press =
        |name: &str, button, modifiers| inner.pressed(Which::Tree, shown.position(name), button, modifiers, None);
    assert!(press("b", gdk::BUTTON_PRIMARY, gdk::ModifierType::CONTROL_MASK));
    assert!(!press("b", gdk::BUTTON_PRIMARY, gdk::ModifierType::empty()));
    assert!(!press("c", gdk::BUTTON_MIDDLE, gdk::ModifierType::empty()));
    assert!(inner.released(gdk::BUTTON_MIDDLE));

    assert_eq!(
        events.take(),
        [
            SidebarEvent::OpenInNewTab(table("b")),
            SidebarEvent::OpenInNewTab(table("c"))
        ]
    );
}

#[gtk4::test]
fn a_middle_click_opens_the_table_it_was_pressed_on() {
    let alpha = connection("Alpha", None);
    let shown = Shown::new(std::slice::from_ref(&alpha));
    let (view, events) = session(&["a", "b", "c"].map(|name| object("public", name)), every_affordance());
    shown.open(&alpha, &view);
    let inner = shown.inner();
    assert!(
        !inner.released(gdk::BUTTON_MIDDLE),
        "a release with no press opened a table"
    );
    let position = shown.position("b");

    inner.pressed(
        Which::Tree,
        position,
        gdk::BUTTON_MIDDLE,
        gdk::ModifierType::empty(),
        None,
    );
    // A refresh lands between the press and the release, and puts
    // another table where the pressed row was.
    tables(&view, &["a", "aa", "b", "c"]);

    assert!(inner.released(gdk::BUTTON_MIDDLE));
    assert_eq!(events.take(), [SidebarEvent::OpenInNewTab(table("b"))]);
}

#[gtk4::test]
fn the_connection_menu_holds_the_pickers_items() {
    let (alpha, beta) = (connection("Alpha", None), connection("Beta", Some("Work")));
    let shown = Shown::new(&[alpha.clone(), beta.clone()]);
    let (view, _) = session(&[object("public", "orders")], every_affordance());
    shown.open(&alpha, &view);
    shown.row("Work").set_expanded(true);
    let popover = shown.popover();

    shown.menu("Beta");
    let closed = popover.menu_model().map(|menu| menu_items(&menu)).unwrap_or_default();
    popover.popdown();
    shown.menu("Alpha");
    let open = menu_actions(&popover);
    let group = popover
        .menu_model()
        .map(|menu| menu_items(&menu))
        .unwrap_or_default()
        .into_iter()
        .find(|(action, _)| action == "picker-row.group");
    popover.popdown();

    let actions: Vec<&str> = closed.iter().map(|(action, _)| action.as_str()).collect();
    for action in [
        "picker.connect",
        "picker.edit",
        "picker.duplicate",
        "picker-row.color",
        "picker-row.group",
        "picker.new-group",
        "picker.delete",
    ] {
        assert!(actions.contains(&action), "{action} missing from {actions:?}");
    }
    let id = beta.id.to_string();
    assert!(
        closed
            .iter()
            .filter(|(action, _)| action.starts_with("picker."))
            .all(
                |(_, target)| target.as_ref().and_then(|target| target.get::<String>()).as_deref() == Some(id.as_str())
            )
    );
    assert_eq!(
        open[..3],
        ["win.new-query-in", "win.refresh-in", "win.disconnect-session"],
        "{open:?}"
    );
    assert!(!open.contains(&"picker.connect".to_owned()));
    assert!(open.contains(&"picker.delete".to_owned()));
    assert!(group.is_some(), "Move to Group has no choices");
    let state = WidgetExt::activate_action(&popover, "picker-row.group", Some(&"Work".to_variant()));
    assert!(state.is_ok(), "the menu's choices reach no action");
}

#[gtk4::test]
fn the_schema_menu_follows_the_dialect() {
    let alpha = connection("Alpha", None);
    let shown = Shown::new(std::slice::from_ref(&alpha));
    let (view, events) = session(
        &[object("public", "orders"), object("sales", "leads")],
        every_affordance(),
    );
    shown.open(&alpha, &view);
    let popover = shown.popover();

    shown.menu("sales");
    assert_eq!(
        menu_actions(&popover),
        ["sidebar.new-table", "sidebar.show-schema-diagram"]
    );
    for action in ["sidebar.new-table", "sidebar.show-schema-diagram"] {
        WidgetExt::activate_action(&popover, action, Some(&Some("sales").to_variant())).expect(action);
    }
    popover.popdown();
    assert_eq!(
        events.take(),
        [
            SidebarEvent::NewTable(Some("sales".to_owned())),
            SidebarEvent::ShowDiagram(Some("sales".to_owned()))
        ]
    );

    view.set_affordances(SidebarAffordances {
        can_create_table: false,
        ..every_affordance()
    });
    shown.menu("sales");
    assert_eq!(menu_actions(&popover), ["sidebar.show-schema-diagram"]);
    popover.popdown();
}

#[gtk4::test]
fn collections_and_keys_offer_no_er_diagram() {
    let (documents, cache) = (connection("Docs", None), connection("Cache", None));
    let shown = Shown::new(&[documents.clone(), cache.clone()]);
    let (collections, collection_events) = session(
        &[object("shop", "orders")],
        SidebarAffordances {
            can_create_table: false,
            can_edit_structure: false,
            speaks_sql: false,
            ..every_affordance()
        },
    );
    collections.hold_collections();
    let (keys, key_events) = session(&[], every_affordance());
    keys.hold_keys(|| {});
    keys.show_keys(
        SidebarIndex::keys(
            &[ObjectInfo {
                schema: None,
                name: "user:1".to_owned(),
                kind: ObjectKind::Key(KeyKind::Hash),
            }],
            "db0".to_owned(),
        ),
        false,
    );
    shown.open(&documents, &collections);
    shown.open(&cache, &keys);
    let popover = shown.popover();

    shown.menu("shop");
    assert!(!popover.is_visible(), "documents have no keys to draw");
    shown.menu("db0");
    assert!(!popover.is_visible(), "keys have no diagram");
    keys.actions()
        .activate_action("show-schema-diagram", Some(&None::<String>.to_variant()));
    collections
        .actions()
        .activate_action("show-schema-diagram", Some(&Some("shop").to_variant()));
    assert!(collection_events.take().is_empty() && key_events.take().is_empty());
}

#[gtk4::test]
fn context_menu_action_carries_object_key() {
    let (view, events) = session(
        &[object("public", "orders"), object("public", "users")],
        every_affordance(),
    );
    let actions = view.actions();
    let key = ObjectKey(table("users")).to_variant();

    for action in [
        "open-in-new-tab",
        "edit-structure",
        "show-create-table",
        "import-csv",
        "drop-table",
    ] {
        actions.activate_action(action, Some(&key));
    }
    actions.activate_action("drop-table", Some(&(None::<String>, String::new()).to_variant()));
    actions.activate_action("drop-table", Some(&ObjectKey(table("gone")).to_variant()));

    assert_eq!(
        events.take(),
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
    let (view, events) = session(
        &[object("public", "orders")],
        SidebarAffordances {
            read_only: true,
            ..every_affordance()
        },
    );

    view.actions()
        .activate_action("drop-table", Some(&ObjectKey(table("orders")).to_variant()));
    view.actions()
        .activate_action("new-table", Some(&Some("public".to_owned()).to_variant()));

    assert!(events.take().is_empty());
}

/// The scroll marks the row the list focuses next; the grab carries the
/// focus to its expander.
fn focus_row(shown: &Shown, name: &str) {
    let list_view = shown.pane().list_view.clone();
    list_view.scroll_to(shown.position(name), gtk::ListScrollFlags::FOCUS, None);
    list_view.grab_focus();
    wait_until(WAIT, || {
        let focused = gtk::prelude::GtkWindowExt::focus(&shown.window);
        focused.is_some_and(|widget| {
            widget
                .downcast_ref::<gtk::TreeExpander>()
                .and_then(|expander| expander.list_row())
                .and_then(|row| item_title(row.upcast_ref()))
                .as_deref()
                == Some(name)
        })
    })
    .expect("the row's expander focused");
}

#[gtk4::test]
fn keyboard_menu_falls_back_to_the_selected_row() {
    let alpha = connection("Alpha", None);
    let shown = Shown::new(std::slice::from_ref(&alpha));
    let (view, _) = session(
        &["a", "b", "c", "d"].map(|name| object("public", name)),
        every_affordance(),
    );
    let key = shown.open(&alpha, &view);
    shown.tree.select(Some(&key), Some(&table("c")));
    // Showing the window focuses its first control, which may be a row.
    gtk::prelude::GtkWindowExt::set_focus(&shown.window, None::<&gtk::Widget>);

    WidgetExt::activate_action(&shown.tree.widget(), "tree.context-menu", None).expect("the action");

    let popover = shown.popover();
    assert_eq!(menu_table(&popover), Some(ObjectKey(table("c"))));
    assert!(popover.pointing_to().0, "the menu points at nothing");
    popover.popdown();
}

#[gtk4::test]
fn keyboard_menu_opens_for_the_focused_row() {
    let alpha = connection("Alpha", None);
    let shown = Shown::new(std::slice::from_ref(&alpha));
    let (view, _) = session(
        &["a", "b", "c", "d"].map(|name| object("public", name)),
        every_affordance(),
    );
    let key = shown.open(&alpha, &view);
    wait_until(WAIT, || shown.pane().list_view.height() > 0).expect("the list laid out");

    // An editor tab in front selects the connection's row.
    focus_row(&shown, "c");
    shown.tree.select(Some(&key), None);
    WidgetExt::activate_action(&shown.tree.widget(), "tree.context-menu", None).expect("the action");
    assert_eq!(menu_table(&shown.popover()), Some(ObjectKey(table("c"))));
    shown.popover().popdown();

    // A table tab in front selects its own row, not the focused one.
    focus_row(&shown, "c");
    shown.tree.select(Some(&key), Some(&table("a")));
    WidgetExt::activate_action(&shown.tree.widget(), "tree.context-menu", None).expect("the action");
    assert_eq!(menu_table(&shown.popover()), Some(ObjectKey(table("c"))));
    shown.popover().popdown();
}

#[gtk4::test]
fn the_menu_keys_reach_the_context_menu_action() {
    let shown = Shown::new(&[connection("Alpha", None)]);

    let bound = crate::test_support::shortcut_keys::owner_controller(
        &shown.tree.widget(),
        crate::application::ShortcutOwner::ConnectionTree,
    )
    .expect("the tree's keys");
    let actions: Vec<String> = crate::test_support::shortcut_keys::shortcuts(&bound)
        .into_iter()
        .filter_map(|shortcut| shortcut.action().and_downcast::<gtk::NamedAction>())
        .map(|action| action.action_name().to_string())
        .collect();

    assert_eq!(actions, ["tree.context-menu", "tree.context-menu"]);
}

#[gtk4::test]
fn the_keyboard_focus_is_on_the_rows_expander() {
    let shown = Shown::new(&[connection("Alpha", Some("Work"))]);

    focus_row(&shown, "Work");

    let item = shown.row_widget("Work").imp().item.upgrade().expect("the row's item");
    assert!(!item.is_focusable(), "the row takes the focus the expander's keys need");
}

/// These press real keys on the X display every test shares; nextest runs
/// them with no other test beside them.
mod real_keys {
    use gtk4::gdk;
    use gtk4::prelude::*;

    use super::{Shown, connection, focus_row};
    use crate::test_support::{KeyInjector, wait_until};
    use crate::ui::session_window::tests::WAIT;

    #[gtk4::test]
    fn plus_and_minus_open_and_fold_a_group() {
        let shown = Shown::new(&[connection("Alpha", Some("Work")), connection("Beta", None)]);
        KeyInjector::focus_only(&shown.window);
        wait_until(WAIT, || shown.window.is_active()).expect("the window to take the focus");
        let keys = KeyInjector::connect().expect("an X11 display");
        focus_row(&shown, "Work");

        keys.press(gdk::Key::KP_Add, gdk::ModifierType::empty())
            .expect("the key press");
        wait_until(WAIT, || shown.row("Work").is_expanded()).expect("+ to open the group");
        keys.press(gdk::Key::KP_Subtract, gdk::ModifierType::empty())
            .expect("the key press");
        wait_until(WAIT, || !shown.row("Work").is_expanded()).expect("- to fold the group");
    }
}

fn front_table(test: &TestWindow) -> Option<String> {
    let tree = crate::ui::workspace::tests::shell_of(&test.workspace()).tree()?;
    let inner = &tree.inner;
    inner.tree.selection.selected_item().and_then(|item| item_title(&item))
}

fn shown_tables(workspace: &crate::ui::workspace::Workspace) -> Option<u32> {
    workspace.read(|model| listed(&model.sidebar))
}

#[gtk4::test]
fn the_tree_selects_the_table_in_front_and_the_connection_for_an_editor() {
    let test = TestWindow::connected_with("SidebarSync", |script| {
        script.list_objects.once(FakeReply::ok(vec![
            object("public", "orders"),
            object("public", "users"),
        ]));
    });
    let workspace = test.workspace();
    wait_until(WAIT, || shown_tables(&workspace) == Some(2)).expect("the tables listed");

    workspace.with_model(|model| {
        model.open_tab(TabSpec::Table {
            table: table("users"),
            page: TablePage::first(100),
            filter: crate::ui::browse_tab::TableFilter::Remembered,
        })
    });
    wait_until(WAIT, || front_table(&test).as_deref() == Some("users")).expect("the table's row selected");

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
    wait_until(WAIT, || front_table(&test).as_deref() == Some(test.saved.name.as_str()))
        .expect("the connection's row selected for the editor");
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

    wait_until(WAIT, || shown_tables(&workspace) == Some(2)).expect("the second schema's table listed");
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
    wait_until(WAIT, || shown_tables(&workspace) == Some(2)).expect("the tables listed");
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
    assert_eq!(shown_tables(&workspace), Some(2), "the failure emptied the list");

    WidgetExt::activate_action(&test.window, "win.refresh-tables", None).expect("the banner's Retry");

    wait_until(WAIT, || shown_tables(&workspace) == Some(3)).expect("the list read again");
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
    wait_until(WAIT, || shown_tables(&workspace) == Some(1)).expect("the table listed");
    let button = crate::ui::workspace::tests::shell_of(&workspace)
        .imp()
        .refresh_tables_button
        .get();
    assert_eq!(button.action_name().as_deref(), Some("win.refresh-tables"));
    crate::test_support::assert_labelled(&button).expect("the refresh button is named");

    button.emit_clicked();

    wait_until(WAIT, || shown_tables(&workspace) == Some(2)).expect("the new table listed");
}

#[gtk4::test]
fn ddl_run_in_the_editor_reads_the_tables_again() {
    use tablepro_core::EditorSession;
    use tablepro_test_support::{FakeEditorSession, FakeRun, Replies};

    let mut runs = Replies::default();
    runs.always(FakeRun::completed(Vec::new()));
    let editor_session: Arc<dyn EditorSession> = Arc::new(FakeEditorSession::new(runs));
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
    wait_until(WAIT, || shown_tables(&workspace) == Some(1)).expect("the table listed");
    workspace.with_model(|model| model.open_editor_tab(Some("CREATE TABLE orders (id int)".to_owned())));
    let editor = crate::ui::session_window::tests::editors(&test.window)
        .pop()
        .expect("the editor tab");

    editor.run();

    wait_until(WAIT, || shown_tables(&workspace) == Some(2)).expect("the created table listed without a reconnect");
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
    wait_until(WAIT, || shown_tables(&workspace) == Some(1)).expect("the table listed");
    let session = workspace
        .read(|model| model.context.active.get())
        .flatten()
        .expect("the session");

    let listed = || session.catalog().subscribe(ObjectScope::AllSchemas).borrow().clone();
    let before = listed().generation;

    // What a reconnect does once the new connection read its catalog.
    session.catalog().commit(Vec::new(), vec![object("public", "users")]);

    wait_until(Duration::from_secs(10), || shown_tables(&workspace) == Some(2))
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
    wait_until(WAIT, || shown_tables(&workspace) == Some(1)).expect("the table listed");
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
    assert_eq!(shown_tables(&workspace), Some(1), "the failure emptied the list");
}
