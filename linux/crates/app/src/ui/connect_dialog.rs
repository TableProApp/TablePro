use std::sync::Arc;

use relm4::adw::prelude::*;
use relm4::prelude::*;
use relm4::{adw, gtk};
use secrecy::{ExposeSecret, SecretString};
use uuid::Uuid;

use tablepro_core::{AuthMode, ConnectOptions, DriverRegistry, TableInfo};
use tablepro_storage::{
    SavedConnection, SavedSshConfig, save_connections, store_password, store_ssh_passphrase, store_ssh_password,
};

use super::ssh_section::{SshInputs, SshSecretToStore, SshSection};
use crate::services::connection_service;
use crate::services::database_service::{self, ReconnectParams};

pub struct ConnectDialog {
    registry: Arc<DriverRegistry>,
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
        AuthMode::Password => crate::tr!("Password"),
        AuthMode::Kerberos => crate::tr!("Windows (Kerberos)"),
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
    Connected { tables: Vec<TableInfo>, driver_id: String },
    Closed,
}

#[derive(Debug)]
#[allow(clippy::large_enum_variant)]
pub enum ConnectDialogCmd {
    Result(Result<(SavedConnection, Vec<TableInfo>), String>),
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
            .title(crate::tr!("Driver"))
            .model(&driver_model)
            .build();
        let sender_for_combo = sender.clone();
        driver_combo.connect_selected_notify(move |row| {
            sender_for_combo.input(ConnectDialogInput::DriverChanged(row.selected()));
        });

        let host = adw::EntryRow::builder()
            .title(crate::tr!("Host"))
            .text("localhost")
            .build();
        // Port is a u16 1-65535. AdwSpinRow enforces the range natively;
        // no parse + fallback dance, no inline-error CSS to maintain.
        let port = adw::SpinRow::with_range(1.0, 65535.0, 1.0);
        port.set_title(&crate::tr!("Port"));
        port.set_value(5432.0);
        let database = adw::EntryRow::builder()
            .title(crate::tr!("Database"))
            .text("postgres")
            .build();
        let username = adw::EntryRow::builder()
            .title(crate::tr!("Username"))
            .text("postgres")
            .build();
        let password = adw::PasswordEntryRow::builder().title(crate::tr!("Password")).build();
        let use_tls = adw::SwitchRow::builder()
            .title(crate::tr!("Use TLS"))
            .subtitle(crate::tr!("Require encrypted connection"))
            .active(false)
            .build();
        let read_only = adw::SwitchRow::builder()
            .title(crate::tr!("Read-only mode"))
            .subtitle(crate::tr!("Block INSERT, UPDATE, DELETE, and DDL on this connection"))
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
        let connection_group = adw::PreferencesGroup::builder().title(crate::tr!("Connection")).build();
        connection_group.add(&driver_combo);
        connection_group.add(&host);
        connection_group.add(&port);
        connection_group.add(&database);

        let auth_labels: Vec<String> = AUTH_MODE_ROWS.iter().map(|mode| auth_mode_label(*mode)).collect();
        let auth_labels_ref: Vec<&str> = auth_labels.iter().map(String::as_str).collect();
        let auth_mode_model = gtk::StringList::new(&auth_labels_ref);
        let auth_combo = adw::ComboRow::builder()
            .title(crate::tr!("Method"))
            .model(&auth_mode_model)
            .build();
        let sender_for_authmode = sender.clone();
        auth_combo.connect_selected_notify(move |_| {
            sender_for_authmode.input(ConnectDialogInput::AuthModeChanged);
        });

        let auth_group = adw::PreferencesGroup::builder()
            .title(crate::tr!("Authentication"))
            .build();
        auth_group.add(&auth_combo);
        auth_group.add(&username);
        auth_group.add(&password);

        let options_group = adw::PreferencesGroup::builder().title(crate::tr!("Options")).build();
        options_group.add(&use_tls);
        options_group.add(&read_only);

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

        let page = adw::PreferencesPage::new();
        page.add(&connection_group);
        page.add(&auth_group);
        page.add(&options_group);
        page.add(&ssh.group);
        let toast_overlay = adw::ToastOverlay::new();
        toast_overlay.set_child(Some(&page));

        let mut model = ConnectDialog {
            registry: init.registry,
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
        };
        let widgets = view_output!();

