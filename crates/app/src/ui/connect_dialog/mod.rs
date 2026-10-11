use std::sync::Arc;

use relm4::adw::prelude::*;
use relm4::prelude::*;
use relm4::{adw, gtk};
use secrecy::{ExposeSecret, SecretString};
use uuid::Uuid;

use tablepro_core::{
    AuthMode, ConnectOptions, Connection, DriverMaturity, DriverRegistry, Environment, TlsMode,
    connection_form_defaults,
};
use tablepro_storage::{
    SavedConnection, delete_password, save_connections, store_password, store_ssh_passphrase, store_ssh_password,
};

use super::ssh_section::{SshInputs, SshSecretToStore, SshSection};
use crate::services::connection_service;
use crate::services::database_service::ReconnectParams;

pub struct ConnectDialog {
    registry: Arc<DriverRegistry>,
    drivers: Vec<DriverEntry>,
    driver_combo: adw::ComboRow,
    endpoint_combo: adw::ComboRow,
    name: adw::EntryRow,
    host: adw::EntryRow,
    port: adw::SpinRow,
    socket_dir: adw::EntryRow,
    resolved_socket: adw::ActionRow,
    database: adw::EntryRow,
    database_file_picker: gtk::Box,
    username: adw::EntryRow,
    password: adw::PasswordEntryRow,
    auth_combo: adw::ComboRow,
    tls_mode: adw::ComboRow,
    tls_root_cert: adw::EntryRow,
    tls_client_cert: adw::EntryRow,
    tls_client_key: adw::EntryRow,
    read_only: adw::SwitchRow,
    connect_timeout: adw::SpinRow,
    query_timeout: adw::SpinRow,
    environment: adw::ComboRow,
    auth_group: adw::PreferencesGroup,
    ssh: SshSection,
    test_button: gtk::Button,
    submit: gtk::Button,
    toast_overlay: adw::ToastOverlay,
    test_banner: adw::Banner,
    header_title: gtk::Label,
    header_actions: gtk::Box,
    form: AuthFormState,
    preferences: crate::services::preferences::PreferencesStore,
    bound_connection_id: Option<Uuid>,
    ssh_environment: tablepro_transport::SshEnvironment,
    audit_factory: tablepro_transport::TransportAuditFactory,
    guard_factory: crate::services::database_service::CandidateGuardFactory,
    applied_driver: Option<u32>,
    connect_cancel: Option<tokio_util::sync::CancellationToken>,
}

#[derive(Debug, Clone)]
struct DriverEntry {
    id: String,
    display_name: String,
    maturity: DriverMaturity,
}

const AUTH_MODE_ROWS: [AuthMode; 2] = [AuthMode::Password, AuthMode::Kerberos];

fn auth_mode_label(mode: AuthMode) -> String {
    match mode {
        AuthMode::Password => crate::tr!("Password"),
        AuthMode::Kerberos => crate::tr!("Windows (Kerberos)"),
    }
}

fn auth_mode_for_row(row: u32) -> AuthMode {
    AUTH_MODE_ROWS.get(row as usize).copied().unwrap_or_default()
}

fn selected_path(row: &adw::EntryRow) -> Option<std::path::PathBuf> {
    let value = row.text();
    let path = value.trim();
    (!path.is_empty()).then(|| std::path::PathBuf::from(path))
}

mod browse;
mod form;
mod identity;
mod prefill;

use form::{
    AuthFormState, EndpointFormState, default_driver_row, resolved_socket_path, socket_directory_is_valid,
    test_result_text,
};
use identity::{ConnectionIdentity, find_existing, saved_connection_name};
pub use prefill::{ConnectionPrefill, has_jump_chain, load_prefill};

pub struct ConnectDialogInit {
    pub registry: Arc<DriverRegistry>,
    pub preferences: crate::services::preferences::PreferencesStore,
    /// Saved connection this dialog edits. When set it decides which
    /// record is written, so two connections to one endpoint stay
    /// separate instead of folding into whichever matched first.
    pub bound_connection_id: Option<Uuid>,
    pub prefill: Option<ConnectionPrefill>,
    pub ssh_environment: tablepro_transport::SshEnvironment,
    pub audit_factory: tablepro_transport::TransportAuditFactory,
    pub guard_factory: crate::services::database_service::CandidateGuardFactory,
}

#[derive(Debug)]
pub enum ConnectDialogInput {
    DriverChanged(u32),
    SshToggled,
    TlsModeChanged,
    SshAuthChanged,
    AuthModeChanged,
    EndpointChanged,
    Submit,
    TestConnection,
    InputChanged,
    Closed,
}

#[derive(Debug)]
pub enum ConnectDialogOutput {
    Prepared(Box<connection_service::PreparedConnection>),
    Closed,
}

#[derive(Debug)]
#[allow(clippy::large_enum_variant)]
pub enum ConnectDialogCmd {
    Result(Result<connection_service::PreparedConnection, String>),
    Cancelled,
    TestResult(Result<usize, String>),
}

/// Which async operation (if any) is currently in flight. Drives
/// the per-button busy-label rendering — only the *busy* button gets
/// the in-progress wording, the other keeps its static label.
#[derive(Debug, Clone, Copy)]
enum BusyKind {
    None,
    Connecting,
    Testing,
}

#[relm4::component(pub)]
impl Component for ConnectDialog {
    type Init = ConnectDialogInit;
    type Input = ConnectDialogInput;
    type Output = ConnectDialogOutput;
    type CommandOutput = ConnectDialogCmd;

