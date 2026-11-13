use std::cell::RefCell;
use std::rc::Rc;
use std::time::Duration;

use tablepro_core::{AiPolicy, AuthMode, ExternalAccess, SafeModeLevel, TlsConfig};
use tablepro_foreign_import::ForeignPlatform;
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

fn drivers() -> Arc<DriverRegistry> {
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
        safe_mode: SafeModeLevel::Off,
        external_access: ExternalAccess::ReadOnly,
        ai_policy: AiPolicy::Ask,
        query_timeout_secs: None,
        masking_rules: Vec::new(),
        auth_mode: AuthMode::Password,
        ssh: None,
        last_opened_at: None,
        color: None,
        group_id: None,
        order: 0,
        tags: Vec::new(),
        icon: None,
        options: Default::default(),
    }
}

impl Harness {
    fn new() -> Self {
        crate::register_test_resources();
        let runtime = test_runtime();
        let root = tempfile::tempdir().expect("tempdir");
        let home = root.path().join("home");
        let dirs = ForeignAppDirs::conventional(ForeignPlatform::Linux, &home);
        let project = dirs.data.join("DBeaverData/workspace6/General/.dbeaver");
        std::fs::create_dir_all(&project).expect("the DBeaver project");
        write_text_file(&project.join("data-sources.json"), DATA_SOURCES);
        write_text_file(&project.join("project-metadata.json"), PROJECT_METADATA);
        let scripts = project.parent().expect("the project folder").join("Scripts");
        for folder in ["a", "b"] {
            std::fs::create_dir_all(scripts.join(folder)).expect("a scripts folder");
            write_text_file(&scripts.join(folder).join("Report.sql"), &format!("SELECT '{folder}'"));
        }

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

    fn source(&self, app: ForeignApp) -> Option<(bool, gtk::CheckButton)> {
        self.dialog
            .imp()
            .sources
            .borrow()
            .iter()
            .find(|row| row.app == app)
            .map(|row| (row.available, row.check.clone()))
    }

    fn sources_shown(&self) -> bool {
        self.dialog.imp().sources_stack.visible_child_name().as_deref() == Some("sources")
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
    assert!(harness.dialog.imp().continue_button.is_sensitive());

    harness.dialog.imp().continue_button.emit_clicked();
    wait_until(WAIT, || harness.page().as_deref() == Some("review")).expect("the review");

    let imp = harness.dialog.imp();
    {
        let reviewing = imp.reviewing.borrow();
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
    assert!(imp.import_button.is_sensitive());
}

#[gtk4::test]
fn checking_a_duplicate_offers_its_choice_and_import_hands_over_the_plan() {
    let harness = Harness::new();
    wait_until(WAIT, || harness.sources_shown()).expect("the apps to be looked for");
    harness.dialog.imp().continue_button.emit_clicked();
    wait_until(WAIT, || harness.page().as_deref() == Some("review")).expect("the review");

    let duplicate = {
        let reviewing = harness.dialog.imp().reviewing.borrow();
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

    harness.dialog.imp().import_button.emit_clicked();
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
    harness.dialog.imp().continue_button.emit_clicked();
    wait_until(WAIT, || harness.page().as_deref() == Some("review")).expect("the review");

    let (first, second) = {
        let reviewing = harness.dialog.imp().reviewing.borrow();
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
