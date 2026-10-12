use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;

use relm4::adw::prelude::*;
use relm4::prelude::*;
use relm4::{adw, gtk};
use secrecy::SecretString;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use tablepro_core::credentials::{SecretKind, SecretSave};
use tablepro_core::{
    AuthMode, ConfigError, Credentials, DriverError, FileEndpoint, NetworkEndpoint, TlsConfig, TlsMode,
    WorkspaceSettings,
};
use tablepro_session::connect::AttemptGeneration;
use tablepro_session::{
    ConnectAttempts, ConnectError, ConnectRequest, ConnectionMetadata, PendingSave, PendingSession, RequestTarget,
    SessionKey,
};
use tablepro_storage::{SavedConnection, SavedSshConfig};

use super::ssh_section::{SshInputs, SshSecretToStore, SshSection};

use crate::services::secret_labels;
use crate::services::session_context::SessionContext;
use crate::ui::app::ReadySession;

pub struct ConnectDialog {
    context: Rc<SessionContext>,
    storage: crate::storage::SharedStorage,
    settings: Rc<tablepro_storage::AppSettings>,
    /// The Connect or Test run in flight; closing the dialog or starting
    /// another one cancels it and discards whatever it brings back.
    attempts: ConnectAttempts,
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
    pub context: Rc<SessionContext>,
    pub storage: crate::storage::SharedStorage,
    pub settings: Rc<tablepro_storage::AppSettings>,
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
    /// The connection works and is saved; the window adopts it.
    Connected(Box<ReadySession>),
    Closed,
}

/// What a successful connect produced, including anything the keyring
/// refused to keep so the dialog can say so.
#[derive(Debug)]
pub struct ConnectOutcome {
    pub saved: SavedConnection,
    pub pending: PendingSession,
    pub secret_warnings: Vec<String>,
}