    view! {
        adw::Dialog {
            set_title: &crate::tr!("Connect"),
            set_content_width: 560,
            set_content_height: 720,
            connect_closed => ConnectDialogInput::Closed,

            #[wrap(Some)]
            set_child = &adw::ToolbarView {
                add_top_bar = &adw::HeaderBar {
                    set_centering_policy: adw::CenteringPolicy::Loose,
                    set_title_widget: Some(&model.header_title),
                    pack_end: &model.header_actions,
                },

                #[wrap(Some)]
                set_content = &model.toast_overlay.clone(),
            },
        }
    }

    fn init(init: Self::Init, root: Self::Root, sender: ComponentSender<Self>) -> ComponentParts<Self> {
        let mut drivers: Vec<DriverEntry> = init
            .registry
            .iter()
            .map(|d| DriverEntry {
                id: d.id().to_string(),
                display_name: d.display_name().to_string(),
                maturity: d.maturity(),
            })
            .collect();
        drivers.sort_by(|a, b| a.display_name.cmp(&b.display_name));

        let names: Vec<String> = drivers.iter().map(|d| d.display_name.clone()).collect();
        let names_ref: Vec<&str> = names.iter().map(String::as_str).collect();
        let driver_model = gtk::StringList::new(&names_ref);

        let driver_combo = adw::ComboRow::builder()
            .title(crate::tr!("Driver"))
            .model(&driver_model)
            .selected(default_driver_row(&drivers))
            .build();
        let sender_for_combo = sender.clone();
        driver_combo.connect_selected_notify(move |row| {
            sender_for_combo.input(ConnectDialogInput::DriverChanged(row.selected()));
        });

        let endpoint_combo = adw::ComboRow::builder()
            .title(crate::tr!("Endpoint"))
            .subtitle(crate::tr!("Connect over the network or a local PostgreSQL socket"))
            .model(&gtk::StringList::new(&["Network", "Unix socket"]))
            .build();
        let sender_for_endpoint = sender.clone();
        endpoint_combo.connect_selected_notify(move |_| {
            sender_for_endpoint.input(ConnectDialogInput::EndpointChanged);
        });

        let name = adw::EntryRow::builder().title(crate::tr!("Name (optional)")).build();
        let host = adw::EntryRow::builder()
            .title(crate::tr!("Host"))
            .text("localhost")
            .build();
        // Port is a u16 1-65535. AdwSpinRow enforces the range natively;
        // no parse + fallback dance, no inline-error CSS to maintain.
        let port = adw::SpinRow::with_range(1.0, 65535.0, 1.0);
        port.set_title(&crate::tr!("Port"));
        let sender_for_port = sender.clone();
        port.connect_value_notify(move |_| sender_for_port.input(ConnectDialogInput::InputChanged));
        let socket_dir = adw::EntryRow::builder()
            .title(crate::tr!("Socket directory"))
            .text("/run/postgresql")
            .build();
        let resolved_socket = adw::ActionRow::builder().title(crate::tr!("Resolved socket")).build();
        let database = adw::EntryRow::builder().title(crate::tr!("Database")).build();
        let database_file_picker = browse::attach_database_file_picker(&database);
        database_file_picker.set_visible(false);
        let username = adw::EntryRow::builder().title(crate::tr!("Username")).build();
        let password = adw::PasswordEntryRow::builder().title(crate::tr!("Password")).build();
        let tls_mode = adw::ComboRow::builder()
            .title(crate::tr!("TLS"))
            .subtitle(crate::tr!("How the client encrypts and verifies the server"))
            .build();
        let tls_labels: Vec<&str> = TlsMode::ALL.iter().map(|m| m.label()).collect();
        let tls_model = gtk::StringList::new(&tls_labels);
        tls_mode.set_model(Some(&tls_model));
        tls_mode.set_selected(TlsMode::VerifyFull.index());
        let tls_root_cert = adw::EntryRow::builder()
            .title(crate::tr!("Certificate authority"))
            .build();
        browse::attach_certificate_picker(&tls_root_cert);
        let tls_client_cert = adw::EntryRow::builder().title(crate::tr!("Client certificate")).build();
        browse::attach_client_certificate_picker(&tls_client_cert);
        let tls_client_key = adw::EntryRow::builder().title(crate::tr!("Client private key")).build();
        browse::attach_client_key_picker(&tls_client_key);
        let sender_for_tls = sender.clone();
        tls_mode.connect_selected_notify(move |_| {
            sender_for_tls.input(ConnectDialogInput::TlsModeChanged);
        });
        let read_only = adw::SwitchRow::builder()
            .title(crate::tr!("Read-only mode"))
            .subtitle(crate::tr!("Block writes at the policy layer"))
            .active(false)
            .build();
        let environment = adw::ComboRow::builder()
            .title(crate::tr!("Environment"))
            .subtitle(crate::tr!("Drives agent and approval defaults"))
            .build();
        let env_model = gtk::StringList::new(&["Local", "Dev", "Staging", "Prod"]);
        environment.set_model(Some(&env_model));
        environment.set_selected(0);

        let ssh = SshSection::build();
        let sender_for_ssh = sender.clone();
        ssh.expander.connect_enable_expansion_notify(move |_| {
            sender_for_ssh.input(ConnectDialogInput::SshToggled);
        });
        let sender_for_auth = sender.clone();
        ssh.auth_combo.connect_selected_notify(move |_| {
            sender_for_auth.input(ConnectDialogInput::SshAuthChanged);
        });

        for entry in [&host, &socket_dir, &database, &username] {
            let s = sender.clone();
            entry.connect_changed(move |_| s.input(ConnectDialogInput::InputChanged));
        }
        let s = sender.clone();
        password.connect_changed(move |_| s.input(ConnectDialogInput::InputChanged));
        for entry in [&tls_client_cert, &tls_client_key] {
            let s = sender.clone();
            entry.connect_changed(move |_| s.input(ConnectDialogInput::InputChanged));
        }

        // Semantic preferences groups: Connection / Authentication /
        // Options / SSH. AdwPreferencesPage renders them with the
        // standard Adwaita section spacing & headers.
        let connection_group = adw::PreferencesGroup::builder().title(crate::tr!("Connection")).build();
        connection_group.add(&driver_combo);
        connection_group.add(&name);
        connection_group.add(&endpoint_combo);
        connection_group.add(&host);
        connection_group.add(&port);
        connection_group.add(&socket_dir);
        connection_group.add(&resolved_socket);
        connection_group.add(&database);

        let auth_labels: Vec<String> = AUTH_MODE_ROWS.iter().map(|mode| auth_mode_label(*mode)).collect();
        let auth_labels_ref: Vec<&str> = auth_labels.iter().map(String::as_str).collect();
        let auth_mode_model = gtk::StringList::new(&auth_labels_ref);
        let auth_combo = adw::ComboRow::builder()
            .title(crate::tr!("Method"))
            .model(&auth_mode_model)
            .build();
        let sender_for_auth_mode = sender.clone();
        auth_combo.connect_selected_notify(move |_| {
            sender_for_auth_mode.input(ConnectDialogInput::AuthModeChanged);
        });

        let auth_group = adw::PreferencesGroup::builder()
            .title(crate::tr!("Authentication"))
            .build();
        auth_group.add(&auth_combo);
        auth_group.add(&username);
        auth_group.add(&password);

        let options_group = adw::PreferencesGroup::builder().title(crate::tr!("Options")).build();
        options_group.add(&tls_mode);
        options_group.add(&tls_root_cert);
        options_group.add(&tls_client_cert);
        options_group.add(&tls_client_key);
        options_group.add(&read_only);
        let (connect_timeout, query_timeout) = timeout_rows();
        options_group.add(&connect_timeout);
        options_group.add(&query_timeout);
        options_group.add(&environment);

        let test_button = gtk::Button::builder().label(crate::tr!("Test")).build();
        let sender_for_test = sender.clone();
        test_button.connect_clicked(move |_| {
            sender_for_test.input(ConnectDialogInput::TestConnection);
        });

        let submit = gtk::Button::builder().label(crate::tr!("Connect")).build();
        submit.add_css_class("suggested-action");
        let sender_for_submit = sender.clone();
        submit.connect_clicked(move |_| {
            sender_for_submit.input(ConnectDialogInput::Submit);
        });

        let initial_title = drivers
            .get(default_driver_row(&drivers) as usize)
            .map(|driver| crate::tr!("Connect to {name}").replace("{name}", &driver.display_name))
            .unwrap_or_else(|| crate::tr!("Connect"));
        let header_title = gtk::Label::new(Some(&initial_title));
        header_title.set_halign(gtk::Align::Fill);
        header_title.set_valign(gtk::Align::Center);
        header_title.set_hexpand(true);
        header_title.set_xalign(0.0);
        header_title.set_ellipsize(gtk::pango::EllipsizeMode::End);
        header_title.add_css_class("title");
        let header_actions = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        header_actions.append(&test_button);
        header_actions.append(&submit);

        let page = adw::PreferencesPage::new();
        page.add(&connection_group);
        page.add(&auth_group);
        page.add(&options_group);
        page.add(&ssh.group);
        let test_banner = adw::Banner::new("");
        let body = gtk::Box::new(gtk::Orientation::Vertical, 0);
        page.set_vexpand(true);
        body.append(&test_banner);
        body.append(&page);
        let toast_overlay = adw::ToastOverlay::new();
        toast_overlay.set_child(Some(&body));

        let mut model = ConnectDialog {
            registry: init.registry,
            drivers: drivers.clone(),
            driver_combo,
            endpoint_combo,
            name,
            host,
            port,
            socket_dir,
            resolved_socket,
            database,
            database_file_picker,
            username,
            password,
            auth_combo,
            tls_mode,
            tls_root_cert,
            tls_client_cert,
            tls_client_key,
            read_only,
            connect_timeout,
            query_timeout,
            environment,
            auth_group,
            ssh,
            test_button,
            submit,
            toast_overlay,
            test_banner,
            header_title,
            header_actions,
            form: AuthFormState::default(),
            preferences: init.preferences,
            bound_connection_id: init.bound_connection_id,
            ssh_environment: init.ssh_environment,
            audit_factory: init.audit_factory,
            guard_factory: init.guard_factory,
            applied_driver: None,
            connect_cancel: None,
        };
        let widgets = view_output!();
        let selected = model.driver_combo.selected();
        model.apply_selected_driver(selected, &root);
        if let Some(prefill) = &init.prefill {
            model.apply_prefill(prefill, &root);
        }

        // Make Connect the dialog's default widget so pressing Enter
        // from any AdwEntryRow submits the form. Per HIG, every
        // dialog with a primary action should respond to Enter — the
        // suggested-action class alone only handles styling, not the
        // keybind.
        root.set_default_widget(Some(&model.submit));

        ComponentParts { model, widgets }
    }

