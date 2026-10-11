use relm4::adw;
use relm4::adw::prelude::*;
use secrecy::{ExposeSecret, SecretString};

use tablepro_core::{AuthMode, Environment};
use tablepro_storage::{
    SavedConnection, SavedSshAuth, StorageError, load_password, load_ssh_passphrase, load_ssh_password,
};

use super::{AUTH_MODE_ROWS, ConnectDialog, DriverEntry};

#[derive(Debug)]
pub struct ConnectionPrefill {
    pub saved: SavedConnection,
    pub password: Option<SecretString>,
    pub ssh_password: Option<SecretString>,
    pub ssh_passphrase: Option<SecretString>,
    pub unreadable_secrets: bool,
}

pub fn has_jump_chain(saved: &SavedConnection) -> bool {
    saved.ssh.as_ref().is_some_and(|ssh| ssh.jump.is_some())
}

pub fn readable(result: Result<Option<SecretString>, StorageError>, unreadable: &mut bool) -> Option<SecretString> {
    match result {
        Ok(secret) => secret,
        Err(error) => {
            tracing::warn!(%error, "a saved secret could not be read for editing");
            *unreadable = true;
            None
        }
    }
}

pub async fn load_prefill(saved: SavedConnection) -> ConnectionPrefill {
    let mut unreadable_secrets = false;
    let password = match saved.auth_mode {
        AuthMode::Password => readable(load_password(saved.id).await, &mut unreadable_secrets),
        AuthMode::Kerberos => None,
    };
    let (ssh_password, ssh_passphrase) = match saved.ssh.as_ref().map(|ssh| (&ssh.auth, ssh.agent)) {
        Some((SavedSshAuth::Password, false)) => (
            readable(load_ssh_password(saved.id).await, &mut unreadable_secrets),
            None,
        ),
        Some((
            SavedSshAuth::PrivateKey {
                has_passphrase: true, ..
            },
            false,
        )) => (
            None,
            readable(load_ssh_passphrase(saved.id).await, &mut unreadable_secrets),
        ),
        _ => (None, None),
    };
    ConnectionPrefill {
        saved,
        password,
        ssh_password,
        ssh_passphrase,
        unreadable_secrets,
    }
}

pub(super) fn environment_row(environment: Environment) -> u32 {
    match environment {
        Environment::Local => 0,
        Environment::Dev => 1,
        Environment::Staging => 2,
        Environment::Prod => 3,
    }
}

pub(super) fn auth_row(mode: AuthMode) -> u32 {
    AUTH_MODE_ROWS.iter().position(|row| *row == mode).unwrap_or(0) as u32
}

pub(super) fn driver_row(drivers: &[DriverEntry], driver_id: &str) -> Option<u32> {
    drivers.iter().position(|d| d.id == driver_id).map(|row| row as u32)
}

fn seconds_row(seconds: Option<u32>) -> f64 {
    f64::from(seconds.unwrap_or(0))
}

