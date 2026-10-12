//! The connect dialog. It checks what the user typed and hands the
//! window a `ConnectSubmission`; the window connects and saves. The
//! Test button is the one place it connects, and it disconnects again.

mod connect_form;
mod connect_submission;
mod form_errors;
mod form_field;
mod imp;
mod pem_validation;
mod read_only_row;
mod row_problem;
mod sqlite_file_row;
#[cfg(test)]
mod tests;
mod tls_section;

use std::sync::Arc;

use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use secrecy::SecretString;
use tablepro_core::credentials::CredentialInteraction;
use tablepro_core::{
    AuthMode, ConfigError, DatabaseDriver, DriverCapabilities, DriverRegistry, TlsConfig, TransportClass,
    WorkspaceSettings,
};
use tablepro_session::runtime::Tasks;
use tablepro_session::{ConnectError, ConnectRequest, ConnectionMetadata, Connector, PendingSave};
use tablepro_storage::SavedConnection;
use uuid::Uuid;

pub use self::connect_form::ConnectForm;
use self::connect_form::match_saved_connection;
pub use self::connect_submission::ConnectSubmission;
pub use self::form_errors::FormErrors;
pub use self::form_field::FormField;
use self::pem_validation::{PemState, PemValidation};
pub use self::row_problem::show_problem;
use crate::ui::error_text::TlsRemedy;
use crate::ui::ssh_inputs::SshEnvironment;

glib::wrapper! {
    pub struct ConnectDialog(ObjectSubclass<imp::ConnectDialog>)
        @extends adw::Dialog, gtk4::Widget,
        @implements gtk4::Accessible, gtk4::Buildable, gtk4::ConstraintTarget, gtk4::ShortcutManager;
}

/// What the dialog is opened with. It reads no storage itself: the
/// saved list and the remembered driver come from the window.
pub struct ConnectDialogInit {
    pub drivers: Arc<DriverRegistry>,
    /// Used by Test only; Connect hands the request to the window.
    pub connector: Arc<dyn Connector>,
    pub interaction: CredentialInteraction,
    pub tasks: Tasks,
    pub saved_connections: Arc<[SavedConnection]>,
    pub remembered_driver: String,
    pub ssh_environment: SshEnvironment,
    pub prefill: Option<ConnectPrefill>,
}

/// A connection to show again, after a connect from this dialog failed.
#[derive(Debug, Clone)]
pub struct ConnectPrefill {
    pub connection: SavedConnection,
    /// The password typed last time, held in memory only.
    pub password: Option<SecretString>,
}

pub(crate) struct DialogServices {
    connector: Arc<dyn Connector>,
    interaction: CredentialInteraction,
    tasks: Tasks,
    saved_connections: Arc<[SavedConnection]>,
}

#[derive(Clone)]
pub(crate) struct DriverEntry {
    id: String,
    display_name: String,
    driver: Arc<dyn DatabaseDriver>,
}

impl DriverEntry {
    fn capabilities(&self) -> &'static DriverCapabilities {
        self.driver.capabilities()
    }
}

