use std::sync::Arc;
use std::time::Duration;

use gtk4::{AccessibleProperty, AccessibleState};
use tablepro_core::credentials::{CredentialInteraction, SecretKind};
use tablepro_core::{DriverError, FileOpenMode, TlsFailure, TlsMode};
use tablepro_session::RequestTarget;
use tablepro_session::fakes::{FakeConnector, FakeEstablish};
use tablepro_test_support::ConnectionScript;

use super::*;
use crate::test_support::{SignalLog, assert_labelled, wait_until};
use crate::ui::ssh_inputs::SshAuthChoice;

const WAIT: Duration = Duration::from_secs(10);

struct Harness {
    dialog: ConnectDialog,
    connector: FakeConnector,
    _runtime: crate::runtime::AppRuntime,
}

struct Options {
    connector: FakeConnector,
    remembered: &'static str,
    environment: SshEnvironment,
    saved: Vec<SavedConnection>,
    prefill: Option<ConnectPrefill>,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            connector: FakeConnector::new([]),
            remembered: "postgres",
            environment: SshEnvironment::default(),
            saved: Vec::new(),
            prefill: None,
        }
    }
}

fn registry() -> Arc<DriverRegistry> {
    let mut registry = DriverRegistry::new();
    registry.register(Arc::new(drivers_clickhouse::ClickhouseDriver));
    registry.register(Arc::new(drivers_mssql::MssqlDriver));
    registry.register(Arc::new(drivers_mysql::MysqlDriver));
    registry.register(Arc::new(drivers_postgres::PgDriver));
    registry.register(Arc::new(drivers_sqlite::SqliteDriver));
    Arc::new(registry)
}

/// Every driver the app ships, so the combo has the shape a user sees.
fn open(options: Options) -> Harness {
    let _ = adw::init();
    crate::register_test_resources();
    let runtime = crate::test_support::test_runtime();
    let dialog = ConnectDialog::new(ConnectDialogInit {
        drivers: registry(),
        connector: Arc::new(options.connector.clone()),
        interaction: CredentialInteraction::Unattended,
        tasks: runtime.tasks(),
        saved_connections: Arc::from(options.saved),
        remembered_driver: options.remembered.to_owned(),
        ssh_environment: options.environment,
        prefill: options.prefill,
    });
    Harness {
        dialog,
        connector: options.connector,
        _runtime: runtime,
    }
}

fn dialog() -> Harness {
    open(Options::default())
}

fn select(dialog: &ConnectDialog, driver_id: &str) {
    let index = dialog
        .imp()
        .drivers
        .borrow()
        .iter()
        .position(|entry| entry.id == driver_id)
        .unwrap_or_else(|| panic!("{driver_id} is not in the combo"));
    dialog.imp().driver_row.set_selected(index as u32);
}

fn fill_network(dialog: &ConnectDialog) {
    let imp = dialog.imp();
    imp.host_row.set_text("db.example.com");
    imp.database_row.set_text("sales");
    imp.username_row.set_text("app");
    imp.password_row.set_text("s3cret");
}

fn caps_of(driver_id: &str) -> &'static DriverCapabilities {
    registry()
        .get(driver_id)
        .map(|driver| driver.capabilities())
        .unwrap_or_else(|| panic!("{driver_id} is registered"))
}

#[gtk4::test]
fn dialog_opens_with_remembered_driver_and_its_port() {
    let harness = open(Options {
        remembered: "clickhouse",
        ..Options::default()
    });
    let imp = harness.dialog.imp();

    assert_eq!(harness.dialog.form().driver_id, "clickhouse");
    assert_eq!(imp.port_row.value() as u16, 8123);
    assert_eq!(imp.host_row.text(), "", "the host was prefilled instead of left empty");
    assert_eq!(imp.username_row.text(), "");
}

#[gtk4::test]
fn an_uninstalled_remembered_driver_falls_back_to_postgres() {
    let harness = open(Options {
        remembered: "cassandra",
        ..Options::default()
    });

    assert_eq!(harness.dialog.form().driver_id, "postgres");
}

#[gtk4::test]
fn driver_switch_keeps_user_edited_port() {
    let harness = dialog();
    harness.dialog.imp().port_row.set_value(6543.0);

    select(&harness.dialog, "clickhouse");

    assert_eq!(
        harness.dialog.imp().port_row.value() as u16,
        6543,
        "a driver switch overwrote a port the user typed"
    );
}

