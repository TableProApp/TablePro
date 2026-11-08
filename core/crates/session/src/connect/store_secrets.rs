use tablepro_core::credentials::{SecretError, SecretKind, SecretSave, SecretVault};
use uuid::Uuid;

// After a refusal that holds for the whole keyring, another store would only show the unlock prompt or send the portal
// request again for the same answer.
pub(crate) async fn store_secrets(
    vault: &dyn SecretVault,
    id: Uuid,
    saves: &[SecretSave],
) -> Vec<(SecretKind, SecretError)> {
    let mut refused: Vec<(SecretKind, SecretError)> = Vec::new();
    for save in saves {
        let every = refused
            .iter()
            .map(|(_, error)| error)
            .find(|error| refuses_every_secret(error))
            .cloned();
        if let Some(error) = every {
            refused.push((save.kind, error));
            continue;
        }
        if let Err(error) = vault.store(id, save.kind, &save.secret, &save.label).await {
            refused.push((save.kind, error));
        }
    }
    refused
}

// A Backend refusal can be about the one item.
fn refuses_every_secret(error: &SecretError) -> bool {
    !matches!(error, SecretError::Backend { .. } | SecretError::InvalidEncoding)
}

#[cfg(test)]
mod tests {
    use secrecy::SecretString;
    use tablepro_test_support::{Call, FakeSecretVault};

    use super::*;

    fn save(kind: SecretKind) -> SecretSave {
        SecretSave {
            kind,
            secret: SecretString::from("s3cret"),
            label: format!("{kind:?}"),
        }
    }

    fn saves() -> Vec<SecretSave> {
        vec![save(SecretKind::DatabasePassword), save(SecretKind::SshPassphrase)]
    }

    #[tokio::test]
    async fn a_locked_keyring_is_asked_once_for_the_whole_save() {
        let vault = FakeSecretVault::new();
        vault.fail_store(SecretKind::DatabasePassword, SecretError::UnlockDismissed);
        let id = Uuid::new_v4();

        let refused = store_secrets(&vault, id, &saves()).await;

        assert_eq!(vault.calls(), vec![Call::Store(id, SecretKind::DatabasePassword)]);
        assert_eq!(
            refused,
            vec![
                (SecretKind::DatabasePassword, SecretError::UnlockDismissed),
                (SecretKind::SshPassphrase, SecretError::UnlockDismissed),
            ]
        );
    }

    #[tokio::test]
    async fn an_item_the_service_refused_does_not_stop_the_next() {
        let vault = FakeSecretVault::new();
        let failure = SecretError::Backend {
            detail: "no such object".to_owned(),
            service_message: None,
        };
        vault.fail_store(SecretKind::DatabasePassword, failure.clone());
        let id = Uuid::new_v4();

        let refused = store_secrets(&vault, id, &saves()).await;

        assert_eq!(
            vault.calls(),
            vec![
                Call::Store(id, SecretKind::DatabasePassword),
                Call::Store(id, SecretKind::SshPassphrase)
            ]
        );
        assert_eq!(refused, vec![(SecretKind::DatabasePassword, failure)]);
    }
}
