use std::sync::Arc;

use relm4::adw::prelude::*;
use relm4::prelude::*;
use relm4::{adw, gtk};
use secrecy::SecretString;
use uuid::Uuid;

use tablepro_core::{AuthMode, ConnectOptions, DriverRegistry, TableInfo};
use tablepro_storage::{ConnectionStore, SavedConnection, SavedSshConfig};

use super::ssh_section::{SshInputs, SshSecretToStore, SshSection};
use tablepro_core::credentials::{SecretKind, SecretVault};

use crate::services::connection_service;
use crate::services::database_service::{self, ReconnectParams};
use crate::services::secret_labels;
use crate::services::secret_save_report::SecretSaveReport;

pub struct ConnectDialog {
    registry: Arc<DriverRegistry>,
    storage: crate::storage::SharedStorage,
    settings: std::rc::Rc<tablepro_storage::AppSettings>,
    tasks: tablepro_session::runtime::Tasks,
    drivers: Vec<DriverEntry>,
    driver_combo: adw::ComboRow,
    host: adw::EntryRow,
    port: adw::SpinRow,
    database: adw::EntryRow,
    username: adw::EntryRow,
    password: adw::PasswordEntryRow,
    auth_combo: adw::ComboRow,
    use_tls: adw::SwitchRow,
    read_only: adw::SwitchRow,
    auth_group: adw::PreferencesGroup,
    ssh: SshSection,
    test_button: gtk::Button,
    submit: gtk::Button,
    toast_overlay: adw::ToastOverlay,
    form: AuthFormState,
    /// Set once the user types a port. A driver switch only overwrites
    /// the port while this is false, so a deliberate 6543 survives a
    /// look at another driver.
    port_edited: std::rc::Rc<std::cell::Cell<bool>>,
    /// The handler that sets `port_edited`, blocked while the code
    /// writes the port so applying a driver is not read as an edit.
    port_handler: glib::SignalHandlerId,
}

#[derive(Debug, Clone)]
struct DriverEntry {
    id: String,
    display_name: String,
}

/// The auth-method model's rows, in the order the combo shows them.
/// The label list and the selection decoder are both derived from this,
/// so a row index can never mean two different things.
const AUTH_MODE_ROWS: [AuthMode; 2] = [AuthMode::Password, AuthMode::Kerberos];

fn auth_mode_label(mode: AuthMode) -> String {
    match mode {
        AuthMode::Password => crate::i18n::gettext("Password"),
        AuthMode::Kerberos => crate::i18n::gettext("Windows (Kerberos)"),
    }
}

fn auth_mode_for_row(row: u32) -> AuthMode {
    AUTH_MODE_ROWS.get(row as usize).copied().unwrap_or_default()
}

/// What the selected driver allows, kept beside the widgets so the form
/// never reads its own visibility flags back to work out the mode.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
struct AuthFormState {
    file_based: bool,
    supports_integrated: bool,
    selected: AuthMode,
}

impl AuthFormState {
    /// A selection left over from another driver resolves back to
    /// password auth instead of leaking across the switch.
    fn mode(self) -> AuthMode {
        if self.shows_method() {
            self.selected
        } else {
            AuthMode::Password
        }
    }

    fn shows_method(self) -> bool {
        !self.file_based && self.supports_integrated
    }

    fn shows_credentials(self) -> bool {
        !self.file_based && self.mode() == AuthMode::Password
    }
}

pub struct ConnectDialogInit {
    pub registry: Arc<DriverRegistry>,
    pub storage: crate::storage::SharedStorage,
    pub settings: std::rc::Rc<tablepro_storage::AppSettings>,
    pub tasks: tablepro_session::runtime::Tasks,
}

#[derive(Debug)]
pub enum ConnectDialogInput {
    DriverChanged(u32),
    SshToggled,
    SshAuthChanged,
    AuthModeChanged,
    Submit,
    TestConnection,
    InputChanged,
    Closed,
}

#[derive(Debug)]
pub enum ConnectDialogOutput {
    Connected {
        tables: Vec<TableInfo>,
        driver_id: String,
    },
    /// Something the user should see that did not stop the connect,
    /// such as a password the keyring refused to keep.
    Warning(String),
    Closed,
}

/// What a successful connect produced, including anything the keyring
/// refused to keep so the dialog can say so.
#[derive(Debug)]
pub struct ConnectOutcome {
    pub saved: SavedConnection,
    pub tables: Vec<TableInfo>,
    pub secret_warnings: Vec<String>,
}

#[derive(Debug)]
#[expect(
    clippy::large_enum_variant,
    reason = "relm4 moves each message once through a channel, so boxing would only add an allocation"
)]
pub enum ConnectDialogCmd {
    Result(Result<ConnectOutcome, String>),
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
            set_title: &crate::i18n::gettext("Connect"),
            set_content_width: 480,
            set_content_height: 720,
            connect_closed => ConnectDialogInput::Closed,