impl ConnectDialog {
    pub(super) fn apply_prefill(&mut self, prefill: &ConnectionPrefill, root: &adw::Dialog) {
        let saved = &prefill.saved;
        if let Some(row) = driver_row(&self.drivers, &saved.driver_id) {
            self.driver_combo.set_selected(row);
            self.apply_selected_driver(row, root);
        }
        self.name.set_text(&saved.name);
        self.host.set_text(&saved.host);
        self.port.set_value(f64::from(saved.port));
        self.database.set_text(&saved.database);
        self.username.set_text(&saved.username);
        if let Some(dir) = &saved.socket_dir {
            self.endpoint_combo.set_selected(1);
            self.socket_dir.set_text(&dir.to_string_lossy());
        }
        self.auth_combo.set_selected(auth_row(saved.auth_mode));
        self.form.selected = saved.auth_mode;
        self.apply_form_state();
        self.tls_mode.set_selected(saved.effective_tls_mode().index());
        if let Some(root_cert) = &saved.tls_root_cert {
            self.tls_root_cert.set_text(&root_cert.to_string_lossy());
        }
        if let Some(client_cert) = &saved.tls_client_cert {
            self.tls_client_cert.set_text(&client_cert.to_string_lossy());
        }
        if let Some(client_key) = &saved.tls_client_key {
            self.tls_client_key.set_text(&client_key.to_string_lossy());
        }
        self.apply_tls_visibility();
        self.read_only.set_active(saved.read_only);
        self.environment.set_selected(environment_row(saved.environment));
        self.connect_timeout.set_value(seconds_row(saved.connect_timeout_secs));
        self.query_timeout.set_value(seconds_row(saved.query_timeout_secs));
        if let Some(password) = &prefill.password {
            self.password.set_text(password.expose_secret());
        }
        if let Some(ssh) = &saved.ssh {
            self.ssh
                .prefill(ssh, prefill.ssh_password.as_ref(), prefill.ssh_passphrase.as_ref());
        }
        let title = crate::tr!("Edit {name}").replace("{name}", &saved.name);
        root.set_title(&title);
        self.header_title.set_text(&title);
        if prefill.unreadable_secrets {
            self.show_toast(&crate::tr!(
                "The saved password could not be read from the keyring. Enter it again to keep password sign-in."
            ));
        }
        self.refresh_validity();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tablepro_core::DriverMaturity;
    use tablepro_storage::{KeyringFailure, SavedSshConfig};
    use uuid::Uuid;

    fn entry(id: &str) -> DriverEntry {
        DriverEntry {
            id: id.to_string(),
            display_name: id.to_string(),
            maturity: DriverMaturity::Stable,
        }
    }

    fn saved_with_ssh(ssh: Option<SavedSshConfig>) -> SavedConnection {
        SavedConnection {
            id: Uuid::new_v4(),
            name: "db".into(),
            driver_id: "postgres".into(),
            host: "h".into(),
            port: 5432,
            socket_dir: None,
            database: "d".into(),
            username: "u".into(),
            use_tls: false,
            tls_mode: None,
            tls_root_cert: None,
            tls_client_cert: None,
            tls_client_key: None,
            read_only: false,
            auth_mode: AuthMode::Password,
            environment: Environment::Local,
            ssh,
            last_opened_at: None,
            connect_timeout_secs: None,
            query_timeout_secs: None,
        }
    }

    fn hop(jump: Option<SavedSshConfig>) -> SavedSshConfig {
        SavedSshConfig {
            hop_id: uuid::Uuid::new_v4(),
            credential_revision: 0,
            host: "bastion".into(),
            port: 22,
            username: "me".into(),
            auth: SavedSshAuth::Password,
            jump: jump.map(Box::new),
            client: tablepro_storage::SshClient::Builtin,
            agent: false,
        }
    }

    #[test]
    fn environment_rows_match_the_form_order() {
        let rows: Vec<u32> = [
            Environment::Local,
            Environment::Dev,
            Environment::Staging,
            Environment::Prod,
        ]
        .into_iter()
        .map(environment_row)
        .collect();
        assert_eq!(rows, vec![0, 1, 2, 3]);
    }

    #[test]
    fn auth_rows_round_trip_through_the_form_decoder() {
        for mode in AUTH_MODE_ROWS {
            assert_eq!(super::super::auth_mode_for_row(auth_row(mode)), mode);
        }
    }

    #[test]
    fn driver_row_finds_the_sorted_position_or_nothing() {
        let drivers = [entry("mysql"), entry("postgres"), entry("sqlite")];
        assert_eq!(driver_row(&drivers, "postgres"), Some(1));
        assert_eq!(driver_row(&drivers, "oracle"), None);
    }

    #[test]
    fn only_a_connection_with_a_jump_chain_is_refused_for_editing() {
        assert!(!has_jump_chain(&saved_with_ssh(None)));
        assert!(!has_jump_chain(&saved_with_ssh(Some(hop(None)))));
        assert!(has_jump_chain(&saved_with_ssh(Some(hop(Some(hop(None)))))));
    }

    #[test]
    fn a_secret_that_cannot_be_read_is_flagged_instead_of_failing_the_edit() {
        let mut unreadable = false;
        let kept = readable(Ok(Some(SecretString::new("pw".into()))), &mut unreadable);
        assert_eq!(kept.map(|s| s.expose_secret().to_string()), Some("pw".to_string()));
        assert!(!unreadable);

        assert!(readable(Ok(None), &mut unreadable).is_none());
        assert!(!unreadable);

        assert!(readable(Err(StorageError::Keyring(KeyringFailure::Unavailable)), &mut unreadable).is_none());
        assert!(unreadable);
    }

    #[test]
    fn unset_timeouts_show_zero() {
        assert_eq!(seconds_row(None), 0.0);
        assert_eq!(seconds_row(Some(45)), 45.0);
    }
}