impl ConnectDialog {
    pub fn new(init: ConnectDialogInit) -> Self {
        let dialog: Self = glib::Object::new();
        let imp = dialog.imp();
        let mut drivers: Vec<DriverEntry> = init
            .drivers
            .iter()
            .map(|driver| DriverEntry {
                id: driver.id().to_owned(),
                display_name: driver.display_name().to_owned(),
                driver: driver.clone(),
            })
            .collect();
        drivers.sort_by(|a, b| a.display_name.cmp(&b.display_name));
        let names: Vec<&str> = drivers.iter().map(|entry| entry.display_name.as_str()).collect();
        imp.driver_names.splice(0, imp.driver_names.n_items(), &names);
        let _ = imp.services.set(DialogServices {
            connector: init.connector,
            interaction: init.interaction,
            tasks: init.tasks,
            saved_connections: init.saved_connections,
        });
        imp.ssh_section.apply_environment(&init.ssh_environment);

        let wanted = init
            .prefill
            .as_ref()
            .map_or(init.remembered_driver.as_str(), |prefill| {
                prefill.connection.driver_id.as_str()
            });
        let index = driver_index(&drivers, wanted);
        imp.prefill_id
            .set(init.prefill.as_ref().map(|prefill| prefill.connection.id));
        imp.drivers.replace(drivers);
        imp.updating.set(true);
        imp.driver_row.set_selected(index as u32);
        imp.updating.set(false);

        let form = match (init.prefill, dialog.entry_at(index)) {
            (Some(prefill), Some(entry)) => {
                let mut form = ConnectForm::from_saved(&prefill.connection, entry.capabilities());
                if let Some(password) = prefill.password {
                    form.password = password;
                }
                form
            }
            (None, Some(entry)) => ConnectForm::new(&entry.id, entry.capabilities()),
            (_, None) => ConnectForm::new("", &NO_DRIVER),
        };
        dialog.show_driver(index, &form);
        dialog.connect_handlers();
        dialog.recheck_files();
        dialog.refresh();
        dialog
    }