            #[wrap(Some)]
            set_child = &adw::ToolbarView {
                // Action buttons in the headerbar — Test on the start
                // (secondary), Connect on the end (primary). Matches
                // GNOME Connections / Builder shape; no manual bottom
                // Box, no pill class on header buttons.
                add_top_bar = &adw::HeaderBar {
                    pack_start: &model.test_button,
                    pack_end: &model.submit,
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
            })
            .collect();
        drivers.sort_by(|a, b| a.display_name.cmp(&b.display_name));

        let names: Vec<String> = drivers.iter().map(|d| d.display_name.clone()).collect();
        let names_ref: Vec<&str> = names.iter().map(String::as_str).collect();
        let driver_model = gtk::StringList::new(&names_ref);

        let driver_combo = adw::ComboRow::builder()
            .title(crate::i18n::gettext("Driver"))
            .model(&driver_model)
            .build();
        let sender_for_combo = sender.clone();
        driver_combo.connect_selected_notify(move |row| {
            sender_for_combo.input(ConnectDialogInput::DriverChanged(row.selected()));
        });

        let host = adw::EntryRow::builder()
            .title(crate::i18n::gettext("Host"))
            .activates_default(true)
            .build();
        // Port is a u16 1-65535. AdwSpinRow enforces the range natively;
        // no parse + fallback dance, no inline-error CSS to maintain.
        let port = adw::SpinRow::with_range(1.0, 65535.0, 1.0);
        port.set_title(&crate::i18n::gettext("Port"));
        let port_edited = std::rc::Rc::new(std::cell::Cell::new(false));
        let port_edited_for_handler = port_edited.clone();
        let port_handler = port.connect_value_notify(move |_| {
            port_edited_for_handler.set(true);
        });
        let database = adw::EntryRow::builder()
            .title(crate::i18n::gettext("Database"))
            .activates_default(true)
            .build();
        let username = adw::EntryRow::builder()
            .title(crate::i18n::gettext("Username"))
            .activates_default(true)
            .build();
        let password = adw::PasswordEntryRow::builder()
            .title(crate::i18n::gettext("Password"))
            .activates_default(true)
            .build();
        let use_tls = adw::SwitchRow::builder()
            .title(crate::i18n::gettext("Use TLS"))
            .subtitle(crate::i18n::gettext("Require encrypted connection"))
            .active(false)
            .build();
        let read_only = adw::SwitchRow::builder()
            .title(crate::i18n::gettext("Read-only mode"))
            .subtitle(crate::i18n::gettext(
                "Block INSERT, UPDATE, DELETE, and DDL on this connection",
            ))
            .active(false)
            .build();

        let ssh = SshSection::build();
        let sender_for_ssh = sender.clone();
        ssh.expander.connect_enable_expansion_notify(move |_| {
            sender_for_ssh.input(ConnectDialogInput::SshToggled);
        });
        let sender_for_auth = sender.clone();
        ssh.auth_combo.connect_selected_notify(move |_| {
            sender_for_auth.input(ConnectDialogInput::SshAuthChanged);
        });

        for entry in [&host, &database, &username] {
            let s = sender.clone();
            entry.connect_changed(move |_| s.input(ConnectDialogInput::InputChanged));
        }
        let s = sender.clone();
        password.connect_changed(move |_| s.input(ConnectDialogInput::InputChanged));

        // Semantic preferences groups: Connection / Authentication /
        // Options / SSH. AdwPreferencesPage renders them with the
        // standard Adwaita section spacing & headers.
        let connection_group = adw::PreferencesGroup::builder()
            .title(crate::i18n::gettext("Connection"))
            .build();
        connection_group.add(&driver_combo);
        connection_group.add(&host);
        connection_group.add(&port);
        connection_group.add(&database);

        let auth_labels: Vec<String> = AUTH_MODE_ROWS.iter().map(|mode| auth_mode_label(*mode)).collect();
        let auth_labels_ref: Vec<&str> = auth_labels.iter().map(String::as_str).collect();
        let auth_mode_model = gtk::StringList::new(&auth_labels_ref);
        let auth_combo = adw::ComboRow::builder()
            .title(crate::i18n::gettext("Method"))
            .model(&auth_mode_model)
            .build();
        let sender_for_authmode = sender.clone();
        auth_combo.connect_selected_notify(move |_| {
            sender_for_authmode.input(ConnectDialogInput::AuthModeChanged);
        });

        let auth_group = adw::PreferencesGroup::builder()
            .title(crate::i18n::gettext("Authentication"))
            .build();
        auth_group.add(&auth_combo);
        auth_group.add(&username);
        auth_group.add(&password);

        let options_group = adw::PreferencesGroup::builder()
            .title(crate::i18n::gettext("Options"))
            .build();
        options_group.add(&use_tls);
        options_group.add(&read_only);