    fn update(&mut self, msg: Self::Input, sender: ComponentSender<Self>, root: &Self::Root) {
        match msg {
            ConnectDialogInput::DriverChanged(idx) => {
                if self.applied_driver != Some(idx) {
                    self.apply_selected_driver(idx, root);
                }
            }

            ConnectDialogInput::TlsModeChanged => {
                self.apply_tls_visibility();
            }
            ConnectDialogInput::EndpointChanged => {
                self.apply_form_state();
                self.refresh_validity();
            }
            ConnectDialogInput::SshToggled => {
                self.refresh_validity();
            }

            ConnectDialogInput::SshAuthChanged => {
                self.ssh.refresh_auth_visibility();
                self.refresh_validity();
            }

            ConnectDialogInput::AuthModeChanged => {
                self.form.selected = auth_mode_for_row(self.auth_combo.selected());
                self.apply_form_state();
                self.refresh_validity();
            }

            ConnectDialogInput::InputChanged => {
                self.test_banner.set_revealed(false);
                self.refresh_validity();
            }

            ConnectDialogInput::Submit => {
                if let Some(cancel) = self.connect_cancel.take() {
                    cancel.cancel();
                    return;
                }
                self.set_busy(BusyKind::Connecting);

                let idx = self.driver_combo.selected() as usize;
                let Some(entry) = self.drivers.get(idx).cloned() else {
                    self.set_busy(BusyKind::None);
                    self.show_toast(&crate::tr!("No driver selected"));
                    return;
                };

                let driver = match self.registry.get(&entry.id) {
                    Some(d) => d,
                    None => {
                        self.set_busy(BusyKind::None);
                        self.show_toast(&crate::tr!("Driver {id} not registered").replace("{id}", &entry.id));
                        return;
                    }
                };

                let opts = self.collect_options(driver.as_ref());

                let label = saved_connection_name(self.name.text().as_str(), &entry.id, &opts);
                let driver_id = entry.id.clone();

                let ssh_inputs = if self.ssh.is_enabled() {
                    match self.ssh.collect() {
                        Ok(inputs) => Some(inputs),
                        Err(e) => {
                            self.set_busy(BusyKind::None);
                            self.show_toast(&e);
                            return;
                        }
                    }
                } else {
                    None
                };
                let read_only = self.read_only.is_active();
                let environment = self.selected_environment();
                let query_timeout_secs = timeout_value(self.query_timeout.value());
                let timeout_secs = query_timeout_secs
                    .unwrap_or_else(|| crate::services::operation_control::configured_timeout_secs(&self.preferences));
                let ssh_environment = self.ssh_environment.clone();
                let audit_factory = self.audit_factory.clone();
                let guard_factory = self.guard_factory.clone();

                let bound_id = self.bound_connection_id;
                let cancel = tokio_util::sync::CancellationToken::new();
                self.connect_cancel = Some(cancel.clone());
                sender.command(move |out, shutdown| {
                    shutdown
                        .register(async move {
                            let result = run_connect(ConnectRequest {
                                driver: driver.clone(),
                                driver_id,
                                bound_id,
                                label,
                                opts,
                                ssh: ssh_inputs,
                                ssh_environment,
                                audit_factory,
                                guard_factory,
                                read_only,
                                environment,
                                timeout_secs,
                                query_timeout_secs,
                                cancel,
                            })
                            .await;
                            let message = match result {
                                Ok(Some(prepared)) => ConnectDialogCmd::Result(Ok(prepared)),
                                Ok(None) => ConnectDialogCmd::Cancelled,
                                Err(error) => ConnectDialogCmd::Result(Err(error)),
                            };
                            out.send(message).ok();
                        })
                        .drop_on_shutdown()
                });
            }

            ConnectDialogInput::TestConnection => {
                self.test_banner.set_revealed(false);
                self.set_busy(BusyKind::Testing);

                let idx = self.driver_combo.selected() as usize;
                let Some(entry) = self.drivers.get(idx).cloned() else {
                    self.set_busy(BusyKind::None);
                    self.show_toast(&crate::tr!("No driver selected"));
                    return;
                };
                let Some(driver) = self.registry.get(&entry.id) else {
                    self.set_busy(BusyKind::None);
                    self.show_toast(&crate::tr!("Driver {id} not registered").replace("{id}", &entry.id));
                    return;
                };
                let opts = self.collect_options(driver.as_ref());
                let ssh_inputs = if self.ssh.is_enabled() {
                    match self.ssh.collect() {
                        Ok(inputs) => Some(inputs),
                        Err(e) => {
                            self.set_busy(BusyKind::None);
                            self.show_toast(&e);
                            return;
                        }
                    }
                } else {
                    None
                };

                let query_timeout_secs = timeout_value(self.query_timeout.value());
                let timeout_secs = query_timeout_secs
                    .unwrap_or_else(|| crate::services::operation_control::configured_timeout_secs(&self.preferences));
                let ssh_environment = self.ssh_environment.clone();
                let audit_factory = self.audit_factory.clone();
                let guard_factory = self.guard_factory.clone();
                let name = saved_connection_name(self.name.text().as_str(), &entry.id, &opts);
                let read_only = self.read_only.is_active();
                let query_timeout_secs = timeout_value(self.query_timeout.value());
                let bound_id = self.bound_connection_id;
                let environment = self.selected_environment();
                let cancellation = tokio_util::sync::CancellationToken::new();
                self.connect_cancel = Some(cancellation.clone());
                sender.command(move |out, shutdown| {
                    shutdown
                        .register(async move {
                            let control = crate::services::operation_control::bounded(timeout_secs);
                            let ssh = ssh_inputs.as_ref().map(SshInputs::route).transpose();
                            let result = match ssh {
                                Err(error) => Err(error),
                                Ok(ssh) => {
                                    let identity = ConnectionIdentity {
                                        bound_id,
                                        driver_id: &entry.id,
                                        opts: &opts,
                                        file_based: driver.is_file_based(),
                                        ssh: ssh_inputs.as_ref(),
                                    };
                                    let existing = find_existing(&identity).await;
                                    let id = existing
                                        .as_ref()
                                        .map_or_else(|| bound_id.unwrap_or_else(Uuid::new_v4), |saved| saved.id);
                                    let audit = audit_factory.context(
                                        tablepro_policy::Principal::human_gui(),
                                        id,
                                        name.clone(),
                                        environment,
                                        entry.id.clone(),
                                    );
                                    let ssh_environment = ssh_environment.with_audit(audit);
                                    let metadata = crate::services::database_service::ConnectionMetadata {
                                        id,
                                        name: name.clone(),
                                        driver_id: entry.id.clone(),
                                        environment,
                                        read_only,
                                        server_version: None,
                                        query_timeout_secs,
                                    };
                                    match tablepro_transport::establish_with_cancellation(
                                        driver.as_ref(),
                                        opts,
                                        ssh,
                                        &ssh_environment,
                                        cancellation,
                                    )
                                    .await
                                    {
                                        Ok((conn, _tunnel)) => {
                                            let conn: Arc<dyn tablepro_core::Connection> = Arc::from(conn);
                                            let guarded = guard_factory.guard(
                                                conn,
                                                &metadata,
                                                tablepro_policy::Principal::human_gui(),
                                            );
                                            match guarded.list_tables_controlled(&control).await {
                                                Ok(tables) => Ok(tables.len()),
                                                Err(e) => Err(format!("list_tables: {e}")),
                                            }
                                        }
                                        Err(e) => Err(e.to_string()),
                                    }
                                }
                            };
                            out.send(ConnectDialogCmd::TestResult(result)).ok();
                        })
                        .drop_on_shutdown()
                });
            }

            ConnectDialogInput::Closed => {
                if let Some(cancel) = self.connect_cancel.take() {
                    cancel.cancel();
                }
                let _ = sender.output(ConnectDialogOutput::Closed);
            }
        }
    }