    pub fn connect_submitted<F: Fn(&Self, ConnectSubmission) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "submitted",
            false,
            glib::closure_local!(move |dialog: &Self, submission: ConnectSubmission| {
                f(dialog, submission);
            }),
        )
    }

    /// Show a row and put the focus in it, for an error that names the
    /// setting that fixes it.
    pub fn reveal_field(&self, field: FormField) {
        let imp = self.imp();
        if field.is_tls() {
            imp.tls_section.reveal(field);
        } else if field.is_ssh() {
            imp.ssh_section.reveal(field);
        } else {
            let row: gtk4::Widget = match field {
                FormField::Port => imp.port_row.get().upcast(),
                FormField::Database => imp.database_row.get().upcast(),
                FormField::File => imp.file_row.get().upcast(),
                FormField::AuthMode => imp.auth_mode_row.get().upcast(),
                FormField::Username => imp.username_row.get().upcast(),
                _ => imp.host_row.get().upcast(),
            };
            row.grab_focus();
        }
    }

    fn services(&self) -> Option<&DialogServices> {
        self.imp().services.get()
    }

    fn entry_at(&self, index: usize) -> Option<DriverEntry> {
        self.imp().drivers.borrow().get(index).cloned()
    }

    fn current_entry(&self) -> Option<DriverEntry> {
        self.entry_at(self.imp().driver_row.selected() as usize)
    }

    fn connect_handlers(&self) {
        let imp = self.imp();
        let weak = self.downgrade();
        imp.driver_row.connect_selected_notify(move |_| {
            if let Some(dialog) = weak.upgrade()
                && !dialog.imp().updating.get()
            {
                dialog.switch_driver();
            }
        });
        let weak = self.downgrade();
        imp.port_row.connect_value_notify(move |_| {
            if let Some(dialog) = weak.upgrade()
                && !dialog.imp().updating.get()
            {
                dialog.imp().port_edited.set(true);
                dialog.refresh();
            }
        });
        let weak = self.downgrade();
        imp.auth_mode_row.connect_selected_notify(move |_| {
            if let Some(dialog) = weak.upgrade()
                && !dialog.imp().updating.get()
            {
                dialog.show_auth_rows();
                dialog.refresh();
            }
        });
        let entries: [&adw::EntryRow; 3] = [&imp.host_row, &imp.database_row, &imp.username_row];
        for row in entries {
            let weak = self.downgrade();
            row.connect_changed(move |_| {
                if let Some(dialog) = weak.upgrade() {
                    dialog.refresh();
                }
            });
        }
        let weak = self.downgrade();
        imp.password_row.connect_changed(move |_| {
            if let Some(dialog) = weak.upgrade() {
                dialog.refresh();
            }
        });
        let weak = self.downgrade();
        imp.file_row.connect_changed(move |_| {
            if let Some(dialog) = weak.upgrade() {
                dialog.refresh();
            }
        });
        let weak = self.downgrade();
        imp.tls_section.connect_changed(move |_| {
            if let Some(dialog) = weak.upgrade() {
                dialog.recheck_files();
                dialog.refresh();
            }
        });
        let weak = self.downgrade();
        imp.ssh_section.connect_changed(move |_| {
            if let Some(dialog) = weak.upgrade() {
                dialog.imp().tls_section.set_route(dialog.route());
                dialog.recheck_files();
                dialog.refresh();
            }
        });
        let weak = self.downgrade();
        imp.connect_button.connect_clicked(move |_| {
            if let Some(dialog) = weak.upgrade() {
                dialog.submit();
            }
        });
        let weak = self.downgrade();
        imp.test_button.connect_clicked(move |_| {
            if let Some(dialog) = weak.upgrade() {
                dialog.toggle_test();
            }
        });
    }

    /// The form as the rows hold it now.
    pub fn form(&self) -> ConnectForm {
        let imp = self.imp();
        let entry = self.current_entry();
        let caps = entry.as_ref().map_or(&NO_DRIVER, DriverEntry::capabilities);
        let auth = imp
            .auth_modes
            .borrow()
            .get(imp.auth_mode_row.selected() as usize)
            .copied()
            .unwrap_or_default();
        ConnectForm {
            driver_id: entry.map(|entry| entry.id).unwrap_or_default(),
            host: imp.host_row.text().to_string(),
            port: imp.port_row.value() as u16,
            port_edited: imp.port_edited.get(),
            database: imp.database_row.text().to_string(),
            auth,
            username: imp.username_row.text().to_string(),
            password: SecretString::from(imp.password_row.text().to_string()),
            remember_password: imp.remember_row.is_active(),
            tls: imp.tls_section.form_state(),
            read_only: imp.read_only_row.is_active(),
            ssh: (!caps.is_file_based()).then(|| imp.ssh_section.form_state()).flatten(),
            file: imp.file_row.endpoint(),
        }
    }

    fn route(&self) -> TransportClass {
        if self.imp().ssh_section.is_enabled() {
            TransportClass::SshForward
        } else {
            TransportClass::DirectTcp
        }
    }

    fn switch_driver(&self) {
        let imp = self.imp();
        let index = imp.driver_row.selected() as usize;
        let Some(entry) = self.entry_at(index) else {
            return;
        };
        let mut form = self.form();
        form.switch_driver(&entry.id, entry.capabilities());
        self.show_driver(index, &form);
        self.recheck_files();
        self.refresh();
    }

    /// Show the rows `index`'s driver uses, filled from `form`.
    fn show_driver(&self, index: usize, form: &ConnectForm) {
        let imp = self.imp();
        let Some(entry) = self.entry_at(index) else {
            return;
        };
        let caps = entry.capabilities();
        let file_based = caps.is_file_based();
        imp.updating.set(true);
        imp.host_row.set_text(&form.host);
        imp.port_row.set_value(f64::from(form.port));
        imp.port_edited.set(form.port_edited);
        imp.database_row.set_text(&form.database);
        imp.username_row.set_text(&form.username);
        if imp.password_row.text() != secrecy::ExposeSecret::expose_secret(&form.password) {
            imp.password_row
                .set_text(secrecy::ExposeSecret::expose_secret(&form.password));
        }
        imp.read_only_row.set_active(form.read_only);
        if form.file.is_some() || imp.file_row.endpoint().is_some() {
            imp.file_row.set_endpoint(form.file.clone());
        }
        if let Some(ssh) = &form.ssh {
            imp.ssh_section.set_state(Some(ssh));
        }

        let modes: Vec<AuthMode> = caps.auth_modes.to_vec();
        let labels: Vec<String> = modes.iter().map(|mode| auth_mode_label(*mode)).collect();
        let labels: Vec<&str> = labels.iter().map(String::as_str).collect();
        imp.auth_mode_names.splice(0, imp.auth_mode_names.n_items(), &labels);
        let selected = modes.iter().position(|mode| *mode == form.auth).unwrap_or(0);
        imp.auth_mode_row.set_selected(selected as u32);
        imp.auth_modes.replace(modes);
        imp.updating.set(false);

        imp.host_row.set_visible(!file_based);
        imp.port_row.set_visible(!file_based);
        imp.database_row.set_visible(!file_based);
        imp.database_row.set_title(&if caps.database_required {
            crate::i18n::gettext("Database")
        } else {
            crate::i18n::gettext("Database (optional)")
        });
        imp.file_row.set_visible(file_based);
        imp.auth_group.set_visible(!file_based && !caps.auth_modes.is_empty());
        imp.ssh_section.set_visible(!file_based);
        let tls = if file_based { None } else { caps.tls.as_ref() };
        imp.tls_section.apply(tls, self.route(), &form.tls);
        imp.read_only_row
            .set_subtitle(&read_only_row::read_only_subtitle(caps.read_only));
        self.show_auth_rows();
        self.set_title(&crate::i18n::gettext_f(
            "Connect to {name}",
            &[("name", &entry.display_name)],
        ));
    }

    fn show_auth_rows(&self) {
        let imp = self.imp();
        imp.auth_mode_row.set_visible(imp.auth_modes.borrow().len() > 1);
        let password = self.form().auth == AuthMode::Password;
        imp.username_row.set_visible(password);
        imp.password_row.set_visible(password);
        imp.remember_row.set_visible(password);
    }

    /// The TLS settings the request would carry, for the file check.
    fn tls_config(&self) -> TlsConfig {
        let Some(entry) = self.current_entry() else {
            return TlsConfig::disabled();
        };
        match entry.capabilities().tls.as_ref() {
            Some(caps) if !entry.capabilities().is_file_based() => {
                self.imp().tls_section.form_state().config(caps, self.route())
            }
            _ => TlsConfig::disabled(),
        }
    }

    /// Read the chosen certificate files on the blocking pool. Connect
    /// waits for the answer, and only the newest check counts.
    fn recheck_files(&self) {
        let imp = self.imp();
        let config = self.tls_config();
        if imp.pem_checked.borrow().as_ref() == Some(&config) {
            return;
        }
        imp.pem_checked.replace(Some(config.clone()));
        if !PemValidation::needs_check(&config) {
            imp.pem.clear();
            return;
        }
        let Some(services) = self.services() else {
            return;
        };
        let ticket = imp.pem.begin();
        let fallback_path = config
            .ca_file
            .clone()
            .or_else(|| {
                config
                    .client_identity
                    .as_ref()
                    .map(|identity| identity.certificate.clone())
            })
            .unwrap_or_default();
        let check = services
            .tasks
            .spawn_blocking_task(move || tablepro_net::tls::check_pem_files(&config));
        let weak = self.downgrade();
        glib::spawn_future_local(async move {
            let result = check.await.unwrap_or_else(|failure| {
                Err(ConfigError::CaFile {
                    path: fallback_path,
                    problem: tablepro_core::CertificateFileProblem::Unreadable {
                        detail: failure.to_string(),
                    },
                })
            });
            if let Some(dialog) = weak.upgrade()
                && dialog.imp().pem.finish(ticket, result)
            {
                dialog.refresh();
            }
        });
    }

    /// Paint the rows, and allow Connect only on a form that would work.
    fn refresh(&self) {
        let imp = self.imp();
        if imp.updating.get() {
            return;
        }
        let Some(entry) = self.current_entry() else {
            imp.connect_button.set_sensitive(false);
            imp.test_button.set_sensitive(false);
            return;
        };
        let errors = self.form().validate(entry.capabilities()).err().unwrap_or_default();
        let shown = |field| errors.shown_on(field).map(|problem| problem.message.as_str());
        show_problem(&*imp.host_row, shown(FormField::Host));
        show_problem(&*imp.port_row, shown(FormField::Port));
        show_problem(&*imp.database_row, shown(FormField::Database));
        show_problem(&*imp.file_row, shown(FormField::File));
        show_problem(&*imp.auth_mode_row, shown(FormField::AuthMode));
        show_problem(&*imp.username_row, shown(FormField::Username));
        let pem = imp.pem.state();
        let file_problem = match &pem {
            PemState::Invalid(error) => Some(error),
            PemState::Valid | PemState::Pending => None,
        };
        imp.tls_section.show_problems(&errors, file_problem);
        imp.ssh_section.show_problems(&errors);

        let blocker = match (&pem, errors.message()) {
            (_, Some(message)) => Some(message.to_owned()),
            (PemState::Invalid(error), None) => Some(crate::ui::error_text::config_message(error)),
            (PemState::Pending, None) => Some(crate::i18n::gettext("Checking the certificate files…")),
            (PemState::Valid, None) => None,
        };
        imp.connect_button.set_sensitive(blocker.is_none());
        imp.connect_button.set_tooltip_text(blocker.as_deref());
        imp.test_button.set_sensitive(blocker.is_none() || imp.testing.get());
    }

    /// Everything a Connect or a Test sends, or the reason there is
    /// nothing to send yet.
    fn build_submission(&self) -> Result<ConnectSubmission, String> {
        let entry = self
            .current_entry()
            .ok_or_else(|| crate::i18n::gettext("No driver selected"))?;
        let caps = entry.capabilities();
        let form = self.form();
        let valid = form
            .validate(caps)
            .map_err(|errors| errors.message().unwrap_or_default().to_owned())?;
        match self.imp().pem.state() {
            PemState::Valid => {}
            PemState::Pending => return Err(crate::i18n::gettext("Checking the certificate files…")),
            PemState::Invalid(error) => return Err(crate::ui::error_text::config_message(&error)),
        }
        let saved_connections = self
            .services()
            .map(|services| services.saved_connections.clone())
            .unwrap_or_else(|| Arc::from(Vec::new()));
        let candidate = form.saved_connection(caps, &valid, Uuid::new_v4(), None);
        let reopened = self.imp().prefill_id.get();
        let existing = saved_connections
            .iter()
            .find(|saved| Some(saved.id) == reopened && saved.driver_id == entry.id)
            .or_else(|| {
                match_saved_connection(&saved_connections, &candidate, caps.is_file_based())
                    .and_then(|id| saved_connections.iter().find(|saved| saved.id == id))
            });
        let id = existing.map_or(candidate.id, |saved| saved.id);
        let connection = form.saved_connection(caps, &valid, id, existing);
        let request = ConnectRequest {
            metadata: ConnectionMetadata {
                id,
                name: connection.name.clone(),
                driver_id: entry.id.clone(),
            },
            driver: entry.driver.clone(),
            target: valid.target.clone(),
            workspace_settings: WorkspaceSettings::workspace(form.read_only),
        };
        let pending_save = PendingSave {
            secrets: form.secrets_to_store(&valid, &connection),
            forget: form.secrets_to_forget(&valid),
            connection,
            is_new: existing.is_none(),
        };
        Ok(ConnectSubmission { request, pending_save })
    }

    /// Hand the window what to connect to, and close. The window shows
    /// the connect and saves the entry once it works.
    fn submit(&self) {
        match self.build_submission() {
            Ok(submission) => {
                self.stop_test();
                self.emit_by_name::<()>("submitted", &[&submission]);
                self.close();
            }
            Err(message) => self.show_toast(&message, None),
        }
    }

    fn toggle_test(&self) {
        if self.imp().testing.get() {
            self.stop_test();
            return;
        }
        let submission = match self.build_submission() {
            Ok(submission) => submission,
            Err(message) => {
                self.show_toast(&message, None);
                return;
            }
        };
        let Some(services) = self.services() else {
            return;
        };
        let imp = self.imp();
        let ticket = imp.tests.begin();
        let generation = ticket.generation();
        imp.testing.set(true);
        imp.test_button.set_label(&crate::i18n::gettext("Stop"));
        imp.test_button
            .set_tooltip_text(Some(&crate::i18n::gettext("Stop the test")));
        self.refresh();

        // A test entry is never saved, so it gets an id of its own.
        let mut request = submission.request;
        request.metadata.id = Uuid::new_v4();
        let connector = services.connector.clone();
        let interaction = services.interaction.clone();
        let cancel = ticket.cancel().clone();
        // Closing happens in the same task, so a connect that finishes
        // after the user stopped waiting is still closed.
        let work = async move {
            let pending = connector.establish(request, interaction, cancel).await?;
            let report = pending.discard().await;
            tracing::debug!(?report, "closed the test connection");
            Ok::<(), ConnectError>(())
        };
        let weak = self.downgrade();
        crate::runtime::spawn_and_deliver(&services.tasks, work, move |outcome| {
            let Some(dialog) = weak.upgrade() else {
                return;
            };
            let imp = dialog.imp();
            if !imp.testing.get() || !imp.tests.accepts(generation) {
                return;
            }
            dialog.stop_test();
            match outcome {
                Ok(Ok(())) => dialog.show_toast(&crate::i18n::gettext("Connection works"), None),
                Ok(Err(ConnectError::Cancelled)) => {}
                Ok(Err(error)) => dialog.show_toast(
                    &crate::ui::error_text::connect_error_message(&error),
                    crate::ui::error_text::connect_remedy(&error),
                ),
                Err(failure) => dialog.show_toast(&crate::ui::error_text::task_failure_message(&failure), None),
            }
        });
    }

    fn stop_test(&self) {
        let imp = self.imp();
        imp.tests.cancel();
        if !imp.testing.replace(false) {
            return;
        }
        imp.test_button.set_label(&crate::i18n::gettext("Test"));
        imp.test_button.set_tooltip_text(Some(&crate::i18n::gettext(
            "Connect once to check the settings, then disconnect",
        )));
        self.refresh();
    }

    fn show_toast(&self, message: &str, remedy: Option<TlsRemedy>) {
        let toast = adw::Toast::new(message);
        if let Some(remedy) = remedy {
            toast.set_button_label(Some(&remedy.label()));
            let weak = self.downgrade();
            toast.connect_button_clicked(move |_| {
                if let Some(dialog) = weak.upgrade() {
                    dialog.reveal_field(remedy_field(remedy));
                }
            });
        }
        #[cfg(test)]
        self.imp().toasts.borrow_mut().push(message.to_owned());
        self.imp().toast_overlay.add_toast(toast);
    }
}