        let test_button = gtk::Button::builder().label(crate::i18n::gettext("Test")).build();
        let sender_for_test = sender.clone();
        test_button.connect_clicked(move |_| {
            sender_for_test.input(ConnectDialogInput::TestConnection);
        });

        let submit = gtk::Button::builder().label(crate::i18n::gettext("Connect")).build();
        submit.add_css_class("suggested-action");
        let sender_for_submit = sender.clone();
        submit.connect_clicked(move |_| {
            sender_for_submit.input(ConnectDialogInput::Submit);
        });

        let page = adw::PreferencesPage::new();
        page.add(&connection_group);
        page.add(&auth_group);
        page.add(&options_group);
        page.add(&ssh.group);
        let toast_overlay = adw::ToastOverlay::new();
        toast_overlay.set_child(Some(&page));

        let mut model = ConnectDialog {
            registry: init.registry,
            storage: init.storage,
            settings: init.settings,
            tasks: init.tasks,
            drivers: drivers.clone(),
            driver_combo,
            host,
            port,
            database,
            username,
            password,
            auth_combo,
            use_tls,
            read_only,
            auth_group,
            ssh,
            test_button,
            submit,
            toast_overlay,
            form: AuthFormState::default(),
            port_edited,
            port_handler,
        };
        let widgets = view_output!();

        // Open on the driver the user connected to last, so the common
        // case is one click rather than a combo hunt.
        let remembered = model.settings.connect_dialog_driver();
        let selected = driver_index(&drivers, &remembered);
        model.driver_combo.set_selected(selected as u32);
        model.apply_driver(selected, &root);
        model.refresh_validity();

        // Enter submits. Each row carries activates-default, which is
        // what makes AdwEntryRow call gtk_widget_activate_default; the
        // default widget alone does nothing without it. Connect stays
        // insensitive while the form is invalid, so Enter on a bad form
        // does nothing.
        root.set_default_widget(Some(&model.submit));

        ComponentParts { model, widgets }
    }

    fn update(&mut self, msg: Self::Input, sender: ComponentSender<Self>, root: &Self::Root) {
        match msg {
            ConnectDialogInput::DriverChanged(idx) => {
                self.apply_driver(idx as usize, root);
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
                self.refresh_validity();
            }

            ConnectDialogInput::Submit => {
                self.set_busy(BusyKind::Connecting);

                let idx = self.driver_combo.selected() as usize;
                let Some(entry) = self.drivers.get(idx).cloned() else {
                    self.set_busy(BusyKind::None);
                    self.show_toast(&crate::i18n::gettext("No driver selected"));
                    return;
                };

                let driver = match self.registry.get(&entry.id) {
                    Some(d) => d,
                    None => {
                        self.set_busy(BusyKind::None);
                        self.show_toast(&crate::i18n::gettext_f(
                            "Driver {id} not registered",
                            &[("id", &entry.id)],
                        ));
                        return;
                    }
                };

                let opts = self.collect_options();

                let label = if entry.id == "sqlite" {
                    opts.database.clone()
                } else if opts.auth_mode == AuthMode::Kerberos {
                    opts.host.clone()
                } else {
                    format!("{}@{}", opts.username, opts.host)
                };
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
                let targets = SaveTargets {
                    connections: self.storage.connections().clone(),
                    secrets: self.storage.secrets().clone(),
                    tasks: self.tasks.clone(),
                };

                sender.command(move |out, shutdown| {
                    shutdown
                        .register(async move {
                            let result = run_connect(
                                driver.clone(),
                                targets.clone(),
                                driver_id,
                                label,
                                opts,
                                ssh_inputs,
                                read_only,
                            )
                            .await;
                            out.send(ConnectDialogCmd::Result(result)).ok();
                        })
                        .drop_on_shutdown()
                });
            }

            ConnectDialogInput::TestConnection => {
                self.set_busy(BusyKind::Testing);

                let idx = self.driver_combo.selected() as usize;
                let Some(entry) = self.drivers.get(idx).cloned() else {
                    self.set_busy(BusyKind::None);
                    self.show_toast(&crate::i18n::gettext("No driver selected"));
                    return;
                };
                let Some(driver) = self.registry.get(&entry.id) else {
                    self.set_busy(BusyKind::None);
                    self.show_toast(&crate::i18n::gettext_f(
                        "Driver {id} not registered",
                        &[("id", &entry.id)],
                    ));
                    return;
                };
                let opts = self.collect_options();
                let ssh_inputs = if self.ssh.is_enabled() {
                    match self.ssh.collect() {
                        Ok(inputs) => Some(inputs.cfg),
                        Err(e) => {
                            self.set_busy(BusyKind::None);
                            self.show_toast(&e);
                            return;
                        }
                    }
                } else {
                    None
                };

                sender.command(move |out, shutdown| {
                    shutdown
                        .register(async move {
                            let result =
                                match connection_service::establish(driver.as_ref(), opts, ssh_inputs, false).await {
                                    Ok((conn, _tunnel)) => match conn.list_tables().await {
                                        Ok(tables) => Ok(tables.len()),
                                        Err(e) => Err(format!("list_tables: {e}")),
                                    },
                                    Err(e) => Err(e),
                                };
                            out.send(ConnectDialogCmd::TestResult(result)).ok();
                        })
                        .drop_on_shutdown()
                });
            }

            ConnectDialogInput::Closed => {
                let _ = sender.output(ConnectDialogOutput::Closed);
            }
        }
    }

    fn update_cmd(&mut self, msg: Self::CommandOutput, sender: ComponentSender<Self>, root: &Self::Root) {
        self.set_busy(BusyKind::None);
        match msg {
            ConnectDialogCmd::Result(Ok(outcome)) => {
                tracing::info!(
                    driver = %outcome.saved.driver_id,
                    table_count = outcome.tables.len(),
                    "connected"
                );
                // The dialog opens on this driver next time.
                if let Err(error) = self.settings.set_connect_dialog_driver(&outcome.saved.driver_id) {
                    tracing::warn!(%error, "could not remember the connect dialog driver");
                }
                // A keyring refusal must not be silent: the connection
                // opened, but the password will be asked for next time.
                for warning in &outcome.secret_warnings {
                    let _ = sender.output(ConnectDialogOutput::Warning(warning.clone()));
                }
                let _ = sender.output(ConnectDialogOutput::Connected {
                    tables: outcome.tables,
                    driver_id: outcome.saved.driver_id,
                });
                root.close();
            }
            ConnectDialogCmd::Result(Err(e)) => {
                tracing::warn!(error = %e, "connect failed");
                self.show_toast(&e);
            }
            ConnectDialogCmd::TestResult(Ok(table_count)) => {
                self.show_toast(&crate::i18n::gettext_f(
                    "Connection ok · {n} table(s) visible",
                    &[("n", &table_count.to_string())],
                ));
            }
            ConnectDialogCmd::TestResult(Err(e)) => {
                self.show_toast(&crate::i18n::gettext_f("Test failed: {error}", &[("error", &e)]));
            }
        }
    }
}