        if let Some(first) = drivers.first() {
            if let Some(driver) = model.registry.get(&first.id) {
                model.apply_driver_form_visibility(driver.as_ref());
            }
            root.set_title(&crate::tr!("Connect to {name}").replace("{name}", &first.display_name));
        }
        model.refresh_validity();

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
                let Some(entry) = self.drivers.get(idx as usize).cloned() else {
                    return;
                };
                if let Some(driver) = self.registry.get(&entry.id) {
                    self.apply_driver_form_visibility(driver.as_ref());
                    self.port.set_value(driver.default_port() as f64);
                }
                root.set_title(&crate::tr!("Connect to {name}").replace("{name}", &entry.display_name));
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

                sender.command(move |out, shutdown| {
                    shutdown
                        .register(async move {
                            let result =
                                run_connect(driver.clone(), driver_id, label, opts, ssh_inputs, read_only).await;
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
                    self.show_toast(&crate::tr!("No driver selected"));
                    return;
                };
                let Some(driver) = self.registry.get(&entry.id) else {
                    self.set_busy(BusyKind::None);
                    self.show_toast(&crate::tr!("Driver {id} not registered").replace("{id}", &entry.id));
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
            ConnectDialogCmd::Result(Ok((saved, tables))) => {
                tracing::info!(driver = %saved.driver_id, table_count = tables.len(), "connected");
                let _ = sender.output(ConnectDialogOutput::Connected {
                    tables,
                    driver_id: saved.driver_id,
                });
                root.close();
            }
            ConnectDialogCmd::Result(Err(e)) => {
                tracing::warn!(error = %e, "connect failed");
                self.show_toast(&e);
            }
            ConnectDialogCmd::TestResult(Ok(table_count)) => {
                self.show_toast(
                    &crate::tr!("Connection ok · {n} table(s) visible").replace("{n}", &table_count.to_string()),
                );
            }
            ConnectDialogCmd::TestResult(Err(e)) => {
                self.show_toast(&crate::tr!("Test failed: {error}").replace("{error}", &e));
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

    fn apply_driver_form_visibility(&mut self, driver: &dyn tablepro_core::DatabaseDriver) {
        self.form.file_based = driver.is_file_based();
        self.form.supports_integrated = driver.supports_integrated_auth();
        self.apply_form_state();
        self.database.set_title(&if self.form.file_based {
            crate::tr!("File path")
        } else {
            crate::tr!("Database")
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
                self.submit.set_label(&crate::tr!("Connect"));
                self.test_button.set_label(&crate::tr!("Test"));
            }
            BusyKind::Connecting => {
                self.submit.set_label(&crate::tr!("Connecting…"));
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

async fn run_connect(
    driver: Arc<dyn tablepro_core::DatabaseDriver>,
    driver_id: String,
    label: String,
    opts: ConnectOptions,
    ssh: Option<SshInputs>,
    read_only: bool,
) -> Result<(SavedConnection, Vec<TableInfo>), String> {
    let stored_password: SecretString = opts.password.clone();
    let ssh_for_establish = ssh.as_ref().map(|s| s.cfg.clone());
    let opts_clone = opts.clone();

    let (conn, tunnel) =
        connection_service::establish(driver.as_ref(), opts.clone(), ssh_for_establish, read_only).await?;
    let tables = conn.list_tables().await.map_err(|e| format!("list_tables: {e}"))?;

    let id = match find_existing_id(&driver_id, &opts_clone, driver.is_file_based(), ssh.as_ref()).await {
        Some(id) => id,
        None => Uuid::new_v4(),
    };

    let saved = SavedConnection {
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
    };

    save_one(&saved).await.map_err(|e| format!("save: {e}"))?;
    if saved.auth_mode == AuthMode::Password {
        let _ = store_password(saved.id, stored_password.expose_secret(), &label).await;
    }
    if let Some(s) = &ssh {
        match &s.secret_to_store {
            SshSecretToStore::Password(p) => {
                let _ = store_ssh_password(saved.id, p.expose_secret(), &label).await;
            }
            SshSecretToStore::Passphrase(p) => {
                let _ = store_ssh_passphrase(saved.id, p.expose_secret(), &label).await;
            }
            SshSecretToStore::None => {}
        }
    }

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
    Ok((saved, tables))
}

async fn save_one(connection: &SavedConnection) -> Result<(), tablepro_storage::StorageError> {
    let mut existing = tablepro_storage::load_connections().await.unwrap_or_default();
    existing.retain(|c| c.id != connection.id);
    existing.push(connection.clone());
    save_connections(&existing).await
}

async fn find_existing_id(
    driver_id: &str,
    opts: &ConnectOptions,
    file_based: bool,
    ssh: Option<&SshInputs>,
) -> Option<Uuid> {
    let existing = tablepro_storage::load_connections().await.ok()?;
    existing
        .into_iter()
        .find(|c| matches_existing(c, driver_id, opts, file_based, ssh))
        .map(|c| c.id)
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
}
