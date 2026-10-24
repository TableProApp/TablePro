use std::cell::RefCell;
use std::rc::Rc;
use std::time::{Duration, SystemTime};

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gio, glib};
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_storage::query_history::{NewEntry, Outcome};
use tablepro_storage::{ConnectionStore, QueryHistory, SavedConnection, StoragePaths};
use tokio::sync::watch;
use uuid::Uuid;

use super::*;
use crate::runtime::AppRuntime;
use crate::services::history_preferences::HistoryPreferences;
use crate::test_support::{descendants, drain_main_context, test_runtime, wait_until};
use crate::ui::file_reveal::RecordingRevealer;

/// Long enough that a loaded machine cannot decide the outcome; a
/// passing test returns as soon as its condition holds.
pub(super) const WAIT: Duration = Duration::from_secs(30);

pub(super) struct Harness {
    pub runtime: AppRuntime,
    pub service: HistoryService,
    pub store: QueryHistory,
    pub connections: ConnectionStore,
    pub revealer: Rc<RecordingRevealer>,
    pub window: adw::Window,
    _root: tempfile::TempDir,
}

impl Harness {
    pub fn new() -> Self {
        Self::revealing_with(RecordingRevealer::succeeding())
    }

    pub fn revealing_with(revealer: RecordingRevealer) -> Self {
        crate::register_test_resources();
        let runtime = test_runtime();
        let root = tempfile::tempdir().expect("tempdir");
        let paths = StoragePaths::under(root.path(), "tablepro-test", "app.tablepro.TablePro.Devel");
        let preferences = HistoryPreferences {
            retention_days: watch::channel(0).1,
            save: watch::channel(true).1,
        };
        let connections = ConnectionStore::new(&paths);
        let service = HistoryService::start(paths, preferences, &runtime.tasks());
        let availability = service.availability();
        wait_until(WAIT, || availability.borrow().is_ready()).expect("the history to open");
        let store = service.store().expect("the history");
        let window = adw::Window::new();
        window.set_default_size(640, 640);
        window.present();
        Self {
            runtime,
            service,
            store,
            connections,
            revealer: Rc::new(revealer),
            window,
            _root: root,
        }
    }

    pub fn record(&self, query: &str) -> i64 {
        self.record_on(query, Uuid::nil(), "local")
    }

    pub fn record_on(&self, query: &str, connection: Uuid, name: &str) -> i64 {
        block_on(
            &self.runtime,
            self.store.record(NewEntry {
                query: query.to_owned(),
                driver_id: "postgres".to_owned(),
                connection_id: connection,
                connection_name: name.to_owned(),
                executed_at: SystemTime::now(),
                duration_ms: Some(1),
                rows_affected: Some(1),
                outcome: Outcome::Success,
            }),
        )
        .expect("record")
    }

    pub fn pin(&self, id: i64) {
        block_on(&self.runtime, self.store.set_pinned(id, true)).expect("pin");
    }

    pub fn save_connection(&self, id: Uuid, name: &str) {
        self.connections
            .upsert_blocking(SavedConnection {
                id,
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
                group: None,
                tags: Vec::new(),
                icon: None,
                options: Default::default(),
            })
            .expect("save the connection");
    }

    pub fn dialog(&self) -> HistoryDialog {
        self.dialog_for(None)
    }

    pub fn dialog_for(&self, preferred_connection: Option<Uuid>) -> HistoryDialog {
        HistoryDialog::new(HistoryDialogInit {
            history: self.service.clone(),
            connections: self.connections.clone(),
            preferred_connection,
            revealer: self.revealer.clone(),
            tasks: self.runtime.tasks(),
        })
    }

    /// A dialog on the test window, so its list view lays out rows.
    pub fn presented_dialog(&self) -> HistoryDialog {
        self.present(self.dialog())
    }

    pub fn present(&self, dialog: HistoryDialog) -> HistoryDialog {
        dialog.present(Some(&self.window));
        dialog
    }

    pub fn stored_queries(&self) -> Vec<String> {
        block_on(
            &self.runtime,
            self.store
                .search_page(&HistoryQuery::default(), HistoryPageRequest::first(100)),
        )
        .expect("search")
        .entries
        .into_iter()
        .map(|entry| entry.query)
        .collect()
    }
}

impl Drop for Harness {
    fn drop(&mut self) {
        crate::test_support::drop_focus(&self.window);
        self.window.destroy();
        drain_main_context();
    }
}

