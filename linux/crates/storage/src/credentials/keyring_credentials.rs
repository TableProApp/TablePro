use std::path::PathBuf;
use std::sync::Arc;

use secrecy::{ExposeSecret, SecretString};
use tablepro_core::credentials::{
    CredentialInteraction, CredentialPrompt, CredentialPrompter, PromptField, PromptPurpose, PromptReason, PromptReply,
    SecretError, SecretKind, SecretLookup, SecretSave, SecretVault,
};
use uuid::Uuid;

use super::{CredentialDemand, CredentialError, KeyringError, ResolvedSecret, SecretLabeler, english_secret_label};
use crate::SavedConnection;

/// A saved connection's secrets, read from the keyring at each connect.
///
/// Reading at connect time rather than once at startup is what lets a
/// user fix a password in Seahorse, press Retry, and get in. When the
/// keyring cannot help and someone is there to ask, it asks.
#[derive(Clone)]
pub struct KeyringCredentials {
    secrets: Arc<dyn SecretVault>,
    connection_id: Uuid,
    passphrase_stored: bool,
    targets: [String; 3],
    key_path: Option<PathBuf>,
    labeler: SecretLabeler,
    session_only: Vec<SecretKind>,
}

impl KeyringCredentials {
    pub fn for_saved(secrets: Arc<dyn SecretVault>, saved: &SavedConnection) -> Self {
        Self {
            secrets,
            connection_id: saved.id,
            passphrase_stored: saved.has_stored_passphrase(),
            targets: SecretKind::ALL.map(|kind| saved.secret_target(kind)),
            key_path: saved.ssh_key_path().map(PathBuf::from),
            labeler: english_secret_label,
            session_only: Vec::new(),
        }
    }

    /// For a session that logged in with secrets of `kinds` the user
    /// typed and the keyring does not hold. Its reconnects use the one
    /// in use: the keyring's copy may be the one the server refused.
    pub fn keeping_session_secrets(mut self, kinds: &[SecretKind]) -> Self {
        self.session_only = kinds.to_vec();
        self
    }

    /// Label remembered secrets with the app's own, translated wording.
    pub fn with_labeler(mut self, labeler: SecretLabeler) -> Self {
        self.labeler = labeler;
        self
    }

    pub fn connection_id(&self) -> Uuid {
        self.connection_id
    }

    pub fn secrets(&self) -> &Arc<dyn SecretVault> {
        &self.secrets
    }

    /// The secret of `kind` to log in with.
    ///
    /// `in_use` is what the connection already holds, from an earlier
    /// prompt in this session; it is kept when nothing is stored, so a
    /// reconnect does not ask for a password that just worked. `None`
    /// means the connection has no such secret to offer: an SSH key the
    /// record says has no stored passphrase, which ssh asks for itself.
    pub async fn resolve(
        &self,
        kind: SecretKind,
        in_use: Option<&SecretString>,
        interaction: &CredentialInteraction,
        demand: CredentialDemand,
    ) -> Result<Option<ResolvedSecret>, CredentialError> {
        if demand.reenter == Some(kind)
            && let CredentialInteraction::Attended(prompter) = interaction
        {
            return self.ask(prompter, kind, PromptReason::Rejected, true).await.map(Some);
        }
        if self.session_only.contains(&kind)
            && let Some(secret) = in_use.filter(|secret| !secret.expose_secret().is_empty())
        {
            return Ok(Some(ResolvedSecret::known(secret.clone())));
        }
        if kind == SecretKind::SshPassphrase && !self.passphrase_stored {
            return Ok(None);
        }
        match self.secrets.load(self.connection_id, kind).await {
            Ok(SecretLookup::Found(secret)) => Ok(Some(ResolvedSecret::known(secret))),
            Ok(SecretLookup::NotStored) => {
                if let Some(secret) = in_use.filter(|secret| !secret.expose_secret().is_empty()) {
                    return Ok(Some(ResolvedSecret::known(secret.clone())));
                }
                match interaction {
                    CredentialInteraction::Attended(prompter) => {
                        self.ask(prompter, kind, PromptReason::NotStored, true).await.map(Some)
                    }
                    CredentialInteraction::Unattended => Err(KeyringError::SecretNotStored { kind }.into()),
                }
            }
            Err(error) => match (interaction, prompt_reason(&error)) {
                (CredentialInteraction::Attended(prompter), Some((reason, offer_remember))) => {
                    self.ask(prompter, kind, reason, offer_remember).await.map(Some)
                }
                _ => Err(KeyringError::Secret { kind, error }.into()),
            },
        }
    }

