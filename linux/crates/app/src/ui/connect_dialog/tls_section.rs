use std::path::PathBuf;

use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::{ConfigError, TlsCapabilities, TlsConfig, TlsMode, TransportClass};

use super::connect_form::{TlsFormState, default_tls_mode, shows_server_name, tls_field};
use super::form_errors::FormErrors;
use super::form_field::FormField;
use super::row_problem::show_problem;

/// Which certificate file a row holds.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CertificateSlot {
    Ca,
    Certificate,
    Key,
}

mod imp {
    use std::cell::{Cell, RefCell};
    use std::sync::OnceLock;

    use glib::subclass::Signal;
    use libadwaita::subclass::prelude::*;

    use super::*;

    #[derive(Default, gtk4::CompositeTemplate)]
    #[template(resource = "/app/tablepro/TablePro/ui/tls-section.ui")]
    pub struct TlsSection {
        #[template_child]
        pub encryption_row: TemplateChild<adw::ComboRow>,
        #[template_child]
        pub encryption_modes: TemplateChild<gtk4::StringList>,
        #[template_child]
        pub certificates_row: TemplateChild<adw::ExpanderRow>,
        #[template_child]
        pub ca_row: TemplateChild<adw::ActionRow>,
        #[template_child]
        pub ca_choose_button: TemplateChild<gtk4::Button>,
        #[template_child]
        pub ca_clear_button: TemplateChild<gtk4::Button>,
        #[template_child]
        pub certificate_row: TemplateChild<adw::ActionRow>,
        #[template_child]
        pub certificate_choose_button: TemplateChild<gtk4::Button>,
        #[template_child]
        pub certificate_clear_button: TemplateChild<gtk4::Button>,
        #[template_child]
        pub key_row: TemplateChild<adw::ActionRow>,
        #[template_child]
        pub key_choose_button: TemplateChild<gtk4::Button>,
        #[template_child]
        pub key_clear_button: TemplateChild<gtk4::Button>,
        #[template_child]
        pub server_name_row: TemplateChild<adw::EntryRow>,
        pub modes: RefCell<Vec<TlsMode>>,
        pub capabilities: Cell<Option<TlsCapabilities>>,
        pub route: Cell<Option<TransportClass>>,
        pub ca_file: RefCell<Option<PathBuf>>,
        pub client_certificate: RefCell<Option<PathBuf>>,
        pub client_key: RefCell<Option<PathBuf>>,
        /// Set while the code writes the rows, so its own writes are not
        /// reported as the user changing them.
        pub updating: Cell<bool>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for TlsSection {
        const NAME: &'static str = "TableProTlsSection";
        type Type = super::TlsSection;
        type ParentType = adw::PreferencesGroup;

        fn class_init(klass: &mut Self::Class) {
            klass.bind_template();
        }

        fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
            object.init_template();
        }
    }

    impl ObjectImpl for TlsSection {
        fn signals() -> &'static [Signal] {
            static SIGNALS: OnceLock<Vec<Signal>> = OnceLock::new();
            SIGNALS.get_or_init(|| vec![Signal::builder("changed").build()])
        }

        fn constructed(&self) {
            self.parent_constructed();
            let section = self.obj();
            for button in [
                &self.ca_clear_button,
                &self.certificate_clear_button,
                &self.key_clear_button,
            ] {
                button.set_icon_name(crate::ui::icons::EDIT_CLEAR);
            }

            let weak = section.downgrade();
            self.encryption_row.connect_selected_notify(move |_| {
                if let Some(section) = weak.upgrade()
                    && !section.imp().updating.get()
                {
                    section.refresh_rows();
                    section.emit_changed();
                }
            });
            let weak = section.downgrade();
            self.server_name_row.connect_changed(move |_| {
                if let Some(section) = weak.upgrade()
                    && !section.imp().updating.get()
                {
                    section.emit_changed();
                }
            });
            let slots = [
                (CertificateSlot::Ca, &self.ca_choose_button, &self.ca_clear_button),
                (
                    CertificateSlot::Certificate,
                    &self.certificate_choose_button,
                    &self.certificate_clear_button,
                ),
                (CertificateSlot::Key, &self.key_choose_button, &self.key_clear_button),
            ];
            for (slot, choose, clear) in slots {
                let weak = section.downgrade();
                choose.connect_clicked(move |_| {
                    if let Some(section) = weak.upgrade() {
                        glib::spawn_future_local(async move { section.choose(slot).await });
                    }
                });
                let weak = section.downgrade();
                clear.connect_clicked(move |_| {
                    if let Some(section) = weak.upgrade() {
                        section.set_file(slot, None);
                    }
                });
            }
        }
    }

    impl WidgetImpl for TlsSection {}
    impl PreferencesGroupImpl for TlsSection {}
}

glib::wrapper! {
    /// The Security group: encryption mode, certificate files and the
    /// name the certificate is checked against.
    pub struct TlsSection(ObjectSubclass<imp::TlsSection>)
        @extends adw::PreferencesGroup, gtk4::Widget,
        @implements gtk4::Accessible, gtk4::Buildable, gtk4::ConstraintTarget;
}

