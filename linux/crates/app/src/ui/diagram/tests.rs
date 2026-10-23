use std::cell::RefCell;
use std::rc::Rc;
use std::time::{Duration, Instant};

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use tablepro_core::meta::{ObjectInfo, ObjectKind, TableRef};
use tablepro_core::{ColumnInfo, DriverError, ForeignKeyInfo};
use tablepro_session::runtime::CountingHold;
use tablepro_test_support::{ConnectionScript, FakeReply};
use tokio_util::sync::CancellationToken;

use super::canvas::DiagramCanvas;
use super::model::tests::{column, key};
use super::model::{SchemaDiagram, TableRead};
use super::*;
use crate::runtime::AppRuntime;
use crate::test_support::{FakeSession, OwnedWindow, assert_labelled, drain_main_context, test_runtime, wait_until};
use crate::ui::tab_load::FirstLoad;

const WAIT: Duration = Duration::from_secs(10);

fn object(name: &str) -> ObjectInfo {
    ObjectInfo {
        schema: Some("sales".to_owned()),
        name: name.to_owned(),
        kind: ObjectKind::Table,
    }
}

fn columns(name: &str) -> Vec<ColumnInfo> {
    match name {
        "orders" => vec![column("id", true, false), column("customer_id", false, false)],
        "order_items" => vec![column("id", true, false), column("order_id", false, false)],
        _ => vec![column("id", true, false), column("name", false, true)],
    }
}

fn keys(name: &str) -> Vec<ForeignKeyInfo> {
    match name {
        "orders" => vec![key(
            "orders_customer",
            &["customer_id"],
            Some("sales"),
            "customers",
            &["id"],
        )],
        "order_items" => vec![key("items_order", &["order_id"], Some("sales"), "orders", &["id"])],
        _ => Vec::new(),
    }
}

/// customers <- orders <- order_items. A fake answers by the table name
/// a call is for, which "orders" also matches in "order_items", so that
/// rule comes first.
fn shop() -> ConnectionScript {
    let mut script = ConnectionScript::default();
    script.list_objects.always(FakeReply::ok(vec![
        object("customers"),
        object("orders"),
        object("order_items"),
    ]));
    for name in ["order_items", "orders"] {
        script
            .fetch_columns
            .when_sql_contains(name, FakeReply::ok(columns(name)));
        script
            .fetch_foreign_keys
            .when_sql_contains(name, FakeReply::ok(keys(name)));
    }
    script.fetch_columns.always(FakeReply::ok(columns("customers")));
    script.fetch_foreign_keys.always(FakeReply::ok(Vec::new()));
    script.fetch_indexes.always(FakeReply::ok(Vec::new()));
    script
}

/// A diagram tab in a window of its own, over a fake session. The tab
/// and the window go before the runtime does.
struct Shown {
    window: Option<OwnedWindow<gtk::Window>>,
    tab: Option<DiagramTab>,
    fake: Option<FakeSession>,
    runtime: Option<AppRuntime>,
}

impl Shown {
    fn new(script: ConnectionScript) -> Self {
        adw::init().expect("libadwaita initialises under the test backend");
        crate::register_test_resources();
        if let Some(settings) = gtk::Settings::default() {
            settings.set_gtk_enable_animations(false);
        }
        let runtime = test_runtime();
        let fake = FakeSession::start(script, [], runtime.tasks());
        let window = gtk::Window::builder().default_width(900).default_height(600).build();
        let toasts = adw::ToastOverlay::new();
        let exports = crate::ui::export::ExportLedger::new(crate::ui::export::ExportLedgerInit {
            tasks: runtime.tasks(),
            hold: Rc::new(CountingHold::new()),
            reporter: crate::ui::export::ExportReporter::new(
                &window,
                &toasts,
                Rc::new(crate::ui::file_reveal::RecordingRevealer::succeeding()),
            ),
            inhibitor: crate::workspace::WindowInhibitor::new(crate::workspace::ApplicationInhibit::new(&window)),
        });
        let tab = DiagramTab::new(DiagramTabInit {
            schema: Some("sales".to_owned()),
            session: fake.session.clone(),
            tasks: runtime.tasks(),
            exports,
            tab_id: uuid::Uuid::new_v4(),
            first_load: FirstLoad::Now,
            places: Vec::new(),
        });
        toasts.set_child(Some(&tab));
        window.set_child(Some(&toasts));
        let window = OwnedWindow::presented(window);
        Self {
            window: Some(window),
            tab: Some(tab),
            fake: Some(fake),
            runtime: Some(runtime),
        }
    }