#[gtk4::test]
fn a_driver_switch_moves_an_untouched_port() {
    let harness = dialog();
    assert_eq!(harness.dialog.imp().port_row.value() as u16, 5432);

    select(&harness.dialog, "clickhouse");

    assert_eq!(harness.dialog.imp().port_row.value() as u16, 8123);
}

#[gtk4::test]
fn driver_switch_keeps_typed_host_and_user() {
    let harness = dialog();
    fill_network(&harness.dialog);

    select(&harness.dialog, "sqlite");
    select(&harness.dialog, "clickhouse");

    let imp = harness.dialog.imp();
    assert_eq!(imp.host_row.text(), "db.example.com");
    assert_eq!(imp.database_row.text(), "sales");
    assert_eq!(imp.username_row.text(), "app");
}

#[gtk4::test]
fn enter_in_any_text_row_reaches_connect() {
    // Enter needs both halves: activates-default on the row, which is
    // what makes AdwEntryRow call gtk_widget_activate_default, and
    // Connect as the dialog's default widget for it to reach.
    let harness = dialog();
    let imp = harness.dialog.imp();

    assert!(imp.host_row.activates_default(), "host");
    assert!(imp.database_row.activates_default(), "database");
    assert!(imp.username_row.activates_default(), "username");
    assert!(imp.password_row.activates_default(), "password");
    assert!(
        imp.tls_section.imp().server_name_row.activates_default(),
        "TLS server name"
    );
    assert_eq!(
        harness.dialog.default_widget(),
        Some(imp.connect_button.get().upcast::<gtk4::Widget>()),
        "Connect is not the dialog's default widget"
    );
}

#[gtk4::test]
fn every_ssh_text_row_submits_on_enter() {
    let harness = dialog();

    for (name, activates) in harness.dialog.imp().ssh_section.rows_activating_default() {
        assert!(activates, "{name} does not submit on Enter");
    }
}

#[gtk4::test]
fn connect_stays_insensitive_until_the_form_is_valid() {
    // Enter on an invalid form does nothing because AdwDialog skips an
    // insensitive default widget.
    let harness = dialog();
    let imp = harness.dialog.imp();
    assert!(
        !imp.connect_button.is_sensitive(),
        "Connect was sensitive on an empty form"
    );
    assert!(
        imp.connect_button.tooltip_text().is_some(),
        "an insensitive Connect does not say why"
    );
    assert!(
        !imp.host_row.has_css_class("error"),
        "an untouched empty row is painted red"
    );

    fill_network(&harness.dialog);

    assert!(
        imp.connect_button.is_sensitive(),
        "Connect stayed insensitive on a valid form"
    );
    assert!(imp.test_button.is_sensitive());
}

#[gtk4::test]
fn a_bad_host_is_marked_for_sight_and_for_screen_readers() {
    let harness = dialog();
    fill_network(&harness.dialog);
    let host = harness.dialog.imp().host_row.get();

    host.set_text("db example.com");

    assert!(host.has_css_class("error"));
    assert!(gtk4::test_accessible_has_state(
        host.upcast_ref::<gtk4::Widget>(),
        AccessibleState::Invalid
    ));
    assert!(host.tooltip_text().is_some());

    host.set_text("db.example.com");

    assert!(!host.has_css_class("error"));
    assert!(!gtk4::test_accessible_has_state(
        host.upcast_ref::<gtk4::Widget>(),
        AccessibleState::Invalid
    ));
}

#[gtk4::test]
fn encryption_combo_lists_only_capability_modes() {
    let harness = dialog();
    for driver_id in ["postgres", "mysql", "mssql", "clickhouse"] {
        select(&harness.dialog, driver_id);
        let section = harness.dialog.imp().tls_section.get();
        let tls = caps_of(driver_id).tls.expect("a network driver with TLS");

        assert!(section.is_visible(), "{driver_id}");
        assert_eq!(
            section.imp().encryption_modes.n_items() as usize,
            tls.modes.len(),
            "{driver_id}"
        );
        assert_eq!(harness.dialog.form().tls.mode, TlsMode::VerifyFull, "{driver_id}");
    }
}