/// How a Connect or a Test ended, for an error the user cancelled
/// carries no message.
#[derive(Debug)]
pub enum ConnectDialogCmd {
    Result(AttemptGeneration, Box<Result<ConnectOutcome, Option<String>>>),
    TestResult(AttemptGeneration, Result<usize, Option<String>>),
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
            .context
            .drivers
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
            context: init.context,
            storage: init.storage,
            settings: init.settings,
            attempts: ConnectAttempts::new(),
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
                let attempt = match self.prepare_attempt() {
                    Ok(attempt) => attempt,
                    Err(message) => {
                        self.show_toast(&message);
                        return;
                    }
                };
                self.set_busy(BusyKind::Connecting);
                let ticket = self.attempts.begin();
                let generation = ticket.generation();
                let work = run_connect(attempt, ticket.cancel().clone());
                let commands = sender.command_sender().clone();
                crate::runtime::spawn_and_deliver(&self.context.tasks, work, move |outcome| {
                    let outcome = outcome.unwrap_or_else(|failure| {
                        Err(Some(crate::ui::error_text::task_failure_message(&failure)))
                    });
                    commands.emit(ConnectDialogCmd::Result(generation, Box::new(outcome)));
                });
            }

            ConnectDialogInput::TestConnection => {
                let attempt = match self.prepare_attempt() {
                    Ok(attempt) => attempt,
                    Err(message) => {
                        self.show_toast(&message);
                        return;
                    }
                };
                self.set_busy(BusyKind::Testing);
                let ticket = self.attempts.begin();
                let generation = ticket.generation();
                let work = run_test(attempt, ticket.cancel().clone());
                let commands = sender.command_sender().clone();
                crate::runtime::spawn_and_deliver(&self.context.tasks, work, move |outcome| {
                    let outcome = outcome.unwrap_or_else(|failure| {
                        Err(Some(crate::ui::error_text::task_failure_message(&failure)))
                    });
                    commands.emit(ConnectDialogCmd::TestResult(generation, outcome));
                });
            }

            ConnectDialogInput::Closed => {
                self.attempts.cancel();
                let _ = sender.output(ConnectDialogOutput::Closed);
            }
        }
    }

    fn update_cmd(&mut self, msg: Self::CommandOutput, sender: ComponentSender<Self>, root: &Self::Root) {
        let generation = match &msg {
            ConnectDialogCmd::Result(generation, _) | ConnectDialogCmd::TestResult(generation, _) => *generation,
        };
        if !self.attempts.accepts(generation) {
            // A late answer to an attempt the user replaced or stopped.
            if let ConnectDialogCmd::Result(_, outcome) = msg
                && let Ok(outcome) = *outcome
            {
                discard(&self.context, outcome.pending);
            }
            return;
        }
        self.set_busy(BusyKind::None);
        self.refresh_validity();
        match msg {
            ConnectDialogCmd::Result(_, outcome) => match *outcome {
                Ok(outcome) => {
                    tracing::info!(driver = %outcome.saved.driver_id, "connected");
                    // The dialog opens on this driver next time.
                    if let Err(error) = self.settings.set_connect_dialog_driver(&outcome.saved.driver_id) {
                        tracing::warn!(%error, "could not remember the connect dialog driver");
                    }
                    let credentials = Arc::new(self.context.keyring_credentials(&outcome.saved));
                    let ready = ReadySession {
                        key: SessionKey::Saved(outcome.saved.id),
                        pending: outcome.pending,
                        credentials,
                        // A keyring refusal must not be silent: the
                        // connection opened, but the password will be
                        // asked for next time.
                        warnings: outcome.secret_warnings,
                        generation: None,
                    };
                    let _ = sender.output(ConnectDialogOutput::Connected(Box::new(ready)));
                    root.close();
                }
                Err(Some(message)) => {
                    tracing::warn!(error = %message, "connect failed");
                    self.show_toast(&message);
                }
                Err(None) => {}
            },
            ConnectDialogCmd::TestResult(_, Ok(table_count)) => {
                self.show_toast(&crate::i18n::gettext_f(
                    "Connection ok · {n} table(s) visible",
                    &[("n", &table_count.to_string())],
                ));
            }
            ConnectDialogCmd::TestResult(_, Err(Some(message))) => {
                self.show_toast(&crate::i18n::gettext_f("Test failed: {error}", &[("error", &message)]));
            }
            ConnectDialogCmd::TestResult(_, Err(None)) => {}
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
        if let Some(driver) = self.context.drivers.get(&entry.id) {
            let capabilities = driver.capabilities();
            self.apply_driver_form_visibility(capabilities);
            if !self.port_edited.get()
                && let Some(port) = capabilities.default_port()
            {
                // Writing the port would otherwise look like the user
                // typing it, and pin the port to this driver's default.
                self.port.block_signal(&self.port_handler);
                self.port.set_value(f64::from(port));
                self.port.unblock_signal(&self.port_handler);
            }
        }
        root.set_title(&crate::i18n::gettext_f(
            "Connect to {name}",
            &[("name", &entry.display_name)],
        ));
    }

    fn apply_driver_form_visibility(&mut self, capabilities: &tablepro_core::DriverCapabilities) {
        self.form.file_based = capabilities.is_file_based();
        self.form.supports_integrated = capabilities.supports(AuthMode::Kerberos);
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

    /// What the form says, read once so the connect works from a
    /// snapshot rather than from widgets the user can still change.
    fn form_values(&self) -> FormValues {
        // The credential rows keep their text while hidden, so a mode or
        // driver that does not use them must drop it here rather than
        // let it reach the driver and the keyring.
        let (username, password) = if self.form.shows_credentials() {
            (self.username.text().to_string(), self.password.text().to_string())
        } else {
            (String::new(), String::new())
        };
        FormValues {
            host: self.host.text().to_string(),
            port: self.port.value() as u16,
            database: self.database.text().to_string(),
            username,
            password: SecretString::from(password),
            auth_mode: self.form.mode(),
            use_tls: self.use_tls.is_active(),
            read_only: self.read_only.is_active(),
            file_based: self.form.file_based,
        }
    }

    /// Everything a Connect or a Test needs, or the sentence that says
    /// why the form cannot be used yet.
    fn prepare_attempt(&self) -> Result<ConnectAttempt, String> {
        let index = self.driver_combo.selected() as usize;
        let Some(entry) = self.drivers.get(index) else {
            return Err(crate::i18n::gettext("No driver selected"));
        };
        let Some(driver) = self.context.drivers.get(&entry.id) else {
            return Err(crate::i18n::gettext_f(
                "Driver {id} not registered",
                &[("id", &entry.id)],
            ));
        };
        let ssh = if self.ssh.is_enabled() && !self.form.file_based {
            Some(self.ssh.collect()?)
        } else {
            None
        };
        Ok(ConnectAttempt {
            driver_id: entry.id.clone(),
            driver,
            form: self.form_values(),
            ssh,
            context: AttemptServices {
                connector: self.context.connector.clone(),
                interaction: self.context.attended(),
                secrets: self.context.secrets.clone(),
                connections: self.storage.connections().clone(),
                tasks: self.context.tasks.clone(),
            },
        })
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

/// What the user typed, as the connect needs it.
#[derive(Debug, Clone)]
struct FormValues {
    host: String,
    port: u16,
    database: String,
    username: String,
    password: SecretString,
    auth_mode: AuthMode,
    use_tls: bool,
    read_only: bool,
    file_based: bool,
}

impl FormValues {
    /// How the entry is named in the connection list.
    fn label(&self) -> String {
        if self.file_based {
            self.database.clone()
        } else if self.auth_mode == AuthMode::Kerberos {
            self.host.clone()
        } else {
            format!("{}@{}", self.username, self.host)
        }
    }

    /// The TLS settings to save. The switch only says on or off; an
    /// entry that already carries a CA file or a server name keeps them
    /// while TLS stays on, so reconnecting through this form does not
    /// strip settings it cannot show.
    fn tls(&self, existing: Option<&SavedConnection>) -> TlsConfig {
        if self.file_based || !self.use_tls {
            return TlsConfig::disabled();
        }
        match existing.map(|saved| &saved.tls) {
            Some(tls) if tls.mode != TlsMode::Disable => tls.clone(),
            _ => TlsConfig::verify_full(),
        }
    }

    /// Where the connect goes. A database file that is not there yet is
    /// created, which is what this form has always done.
    fn target(&self, tls: TlsConfig, ssh: Option<&SshInputs>) -> Result<RequestTarget, ConfigError> {
        if self.file_based {
            let path = PathBuf::from(self.database.trim());
            let endpoint = if path.exists() {
                FileEndpoint::open_existing(path)?
            } else {
                FileEndpoint::create_new(path)?
            };
            return Ok(RequestTarget::File(endpoint));
        }
        let credentials = match self.auth_mode {
            AuthMode::Password => Credentials::Password {
                username: self.username.clone(),
                password: self.password.clone(),
            },
            AuthMode::Kerberos => Credentials::Integrated,
        };
        Ok(RequestTarget::Network {
            endpoint: NetworkEndpoint::new(&self.host, self.port)?,
            ssh: ssh.map(|inputs| inputs.cfg.clone()),
            credentials,
            database: Some(self.database.trim().to_owned()).filter(|name| !name.is_empty()),
            tls,
        })
    }
}

/// The app services a connect from this dialog uses, gathered so the
/// work can leave the GTK thread.
#[derive(Clone)]
struct AttemptServices {
    connector: Arc<dyn tablepro_session::Connector>,
    interaction: tablepro_core::credentials::CredentialInteraction,
    secrets: Arc<dyn tablepro_core::credentials::SecretVault>,
    connections: tablepro_storage::ConnectionStore,
    tasks: tablepro_session::runtime::Tasks,
}

/// One Connect or Test, from a snapshot of the form.
struct ConnectAttempt {
    driver_id: String,
    driver: Arc<dyn tablepro_core::DatabaseDriver>,
    form: FormValues,
    ssh: Option<SshInputs>,
    context: AttemptServices,
}

impl ConnectAttempt {
    fn request(&self, metadata: ConnectionMetadata, tls: TlsConfig) -> Result<ConnectRequest, String> {
        let target = self
            .form
            .target(tls, self.ssh.as_ref())
            .map_err(|error| crate::ui::error_text::driver_message(&DriverError::Config(error)))?;
        Ok(ConnectRequest {
            metadata,
            driver: self.driver.clone(),
            target,
            workspace_settings: WorkspaceSettings::workspace(self.form.read_only),
        })
    }

    fn saved_connection(&self, id: Uuid, existing: Option<&SavedConnection>) -> SavedConnection {
        SavedConnection {
            id,
            name: self.form.label(),
            driver_id: self.driver_id.clone(),
            host: self.form.host.clone(),
            port: self.form.port,
            database: self.form.database.clone(),
            username: self.form.username.clone(),
            tls: self.form.tls(existing),
            read_only: self.form.read_only,
            auth_mode: self.form.auth_mode,
            ssh: self.ssh.as_ref().map(|inputs| inputs.saved.clone()),
            // Stays None until `App::on_connected` stamps it.
            last_opened_at: None,
            // The colour and the group are put on from the connection
            // list, not from this form, so reconnecting through the
            // dialog has to carry what is already there.
            color: existing.and_then(|saved| saved.color),
            group: existing.and_then(|saved| saved.group.clone()),
        }
    }

    /// The secrets the entry is saved with. The database password goes
    /// in even when empty: a login with no password is still a login
    /// the keyring answers for.
    fn secrets_to_store(&self, saved: &SavedConnection) -> Vec<SecretSave> {
        let save = |kind, secret: &SecretString| SecretSave {
            kind,
            secret: secret.clone(),
            label: secret_labels::secret_label(kind, saved),
        };
        let mut secrets = Vec::new();
        if !self.form.file_based && self.form.auth_mode == AuthMode::Password {
            secrets.push(save(SecretKind::DatabasePassword, &self.form.password));
        }
        match self.ssh.as_ref().map(|inputs| &inputs.secret_to_store) {
            Some(SshSecretToStore::Password(secret)) => secrets.push(save(SecretKind::SshPassword, secret)),
            Some(SshSecretToStore::Passphrase(secret)) => secrets.push(save(SecretKind::SshPassphrase, secret)),
            Some(SshSecretToStore::None) | None => {}
        }
        secrets
    }

    async fn find_existing(&self) -> Option<SavedConnection> {
        let connections = self.context.connections.clone();
        let loaded = self
            .context
            .tasks
            .spawn_blocking_task(move || connections.load_blocking())
            .await;
        let existing = match loaded {
            Ok(Ok(existing)) => existing,
            Ok(Err(error)) => {
                tracing::warn!(%error, "the saved connections could not be read to match this one");
                return None;
            }
            Err(failure) => {
                tracing::warn!(%failure, "the connections read task failed");
                return None;
            }
        };
        existing
            .iter()
            .find(|saved| matches_existing(saved, &self.driver_id, &self.form, self.ssh.as_ref()))
            .cloned()
    }
}

/// A cancelled connect needs no message: the user stopped it.
fn connect_failure(error: ConnectError) -> Option<String> {
    match error {
        ConnectError::Cancelled => None,
        error => Some(crate::ui::error_text::connect_error_message(&error)),
    }
}

/// Connect, then save the entry and its secrets. Saving waits for the
/// connect so a typo never lands in the connection list.
async fn run_connect(attempt: ConnectAttempt, cancel: CancellationToken) -> Result<ConnectOutcome, Option<String>> {
    let existing = attempt.find_existing().await;
    let is_new = existing.is_none();
    let id = existing.as_ref().map_or_else(Uuid::new_v4, |saved| saved.id);
    let saved = attempt.saved_connection(id, existing.as_ref());
    let metadata = ConnectionMetadata {
        id,
        name: saved.name.clone(),
        driver_id: saved.driver_id.clone(),
    };
    let request = attempt.request(metadata, saved.tls.clone()).map_err(Some)?;
    let services = attempt.context.clone();
    let pending = services
        .connector
        .establish(request, services.interaction.clone(), cancel)
        .await
        .map_err(connect_failure)?;

    let save = PendingSave {
        secrets: attempt.secrets_to_store(&saved),
        connection: saved,
        is_new,
    };
    let writes = tablepro_session::connect::StoreConnectionWrites::new(services.connections, services.tasks);
    match tablepro_session::persist_pending_save(&*services.secrets, &writes, save).await {
        Ok(report) => {
            let secret_warnings = report
                .secret_failures
                .iter()
                .map(|(_, error)| crate::services::secret_save_report::not_saved_message(error))
                .collect();
            Ok(ConnectOutcome {
                saved: report.saved,
                pending,
                secret_warnings,
            })
        }
        Err(error) => {
            let report = pending.discard().await;
            tracing::debug!(?report, "closed a connection whose entry could not be saved");
            Err(Some(crate::i18n::gettext_f(
                "The connection could not be saved: {error}",
                &[("error", &error.to_string())],
            )))
        }
    }
}

/// Connect, count what the sidebar would show, and close again.
async fn run_test(attempt: ConnectAttempt, cancel: CancellationToken) -> Result<usize, Option<String>> {
    let metadata = ConnectionMetadata {
        id: Uuid::new_v4(),
        name: attempt.form.label(),
        driver_id: attempt.driver_id.clone(),
    };
    let request = attempt.request(metadata, attempt.form.tls(None)).map_err(Some)?;
    let pending = attempt
        .context
        .connector
        .establish(request, attempt.context.interaction.clone(), cancel)
        .await
        .map_err(connect_failure)?;
    let visible = pending
        .objects()
        .iter()
        .filter(|object| object.kind.is_browsable())
        .count();
    let report = pending.discard().await;
    tracing::debug!(?report, "closed the test connection");
    Ok(visible)
}

/// Close a connection the dialog no longer wants, keeping the process
/// alive until it is closed.
fn discard(context: &SessionContext, pending: PendingSession) {
    let hold = context.hold.acquire();
    let closing = context.tasks.spawn_task(pending.discard());
    glib::spawn_future_local(async move {
        if let Ok(report) = closing.await {
            tracing::debug!(?report, "closed a connection that arrived too late");
        }
        drop(hold);
    });
}

fn matches_existing(saved: &SavedConnection, driver_id: &str, form: &FormValues, ssh: Option<&SshInputs>) -> bool {
    if saved.driver_id != driver_id || saved.database != form.database {
        return false;
    }
    // A file-based driver is reached by its path alone. Comparing the
    // credentials there would strand every entry an older build wrote
    // with the hidden Username row's leftover text.
    if form.file_based {
        return true;
    }
    saved.host == form.host
        && saved.port == form.port
        && saved.username == form.username
        && saved.auth_mode == form.auth_mode
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
            tls: TlsConfig::disabled(),
            read_only: false,
            auth_mode,
            ssh: None,
            last_opened_at: None,
            color: None,
            group: None,
        }
    }

    fn form(username: &str, auth_mode: AuthMode) -> FormValues {
        FormValues {
            host: "sql.corp.example".into(),
            port: 1433,
            database: "sales".into(),
            username: username.into(),
            password: SecretString::from(""),
            auth_mode,
            use_tls: false,
            read_only: false,
            file_based: false,
        }
    }

    fn file_form(path: &str) -> FormValues {
        FormValues {
            database: path.into(),
            file_based: true,
            ..form("", AuthMode::Password)
        }
    }

    #[test]
    fn a_file_based_entry_is_identified_by_its_path_alone() {
        let mut legacy = saved("sqlite", "postgres", AuthMode::Password);
        legacy.database = "/srv/app.db".into();
        assert!(matches_existing(&legacy, "sqlite", &file_form("/srv/app.db"), None));
    }

    #[test]
    fn a_network_entry_still_distinguishes_user_and_auth_mode() {
        let entry = saved("mssql", "sa", AuthMode::Password);
        assert!(matches_existing(&entry, "mssql", &form("sa", AuthMode::Password), None));
        assert!(!matches_existing(&entry, "mssql", &form("other", AuthMode::Password), None));
        assert!(!matches_existing(&entry, "mssql", &form("", AuthMode::Kerberos), None));
    }

    #[test]
    fn two_kerberos_entries_on_one_host_are_told_apart_by_database() {
        let sales = saved("mssql", "", AuthMode::Kerberos);
        let mut finance = form("", AuthMode::Kerberos);
        finance.database = "finance".into();
        assert!(matches_existing(&sales, "mssql", &form("", AuthMode::Kerberos), None));
        assert!(!matches_existing(&sales, "mssql", &finance, None));
    }

    #[test]
    fn the_tls_switch_keeps_the_settings_an_entry_already_has() {
        let mut on = form("sa", AuthMode::Password);
        on.use_tls = true;
        let mut existing = saved("mssql", "sa", AuthMode::Password);
        existing.tls = TlsConfig {
            ca_file: Some(PathBuf::from("/etc/ssl/corp-ca.pem")),
            ..TlsConfig::verify_full()
        };

        assert_eq!(on.tls(Some(&existing)), existing.tls, "a CA file was dropped");
        assert_eq!(on.tls(None), TlsConfig::verify_full());
        assert_eq!(form("sa", AuthMode::Password).tls(Some(&existing)), TlsConfig::disabled());
        assert_eq!(file_form("/srv/app.db").tls(Some(&existing)), TlsConfig::disabled());
    }

    #[test]
    fn a_kerberos_form_sends_no_password_and_an_empty_database_is_none() {
        let mut kerberos = form("ignored", AuthMode::Kerberos);
        kerberos.database = "  ".into();

        let RequestTarget::Network {
            credentials, database, ..
        } = kerberos.target(TlsConfig::disabled(), None).expect("a target")
        else {
            panic!("expected a network target");
        };

        assert!(matches!(credentials, Credentials::Integrated));
        assert_eq!(database, None);
    }

    #[test]
    fn a_missing_database_file_is_created_and_an_existing_one_opened() {
        let root = tempfile::tempdir().expect("tempdir");
        let present = root.path().join("present.db");
        std::fs::write(&present, b"").expect("seed");
        let absent = root.path().join("absent.db");

        let mode = |path: &std::path::Path| match file_form(&path.to_string_lossy()).target(TlsConfig::disabled(), None) {
            Ok(RequestTarget::File(endpoint)) => endpoint.mode(),
            other => panic!("expected a file target, got {other:?}"),
        };

        assert_eq!(mode(&present), tablepro_core::FileOpenMode::OpenExisting);
        assert_eq!(mode(&absent), tablepro_core::FileOpenMode::CreateNew);
        assert_eq!(
            file_form("relative.db").target(TlsConfig::disabled(), None).err(),
            Some(ConfigError::RelativePath)
        );
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
            std::sync::Arc::new(tablepro_test_support::FakeSecretVault::new()),
            &runtime.tasks(),
        ));
        let mut registry = tablepro_core::DriverRegistry::new();
        registry.register(std::sync::Arc::new(drivers_clickhouse::ClickhouseDriver));
        registry.register(std::sync::Arc::new(drivers_postgres::PgDriver));
        registry.register(std::sync::Arc::new(drivers_sqlite::SqliteDriver));

        ConnectDialog::builder()
            .launch(ConnectDialogInit {
                context: SessionContext::for_tests(registry, runtime.tasks()),
                storage,
                settings: settings.get().clone(),
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