    fn tab(&self) -> &DiagramTab {
        self.tab.as_ref().expect("the tab")
    }

    fn canvas(&self) -> DiagramCanvas {
        self.tab().canvas()
    }

    fn page(&self) -> String {
        self.tab()
            .imp()
            .inner_stack
            .visible_child_name()
            .map(|name| name.to_string())
            .unwrap_or_default()
    }

    fn drawn(&self) -> &Self {
        wait_until(WAIT, || self.page() == "diagram" && self.canvas().table_count() == 3)
            .unwrap_or_else(|_| panic!("the diagram, not {}", self.page()));
        wait_until(WAIT, || self.canvas().width() > 0).expect("the canvas on screen");
        self
    }

    fn activate(&self, action: &str) {
        WidgetExt::activate_action(self.tab(), action, None).unwrap_or_else(|_| panic!("{action}"));
        drain_main_context();
    }
}

impl Drop for Shown {
    fn drop(&mut self) {
        if let Some(tab) = self.tab.take() {
            tab.shutdown();
        }
        self.window.take();
        self.fake.take();
        if let Some(runtime) = self.runtime.take() {
            runtime.shutdown();
        }
    }
}

fn index_of(canvas: &DiagramCanvas, name: &str) -> usize {
    (0..canvas.table_count())
        .find(|&at| canvas.table(at).is_some_and(|table| table.name == name))
        .unwrap_or_else(|| panic!("no {name} in the diagram"))
}

#[gtk4::test]
fn every_table_of_the_schema_is_drawn_and_named_for_a_screen_reader() {
    let shown = Shown::new(shop());
    shown.drawn();
    let canvas = shown.canvas();

    assert_eq!(canvas.accessible_role(), gtk::AccessibleRole::List);
    for at in 0..canvas.table_count() {
        let node = canvas.node(at).expect("a node per table");
        assert_eq!(node.accessible_role(), gtk::AccessibleRole::ListItem);
        assert!(node.is_focusable());
        assert_labelled(&node).unwrap_or_else(|problem| panic!("{problem:?}"));
        assert!(gtk::test_accessible_has_property(
            &node,
            gtk::AccessibleProperty::Description
        ));
    }
    let orders = index_of(&canvas, "orders");
    assert_eq!(
        super::describe::table_description(&SchemaDiagram::build(reads()), orders),
        "2 columns. References customers. Referenced by order_items. Columns: id, integer, primary key; \
         customer_id, integer, foreign key."
    );
}

fn reads() -> Vec<TableRead> {
    ["customers", "orders", "order_items"]
        .iter()
        .map(|&name| TableRead {
            table: TableRef::new(Some("sales".to_owned()), name),
            columns: columns(name),
            foreign_keys: keys(name),
            indexes: Vec::new(),
        })
        .collect()
}

#[gtk4::test]
fn the_keyboard_selects_a_table_and_opens_it() {
    let shown = Shown::new(shop());
    shown.drawn();
    let canvas = shown.canvas();
    let opened: Rc<RefCell<Vec<TableRef>>> = Rc::default();
    let sink = opened.clone();
    shown
        .tab()
        .connect_open_table(move |_, table| sink.borrow_mut().push(table));
    let orders = index_of(&canvas, "orders");

    canvas.node(orders).expect("the orders node").grab_focus();
    drain_main_context();
    assert_eq!(canvas.selected(), Some(orders), "the focus selects the table");
    shown.activate("diagram.open-table");

    assert_eq!(
        opened.borrow().as_slice(),
        [TableRef::new(Some("sales".to_owned()), "orders")]
    );
    let before = canvas.selected();
    assert!(
        canvas.child_focus(gtk::DirectionType::TabForward),
        "Tab reaches the next table"
    );
    drain_main_context();
    assert_ne!(canvas.selected(), before, "the next table is selected");
}