    fn update_cmd(&mut self, msg: Self::CommandOutput, sender: ComponentSender<Self>, root: &Self::Root) {
        self.set_busy(BusyKind::None);
        self.connect_cancel = None;
        match msg {
            ConnectDialogCmd::Cancelled => self.show_toast(&crate::tr!("Connection cancelled.")),
            ConnectDialogCmd::Result(Ok(prepared)) => {
                tracing::info!(driver = %prepared.driver_id, table_count = prepared.tables.len(), "connection prepared");
                let _ = sender.output(ConnectDialogOutput::Prepared(Box::new(prepared)));
                root.close();
            }
            ConnectDialogCmd::Result(Err(e)) => {
                tracing::warn!(error = %e, "connect failed");
                self.show_toast(&e);
            }
            ConnectDialogCmd::TestResult(result) => {
                self.test_banner.set_title(&test_result_text(&result));
                self.test_banner.set_revealed(true);
            }
        }
    }
}

impl ConnectDialog {
    fn apply_selected_driver(&mut self, idx: u32, root: &adw::Dialog) {
        self.applied_driver = Some(idx);
        let Some(entry) = self.drivers.get(idx as usize).cloned() else {
            return;
        };
        if let Some(driver) = self.registry.get(&entry.id) {
            self.apply_driver_form_visibility(driver.as_ref());
            let defaults = connection_form_defaults(driver.as_ref());
            self.port.set_value(defaults.port as f64);
            self.database.set_text(defaults.database);
            self.username.set_text(defaults.username);
        }
        self.refresh_driver_maturity_subtitle();
        let title = crate::tr!("Connect to {name}").replace("{name}", &entry.display_name);
        root.set_title(&title);
        self.header_title.set_text(&title);
        self.refresh_validity();
    }

