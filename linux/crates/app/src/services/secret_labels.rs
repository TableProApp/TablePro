use tablepro_core::credentials::SecretKind;
use tablepro_storage::SavedConnection;

/// The keyring label for a connection's secret. Seahorse shows it, so
/// it names what the secret opens in the user's own terms.
pub(crate) fn secret_label(kind: SecretKind, connection: &SavedConnection) -> String {
    label_for_target(kind, &connection.secret_target(kind))
}

/// The label for a secret whose target is already worked out, as the
/// keyring credentials hand it over when the user asks to remember a
/// secret they typed.
pub(crate) fn label_for_target(kind: SecretKind, target: &str) -> String {
    match kind {
        SecretKind::DatabasePassword => {
            crate::i18n::gettext_f("TablePro database password for {target}", &[("target", target)])
        }
        SecretKind::SshPassword => crate::i18n::gettext_f("TablePro SSH password for {target}", &[("target", target)]),
        SecretKind::SshPassphrase => {
            crate::i18n::gettext_f("TablePro SSH key passphrase for {target}", &[("target", target)])
        }
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
            tls: tablepro_core::TlsConfig::verify_full(),
            safe_mode: tablepro_core::SafeModeLevel::Off,
            external_access: tablepro_core::ExternalAccess::ReadOnly,
            ai_policy: tablepro_core::AiPolicy::Ask,
            auth_mode: AuthMode::Password,
            ssh: None,
            last_opened_at: None,
            color: None,
            group: None,
            tags: Vec::new(),
            icon: None,
            options: Default::default(),
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
            plain.secret_target(SecretKind::DatabasePassword),
            "app@db.example.com:5432/shop"
        );
        assert_eq!(
            secret_label(SecretKind::DatabasePassword, &plain),
            "TablePro database password for app@db.example.com:5432/shop"
        );

        let with_user = with_ssh(SavedSshAuth::Password, Some("deploy"));
        assert_eq!(
            with_user.secret_target(SecretKind::SshPassword),
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
            keyed.secret_target(SecretKind::SshPassphrase),
            "/home/u/.ssh/id_ed25519"
        );

        let agent = with_ssh(SavedSshAuth::Agent, Some("deploy"));
        assert_eq!(
            agent.secret_target(SecretKind::SshPassphrase),
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
            anonymous.secret_target(SecretKind::DatabasePassword),
            "db.example.com:5432/shop"
        );

        let no_ssh_user = with_ssh(SavedSshAuth::Password, None);
        assert_eq!(
            no_ssh_user.secret_target(SecretKind::SshPassword),
            "bastion.example.com"
        );

        let empty_ssh_user = with_ssh(SavedSshAuth::Password, Some(""));
        assert_eq!(
            empty_ssh_user.secret_target(SecretKind::SshPassword),
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