#[gtk4::test]
fn a_table_moved_by_the_keyboard_keeps_its_place_through_a_refresh() {
    let shown = Shown::new(shop());
    shown.drawn();
    let canvas = shown.canvas();
    let customers = index_of(&canvas, "customers");
    canvas.focus_table(customers);
    let place = |canvas: &DiagramCanvas| canvas.kept_places().and_then(|places| places.get("customers").copied());
    assert_eq!(place(&canvas), None, "nothing was moved yet");

    shown.activate("diagram.move-table-right");
    shown.activate("diagram.move-table-down");
    let moved = place(&canvas).expect("the table was moved");
    shown.activate("diagram.refresh");
    wait_until(WAIT, || !shown.tab().is_loading()).expect("the refresh to end");

    assert_eq!(place(&shown.canvas()), Some(moved));
    assert_eq!(
        shown.canvas().selected_table().map(|table| table.name),
        Some("customers".to_owned())
    );
}

#[gtk4::test]
fn zoom_steps_fits_and_resets() {
    let shown = Shown::new(shop());
    shown.drawn();
    let canvas = shown.canvas();
    shown.activate("diagram.zoom-reset");
    assert_eq!(canvas.zoom(), 1.0);

    shown.activate("diagram.zoom-in");
    assert_eq!(canvas.zoom(), 1.1);
    wait_until(WAIT, || {
        shown.tab().imp().zoom_reset_button.label().as_deref() == Some("110%")
    })
    .expect("the label follows the zoom");
    shown.activate("diagram.zoom-out");
    shown.activate("diagram.zoom-out");
    assert_eq!(canvas.zoom(), 0.9);
    shown.activate("diagram.zoom-fit");
    assert!(canvas.zoom() <= 1.0);
}

#[gtk4::test]
fn stop_ends_the_read_and_says_so() {
    let mut script = shop();
    let release = CancellationToken::new();
    script.fetch_indexes = Default::default();
    script.fetch_indexes.always(FakeReply::UntilReleased {
        release: release.clone(),
        outcome: Ok(Vec::new()),
    });
    let shown = Shown::new(script);
    wait_until(WAIT, || shown.tab().is_loading() && shown.page() == "loading").expect("the read to run");

    shown.activate("diagram.stop");

    wait_until(WAIT, || shown.page() == "stopped").expect("the tab says the read stopped");
    assert!(!shown.tab().is_loading());
    release.cancel();
}

#[gtk4::test]
fn a_failed_refresh_keeps_the_diagram_under_a_banner() {
    let mut script = shop();
    script.fetch_indexes = Default::default();
    for _ in 0..3 {
        script.fetch_indexes.once(FakeReply::ok(Vec::new()));
    }
    script
        .fetch_indexes
        .always(FakeReply::err(DriverError::server("permission denied")));
    let shown = Shown::new(script);
    shown.drawn();

    shown.activate("diagram.refresh");
    wait_until(WAIT, || !shown.tab().is_loading()).expect("the refresh to end");

    assert_eq!(shown.page(), "diagram");
    assert!(
        shown.tab().imp().stale_banner.is_revealed(),
        "the banner says the diagram is the last one read"
    );
}

#[gtk4::test]
fn a_change_to_the_schema_offers_a_refresh() {
    let shown = Shown::new(shop());
    shown.drawn();
    assert!(!shown.tab().imp().outdated_banner.is_revealed());

    shown.tab().schema_changed();

    assert!(shown.tab().imp().outdated_banner.is_revealed());
    shown.activate("diagram.refresh");
    wait_until(WAIT, || !shown.tab().is_loading()).expect("the refresh to end");
    assert!(
        !shown.tab().imp().outdated_banner.is_revealed(),
        "a diagram read again is up to date"
    );
}

