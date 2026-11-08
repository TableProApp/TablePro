use std::cell::RefCell;
use std::rc::Rc;
use std::time::Duration;

use tablepro_core::DriverError;
use tablepro_core::meta::ObjectInfo;
use tablepro_test_support::{ConnectionScript, FakeReply};

use super::*;
use crate::test_support::{FakeSession, finish_on_main, test_runtime, wait_until};

const WAIT: Duration = Duration::from_secs(5);

fn object(name: &str, kind: ObjectKind) -> ObjectInfo {
    ObjectInfo::new(Some("public".to_owned()), name, kind)
}

type Fixture = (
    crate::runtime::AppRuntime,
    FakeSession,
    QuickOpen,
    Rc<RefCell<Vec<Pick>>>,
);

fn setup(objects: Vec<ObjectInfo>) -> Fixture {
    let mut script = ConnectionScript::default();
    script.list_objects.always(FakeReply::ok(objects));
    setup_script(script)
}

fn setup_script(script: ConnectionScript) -> Fixture {
    adw::init().expect("libadwaita");
    let runtime = test_runtime();
    let fake = FakeSession::start(script, [], runtime.tasks());
    let chosen = Rc::new(RefCell::new(Vec::new()));
    let sink = chosen.clone();
    let dialog = QuickOpen::new(fake.session.clone(), runtime.tasks(), move |pick| {
        sink.borrow_mut().push(pick)
    });
    (runtime, fake, dialog, chosen)
}

fn ready(dialog: &QuickOpen) {
    wait_until(WAIT, || dialog.current()).expect("current search results");
}

#[gtk4::test]
fn an_unloaded_catalog_arrives_without_reopening() {
    let (_runtime, _fake, dialog, _) = setup(vec![object("orders", ObjectKind::Table)]);
    assert_eq!(dialog.imp().widgets.get().unwrap().store.n_items(), 0);
    ready(&dialog);
    assert_eq!(dialog.selected().unwrap().name(), "orders");
    dialog.dismiss();
}

#[gtk4::test]
fn enter_after_typing_uses_the_new_search() {
    let (_runtime, _fake, dialog, chosen) = setup(vec![
        object("customers", ObjectKind::Table),
        object("orders", ObjectKind::Table),
    ]);
    ready(&dialog);
    let widgets = dialog.imp().widgets.get().unwrap();
    widgets.entry.set_text("orders");
    widgets.entry.emit_by_name::<()>("activate", &[]);
    assert!(chosen.borrow().is_empty(), "the previous row opened");
    wait_until(WAIT, || !chosen.borrow().is_empty()).expect("deferred activation");
    assert_eq!(
        chosen.borrow()[0],
        Pick::Table {
            table: tablepro_core::meta::TableRef::new(Some("public".to_owned()), "orders"),
            structure: false
        }
    );
}

#[gtk4::test]
fn a_miss_cannot_activate_a_previous_result() {
    let (_runtime, _fake, dialog, chosen) = setup(vec![object("orders", ObjectKind::Table)]);
    ready(&dialog);
    dialog.imp().widgets.get().unwrap().entry.set_text("missing");
    dialog.activate(false);
    ready(&dialog);
    assert!(chosen.borrow().is_empty());
    assert_eq!(
        dialog
            .imp()
            .widgets
            .get()
            .unwrap()
            .stack
            .visible_child_name()
            .as_deref(),
        Some("status")
    );
    dialog.dismiss();
}

#[gtk4::test]
fn keyboard_navigation_scrolls_and_keeps_search_focus() {
    let (_runtime, _fake, dialog, _) = setup(
        (0..100)
            .map(|i| object(&format!("table_{i:03}"), ObjectKind::Table))
            .collect(),
    );
    let window = adw::Window::new();
    window.set_default_size(800, 600);
    window.present();
    dialog.present(Some(&window));
    ready(&dialog);
    wait_until(WAIT, || dialog.entry_has_focus()).expect("search focus");
    for _ in 0..60 {
        assert_eq!(
            dialog.key(gdk::Key::Down, gdk::ModifierType::empty()),
            glib::Propagation::Stop
        );
    }
    let widgets = dialog.imp().widgets.get().unwrap();
    assert_eq!(widgets.selection.selected(), 60);
    assert!(dialog.entry_has_focus());
    let scrolled = widgets
        .list
        .parent()
        .and_downcast::<gtk::ScrolledWindow>()
        .expect("scroller");
    wait_until(WAIT, || scrolled.vadjustment().value() > 0.0).expect("selected row scrolled into view");
    widgets.entry.emit_by_name::<()>("stop-search", &[]);
    wait_until(WAIT, || dialog.parent().is_none()).expect("Escape closes");
    assert!(dialog.imp().context.borrow().is_none());
    window.destroy();
}

#[gtk4::test]
fn structure_is_not_offered_for_views_or_a_dialect_without_ddl() {
    let (_runtime, _fake, dialog, chosen) = setup(vec![
        object("orders", ObjectKind::Table),
        object("view", ObjectKind::View),
    ]);
    ready(&dialog);
    assert_eq!(
        dialog.key(gdk::Key::Return, gdk::ModifierType::CONTROL_MASK),
        glib::Propagation::Stop
    );
    assert!(chosen.borrow().is_empty(), "the fake dialect has no DDL");
    dialog.step(1);
    dialog.activate(true);
    assert!(chosen.borrow().is_empty());
    dialog.activate(false);
    assert_eq!(chosen.borrow().len(), 1, "a view can still be browsed");
    assert!(matches!(chosen.borrow()[0], Pick::Table { structure: false, .. }));
}