/// The test drives the runtime from outside it, which is the one place
/// blocking on it cannot deadlock.
#[expect(
    clippy::disallowed_methods,
    reason = "a GTK test has no runtime of its own, so it drives the app's from outside"
)]
pub(super) fn block_on<F: std::future::Future>(runtime: &AppRuntime, future: F) -> F::Output {
    runtime.tasks().handle().block_on(future)
}

pub(super) fn entries(dialog: &HistoryDialog) -> Vec<String> {
    let Some(parts) = dialog.imp().parts.get() else {
        return Vec::new();
    };
    parts
        .entries
        .iter::<HistoryEntryObject>()
        .filter_map(Result::ok)
        .filter_map(|entry| entry.query())
        .collect()
}

pub(super) fn rows(dialog: &HistoryDialog) -> Vec<HistoryRow> {
    descendants(&dialog.imp().list_view.get())
        .into_iter()
        .filter_map(|widget| widget.downcast::<HistoryRow>().ok())
        .filter(|row| row.entry().is_some())
        .collect()
}

pub(super) fn row_titled(dialog: &HistoryDialog, title: &str) -> Option<HistoryRow> {
    rows(dialog).into_iter().find(|row| row.title() == title)
}

/// What the menu's item called `label` activates, and with what target.
pub(super) fn menu_item(menu: &gio::MenuModel, label: &str) -> Option<(String, Option<glib::Variant>)> {
    for index in 0..menu.n_items() {
        if let Some(section) = menu.item_link(index, gio::MENU_LINK_SECTION)
            && let Some(found) = menu_item(&section, label)
        {
            return Some(found);
        }
        let text = menu.item_attribute_value(index, gio::MENU_ATTRIBUTE_LABEL, Some(glib::VariantTy::STRING));
        if text.and_then(|text| text.get::<String>()).as_deref() == Some(label) {
            let action = menu
                .item_attribute_value(index, gio::MENU_ATTRIBUTE_ACTION, Some(glib::VariantTy::STRING))?
                .get::<String>()?;
            let target = menu.item_attribute_value(index, gio::MENU_ATTRIBUTE_TARGET, None);
            return Some((action, target));
        }
    }
    None
}

/// Every row has the same check box, Pin and Delete, so each says which
/// query it acts on.
#[gtk4::test]
fn each_rows_controls_name_their_query() {
    let harness = Harness::new();
    harness.record("SELECT 1");
    let dialog = harness.presented_dialog();
    wait_until(WAIT, || !rows(&dialog).is_empty()).expect("the row");
    let row = rows(&dialog).remove(0);

    let controls: Vec<gtk::Widget> = descendants(&row)
        .into_iter()
        .filter(|widget| widget.is::<gtk::CheckButton>() || widget.is::<gtk::Button>())
        .collect();
    assert_eq!(controls.len(), 3, "the check box, Pin and Delete");
    for control in controls {
        assert!(
            gtk::test_accessible_has_relation(&control, gtk::AccessibleRelation::DescribedBy),
            "{} does not name its query",
            control.type_().name()
        );
    }
}

#[gtk4::test]
fn list_view_shows_pinned_section_header() {
    let harness = Harness::new();
    let pinned = harness.record("SELECT pinned");
    harness.pin(pinned);
    harness.record("SELECT plain");

    let dialog = harness.presented_dialog();
    let list_view = dialog.imp().list_view.get();
    let header = |text: &str| {
        descendants(&list_view)
            .into_iter()
            .filter_map(|widget| widget.downcast::<gtk::Label>().ok())
            .find(|label| label.has_css_class("heading") && label.label() == text)
    };
    wait_until(WAIT, || header("Pinned").is_some() && header("All Queries").is_some())
        .expect("a header for each section");

    let top_of = |widget: Option<gtk::Widget>| {
        widget
            .filter(|widget| widget.height() > 0)
            .and_then(|widget| widget.compute_point(&list_view, &graphene::Point::new(0.0, 0.0)))
            .map(|point| point.y())
    };
    let order = || {
        [
            top_of(header("Pinned").map(Cast::upcast)),
            top_of(row_titled(&dialog, "SELECT pinned").map(Cast::upcast)),
            top_of(header("All Queries").map(Cast::upcast)),
            top_of(row_titled(&dialog, "SELECT plain").map(Cast::upcast)),
        ]
    };
    let in_order = || {
        let tops = order();
        tops.iter().all(Option::is_some) && tops.windows(2).all(|pair| pair[0] < pair[1])
    };
    let laid_out = wait_until(WAIT, in_order);
    assert!(
        laid_out.is_ok(),
        "headers and rows are not in section order: {:?}",
        order()
    );
    dialog.close();
}

