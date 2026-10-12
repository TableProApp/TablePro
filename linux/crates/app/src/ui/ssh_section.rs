use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use secrecy::SecretString;

use super::connect_dialog::{FormErrors, FormField, show_problem};
use super::ssh_inputs::{SshAuthChoice, SshEnvironment, SshFormState};

mod imp {
    use std::cell::Cell;
    use std::sync::OnceLock;

    use glib::subclass::Signal;
    use libadwaita::subclass::prelude::*;

    use super::*;

    #[derive(Default, gtk4::CompositeTemplate)]
    #[template(resource = "/app/tablepro/TablePro/ui/ssh-section.ui")]
    pub struct SshSection {
        #[template_child]
        pub expander: TemplateChild<adw::ExpanderRow>,
        #[template_child]
        pub host_row: TemplateChild<adw::EntryRow>,
        #[template_child]
        pub port_row: TemplateChild<adw::EntryRow>,
        #[template_child]
        pub user_row: TemplateChild<adw::EntryRow>,
        #[template_child]
        pub jump_row: TemplateChild<adw::EntryRow>,
        #[template_child]
        pub auth_row: TemplateChild<adw::ComboRow>,
        #[template_child]
        pub auth_names: TemplateChild<gtk4::StringList>,
        #[template_child]
        pub password_row: TemplateChild<adw::PasswordEntryRow>,
        #[template_child]
        pub key_row: TemplateChild<adw::EntryRow>,
        #[template_child]
        pub key_browse_button: TemplateChild<gtk4::Button>,
        #[template_child]
        pub passphrase_row: TemplateChild<adw::PasswordEntryRow>,
        /// Set while the code writes the rows, so its own writes are not
        /// reported as the user changing them.
        pub updating: Cell<bool>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for SshSection {
        const NAME: &'static str = "TableProSshSection";
        type Type = super::SshSection;
        type ParentType = adw::PreferencesGroup;

        fn class_init(klass: &mut Self::Class) {
            klass.bind_template();
        }

        fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
            object.init_template();
        }
    }

    impl ObjectImpl for SshSection {
        fn signals() -> &'static [Signal] {
            static SIGNALS: OnceLock<Vec<Signal>> = OnceLock::new();
            SIGNALS.get_or_init(|| vec![Signal::builder("changed").build()])
        }

        fn constructed(&self) {
            self.parent_constructed();
            let section = self.obj();
            let labels: Vec<String> = SshAuthChoice::ALL.iter().map(|choice| choice.label()).collect();
            let labels: Vec<&str> = labels.iter().map(String::as_str).collect();
            self.auth_names.splice(0, self.auth_names.n_items(), &labels);
            self.key_browse_button.set_icon_name(crate::ui::icons::DOCUMENT_OPEN);
            section.refresh_auth_rows();

            let weak = section.downgrade();
            self.expander.connect_enable_expansion_notify(move |_| {
                if let Some(section) = weak.upgrade() {
                    section.emit_changed();
                }
            });
            let weak = section.downgrade();
            self.auth_row.connect_selected_notify(move |_| {
                if let Some(section) = weak.upgrade() {
                    section.refresh_auth_rows();
                    section.emit_changed();
                }
            });
            let entries: [&adw::EntryRow; 4] = [&self.host_row, &self.port_row, &self.user_row, &self.jump_row];
            for row in entries {
                let weak = section.downgrade();
                row.connect_changed(move |_| {
                    if let Some(section) = weak.upgrade() {
                        section.emit_changed();
                    }
                });
            }
            let key_row: &adw::EntryRow = &self.key_row;
            let weak = section.downgrade();
            key_row.connect_changed(move |_| {
                if let Some(section) = weak.upgrade() {
                    section.emit_changed();
                }
            });
            for row in [&self.password_row, &self.passphrase_row] {
                let weak = section.downgrade();
                row.connect_changed(move |_| {
                    if let Some(section) = weak.upgrade() {
                        section.emit_changed();
                    }
                });
            }
            let weak = section.downgrade();
            self.key_browse_button.connect_clicked(move |_| {
                if let Some(section) = weak.upgrade() {
                    glib::spawn_future_local(async move { section.choose_key().await });
                }
            });
        }
    }

    impl WidgetImpl for SshSection {}
    impl PreferencesGroupImpl for SshSection {}
}

glib::wrapper! {
    /// The optional SSH tunnel. OpenSSH reads the user's own SSH
    /// configuration, so a host alias and an empty port or username
    /// work the way they do in a terminal.
    pub struct SshSection(ObjectSubclass<imp::SshSection>)
        @extends adw::PreferencesGroup, gtk4::Widget,
        @implements gtk4::Accessible, gtk4::Buildable, gtk4::ConstraintTarget;
}

impl Default for SshSection {
    fn default() -> Self {
        glib::Object::new()
    }
}

impl SshSection {
    pub fn is_enabled(&self) -> bool {
        self.imp().expander.enables_expansion()
    }

    /// Start from what this machine has: the agent when one runs, else
    /// the first key in ~/.ssh.
    pub fn apply_environment(&self, environment: &SshEnvironment) {
        self.set_rows(&SshFormState::new(environment));
    }

    /// The rows as typed, or `None` while the tunnel is off.
    pub fn form_state(&self) -> Option<SshFormState> {
        if !self.is_enabled() {
            return None;
        }
        let imp = self.imp();
        Some(SshFormState {
            host: imp.host_row.text().to_string(),
            port: imp.port_row.text().to_string(),
            user: imp.user_row.text().to_string(),
            jump_hosts: imp.jump_row.text().to_string(),
            auth: SshAuthChoice::from_index(imp.auth_row.selected()),
            key_path: imp.key_row.text().to_string(),
            password: SecretString::from(imp.password_row.text().to_string()),
            passphrase: SecretString::from(imp.passphrase_row.text().to_string()),
        })
    }

