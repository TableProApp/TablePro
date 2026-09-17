use tablepro_core::credentials::SecretKind;
use tablepro_storage::SavedConnection;

/// What the secret belongs to, in the user's own terms. This is what
/// Seahorse and GNOME Settings show, so it has to identify the
/// connection without the user opening TablePro.
pub(crate) fn secret_target(kind: SecretKind, connection: &SavedConnection) -> String {
    match kind {
        SecretKind::DatabasePassword => database_target(connection),
        SecretKind::SshPassword => ssh_target(connection),
        SecretKind::SshPassphrase => passphrase_target(connection),
    }
}

pub(crate) fn secret_label(kind: SecretKind, connection: &SavedConnection) -> String {
    let target = secret_target(kind, connection);
    match kind {
        SecretKind::DatabasePassword => {
            crate::i18n::gettext_f("TablePro database password for {target}", &[("target", &target)])
        }
        SecretKind::SshPassword => crate::i18n::gettext_f("TablePro SSH password for {target}", &[("target", &target)]),
        SecretKind::SshPassphrase => {
            crate::i18n::gettext_f("TablePro SSH key passphrase for {target}", &[("target", &target)])
        }
    }
}

fn database_target(connection: &SavedConnection) -> String {
    let mut target = String::new();
    if !connection.username.is_empty() {
        target.push_str(&connection.username);
        target.push('@');
    }
    target.push_str(&connection.host);
    target.push(':');
    target.push_str(&connection.port.to_string());
    if !connection.database.is_empty() {
        target.push('/');
        target.push_str(&connection.database);
    }
    target
}

fn ssh_target(connection: &SavedConnection) -> String {
    let Some(ssh) = &connection.ssh else {
        return connection.host.clone();
    };
    match ssh.username.as_deref().filter(|user| !user.is_empty()) {
        Some(user) => format!("{user}@{}", ssh.host),
        None => ssh.host.clone(),
    }
}

/// A passphrase belongs to a key file, so the path identifies it better
/// than the host does. Without a path the key comes from the agent or
/// the SSH config, and the host is all there is.
fn passphrase_target(connection: &SavedConnection) -> String {
    let path = connection.ssh.as_ref().and_then(|ssh| match &ssh.auth {
        tablepro_storage::SavedSshAuth::PrivateKey { path, .. } => path.as_ref(),
        _ => None,
    });
    match path {
        Some(path) => path.display().to_string(),
        None => ssh_target(connection),
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use tablepro_core::AuthMode;
    use tablepro_storage::{SavedSshAuth, SavedSshConfig};
    use uuid::Uuid;

    use super::*;

    fn connection() -> SavedConnection {
        SavedConnection {
            id: Uuid::nil(),
            name: "Prod".into(),
            driver_id: "postgres".into(),
            host: "db.example.com".into(),
            port: 5432,
            database: "shop".into(),
            username: "app".into(),
            use_tls: true,
            read_only: false,
            auth_mode: AuthMode::Password,
            ssh: None,
            last_opened_at: None,
            color: None,
            group: None,
        }
    }

    fn with_ssh(auth: SavedSshAuth, username: Option<&str>) -> SavedConnection {
        SavedConnection {
            ssh: Some(SavedSshConfig {
                host: "bastion.example.com".into(),
                port: None,
                username: username.map(str::to_owned),
                jump_hosts: Vec::new(),
                auth,
            }),
            ..connection()
        }
    }

    #[test]
    fn secret_label_and_target_per_kind() {
        let plain = connection();
        assert_eq!(
            secret_target(SecretKind::DatabasePassword, &plain),
            "app@db.example.com:5432/shop"
        );
        assert_eq!(
            secret_label(SecretKind::DatabasePassword, &plain),
            "TablePro database password for app@db.example.com:5432/shop"
        );

        let with_user = with_ssh(SavedSshAuth::Password, Some("deploy"));
        assert_eq!(
            secret_target(SecretKind::SshPassword, &with_user),
            "deploy@bastion.example.com"
        );

        let keyed = with_ssh(
            SavedSshAuth::PrivateKey {
                path: Some(PathBuf::from("/home/u/.ssh/id_ed25519")),
                has_passphrase: true,
            },
            Some("deploy"),
        );
        assert_eq!(
            secret_target(SecretKind::SshPassphrase, &keyed),
            "/home/u/.ssh/id_ed25519"
        );

        let agent = with_ssh(SavedSshAuth::Agent, Some("deploy"));
        assert_eq!(
            secret_target(SecretKind::SshPassphrase, &agent),
            "deploy@bastion.example.com"
        );
    }

    #[test]
    fn an_empty_user_is_left_out_of_the_target() {
        let anonymous = SavedConnection {
            username: String::new(),
            ..connection()
        };
        assert_eq!(
            secret_target(SecretKind::DatabasePassword, &anonymous),
            "db.example.com:5432/shop"
        );

        let no_ssh_user = with_ssh(SavedSshAuth::Password, None);
        assert_eq!(
            secret_target(SecretKind::SshPassword, &no_ssh_user),
            "bastion.example.com"
        );

        let empty_ssh_user = with_ssh(SavedSshAuth::Password, Some(""));
        assert_eq!(
            secret_target(SecretKind::SshPassword, &empty_ssh_user),
            "bastion.example.com"
        );
    }

    #[test]
    fn every_kind_has_a_distinct_label() {
        let keyed = with_ssh(
            SavedSshAuth::PrivateKey {
                path: Some(PathBuf::from("/home/u/.ssh/id_ed25519")),
                has_passphrase: true,
            },
            Some("deploy"),
        );
        let labels: std::collections::HashSet<String> = SecretKind::ALL
            .into_iter()
            .map(|kind| secret_label(kind, &keyed))
            .collect();

        assert_eq!(labels.len(), 3, "two kinds share a label: {labels:?}");
    }
}