#[gtk4::test]
fn a_schema_with_no_tables_says_so() {
    let mut script = ConnectionScript::default();
    script.list_objects.always(FakeReply::ok(Vec::new()));

    let shown = Shown::new(script);

    wait_until(WAIT, || shown.page() == "empty").expect("the empty page");
}

/// A schema of hundreds of tables lays out and draws without holding the
/// window for long. The bound is far above a debug build's time, so it
/// catches a layout that grows out of hand, not a slow machine.
#[gtk4::test]
fn five_hundred_tables_lay_out_and_draw_in_bounded_time() {
    let shown = Shown::new(shop());
    shown.drawn();
    let reads: Vec<TableRead> = (0..500)
        .map(|at| TableRead {
            table: TableRef::new(Some("sales".to_owned()), format!("table_{at:03}")),
            columns: (0..10).map(|c| column(&format!("column_{c}"), c == 0, c > 2)).collect(),
            foreign_keys: match at {
                0 => Vec::new(),
                _ => vec![key(
                    "parent",
                    &["column_1"],
                    None,
                    &format!("table_{:03}", at / 3),
                    &["column_0"],
                )],
            },
            indexes: Vec::new(),
        })
        .collect();
    let canvas = shown.canvas();

    let started = Instant::now();
    canvas.set_diagram(SchemaDiagram::build(reads), None);
    drain_main_context();
    let laid_out = started.elapsed();
    let started = Instant::now();
    let drawn = canvas.render();
    let rendered = started.elapsed();

    assert_eq!(canvas.table_count(), 500);
    assert!(drawn.is_some());
    assert!(laid_out < Duration::from_secs(10), "laid out in {laid_out:?}");
    assert!(rendered < Duration::from_secs(10), "drawn in {rendered:?}");
}

/// The first read answers at once; every read after it waits for
/// `release`.
fn held_after_first_read(release: &CancellationToken) -> ConnectionScript {
    let mut script = shop();
    script.fetch_indexes = Default::default();
    for _ in 0..3 {
        script.fetch_indexes.once(FakeReply::ok(Vec::new()));
    }
    script.fetch_indexes.always(FakeReply::UntilReleased {
        release: release.clone(),
        outcome: Ok(Vec::new()),
    });
    script
}

#[gtk4::test]
fn a_table_moved_while_a_refresh_runs_keeps_its_new_place() {
    let release = CancellationToken::new();
    let shown = Shown::new(held_after_first_read(&release));
    shown.drawn();
    let canvas = shown.canvas();
    canvas.focus_table(index_of(&canvas, "orders"));
    shown.activate("diagram.refresh");
    wait_until(WAIT, || shown.tab().is_loading()).expect("the refresh to run");

    shown.activate("diagram.move-table-down");
    let moved = canvas.kept_places().and_then(|places| places.get("orders").copied());
    release.cancel();
    wait_until(WAIT, || !shown.tab().is_loading()).expect("the refresh to end");

    assert!(moved.is_some());
    assert_eq!(
        shown
            .canvas()
            .kept_places()
            .and_then(|places| places.get("orders").copied()),
        moved
    );
}

#[gtk4::test]
fn reset_layout_after_a_stopped_refresh_saves_no_places() {
    let release = CancellationToken::new();
    let shown = Shown::new(held_after_first_read(&release));
    shown.drawn();
    let canvas = shown.canvas();
    canvas.focus_table(index_of(&canvas, "orders"));
    shown.activate("diagram.move-table-right");
    assert_eq!(shown.tab().places().len(), 3, "a moved table saves every place");
    shown.activate("diagram.refresh");
    shown.activate("diagram.stop");

    shown.activate("diagram.reset-layout");

    assert!(shown.tab().places().is_empty(), "{:?}", shown.tab().places());
    release.cancel();
}

