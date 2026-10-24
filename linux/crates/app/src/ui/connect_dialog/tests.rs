use std::sync::Arc;
use std::time::Duration;

use gtk4::{AccessibleProperty, AccessibleState};
use tablepro_core::credentials::{CredentialInteraction, SecretKind, SecretVault};
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
    store: tablepro_storage::ConnectionStore,
    vault: Arc<tablepro_test_support::FakeSecretVault>,
    _runtime: crate::runtime::AppRuntime,
    _dir: tempfile::TempDir,
}

struct Options {
    connector: FakeConnector,
    remembered: &'static str,
    environment: SshEnvironment,
    saved: Vec<SavedConnection>,
    prefill: Option<ConnectPrefill>,
    mode: ConnectDialogMode,
    tags: Vec<tablepro_storage::ConnectionTag>,
    ai_assistant: bool,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            connector: FakeConnector::new([]),
            remembered: "postgres",
            environment: SshEnvironment::default(),
            saved: Vec::new(),
            prefill: None,
            mode: ConnectDialogMode::Create,
            tags: Vec::new(),
            ai_assistant: false,
        }
    }
}

fn registry() -> Arc<DriverRegistry> {
    let mut registry = DriverRegistry::new();
    registry.register(Arc::new(tablepro_driver_cassandra::CassandraDriver));
    registry.register(Arc::new(tablepro_driver_clickhouse::ClickhouseDriver));
    registry.register(Arc::new(tablepro_driver_duckdb::DuckDbDriver));
    registry.register(Arc::new(tablepro_driver_mongodb::MongoDriver));
    registry.register(Arc::new(tablepro_driver_mssql::MssqlDriver));
    registry.register(Arc::new(tablepro_driver_mysql::MysqlDriver));
    registry.register(Arc::new(tablepro_driver_postgres::PgDriver));
    registry.register(Arc::new(tablepro_driver_redis::RedisDriver));
    registry.register(Arc::new(tablepro_driver_sqlite::SqliteDriver));
    Arc::new(registry)
}