    fn refresh_validity(&self) {
        let client_cert_set = !self.tls_client_cert.text().trim().is_empty();
        let client_key_set = !self.tls_client_key.text().trim().is_empty();
        let invalid_client_tls = client_cert_set != client_key_set
            || ((client_cert_set || client_key_set)
                && matches!(self.selected_tls_mode(), TlsMode::Disabled | TlsMode::Prefer));
        toggle_error(&self.tls_client_cert, invalid_client_tls);
        toggle_error(&self.tls_client_key, invalid_client_tls);
        let database_empty = self.database.text().trim().is_empty();
        toggle_error(&self.database, database_empty);

        let socket = self.uses_local_socket();
        let host_required = !self.form.file_based && !socket;
        let host_empty = host_required && self.host.text().trim().is_empty();
        toggle_error(&self.host, host_empty);

        let username_required = self.form.shows_credentials() && !socket;
        let username_empty = username_required && self.username.text().trim().is_empty();
        toggle_error(&self.username, username_empty);
        let socket_invalid = socket && !socket_directory_is_valid(self.socket_dir.text().as_str());
        toggle_error(&self.socket_dir, socket_invalid);
        let resolved = resolved_socket_path(self.socket_dir.text().as_str(), self.port.value() as u16);
        self.resolved_socket.set_subtitle(&resolved.display().to_string());

        let valid = self.is_form_valid();
        self.submit.set_sensitive(valid);
        self.test_button.set_sensitive(valid);
    }

    fn is_form_valid(&self) -> bool {
        let client_cert_set = !self.tls_client_cert.text().trim().is_empty();
        let client_key_set = !self.tls_client_key.text().trim().is_empty();
        if client_cert_set != client_key_set
            || (client_cert_set && matches!(self.selected_tls_mode(), TlsMode::Disabled | TlsMode::Prefer))
        {
            return false;
        }
        if self.database.text().trim().is_empty() {
            return false;
        }
        if !self.form.file_based {
            if !self.uses_local_socket() && self.host.text().trim().is_empty() {
                return false;
            }
            if self.uses_local_socket() && !socket_directory_is_valid(self.socket_dir.text().as_str()) {
                return false;
            }
            if self.form.shows_credentials() && !self.uses_local_socket() && self.username.text().trim().is_empty() {
                return false;
            }
        }
        if !self.uses_local_socket() && self.ssh.is_enabled() {
            return self.ssh.collect().is_ok();
        }
        true
    }