    async fn ask(
        &self,
        prompter: &Arc<dyn CredentialPrompter>,
        kind: SecretKind,
        reason: PromptReason,
        offer_remember: bool,
    ) -> Result<ResolvedSecret, CredentialError> {
        let target = self.target(kind).to_owned();
        let (purpose, label) = match kind {
            SecretKind::DatabasePassword => (PromptPurpose::DatabasePassword { reason }, "Password"),
            SecretKind::SshPassword => (PromptPurpose::SshPassword { reason }, "Password"),
            SecretKind::SshPassphrase => (
                PromptPurpose::SshPassphrase {
                    path: self.key_path.clone().unwrap_or_default(),
                    reason,
                },
                "Passphrase",
            ),
        };
        let request = CredentialPrompt {
            purpose,
            target: target.clone(),
            fields: vec![PromptField {
                label: label.to_owned(),
                secret: true,
            }],
            offer_remember,
        };
        let PromptReply::Submitted { values, remember } = prompter.prompt(request).await else {
            return Err(CredentialError::Cancelled);
        };
        let Some(secret) = values.into_iter().next() else {
            return Err(CredentialError::Cancelled);
        };
        let remember = (remember && offer_remember).then(|| SecretSave {
            kind,
            secret: secret.clone(),
            label: (self.labeler)(kind, &target),
        });
        Ok(ResolvedSecret {
            secret,
            remember,
            typed: true,
        })
    }

    fn target(&self, kind: SecretKind) -> &str {
        let index = SecretKind::ALL
            .iter()
            .position(|candidate| *candidate == kind)
            .unwrap_or(0);
        &self.targets[index]
    }
}

impl std::fmt::Debug for KeyringCredentials {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("KeyringCredentials")
            .field("connection_id", &self.connection_id)
            .field("passphrase_stored", &self.passphrase_stored)
            .field("session_only", &self.session_only)
            .finish_non_exhaustive()
    }
}

/// Which keyring failures a person can get past by typing the secret,
/// and whether remembering it afterwards can work. A missing service
/// cannot store anything, so it does not offer to.
fn prompt_reason(error: &SecretError) -> Option<(PromptReason, bool)> {
    match error {
        SecretError::Locked | SecretError::UnlockDismissed => Some((PromptReason::KeyringLocked, true)),
        SecretError::ServiceUnavailable { detail } | SecretError::PortalUnavailable { detail } => {
            Some((PromptReason::KeyringUnavailable { detail: detail.clone() }, false))
        }
        SecretError::InvalidEncoding | SecretError::Backend { .. } => None,
    }
}

#[cfg(test)]
mod tests {
    use std::collections::{HashMap, VecDeque};
    use std::future::Future;
    use std::pin::Pin;
    use std::sync::Mutex;

    use async_trait::async_trait;
    use tablepro_core::{AuthMode, TlsConfig};

    use super::*;
    use crate::{SavedSshAuth, SavedSshConfig};

    /// A keyring that answers from a map, failing loads of one kind on
    /// request and counting every load.
    #[derive(Default)]
    struct Vault {
        stored: Mutex<HashMap<SecretKind, String>>,
        failing: Mutex<HashMap<SecretKind, SecretError>>,
        loads: Mutex<Vec<SecretKind>>,
    }

    impl Vault {
        fn holding(kind: SecretKind, secret: &str) -> Self {
            let vault = Self::default();
            vault.stored.lock().unwrap().insert(kind, secret.to_owned());
            vault
        }