/// Every driver the app ships, so the combo has the shape a user sees.
fn open(options: Options) -> Harness {
    let _ = adw::init();
    crate::register_test_resources();
    let runtime = crate::test_support::test_runtime();
    let dir = tempfile::tempdir().expect("a temporary directory");
    let store = tablepro_storage::ConnectionStore::new(&tablepro_storage::StoragePaths::under(
        dir.path(),
        "tablepro",
        crate::config::APP_ID,
    ));
    // Written as a file so the entries keep the tags' ids.
    #[derive(serde::Serialize)]
    struct Seeded<'a> {
        version: u32,
        connections: &'a [SavedConnection],
        tags: &'a [tablepro_storage::ConnectionTag],
    }
    let seeded = Seeded {
        version: 2,
        connections: &options.saved,
        tags: &options.tags,
    };
    let file = store.path().to_owned();
    std::fs::create_dir_all(file.parent().expect("a folder")).expect("the folder");
    std::fs::write(&file, serde_json::to_vec(&seeded).expect("the list")).expect("the file");
    let vault = Arc::new(tablepro_test_support::FakeSecretVault::new());
    let dialog = ConnectDialog::new(ConnectDialogInit {
        drivers: registry(),
        connector: Arc::new(options.connector.clone()),
        interaction: CredentialInteraction::Unattended,
        tasks: runtime.tasks(),
        saved_connections: Arc::from(options.saved),
        tags: Arc::from(options.tags),
        remembered_driver: options.remembered.to_owned(),
        ai_assistant: options.ai_assistant,
        ssh_environment: options.environment,
        prefill: options.prefill,
        mode: options.mode,
        editor: crate::services::saved_connection_editor::SavedConnectionEditor::new(
            store.clone(),
            vault.clone(),
            runtime.tasks(),
        ),
        credentials: std::rc::Rc::new(crate::services::session_context::KeyringSources::new(vault.clone())),
        hold: std::rc::Rc::new(tablepro_session::runtime::CountingHold::new()),
    });
    Harness {
        dialog,
        connector: options.connector,
        store,
        vault,
        _runtime: runtime,
        _dir: dir,
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

/// The dialog in a window, as the app shows it before anyone can press
/// Connect or Save. Without animations it closes before the next line.
fn present(dialog: &ConnectDialog) -> crate::test_support::OwnedWindow<adw::Window> {
    if let Some(settings) = gtk4::Settings::default() {
        settings.set_gtk_enable_animations(false);
    }
    let window = crate::test_support::OwnedWindow::presented(
        adw::Window::builder().default_width(1000).default_height(700).build(),
    );
    dialog.present(Some(&*window));
    window
}

/// Runs `step` with GLib criticals fatal, so a close of a dialog that
/// is not presented aborts the test.
fn without_criticals(step: impl FnOnce()) {
    let previous = glib::log_set_always_fatal(glib::LogLevels::LEVEL_CRITICAL);
    step();
    crate::test_support::drain_main_context();
    glib::log_set_always_fatal(previous);
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
        remembered: "retired-engine",
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

    // The focus is in the row's text field, which is what a reader reads.
    let field = host.delegate().expect("the row's text field");

    host.set_text("db example.com");

    assert!(host.has_css_class("error"));
    for widget in [host.upcast_ref::<gtk4::Widget>(), field.upcast_ref()] {
        assert!(gtk4::test_accessible_has_state(widget, AccessibleState::Invalid));
    }
    assert!(gtk4::test_accessible_has_property(
        &field,
        gtk4::AccessibleProperty::Description
    ));
    assert!(host.tooltip_text().is_some());

    host.set_text("db.example.com");

    assert!(!host.has_css_class("error"));
    for widget in [host.upcast_ref::<gtk4::Widget>(), field.upcast_ref()] {
        assert!(!gtk4::test_accessible_has_state(widget, AccessibleState::Invalid));
    }
}

#[gtk4::test]
fn encryption_combo_lists_only_capability_modes() {
    let harness = dialog();
    for driver_id in ["postgres", "mysql", "mssql", "clickhouse", "cassandra"] {
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

/// Each encryption mode and SSH method beside the subtitle that
/// describes it, in the dialog at its own width.
#[gtk4::test]
fn a_described_choice_shows_its_whole_value() {
    let harness = dialog();
    let window = present(&harness.dialog);
    let ssh = harness.dialog.imp().ssh_section.get();
    ssh.enable();
    let rows = [
        harness.dialog.imp().tls_section.imp().encryption_row.get(),
        ssh.imp().auth_row.get(),
    ];

    for row in rows {
        let choices = row.model().expect("the choices");
        for index in 0..choices.n_items() {
            row.set_selected(index);
            let choice = row
                .selected_item()
                .and_downcast::<gtk4::StringObject>()
                .expect("a choice")
                .string();
            let whole = wait_until(WAIT, || {
                crate::ui::combo_value::shown_value(&row).is_some_and(|value| {
                    value.label() == choice && value.width() > 0 && !value.layout().is_ellipsized()
                })
            });
            assert!(whole.is_ok(), "{choice} was cut beside {:?}", row.subtitle());
        }
    }
    window.close();
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
fn mongodb_offers_a_seed_list_that_hides_the_port_and_a_login_database() {
    let harness = dialog();
    let imp = harness.dialog.imp();

    select(&harness.dialog, "postgres");
    assert!(!imp.seed_list_row.is_visible());
    assert!(!imp.auth_database_row.is_visible());

    select(&harness.dialog, "mongodb");
    assert!(imp.seed_list_row.is_visible());
    assert!(imp.auth_database_row.is_visible());
    assert!(imp.port_row.is_visible());
    imp.seed_list_row.set_active(true);
    assert!(!imp.port_row.is_visible(), "the SRV records give the ports");

    select(&harness.dialog, "postgres");
    assert!(imp.port_row.is_visible());
    assert!(!imp.seed_list_row.is_visible());
}

#[gtk4::test]
fn file_paths_with_markup_characters_show_as_written() {
    let harness = dialog();
    let imp = harness.dialog.imp();
    let path = std::path::PathBuf::from("/data/R&D <team>/ca.pem");

    imp.tls_section.set_file_path(FormField::CaFile, Some(path.clone()));

    let tls = imp.tls_section.imp();
    for row in [tls.ca_row.get(), tls.certificate_row.get(), tls.key_row.get()] {
        assert!(!row.uses_markup(), "{}", row.title());
    }
    assert!(!imp.file_row.uses_markup());
    assert_eq!(
        tls.ca_row.subtitle().as_deref(),
        Some(path.display().to_string().as_str())
    );
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
fn safe_mode_subtitle_follows_the_level_and_the_enforcement() {
    let harness = dialog();
    let imp = harness.dialog.imp();
    let shown = || imp.safe_mode_row.subtitle().map(|text| text.to_string());
    for driver_id in ["postgres", "mysql", "mssql", "clickhouse", "sqlite", "cassandra"] {
        select(&harness.dialog, driver_id);
        let engine = registry()
            .get(driver_id)
            .map(|driver| driver.display_name().to_owned())
            .unwrap_or_default();
        for (index, level) in SafeModeLevel::ALL.into_iter().enumerate() {
            imp.safe_mode_row.set_selected(index as u32);

            assert_eq!(harness.dialog.form().safe_mode, level, "{driver_id}");
            assert_eq!(
                shown(),
                Some(crate::ui::safe_mode::subtitle(level, caps_of(driver_id), &engine)),
                "{driver_id} {level:?}"
            );
        }
    }
}

#[gtk4::test]
fn an_edit_opens_on_the_saved_level_and_keeps_it() {
    let saved = SavedConnection {
        safe_mode: SafeModeLevel::ConfirmWrites,
        ..shop()
    };
    let harness = open(Options {
        saved: vec![saved.clone()],
        mode: ConnectDialogMode::Edit(Box::new(saved)),
        ..Options::default()
    });

    let imp = harness.dialog.imp();

    assert_eq!(imp.safe_mode_row.selected(), 1);
    assert_eq!(harness.dialog.form().safe_mode, SafeModeLevel::ConfirmWrites);
}

#[gtk4::test]
fn the_external_clients_row_reads_back_each_level_and_says_what_it_allows() {
    let harness = dialog();
    let imp = harness.dialog.imp();

    assert_eq!(harness.dialog.form().external_access, ExternalAccess::ReadOnly);
    for (index, access) in ExternalAccess::ALL.into_iter().enumerate() {
        imp.external_access_row.set_selected(index as u32);

        assert_eq!(harness.dialog.form().external_access, access);
        assert_eq!(
            imp.external_access_row.subtitle().map(|text| text.to_string()),
            Some(crate::ui::external_access::subtitle(access)),
            "{access:?}"
        );
    }
}

#[gtk4::test]
fn an_edit_opens_on_the_saved_external_clients_level_and_saves_it() {
    let saved = SavedConnection {
        external_access: ExternalAccess::Blocked,
        ..shop()
    };
    let harness = open(Options {
        saved: vec![saved.clone()],
        mode: ConnectDialogMode::Edit(Box::new(saved)),
        ..Options::default()
    });
    let imp = harness.dialog.imp();

    assert_eq!(imp.external_access_row.selected(), 0);
    imp.external_access_row.set_selected(2);
    select(&harness.dialog, "mysql");

    assert_eq!(harness.dialog.form().external_access, ExternalAccess::ReadWrite);
}

#[gtk4::test]
fn the_ai_policy_row_shows_only_while_a_provider_answers() {
    let off = dialog();
    let on = open(Options {
        ai_assistant: true,
        ..Options::default()
    });

    assert!(!off.dialog.imp().ai_policy_row.is_visible());
    assert!(on.dialog.imp().ai_policy_row.is_visible());
}

#[gtk4::test]
fn each_ai_policy_says_what_it_sends() {
    let harness = open(Options {
        ai_assistant: true,
        ..Options::default()
    });
    let imp = harness.dialog.imp();

    assert_eq!(harness.dialog.form().ai_policy, AiPolicy::Ask);
    for (index, policy) in AiPolicy::ALL.into_iter().enumerate() {
        imp.ai_policy_row.set_selected(index as u32);

        assert_eq!(harness.dialog.form().ai_policy, policy);
        assert_eq!(
            imp.ai_policy_row.subtitle().map(|text| text.to_string()),
            Some(crate::ui::ai_policy::subtitle(policy)),
            "{policy:?}"
        );
    }
}

#[gtk4::test]
fn an_edit_opens_on_the_saved_ai_policy_and_keeps_it_across_a_driver_change() {
    let saved = SavedConnection {
        ai_policy: AiPolicy::Never,
        ..shop()
    };
    let harness = open(Options {
        saved: vec![saved.clone()],
        mode: ConnectDialogMode::Edit(Box::new(saved)),
        ai_assistant: true,
        ..Options::default()
    });
    let imp = harness.dialog.imp();

    assert_eq!(imp.ai_policy_row.selected(), 2);
    imp.ai_policy_row.set_selected(1);
    select(&harness.dialog, "mysql");

    assert_eq!(harness.dialog.form().ai_policy, AiPolicy::Allow);
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
    let _window = present(&harness.dialog);
    fill_network(&harness.dialog);
    let submissions = SignalLog::connect(&harness.dialog, "submitted", |values| {
        values[1].get::<ConnectSubmission>().expect("a submission")
    });
    let closed = SignalLog::connect(&harness.dialog, "closed", |_| ());

    without_criticals(|| harness.dialog.imp().connect_button.emit_clicked());

    assert_eq!(closed.count(), 1, "Connect left the dialog open");
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
    let _first_window = present(&first.dialog);
    fill_network(&first.dialog);
    let log = SignalLog::connect(&first.dialog, "submitted", |values| {
        values[1].get::<ConnectSubmission>().expect("a submission")
    });
    without_criticals(|| first.dialog.imp().connect_button.emit_clicked());
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
    let _reopened_window = present(&reopened.dialog);
    assert_eq!(reopened.dialog.imp().host_row.text(), "db.example.com");
    assert_eq!(reopened.dialog.imp().password_row.text(), "s3cret");
    reopened.dialog.imp().host_row.set_text("db2.example.com");
    let log = SignalLog::connect(&reopened.dialog, "submitted", |values| {
        values[1].get::<ConnectSubmission>().expect("a submission")
    });
    without_criticals(|| reopened.dialog.imp().connect_button.emit_clicked());

    let edited = log.take().remove(0).pending_save;
    assert_eq!(edited.connection.id, saved.id);
    assert!(!edited.is_new);
    assert_eq!(edited.connection.host, "db2.example.com");
    assert_eq!(edited.connection.name, "app@db2.example.com");
}

#[gtk4::test]
fn a_connect_from_new_connection_never_writes_over_a_saved_entry() {
    let saved = SavedConnection {
        safe_mode: tablepro_core::SafeModeLevel::ReadOnly,
        ..shop()
    };
    let harness = open(Options {
        saved: vec![saved.clone()],
        ..Options::default()
    });
    let _window = present(&harness.dialog);
    fill_network(&harness.dialog);
    harness.dialog.imp().name_row.set_text("Shop RW");
    let log = SignalLog::connect(&harness.dialog, "submitted", |values| {
        values[1].get::<ConnectSubmission>().expect("a submission")
    });

    without_criticals(|| harness.dialog.imp().connect_button.emit_clicked());

    let submitted = log.take().remove(0).pending_save;
    assert!(submitted.is_new, "the connect replaced the saved entry");
    assert_ne!(submitted.connection.id, saved.id);
    assert_eq!(submitted.connection.name, "Shop RW");
    assert_eq!(submitted.connection.safe_mode, SafeModeLevel::Off);
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
fn a_ca_file_is_offered_and_sent_only_with_verify_full() {
    let harness = dialog();
    fill_network(&harness.dialog);
    let section = harness.dialog.imp().tls_section.get();
    let ca = std::path::PathBuf::from("/etc/tls/ca.pem");
    section.set_file_path(FormField::CaFile, Some(ca.clone()));
    let index_of = |wanted: TlsMode| {
        section
            .imp()
            .modes
            .borrow()
            .iter()
            .position(|mode| *mode == wanted)
            .expect("PostgreSQL offers the mode") as u32
    };
    let sent_ca = || {
        let valid = harness.dialog.form().validate(caps_of("postgres")).expect("valid");
        let RequestTarget::Network { tls, .. } = valid.target else {
            panic!("expected a network target");
        };
        tls.ca_file
    };

    section.imp().encryption_row.set_selected(index_of(TlsMode::Require));
    assert!(!section.imp().ca_row.is_visible(), "Require offered a CA file");
    assert_eq!(sent_ca(), None, "Require sent a CA file it would not read");

    section.imp().encryption_row.set_selected(index_of(TlsMode::VerifyFull));
    assert!(section.imp().ca_row.is_visible());
    assert_eq!(sent_ca(), Some(ca), "the CA file chosen before was lost");
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
        imp.name_row.get().upcast(),
        imp.driver_row.get().upcast(),
        imp.host_row.get().upcast(),
        imp.port_row.get().upcast(),
        imp.database_row.get().upcast(),
        imp.file_row.get().upcast(),
        imp.auth_mode_row.get().upcast(),
        imp.username_row.get().upcast(),
        imp.password_row.get().upcast(),
        imp.remember_row.get().upcast(),
        imp.safe_mode_row.get().upcast(),
        imp.external_access_row.get().upcast(),
        imp.ai_policy_row.get().upcast(),
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

fn shop() -> SavedConnection {
    let form = ConnectForm {
        name: "Shop".to_owned(),
        host: "db.example.com".to_owned(),
        database: "sales".to_owned(),
        username: "app".to_owned(),
        ..ConnectForm::new("postgres", caps_of("postgres"))
    };
    let valid = form.validate(caps_of("postgres")).expect("valid");
    form.saved_connection(caps_of("postgres"), &valid, Uuid::new_v4(), None)
}

/// The connect dialog editing `saved`, which is in the list with its
/// password in the keyring.
fn editing(saved: &SavedConnection, connector: FakeConnector) -> Harness {
    let harness = open(Options {
        connector,
        saved: vec![saved.clone()],
        mode: ConnectDialogMode::Edit(Box::new(saved.clone())),
        ..Options::default()
    });
    let (vault, id) = (harness.vault.clone(), saved.id);
    crate::test_support::finish_on_main(WAIT, async move {
        vault
            .store(id, SecretKind::DatabasePassword, &SecretString::from("s3cret"), "label")
            .await
    })
    .expect("the store to end")
    .expect("the password");
    harness
}

#[gtk4::test]
fn edit_dialog_prefills_and_saves_same_id() {
    let saved = shop();
    let harness = editing(&saved, FakeConnector::new([]));
    let _window = present(&harness.dialog);
    let imp = harness.dialog.imp();
    assert_eq!(harness.dialog.title(), "Edit Connection");
    assert_eq!(imp.connect_button.label().as_deref(), Some("Save"));
    assert_eq!(imp.name_row.text(), "Shop");
    assert_eq!(imp.host_row.text(), "db.example.com");
    assert_eq!(imp.password_row.text(), "", "a secret reached the form");
    assert!(
        imp.auth_group
            .description()
            .is_some_and(|text| text.contains("empty to keep")),
        "the password rows do not say they may stay empty"
    );
    let log = SignalLog::connect(&harness.dialog, "saved", |values| {
        values[1].get::<String>().expect("an id")
    });
    let closed = SignalLog::connect(&harness.dialog, "closed", |_| ());
    imp.name_row.set_text("Shop (EU)");
    imp.host_row.set_text("db2.example.com");

    without_criticals(|| {
        imp.connect_button.emit_clicked();
        wait_until(WAIT, || log.count() == 1).expect("the save");
    });

    assert_eq!(closed.count(), 1, "the landed save left the dialog open");
    assert_eq!(log.take(), [saved.id.to_string()]);
    let stored = harness.store.load_blocking().expect("the list");
    assert_eq!(stored.len(), 1, "the edit added an entry");
    assert_eq!(stored[0].id, saved.id);
    assert_eq!(stored[0].name, "Shop (EU)");
    assert_eq!(stored[0].host, "db2.example.com");
    assert_eq!(
        harness
            .vault
            .stored_secret(saved.id, SecretKind::DatabasePassword)
            .as_deref(),
        Some("s3cret"),
        "the empty password row lost the saved password"
    );
    assert!(harness.connector.calls().is_empty(), "Save connected");
}

#[gtk4::test]
fn a_refused_save_keeps_the_dialog_open_with_the_reason() {
    let saved = shop();
    let harness = editing(&saved, FakeConnector::new([]));
    harness.vault.fail_store(
        SecretKind::DatabasePassword,
        tablepro_core::credentials::SecretError::Locked,
    );
    let imp = harness.dialog.imp();
    let log = SignalLog::connect(&harness.dialog, "saved", |_| ());
    imp.password_row.set_text("n3w");

    imp.connect_button.emit_clicked();
    wait_until(WAIT, || !imp.toasts.borrow().is_empty()).expect("the reason");

    assert_eq!(log.count(), 0);
    assert!(imp.toasts.borrow()[0].contains("locked"), "{:?}", imp.toasts.borrow());
    assert!(imp.connect_button.is_sensitive(), "Save stayed off after the failure");
    assert_eq!(harness.store.load_blocking().expect("the list")[0], saved);
}

#[gtk4::test]
fn a_save_landing_after_the_user_closed_the_dialog_does_not_close_it_again() {
    let saved = shop();
    let harness = editing(&saved, FakeConnector::new([]));
    let _window = present(&harness.dialog);
    let imp = harness.dialog.imp();
    let log = SignalLog::connect(&harness.dialog, "saved", |_| ());
    let closed = SignalLog::connect(&harness.dialog, "closed", |_| ());
    imp.host_row.set_text("db2.example.com");

    without_criticals(|| {
        imp.connect_button.emit_clicked();
        harness.dialog.close();
        wait_until(WAIT, || log.count() == 1).expect("the save");
    });

    assert_eq!(closed.count(), 1);
    assert_eq!(
        harness.store.load_blocking().expect("the list")[0].host,
        "db2.example.com",
        "closing the dialog lost the save"
    );
}

#[gtk4::test]
fn an_edit_test_logs_in_with_the_kept_password() {
    let saved = shop();
    let harness = editing(
        &saved,
        FakeConnector::new([FakeEstablish::Connect(ConnectionScript::default())]),
    );
    let imp = harness.dialog.imp();

    imp.test_button.emit_clicked();
    wait_until(WAIT, || !imp.toasts.borrow().is_empty()).expect("the test result");

    assert_eq!(imp.toasts.borrow().as_slice(), ["Connection works"]);
    assert_eq!(tested_password(&harness), "s3cret");
}

#[gtk4::test]
fn an_edit_test_logs_in_with_a_typed_password_it_will_not_keep() {
    let saved = shop();
    let harness = editing(
        &saved,
        FakeConnector::new([FakeEstablish::Connect(ConnectionScript::default())]),
    );
    let imp = harness.dialog.imp();
    imp.password_row.set_text("n3w");
    imp.remember_row.set_active(false);

    imp.test_button.emit_clicked();
    wait_until(WAIT, || !imp.toasts.borrow().is_empty()).expect("the test result");

    assert_eq!(tested_password(&harness), "n3w", "Test used the stored password");
    assert_eq!(
        harness
            .vault
            .stored_secret(saved.id, SecretKind::DatabasePassword)
            .as_deref(),
        Some("s3cret"),
        "Test changed the keyring"
    );
}

/// The password the first connect logged in with.
fn tested_password(harness: &Harness) -> String {
    let calls = harness.connector.calls();
    let RequestTarget::Network {
        credentials: tablepro_core::Credentials::Password { password, .. },
        ..
    } = &calls[0].request.target
    else {
        panic!("expected a password login");
    };
    secrecy::ExposeSecret::expose_secret(password).to_owned()
}

fn tag_checks(dialog: &ConnectDialog) -> Vec<(String, bool)> {
    dialog
        .imp()
        .tag_checks
        .borrow()
        .iter()
        .map(|(tag, check)| (tag.name.as_str().to_owned(), check.is_active()))
        .collect()
}

fn tick(dialog: &ConnectDialog, name: &str, ticked: bool) {
    let checks = dialog.imp().tag_checks.borrow();
    let (_, check) = checks
        .iter()
        .find(|(tag, _)| tag.name.as_str() == name)
        .unwrap_or_else(|| panic!("no row for {name}"));
    check.set_active(ticked);
}

fn pick_icon(dialog: &ConnectDialog, icon: Option<tablepro_storage::ConnectionIcon>) {
    let position = icon
        .and_then(|icon| {
            tablepro_storage::ConnectionIcon::ALL
                .iter()
                .position(|candidate| *candidate == icon)
        })
        .map_or(0, |at| at + 1);
    dialog
        .imp()
        .icon_row
        .set_selected(u32::try_from(position).expect("a position"));
}

fn tag(name: &str) -> tablepro_storage::ConnectionTag {
    tablepro_storage::ConnectionTag::new(
        tablepro_storage::ConnectionTagName::new(name).expect("a tag name"),
        tablepro_storage::ConnectionColor::Red,
    )
}

#[gtk4::test]
fn the_tags_and_icon_picked_go_with_the_connection_a_connect_saves() {
    let (acme, production) = (tag("acme"), tag("production"));
    let harness = open(Options {
        tags: vec![acme, production.clone()],
        ..Options::default()
    });
    let _window = present(&harness.dialog);
    fill_network(&harness.dialog);
    assert_eq!(
        tag_checks(&harness.dialog),
        [("acme".to_owned(), false), ("production".to_owned(), false)]
    );
    assert_eq!(harness.dialog.imp().tags_row.subtitle().as_str(), "None");
    tick(&harness.dialog, "production", true);
    pick_icon(&harness.dialog, Some(tablepro_storage::ConnectionIcon::Shield));
    let submissions = SignalLog::connect(&harness.dialog, "submitted", |values| {
        values[1].get::<ConnectSubmission>().expect("a submission")
    });

    assert_eq!(harness.dialog.imp().tags_row.subtitle().as_str(), "production");
    without_criticals(|| harness.dialog.imp().connect_button.emit_clicked());

    let saved = submissions.take().remove(0).pending_save.connection;
    assert_eq!(saved.tags, [production.id]);
    assert_eq!(saved.icon, Some(tablepro_storage::ConnectionIcon::Shield));
}

#[gtk4::test]
fn an_edit_opens_on_its_tags_and_icon_and_saves_what_changed() {
    let (acme, production) = (tag("acme"), tag("production"));
    let saved = SavedConnection {
        tags: vec![acme.id],
        icon: Some(tablepro_storage::ConnectionIcon::Cloud),
        ..shop()
    };
    let harness = open(Options {
        tags: vec![acme, production.clone()],
        saved: vec![saved.clone()],
        mode: ConnectDialogMode::Edit(Box::new(saved.clone())),
        ..Options::default()
    });
    let _window = present(&harness.dialog);
    let imp = harness.dialog.imp();

    assert_eq!(
        tag_checks(&harness.dialog),
        [("acme".to_owned(), true), ("production".to_owned(), false)]
    );
    assert_eq!(
        harness.dialog.picked_icon(),
        Some(tablepro_storage::ConnectionIcon::Cloud)
    );
    let cloud = crate::ui::icons::connection_icon(tablepro_storage::ConnectionIcon::Cloud);
    assert!(
        crate::test_support::descendants(&*imp.icon_row)
            .into_iter()
            .filter_map(|widget| widget.downcast::<gtk4::Image>().ok())
            .any(|image| image.is_visible() && image.icon_name().is_some_and(|name| name.as_str() == cloud)),
        "the picked icon does not show in the row"
    );
    tick(&harness.dialog, "acme", false);
    tick(&harness.dialog, "production", true);
    pick_icon(&harness.dialog, None);
    let log = SignalLog::connect(&harness.dialog, "saved", |_| ());

    without_criticals(|| {
        imp.connect_button.emit_clicked();
        wait_until(WAIT, || log.count() == 1).expect("the save");
    });

    let stored = harness.store.load_blocking().expect("the list");
    assert_eq!(stored[0].tags, [production.id]);
    assert_eq!(stored[0].icon, None);
}

#[gtk4::test]
fn a_tag_name_is_listed_as_text_not_markup() {
    let odd = tag("R&D <prod>");
    let harness = open(Options {
        tags: vec![odd],
        ..Options::default()
    });

    tick(&harness.dialog, "R&D <prod>", true);

    let row = &harness.dialog.imp().tags_row;
    assert!(!row.uses_markup());
    assert_eq!(row.subtitle().as_str(), "R&D <prod>");
}

#[gtk4::test]
fn connect_waits_while_a_tag_made_from_the_dialog_is_written() {
    let harness = dialog();
    let imp = harness.dialog.imp();
    fill_network(&harness.dialog);
    harness.dialog.refresh();
    assert!(imp.connect_button.is_sensitive());

    imp.creating_tag.set(true);
    harness.dialog.refresh();

    assert!(
        !imp.connect_button.is_sensitive(),
        "Connect could leave the new tag off"
    );
    assert_eq!(
        harness.dialog.build_submission().err().as_deref(),
        Some("Creating the tag…")
    );
    imp.creating_tag.set(false);
    harness.dialog.refresh();
    assert!(imp.connect_button.is_sensitive());
}