#[gtk4::test]
fn edge_reached_appends_next_page() {
    let harness = Harness::new();
    let total = PAGE_SIZE + 30;
    for index in 0..total {
        harness.record(&format!("SELECT {index}"));
    }

    let dialog = harness.dialog();
    wait_until(WAIT, || entries(&dialog).len() == PAGE_SIZE).expect("the first page");

    let scroll = dialog.imp().scroll.get();
    scroll.emit_by_name::<()>("edge-reached", &[&gtk::PositionType::Bottom]);
    // A second edge while the first read is out must not read the same
    // page again.
    scroll.emit_by_name::<()>("edge-reached", &[&gtk::PositionType::Bottom]);
    wait_until(WAIT, || entries(&dialog).len() >= total).expect("the next page");
    scroll.emit_by_name::<()>("edge-reached", &[&gtk::PositionType::Bottom]);
    crate::test_support::drain_main_context();
    std::thread::sleep(Duration::from_millis(50));
    crate::test_support::drain_main_context();

    let shown = entries(&dialog);
    assert_eq!(shown.len(), total, "a page was read twice or past the end");
    let mut distinct = shown.clone();
    distinct.sort();
    distinct.dedup();
    assert_eq!(distinct.len(), total);
    assert_eq!(
        shown.first().map(String::as_str),
        Some(format!("SELECT {}", total - 1).as_str())
    );
}

#[gtk4::test]
fn refresh_keeps_rows_until_results_arrive() {
    let harness = Harness::new();
    harness.record("SELECT alpha");
    harness.record("SELECT beta");
    let dialog = harness.presented_dialog();
    wait_until(WAIT, || entries(&dialog).len() == 2).expect("the first page");

    dialog.imp().search_entry.set_text("alpha");
    dialog.refresh();

    assert_eq!(entries(&dialog).len(), 2, "the rows went before the new ones came");
    assert_eq!(dialog.imp().stack.visible_child_name().as_deref(), Some("list"));
    wait_until(WAIT, || entries(&dialog) == ["SELECT alpha"]).expect("the search result");
    dialog.close();
}

#[gtk4::test]
fn row_context_menu_open_emits_output_for_clicked_id() {
    let harness = Harness::new();
    harness.record("SELECT first");
    harness.record("SELECT second");
    let dialog = harness.presented_dialog();
    let chosen: Rc<RefCell<Vec<(QueryDestination, String)>>> = Rc::default();
    let sink = chosen.clone();
    dialog.connect_query_chosen(move |_, destination, query| sink.borrow_mut().push((destination, query)));
    wait_until(WAIT, || row_titled(&dialog, "SELECT first").is_some()).expect("the rows");
    let row = row_titled(&dialog, "SELECT first").expect("the row");

    let controllers = row.observe_controllers();
    let gesture = (0..controllers.n_items())
        .filter_map(|index| controllers.item(index).and_downcast::<gtk::GestureClick>())
        .find(|gesture| gesture.button() == gtk::gdk::BUTTON_SECONDARY)
        .expect("a row answers a right-click");
    gesture.emit_by_name::<()>("pressed", &[&1i32, &4.0f64, &4.0f64]);

    let menu = dialog.imp().parts.get().expect("parts").menu.clone();
    assert!(menu.is_visible(), "the menu did not open");
    let model = menu.menu_model().expect("a menu model");
    let (action, target) = menu_item(&model, "Open in New Tab").expect("an Open item");
    menu.popdown();
    dialog.activate_action(&action, target.as_ref()).expect("the action");

    assert_eq!(
        *chosen.borrow(),
        [(QueryDestination::NewTab, "SELECT first".to_owned())]
    );
}

pub(super) fn filter_labels(dialog: &HistoryDialog) -> Vec<String> {
    let Some(parts) = dialog.imp().parts.get() else {
        return Vec::new();
    };
    let labels = parts.filters.connections().labels();
    (0..labels.n_items())
        .filter_map(|position| labels.string(position))
        .map(String::from)
        .collect()
}

