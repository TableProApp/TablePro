use std::sync::Arc;

use async_trait::async_trait;
use secrecy::SecretString;
use tablepro_account::{RefreshTokenVault, RefreshTokenVaults, SignInKey};
use tablepro_core::AiProvider;
use tablepro_core::credentials::{SecretError, SecretItem, SecretItems, SecretKind, SecretLookup, SecretVault};
use tablepro_session::runtime::Tasks;
use tablepro_storage::{SecretOwner, SecretOwnerKind};
use uuid::Uuid;

/// What the app says about itself when it starts the core.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HostConfig {
    /// Reported to servers next to the application name.
    pub client_version: String,
    // The folder the saved connections live in. None leaves the library out.
    pub storage_dir: Option<String>,
}

/// The platform's secret store, which the app implements: the Windows
/// Credential Manager, the macOS keychain. Each call may block, so the
/// core makes it on a blocking thread, never on a runtime worker.
#[uniffi::export(callback_interface)]
pub trait HostSecrets: Send + Sync {
    fn load(&self, connection_id: String, kind: SecretKindTag) -> Result<Option<SecretString>, HostSecretError>;

    fn store(
        &self,
        connection_id: String,
        kind: SecretKindTag,
        secret: SecretString,
        label: String,
    ) -> Result<(), HostSecretError>;

    fn relabel(&self, connection_id: String, kind: SecretKindTag, label: String) -> Result<(), HostSecretError>;

    fn delete(&self, connection_id: String, kind: SecretKindTag) -> Result<(), HostSecretError>;

    // A library write calls it, and delete_profile, while it holds the library's lock, so neither may call the library.
    fn delete_connection(&self, connection_id: String) -> Result<(), HostSecretError>;

    // Every secret of an SSH or credential profile, which the store keeps apart from connections'. NotOwned is a host's
    // answer for secrets another app keeps, as the Mac keeps those iOS reads: the core then stops asking.
    fn delete_profile(&self, profile_id: String, kind: ProfileKindTag) -> Result<SecretDeletionTag, HostSecretError>;

    fn load_item(&self, item: SecretItemTag) -> Result<Option<SecretString>, HostSecretError>;

    /// The app names the item in its own words.
    fn store_item(&self, item: SecretItemTag, secret: SecretString) -> Result<(), HostSecretError>;