        fn failing(kind: SecretKind, error: SecretError) -> Self {
            let vault = Self::default();
            vault.failing.lock().unwrap().insert(kind, error);
            vault
        }

        fn loads(&self) -> Vec<SecretKind> {
            self.loads.lock().unwrap().clone()
        }
    }

    #[async_trait]
    impl SecretVault for Vault {
        async fn store(&self, _: Uuid, kind: SecretKind, secret: &SecretString, _: &str) -> Result<(), SecretError> {
            self.stored
                .lock()
                .unwrap()
                .insert(kind, secret.expose_secret().to_owned());
            Ok(())
        }

        async fn load(&self, _: Uuid, kind: SecretKind) -> Result<SecretLookup, SecretError> {
            self.loads.lock().unwrap().push(kind);
            if let Some(error) = self.failing.lock().unwrap().get(&kind) {
                return Err(error.clone());
            }
            Ok(match self.stored.lock().unwrap().get(&kind) {
                Some(secret) => SecretLookup::Found(SecretString::from(secret.clone())),
                None => SecretLookup::NotStored,
            })
        }

        async fn relabel(&self, _: Uuid, _: SecretKind, _: &str) -> Result<(), SecretError> {
            Ok(())
        }

        async fn delete_kind(&self, _: Uuid, kind: SecretKind) -> Result<(), SecretError> {
            self.stored.lock().unwrap().remove(&kind);
            Ok(())
        }

        async fn delete_connection(&self, _: Uuid) -> Result<(), SecretError> {
            self.stored.lock().unwrap().clear();
            Ok(())
        }
    }

    #[derive(Default)]
    struct Prompter {
        replies: Mutex<VecDeque<PromptReply>>,
        requests: Mutex<Vec<CredentialPrompt>>,
    }

    impl Prompter {
        fn answering(replies: impl IntoIterator<Item = PromptReply>) -> Arc<Self> {
            Arc::new(Self {
                replies: Mutex::new(replies.into_iter().collect()),
                requests: Mutex::default(),
            })
        }

        fn requests(&self) -> Vec<CredentialPrompt> {
            self.requests.lock().unwrap().clone()
        }
    }