/// The text of the toast on screen, and its button.
pub(super) fn toast(window: &adw::Window, text: &str) -> Option<gtk::Button> {
    let toast = descendants(window)
        .into_iter()
        .find(|widget| widget.type_().name() == "AdwToastWidget" && has_label(widget, text))?;
    descendants(&toast)
        .into_iter()
        .filter_map(|widget| widget.downcast::<gtk::Button>().ok())
        .find(|button| button.label().is_some_and(|label| label.contains("Undo")))
}

fn has_label(root: &gtk::Widget, text: &str) -> bool {
    descendants(root)
        .into_iter()
        .filter_map(|widget| widget.downcast::<gtk::Label>().ok())
        .any(|label| label.label() == text)
}

#[gtk4::test]
fn filter_lists_saved_connection_without_live_session() {
    let harness = Harness::new();
    let (saved, unsaved) = (Uuid::new_v4(), Uuid::new_v4());
    harness.record_on("SELECT 1", saved, "Warehouse (old name)");
    harness.record_on("SELECT 2", unsaved, "Scratch");
    harness.save_connection(saved, "Warehouse");

    let dialog = harness.dialog();

    wait_until(WAIT, || filter_labels(&dialog).len() == 3).expect("the connections");
    assert_eq!(filter_labels(&dialog), ["All Connections", "Scratch", "Warehouse"]);
    connection_drop_down(&dialog).set_selected(2);
    wait_until(WAIT, || entries(&dialog) == ["SELECT 1"]).expect("the saved connection's queries");
}

#[gtk4::test]
fn filter_defaults_to_presenting_window_connection() {
    let harness = Harness::new();
    let (other, presenting) = (Uuid::new_v4(), Uuid::new_v4());
    harness.record_on("SELECT other", other, "Other");
    harness.record_on("SELECT presenting", presenting, "Presenting");

    let dialog = harness.dialog_for(Some(presenting));

    wait_until(WAIT, || entries(&dialog) == ["SELECT presenting"]).expect("the presenting connection's queries");
    let selected = connection_drop_down(&dialog).selected();
    assert_eq!(filter_labels(&dialog)[selected as usize], "Presenting");

    let without_history = harness.dialog_for(Some(Uuid::new_v4()));
    wait_until(WAIT, || entries(&without_history).len() == 2).expect("every query");
    assert_eq!(connection_drop_down(&without_history).selected(), 0);
}

#[gtk4::test]
fn delete_undo_restores_row() {
    let harness = Harness::new();
    harness.record("SELECT kept");
    let gone = harness.record("SELECT gone");
    let dialog = harness.presented_dialog();
    wait_until(WAIT, || entries(&dialog).len() == 2).expect("the first page");

    dialog
        .activate_action("history.delete", Some(&gone.to_variant()))
        .expect("the action");

    wait_until(WAIT, || entries(&dialog) == ["SELECT kept"]).expect("the row to go");
    assert_eq!(harness.stored_queries(), ["SELECT kept"]);
    wait_until(WAIT, || toast(&harness.window, "1 query deleted").is_some()).expect("a toast");
    toast(&harness.window, "1 query deleted").expect("Undo").emit_clicked();

    wait_until(WAIT, || entries(&dialog) == ["SELECT gone", "SELECT kept"]).expect("the row back");
    assert_eq!(harness.stored_queries(), ["SELECT gone", "SELECT kept"]);
    let found = block_on(
        &harness.runtime,
        harness
            .store
            .search_page(&HistoryQuery::from_input("gone"), HistoryPageRequest::first(10)),
    )
    .expect("search");
    assert_eq!(found.entries.len(), 1, "the restored row is not searchable");
    assert_eq!(found.entries[0].id, gone);
}

#[gtk4::test]
fn bulk_delete_shows_toast_not_alert() {
    let harness = Harness::new();
    for query in ["SELECT 1", "SELECT 2", "SELECT 3"] {
        harness.record(query);
    }
    let dialog = harness.presented_dialog();
    wait_until(WAIT, || entries(&dialog).len() == 3).expect("the first page");
    dialog.set_selecting(true);
    let parts = dialog.imp().parts.get().expect("parts");
    parts.multiple.select_item(0, false);
    parts.multiple.select_item(2, false);

    dialog
        .activate_action("history.delete-selected", None)
        .expect("the action");

    wait_until(WAIT, || entries(&dialog) == ["SELECT 2"]).expect("the selected rows to go");
    assert!(
        crate::workspace::visible_alert(&harness.window).is_none(),
        "a bulk delete asked first"
    );
    wait_until(WAIT, || toast(&harness.window, "2 queries deleted").is_some()).expect("a toast");
}