impl Default for TlsSection {
    fn default() -> Self {
        glib::Object::new()
    }
}

impl TlsSection {
    /// Show the modes and rows this driver offers, filled from `state`.
    /// A driver without TLS hides the whole group.
    pub fn apply(&self, caps: Option<&TlsCapabilities>, route: TransportClass, state: &TlsFormState) {
        let imp = self.imp();
        imp.capabilities.set(caps.copied());
        imp.route.set(Some(route));
        let Some(caps) = caps else {
            self.set_visible(false);
            return;
        };
        self.set_visible(true);
        imp.updating.set(true);
        let labels: Vec<String> = caps.modes.iter().map(|mode| mode_label(*mode)).collect();
        let labels: Vec<&str> = labels.iter().map(String::as_str).collect();
        imp.encryption_modes.splice(0, imp.encryption_modes.n_items(), &labels);
        imp.modes.replace(caps.modes.to_vec());
        let mode = if caps.modes.contains(&state.mode) {
            state.mode
        } else {
            default_tls_mode(Some(caps))
        };
        let index = caps.modes.iter().position(|candidate| *candidate == mode).unwrap_or(0);
        imp.encryption_row.set_selected(index as u32);
        imp.ca_file.replace(state.ca_file.clone());
        imp.client_certificate.replace(state.client_certificate.clone());
        imp.client_key.replace(state.client_key.clone());
        imp.server_name_row.set_text(&state.server_name);
        imp.updating.set(false);
        self.refresh_rows();
    }

    /// The route decides whether the server name can be overridden.
    pub fn set_route(&self, route: TransportClass) {
        self.imp().route.set(Some(route));
        self.refresh_rows();
    }

    pub fn form_state(&self) -> TlsFormState {
        let imp = self.imp();
        TlsFormState {
            mode: self.mode(),
            ca_file: imp.ca_file.borrow().clone(),
            client_certificate: imp.client_certificate.borrow().clone(),
            client_key: imp.client_key.borrow().clone(),
            server_name: imp.server_name_row.text().to_string(),
        }
    }

    /// Paint each row the form or the file check found a problem in.
    /// A file row says what is wrong with the file in its subtitle.
    pub fn show_problems(&self, errors: &FormErrors, files: Option<&ConfigError>) {
        let imp = self.imp();
        let file_problem = files.map(|error| {
            let state = self.form_state();
            let caps = imp.capabilities.get();
            let route = imp.route.get().unwrap_or(TransportClass::DirectTcp);
            let config = caps
                .map(|caps| state.config(&caps, route))
                .unwrap_or_else(TlsConfig::disabled);
            (tls_field(error, &config), crate::ui::error_text::config_message(error))
        });
        let problem = |field: FormField| -> Option<String> {
            match &file_problem {
                Some((problem_field, message)) if *problem_field == field => Some(message.clone()),
                _ => errors.shown_on(field).map(|problem| problem.message.clone()),
            }
        };
        show_problem(&*imp.encryption_row, problem(FormField::Encryption).as_deref());
        show_problem(&*imp.server_name_row, problem(FormField::ServerName).as_deref());
        for (slot, field) in [
            (CertificateSlot::Ca, FormField::CaFile),
            (CertificateSlot::Certificate, FormField::ClientCertificate),
            (CertificateSlot::Key, FormField::ClientKey),
        ] {
            let message = problem(field);
            let row = self.row(slot);
            show_problem(&row, message.as_deref());
            let subtitle = message.unwrap_or_else(|| self.file_subtitle(slot));
            row.set_subtitle(&subtitle);
        }
    }

    /// Open the certificate rows and put the focus on `field`, for a
    /// toast button that names the setting that fixes a failure.
    pub fn reveal(&self, field: FormField) {
        let imp = self.imp();
        if self.mode() == TlsMode::Disable {
            return;
        }
        imp.certificates_row.set_expanded(true);
        let target: gtk4::Widget = match field {
            FormField::CaFile => imp.ca_choose_button.get().upcast(),
            FormField::ClientCertificate => imp.certificate_choose_button.get().upcast(),
            FormField::ClientKey => imp.key_choose_button.get().upcast(),
            FormField::ServerName => imp.server_name_row.get().upcast(),
            _ => imp.encryption_row.get().upcast(),
        };
        target.grab_focus();
    }