#[gtk4::test]
fn a_change_while_the_tables_are_read_leaves_the_diagram_marked_out_of_date() {
    let release = CancellationToken::new();
    let mut script = shop();
    script.fetch_indexes = Default::default();
    script.fetch_indexes.always(FakeReply::UntilReleased {
        release: release.clone(),
        outcome: Ok(Vec::new()),
    });
    let shown = Shown::new(script);
    wait_until(WAIT, || shown.tab().is_loading()).expect("the read to run");

    shown.tab().schema_changed();
    release.cancel();
    shown.drawn();

    assert!(shown.tab().imp().outdated_banner.is_revealed());
}

/// The scrolled area keeps the room a moved card left, but Best Fit and
/// an export show only where the cards are now.
#[gtk4::test]
fn best_fit_and_export_ignore_where_a_moved_table_was() {
    let shown = Shown::new(shop());
    shown.drawn();
    let canvas = shown.canvas();
    shown.activate("diagram.zoom-fit");
    let fitted = canvas.zoom();
    let (_, width, height) = canvas.render().expect("a diagram");
    let customers = index_of(&canvas, "customers");
    let home = canvas.card_position(customers);

    canvas.place_card(
        customers,
        super::layout::Point {
            x: home.x + 5_000.0,
            y: home.y + 3_000.0,
        },
    );
    canvas.settle_move();
    canvas.place_card(customers, home);
    canvas.settle_move();
    shown.activate("diagram.zoom-fit");

    assert_eq!(canvas.zoom(), fitted);
    let (_, after_width, after_height) = canvas.render().expect("a diagram");
    assert_eq!((after_width, after_height), (width, height));
}

#[gtk4::test]
fn a_refresh_leaves_the_view_where_it_was() {
    let shown = Shown::new(shop());
    shown.drawn();
    let canvas = shown.canvas();
    let customers = index_of(&canvas, "customers");
    let home = canvas.card_position(customers);
    canvas.place_card(
        customers,
        super::layout::Point {
            x: home.x - 3_000.0,
            y: home.y - 2_000.0,
        },
    );
    canvas.settle_move();
    canvas.place_card(customers, home);
    canvas.settle_move();
    drain_main_context();
    let orders = index_of(&canvas, "orders");
    let before = canvas.card_bounds(orders);

    shown.activate("diagram.refresh");
    wait_until(WAIT, || !shown.tab().is_loading()).expect("the refresh to end");
    drain_main_context();

    assert_eq!(shown.canvas().card_bounds(index_of(&shown.canvas(), "orders")), before);
}

#[gtk4::test]
fn a_stopped_read_is_not_read_again_on_reconnect() {
    let release = CancellationToken::new();
    let mut script = shop();
    script.fetch_indexes = Default::default();
    script
        .fetch_indexes
        .once(FakeReply::err(DriverError::server("connection reset")));
    script.fetch_indexes.always(FakeReply::UntilReleased {
        release: release.clone(),
        outcome: Ok(Vec::new()),
    });
    let shown = Shown::new(script);
    wait_until(WAIT, || shown.page() == "error").expect("the failed read");
    shown.activate("diagram.refresh");
    wait_until(WAIT, || shown.tab().is_loading()).expect("the read again");
    shown.activate("diagram.stop");

    shown
        .tab()
        .on_link_changed(tablepro_session::LinkGeneration::FIRST.next().next());
    drain_main_context();

    assert!(!shown.tab().is_loading(), "a reconnect read the stopped schema again");
    assert_eq!(shown.page(), "stopped");
    release.cancel();
}

#[gtk4::test]
fn an_export_draws_the_whole_diagram_at_twice_its_size() {
    let shown = Shown::new(shop());
    shown.drawn();
    let canvas = shown.canvas();
    shown.activate("diagram.zoom-in");

    let (node, width, height) = canvas.render().expect("a diagram");
    let draw = |format| super::export::encode(super::export::draw(&node, width, height, format).expect("drawn"));
    let png = draw(super::export::ImageFormat::Png).expect("a PNG");
    let svg = draw(super::export::ImageFormat::Svg).expect("an SVG");

    let texture = gtk::gdk::Texture::from_bytes(&gtk::glib::Bytes::from(&png)).expect("a PNG GTK reads");
    assert_eq!(
        (texture.width(), texture.height()),
        ((width * 2.0).ceil() as i32, (height * 2.0).ceil() as i32),
        "the whole diagram at twice its size, whatever the zoom"
    );
    assert!(String::from_utf8(svg).expect("SVG is text").contains("<svg"));
}