impl ConnectDialog {
    fn refresh_validity(&self) {
        let database_empty = self.database.text().trim().is_empty();
        toggle_error(&self.database, database_empty);

        let host_required = !self.form.file_based;
        let host_empty = host_required && self.host.text().trim().is_empty();
        toggle_error(&self.host, host_empty);

        let username_required = self.form.shows_credentials();
        let username_empty = username_required && self.username.text().trim().is_empty();
        toggle_error(&self.username, username_empty);

        let valid = self.is_form_valid();
        self.submit.set_sensitive(valid);
        self.test_button.set_sensitive(valid);
    }

    fn is_form_valid(&self) -> bool {
        if self.database.text().trim().is_empty() {
            return false;
        }
        if !self.form.file_based {
            if self.host.text().trim().is_empty() {
                return false;
            }
            if self.form.shows_credentials() && self.username.text().trim().is_empty() {
                return false;
            }
        }
        if self.ssh.is_enabled() {
            return self.ssh.collect().is_ok();
        }
        true
    }

    /// Show the driver's form and put its default port in, unless the
    /// user has typed one. Their host, database and username stay: a
    /// look at another driver must not wipe what they filled in.
    fn apply_driver(&mut self, index: usize, root: &adw::Dialog) {
        let Some(entry) = self.drivers.get(index).cloned() else {
            return;
        };
        if let Some(driver) = self.registry.get(&entry.id) {
            self.apply_driver_form_visibility(driver.as_ref());
            if !self.port_edited.get() {
                // Writing the port would otherwise look like the user
                // typing it, and pin the port to this driver's default.
                self.port.block_signal(&self.port_handler);
                self.port.set_value(driver.default_port() as f64);
                self.port.unblock_signal(&self.port_handler);
            }
        }
        root.set_title(&crate::i18n::gettext_f(
            "Connect to {name}",
            &[("name", &entry.display_name)],
        ));
    }

    fn apply_driver_form_visibility(&mut self, driver: &dyn tablepro_core::DatabaseDriver) {
        self.form.file_based = driver.is_file_based();
        self.form.supports_integrated = driver.supports_integrated_auth();
        self.apply_form_state();
        self.database.set_title(&if self.form.file_based {
            crate::i18n::gettext("File path")
        } else {
            crate::i18n::gettext("Database")
        });
    }

    fn apply_form_state(&self) {
        let network = !self.form.file_based;
        self.host.set_visible(network);
        self.port.set_visible(network);
        self.use_tls.set_visible(network);
        // For file-based drivers (SQLite), only Connection + Options
        // groups make sense; hide Authentication and SSH entirely.
        self.auth_group.set_visible(network);
        self.ssh.set_visible(network);
        self.auth_combo.set_visible(self.form.shows_method());
        let credentials = self.form.shows_credentials();
        self.username.set_visible(credentials);
        self.password.set_visible(credentials);
    }