    pub fn connect_changed<F: Fn(&Self) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "changed",
            false,
            glib::closure_local!(move |section: &Self| {
                f(section);
            }),
        )
    }

    /// Put a certificate file in a row, as the file chooser does.
    pub fn set_file_path(&self, field: FormField, path: Option<PathBuf>) {
        let slot = match field {
            FormField::ClientCertificate => CertificateSlot::Certificate,
            FormField::ClientKey => CertificateSlot::Key,
            _ => CertificateSlot::Ca,
        };
        self.set_file(slot, path);
    }

    fn mode(&self) -> TlsMode {
        let imp = self.imp();
        let selected = imp.encryption_row.selected() as usize;
        imp.modes.borrow().get(selected).copied().unwrap_or(TlsMode::Disable)
    }

    fn emit_changed(&self) {
        self.emit_by_name::<()>("changed", &[]);
    }

    fn set_file(&self, slot: CertificateSlot, path: Option<PathBuf>) {
        self.slot(slot).replace(path);
        self.refresh_rows();
        self.emit_changed();
    }

    fn slot(&self, slot: CertificateSlot) -> &std::cell::RefCell<Option<PathBuf>> {
        let imp = self.imp();
        match slot {
            CertificateSlot::Ca => &imp.ca_file,
            CertificateSlot::Certificate => &imp.client_certificate,
            CertificateSlot::Key => &imp.client_key,
        }
    }

    fn row(&self, slot: CertificateSlot) -> adw::ActionRow {
        let imp = self.imp();
        match slot {
            CertificateSlot::Ca => imp.ca_row.get(),
            CertificateSlot::Certificate => imp.certificate_row.get(),
            CertificateSlot::Key => imp.key_row.get(),
        }
    }

    fn clear_button(&self, slot: CertificateSlot) -> gtk4::Button {
        let imp = self.imp();
        match slot {
            CertificateSlot::Ca => imp.ca_clear_button.get(),
            CertificateSlot::Certificate => imp.certificate_clear_button.get(),
            CertificateSlot::Key => imp.key_clear_button.get(),
        }
    }

    fn file_subtitle(&self, slot: CertificateSlot) -> String {
        match self.slot(slot).borrow().as_deref() {
            Some(path) => path.display().to_string(),
            None if slot == CertificateSlot::Ca => crate::i18n::gettext("The system's certificate authorities"),
            None => crate::i18n::gettext("None"),
        }
    }

    fn refresh_rows(&self) {
        let imp = self.imp();
        let Some(caps) = imp.capabilities.get() else {
            return;
        };
        let mode = self.mode();
        imp.encryption_row.set_subtitle(&mode_description(mode));
        imp.certificates_row.set_visible(mode != TlsMode::Disable);
        imp.ca_row.set_visible(caps.ca_file);
        imp.certificate_row.set_visible(caps.client_identity);
        imp.key_row.set_visible(caps.client_identity);
        let route = imp.route.get().unwrap_or(TransportClass::DirectTcp);
        imp.server_name_row.set_visible(shows_server_name(&caps, route));
        for slot in [CertificateSlot::Ca, CertificateSlot::Certificate, CertificateSlot::Key] {
            let chosen = self.slot(slot).borrow().is_some();
            self.clear_button(slot).set_visible(chosen);
            if !self.row(slot).has_css_class("error") {
                self.row(slot).set_subtitle(&self.file_subtitle(slot));
            }
        }
    }

    async fn choose(&self, slot: CertificateSlot) {
        let title = match slot {
            CertificateSlot::Ca => crate::i18n::gettext("Choose CA Certificate"),
            CertificateSlot::Certificate => crate::i18n::gettext("Choose Client Certificate"),
            CertificateSlot::Key => crate::i18n::gettext("Choose Client Key"),
        };
        let dialog = pem_dialog(&title);
        let parent = self.root().and_downcast::<gtk4::Window>();
        let chosen = dialog.open_future(parent.as_ref()).await;
        if let Some(path) = chosen.ok().and_then(|file| file.path()) {
            self.set_file(slot, Some(path));
        }
    }
}

pub fn mode_label(mode: TlsMode) -> String {
    match mode {
        TlsMode::Disable => crate::i18n::gettext("Disable"),
        TlsMode::Require => crate::i18n::gettext("Require"),
        TlsMode::VerifyFull => crate::i18n::gettext("Verify full"),
    }
}

/// What each mode protects against, so the choice is an informed one.
pub fn mode_description(mode: TlsMode) -> String {
    match mode {
        TlsMode::Disable => crate::i18n::gettext("Not encrypted. Anyone on the network can read the traffic."),
        TlsMode::Require => crate::i18n::gettext("Encrypted. The server certificate is not checked."),
        TlsMode::VerifyFull => crate::i18n::gettext("Encrypted. The certificate must be valid for the server name."),
    }
}

fn pem_dialog(title: &str) -> gtk4::FileDialog {
    let pem = gtk4::FileFilter::new();
    pem.set_name(Some(&crate::i18n::gettext("PEM certificates and keys")));
    for mime in ["application/x-pem-file", "application/x-x509-ca-cert"] {
        pem.add_mime_type(mime);
    }
    for suffix in ["pem", "crt", "cer", "key"] {
        pem.add_suffix(suffix);
    }
    let any = gtk4::FileFilter::new();
    any.set_name(Some(&crate::i18n::gettext("All files")));
    any.add_pattern("*");
    let filters = gio::ListStore::new::<gtk4::FileFilter>();
    filters.append(&pem);
    filters.append(&any);
    gtk4::FileDialog::builder()
        .title(title)
        .modal(true)
        .filters(&filters)
        .default_filter(&pem)
        .build()
}