    fn selected_environment(&self) -> Environment {
        match self.environment.selected() {
            1 => Environment::Dev,
            2 => Environment::Staging,
            3 => Environment::Prod,
            _ => Environment::Local,
        }
    }

    fn selected_tls_mode(&self) -> TlsMode {
        TlsMode::from_index(self.tls_mode.selected())
    }

    fn tls_config_for(&self, driver: &dyn tablepro_core::DatabaseDriver) -> tablepro_core::TlsConfig {
        let mode = if driver.is_file_based() || self.uses_local_socket() {
            TlsMode::Disabled
        } else {
            self.selected_tls_mode()
        };
        tablepro_core::TlsConfig {
            mode,
            root_cert: self.selected_root_cert(mode),
            client_cert: selected_path(&self.tls_client_cert),
            client_key: selected_path(&self.tls_client_key),
            ..Default::default()
        }
    }

    fn selected_root_cert(&self, mode: TlsMode) -> Option<std::path::PathBuf> {
        if !mode.verifies_cert() {
            return None;
        }
        let text = self.tls_root_cert.text();
        let trimmed = text.trim();
        if trimmed.is_empty() {
            return None;
        }
        Some(std::path::PathBuf::from(trimmed))
    }

    fn apply_tls_visibility(&self) {
        self.tls_root_cert.set_visible(
            !self.form.file_based && !self.uses_local_socket() && self.selected_tls_mode().verifies_cert(),
        );
        let identity_configured =
            !self.tls_client_cert.text().trim().is_empty() || !self.tls_client_key.text().trim().is_empty();
        let client_auth_supported = self
            .drivers
            .get(self.driver_combo.selected() as usize)
            .and_then(|entry| self.registry.get(&entry.id))
            .is_some_and(|driver| driver.supports_client_tls_auth());
        let visible = identity_configured
            || (!self.form.file_based
                && !self.uses_local_socket()
                && client_auth_supported
                && self.selected_tls_mode() != TlsMode::Disabled);
        self.tls_client_cert.set_visible(visible);
        self.tls_client_key.set_visible(visible);
    }

    fn apply_driver_form_visibility(&mut self, driver: &dyn tablepro_core::DatabaseDriver) {
        self.form.file_based = driver.is_file_based();
        self.form.supports_integrated = driver.supports_integrated_auth();
        self.form.supports_local_socket = driver.supports_local_socket();
        if !self.form.supports_local_socket {
            self.endpoint_combo.set_selected(0);
        }
        self.apply_form_state();
        self.apply_tls_visibility();
        self.database_file_picker.set_visible(self.form.file_based);
        self.database.set_title(&if self.form.file_based {
            crate::tr!("File path")
        } else {
            crate::tr!("Database")
        });
    }

    fn apply_form_state(&self) {
        let endpoint = self.endpoint_state();
        let socket = endpoint.uses_local_socket();
        let network = endpoint.shows_network();
        self.endpoint_combo.set_visible(endpoint.shows_endpoint_choice());
        self.host.set_visible(network);
        self.port.set_visible(endpoint.shows_port());
        self.socket_dir.set_visible(endpoint.shows_socket_rows());
        self.resolved_socket.set_visible(endpoint.shows_socket_rows());
        self.tls_mode.set_visible(network);
        self.auth_group.set_visible(!self.form.file_based);
        self.ssh.set_visible(network);
        if socket {
            self.tls_mode.set_selected(TlsMode::Disabled.index());
            self.ssh.expander.set_enable_expansion(false);
            self.password.set_title(&crate::tr!("Password (optional)"));
        } else {
            self.password.set_title(&crate::tr!("Password"));
        }
        self.auth_combo.set_visible(self.form.shows_method());
        let credentials = self.form.shows_credentials();
        self.username.set_visible(credentials);
        self.password.set_visible(credentials);
    }

    fn collect_options(&self, driver: &dyn tablepro_core::DatabaseDriver) -> ConnectOptions {
        let socket = self.uses_local_socket();
        let (username, password) = if self.form.shows_credentials() {
            let entered = self.username.text().trim().to_string();
            let username = if socket && entered.is_empty() {
                whoami::username().unwrap_or_default()
            } else {
                entered
            };
            (username, self.password.text().to_string())
        } else {
            (String::new(), String::new())
        };
        ConnectOptions {
            host: self.host.text().to_string(),
            port: self.port.value() as u16,
            database: self.database.text().to_string(),
            username,
            password: SecretString::new(password.into()),
            tls: self.tls_config_for(driver),
            auth_mode: self.form.mode(),
            local_socket_dir: socket.then(|| std::path::PathBuf::from(self.socket_dir.text().as_str())),
            application_name: Some("BookiE".into()),
            connect_timeout_secs: timeout_value(self.connect_timeout.value()),
            read_only: self.read_only.is_active(),
            ..Default::default()
        }
    }

    fn endpoint_state(&self) -> EndpointFormState {
        EndpointFormState {
            file_based: self.form.file_based,
            supports_local_socket: self.form.supports_local_socket,
            socket_selected: self.endpoint_combo.selected() == 1,
        }
    }

    fn uses_local_socket(&self) -> bool {
        self.endpoint_state().uses_local_socket()
    }

    fn refresh_driver_maturity_subtitle(&self) {
        let idx = self.driver_combo.selected() as usize;
        let subtitle = match self.drivers.get(idx).map(|d| d.maturity) {
            Some(DriverMaturity::Experimental) => {
                crate::tr!("Experimental: connect and browse work; some writes and transactions are limited")
            }
            _ => String::new(),
        };
        self.driver_combo.set_subtitle(&subtitle);
    }

    fn show_toast(&self, message: &str) {
        self.toast_overlay.add_toast(adw::Toast::new(message));
    }