#[gtk4::test]
fn a_refresh_keeps_the_view_though_a_table_has_the_keyboard() {
    let shown = Shown::new(shop());
    shown.drawn();
    let canvas = shown.canvas();
    let orders = index_of(&canvas, "orders");
    canvas.focus_table(orders);
    let scroller = shown.tab().imp().scroller.get();
    let h = scroller.hadjustment();
    h.set_value(h.upper() - h.page_size());
    drain_main_context();
    let before = canvas.card_bounds(orders);

    shown.activate("diagram.refresh");
    wait_until(WAIT, || !shown.tab().is_loading()).expect("the refresh to end");
    drain_main_context();

    let canvas = shown.canvas();
    assert_eq!(canvas.card_bounds(index_of(&canvas, "orders")), before);
    assert!(crate::ui::a11y::holds_focus(&canvas), "the keyboard left the diagram");
}

#[gtk4::test]
fn a_refresh_that_leaves_no_tables_hands_the_keyboard_on() {
    let mut script = shop();
    script.list_objects = Default::default();
    script.list_objects.once(FakeReply::ok(vec![
        object("customers"),
        object("orders"),
        object("order_items"),
    ]));
    script.list_objects.always(FakeReply::ok(Vec::new()));
    let shown = Shown::new(script);
    shown.drawn();
    shown.canvas().focus_table(0);

    shown.activate("diagram.refresh");
    wait_until(WAIT, || shown.page() == "empty").expect("the empty page");

    assert!(
        shown.tab().imp().refresh_button.has_focus(),
        "the keyboard was left nowhere"
    );
}

/// The narrowest window, as the workspace's tests measure it; the
/// header bar above the tab takes the rest of its height.
const FLOOR_WIDTH: i32 = 360;
const FLOOR_TAB_HEIGHT: i32 = 240;

fn fits_the_floor(tab: &DiagramTab, state: &str) {
    let (width, ..) = tab.measure(gtk::Orientation::Horizontal, -1);
    let (height, ..) = tab.measure(gtk::Orientation::Vertical, FLOOR_WIDTH);
    assert!(width <= FLOOR_WIDTH, "{state}: the tab needs {width} px wide");
    assert!(height <= FLOOR_TAB_HEIGHT, "{state}: the tab needs {height} px high");
}

#[gtk4::test]
fn refresh_turns_into_stop_and_the_bar_fits_the_narrowest_window() {
    let release = CancellationToken::new();
    let shown = Shown::new(held_after_first_read(&release));
    shown.drawn();
    let button = shown.tab().imp().refresh_button.get();
    fits_the_floor(shown.tab(), "drawn");
    button.grab_focus();

    button.emit_clicked();
    wait_until(WAIT, || shown.tab().is_loading()).expect("the refresh to run");
    shown
        .tab()
        .imp()
        .refresh_label
        .set_label("Reading the list of tables… 499 of 500 tables read");

    assert_eq!(button.action_name().as_deref(), Some("diagram.stop"));
    assert_eq!(button.tooltip_text().as_deref(), Some("Stop"));
    assert!(
        !gtk::test_accessible_has_property(&button, gtk::AccessibleProperty::KeyShortcuts),
        "Stop announced Refresh's keys"
    );
    assert!(button.has_focus(), "the keyboard left the button");
    fits_the_floor(shown.tab(), "refreshing");

    button.emit_clicked();
    wait_until(WAIT, || !shown.tab().is_loading()).expect("the refresh to stop");

    assert_eq!(button.action_name().as_deref(), Some("diagram.refresh"));
    assert_eq!(button.tooltip_text().as_deref(), Some("Refresh"));
    assert!(gtk::test_accessible_has_property(
        &button,
        gtk::AccessibleProperty::KeyShortcuts
    ));
    assert!(button.has_focus(), "the keyboard left the button");
    release.cancel();
}
