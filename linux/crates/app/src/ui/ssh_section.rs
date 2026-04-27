use std::path::PathBuf;

use relm4::adw::prelude::*;
use relm4::{adw, gtk};
use secrecy::SecretString;

use tablepro_ssh::{SshAuth, SshConfig};
use tablepro_storage::{SavedSshAuth, SavedSshConfig};

const SSH_AUTH_PASSWORD: u32 = 0;
const SSH_AUTH_KEY: u32 = 1;

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
        let group = adw::PreferencesGroup::builder().title(crate::tr!("SSH tunnel")).build();

        let expander = adw::ExpanderRow::builder()
            .title(crate::tr!("Use SSH tunnel"))
            .subtitle(crate::tr!("Reach the database through a bastion host"))
            .show_enable_switch(true)
            .enable_expansion(false)
            .build();
        group.add(&expander);

        let host = adw::EntryRow::builder().title(crate::tr!("Host")).build();
        let port = adw::SpinRow::with_range(1.0, 65535.0, 1.0);
        port.set_title(&crate::tr!("Port"));
        port.set_value(22.0);
        let user = adw::EntryRow::builder().title(crate::tr!("Username")).build();

        let auth_pwd = crate::tr!("Password");
        let auth_key = crate::tr!("Private key");
        let auth_model = gtk::StringList::new(&[auth_pwd.as_str(), auth_key.as_str()]);
        let auth_combo = adw::ComboRow::builder()
            .title(crate::tr!("Authentication"))
            .model(&auth_model)
            .selected(SSH_AUTH_PASSWORD)
            .build();

        let password = adw::PasswordEntryRow::builder().title(crate::tr!("Password")).build();
        let key_path = adw::EntryRow::builder()
            .title(crate::tr!("Private key path"))
            .text(default_ssh_key_path())
            .build();
        attach_key_browse_button(&key_path);
        let passphrase = adw::PasswordEntryRow::builder().title(crate::tr!("Passphrase")).build();

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
        let host = self.host.text().to_string();
        if host.trim().is_empty() {
            return Err(crate::tr!("SSH host is required"));
        }
        let port: u16 = self.port.value() as u16;
        let username = self.user.text().to_string();
        if username.trim().is_empty() {
            return Err(crate::tr!("SSH username is required"));
        }

        let (auth, saved_auth, secret) = match self.auth_combo.selected() {
            SSH_AUTH_KEY => {
                let path = self.key_path.text().to_string();
                if path.trim().is_empty() {
                    return Err(crate::tr!("Private key path is required"));
                }
                let path_buf = PathBuf::from(path);
                let raw_passphrase = self.passphrase.text().to_string();
                let has_passphrase = !raw_passphrase.is_empty();
                let auth = SshAuth::PrivateKey {
                    path: path_buf.clone(),
                    passphrase: if has_passphrase {
                        Some(SecretString::new(raw_passphrase.clone().into()))
                    } else {
                        None
                    },
                };
                let saved_auth = SavedSshAuth::PrivateKey {
                    path: path_buf,
                    has_passphrase,
                };
                let secret = if has_passphrase {
                    SshSecretToStore::Passphrase(SecretString::new(raw_passphrase.into()))
                } else {
                    SshSecretToStore::None
                };
                (auth, saved_auth, secret)
            }
            _ => {
                let raw_password = self.password.text().to_string();
                let auth = SshAuth::Password {
                    password: SecretString::new(raw_password.clone().into()),
                };
                let saved_auth = SavedSshAuth::Password;
                let secret = SshSecretToStore::Password(SecretString::new(raw_password.into()));
                (auth, saved_auth, secret)
            }
        };

        Ok(SshInputs {
            cfg: SshConfig {
                host: host.clone(),
                port,
                username: username.clone(),
                auth,
            },
            saved: SavedSshConfig {
                host,
                port,
                username,
                auth: saved_auth,
            },
            secret_to_store: secret,
        })
    }
}

fn default_ssh_key_path() -> String {
    let Some(home) = std::env::var_os("HOME") else {
        return String::new();
    };
    let home = PathBuf::from(home).join(".ssh");
    for candidate in ["id_ed25519", "id_rsa", "id_ecdsa"] {
        let path = home.join(candidate);
        if path.exists() {
            return path.to_string_lossy().into_owned();
        }
    }
    String::new()
}

fn attach_key_browse_button(key_path: &adw::EntryRow) {
    let button = gtk::Button::builder()
        .icon_name("document-open-symbolic")
        .tooltip_text(crate::tr!("Browse for private key"))
        .valign(gtk::Align::Center)
        .build();
    button.add_css_class("flat");
    let entry = key_path.clone();
    button.connect_clicked(move |btn| {
        let dialog = gtk::FileDialog::builder()
            .title(crate::tr!("Select SSH private key"))
            .modal(true)
            .build();
        // Filter to common SSH key filenames (id_ed25519, id_rsa,
        // id_ecdsa, *.pem, *.key) so the file picker hides irrelevant
        // entries — matches the pattern GNOME Settings uses for
        // certificate pickers.
        let filter = gtk::FileFilter::new();
        filter.set_name(Some(&crate::tr!("SSH keys")));
        for pattern in ["id_*", "*.pem", "*.key"] {
            filter.add_pattern(pattern);
        }
        filter.add_mime_type("application/x-pem-file");
        let filters = gtk::gio::ListStore::new::<gtk::FileFilter>();
        filters.append(&filter);
        dialog.set_filters(Some(&filters));
        dialog.set_default_filter(Some(&filter));

        if let Some(home) = std::env::var_os("HOME") {
            let ssh_dir = std::path::PathBuf::from(home).join(".ssh");
            if ssh_dir.exists() {
                dialog.set_initial_folder(Some(&gtk::gio::File::for_path(&ssh_dir)));
            }
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