#[gtk4::test]
fn sqlite_shows_file_row_and_hides_security_and_ssh() {
    let harness = dialog();

    select(&harness.dialog, "sqlite");

    let imp = harness.dialog.imp();
    assert!(imp.file_row.is_visible());
    assert!(!imp.host_row.is_visible());
    assert!(!imp.port_row.is_visible());
    assert!(!imp.database_row.is_visible());
    assert!(!imp.auth_group.is_visible());
    assert!(!imp.tls_section.is_visible());
    assert!(!imp.ssh_section.is_visible());

    select(&harness.dialog, "postgres");
    assert!(!imp.file_row.is_visible());
    assert!(imp.tls_section.is_visible());
    assert!(imp.ssh_section.is_visible());
}

#[gtk4::test]
fn new_database_sets_create_new_endpoint() {
    let harness = dialog();
    select(&harness.dialog, "sqlite");
    let root = tempfile::tempdir().expect("tempdir");
    let path = root.path().join("Untitled.sqlite3");

    harness
        .dialog
        .imp()
        .file_row
        .adopt_choice(path.clone(), FileOpenMode::CreateNew);

    let file = harness.dialog.form().file.expect("a file");
    assert_eq!(file.path(), path);
    assert_eq!(file.mode(), FileOpenMode::CreateNew);
    assert!(harness.dialog.imp().connect_button.is_sensitive());
}

#[gtk4::test]
fn mysql_requires_database() {
    let harness = dialog();
    select(&harness.dialog, "mysql");
    fill_network(&harness.dialog);
    let imp = harness.dialog.imp();
    assert!(imp.connect_button.is_sensitive());

    imp.database_row.set_text("");

    assert!(!imp.connect_button.is_sensitive(), "MySQL connected with no database");
    select(&harness.dialog, "postgres");
    assert!(imp.connect_button.is_sensitive(), "PostgreSQL needs no database name");
}

#[gtk4::test]
fn read_only_subtitle_follows_enforcement() {
    let harness = dialog();
    for driver_id in ["postgres", "mysql", "mssql", "clickhouse", "sqlite"] {
        select(&harness.dialog, driver_id);

        assert_eq!(
            harness
                .dialog
                .imp()
                .read_only_row
                .subtitle()
                .map(|text| text.to_string()),
            Some(read_only_row::read_only_subtitle(caps_of(driver_id).read_only)),
            "{driver_id}"
        );
    }
}

#[gtk4::test]
fn connect_insensitive_while_pem_check_pending() {
    let harness = dialog();
    fill_network(&harness.dialog);
    let root = tempfile::tempdir().expect("tempdir");
    let ca = root.path().join("ca.pem");
    std::fs::write(&ca, b"-----BEGIN CERTIFICATE-----\nnot base64\n").expect("write");

    harness
        .dialog
        .imp()
        .tls_section
        .set_file_path(FormField::CaFile, Some(ca));

    assert_eq!(harness.dialog.imp().pem.state(), PemState::Pending);
    assert!(
        !harness.dialog.imp().connect_button.is_sensitive(),
        "Connect was sensitive before the file was read"
    );
}

#[gtk4::test]
fn invalid_ca_marks_row_error_and_disables_connect() {
    let harness = dialog();
    fill_network(&harness.dialog);
    let root = tempfile::tempdir().expect("tempdir");
    let ca = root.path().join("ca.pem");
    std::fs::write(&ca, b"this is not a certificate").expect("write");
    let imp = harness.dialog.imp();

    imp.tls_section.set_file_path(FormField::CaFile, Some(ca));
    wait_until(WAIT, || matches!(imp.pem.state(), PemState::Invalid(_))).expect("the file check");

    let ca_row = imp.tls_section.imp().ca_row.get();
    assert!(ca_row.has_css_class("error"));
    assert!(gtk4::test_accessible_has_state(
        ca_row.upcast_ref::<gtk4::Widget>(),
        AccessibleState::Invalid
    ));
    assert!(
        ca_row
            .subtitle()
            .is_some_and(|subtitle| subtitle.contains("no certificates")),
        "{:?}",
        ca_row.subtitle()
    );
    assert!(!imp.connect_button.is_sensitive());

    imp.tls_section.set_file_path(FormField::CaFile, None);
    assert_eq!(imp.pem.state(), PemState::Valid);
    assert!(
        imp.connect_button.is_sensitive(),
        "clearing the bad file did not re-enable Connect"
    );
}

