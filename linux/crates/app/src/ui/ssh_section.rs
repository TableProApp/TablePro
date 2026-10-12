use relm4::adw::prelude::*;
use relm4::{adw, gtk};
use secrecy::SecretString;

use tablepro_ssh::{SshAuth, SshConfig};
use tablepro_storage::SavedSshConfig;

use super::ssh_inputs::{SSH_AUTH_PASSWORD, SshRowValues, saved_ssh_from_rows};

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

        let host = adw::EntryRow::builder()
            .title(crate::i18n::gettext("Host"))
            .activates_default(true)
            .build();
        let port = adw::SpinRow::with_range(1.0, 65535.0, 1.0);
        port.set_title(&crate::i18n::gettext("Port"));
        port.set_value(22.0);
        let user = adw::EntryRow::builder()
            .title(crate::i18n::gettext("Username"))
            .activates_default(true)
            .build();

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
            .activates_default(true)
            .build();
        let key_path = adw::EntryRow::builder()
            .title(crate::i18n::gettext("Private key path"))
            .text(default_ssh_key_path())
            .activates_default(true)
            .build();
        attach_key_browse_button(&key_path);
        let passphrase = adw::PasswordEntryRow::builder()
            .title(crate::i18n::gettext("Passphrase"))
            .activates_default(true)
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
        let mut cfg = tablepro_session::connect::ssh_config(&saved)
            .map_err(|failure| crate::ui::error_text::ssh_failure_message(&failure))?;
        let secret_to_store = fill_secret(
            &mut cfg,
            SecretString::from(self.password.text().to_string()),
            SecretString::from(passphrase_text.to_string()),
        );
        Ok(SshInputs {
            cfg,
            saved,
            secret_to_store,
        })
    }
}

/// Put the typed secret into the configuration the rows produced, and
/// say which one the keyring should keep. A key with no passphrase typed
/// keeps none, so ssh asks for it itself if the key needs one.
fn fill_secret(cfg: &mut SshConfig, password: SecretString, passphrase: SecretString) -> SshSecretToStore {
    match &mut cfg.auth {
        SshAuth::Password { password: slot } => {
            *slot = password.clone();
            SshSecretToStore::Password(password)
        }
        SshAuth::PrivateKey { passphrase: slot, .. } => {
            if secrecy::ExposeSecret::expose_secret(&passphrase).is_empty() {
                return SshSecretToStore::None;
            }
            *slot = Some(passphrase.clone());
            SshSecretToStore::Passphrase(passphrase)
        }
        SshAuth::Agent | SshAuth::KeyboardInteractive => SshSecretToStore::None,
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

#[cfg(test)]
impl SshSection {
    /// Every text row in the section, with whether Enter submits from
    /// it. The port is a spin row, which has no text to submit.
    pub(crate) fn rows_activating_default(&self) -> [(&'static str, bool); 5] {
        [
            ("host", self.host.activates_default()),
            ("user", self.user.activates_default()),
            ("password", self.password.activates_default()),
            ("key_path", self.key_path.activates_default()),
            ("passphrase", self.passphrase.activates_default()),
        ]
    }
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

#[cfg(test)]
mod tests {
    use secrecy::ExposeSecret;
    use tablepro_storage::SavedSshAuth;

    use super::*;

    fn config(auth: SavedSshAuth) -> SshConfig {
        tablepro_session::connect::ssh_config(&SavedSshConfig {
            host: "bastion.example.com".to_owned(),
            port: Some(22),
            username: Some("deploy".to_owned()),
            jump_hosts: Vec::new(),
            auth,
        })
        .expect("a valid SSH section")
    }

    #[test]
    fn a_password_login_carries_and_keeps_the_typed_password() {
        let mut cfg = config(SavedSshAuth::Password);

        let kept = fill_secret(&mut cfg, SecretString::from("s3cret"), SecretString::from(""));

        let SshAuth::Password { password } = &cfg.auth else {
            panic!("expected password auth");
        };
        assert_eq!(password.expose_secret(), "s3cret");
        assert!(matches!(kept, SshSecretToStore::Password(_)));
    }

    #[test]
    fn a_key_with_no_passphrase_typed_keeps_none() {
        let key = SavedSshAuth::PrivateKey {
            path: Some("/home/u/.ssh/id_ed25519".into()),
            has_passphrase: false,
        };
        let mut cfg = config(key.clone());
        assert!(matches!(
            fill_secret(&mut cfg, SecretString::from(""), SecretString::from("")),
            SshSecretToStore::None
        ));

        let mut cfg = config(key);
        let kept = fill_secret(&mut cfg, SecretString::from(""), SecretString::from("phrase"));
        let SshAuth::PrivateKey { passphrase, .. } = &cfg.auth else {
            panic!("expected key auth");
        };
        assert_eq!(passphrase.as_ref().map(ExposeSecret::expose_secret), Some("phrase"));
        assert!(matches!(kept, SshSecretToStore::Passphrase(_)));
    }
}