#[gtk4::test]
fn connection_named_with_ampersand_renders_in_filter() {
    let harness = Harness::new();
    let connection = Uuid::new_v4();
    let name = "R&D <prod>";
    harness.record_on("SELECT 1", connection, name);

    let dialog = harness.present(harness.dialog_for(Some(connection)));

    wait_until(WAIT, || filter_labels(&dialog).len() == 2).expect("the connections");
    assert_eq!(filter_labels(&dialog)[1], name);
    let drop_down = connection_drop_down(&dialog);
    let shown = || {
        descendants(&drop_down)
            .into_iter()
            .filter_map(|widget| widget.downcast::<gtk::Label>().ok())
            .find(|label| label.is_mapped() && label.label() == name)
    };
    wait_until(WAIT, || shown().is_some()).expect("the name on the drop-down");
    assert!(
        shown().is_some_and(|label| !label.uses_markup()),
        "the name was read as markup"
    );
}

fn connection_drop_down(dialog: &HistoryDialog) -> gtk::DropDown {
    dialog.imp().parts.get().expect("parts").filters.controls().0
}

#[gtk4::test]
fn history_filters_use_dropdowns_and_toggle_group() {
    let harness = Harness::new();

    let dialog = harness.presented_dialog();

    let header = crate::test_support::first_descendant_of_type::<adw::HeaderBar>(&dialog).expect("a header bar");
    let popovers: Vec<gtk::Widget> = descendants(&header)
        .into_iter()
        .filter(|widget| widget.is::<gtk::Popover>() && !widget.is::<gtk::PopoverMenu>())
        .collect();
    assert!(popovers.is_empty(), "the header still has a filter popover");
    assert!(crate::test_support::first_descendant_of_type::<adw::ComboRow>(&dialog).is_none());
    let root = dialog.imp().parts.get().expect("parts").filters.root().clone();
    let children: Vec<gtk::Widget> = std::iter::successors(root.first_child(), gtk::Widget::next_sibling).collect();
    assert_eq!(children.iter().filter(|child| child.is::<gtk::DropDown>()).count(), 2);
    assert_eq!(
        children.iter().filter(|child| child.is::<adw::ToggleGroup>()).count(),
        1
    );
    let search_bar = dialog.imp().search_bar.get().upcast::<gtk::Widget>();
    assert_eq!(
        root.prev_sibling(),
        Some(search_bar),
        "the filters are not under the search bar"
    );
}

#[gtk4::test]
fn connection_dropdown_follows_model_and_preferred_connection() {
    let harness = Harness::new();
    let (alpha, beta) = (Uuid::new_v4(), Uuid::new_v4());
    harness.record_on("SELECT a", alpha, "Alpha");
    harness.record_on("SELECT b", beta, "Beta");

    let dialog = harness.dialog_for(Some(beta));
    let drop_down = connection_drop_down(&dialog);
    let labels = dialog
        .imp()
        .parts
        .get()
        .expect("parts")
        .filters
        .connections()
        .labels()
        .clone();

    assert_eq!(drop_down.model().and_downcast::<gtk::StringList>(), Some(labels));
    wait_until(WAIT, || drop_down.model().map(|model| model.n_items()) == Some(3)).expect("the connections");
    assert_eq!(drop_down.selected(), 2);
    wait_until(WAIT, || entries(&dialog) == ["SELECT b"]).expect("Beta's queries");
    drop_down.set_selected(1);
    wait_until(WAIT, || entries(&dialog) == ["SELECT a"]).expect("Alpha's queries");
}

#[gtk4::test]
fn filters_are_labelled() {
    let filters = HistoryFilters::new(&ConnectionFilterModel::new());
    let (connection, status, window) = filters.controls();

    for control in [connection.upcast::<gtk::Widget>(), status.upcast(), window.upcast()] {
        assert!(
            gtk::test_accessible_has_property(&control, gtk::AccessibleProperty::Label),
            "{} has no accessible label",
            control.type_().name()
        );
    }
}

