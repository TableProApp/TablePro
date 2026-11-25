use std::cell::RefCell;
use std::rc::Rc;
use std::time::Duration;

use tablepro_core::{AiPolicy, AuthMode, ExternalAccess, SafeModeLevel, TlsConfig};
use tablepro_foreign_import::review::{ImportPlan, ImportReview};
use tablepro_foreign_import::{
    ForeignApp, ForeignPlatform, ForeignSource, Inventory, PasswordOffer, SourceAvailability, UnreadableReason,
};
use tablepro_session::runtime::TaskFailure;
use tablepro_storage::{SavedConnection, StoragePaths};
use uuid::Uuid;

use super::*;
use crate::test_support::{test_runtime, wait_until, write_text_file};

const WAIT: Duration = Duration::from_secs(30);

const DATA_SOURCES: &str = r#"{
  "folders": {"Clients": {}},
  "connections": {
    "postgres-orders": {
      "provider": "postgresql", "name": "orders-prod", "folder": "Clients",
      "configuration": {"host": "db.acme.example", "port": "5432", "database": "orders", "user": "app"}
    },
    "mysql-billing": {
      "provider": "mysql", "name": "billing",
      "configuration": {"host": "billing.acme.example", "port": "3306", "database": "billing", "user": "deploy"}
    },
    "oracle-ledger": {
      "provider": "oracle", "name": "ledger",
      "configuration": {"host": "ora.acme.example", "port": "1521", "database": "LEDGER", "user": "fin"}
    }
  }
}"#;

// Two scripts of one name for one connection: the library keeps one query per name there.
const PROJECT_METADATA: &str = r#"{"resources": {
  "Scripts/a/Report.sql": {"default-datasource": "mysql-billing"},
  "Scripts/b/Report.sql": {"default-datasource": "mysql-billing"}
}}"#;

struct Harness {
    _runtime: crate::runtime::AppRuntime,
    _root: tempfile::TempDir,
    store: ConnectionStore,
    dialog: ImportFromAppDialog,
    imported: Rc<RefCell<Option<(ImportReview, ImportPlan)>>>,
    _window: adw::Window,
}

// A home folder where another app keeps the three connections and two scripts above.
pub(crate) fn dbeaver_home(root: &std::path::Path) -> ForeignAppDirs {
    let dirs = ForeignAppDirs::conventional(ForeignPlatform::Linux, &root.join("home"));
    let project = dirs.data.join("DBeaverData/workspace6/General/.dbeaver");
    std::fs::create_dir_all(&project).expect("the DBeaver project");
    write_text_file(&project.join("data-sources.json"), DATA_SOURCES);
    write_text_file(&project.join("project-metadata.json"), PROJECT_METADATA);
    let scripts = project.parent().expect("the project folder").join("Scripts");
    for folder in ["a", "b"] {
        std::fs::create_dir_all(scripts.join(folder)).expect("a scripts folder");
        write_text_file(&scripts.join(folder).join("Report.sql"), &format!("SELECT '{folder}'"));
    }
    dirs
}

pub(crate) fn drivers() -> Arc<DriverRegistry> {
    let mut drivers = DriverRegistry::new();
    drivers.register(Arc::new(tablepro_driver_postgres::PgDriver));
    drivers.register(Arc::new(tablepro_driver_mysql::MysqlDriver));
    Arc::new(drivers)
}

fn saved_orders() -> SavedConnection {
    SavedConnection {
        id: Uuid::new_v4(),
        name: "orders".to_owned(),
        driver_id: "postgres".to_owned(),
        host: "db.acme.example".to_owned(),
        port: 5432,
        database: "orders".to_owned(),
        username: "app".to_owned(),
        tls: TlsConfig::verify_full(),
        safe_mode: SafeModeLevel::Silent,
        external_access: ExternalAccess::ReadOnly,
        ai_policy: AiPolicy::Ask,
        query_timeout_secs: None,
        auth_mode: AuthMode::Password,
        ssh: None,
        last_opened_at: None,
        color: None,
        group_id: None,
        order: 0,
        tags: Vec::new(),
        icon: None,
        options: Default::default(),
        details: Default::default(),
        device: Default::default(),
        unknown: Default::default(),
    }
}

