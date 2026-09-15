use relm4::adw::prelude::*;
use relm4::{adw, gtk};
use secrecy::SecretString;

use tablepro_ssh::russh_tunnel::{SshAuth, SshConfig};
use tablepro_storage::SavedSshConfig;

use super::ssh_inputs::{SSH_AUTH_PASSWORD, SshRowValues, saved_ssh_from_rows};
use crate::services::connection_service::{InterimSshAuth, interim_ssh_target};

/// SSH section uses a single `AdwPreferencesGroup` containing one
/// `AdwExpanderRow`. The expander's enable-switch toggles whether the
/// tunnel is used; expanding it reveals the host / port / user / auth
/// rows. This is the native Adwaita pattern for an optional sub-form
/// (matches GNOME Settings' "Custom Network Settings" expander).
pub struct SshSection {
    pub group: adw::PreferencesGroup,
    pub expander: adw::ExpanderRow,
    pub auth_combo: adw::ComboRow,
    host: adw::EntryRow,
    port: adw::SpinRow,
    user: adw::EntryRow,
    password: adw::PasswordEntryRow,
    key_path: adw::EntryRow,
    passphrase: adw::PasswordEntryRow,
}

#[derive(Clone)]
pub struct SshInputs {
    pub cfg: SshConfig,
    pub saved: SavedSshConfig,
    pub secret_to_store: SshSecretToStore,
}

#[derive(Clone)]
pub enum SshSecretToStore {
    Password(SecretString),
    Passphrase(SecretString),
    None,
}

impl SshSection {
    pub fn build() -> Self {
        let group = adw::PreferencesGroup::builder()
            .title(crate::i18n::gettext("SSH tunnel"))
            .build();

        let expander = adw::ExpanderRow::builder()
            .title(crate::i18n::gettext("Use SSH tunnel"))
            .subtitle(crate::i18n::gettext("Reach the database through a bastion host"))
            .show_enable_switch(true)
            .enable_expansion(false)
            .build();
        group.add(&expander);

        let host = adw::EntryRow::builder().title(crate::i18n::gettext("Host")).build();
        let port = adw::SpinRow::with_range(1.0, 65535.0, 1.0);
        port.set_title(&crate::i18n::gettext("Port"));
        port.set_value(22.0);
        let user = adw::EntryRow::builder().title(crate::i18n::gettext("Username")).build();

        let auth_pwd = crate::i18n::gettext("Password");
        let auth_key = crate::i18n::gettext("Private key");
        let auth_model = gtk::StringList::new(&[auth_pwd.as_str(), auth_key.as_str()]);
        let auth_combo = adw::ComboRow::builder()
            .title(crate::i18n::gettext("Authentication"))
            .model(&auth_model)
            .selected(SSH_AUTH_PASSWORD)
            .build();

        let password = adw::PasswordEntryRow::builder()
            .title(crate::i18n::gettext("Password"))
            .build();
        let key_path = adw::EntryRow::builder()
            .title(crate::i18n::gettext("Private key path"))
            .text(default_ssh_key_path())
            .build();
        attach_key_browse_button(&key_path);
        let passphrase = adw::PasswordEntryRow::builder()
            .title(crate::i18n::gettext("Passphrase"))
            .build();

        expander.add_row(&host);
        expander.add_row(&port);
        expander.add_row(&user);
        expander.add_row(&auth_combo);
        expander.add_row(&password);
        expander.add_row(&key_path);
        expander.add_row(&passphrase);

        let section = Self {
            group,
            expander,
            auth_combo,
            host,
            port,
            user,
            password,
            key_path,
            passphrase,
        };
        section.refresh_auth_visibility();
        section
    }

    pub fn set_visible(&self, visible: bool) {
        self.group.set_visible(visible);
        if !visible {
            self.expander.set_enable_expansion(false);
        }
    }

    pub fn is_enabled(&self) -> bool {
        self.expander.enables_expansion()
    }