#[gtk4::test]
fn the_open_search_bar_is_labelled() {
    let harness = Harness::new();
    let dialog = harness.presented_dialog();
    let imp = dialog.imp();

    imp.search_bar.set_search_mode(true);
    crate::test_support::drain_main_context();

    crate::test_support::assert_labelled(&imp.search_entry.get()).unwrap_or_else(|problem| panic!("{problem}"));
    assert_eq!(
        crate::test_support::unlabelled_icon_buttons(&dialog),
        Vec::<String>::new()
    );
}

#[gtk4::test]
fn history_dialog_show_in_files_reveals_the_database_file() {
    let harness = Harness::new();
    let dialog = harness.presented_dialog();
    let header = crate::test_support::first_descendant_of_type::<adw::HeaderBar>(&dialog).expect("a header bar");
    let menu = descendants(&header)
        .into_iter()
        .filter_map(|widget| widget.downcast::<gtk::MenuButton>().ok())
        .find_map(|button| button.menu_model())
        .expect("the dialog's menu");
    let (action, target) = menu_item(&menu, "Show in Files").expect("a Show in Files item");

    dialog.activate_action(&action, target.as_ref()).expect("the action");

    assert_eq!(harness.revealer.revealed(), [harness.store.path().to_path_buf()]);
    assert!(harness.store.path().ends_with("history.db"));
}

#[gtk4::test]
fn history_dialog_reveal_failure_shows_a_toast() {
    let harness = Harness::revealing_with(RecordingRevealer::failing());
    let dialog = harness.presented_dialog();

    dialog
        .activate_action("history.show-in-files", None)
        .expect("the action");

    let window: gtk::Widget = harness.window.clone().upcast();
    wait_until(WAIT, || has_label(&window, "Could not show the file in Files")).expect("a toast");
}

#[gtk4::test]
fn menu_key_opens_the_menu_of_the_focused_row() {
    let harness = Harness::new();
    let first = harness.record("SELECT first");
    harness.record("SELECT second");
    let dialog = harness.presented_dialog();
    wait_until(WAIT, || row_titled(&dialog, "SELECT first").is_some()).expect("the rows");
    let list_view = dialog.imp().list_view.get();
    // Newest first, so the older entry is the second row. The scroll
    // marks the row the list focuses next; the grab carries it there.
    list_view.scroll_to(1, gtk::ListScrollFlags::FOCUS, None);
    list_view.grab_focus();
    let focused_title = || {
        list_view
            .focus_child()
            .and_then(|item| item.first_child())
            .and_downcast::<HistoryRow>()
            .map(|row| row.title())
    };
    wait_until(WAIT, || focused_title().as_deref() == Some("SELECT first")).expect("the second row focused");

    dialog.activate_action("history-row.menu", None).expect("the action");

    let menu = dialog.imp().parts.get().expect("parts").menu.clone();
    assert!(menu.is_visible(), "the menu did not open");
    let model = menu.menu_model().expect("a menu model");
    let (_, target) = menu_item(&model, "Delete").expect("a Delete item");
    assert_eq!(target.and_then(|target| target.get::<i64>()), Some(first));
    menu.popdown();
}

fn select_entry(dialog: &HistoryDialog, id: i64) {
    let selection = &dialog.imp().parts.get().expect("parts").multiple;
    let position = (0..selection.n_items())
        .find(|position| {
            selection
                .item(*position)
                .and_downcast::<HistoryEntryObject>()
                .and_then(|entry| entry.id())
                == Some(id)
        })
        .expect("the entry on screen");
    selection.select_item(position, false);
}

fn scroll_to_end(dialog: &HistoryDialog) {
    dialog
        .imp()
        .scroll
        .emit_by_name::<()>("edge-reached", &[&gtk::PositionType::Bottom]);
}

#[gtk4::test]
fn deleting_every_loaded_row_loads_the_rest() {
    let harness = Harness::new();
    for index in 0..PAGE_SIZE + 5 {
        harness.record(&format!("SELECT {index}"));
    }
    let dialog = harness.dialog();
    wait_until(WAIT, || entries(&dialog).len() == PAGE_SIZE).expect("the first page");
    dialog.set_selecting(true);
    dialog.imp().parts.get().expect("parts").multiple.select_all();

    dialog
        .activate_action("history.delete-selected", None)
        .expect("the action");

    wait_until(WAIT, || entries(&dialog).len() == 5).expect("the rest of the history");
    assert_eq!(
        entries(&dialog),
        ["SELECT 4", "SELECT 3", "SELECT 2", "SELECT 1", "SELECT 0"]
    );
    assert_eq!(dialog.imp().stack.visible_child_name().as_deref(), Some("list"));
}

