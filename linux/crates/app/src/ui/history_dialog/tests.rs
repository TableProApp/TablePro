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
use tablepro_storage::{QueryHistory, StoragePaths};
use tokio::sync::watch;
use uuid::Uuid;

use super::*;
use crate::runtime::AppRuntime;
use crate::services::history_preferences::HistoryPreferences;
use crate::test_support::{descendants, test_runtime, wait_until};

/// Long enough that a loaded machine cannot decide the outcome; a
/// passing test returns as soon as its condition holds.
pub(super) const WAIT: Duration = Duration::from_secs(30);

pub(super) struct Harness {
    pub runtime: AppRuntime,
    pub service: HistoryService,
    pub store: QueryHistory,
    pub window: adw::Window,
    _root: tempfile::TempDir,
}

impl Harness {
    pub fn new() -> Self {
        crate::register_test_resources();
        let runtime = test_runtime();
        let root = tempfile::tempdir().expect("tempdir");
        let paths = StoragePaths::under(root.path(), "tablepro-test", "app.tablepro.TablePro.Devel");
        let preferences = HistoryPreferences {
            retention_days: watch::channel(0).1,
            save: watch::channel(true).1,
        };
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

    pub fn dialog(&self) -> HistoryDialog {
        HistoryDialog::new(HistoryDialogInit {
            history: self.service.clone(),
            tasks: self.runtime.tasks(),
        })
    }

    /// A dialog on the test window, so its list view lays out rows.
    pub fn presented_dialog(&self) -> HistoryDialog {
        let dialog = self.dialog();
        dialog.present(Some(&self.window));
        dialog
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

/// What the row menu's item called `label` activates.
pub(super) fn menu_item(menu: &gio::MenuModel, label: &str) -> Option<(String, glib::Variant)> {
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
            let target = menu.item_attribute_value(index, gio::MENU_ATTRIBUTE_TARGET, None)?;
            return Some((action, target));
        }
    }
    None
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
    dialog.activate_action(&action, Some(&target)).expect("the action");

    assert_eq!(
        *chosen.borrow(),
        [(QueryDestination::NewTab, "SELECT first".to_owned())]
    );
}