    fn collect_options(&self) -> ConnectOptions {
        // The credential rows keep their text while hidden, so a mode or
        // driver that does not use them must drop it here rather than
        // let it reach the driver and the keyring.
        let (username, password) = if self.form.shows_credentials() {
            (self.username.text().to_string(), self.password.text().to_string())
        } else {
            (String::new(), String::new())
        };
        ConnectOptions {
            host: self.host.text().to_string(),
            port: self.port.value() as u16,
            database: self.database.text().to_string(),
            username,
            password: SecretString::new(password.into()),
            use_tls: self.use_tls.is_active(),
            auth_mode: self.form.mode(),
            service_endpoint: None,
        }
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
        self.submit.set_sensitive(!busy);
        self.test_button.set_sensitive(!busy);
        match kind {
            BusyKind::None => {
                self.submit.set_label(&crate::i18n::gettext("Connect"));
                self.test_button.set_label(&crate::i18n::gettext("Test"));
            }
            BusyKind::Connecting => {
                self.submit.set_label(&crate::i18n::gettext("Connecting…"));
                self.test_button.set_label(&crate::i18n::gettext("Test"));
            }
            BusyKind::Testing => {
                self.submit.set_label(&crate::i18n::gettext("Connect"));
                self.test_button.set_label(&crate::i18n::gettext("Testing…"));
            }
        }
    }
}

/// Where the remembered driver sits in the sorted list, falling back to
/// PostgreSQL and then to whatever is first, so an uninstalled driver
/// id in the settings never opens an empty dialog.
fn driver_index(drivers: &[DriverEntry], remembered: &str) -> usize {
    drivers
        .iter()
        .position(|entry| entry.id == remembered)
        .or_else(|| drivers.iter().position(|entry| entry.id == "postgres"))
        .unwrap_or(0)
}

fn toggle_error(row: &adw::EntryRow, invalid: bool) {
    if invalid {
        row.add_css_class("error");
    } else {
        row.remove_css_class("error");
    }
}

/// The two stores a successful connect writes to. Bundled so the
/// connect future takes one value instead of two.
#[derive(Clone)]
struct SaveTargets {
    connections: ConnectionStore,
    secrets: std::sync::Arc<dyn SecretVault>,
    tasks: tablepro_session::runtime::Tasks,
}

async fn run_connect(
    driver: Arc<dyn tablepro_core::DatabaseDriver>,
    targets: SaveTargets,
    driver_id: String,
    label: String,
    opts: ConnectOptions,
    ssh: Option<SshInputs>,
    read_only: bool,
) -> Result<ConnectOutcome, String> {
    let stored_password: SecretString = opts.password.clone();
    let ssh_for_establish = ssh.as_ref().map(|s| s.cfg.clone());
    let opts_clone = opts.clone();

    let (conn, tunnel) =
        connection_service::establish(driver.as_ref(), opts.clone(), ssh_for_establish, read_only).await?;
    let tables = conn.list_tables().await.map_err(|e| format!("list_tables: {e}"))?;

    // Read once: the entry says both which id to write under and what
    // the user already put on it that this form does not carry.
    let existing = find_existing(&targets, &driver_id, &opts_clone, driver.is_file_based(), ssh.as_ref()).await;
    let is_new = existing.is_none();
    let id = existing.as_ref().map(|saved| saved.id).unwrap_or_else(Uuid::new_v4);

    let mut saved = SavedConnection {
        id,
        name: label.clone(),
        driver_id: driver_id.clone(),
        host: opts_clone.host.clone(),
        port: opts_clone.port,
        database: opts_clone.database.clone(),
        username: opts_clone.username.clone(),
        use_tls: opts_clone.use_tls,
        read_only,
        auth_mode: opts_clone.auth_mode,
        ssh: ssh.as_ref().map(|s| s.saved.clone()),
        // Stays None until `App::on_connected` stamps it. Save then
        // connect arrives in that order, so a freshly-saved entry is
        // briefly None on disk before the touch lands.
        last_opened_at: None,
        // The colour and the group are put on from the connection list,
        // not from this form, so reconnecting through the dialog has to
        // carry what is already there instead of clearing it.
        color: existing.as_ref().and_then(|saved| saved.color),
        group: existing.as_ref().and_then(|saved| saved.group.clone()),
    };

    // Secrets go in first, so the single list write can record whether
    // the passphrase actually landed. Storing after the write would
    // leave has_passphrase claiming a secret that is not there.
    let mut report = SecretSaveReport::default();
    if saved.auth_mode == AuthMode::Password {
        let label = secret_labels::secret_label(SecretKind::DatabasePassword, &saved);
        report.record(
            SecretKind::DatabasePassword,
            targets
                .secrets
                .store(saved.id, SecretKind::DatabasePassword, &stored_password, &label)
                .await,
        );
    }
    if let Some(section) = &ssh {
        match &section.secret_to_store {
            SshSecretToStore::Password(secret) => {
                let label = secret_labels::secret_label(SecretKind::SshPassword, &saved);
                report.record(
                    SecretKind::SshPassword,
                    targets
                        .secrets
                        .store(saved.id, SecretKind::SshPassword, secret, &label)
                        .await,
                );
            }
            SshSecretToStore::Passphrase(secret) => {
                let label = secret_labels::secret_label(SecretKind::SshPassphrase, &saved);
                let stored = report.record(
                    SecretKind::SshPassphrase,
                    targets
                        .secrets
                        .store(saved.id, SecretKind::SshPassphrase, secret, &label)
                        .await,
                );
                if let Some(config) = saved.ssh.as_mut()
                    && let tablepro_storage::SavedSshAuth::PrivateKey { has_passphrase, .. } = &mut config.auth
                {
                    *has_passphrase = stored;
                }
            }
            SshSecretToStore::None => {}
        }
    }

    if let Err(error) = save_one(&targets, &saved).await {
        // The list write is what makes the connection real. Without it
        // the secrets just stored belong to nothing, so they go again.
        if is_new {
            let _ = targets.secrets.delete_connection(saved.id).await;
        }
        return Err(crate::i18n::gettext_f(
            "The connection could not be saved: {error}",
            &[("error", &error.to_string())],
        ));
    }
    for message in report.messages() {
        tracing::warn!(message, "a secret was not stored");
    }
    let secret_warnings = report.messages();

    let params = ReconnectParams {
        driver: driver.clone(),
        opts: opts_clone,
        ssh: ssh.as_ref().map(|s| s.cfg.clone()),
        read_only,
    };
    let metadata = crate::services::database_service::ConnectionMetadata {
        id: saved.id,
        name: saved.name.clone(),
        driver_id: saved.driver_id.clone(),
    };
    database_service::instance().add(saved.id, metadata, conn, tunnel, read_only, params);
    Ok(ConnectOutcome {
        saved,
        tables,
        secret_warnings,
    })
}