#[gtk4::test]
fn deleting_a_row_already_gone_removes_it_without_undo() {
    let harness = Harness::new();
    harness.record("SELECT kept");
    let gone = harness.record("SELECT gone");
    let dialog = harness.presented_dialog();
    wait_until(WAIT, || entries(&dialog).len() == 2).expect("the first page");
    block_on(&harness.runtime, harness.store.delete_returning(&[gone])).expect("a delete elsewhere");

    dialog
        .activate_action("history.delete", Some(&gone.to_variant()))
        .expect("the action");

    wait_until(WAIT, || entries(&dialog) == ["SELECT kept"]).expect("the row to go");
    assert!(
        toast(&harness.window, "1 query deleted").is_none(),
        "Undo offered for nothing deleted"
    );
}

#[gtk4::test]
fn clear_all_says_saved_queries_are_kept_and_keeps_them() {
    use crate::workspace::{answer, visible_alert};
    use tablepro_storage::saved_queries::NewSavedQuery;

    let harness = Harness::new();
    harness.record("SELECT 1");
    let saved = harness.store.saved_queries();
    block_on(
        &harness.runtime,
        saved.save(NewSavedQuery {
            name: "daily".to_owned(),
            query: "SELECT 1".to_owned(),
            connection_id: Uuid::new_v4(),
            connection_name: "local".to_owned(),
        }),
    )
    .expect("a saved query");
    let dialog = harness.presented_dialog();
    wait_until(WAIT, || entries(&dialog).len() == 1).expect("the first page");

    dialog.activate_action("history.clear-all", None).expect("the action");
    wait_until(WAIT, || visible_alert(&harness.window).is_some()).expect("the confirmation");
    let body = visible_alert(&harness.window)
        .map(|alert| alert.body().to_string())
        .unwrap_or_default();
    assert_eq!(
        body,
        "This permanently deletes every history entry, including pinned ones. Saved queries are kept."
    );
    assert!(answer(&harness.window, "clear"));

    wait_until(WAIT, || harness.stored_queries().is_empty()).expect("the history cleared");
    let kept = block_on(&harness.runtime, saved.list(None)).expect("the saved queries");
    assert_eq!(kept.len(), 1, "clearing the history took the saved queries too");
}

#[gtk4::test]
fn undo_that_fails_says_so() {
    let harness = Harness::new();
    let gone = harness.record("SELECT gone");
    let dialog = harness.presented_dialog();
    wait_until(WAIT, || entries(&dialog).len() == 1).expect("the first page");
    let entry = block_on(
        &harness.runtime,
        harness
            .store
            .search_page(&HistoryQuery::default(), HistoryPageRequest::first(10)),
    )
    .expect("search")
    .entries
    .remove(0);
    dialog
        .activate_action("history.delete", Some(&gone.to_variant()))
        .expect("the action");
    wait_until(WAIT, || toast(&harness.window, "1 query deleted").is_some()).expect("a toast");
    // Back under its id before Undo runs, so the restore collides.
    block_on(&harness.runtime, harness.store.restore(&[entry])).expect("a restore elsewhere");

    toast(&harness.window, "1 query deleted").expect("Undo").emit_clicked();

    let window: gtk::Widget = harness.window.clone().upcast();
    wait_until(WAIT, || has_label(&window, "The queries could not be restored.")).expect("a toast");
}

#[gtk4::test]
fn click_in_select_mode_toggles_the_row() {
    let harness = Harness::new();
    let first = harness.record("SELECT 1");
    harness.record("SELECT 2");
    let third = harness.record("SELECT 3");
    let dialog = harness.presented_dialog();
    dialog.set_selecting(true);
    wait_until(WAIT, || row_titled(&dialog, "SELECT 1").is_some()).expect("the rows");
    select_entry(&dialog, third);
    let click = || {
        let row = row_titled(&dialog, "SELECT 1").expect("the row");
        let controllers = row.observe_controllers();
        let gesture = (0..controllers.n_items())
            .filter_map(|index| controllers.item(index).and_downcast::<gtk::GestureClick>())
            .find(|gesture| gesture.button() == gtk::gdk::BUTTON_PRIMARY)
            .expect("a row answers a click");
        gesture.emit_by_name::<()>("released", &[&1i32, &4.0f64, &4.0f64]);
    };

    click();
    let mut selected = dialog.selected_ids();
    selected.sort_unstable();
    assert_eq!(selected, [first, third], "the click replaced the selection");

    click();
    assert_eq!(dialog.selected_ids(), [third]);
}