#[gtk4::test]
fn connect_emits_submission_without_establishing() {
    let harness = dialog();
    fill_network(&harness.dialog);
    let submissions = SignalLog::connect(&harness.dialog, "submitted", |values| {
        values[1].get::<ConnectSubmission>().expect("a submission")
    });

    harness.dialog.imp().connect_button.emit_clicked();

    let mut sent = submissions.take();
    assert_eq!(sent.len(), 1);
    assert!(harness.connector.calls().is_empty(), "the dialog connected by itself");
    let submission = sent.remove(0);
    assert_eq!(submission.request.metadata.driver_id, "postgres");
    assert_eq!(submission.request.metadata.id, submission.pending_save.connection.id);
    assert!(submission.pending_save.is_new);
    assert_eq!(submission.pending_save.connection.host, "db.example.com");
    let kinds: Vec<SecretKind> = submission
        .pending_save
        .secrets
        .iter()
        .map(|secret| secret.kind)
        .collect();
    assert_eq!(kinds, vec![SecretKind::DatabasePassword]);
    let RequestTarget::Network { tls, .. } = &submission.request.target else {
        panic!("expected a network target");
    };
    assert_eq!(tls.mode, TlsMode::VerifyFull);
}

#[gtk4::test]
fn a_reopened_entry_keeps_its_id_after_the_host_changes() {
    let first = dialog();
    fill_network(&first.dialog);
    let log = SignalLog::connect(&first.dialog, "submitted", |values| {
        values[1].get::<ConnectSubmission>().expect("a submission")
    });
    first.dialog.imp().connect_button.emit_clicked();
    let saved = log.take().remove(0).pending_save.connection;
    drop(log);

    let reopened = open(Options {
        saved: vec![saved.clone()],
        prefill: Some(ConnectPrefill {
            connection: saved.clone(),
            password: Some(SecretString::from("s3cret")),
        }),
        ..Options::default()
    });
    assert_eq!(reopened.dialog.imp().host_row.text(), "db.example.com");
    assert_eq!(reopened.dialog.imp().password_row.text(), "s3cret");
    reopened.dialog.imp().host_row.set_text("db2.example.com");
    let log = SignalLog::connect(&reopened.dialog, "submitted", |values| {
        values[1].get::<ConnectSubmission>().expect("a submission")
    });
    reopened.dialog.imp().connect_button.emit_clicked();

    let edited = log.take().remove(0).pending_save;
    assert_eq!(edited.connection.id, saved.id);
    assert!(!edited.is_new);
    assert_eq!(edited.connection.host, "db2.example.com");
}

#[gtk4::test]
fn test_button_stop_cancels_establish() {
    let harness = open(Options {
        connector: FakeConnector::new([]).always(FakeEstablish::UntilCancelled),
        ..Options::default()
    });
    fill_network(&harness.dialog);
    let imp = harness.dialog.imp();

    imp.test_button.emit_clicked();
    assert_eq!(imp.test_button.label().as_deref(), Some("Stop"));
    wait_until(WAIT, || harness.connector.calls().len() == 1).expect("the test connect");

    imp.test_button.emit_clicked();

    assert_eq!(imp.test_button.label().as_deref(), Some("Test"));
    crate::test_support::drain_main_context();
    assert!(imp.toasts.borrow().is_empty(), "a stopped test reported something");
}

#[gtk4::test]
fn test_success_toast_has_no_count() {
    let harness = open(Options {
        connector: FakeConnector::new([FakeEstablish::Connect(ConnectionScript::default())]),
        ..Options::default()
    });
    fill_network(&harness.dialog);
    let imp = harness.dialog.imp();

    imp.test_button.emit_clicked();
    wait_until(WAIT, || !imp.toasts.borrow().is_empty()).expect("the test result");

    assert_eq!(imp.toasts.borrow().as_slice(), ["Connection works"]);
    assert_eq!(imp.test_button.label().as_deref(), Some("Test"));
    let connections = harness.connector.connections();
    assert_eq!(connections.len(), 1);
    assert_eq!(harness.connector.calls()[0].request.metadata.driver_id, "postgres");
}

