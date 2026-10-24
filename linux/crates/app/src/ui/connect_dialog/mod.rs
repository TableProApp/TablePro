//! The connect dialog. It checks what the user typed and hands the
//! window a `ConnectSubmission`; the window connects and saves. The
//! Test button is the one place it connects, and it disconnects again.

mod appearance;
mod connect_dialog_mode;
mod connect_form;
mod connect_submission;
mod database_file_row;
mod form_errors;
mod form_field;
mod imp;
mod pem_validation;
mod row_problem;
#[cfg(test)]
mod tests;
mod tls_section;

use std::rc::Rc;
use std::sync::Arc;

use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use secrecy::SecretString;
use tablepro_core::credentials::CredentialInteraction;
use tablepro_core::{
    AiPolicy, AuthMode, ConfigError, DatabaseDriver, DriverCapabilities, DriverRegistry, ExternalAccess, NetworkOption,
    NetworkOptions, SafeModeLevel, TlsConfig, TransportClass, WorkspaceSettings,
};
use tablepro_session::runtime::{ProcessHold, Tasks};
use tablepro_session::{ConnectError, ConnectRequest, ConnectionMetadata, Connector, CredentialSource, PendingSave};
use tablepro_storage::{ConnectionTag, CredentialDemand, SavedConnection};
use uuid::Uuid;

pub use self::connect_dialog_mode::ConnectDialogMode;
use self::connect_form::ValidatedForm;
pub use self::connect_form::{ConnectForm, driver_shows_server_name};
pub use self::connect_submission::ConnectSubmission;
pub(crate) use self::database_file_row::{DatabaseFiles, database_file_dialog};
pub use self::form_errors::FormErrors;
pub use self::form_field::FormField;
use self::pem_validation::{PemState, PemValidation};
pub use self::row_problem::show_problem;
use crate::services::saved_connection_editor::SavedConnectionEditor;
use crate::services::secret_changes::SecretChanges;
use crate::services::session_context::CredentialSourceFactory;
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
    /// The tags the Appearance group offers.
    pub tags: Arc<[ConnectionTag]>,
    pub remembered_driver: String,
    /// Whether a provider answers the AI assistant, which is when its
    /// policy row is shown.
    pub ai_assistant: bool,
    pub ssh_environment: SshEnvironment,
    /// What a Create opens on after a connect from it failed.
    pub prefill: Option<ConnectPrefill>,
    pub mode: ConnectDialogMode,
    /// Writes an Edit's Save, secrets first.
    pub editor: SavedConnectionEditor,
    /// Where an Edit's Test reads the secrets it keeps.
    pub credentials: Rc<dyn CredentialSourceFactory>,
    /// Keeps the process alive while an Edit's Save is written.
    pub hold: Rc<dyn ProcessHold>,
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
    editor: SavedConnectionEditor,
    credentials: Rc<dyn CredentialSourceFactory>,
    hold: Rc<dyn ProcessHold>,
}

/// A form that passed every check, with the driver it is for.
struct CheckedForm {
    entry: DriverEntry,
    form: ConnectForm,
    valid: ValidatedForm,
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
        let levels: Vec<String> = SafeModeLevel::ALL
            .into_iter()
            .map(crate::ui::safe_mode::label)
            .collect();
        let levels: Vec<&str> = levels.iter().map(String::as_str).collect();
        imp.safe_mode_names.splice(0, imp.safe_mode_names.n_items(), &levels);
        crate::ui::combo_value::show_whole_value(&imp.safe_mode_row);
        let access: Vec<String> = ExternalAccess::ALL
            .into_iter()
            .map(crate::ui::external_access::label)
            .collect();
        let access: Vec<&str> = access.iter().map(String::as_str).collect();
        imp.external_access_names
            .splice(0, imp.external_access_names.n_items(), &access);
        crate::ui::combo_value::show_whole_value(&imp.external_access_row);
        let policies: Vec<String> = AiPolicy::ALL.into_iter().map(crate::ui::ai_policy::label).collect();
        let policies: Vec<&str> = policies.iter().map(String::as_str).collect();
        imp.ai_policy_names.splice(0, imp.ai_policy_names.n_items(), &policies);
        crate::ui::combo_value::show_whole_value(&imp.ai_policy_row);
        imp.ai_policy_row.set_visible(init.ai_assistant);
        imp.file_row.set_tasks(init.tasks.clone());
        let _ = imp.services.set(DialogServices {
            connector: init.connector,
            interaction: init.interaction,
            tasks: init.tasks,
            saved_connections: init.saved_connections,
            editor: init.editor,
            credentials: init.credentials,
            hold: init.hold,
        });
        imp.ssh_section.apply_environment(&init.ssh_environment);
        let tags = init.tags;