impl Harness {
    fn new() -> Self {
        crate::register_test_resources();
        let runtime = test_runtime();
        let root = tempfile::tempdir().expect("tempdir");
        let dirs = dbeaver_home(root.path());

        let paths = StoragePaths::under(root.path(), "tablepro-test", "app.tablepro.TablePro.Devel");
        let store = ConnectionStore::new(&paths);
        store.upsert_blocking(saved_orders()).expect("a saved connection");

        let imported = Rc::new(RefCell::new(None));
        let sink = imported.clone();
        let dialog = ImportFromAppDialog::new(ImportFromAppInit {
            dirs,
            drivers: drivers(),
            connections: store.clone(),
            tasks: runtime.tasks(),
            on_import: Box::new(move |review, plan| {
                sink.replace(Some((review, plan)));
            }),
        });
        let window = adw::Window::new();
        window.set_default_size(800, 800);
        window.present();
        dialog.present(Some(&window));
        Self {
            _runtime: runtime,
            _root: root,
            store,
            dialog,
            imported,
            _window: window,
        }
    }

    fn pages(&self) -> &ImportPages {
        self.dialog.pages().expect("the dialog's pages")
    }

    fn source(&self, app: ForeignApp) -> Option<(bool, gtk::CheckButton)> {
        source_of(self.pages(), app).map(|(available, check, _)| (available, check))
    }

    fn sources_shown(&self) -> bool {
        self.pages().sources_page().as_deref() == Some("sources")
    }

    fn page(&self) -> Option<String> {
        self.dialog
            .imp()
            .navigation
            .visible_page()
            .and_then(|page| page.tag())
            .map(|tag| tag.to_string())
    }
}

fn source_of(pages: &ImportPages, app: ForeignApp) -> Option<(bool, gtk::CheckButton, adw::ActionRow)> {
    pages
        .sources()
        .iter()
        .find(|row| row.app == app)
        .map(|row| (row.available, row.check.clone(), row.row.clone()))
}

#[gtk4::test]
fn an_app_found_on_this_computer_is_read_into_a_review_with_the_duplicate_unchecked() {
    let harness = Harness::new();
    wait_until(WAIT, || harness.sources_shown()).expect("the apps to be looked for");

    assert!(
        harness.source(ForeignApp::SequelAce).is_none(),
        "an app that runs only on macOS is listed"
    );
    let (available, check) = harness.source(ForeignApp::DBeaver).expect("the DBeaver row");
    assert!(available);
    assert!(check.is_active(), "the first app found is not picked");
    let (navicat_available, _) = harness.source(ForeignApp::Navicat).expect("the Navicat row");
    assert!(navicat_available, "an app read from an export file is always offered");
    assert!(harness.pages().continue_button().is_sensitive());

    harness.pages().continue_button().emit_clicked();
    wait_until(WAIT, || harness.page().as_deref() == Some(pages::REVIEW)).expect("the review");

    {
        let reviewing = harness.pages().reviewing();
        let reviewing = reviewing.as_ref().expect("a review");
        let names: Vec<&str> = reviewing
            .review
            .connections()
            .iter()
            .map(|row| row.name.as_str())
            .collect();
        assert_eq!(names, ["billing", "ledger", "orders-prod"]);
        let checked: Vec<bool> = reviewing
            .connections
            .iter()
            .map(|widgets| widgets.check.is_active())
            .collect();
        // The duplicate of a saved connection and the engine with no driver start unchecked.
        assert_eq!(checked, [true, false, false]);
        assert!(
            !reviewing.connections[1].check.is_sensitive(),
            "a connection no driver opens can be picked"
        );
        let duplicate = reviewing.connections[2]
            .resolution
            .as_ref()
            .expect("a choice for the duplicate");
        assert!(
            !duplicate.is_visible(),
            "the duplicate's choice shows while it is unchecked"
        );
    }
    assert!(harness.pages().import_button().is_sensitive());
}