#[gtk4::test]
fn a_failed_test_names_the_problem() {
    let harness = open(Options {
        connector: FakeConnector::new([FakeEstablish::Fail(ConnectError::Driver(DriverError::Tls {
            failure: TlsFailure::UnknownIssuer,
            detail: "unknown issuer".to_owned(),
        }))]),
        ..Options::default()
    });
    fill_network(&harness.dialog);
    let imp = harness.dialog.imp();

    imp.test_button.emit_clicked();
    wait_until(WAIT, || !imp.toasts.borrow().is_empty()).expect("the test result");

    let toast = imp.toasts.borrow()[0].clone();
    assert!(toast.contains("CA certificate"), "{toast}");
}

#[gtk4::test]
fn the_tls_remedy_opens_the_certificate_rows() {
    let harness = dialog();
    let section = harness.dialog.imp().tls_section.get();
    assert!(!section.imp().certificates_row.is_expanded());

    harness
        .dialog
        .reveal_field(remedy_field(TlsRemedy::ChooseCaCertificate));

    assert!(section.imp().certificates_row.is_expanded());
}

#[gtk4::test]
fn agent_is_default_with_ssh_auth_sock() {
    let with_agent = open(Options {
        environment: SshEnvironment {
            agent: true,
            default_key: Some("/home/u/.ssh/id_ed25519".into()),
        },
        ..Options::default()
    });
    let section = with_agent.dialog.imp().ssh_section.get();
    section.enable();
    assert_eq!(section.form_state().map(|state| state.auth), Some(SshAuthChoice::Agent));

    let key_only = open(Options {
        environment: SshEnvironment {
            agent: false,
            default_key: Some("/home/u/.ssh/id_ed25519".into()),
        },
        ..Options::default()
    });
    let section = key_only.dialog.imp().ssh_section.get();
    section.enable();
    let state = section.form_state().expect("the tunnel is on");
    assert_eq!(state.auth, SshAuthChoice::PrivateKey);
    assert_eq!(state.key_path, "/home/u/.ssh/id_ed25519");
}

#[gtk4::test]
fn an_ssh_alias_alone_is_enough_to_connect() {
    let harness = open(Options {
        environment: SshEnvironment {
            agent: true,
            default_key: None,
        },
        ..Options::default()
    });
    fill_network(&harness.dialog);
    let section = harness.dialog.imp().ssh_section.get();

    section.enable();
    assert!(
        !harness.dialog.imp().connect_button.is_sensitive(),
        "an empty SSH host passed"
    );
    section.set_host("prod-bastion");

    assert!(harness.dialog.imp().connect_button.is_sensitive());
    let RequestTarget::Network { ssh, .. } = harness
        .dialog
        .form()
        .validate(caps_of("postgres"))
        .expect("valid")
        .target
    else {
        panic!("expected a network target");
    };
    let ssh = ssh.expect("the tunnel is on");
    assert_eq!(ssh.destination.host(), "prod-bastion");
    assert_eq!(ssh.destination.port(), None);
    assert_eq!(ssh.destination.user(), None);
}

#[gtk4::test]
fn every_row_has_an_accessible_name() {
    let harness = dialog();
    let imp = harness.dialog.imp();
    let tls = imp.tls_section.imp();
    let rows: Vec<gtk4::Widget> = vec![
        imp.driver_row.get().upcast(),
        imp.host_row.get().upcast(),
        imp.port_row.get().upcast(),
        imp.database_row.get().upcast(),
        imp.file_row.get().upcast(),
        imp.auth_mode_row.get().upcast(),
        imp.username_row.get().upcast(),
        imp.password_row.get().upcast(),
        imp.remember_row.get().upcast(),
        imp.read_only_row.get().upcast(),
        tls.encryption_row.get().upcast(),
        tls.certificates_row.get().upcast(),
        tls.ca_row.get().upcast(),
        tls.certificate_row.get().upcast(),
        tls.key_row.get().upcast(),
        tls.server_name_row.get().upcast(),
    ];
    let rows = rows.into_iter().chain(imp.ssh_section.rows());
    for row in rows {
        assert_labelled(&row).unwrap_or_else(|problem| panic!("{problem:?}"));
    }

    for button in [
        tls.ca_clear_button.get(),
        tls.certificate_clear_button.get(),
        tls.key_clear_button.get(),
        tls.ca_choose_button.get(),
    ] {
        assert!(
            gtk4::test_accessible_has_property(&button, AccessibleProperty::Label),
            "{:?} has no accessible name",
            button.tooltip_text()
        );
    }
}