#[gtk4::test]
fn a_catalog_refresh_preserves_identity_and_removes_dropped_objects() {
    let mut script = ConnectionScript::default();
    script
        .list_objects
        .once(FakeReply::ok(vec![
            object("orders", ObjectKind::Table),
            object("users", ObjectKind::Table),
        ]))
        .always(FakeReply::ok(vec![
            object("aardvark", ObjectKind::Table),
            object("users", ObjectKind::Table),
        ]));
    let (runtime, fake, dialog, _) = setup_script(script);
    ready(&dialog);
    dialog.step(1);
    let session = fake.session.clone();
    finish_on_main(
        WAIT,
        runtime
            .tasks()
            .spawn_task(async move { session.refresh_objects(ObjectScope::AllSchemas).await }),
    )
    .unwrap()
    .unwrap()
    .unwrap();
    wait_until(WAIT, || dialog.imp().generation.get() == Some(2) && dialog.current()).unwrap();
    assert_eq!(dialog.selected().unwrap().name(), "users");
    dialog.imp().widgets.get().unwrap().entry.set_text("orders");
    dialog.search();
    ready(&dialog);
    assert!(dialog.selected().is_none());
    dialog.dismiss();
}

#[gtk4::test]
fn a_failed_read_has_retry_and_recovers() {
    adw::init().expect("libadwaita");
    let runtime = test_runtime();
    let mut script = ConnectionScript::default();
    script.list_objects.once(FakeReply::err(DriverError::Cancelled));
    script
        .list_objects
        .always(FakeReply::ok(vec![object("orders", ObjectKind::Table)]));
    let fake = FakeSession::start(script, [], runtime.tasks());
    let dialog = QuickOpen::new(fake.session, runtime.tasks(), |_| {});
    let widgets = dialog.imp().widgets.get().unwrap();
    wait_until(WAIT, || widgets.banner.is_revealed()).expect("read failure visible");
    widgets.banner.emit_by_name::<()>("button-clicked", &[]);
    ready(&dialog);
    assert_eq!(dialog.selected().unwrap().name(), "orders");
    assert!(!widgets.banner.is_revealed());
    dialog.dismiss();
}

#[gtk4::test]
fn a_closed_dialog_retained_by_its_workspace_stops_work() {
    let (runtime, fake, dialog, chosen) = setup(vec![object("orders", ObjectKind::Table)]);
    ready(&dialog);
    dialog.imp().widgets.get().unwrap().entry.set_text("ord");
    dialog.activate(false);
    dialog.dismiss();
    let generation = dialog.imp().generation.get();
    let session = fake.session.clone();
    finish_on_main(
        WAIT,
        runtime
            .tasks()
            .spawn_task(async move { session.refresh_objects(ObjectScope::AllSchemas).await }),
    )
    .unwrap()
    .unwrap()
    .unwrap();
    crate::test_support::drain_main_context();
    assert_eq!(dialog.imp().generation.get(), generation);
    assert!(dialog.imp().watches.borrow().is_empty());
    assert!(dialog.imp().context.borrow().is_none());
    assert!(chosen.borrow().is_empty());
}

#[gtk4::test]
fn control_enter_opens_table_structure_with_a_ddl_dialect() {
    let mut script = ConnectionScript {
        dialect: Arc::new(tablepro_driver_postgres::PgDialect::new(
            &tablepro_core::ServerInfo::new("PostgreSQL", "18.0", 18, 0, 0),
        )),
        ..ConnectionScript::default()
    };
    script
        .list_objects
        .always(FakeReply::ok(vec![object("orders", ObjectKind::Table)]));
    let (_runtime, _fake, dialog, chosen) = setup_script(script);
    ready(&dialog);
    assert_eq!(
        dialog.key(gdk::Key::Return, gdk::ModifierType::CONTROL_MASK),
        glib::Propagation::Stop
    );
    assert_eq!(chosen.borrow().len(), 1);
    assert!(matches!(chosen.borrow()[0], Pick::Table { structure: true, .. }));
}

#[gtk4::test]
fn clicking_a_stale_row_never_opens_a_different_search_result() {
    let (_runtime, _fake, dialog, chosen) = setup(vec![
        object("customers", ObjectKind::Table),
        object("orders", ObjectKind::Table),
    ]);
    ready(&dialog);
    let widgets = dialog.imp().widgets.get().unwrap();
    widgets.entry.set_text("orders");
    widgets.list.emit_by_name::<()>("activate", &[&0u32]);
    ready(&dialog);
    assert!(chosen.borrow().is_empty());
    assert_eq!(dialog.selected().unwrap().name(), "orders");
    widgets.list.emit_by_name::<()>("activate", &[&0u32]);
    assert_eq!(chosen.borrow().len(), 1);
}

#[gtk4::test]
fn arrows_before_search_finishes_apply_before_enter() {
    let (_runtime, _fake, dialog, chosen) = setup(vec![
        object("customers", ObjectKind::Table),
        object("order_items", ObjectKind::Table),
        object("orders", ObjectKind::Table),
    ]);
    ready(&dialog);
    dialog.imp().widgets.get().unwrap().entry.set_text("ord");
    dialog.step(1);
    dialog.activate(false);
    wait_until(WAIT, || !chosen.borrow().is_empty()).expect("pending navigation and activation");
    assert_eq!(
        chosen.borrow()[0],
        Pick::Table {
            table: tablepro_core::meta::TableRef::new(Some("public".to_owned()), "orders"),
            structure: false
        }
    );
}