/// The store serialises the read, apply and write itself, so the save
/// path is one call and two concurrent saves cannot lose an entry.
async fn save_one(targets: &SaveTargets, connection: &SavedConnection) -> Result<(), tablepro_storage::StorageError> {
    let connections = targets.connections.clone();
    let connection = connection.clone();
    targets
        .tasks
        .spawn_blocking_task(move || connections.upsert_blocking(connection))
        .await
        .map_err(|failure| {
            tablepro_storage::StorageError::Schema(format!("the connections write task failed: {failure}"))
        })?
}

async fn load_connections(
    targets: &SaveTargets,
) -> Result<std::sync::Arc<[SavedConnection]>, tablepro_storage::StorageError> {
    let connections = targets.connections.clone();
    targets
        .tasks
        .spawn_blocking_task(move || connections.load_blocking())
        .await
        .map_err(|failure| {
            tablepro_storage::StorageError::Schema(format!("the connections read task failed: {failure}"))
        })?
}

async fn find_existing(
    targets: &SaveTargets,
    driver_id: &str,
    opts: &ConnectOptions,
    file_based: bool,
    ssh: Option<&SshInputs>,
) -> Option<SavedConnection> {
    let existing = load_connections(targets).await.ok()?;
    existing
        .iter()
        .find(|saved| matches_existing(saved, driver_id, opts, file_based, ssh))
        .cloned()
}

fn matches_existing(
    saved: &SavedConnection,
    driver_id: &str,
    opts: &ConnectOptions,
    file_based: bool,
    ssh: Option<&SshInputs>,
) -> bool {
    if saved.driver_id != driver_id || saved.database != opts.database {
        return false;
    }
    // A file-based driver is reached by its path alone. Comparing the
    // credentials there would strand every entry an older build wrote
    // with the hidden Username row's leftover text.
    if file_based {
        return true;
    }
    saved.host == opts.host
        && saved.port == opts.port
        && saved.username == opts.username
        && saved.auth_mode == opts.auth_mode
        && saved_ssh_matches(&saved.ssh, ssh)
}