    /// Fill the rows and turn the tunnel on, or leave the rows as they
    /// are and turn it off.
    pub fn set_state(&self, state: Option<&SshFormState>) {
        let imp = self.imp();
        match state {
            Some(state) => {
                self.set_rows(state);
                imp.expander.set_enable_expansion(true);
            }
            None => imp.expander.set_enable_expansion(false),
        }
    }

    pub fn show_problems(&self, errors: &FormErrors) {
        let imp = self.imp();
        let message = |field| errors.shown_on(field).map(|problem| problem.message.as_str());
        show_problem(&*imp.host_row, message(FormField::SshHost));
        show_problem(&*imp.port_row, message(FormField::SshPort));
        show_problem(&*imp.user_row, message(FormField::SshUser));
        show_problem(&*imp.jump_row, message(FormField::SshJumpHosts));
        show_problem(&*imp.key_row, message(FormField::SshKeyPath));
    }

    pub fn reveal(&self, field: FormField) {
        let imp = self.imp();
        imp.expander.set_expanded(true);
        let row: gtk4::Widget = match field {
            FormField::SshPort => imp.port_row.get().upcast(),
            FormField::SshUser => imp.user_row.get().upcast(),
            FormField::SshJumpHosts => imp.jump_row.get().upcast(),
            FormField::SshKeyPath => imp.key_row.get().upcast(),
            _ => imp.host_row.get().upcast(),
        };
        row.grab_focus();
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

    fn set_rows(&self, state: &SshFormState) {
        let imp = self.imp();
        imp.updating.set(true);
        imp.host_row.set_text(&state.host);
        imp.port_row.set_text(&state.port);
        imp.user_row.set_text(&state.user);
        imp.jump_row.set_text(&state.jump_hosts);
        imp.auth_row.set_selected(state.auth.index());
        imp.key_row.set_text(&state.key_path);
        imp.updating.set(false);
        self.refresh_auth_rows();
        self.emit_changed();
    }

    fn emit_changed(&self) {
        if !self.imp().updating.get() {
            self.emit_by_name::<()>("changed", &[]);
        }
    }

    fn refresh_auth_rows(&self) {
        let imp = self.imp();
        let auth = SshAuthChoice::from_index(imp.auth_row.selected());
        imp.auth_row.set_subtitle(&auth.description());
        imp.password_row.set_visible(auth == SshAuthChoice::Password);
        imp.key_row.set_visible(auth == SshAuthChoice::PrivateKey);
        imp.passphrase_row.set_visible(auth == SshAuthChoice::PrivateKey);
    }

    async fn choose_key(&self) {
        let filter = gtk4::FileFilter::new();
        filter.set_name(Some(&crate::i18n::gettext("SSH keys")));
        for pattern in ["id_*", "*.pem", "*.key"] {
            filter.add_pattern(pattern);
        }
        filter.add_mime_type("application/x-pem-file");
        let any = gtk4::FileFilter::new();
        any.set_name(Some(&crate::i18n::gettext("All files")));
        any.add_pattern("*");
        let filters = gio::ListStore::new::<gtk4::FileFilter>();
        filters.append(&filter);
        filters.append(&any);
        let dialog = gtk4::FileDialog::builder()
            .title(crate::i18n::gettext("Choose Private Key"))
            .modal(true)
            .filters(&filters)
            .default_filter(&filter)
            .build();
        let ssh_dir = glib::home_dir().join(".ssh");
        if ssh_dir.is_dir() {
            dialog.set_initial_folder(Some(&gio::File::for_path(&ssh_dir)));
        }
        let parent = self.root().and_downcast::<gtk4::Window>();
        if let Some(path) = dialog
            .open_future(parent.as_ref())
            .await
            .ok()
            .and_then(|file| file.path())
        {
            self.imp().key_row.set_text(&path.to_string_lossy());
        }
    }
}

#[cfg(test)]
impl SshSection {
    /// Every text row in the section, with whether Enter submits from
    /// it.
    pub(crate) fn rows_activating_default(&self) -> Vec<(&'static str, bool)> {
        let imp = self.imp();
        vec![
            ("host", imp.host_row.activates_default()),
            ("port", imp.port_row.activates_default()),
            ("user", imp.user_row.activates_default()),
            ("jump hosts", imp.jump_row.activates_default()),
            ("password", imp.password_row.activates_default()),
            ("key path", imp.key_row.activates_default()),
            ("passphrase", imp.passphrase_row.activates_default()),
        ]
    }

    pub(crate) fn rows(&self) -> Vec<gtk4::Widget> {
        let imp = self.imp();
        vec![
            imp.expander.get().upcast(),
            imp.host_row.get().upcast(),
            imp.port_row.get().upcast(),
            imp.user_row.get().upcast(),
            imp.jump_row.get().upcast(),
            imp.auth_row.get().upcast(),
            imp.password_row.get().upcast(),
            imp.key_row.get().upcast(),
            imp.passphrase_row.get().upcast(),
        ]
    }

    pub(crate) fn set_host(&self, host: &str) {
        self.imp().host_row.set_text(host);
    }

    pub(crate) fn enable(&self) {
        self.imp().expander.set_enable_expansion(true);
    }
}