#[gtk4::test]
fn checking_a_duplicate_offers_its_choice_and_import_hands_over_the_plan() {
    let harness = Harness::new();
    wait_until(WAIT, || harness.sources_shown()).expect("the apps to be looked for");
    harness.pages().continue_button().emit_clicked();
    wait_until(WAIT, || harness.page().as_deref() == Some(pages::REVIEW)).expect("the review");

    let duplicate = {
        let reviewing = harness.pages().reviewing();
        let reviewing = reviewing.as_ref().expect("a review");
        (
            reviewing.connections[2].check.clone(),
            reviewing.connections[2].resolution.clone().expect("a choice"),
        )
    };
    duplicate.0.set_active(true);
    assert!(duplicate.1.is_visible());
    // The saved one verifies TLS and this one does not, so only a copy is offered, never Replace.
    assert_eq!(duplicate.1.model().map(|model| model.n_items()), Some(1));
    assert!(!duplicate.1.is_sensitive());

    harness.pages().import_button().emit_clicked();
    let imported = harness.imported.borrow();
    let (_, plan) = imported.as_ref().expect("the plan handed over");
    let planned: Vec<&str> = plan
        .connections()
        .iter()
        .map(|planned| planned.connection.name.as_str())
        .collect();
    assert_eq!(planned, ["billing", "orders-prod"]);
    assert!(plan.connections().iter().all(|planned| planned.replaces.is_none()));
    assert_eq!(harness.store.list_blocking().expect("the list").connections.len(), 1);
}

#[gtk4::test]
fn a_query_whose_name_another_row_takes_stays_unchecked_when_clicked() {
    let harness = Harness::new();
    wait_until(WAIT, || harness.sources_shown()).expect("the apps to be looked for");
    harness.pages().continue_button().emit_clicked();
    wait_until(WAIT, || harness.page().as_deref() == Some(pages::REVIEW)).expect("the review");

    let (first, second) = {
        let reviewing = harness.pages().reviewing();
        let reviewing = reviewing.as_ref().expect("a review");
        assert_eq!(reviewing.queries.len(), 2);
        (reviewing.queries[0].clone(), reviewing.queries[1].clone())
    };
    assert!(first.check.is_active());
    assert!(!second.check.is_active());
    assert!(
        !second.row.is_sensitive(),
        "a query the plan cannot take can be checked"
    );

    second.check.set_active(true);
    assert!(!second.check.is_active(), "the box shows a query the plan leaves out");

    first.check.set_active(false);
    assert!(
        second.check.is_active(),
        "the second query does not take the name once the first is unchecked"
    );
    assert!(second.row.is_sensitive());
}

fn listed(app: ForeignApp, availability: SourceAvailability, connections: usize) -> ForeignSource {
    ForeignSource {
        app,
        availability,
        inventory: Inventory {
            connections,
            saved_queries: 0,
        },
        password_offer: PasswordOffer::DecryptedWhileReading,
        offers_saved_queries: false,
    }
}

#[gtk4::test]
fn the_app_with_the_most_connections_is_picked_and_an_unreadable_one_says_why() {
    let harness = Harness::new();
    wait_until(WAIT, || harness.sources_shown()).expect("the apps to be looked for");
    let unreadable = SourceAvailability::Unreadable(UnreadableReason {
        code: "foreign_import.parse",
        detail: "failed to parse connections: data-sources.json".to_owned(),
    });

    harness.pages().show_sources_for_test(&[
        listed(ForeignApp::TablePlus, SourceAvailability::Available, 0),
        listed(ForeignApp::DBeaver, unreadable, 0),
        listed(ForeignApp::DataGrip, SourceAvailability::Available, 4),
        listed(ForeignApp::BeekeeperStudio, SourceAvailability::Available, 4),
        listed(ForeignApp::Navicat, SourceAvailability::Available, 0),
    ]);

    let pages = harness.pages();
    assert_eq!(pages.sources().len(), 5, "the rows of the first look stayed");
    let picked = |app| source_of(pages, app).is_some_and(|(_, check, _)| check.is_active());
    assert!(
        picked(ForeignApp::DataGrip),
        "the most connections, the earlier on a tie, is not the one picked"
    );
    assert!(
        !picked(ForeignApp::TablePlus),
        "an app with no connection was picked first"
    );
    assert!(!picked(ForeignApp::BeekeeperStudio));
    let (available, _, row) = source_of(pages, ForeignApp::DBeaver).expect("the DBeaver row");
    assert!(!available);
    assert!(!row.is_sensitive());
    assert_eq!(
        row.subtitle().as_deref(),
        Some("Found, but its files are in a form TablePro does not know"),
        "data that could not be read reads as a count of 0"
    );
    assert_eq!(
        row.tooltip_text().as_deref(),
        Some("failed to parse connections: data-sources.json")
    );
    assert!(pages.continue_button().is_sensitive());
}