        // An Edit opens on what is saved; a Create reopened after a
        // failed connect opens on what was typed.
        let prefill = match &init.mode {
            ConnectDialogMode::Edit(saved) => Some(ConnectPrefill {
                connection: (**saved).clone(),
                password: None,
            }),
            ConnectDialogMode::Create => init.prefill,
        };
        let wanted = prefill.as_ref().map_or(init.remembered_driver.as_str(), |prefill| {
            prefill.connection.driver_id.as_str()
        });
        let index = driver_index(&drivers, wanted);
        imp.prefill_id
            .set(prefill.as_ref().map(|prefill| prefill.connection.id));
        imp.drivers.replace(drivers);
        imp.updating.set(true);
        imp.driver_row.set_selected(index as u32);
        imp.updating.set(false);
        dialog.show_mode(&init.mode);
        imp.mode.replace(init.mode);

        let form = match (prefill, dialog.entry_at(index)) {
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
        dialog.show_appearance(&tags, form.icon, &form.tags);
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

    /// An Edit's Save wrote the connection with id `id`.
    pub fn connect_saved<F: Fn(&Self, Uuid) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "saved",
            false,
            glib::closure_local!(move |dialog: &Self, id: String| match Uuid::parse_str(&id) {
                Ok(id) => f(dialog, id),
                Err(error) => tracing::warn!(%error, "the connect dialog saved an id it cannot read"),
            }),
        )
    }

    /// The saved connection an Edit changes, as it was opened.
    pub fn editing(&self) -> Option<SavedConnection> {
        self.imp().mode.borrow().editing().cloned()
    }

    /// An Edit saves where a Create connects, and says the password rows
    /// may stay empty.
    fn show_mode(&self, mode: &ConnectDialogMode) {
        let imp = self.imp();
        if mode.editing().is_none() {
            return;
        }
        imp.connect_button.set_label(&crate::i18n::gettext("Save"));
        imp.auth_group.set_description(Some(&crate::i18n::gettext(
            "Leave password fields empty to keep the saved passwords.",
        )));
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
                FormField::DnsSeedList => imp.seed_list_row.get().upcast(),
                FormField::AuthDatabase => imp.auth_database_row.get().upcast(),
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

    fn connect_seed_list_row(&self) {
        let weak = self.downgrade();
        self.imp().seed_list_row.connect_active_notify(move |_| {
            if let Some(dialog) = weak.upgrade()
                && !dialog.imp().updating.get()
            {
                dialog.show_seed_list_rows();
                dialog.refresh();
            }
        });
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
        imp.safe_mode_row.connect_selected_notify(move |_| {
            if let Some(dialog) = weak.upgrade() {
                dialog.show_safe_mode_subtitle();
            }
        });
        let weak = self.downgrade();
        imp.external_access_row.connect_selected_notify(move |_| {
            if let Some(dialog) = weak.upgrade() {
                dialog.show_external_access_subtitle();
            }
        });
        let weak = self.downgrade();
        imp.ai_policy_row.connect_selected_notify(move |_| {
            if let Some(dialog) = weak.upgrade() {
                dialog.show_ai_policy_subtitle();
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
        self.connect_seed_list_row();
        let entries: [&adw::EntryRow; 5] = [
            &imp.name_row,
            &imp.host_row,
            &imp.database_row,
            &imp.username_row,
            &imp.auth_database_row,
        ];
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
            name: imp.name_row.text().to_string(),
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
            safe_mode: SafeModeLevel::ALL
                .get(imp.safe_mode_row.selected() as usize)
                .copied()
                .unwrap_or_default(),
            external_access: ExternalAccess::ALL
                .get(imp.external_access_row.selected() as usize)
                .copied()
                .unwrap_or_default(),
            ai_policy: AiPolicy::ALL
                .get(imp.ai_policy_row.selected() as usize)
                .copied()
                .unwrap_or_default(),
            ssh: (!caps.is_file_based()).then(|| imp.ssh_section.form_state()).flatten(),
            file: imp.file_row.endpoint(),
            tags: self.picked_tags(),
            icon: self.picked_icon(),
            options: NetworkOptions {
                dns_seed_list: imp.seed_list_row.is_active(),
                auth_database: Some(imp.auth_database_row.text().to_string()).filter(|name| !name.trim().is_empty()),
            },
        }
    }

    fn shows_server_name(&self) -> bool {
        let entry = self.current_entry();
        driver_shows_server_name(entry.as_ref().map(DriverEntry::capabilities), self.route())
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
        if imp.name_row.text() != form.name {
            imp.name_row.set_text(&form.name);
        }
        imp.host_row.set_text(&form.host);
        imp.port_row.set_value(f64::from(form.port));
        imp.port_edited.set(form.port_edited);
        imp.database_row.set_text(&form.database);
        imp.username_row.set_text(&form.username);
        imp.seed_list_row.set_active(form.options.dns_seed_list);
        imp.auth_database_row
            .set_text(form.options.auth_database.as_deref().unwrap_or_default());
        if imp.password_row.text() != secrecy::ExposeSecret::expose_secret(&form.password) {
            imp.password_row
                .set_text(secrecy::ExposeSecret::expose_secret(&form.password));
        }
        let level = SafeModeLevel::ALL
            .iter()
            .position(|level| *level == form.safe_mode)
            .unwrap_or_default();
        imp.safe_mode_row.set_selected(level as u32);
        let access = ExternalAccess::ALL
            .iter()
            .position(|access| *access == form.external_access)
            .unwrap_or_default();
        imp.external_access_row.set_selected(access as u32);
        let policy = AiPolicy::ALL
            .iter()
            .position(|policy| *policy == form.ai_policy)
            .unwrap_or_default();
        imp.ai_policy_row.set_selected(policy as u32);
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
        imp.database_row
            .set_title(&match (caps.is_key_value(), caps.database_required) {
                (true, _) => crate::i18n::gettext("Database Number (optional)"),
                (false, true) => crate::i18n::gettext("Database"),
                (false, false) => crate::i18n::gettext("Database (optional)"),
            });
        imp.username_row.set_title(&if caps.username_required {
            crate::i18n::gettext("Username")
        } else {
            crate::i18n::gettext("Username (optional)")
        });
        imp.seed_list_row
            .set_visible(!file_based && caps.offers(NetworkOption::DnsSeedList));
        imp.file_row.set_visible(file_based);
        imp.file_row.set_files(DatabaseFiles::of(entry.driver.as_ref()));
        imp.auth_group.set_visible(!file_based && !caps.auth_modes.is_empty());
        imp.ssh_section.set_visible(!file_based);
        let tls = if file_based { None } else { caps.tls.as_ref() };
        imp.tls_section.apply(tls, self.route(), &form.tls);
        self.show_safe_mode_subtitle();
        self.show_external_access_subtitle();
        self.show_ai_policy_subtitle();
        self.show_auth_rows();
        self.show_seed_list_rows();
        self.set_title(&if imp.mode.borrow().editing().is_some() {
            crate::i18n::gettext("Edit Connection")
        } else {
            crate::i18n::gettext_f("Connect to {name}", &[("name", &entry.display_name)])
        });
    }

    fn show_safe_mode_subtitle(&self) {
        let entry = self.current_entry();
        let caps = entry.as_ref().map_or(&NO_DRIVER, DriverEntry::capabilities);
        let engine = entry.as_ref().map_or_else(
            || crate::i18n::gettext("this database"),
            |entry| entry.display_name.clone(),
        );
        self.imp()
            .safe_mode_row
            .set_subtitle(&crate::ui::safe_mode::subtitle(self.form().safe_mode, caps, &engine));
    }

    fn show_external_access_subtitle(&self) {
        self.imp()
            .external_access_row
            .set_subtitle(&crate::ui::external_access::subtitle(self.form().external_access));
    }

    fn show_ai_policy_subtitle(&self) {
        self.imp()
            .ai_policy_row
            .set_subtitle(&crate::ui::ai_policy::subtitle(self.form().ai_policy));
    }

    fn show_auth_rows(&self) {
        let imp = self.imp();
        imp.auth_mode_row.set_visible(imp.auth_modes.borrow().len() > 1);
        let password = self.form().auth == AuthMode::Password;
        imp.username_row.set_visible(password);
        imp.password_row.set_visible(password);
        imp.remember_row.set_visible(password);
        let entry = self.current_entry();
        let caps = entry.as_ref().map_or(&NO_DRIVER, DriverEntry::capabilities);
        imp.auth_database_row
            .set_visible(password && caps.offers(NetworkOption::AuthDatabase));
    }

    /// A seed list's SRV records give the ports, so the port row goes
    /// while the list is on.
    fn show_seed_list_rows(&self) {
        let imp = self.imp();
        let entry = self.current_entry();
        let caps = entry.as_ref().map_or(&NO_DRIVER, DriverEntry::capabilities);
        let seed_list = imp.seed_list_row.is_visible() && imp.seed_list_row.is_active();
        imp.port_row.set_visible(!caps.is_file_based() && !seed_list);
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
                tracing::warn!(%failure, "the certificate check did not finish");
                Err(ConfigError::CaFile {
                    path: fallback_path,
                    problem: tablepro_core::CertificateFileProblem::Unreadable {
                        kind: std::io::ErrorKind::Other,
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
        show_problem(&*imp.seed_list_row, shown(FormField::DnsSeedList));
        show_problem(&*imp.auth_database_row, shown(FormField::AuthDatabase));
        let pem = imp.pem.state();
        let file_problem = match &pem {
            PemState::Invalid(error) => Some(error),
            PemState::Valid | PemState::Pending => None,
        };
        imp.tls_section.show_problems(&errors, file_problem);
        imp.ssh_section.show_problems(&errors);

        let blocker = match (&pem, errors.message()) {
            _ if imp.creating_tag.get() => Some(creating_tag_text()),
            (_, Some(message)) => Some(message.to_owned()),
            (PemState::Invalid(error), None) => Some(crate::ui::error_text::config_message(error)),
            (PemState::Pending, None) => Some(crate::i18n::gettext("Checking the certificate files…")),
            (PemState::Valid, None) => None,
        };
        imp.connect_button.set_sensitive(blocker.is_none() && !imp.saving.get());
        imp.connect_button.set_tooltip_text(blocker.as_deref());
        imp.test_button.set_sensitive(blocker.is_none() || imp.testing.get());
    }

    /// The form, checked, or the reason it cannot be used yet.
    fn checked_form(&self) -> Result<CheckedForm, String> {
        // A tag made from the dialog is ticked once it exists; a save
        // before then would leave it off.
        if self.imp().creating_tag.get() {
            return Err(creating_tag_text());
        }
        let entry = self
            .current_entry()
            .ok_or_else(|| crate::i18n::gettext("No driver selected"))?;
        let form = self.form();
        let valid = form
            .validate(entry.capabilities())
            .map_err(|errors| errors.message().unwrap_or_default().to_owned())?;
        match self.imp().pem.state() {
            PemState::Valid => {}
            PemState::Pending => return Err(crate::i18n::gettext("Checking the certificate files…")),
            PemState::Invalid(error) => return Err(crate::ui::error_text::config_message(&error)),
        }
        Ok(CheckedForm { entry, form, valid })
    }

    /// Everything a Connect or a Test sends, or the reason there is
    /// nothing to send yet.
    fn build_submission(&self) -> Result<ConnectSubmission, String> {
        let CheckedForm { entry, form, valid } = self.checked_form()?;
        let caps = entry.capabilities();
        let saved_connections = self
            .services()
            .map(|services| services.saved_connections.clone())
            .unwrap_or_else(|| Arc::from(Vec::new()));
        // Only the entry the dialog was reopened on is written over. One
        // that merely reaches the same database may differ in its name
        // or its read-only switch, and New Connection must not undo them.
        let reopened = self.imp().prefill_id.get();
        let existing = saved_connections
            .iter()
            .find(|saved| Some(saved.id) == reopened && saved.driver_id == entry.id);
        let id = existing.map_or_else(Uuid::new_v4, |saved| saved.id);
        let connection = form.submitted_connection(caps, &valid, id, existing);
        let request = connect_request(&entry, &form, &valid, &connection);
        let pending_save = PendingSave {
            secrets: form.secrets_to_store(&valid, &connection),
            forget: form.secrets_to_forget(&valid),
            connection,
            is_new: existing.is_none(),
        };
        Ok(ConnectSubmission { request, pending_save })
    }

    /// The saved connection an Edit's form describes, under its own id,
    /// and what saving it does to each secret.
    fn edited(&self, original: &SavedConnection, checked: &CheckedForm) -> (SavedConnection, SecretChanges) {
        let CheckedForm { entry, form, valid } = checked;
        let original_caps = self
            .imp()
            .drivers
            .borrow()
            .iter()
            .find(|candidate| candidate.id == original.driver_id)
            .map_or(&NO_DRIVER, DriverEntry::capabilities);
        let changes = form.secret_changes(original, original_caps, valid);
        let mut connection = form.saved_connection(entry.capabilities(), valid, original.id, Some(original));
        changes.settle_passphrase(&mut connection, original);
        (connection, changes)
    }

    /// Hand the window what to connect to, and close. The window shows
    /// the connect and saves the entry once it works. An Edit saves
    /// instead, and closes once the save lands.
    fn submit(&self) {
        if let Some(original) = self.editing() {
            self.save_edit(&original);
            return;
        }
        match self.build_submission() {
            Ok(submission) => {
                self.stop_test();
                self.emit_by_name::<()>("submitted", &[&submission]);
                self.close();
            }
            Err(message) => self.show_toast(&message, None),
        }
    }

    /// Write an Edit, secrets first, and close once it lands. A failure
    /// keeps the dialog open with what the user typed, to try again.
    fn save_edit(&self, original: &SavedConnection) {
        let imp = self.imp();
        if imp.saving.get() {
            return;
        }
        let checked = match self.checked_form() {
            Ok(checked) => checked,
            Err(message) => {
                self.show_toast(&message, None);
                return;
            }
        };
        let Some(services) = self.services() else {
            return;
        };
        let (connection, changes) = self.edited(original, &checked);
        self.stop_test();
        imp.saving.set(true);
        self.refresh();
        let editor = services.editor.clone();
        let hold = services.hold.acquire();
        let weak = self.downgrade();
        crate::runtime::spawn_and_deliver(
            &services.tasks,
            async move { editor.update(connection, changes).await },
            move |outcome| {
                drop(hold);
                let Some(dialog) = weak.upgrade() else {
                    return;
                };
                dialog.imp().saving.set(false);
                dialog.refresh();
                match outcome {
                    Ok(Ok(saved)) => {
                        dialog.emit_by_name::<()>("saved", &[&saved.id.to_string()]);
                        if !dialog.imp().has_closed.get() {
                            dialog.close();
                        }
                    }
                    Ok(Err(error)) => {
                        tracing::warn!(%error, "could not save the edited connection");
                        dialog.show_toast(&crate::ui::error_text::saved_connection_error_message(&error), None);
                    }
                    Err(failure) => dialog.show_toast(&crate::ui::error_text::task_failure_message(&failure), None),
                }
            },
        );
    }

    /// What a Test connects with: the request, and for an Edit, where
    /// the secrets its empty rows keep are read from.
    fn test_request(&self) -> Result<(ConnectRequest, Option<Arc<dyn CredentialSource>>), String> {
        let Some(original) = self.editing() else {
            return self.build_submission().map(|submission| (submission.request, None));
        };
        let checked = self.checked_form()?;
        let (connection, _) = self.edited(&original, &checked);
        let request = connect_request(&checked.entry, &checked.form, &checked.valid, &connection);
        let typed = checked.form.typed_secrets(&checked.valid);
        let kept = self
            .services()
            .map(|services| services.credentials.for_connection(Some(&connection), &typed));
        Ok((request, kept))
    }

    fn toggle_test(&self) {
        if self.imp().testing.get() {
            self.stop_test();
            return;
        }
        let (request, kept) = match self.test_request() {
            Ok(test) => test,
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
            .set_tooltip_text(Some(&crate::i18n::gettext("Stop the Test")));
        self.refresh();

        // A test entry is never saved, so it gets an id of its own.
        let mut request = request;
        request.metadata.id = Uuid::new_v4();
        let connector = services.connector.clone();
        let interaction = services.interaction.clone();
        let cancel = ticket.cancel().clone();
        // Closing happens in the same task, so a connect that finishes
        // after the user stopped waiting is still closed.
        let work = async move {
            let request = match kept {
                Some(source) => {
                    let refreshing = source.refresh(request, interaction.clone(), CredentialDemand::default());
                    cancel
                        .run_until_cancelled(refreshing)
                        .await
                        .ok_or(ConnectError::Cancelled)??
                        .request
                }
                None => request,
            };
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
                    crate::ui::error_text::connect_remedy(&error, dialog.shows_server_name()),
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
        imp.test_button
            .set_tooltip_text(Some(&crate::i18n::gettext("Connect Once to Check the Settings")));
        self.refresh();
    }

    fn show_toast(&self, message: &str, remedy: Option<TlsRemedy>) {
        let toast = crate::ui::plain_toast(message);
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

/// What a connect to `connection`, as the form describes it, sends.
fn connect_request(
    entry: &DriverEntry,
    form: &ConnectForm,
    valid: &ValidatedForm,
    connection: &SavedConnection,
) -> ConnectRequest {
    ConnectRequest {
        metadata: ConnectionMetadata {
            id: connection.id,
            name: connection.name.clone(),
            driver_id: entry.id.clone(),
        },
        driver: entry.driver.clone(),
        target: valid.target.clone(),
        workspace_settings: WorkspaceSettings::workspace(form.safe_mode.blocks_writes()),
        safe_mode: form.safe_mode,
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
    data_model: tablepro_core::DataModel::Relational,
    endpoint: tablepro_core::EndpointKind::File(tablepro_core::FileFormat {
        signature: tablepro_core::FileSignature { offset: 0, bytes: &[] },
        suffixes: &[],
        mime_types: &[],
        empty_file_is_database: false,
    }),
    auth_modes: &[],
    username_required: true,
    tls: None,
    read_only: tablepro_core::ReadOnlyEnforcement::LoginPrivileges,
    dml_writes: tablepro_core::WriteAtomicity::Transactional,
    ddl_writes: tablepro_core::WriteAtomicity::Transactional,
    script_execution: tablepro_core::ScriptExecution::SingleStatement,
    commit_resolution: tablepro_core::CommitResolutionSupport::Unavailable,
    row_count_estimate: tablepro_core::EstimateQuality::Unavailable,
    object_kinds: &[],
    database_required: false,
    network_options: &[],
    statement_stop: tablepro_core::StatementStop::Server,
};

fn creating_tag_text() -> String {
    crate::i18n::gettext("Creating the tag…")
}

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
