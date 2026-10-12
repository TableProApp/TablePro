use std::cell::{Cell, OnceCell, RefCell};
use std::sync::OnceLock;

use glib::subclass::Signal;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::subclass::prelude::*;
use tablepro_core::{AuthMode, TlsConfig};
use tablepro_session::ConnectAttempts;

use super::connect_submission::ConnectSubmission;
use super::pem_validation::PemValidation;
use super::sqlite_file_row::SqliteFileRow;
use super::tls_section::TlsSection;
use super::{DialogServices, DriverEntry};
use crate::ui::ssh_section::SshSection;

#[derive(Default, gtk4::CompositeTemplate)]
#[template(resource = "/app/tablepro/TablePro/ui/connect-dialog.ui")]
pub struct ConnectDialog {
    #[template_child]
    pub test_button: TemplateChild<gtk4::Button>,
    #[template_child]
    pub connect_button: TemplateChild<gtk4::Button>,
    #[template_child]
    pub toast_overlay: TemplateChild<adw::ToastOverlay>,
    #[template_child]
    pub driver_row: TemplateChild<adw::ComboRow>,
    #[template_child]
    pub driver_names: TemplateChild<gtk4::StringList>,
    #[template_child]
    pub host_row: TemplateChild<adw::EntryRow>,
    #[template_child]
    pub port_row: TemplateChild<adw::SpinRow>,
    #[template_child]
    pub database_row: TemplateChild<adw::EntryRow>,
    #[template_child]
    pub file_row: TemplateChild<SqliteFileRow>,
    #[template_child]
    pub auth_group: TemplateChild<adw::PreferencesGroup>,
    #[template_child]
    pub auth_mode_row: TemplateChild<adw::ComboRow>,
    #[template_child]
    pub auth_mode_names: TemplateChild<gtk4::StringList>,
    #[template_child]
    pub username_row: TemplateChild<adw::EntryRow>,
    #[template_child]
    pub password_row: TemplateChild<adw::PasswordEntryRow>,
    #[template_child]
    pub remember_row: TemplateChild<adw::SwitchRow>,
    #[template_child]
    pub tls_section: TemplateChild<TlsSection>,
    #[template_child]
    pub ssh_section: TemplateChild<SshSection>,
    #[template_child]
    pub read_only_row: TemplateChild<adw::SwitchRow>,

    pub(super) services: OnceCell<DialogServices>,
    pub(super) drivers: RefCell<Vec<DriverEntry>>,
    pub auth_modes: RefCell<Vec<AuthMode>>,
    /// Set once the user types a port; see `ConnectForm::port_edited`.
    pub port_edited: Cell<bool>,
    /// Set while the code writes rows, so its writes are not taken for
    /// the user's.
    pub updating: Cell<bool>,
    /// The entry the dialog was reopened on, which a submission updates
    /// even when the user changed the host it was found by.
    pub prefill_id: Cell<Option<uuid::Uuid>>,
    pub pem: PemValidation,
    /// The TLS settings the last file check read, so a keystroke in an
    /// unrelated row does not read the files again.
    pub pem_checked: RefCell<Option<TlsConfig>>,
    /// The Test run in flight. Closing the dialog or pressing Stop
    /// cancels it, and its late answer is dropped.
    pub tests: ConnectAttempts,
    pub testing: Cell<bool>,
    #[cfg(test)]
    pub toasts: RefCell<Vec<String>>,
}

#[glib::object_subclass]
impl ObjectSubclass for ConnectDialog {
    const NAME: &'static str = "TableProConnectDialog";
    type Type = super::ConnectDialog;
    type ParentType = adw::Dialog;

    fn class_init(klass: &mut Self::Class) {
        SqliteFileRow::ensure_type();
        TlsSection::ensure_type();
        SshSection::ensure_type();
        klass.bind_template();
    }

    fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
        object.init_template();
    }
}

impl ObjectImpl for ConnectDialog {
    fn signals() -> &'static [Signal] {
        static SIGNALS: OnceLock<Vec<Signal>> = OnceLock::new();
        SIGNALS.get_or_init(|| {
            vec![
                Signal::builder("submitted")
                    .param_types([ConnectSubmission::static_type()])
                    .build(),
            ]
        })
    }
}

impl WidgetImpl for ConnectDialog {}

impl AdwDialogImpl for ConnectDialog {
    fn closed(&self) {
        self.tests.cancel();
        self.testing.set(false);
        self.parent_closed();
    }
}