    fn delete_item(&self, item: SecretItemTag) -> Result<(), HostSecretError>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum SecretKindTag {
    DatabasePassword,
    SshPassword,
    SshPassphrase,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum ProfileKindTag {
    Ssh,
    Credential,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum SecretDeletionTag {
    Deleted,
    NotOwned,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum SecretItemTag {
    McpToken,
    AnthropicKey,
    OpenAiKey,
    OpenAiCompatibleKey,
    // tablepro.app's account refresh token, which only the account asks for (core ADR 0016). On the Mac it is the
    // Keychain item com.TablePro.account.refreshToken, which signed-in Macs already hold.
    AccountRefreshToken,
    // Another server's, one item per sign-in, so a company server's never lands in tablepro.app's (core ADR 0046).
    AccountRefreshTokenFor { sign_in_key: String },
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum HostSecretError {
    #[error("the secret store is unavailable: {detail}")]
    Unavailable { detail: String },
    #[error("the secret store is locked")]
    Locked,
    #[error("the unlock prompt was dismissed")]
    Dismissed,
    #[error("the secret store failed: {detail}")]
    Failed { detail: String },
}

impl From<uniffi::UnexpectedUniFFICallbackError> for HostSecretError {
    fn from(error: uniffi::UnexpectedUniFFICallbackError) -> Self {
        Self::Failed { detail: error.reason }
    }
}

impl From<HostSecretError> for SecretError {
    fn from(error: HostSecretError) -> Self {
        match error {
            HostSecretError::Unavailable { detail } => Self::ServiceUnavailable { detail },
            HostSecretError::Locked => Self::Locked,
            HostSecretError::Dismissed => Self::UnlockDismissed,
            HostSecretError::Failed { detail } => Self::Backend {
                detail,
                service_message: None,
            },
        }
    }
}

impl From<SecretKind> for SecretKindTag {
    fn from(kind: SecretKind) -> Self {
        match kind {
            SecretKind::DatabasePassword => Self::DatabasePassword,
            SecretKind::SshPassword => Self::SshPassword,
            SecretKind::SshPassphrase => Self::SshPassphrase,
        }
    }
}

impl From<SecretItem> for SecretItemTag {
    fn from(item: SecretItem) -> Self {
        match item {
            SecretItem::McpToken => Self::McpToken,
            SecretItem::AiKey(AiProvider::Anthropic) => Self::AnthropicKey,
            SecretItem::AiKey(AiProvider::OpenAi) => Self::OpenAiKey,
            SecretItem::AiKey(AiProvider::OpenAiCompatible) => Self::OpenAiCompatibleKey,
        }
    }
}

pub struct HostSecretStore {
    host: Arc<dyn HostSecrets>,
    tasks: Tasks,
}

impl HostSecretStore {
    pub(crate) fn new(host: Box<dyn HostSecrets>, tasks: Tasks) -> Self {
        Self {
            host: Arc::from(host),
            tasks,
        }
    }

    async fn call<T, F>(&self, call: F) -> Result<T, SecretError>
    where
        T: Send + 'static,
        F: FnOnce(&dyn HostSecrets) -> Result<T, HostSecretError> + Send + 'static,
    {
        let host = self.host.clone();
        match self.tasks.spawn_blocking_task(move || call(host.as_ref())).await {
            Ok(result) => result.map_err(SecretError::from),
            Err(failure) => Err(SecretError::Backend {
                detail: failure.to_string(),
                service_message: None,
            }),
        }
    }
}

impl std::fmt::Debug for HostSecretStore {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("HostSecretStore").finish_non_exhaustive()
    }
}

#[async_trait]
impl SecretVault for HostSecretStore {
    async fn store(&self, id: Uuid, kind: SecretKind, secret: &SecretString, label: &str) -> Result<(), SecretError> {
        let (secret, label) = (secret.clone(), label.to_owned());
        self.call(move |host| host.store(id.to_string(), kind.into(), secret, label))
            .await
    }

    async fn load(&self, id: Uuid, kind: SecretKind) -> Result<SecretLookup, SecretError> {
        let found = self.call(move |host| host.load(id.to_string(), kind.into())).await?;
        Ok(found.map_or(SecretLookup::NotStored, SecretLookup::Found))
    }

    async fn relabel(&self, id: Uuid, kind: SecretKind, label: &str) -> Result<(), SecretError> {
        let label = label.to_owned();
        self.call(move |host| host.relabel(id.to_string(), kind.into(), label))
            .await
    }

    async fn delete_kind(&self, id: Uuid, kind: SecretKind) -> Result<(), SecretError> {
        self.call(move |host| host.delete(id.to_string(), kind.into())).await
    }

    async fn delete_connection(&self, id: Uuid) -> Result<(), SecretError> {
        self.call(move |host| host.delete_connection(id.to_string())).await
    }
}

// Deletes a removed record's secrets on the calling thread: a library write calls it from the blocking thread it runs
// on, while it holds the store's lock.
pub(crate) trait SecretDeleter: Send + Sync {
    fn delete_secrets(&self, owner: SecretOwner) -> Result<SecretDeletionTag, SecretError>;
}

impl SecretDeleter for HostSecretStore {
    fn delete_secrets(&self, owner: SecretOwner) -> Result<SecretDeletionTag, SecretError> {
        let id = owner.id.to_string();
        let answered = match owner.kind {
            SecretOwnerKind::Connection => self.host.delete_connection(id).map(|()| SecretDeletionTag::Deleted),
            SecretOwnerKind::SshProfile => self.host.delete_profile(id, ProfileKindTag::Ssh),
            SecretOwnerKind::CredentialProfile => self.host.delete_profile(id, ProfileKindTag::Credential),
        };
        answered.map_err(SecretError::from)
    }
}

#[async_trait]
impl SecretItems for HostSecretStore {
    async fn load_item(&self, item: SecretItem) -> Result<Option<SecretString>, SecretError> {
        self.call(move |host| host.load_item(item.into())).await
    }

    async fn store_item(&self, item: SecretItem, secret: &SecretString) -> Result<(), SecretError> {
        let secret = secret.clone();
        self.call(move |host| host.store_item(item.into(), secret)).await
    }

    async fn delete_item(&self, item: SecretItem) -> Result<(), SecretError> {
        self.call(move |host| host.delete_item(item.into())).await
    }
}

// The host's item for each sign-in.
pub(crate) struct HostRefreshTokens(pub(crate) Arc<HostSecretStore>);

impl RefreshTokenVaults for HostRefreshTokens {
    fn vault(&self, sign_in: &SignInKey) -> Arc<dyn RefreshTokenVault> {
        let item = match sign_in.production {
            true => SecretItemTag::AccountRefreshToken,
            false => SecretItemTag::AccountRefreshTokenFor {
                sign_in_key: sign_in.key.clone(),
            },
        };
        Arc::new(HostRefreshToken {
            store: self.0.clone(),
            item,
        })
    }
}

struct HostRefreshToken {
    store: Arc<HostSecretStore>,
    item: SecretItemTag,
}

#[async_trait]
impl RefreshTokenVault for HostRefreshToken {
    async fn load_refresh_token(&self) -> Result<Option<SecretString>, SecretError> {
        let item = self.item.clone();
        self.store.call(move |host| host.load_item(item)).await
    }

    async fn store_refresh_token(&self, token: &SecretString) -> Result<(), SecretError> {
        let (item, token) = (self.item.clone(), token.clone());
        self.store.call(move |host| host.store_item(item, token)).await
    }

    async fn delete_refresh_token(&self) -> Result<(), SecretError> {
        let item = self.item.clone();
        self.store.call(move |host| host.delete_item(item)).await
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::sync::Mutex;

    use secrecy::ExposeSecret;

    use super::*;
    use crate::runtime;

    #[derive(Default)]
    struct MemorySecrets {
        stored: Mutex<HashMap<(String, SecretKindTag), (SecretString, String)>>,
        items: Mutex<HashMap<SecretItemTag, SecretString>>,
        profiles_deleted: Mutex<Vec<(String, ProfileKindTag)>>,
        locked: bool,
    }

    impl HostSecrets for MemorySecrets {
        fn load(&self, connection_id: String, kind: SecretKindTag) -> Result<Option<SecretString>, HostSecretError> {
            if self.locked {
                return Err(HostSecretError::Locked);
            }
            let stored = self.stored.lock().unwrap();
            Ok(stored.get(&(connection_id, kind)).map(|(secret, _)| secret.clone()))
        }

        fn store(
            &self,
            connection_id: String,
            kind: SecretKindTag,
            secret: SecretString,
            label: String,
        ) -> Result<(), HostSecretError> {
            self.stored
                .lock()
                .unwrap()
                .insert((connection_id, kind), (secret, label));
            Ok(())
        }

        fn relabel(&self, connection_id: String, kind: SecretKindTag, label: String) -> Result<(), HostSecretError> {
            if let Some(entry) = self.stored.lock().unwrap().get_mut(&(connection_id, kind)) {
                entry.1 = label;
            }
            Ok(())
        }

        fn delete(&self, connection_id: String, kind: SecretKindTag) -> Result<(), HostSecretError> {
            self.stored.lock().unwrap().remove(&(connection_id, kind));
            Ok(())
        }

        fn delete_connection(&self, connection_id: String) -> Result<(), HostSecretError> {
            self.stored.lock().unwrap().retain(|(id, _), _| *id != connection_id);
            Ok(())
        }

        fn delete_profile(
            &self,
            profile_id: String,
            kind: ProfileKindTag,
        ) -> Result<SecretDeletionTag, HostSecretError> {
            if self.locked {
                return Err(HostSecretError::Locked);
            }
            self.profiles_deleted.lock().unwrap().push((profile_id, kind));
            Ok(match kind {
                ProfileKindTag::Ssh => SecretDeletionTag::Deleted,
                ProfileKindTag::Credential => SecretDeletionTag::NotOwned,
            })
        }

        fn load_item(&self, item: SecretItemTag) -> Result<Option<SecretString>, HostSecretError> {
            Ok(self.items.lock().unwrap().get(&item).cloned())
        }

        fn store_item(&self, item: SecretItemTag, secret: SecretString) -> Result<(), HostSecretError> {
            self.items.lock().unwrap().insert(item, secret);
            Ok(())
        }

        fn delete_item(&self, item: SecretItemTag) -> Result<(), HostSecretError> {
            self.items.lock().unwrap().remove(&item);
            Ok(())
        }
    }

    fn store(host: MemorySecrets) -> HostSecretStore {
        HostSecretStore::new(Box::new(host), runtime::tasks().unwrap())
    }

    #[tokio::test]
    async fn a_connection_secret_goes_through_the_host_and_back() {
        let store = store(MemorySecrets::default());
        let id = Uuid::new_v4();
        let secret = SecretString::from("hunter2");

        store
            .store(id, SecretKind::DatabasePassword, &secret, "TablePro database password")
            .await
            .unwrap();
        let found = store.load(id, SecretKind::DatabasePassword).await.unwrap();
        store.delete_connection(id).await.unwrap();
        let after_delete = store.load(id, SecretKind::DatabasePassword).await.unwrap();

        assert_eq!(
            found.found().map(|secret| secret.expose_secret().to_owned()),
            Some("hunter2".to_owned())
        );
        assert!(!after_delete.is_stored());
    }

    #[test]
    fn a_removed_record_s_secrets_go_by_its_id_and_kind_and_a_locked_store_says_so() {
        let host = Arc::new(MemorySecrets::default());
        let store = HostSecretStore {
            host: host.clone(),
            tasks: runtime::tasks().unwrap(),
        };
        let id = Uuid::new_v4();
        host.stored.lock().unwrap().insert(
            (id.to_string(), SecretKindTag::DatabasePassword),
            (SecretString::from("connection"), String::new()),
        );

        let answer = store
            .delete_secrets(SecretOwner::new(SecretOwnerKind::CredentialProfile, id))
            .unwrap();
        let connection_kept = !host.stored.lock().unwrap().is_empty();
        let connection = store
            .delete_secrets(SecretOwner::new(SecretOwnerKind::Connection, id))
            .unwrap();
        let locked = HostSecretStore::new(
            Box::new(MemorySecrets {
                locked: true,
                ..MemorySecrets::default()
            }),
            runtime::tasks().unwrap(),
        )
        .delete_secrets(SecretOwner::new(SecretOwnerKind::SshProfile, id));

        assert!(connection_kept, "a profile's delete took a connection's secret");
        assert_eq!(connection, SecretDeletionTag::Deleted);
        assert!(host.stored.lock().unwrap().is_empty());

        assert_eq!(answer, SecretDeletionTag::NotOwned, "the host's own answer comes back");
        assert_eq!(
            *host.profiles_deleted.lock().unwrap(),
            [(id.to_string(), ProfileKindTag::Credential)]
        );
        assert!(matches!(locked, Err(SecretError::Locked)), "{locked:?}");
    }

    #[tokio::test]
    async fn an_item_is_kept_apart_from_every_connection() {
        let store = store(MemorySecrets::default());
        let item = SecretItem::AiKey(AiProvider::Anthropic);

        store.store_item(item, &SecretString::from("sk-test")).await.unwrap();
        store.delete_connection(Uuid::new_v4()).await.unwrap();
        let found = store.load_item(item).await.unwrap();

        assert_eq!(
            found.map(|secret| secret.expose_secret().to_owned()),
            Some("sk-test".to_owned())
        );
    }

    #[tokio::test]
    async fn the_account_s_refresh_token_is_an_item_of_its_own() {
        let store = Arc::new(store(MemorySecrets::default()));
        let ai = SecretItem::AiKey(AiProvider::Anthropic);
        store.store_item(ai, &SecretString::from("sk-test")).await.unwrap();
        let production = HostRefreshTokens(store.clone()).vault(&SignInKey {
            key: "e6989de2b8e8cbc0".to_owned(),
            production: true,
        });

        production
            .store_refresh_token(&SecretString::from("refresh"))
            .await
            .unwrap();
        let found = production.load_refresh_token().await.unwrap();
        production.delete_refresh_token().await.unwrap();
        let gone = production.load_refresh_token().await.unwrap();
        let kept = store.load_item(ai).await.unwrap();

        assert_eq!(
            found.map(|token| token.expose_secret().to_owned()),
            Some("refresh".to_owned())
        );
        assert!(gone.is_none());
        assert_eq!(
            kept.map(|secret| secret.expose_secret().to_owned()),
            Some("sk-test".to_owned())
        );
    }

    #[tokio::test]
    async fn tablepro_app_keeps_its_fixed_item_and_another_server_one_by_its_sign_in_key() {
        let host = MemorySecrets::default();
        let store = Arc::new(store(host));
        let vaults = HostRefreshTokens(store.clone());
        let production = vaults.vault(&SignInKey {
            key: "e6989de2b8e8cbc0".to_owned(),
            production: true,
        });
        let company = vaults.vault(&SignInKey {
            key: "0123456789abcdef".to_owned(),
            production: false,
        });

        production
            .store_refresh_token(&SecretString::from("tablepro"))
            .await
            .unwrap();
        company
            .store_refresh_token(&SecretString::from("company"))
            .await
            .unwrap();
        let fixed = store
            .call(|host| host.load_item(SecretItemTag::AccountRefreshToken))
            .await
            .unwrap();
        let keyed = store
            .call(|host| {
                host.load_item(SecretItemTag::AccountRefreshTokenFor {
                    sign_in_key: "0123456789abcdef".to_owned(),
                })
            })
            .await
            .unwrap();

        assert_eq!(
            fixed.map(|token| token.expose_secret().to_owned()).as_deref(),
            Some("tablepro")
        );
        assert_eq!(
            keyed.map(|token| token.expose_secret().to_owned()).as_deref(),
            Some("company")
        );
    }

    #[tokio::test]
    async fn the_host_s_refusal_reaches_the_core_as_its_secret_error() {
        let store = store(MemorySecrets {
            locked: true,
            ..MemorySecrets::default()
        });

        let error = store.load(Uuid::new_v4(), SecretKind::SshPassword).await.unwrap_err();

        assert_eq!(error, SecretError::Locked);
        assert!(error.is_retryable());
    }
}