/// The row that fixes a TLS failure.
pub fn remedy_field(remedy: TlsRemedy) -> FormField {
    match remedy {
        TlsRemedy::ChooseCaCertificate => FormField::CaFile,
        TlsRemedy::SetServerName => FormField::ServerName,
    }
}

/// Capabilities for a registry with no drivers at all, so the form
/// still has something to read.
static NO_DRIVER: DriverCapabilities = DriverCapabilities {
    endpoint: tablepro_core::EndpointKind::File,
    auth_modes: &[],
    tls: None,
    read_only: tablepro_core::ReadOnlyEnforcement::LoginPrivileges,
    dml_writes: tablepro_core::WriteAtomicity::Transactional,
    ddl_writes: tablepro_core::WriteAtomicity::Transactional,
    script_execution: tablepro_core::ScriptExecution::SingleStatement,
    commit_resolution: tablepro_core::CommitResolutionSupport::Unavailable,
    row_count_estimate: tablepro_core::EstimateQuality::Unavailable,
    object_kinds: &[],
    database_required: false,
};

fn auth_mode_label(mode: AuthMode) -> String {
    match mode {
        AuthMode::Password => crate::i18n::gettext("Password"),
        AuthMode::Kerberos => crate::i18n::gettext("Windows (Kerberos)"),
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