#[gtk4::test]
fn with_no_app_available_nothing_is_picked() {
    let harness = Harness::new();
    wait_until(WAIT, || harness.sources_shown()).expect("the apps to be looked for");

    harness.pages().show_sources_for_test(&[
        listed(ForeignApp::TablePlus, SourceAvailability::NotFound, 0),
        listed(ForeignApp::DBeaver, SourceAvailability::NotFound, 0),
    ]);

    assert!(harness.pages().sources().iter().all(|row| !row.check.is_active()));
    assert!(!harness.pages().continue_button().is_sensitive());
}

#[gtk4::test]
fn a_search_that_fails_says_so_rather_than_listing_nothing() {
    let harness = Harness::new();
    wait_until(WAIT, || harness.sources_shown()).expect("the apps to be looked for");

    harness.pages().sources_scanned(Err(TaskFailure::Aborted));

    assert_eq!(harness.pages().sources_page().as_deref(), Some("scan-failed"));
    assert!(!harness.pages().continue_button().is_sensitive());
}

struct Queued {
    _runtime: crate::runtime::AppRuntime,
    _root: tempfile::TempDir,
    project: std::path::PathBuf,
    view: adw::NavigationView,
    pages: ImportPages,
    imported: Rc<RefCell<Vec<usize>>>,
    skipped: Rc<std::cell::Cell<usize>>,
    _window: crate::test_support::OwnedWindow<adw::Window>,
}

impl Queued {
    fn new(apps: Vec<ForeignApp>) -> Self {
        crate::register_test_resources();
        let runtime = test_runtime();
        let root = tempfile::tempdir().expect("tempdir");
        let dirs = dbeaver_home(root.path());
        let project = dirs.data.join("DBeaverData/workspace6/General/.dbeaver");
        let paths = StoragePaths::under(root.path(), "tablepro-test", "app.tablepro.TablePro.Devel");
        let view = adw::NavigationView::new();
        let host = adw::NavigationPage::builder()
            .tag("host")
            .title("Host")
            .child(&gtk::Label::new(None))
            .build();
        view.add(&host);
        let window = crate::test_support::OwnedWindow::new(adw::Window::new());
        window.set_content(Some(&view));
        window.present();
        let imported = Rc::new(RefCell::new(Vec::new()));
        let skipped = Rc::new(std::cell::Cell::new(0));
        let (sink, skips) = (imported.clone(), skipped.clone());
        let pages = ImportPages::new(ImportPagesInit {
            dirs,
            drivers: drivers(),
            connections: ConnectionStore::new(&paths),
            tasks: runtime.tasks(),
            mode: ImportPagesMode::Queue(apps),
            on_import: Box::new(move |_review: ImportReview, plan: ImportPlan| {
                sink.borrow_mut().push(plan.connections().len());
            }),
            on_cancel: Box::new(move || skips.set(skips.get() + 1)),
        });
        pages.attach(&view);
        Self {
            _runtime: runtime,
            _root: root,
            project,
            view,
            pages,
            imported,
            skipped,
            _window: window,
        }
    }

    fn stack(&self) -> Vec<String> {
        let stack = self.view.navigation_stack();
        (0..stack.n_items())
            .filter_map(|at| stack.item(at).and_downcast::<adw::NavigationPage>())
            .filter_map(|page| page.tag().map(|tag| tag.to_string()))
            .collect()
    }

    fn wait_for_review(&self) {
        wait_until(WAIT, || self.stack().last().map(String::as_str) == Some(pages::REVIEW)).expect("the review");
    }

    fn held_rows(&self) -> (Vec<adw::ActionRow>, Vec<adw::ActionRow>) {
        let reviewing = self.pages.reviewing();
        let reviewing = reviewing.as_ref().expect("a review");
        (
            reviewing.connections.iter().map(|row| row.row.clone()).collect(),
            reviewing.queries.iter().map(|row| row.row.clone()).collect(),
        )
    }