    /// Disable Connect / Test while an async op is in flight and
    /// switch the **busy** button's label to the in-progress wording
    /// (the *other* button keeps its static label so the user isn't
    /// confused about what's happening). The previous version
    /// rewrote `submit.set_label("Testing…")` during a Test, leaving
    /// the Connect button reading "Testing…" — a misleading label
    /// for a button that isn't running the test.
    fn set_busy(&self, kind: BusyKind) {
        let busy = !matches!(kind, BusyKind::None);
        self.submit.set_sensitive(!busy || matches!(kind, BusyKind::Connecting));
        self.test_button.set_sensitive(!busy);
        match kind {
            BusyKind::None => {
                self.submit.set_label(&crate::tr!("Connect"));
                self.test_button.set_label(&crate::tr!("Test"));
            }
            BusyKind::Connecting => {
                self.submit.set_label(&crate::tr!("Cancel"));
                self.test_button.set_label(&crate::tr!("Test"));
            }
            BusyKind::Testing => {
                self.submit.set_label(&crate::tr!("Connect"));
                self.test_button.set_label(&crate::tr!("Testing…"));
            }
        }
    }
}

fn toggle_error(row: &adw::EntryRow, invalid: bool) {
    if invalid {
        row.add_css_class("error");
    } else {
        row.remove_css_class("error");
    }
}

struct ConnectRequest {
    driver: Arc<dyn tablepro_core::DatabaseDriver>,
    driver_id: String,
    bound_id: Option<Uuid>,
    label: String,
    opts: ConnectOptions,
    ssh: Option<SshInputs>,
    ssh_environment: tablepro_transport::SshEnvironment,
    audit_factory: tablepro_transport::TransportAuditFactory,
    guard_factory: crate::services::database_service::CandidateGuardFactory,
    read_only: bool,
    environment: Environment,
    timeout_secs: u32,
    query_timeout_secs: Option<u32>,
    cancel: tokio_util::sync::CancellationToken,
}

struct OpenedCandidate {
    conn: Arc<dyn tablepro_core::Connection>,
    tunnel: Option<tablepro_transport::Tunnel>,
    server_version: Option<String>,
    tables: Vec<tablepro_core::TableInfo>,
    views: Vec<tablepro_core::TableInfo>,
}

struct CandidateBootstrap<'a> {
    guard_factory: &'a crate::services::database_service::CandidateGuardFactory,
    metadata: &'a crate::services::database_service::ConnectionMetadata,
}

async fn open_candidate(
    driver: &dyn tablepro_core::DatabaseDriver,
    opts: ConnectOptions,
    ssh: Option<tablepro_transport::SshRoute>,
    ssh_environment: &tablepro_transport::SshEnvironment,
    timeout_secs: u32,
    cancellation: tokio_util::sync::CancellationToken,
    bootstrap: CandidateBootstrap<'_>,
) -> Result<OpenedCandidate, String> {
    let (conn, tunnel) =
        tablepro_transport::establish_with_cancellation(driver, opts, ssh, ssh_environment, cancellation)
            .await
            .map_err(|error| error.to_string())?;
    let conn: Arc<dyn tablepro_core::Connection> = Arc::from(conn);
    let guarded = bootstrap.guard_factory.guard(
        conn.clone(),
        bootstrap.metadata,
        tablepro_policy::Principal::human_gui(),
    );
    let server_version = match guarded.server_version().await {
        Ok(version) => version,
        Err(tablepro_core::DriverError::PolicyDenied(message)) => return Err(message),
        Err(_) => None,
    };
    let control = crate::services::operation_control::bounded(timeout_secs);
    let tables = guarded
        .list_tables_controlled(&control)
        .await
        .map_err(|e| format!("list_tables: {e}"))?;
    let views = guarded
        .list_views_controlled(&control)
        .await
        .map_err(|e| format!("list_views: {e}"))?;
    Ok(OpenedCandidate {
        conn,
        tunnel,
        server_version,
        tables,
        views,
    })
}