#[gtk4::test]
fn pin_keeps_the_pages_read_and_the_selection() {
    let harness = Harness::new();
    let ids: Vec<i64> = (0..PAGE_SIZE + 30)
        .map(|index| harness.record(&format!("SELECT {index}")))
        .collect();
    let dialog = harness.dialog();
    wait_until(WAIT, || entries(&dialog).len() == PAGE_SIZE).expect("the first page");
    scroll_to_end(&dialog);
    wait_until(WAIT, || entries(&dialog).len() == ids.len()).expect("the next page");
    dialog.set_selecting(true);
    select_entry(&dialog, ids[5]);

    dialog
        .activate_action("history.pin", Some(&ids[10].to_variant()))
        .expect("the action");

    wait_until(WAIT, || {
        entries(&dialog).first().map(String::as_str) == Some("SELECT 10")
    })
    .expect("the pinned row first");
    assert_eq!(entries(&dialog).len(), ids.len(), "the pages read were dropped");
    assert_eq!(dialog.selected_ids(), [ids[5]]);
}

#[gtk4::test]
fn unpinned_row_past_the_pages_read_comes_back_with_its_page() {
    let harness = Harness::new();
    let oldest = harness.record("SELECT 0");
    for index in 1..PAGE_SIZE + 30 {
        harness.record(&format!("SELECT {index}"));
    }
    harness.pin(oldest);
    let dialog = harness.dialog();
    wait_until(WAIT, || entries(&dialog).len() == PAGE_SIZE).expect("the first page");
    assert_eq!(entries(&dialog).first().map(String::as_str), Some("SELECT 0"));

    dialog
        .activate_action("history.pin", Some(&oldest.to_variant()))
        .expect("the action");

    wait_until(WAIT, || entries(&dialog).len() == PAGE_SIZE - 1).expect("the row to leave");
    assert!(!entries(&dialog).iter().any(|query| query == "SELECT 0"));
    scroll_to_end(&dialog);
    wait_until(WAIT, || entries(&dialog).len() == PAGE_SIZE + 30).expect("the next page");
    let shown = entries(&dialog);
    let mut distinct = shown.clone();
    distinct.sort();
    distinct.dedup();
    assert_eq!(distinct.len(), shown.len(), "a row is shown twice");
    assert_eq!(shown.last().map(String::as_str), Some("SELECT 0"));
}

#[gtk4::test]
fn deleting_a_connections_last_query_drops_it_from_the_filter() {
    let harness = Harness::new();
    let connection = Uuid::new_v4();
    let only = harness.record_on("SELECT 1", connection, "Warehouse");
    let dialog = harness.dialog_for(Some(connection));
    wait_until(WAIT, || entries(&dialog) == ["SELECT 1"]).expect("the connection's queries");
    assert_eq!(connection_drop_down(&dialog).selected(), 1);

    dialog
        .activate_action("history.delete", Some(&only.to_variant()))
        .expect("the action");

    wait_until(WAIT, || filter_labels(&dialog) == ["All Connections"]).expect("the connection to go");
    assert_eq!(connection_drop_down(&dialog).selected(), 0);
    let imp = dialog.imp();
    wait_until(WAIT, || {
        imp.stack.visible_child_name().as_deref() == Some("empty") && imp.status_page.title() == "No Queries Yet"
    })
    .expect("the empty history, not an empty search");
}

#[gtk4::test]
fn copy_query_puts_it_on_the_clipboard_and_says_so() {
    let harness = Harness::new();
    let id = harness.record("SELECT copied");
    let dialog = harness.presented_dialog();
    wait_until(WAIT, || entries(&dialog).len() == 1).expect("the entry");

    dialog
        .activate_action("history.copy", Some(&id.to_variant()))
        .expect("the action");

    let text = dialog
        .clipboard()
        .content()
        .and_then(|content| content.value(String::static_type()).ok())
        .and_then(|value| value.get::<String>().ok());
    assert_eq!(text.as_deref(), Some("SELECT copied"));
    wait_until(WAIT, || has_label(harness.window.upcast_ref(), "Copied to clipboard")).expect("a toast");
}