    fn shown_rows(&self) -> (Vec<adw::ActionRow>, Vec<adw::ActionRow>) {
        let (connections, queries) = self.pages.review_groups();
        (rows_in(&connections), rows_in(&queries))
    }
}

fn rows_in(group: &adw::PreferencesGroup) -> Vec<adw::ActionRow> {
    crate::test_support::descendants(group)
        .into_iter()
        .filter_map(|widget| widget.downcast::<adw::ActionRow>().ok())
        .collect()
}

#[gtk4::test]
fn a_queue_reviews_each_app_over_the_hosts_pages_and_hands_over_the_plan() {
    let queued = Queued::new(vec![ForeignApp::DBeaver]);

    queued.pages.start();
    wait_until(WAIT, || {
        queued.stack().last().map(String::as_str) == Some(pages::REVIEW)
    })
    .expect("the review");

    assert_eq!(
        queued.stack(),
        ["host", pages::REVIEW],
        "Back does not lead to the host's page"
    );
    queued.pages.import_button().emit_clicked();
    assert_eq!(
        *queued.imported.borrow(),
        [2],
        "the connections an engine opens were not imported"
    );
    assert_eq!(queued.stack(), ["host", pages::READING]);
    assert!(!queued.pages.next(), "a queue of one went on");
}

#[gtk4::test]
fn a_queue_goes_past_an_app_whose_rows_are_all_unticked() {
    let queued = Queued::new(vec![ForeignApp::DBeaver]);
    queued.pages.start();
    wait_until(WAIT, || {
        queued.stack().last().map(String::as_str) == Some(pages::REVIEW)
    })
    .expect("the review");

    let checks: Vec<gtk::CheckButton> = queued
        .pages
        .reviewing()
        .as_ref()
        .map(|reviewing| reviewing.connections.iter().map(|row| row.check.clone()).collect())
        .unwrap_or_default();
    for check in checks {
        check.set_active(false);
    }

    assert_eq!(queued.pages.import_button().label().as_deref(), Some("_Continue"));
    queued.pages.import_button().emit_clicked();
    assert_eq!(queued.skipped.get(), 1);
    assert!(queued.imported.borrow().is_empty());
}

#[gtk4::test]
fn cancelling_one_read_skips_its_app_and_the_next_read_still_runs() {
    let queued = Queued::new(vec![ForeignApp::DBeaver, ForeignApp::DBeaver]);
    queued.pages.start();
    let cancel = queued.pages.reading_cancel();
    assert!(cancel.is_visible(), "the guide's read offers no Cancel");

    cancel.emit_clicked();
    assert_eq!(queued.skipped.get(), 1, "Cancel did not move past the app");
    assert!(queued.pages.next(), "the queue stopped after a cancelled read");
    queued.wait_for_review();

    queued.pages.import_button().emit_clicked();
    assert!(!cancel.is_visible(), "a write offers Cancel");
}

#[gtk4::test]
fn the_next_app_s_review_shows_only_its_own_rows() {
    let queued = Queued::new(vec![ForeignApp::DBeaver, ForeignApp::DBeaver]);
    queued.pages.start();
    queued.wait_for_review();
    let (first_connections, first_queries) = queued.held_rows();
    assert_eq!(queued.shown_rows(), (first_connections.clone(), first_queries.clone()));
    queued.pages.import_button().emit_clicked();

    // The second read finds one connection, which both scripts still run on.
    write_text_file(
        &queued.project.join("data-sources.json"),
        r#"{"connections": {"mysql-billing": {"provider": "mysql", "name": "billing",
            "configuration": {"host": "billing.acme.example", "port": "3306", "user": "deploy"}}}}"#,
    );
    assert!(queued.pages.next(), "the queue stopped after its first app");
    queued.wait_for_review();

    let (connections, queries) = queued.held_rows();
    assert_eq!((connections.len(), queries.len()), (1, 2));
    assert_eq!(
        queued.shown_rows(),
        (connections, queries),
        "the first app's rows stayed on the second app's review"
    );
    assert!(
        first_connections
            .iter()
            .chain(&first_queries)
            .all(|row| row.parent().is_none()),
        "a row of the first review is still in a group"
    );
}