    pub fn refresh_auth_visibility(&self) {
        let is_password = self.auth_combo.selected() == SSH_AUTH_PASSWORD;
        self.password.set_visible(is_password);
        self.key_path.set_visible(!is_password);
        self.passphrase.set_visible(!is_password);
    }

    pub fn collect(&self) -> Result<SshInputs, String> {
        let passphrase_text = self.passphrase.text();
        let rows = SshRowValues {
            host: self.host.text().to_string(),
            port: self.port.value(),
            user: self.user.text().to_string(),
            auth_index: self.auth_combo.selected(),
            key_path: self.key_path.text().to_string(),
            has_passphrase_text: !passphrase_text.is_empty(),
        };
        let saved = saved_ssh_from_rows(&rows).map_err(|error| error.message())?;
        let target = interim_ssh_target(&saved).map_err(|error| crate::ui::error_text::ssh_message(&error))?;

        let (auth, secret_to_store) = match target.auth {
            InterimSshAuth::PrivateKey { path, has_passphrase } => {
                let passphrase = has_passphrase.then(|| SecretString::from(passphrase_text.to_string()));
                let secret = passphrase
                    .clone()
                    .map_or(SshSecretToStore::None, SshSecretToStore::Passphrase);
                (SshAuth::PrivateKey { path, passphrase }, secret)
            }
            InterimSshAuth::Password => {
                let password = SecretString::from(self.password.text().to_string());
                (
                    SshAuth::Password {
                        password: password.clone(),
                    },
                    SshSecretToStore::Password(password),
                )
            }
        };

        Ok(SshInputs {
            cfg: SshConfig {
                host: target.host,
                port: target.port,
                username: target.username,
                auth,
            },
            saved,
            secret_to_store,
        })
    }
}

fn default_ssh_key_path() -> String {
    let ssh_dir = gtk::glib::home_dir().join(".ssh");
    ["id_ed25519", "id_rsa", "id_ecdsa"]
        .into_iter()
        .map(|candidate| ssh_dir.join(candidate))
        .find(|path| path.exists())
        .map(|path| path.to_string_lossy().into_owned())
        .unwrap_or_default()
}

fn attach_key_browse_button(key_path: &adw::EntryRow) {
    let button = gtk::Button::builder()
        .icon_name(crate::ui::icons::DOCUMENT_OPEN)
        .tooltip_text(crate::i18n::gettext("Browse for private key"))
        .valign(gtk::Align::Center)
        .build();
    button.add_css_class("flat");
    let entry = key_path.clone();
    button.connect_clicked(move |btn| {
        let dialog = gtk::FileDialog::builder()
            .title(crate::i18n::gettext("Select SSH private key"))
            .modal(true)
            .build();
        let filter = gtk::FileFilter::new();
        filter.set_name(Some(&crate::i18n::gettext("SSH keys")));
        for pattern in ["id_*", "*.pem", "*.key"] {
            filter.add_pattern(pattern);
        }
        filter.add_mime_type("application/x-pem-file");
        let filters = gtk::gio::ListStore::new::<gtk::FileFilter>();
        filters.append(&filter);
        dialog.set_filters(Some(&filters));
        dialog.set_default_filter(Some(&filter));

        let ssh_dir = gtk::glib::home_dir().join(".ssh");
        if ssh_dir.exists() {
            dialog.set_initial_folder(Some(&gtk::gio::File::for_path(&ssh_dir)));
        }
        let entry = entry.clone();
        let parent = btn.root().and_then(|r| r.downcast::<gtk::Window>().ok());
        dialog.open(parent.as_ref(), gtk::gio::Cancellable::NONE, move |result| {
            if let Ok(file) = result
                && let Some(path) = file.path()
            {
                entry.set_text(&path.to_string_lossy());
            }
        });
    });
    key_path.add_suffix(&button);
}