fn saved_ssh_matches(saved: &Option<SavedSshConfig>, current: Option<&SshInputs>) -> bool {
    match (saved, current) {
        (None, None) => true,
        (Some(s), Some(c)) => &c.saved == s,
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// (state, mode, shows_method, shows_credentials)
    #[test]
    fn auth_form_state_drives_mode_and_visibility() {
        let cases = [
            (AuthFormState::default(), AuthMode::Password, false, true),
            // MSSQL: offers the selector, password until Kerberos is picked.
            (
                AuthFormState {
                    file_based: false,
                    supports_integrated: true,
                    selected: AuthMode::Password,
                },
                AuthMode::Password,
                true,
                true,
            ),
            (
                AuthFormState {
                    file_based: false,
                    supports_integrated: true,
                    selected: AuthMode::Kerberos,
                },
                AuthMode::Kerberos,
                true,
                false,
            ),
            // Postgres: a stale Kerberos selection does not survive the switch.
            (
                AuthFormState {
                    file_based: false,
                    supports_integrated: false,
                    selected: AuthMode::Kerberos,
                },
                AuthMode::Password,
                false,
                true,
            ),
            // SQLite: no credentials at all.
            (
                AuthFormState {
                    file_based: true,
                    supports_integrated: true,
                    selected: AuthMode::Kerberos,
                },
                AuthMode::Password,
                false,
                false,
            ),
        ];
        for (state, mode, method, credentials) in cases {
            assert_eq!(state.mode(), mode, "{state:?}");
            assert_eq!(state.shows_method(), method, "{state:?}");
            assert_eq!(state.shows_credentials(), credentials, "{state:?}");
        }
    }

    #[test]
    fn the_combo_rows_decode_to_the_modes_they_are_labelled_with() {
        assert_eq!(auth_mode_for_row(0), AuthMode::Password);
        assert_eq!(auth_mode_for_row(1), AuthMode::Kerberos);
        assert_eq!(auth_mode_for_row(7), AuthMode::Password);
        assert_eq!(AUTH_MODE_ROWS.len(), 2);
    }

    fn saved(driver_id: &str, username: &str, auth_mode: AuthMode) -> SavedConnection {
        SavedConnection {
            id: Uuid::new_v4(),
            name: "saved".into(),
            driver_id: driver_id.into(),
            host: "sql.corp.example".into(),
            port: 1433,
            database: "sales".into(),
            username: username.into(),
            use_tls: false,
            read_only: false,
            auth_mode,
            ssh: None,
            last_opened_at: None,
            color: None,
            group: None,
        }
    }

    fn opts(username: &str, auth_mode: AuthMode) -> ConnectOptions {
        ConnectOptions {
            host: "sql.corp.example".into(),
            port: 1433,
            database: "sales".into(),
            username: username.into(),
            auth_mode,
            ..Default::default()
        }
    }

    #[test]
    fn a_file_based_entry_is_identified_by_its_path_alone() {
        let legacy = saved("sqlite", "postgres", AuthMode::Password);
        assert!(matches_existing(
            &legacy,
            "sqlite",
            &opts("", AuthMode::Password),
            true,
            None
        ));
    }

    #[test]
    fn a_network_entry_still_distinguishes_user_and_auth_mode() {
        let entry = saved("mssql", "sa", AuthMode::Password);
        assert!(matches_existing(
            &entry,
            "mssql",
            &opts("sa", AuthMode::Password),
            false,
            None
        ));
        assert!(!matches_existing(
            &entry,
            "mssql",
            &opts("other", AuthMode::Password),
            false,
            None
        ));
        assert!(!matches_existing(
            &entry,
            "mssql",
            &opts("", AuthMode::Kerberos),
            false,
            None
        ));
    }

    #[test]
    fn two_kerberos_entries_on_one_host_are_told_apart_by_database() {
        let sales = saved("mssql", "", AuthMode::Kerberos);
        let mut finance = opts("", AuthMode::Kerberos);
        finance.database = "finance".into();
        assert!(matches_existing(
            &sales,
            "mssql",
            &opts("", AuthMode::Kerberos),
            false,
            None
        ));
        assert!(!matches_existing(&sales, "mssql", &finance, false, None));
    }

    fn test_dialog() -> relm4::component::Controller<ConnectDialog> {
        dialog_with(&crate::test_support::MemorySettings::new())
    }

    /// Every driver the app ships, so the combo has the same shape a
    /// user sees and a remembered id has somewhere to land.
    fn dialog_with(settings: &crate::test_support::MemorySettings) -> relm4::component::Controller<ConnectDialog> {
        let runtime = crate::runtime::AppRuntime::build().expect("a runtime");
        let root = std::env::temp_dir().join(format!("tablepro-connect-{}", std::process::id()));
        let paths = tablepro_storage::StoragePaths::under(&root, "tablepro-test", "app.tablepro.TablePro.Devel");
        let storage = std::rc::Rc::new(crate::storage::AppStorage::new(
            paths,
            std::sync::Arc::new(tablepro_storage::SecretStore::new(crate::config::secret_schema())),
            &runtime.tasks(),
        ));
        let mut registry = DriverRegistry::new();
        registry.register(std::sync::Arc::new(drivers_clickhouse::ClickhouseDriver));
        registry.register(std::sync::Arc::new(drivers_postgres::PgDriver));
        registry.register(std::sync::Arc::new(drivers_sqlite::SqliteDriver));

        ConnectDialog::builder()
            .launch(ConnectDialogInit {
                registry: Arc::new(registry),
                storage,
                settings: settings.get().clone(),
                tasks: runtime.tasks(),
            })
            .detach()
    }

    /// The combo row index of a driver id, as the sorted list has it.
    fn row_for(controller: &relm4::component::Controller<ConnectDialog>, driver_id: &str) -> u32 {
        let model = controller.model();
        let index = model
            .drivers
            .iter()
            .position(|entry| entry.id == driver_id)
            .unwrap_or_else(|| panic!("{driver_id} is not in the combo"));
        index as u32
    }

    #[gtk4::test]
    fn dialog_opens_with_remembered_driver_and_its_port() {
        let settings = crate::test_support::MemorySettings::new();
        settings
            .get()
            .set_connect_dialog_driver("clickhouse")
            .expect("remember the driver");

        let controller = dialog_with(&settings);
        let model = controller.model();

        assert_eq!(model.driver_combo.selected(), row_for(&controller, "clickhouse"));
        assert_eq!(model.port.value() as u16, 8123);
        assert_eq!(model.host.text(), "", "the host was prefilled instead of placeholdered");
        assert_eq!(model.database.text(), "");
        assert_eq!(model.username.text(), "");
    }

    #[gtk4::test]
    fn an_uninstalled_remembered_driver_falls_back_to_postgres() {
        let settings = crate::test_support::MemorySettings::new();
        settings
            .get()
            .set_connect_dialog_driver("cassandra")
            .expect("remember the driver");

        let controller = dialog_with(&settings);

        assert_eq!(
            controller.model().driver_combo.selected(),
            row_for(&controller, "postgres")
        );
    }

    #[gtk4::test]
    fn driver_switch_keeps_user_edited_port() {
        let controller = dialog_with(&crate::test_support::MemorySettings::new());
        let clickhouse = row_for(&controller, "clickhouse");
        controller.model().port.set_value(6543.0);

        controller
            .sender()
            .send(ConnectDialogInput::DriverChanged(clickhouse))
            .expect("the dialog is running");
        crate::test_support::drain_main_context();

        assert_eq!(
            controller.model().port.value() as u16,
            6543,
            "a driver switch overwrote a port the user typed"
        );
    }

    #[gtk4::test]
    fn a_driver_switch_moves_an_untouched_port() {
        let controller = dialog_with(&crate::test_support::MemorySettings::new());
        assert_eq!(controller.model().port.value() as u16, 5432);
        let clickhouse = row_for(&controller, "clickhouse");

        controller
            .sender()
            .send(ConnectDialogInput::DriverChanged(clickhouse))
            .expect("the dialog is running");
        crate::test_support::drain_main_context();

        assert_eq!(controller.model().port.value() as u16, 8123);
    }

    #[gtk4::test]
    fn driver_switch_keeps_typed_host_and_user() {
        let controller = dialog_with(&crate::test_support::MemorySettings::new());
        {
            let model = controller.model();
            model.host.set_text("db.corp.example");
            model.database.set_text("sales");
            model.username.set_text("reporting");
        }
        let clickhouse = row_for(&controller, "clickhouse");

        controller
            .sender()
            .send(ConnectDialogInput::DriverChanged(clickhouse))
            .expect("the dialog is running");
        crate::test_support::drain_main_context();

        let model = controller.model();
        assert_eq!(model.host.text(), "db.corp.example");
        assert_eq!(model.database.text(), "sales");
        assert_eq!(model.username.text(), "reporting");
    }

    #[gtk4::test]
    fn enter_in_any_text_row_reaches_connect() {
        // Enter needs both halves: activates-default on the row, which
        // is what makes AdwEntryRow call gtk_widget_activate_default,
        // and Connect as the dialog's default widget for it to reach.
        // `structure_tab_dialogs` proves the pair really fires a click.
        let controller = test_dialog();
        let model = controller.model();

        assert!(model.host.activates_default(), "host");
        assert!(model.database.activates_default(), "database");
        assert!(model.username.activates_default(), "username");
        assert!(model.password.activates_default(), "password");
        assert_eq!(
            controller.widget().default_widget(),
            Some(model.submit.clone().upcast::<gtk::Widget>()),
            "Connect is not the dialog's default widget"
        );
    }

    #[gtk4::test]
    fn connect_stays_insensitive_until_the_form_is_valid() {
        // Enter on an invalid form does nothing because AdwDialog skips
        // an insensitive default widget.
        let controller = test_dialog();
        let model = controller.model();
        model.host.set_text("");
        model.database.set_text("postgres");
        model.username.set_text("postgres");
        model.refresh_validity();
        assert!(!model.submit.is_sensitive(), "Connect was sensitive without a host");

        model.host.set_text("localhost");
        model.refresh_validity();

        assert!(
            model.submit.is_sensitive(),
            "Connect stayed insensitive on a valid form"
        );
    }

    #[gtk4::test]
    fn every_ssh_text_row_submits_on_enter() {
        let controller = test_dialog();
        let ssh = &controller.model().ssh;

        for (name, activates) in ssh.rows_activating_default() {
            assert!(activates, "{name} does not submit on Enter");
        }
    }
}