    impl CredentialPrompter for Prompter {
        fn prompt(&self, request: CredentialPrompt) -> Pin<Box<dyn Future<Output = PromptReply> + Send + 'static>> {
            self.requests.lock().unwrap().push(request);
            let reply = self
                .replies
                .lock()
                .unwrap()
                .pop_front()
                .unwrap_or(PromptReply::Cancelled);
            Box::pin(async move { reply })
        }
    }

    fn typed(secret: &str, remember: bool) -> PromptReply {
        PromptReply::Submitted {
            values: vec![SecretString::from(secret)],
            remember,
        }
    }

    fn saved(ssh: Option<SavedSshAuth>) -> SavedConnection {
        SavedConnection {
            id: Uuid::new_v4(),
            name: "Prod".to_owned(),
            driver_id: "postgres".to_owned(),
            host: "db.example.com".to_owned(),
            port: 5432,
            database: "shop".to_owned(),
            username: "app".to_owned(),
            tls: TlsConfig::verify_full(),
            safe_mode: tablepro_core::SafeModeLevel::Off,
            external_access: tablepro_core::ExternalAccess::ReadOnly,
            ai_policy: tablepro_core::AiPolicy::Ask,
            auth_mode: AuthMode::Password,
            ssh: ssh.map(|auth| SavedSshConfig {
                host: "bastion.example.com".to_owned(),
                port: None,
                username: Some("deploy".to_owned()),
                jump_hosts: Vec::new(),
                auth,
            }),
            last_opened_at: None,
            color: None,
            group: None,
            tags: Vec::new(),
            icon: None,
            options: Default::default(),
        }
    }

    fn credentials(vault: Vault, ssh: Option<SavedSshAuth>) -> (KeyringCredentials, Arc<Vault>) {
        let vault = Arc::new(vault);
        (KeyringCredentials::for_saved(vault.clone(), &saved(ssh)), vault)
    }

    fn attended(prompter: &Arc<Prompter>) -> CredentialInteraction {
        CredentialInteraction::Attended(prompter.clone())
    }

    async fn resolve(
        credentials: &KeyringCredentials,
        kind: SecretKind,
        interaction: &CredentialInteraction,
    ) -> Result<Option<ResolvedSecret>, CredentialError> {
        credentials
            .resolve(kind, None, interaction, CredentialDemand::default())
            .await
    }

    #[tokio::test]
    async fn keyring_credentials_found_injects_secret() {
        let (credentials, _) = credentials(Vault::holding(SecretKind::DatabasePassword, "s3cret"), None);

        let resolved = resolve(
            &credentials,
            SecretKind::DatabasePassword,
            &CredentialInteraction::Unattended,
        )
        .await
        .unwrap()
        .unwrap();

        assert_eq!(resolved.secret.expose_secret(), "s3cret");
        assert!(resolved.remember.is_none());
        assert!(!resolved.typed);
    }

    #[tokio::test]
    async fn keyring_credentials_not_stored_is_error_not_empty_password() {
        let (credentials, _) = credentials(Vault::default(), None);

        let refused = resolve(
            &credentials,
            SecretKind::DatabasePassword,
            &CredentialInteraction::Unattended,
        )
        .await;

        assert_eq!(
            refused.unwrap_err(),
            CredentialError::Keyring(KeyringError::SecretNotStored {
                kind: SecretKind::DatabasePassword
            })
        );
    }

    #[tokio::test]
    async fn storage_error_propagates_as_keyring() {
        let (credentials, _) = credentials(Vault::failing(SecretKind::SshPassword, SecretError::Locked), None);

        let refused = resolve(
            &credentials,
            SecretKind::SshPassword,
            &CredentialInteraction::Unattended,
        )
        .await;

        assert_eq!(
            refused.unwrap_err(),
            CredentialError::Keyring(KeyringError::Secret {
                kind: SecretKind::SshPassword,
                error: SecretError::Locked,
            })
        );
    }

    #[tokio::test]
    async fn found_secret_no_prompt() {
        let prompter = Prompter::answering([]);
        let (credentials, _) = credentials(Vault::holding(SecretKind::DatabasePassword, "s3cret"), None);

        resolve(&credentials, SecretKind::DatabasePassword, &attended(&prompter))
            .await
            .unwrap();

        assert!(prompter.requests().is_empty());
    }

    #[tokio::test]
    async fn not_stored_attended_prompts_once_and_returns_remember() {
        let prompter = Prompter::answering([typed("typed", true)]);
        let (credentials, _) = credentials(Vault::default(), None);

        let resolved = resolve(&credentials, SecretKind::DatabasePassword, &attended(&prompter))
            .await
            .unwrap()
            .unwrap();

        assert_eq!(resolved.secret.expose_secret(), "typed");
        assert!(resolved.typed);
        let requests = prompter.requests();
        assert_eq!(requests.len(), 1);
        assert_eq!(
            requests[0].purpose,
            PromptPurpose::DatabasePassword {
                reason: PromptReason::NotStored
            }
        );
        assert_eq!(requests[0].target, "app@db.example.com:5432/shop");
        assert!(requests[0].offer_remember);
        assert!(requests[0].fields.iter().all(|field| field.secret));
        let remember = resolved.remember.unwrap();
        assert_eq!(remember.kind, SecretKind::DatabasePassword);
        assert_eq!(remember.secret.expose_secret(), "typed");
        assert_eq!(
            remember.label,
            "TablePro database password for app@db.example.com:5432/shop"
        );
    }

    #[tokio::test]
    async fn a_typed_secret_is_not_remembered_unless_asked() {
        let prompter = Prompter::answering([typed("typed", false)]);
        let (credentials, _) = credentials(Vault::default(), None);

        let resolved = resolve(&credentials, SecretKind::DatabasePassword, &attended(&prompter))
            .await
            .unwrap()
            .unwrap();

        assert!(resolved.remember.is_none());
    }

    #[tokio::test]
    async fn locked_attended_prompt_reason_keyring_locked() {
        let prompter = Prompter::answering([typed("typed", true)]);
        let (credentials, _) = credentials(
            Vault::failing(SecretKind::DatabasePassword, SecretError::UnlockDismissed),
            None,
        );

        resolve(&credentials, SecretKind::DatabasePassword, &attended(&prompter))
            .await
            .unwrap();

        let requests = prompter.requests();
        assert_eq!(
            requests[0].purpose,
            PromptPurpose::DatabasePassword {
                reason: PromptReason::KeyringLocked
            }
        );
        assert!(requests[0].offer_remember);
    }

    #[tokio::test]
    async fn service_unavailable_prompt_without_remember() {
        let prompter = Prompter::answering([typed("typed", true)]);
        let unavailable = SecretError::ServiceUnavailable {
            detail: "no service".to_owned(),
        };
        let (credentials, _) = credentials(Vault::failing(SecretKind::DatabasePassword, unavailable), None);

        let resolved = resolve(&credentials, SecretKind::DatabasePassword, &attended(&prompter))
            .await
            .unwrap()
            .unwrap();

        let requests = prompter.requests();
        assert_eq!(
            requests[0].purpose,
            PromptPurpose::DatabasePassword {
                reason: PromptReason::KeyringUnavailable {
                    detail: "no service".to_owned()
                }
            }
        );
        assert!(!requests[0].offer_remember);
        assert!(
            resolved.remember.is_none(),
            "a secret was kept with no keyring to keep it in"
        );
    }

    #[tokio::test]
    async fn a_backend_error_is_reported_even_when_someone_could_type() {
        let prompter = Prompter::answering([typed("typed", true)]);
        let backend = SecretError::Backend {
            detail: "broken".to_owned(),
            service_message: None,
        };
        let (credentials, _) = credentials(Vault::failing(SecretKind::DatabasePassword, backend.clone()), None);

        let refused = resolve(&credentials, SecretKind::DatabasePassword, &attended(&prompter)).await;

        assert_eq!(
            refused.unwrap_err(),
            CredentialError::Keyring(KeyringError::Secret {
                kind: SecretKind::DatabasePassword,
                error: backend,
            })
        );
        assert!(prompter.requests().is_empty());
    }

    #[tokio::test]
    async fn cancel_is_connect_cancelled() {
        let prompter = Prompter::answering([PromptReply::Cancelled]);
        let (credentials, _) = credentials(Vault::default(), None);

        let refused = resolve(&credentials, SecretKind::DatabasePassword, &attended(&prompter)).await;

        assert_eq!(refused.unwrap_err(), CredentialError::Cancelled);
    }

    #[tokio::test]
    async fn reenter_skips_keyring_even_when_found() {
        let prompter = Prompter::answering([typed("new", true)]);
        let (credentials, vault) = credentials(Vault::holding(SecretKind::DatabasePassword, "old"), None);

        let resolved = credentials
            .resolve(
                SecretKind::DatabasePassword,
                None,
                &attended(&prompter),
                CredentialDemand::reenter(SecretKind::DatabasePassword),
            )
            .await
            .unwrap()
            .unwrap();

        assert_eq!(resolved.secret.expose_secret(), "new");
        assert!(vault.loads().is_empty(), "the refused secret was read again");
        assert_eq!(
            prompter.requests()[0].purpose,
            PromptPurpose::DatabasePassword {
                reason: PromptReason::Rejected
            }
        );
    }

    #[tokio::test]
    async fn a_secret_typed_for_the_session_wins_over_the_stored_copy() {
        let (credentials, vault) = credentials(Vault::holding(SecretKind::DatabasePassword, "refused"), None);
        let credentials = credentials.keeping_session_secrets(&[SecretKind::DatabasePassword]);
        let in_use = SecretString::from("typed");

        let resolved = credentials
            .resolve(
                SecretKind::DatabasePassword,
                Some(&in_use),
                &CredentialInteraction::Unattended,
                CredentialDemand::default(),
            )
            .await
            .unwrap()
            .unwrap();

        assert_eq!(resolved.secret.expose_secret(), "typed");
        assert!(vault.loads().is_empty(), "the stored copy was read");
    }

    #[tokio::test]
    async fn other_kinds_still_come_from_the_keyring() {
        let (credentials, _) = credentials(
            Vault::holding(SecretKind::SshPassword, "stored"),
            Some(SavedSshAuth::Password),
        );
        let credentials = credentials.keeping_session_secrets(&[SecretKind::DatabasePassword]);
        let in_use = SecretString::from("typed");

        let resolved = credentials
            .resolve(
                SecretKind::SshPassword,
                Some(&in_use),
                &CredentialInteraction::Unattended,
                CredentialDemand::default(),
            )
            .await
            .unwrap()
            .unwrap();

        assert_eq!(resolved.secret.expose_secret(), "stored");
    }

    #[tokio::test]
    async fn not_stored_keeps_the_secret_already_in_use() {
        let (credentials, _) = credentials(Vault::default(), None);
        let in_use = SecretString::from("typed earlier");

        let resolved = credentials
            .resolve(
                SecretKind::DatabasePassword,
                Some(&in_use),
                &CredentialInteraction::Unattended,
                CredentialDemand::default(),
            )
            .await
            .unwrap()
            .unwrap();

        assert_eq!(resolved.secret.expose_secret(), "typed earlier");
    }

    #[tokio::test]
    async fn an_empty_secret_in_use_is_not_kept() {
        let (credentials, _) = credentials(Vault::default(), None);
        let placeholder = SecretString::from("");

        let refused = credentials
            .resolve(
                SecretKind::DatabasePassword,
                Some(&placeholder),
                &CredentialInteraction::Unattended,
                CredentialDemand::default(),
            )
            .await;

        assert!(matches!(
            refused,
            Err(CredentialError::Keyring(KeyringError::SecretNotStored { .. }))
        ));
    }

    #[tokio::test]
    async fn a_passphrase_the_record_does_not_hold_is_left_to_ssh() {
        let key = SavedSshAuth::PrivateKey {
            path: Some(PathBuf::from("/home/u/.ssh/id_ed25519")),
            has_passphrase: false,
        };
        let (credentials, vault) = credentials(Vault::default(), Some(key));

        let resolved = resolve(
            &credentials,
            SecretKind::SshPassphrase,
            &CredentialInteraction::Unattended,
        )
        .await
        .unwrap();

        assert!(resolved.is_none());
        assert!(vault.loads().is_empty(), "the keyring was asked for nothing");
    }

    #[tokio::test]
    async fn a_stored_passphrase_prompt_names_the_key_file() {
        let key = SavedSshAuth::PrivateKey {
            path: Some(PathBuf::from("/home/u/.ssh/id_ed25519")),
            has_passphrase: true,
        };
        let prompter = Prompter::answering([typed("phrase", true)]);
        let (credentials, _) = credentials(Vault::default(), Some(key));

        let resolved = resolve(&credentials, SecretKind::SshPassphrase, &attended(&prompter))
            .await
            .unwrap()
            .unwrap();

        assert_eq!(resolved.secret.expose_secret(), "phrase");
        let request = &prompter.requests()[0];
        assert_eq!(
            request.purpose,
            PromptPurpose::SshPassphrase {
                path: PathBuf::from("/home/u/.ssh/id_ed25519"),
                reason: PromptReason::NotStored
            }
        );
        assert_eq!(request.target, "/home/u/.ssh/id_ed25519");
    }

    #[tokio::test]
    async fn a_custom_labeler_names_remembered_secrets() {
        let prompter = Prompter::answering([typed("typed", true)]);
        let (credentials, _) = credentials(Vault::default(), Some(SavedSshAuth::Password));
        let credentials = credentials.with_labeler(|kind, target| format!("{kind:?} {target}"));

        let resolved = resolve(&credentials, SecretKind::SshPassword, &attended(&prompter))
            .await
            .unwrap()
            .unwrap();

        assert_eq!(
            resolved.remember.unwrap().label,
            "SshPassword deploy@bastion.example.com"
        );
    }
}