async fn run_connect(request: ConnectRequest) -> Result<Option<connection_service::PreparedConnection>, String> {
    let ConnectRequest {
        driver,
        driver_id,
        bound_id,
        label,
        opts,
        ssh,
        ssh_environment,
        audit_factory,
        guard_factory,
        read_only,
        environment,
        timeout_secs,
        query_timeout_secs,
        cancel,
    } = request;
    let stored_password: SecretString = opts.password.clone();
    let ssh_for_establish = ssh.as_ref().map(SshInputs::route).transpose()?;
    let opts_clone = opts.clone();

    let identity = ConnectionIdentity {
        bound_id,
        driver_id: &driver_id,
        opts: &opts_clone,
        file_based: driver.is_file_based(),
        ssh: ssh.as_ref(),
    };
    let existing = find_existing(&identity).await;
    let id = existing
        .as_ref()
        .map(|connection| connection.id)
        .or(bound_id)
        .unwrap_or_else(Uuid::new_v4);
    let ssh_environment = ssh_environment.with_audit(audit_factory.context(
        tablepro_policy::Principal::human_gui(),
        id,
        label.clone(),
        environment,
        driver_id.clone(),
    ));

    let candidate_metadata = crate::services::database_service::ConnectionMetadata {
        id,
        name: label.clone(),
        driver_id: driver_id.clone(),
        environment,
        read_only,
        server_version: None,
        query_timeout_secs,
    };
    let opening = open_candidate(
        driver.as_ref(),
        opts.clone(),
        ssh_for_establish.clone(),
        &ssh_environment,
        timeout_secs,
        cancel.clone(),
        CandidateBootstrap {
            guard_factory: &guard_factory,
            metadata: &candidate_metadata,
        },
    );
    let opened = match opening.await {
        Ok(opened) => opened,
        Err(_) if cancel.is_cancelled() => return Ok(None),
        Err(error) => return Err(error),
    };
    let OpenedCandidate {
        conn,
        tunnel,
        server_version,
        tables,
        views,
    } = opened;

    let tls_mode = opts_clone.tls.mode;
    let saved = SavedConnection {
        id,
        name: label.clone(),
        driver_id: driver_id.clone(),
        host: opts_clone.host.clone(),
        port: opts_clone.port,
        socket_dir: opts_clone.local_socket_dir.clone(),
        database: opts_clone.database.clone(),
        username: opts_clone.username.clone(),
        use_tls: tls_mode.encrypts(),
        tls_mode: Some(tls_mode),
        tls_root_cert: opts_clone.tls.root_cert.clone(),
        tls_client_cert: opts_clone.tls.client_cert.clone(),
        tls_client_key: opts_clone.tls.client_key.clone(),
        auth_mode: opts_clone.auth_mode,
        read_only,
        environment,
        ssh: ssh.as_ref().map(|s| s.saved.clone()),
        last_opened_at: None,
        connect_timeout_secs: opts_clone.connect_timeout_secs,
        query_timeout_secs,
    };

    save_one(&saved).await.map_err(|e| format!("save: {e}"))?;
    match saved.auth_mode {
        AuthMode::Password if stored_password.expose_secret().is_empty() => {
            if let Err(error) = delete_password(saved.id).await {
                rollback_saved_connection(existing.as_ref(), saved.id)
                    .await
                    .map_err(|rollback_error| {
                        format!("delete obsolete stored password: {error}; restore saved connection: {rollback_error}")
                    })?;
                return Err(format!("delete obsolete stored password: {error}"));
            }
        }
        AuthMode::Password => {
            if let Err(error) = store_password(saved.id, stored_password.expose_secret(), &label).await {
                rollback_saved_connection(existing.as_ref(), saved.id)
                    .await
                    .map_err(|rollback_error| {
                        format!("store password: {error}; restore saved connection: {rollback_error}")
                    })?;
                return Err(format!("store password: {error}"));
            }
        }
        AuthMode::Kerberos
            if existing
                .as_ref()
                .is_some_and(|connection| connection.auth_mode == AuthMode::Password) =>
        {
            if let Err(error) = delete_password(saved.id).await {
                rollback_saved_connection(existing.as_ref(), saved.id)
                    .await
                    .map_err(|rollback_error| {
                        format!("delete stored password: {error}; restore saved connection: {rollback_error}")
                    })?;
                return Err(format!("delete stored password: {error}"));
            }
        }
        AuthMode::Kerberos => {}
    }
    if let Some(s) = &ssh {
        match &s.secret_to_store {
            SshSecretToStore::Password(p) => {
                store_ssh_password(saved.id, p.expose_secret(), &label).await.map_err(|error| {
                    format!("Connection settings were saved, but the SSH password was not saved: {error}. Re-enter the SSH password and connect again.")
                })?;
            }
            SshSecretToStore::Passphrase(p) => {
                store_ssh_passphrase(saved.id, p.expose_secret(), &label).await.map_err(|error| {
                    format!("Connection settings were saved, but the SSH key passphrase was not saved: {error}. Re-enter the passphrase and connect again.")
                })?;
            }
            SshSecretToStore::None => {}
        }
    }

    let params = ReconnectParams {
        driver: driver.clone(),
        opts: opts_clone,
        ssh: ssh_for_establish,
        environment: ssh_environment,
    };
    let metadata = crate::services::database_service::ConnectionMetadata {
        id: saved.id,
        name: saved.name.clone(),
        driver_id: saved.driver_id.clone(),
        environment,
        read_only,
        server_version,
        query_timeout_secs: saved.query_timeout_secs,
    };
    Ok(Some(connection_service::PreparedConnection::new(
        tables,
        views,
        saved.driver_id.clone(),
        metadata,
        conn,
        tunnel,
        params,
    )))
}

async fn save_one(connection: &SavedConnection) -> Result<(), tablepro_storage::StorageError> {
    save_connections(std::slice::from_ref(connection)).await
}

async fn rollback_saved_connection(
    previous: Option<&SavedConnection>,
    id: Uuid,
) -> Result<(), tablepro_storage::StorageError> {
    match previous {
        Some(connection) => save_one(connection).await,
        None => tablepro_storage::delete_connection(id).await,
    }
}

fn timeout_rows() -> (adw::SpinRow, adw::SpinRow) {
    let connect = adw::SpinRow::with_range(0.0, 600.0, 1.0);
    connect.set_title(&crate::tr!("Connect timeout (seconds)"));
    connect.set_subtitle(&crate::tr!("0 uses the default of 30 seconds"));
    let query = adw::SpinRow::with_range(0.0, 86_400.0, 1.0);
    query.set_title(&crate::tr!("Query timeout (seconds)"));
    query.set_subtitle(&crate::tr!("0 uses the timeout set in Preferences"));
    (connect, query)
}

fn timeout_value(seconds: f64) -> Option<u32> {
    let whole = seconds.round();
    (whole >= 1.0).then(|| whole.min(f64::from(u32::MAX)) as u32)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_zero_timeout_means_use_the_default() {
        assert_eq!(timeout_value(0.0), None);
        assert_eq!(timeout_value(0.4), None);
        assert_eq!(timeout_value(45.0), Some(45));
    }

    #[test]
    fn auth_mode_rows_decode_to_their_modes() {
        assert_eq!(auth_mode_for_row(0), AuthMode::Password);
        assert_eq!(auth_mode_for_row(1), AuthMode::Kerberos);
        assert_eq!(auth_mode_for_row(7), AuthMode::Password);
    }
}
