use std::sync::Arc;

use async_trait::async_trait;
use secrecy::{ExposeSecret, SecretString};
use tablepro_core::AiProvider;
use tablepro_core::credentials::{SecretError, SecretItem, SecretItems, SecretKind, SecretLookup, SecretVault};
use tablepro_session::runtime::Tasks;
use uuid::Uuid;

/// What the app says about itself when it starts the core.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HostConfig {
    /// Reported to servers next to the application name.
    pub client_version: String,
    // The folder the saved connections live in. None leaves the library out.
    pub storage_dir: Option<String>,
    // Who may sign a driver library. Empty refuses every driver.
    pub driver_signers: Vec<DriverSigner>,
}

/// A certificate allowed to sign a driver library: its subject as
/// Windows writes it ("CN=TablePro, O=TablePro, C=VN"), and the SHA-256
/// of the certificate that issued it, which is its own when self-signed.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DriverSigner {
    pub subject: String,
    pub issuer_sha256: String,
}

/// The platform's secret store, which the app implements: the Windows
/// Credential Manager, the macOS keychain. Each call may block, so the
/// core makes it on a blocking thread, never on a runtime worker.
#[uniffi::export(callback_interface)]
pub trait HostSecrets: Send + Sync {
    fn load(&self, connection_id: String, kind: SecretKindTag) -> Result<Option<String>, HostSecretError>;

    fn store(
        &self,
        connection_id: String,
        kind: SecretKindTag,
        secret: String,
        label: String,
    ) -> Result<(), HostSecretError>;

    fn relabel(&self, connection_id: String, kind: SecretKindTag, label: String) -> Result<(), HostSecretError>;

    fn delete(&self, connection_id: String, kind: SecretKindTag) -> Result<(), HostSecretError>;

    fn delete_connection(&self, connection_id: String) -> Result<(), HostSecretError>;

    fn load_item(&self, item: SecretItemTag) -> Result<Option<String>, HostSecretError>;

    /// The app names the item in its own words.
    fn store_item(&self, item: SecretItemTag, secret: String) -> Result<(), HostSecretError>;

    fn delete_item(&self, item: SecretItemTag) -> Result<(), HostSecretError>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum SecretKindTag {
    DatabasePassword,
    SshPassword,
    SshPassphrase,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum SecretItemTag {
    McpToken,
    AnthropicKey,
    OpenAiKey,
    OpenAiCompatibleKey,
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

fn exposed(secret: &SecretString) -> String {
    secret.expose_secret().to_owned()
}

#[async_trait]
impl SecretVault for HostSecretStore {
    async fn store(&self, id: Uuid, kind: SecretKind, secret: &SecretString, label: &str) -> Result<(), SecretError> {
        let (secret, label) = (exposed(secret), label.to_owned());
        self.call(move |host| host.store(id.to_string(), kind.into(), secret, label))
            .await
    }

    async fn load(&self, id: Uuid, kind: SecretKind) -> Result<SecretLookup, SecretError> {
        let found = self.call(move |host| host.load(id.to_string(), kind.into())).await?;
        Ok(found.map_or(SecretLookup::NotStored, |secret| {
            SecretLookup::Found(SecretString::from(secret))
        }))
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

#[async_trait]
impl SecretItems for HostSecretStore {
    async fn load_item(&self, item: SecretItem) -> Result<Option<SecretString>, SecretError> {
        let found = self.call(move |host| host.load_item(item.into())).await?;
        Ok(found.map(SecretString::from))
    }

    async fn store_item(&self, item: SecretItem, secret: &SecretString) -> Result<(), SecretError> {
        let secret = exposed(secret);
        self.call(move |host| host.store_item(item.into(), secret)).await
    }

    async fn delete_item(&self, item: SecretItem) -> Result<(), SecretError> {
        self.call(move |host| host.delete_item(item.into())).await
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::sync::Mutex;

    use super::*;
    use crate::runtime;

    #[derive(Default)]
    struct MemorySecrets {
        stored: Mutex<HashMap<(String, SecretKindTag), (String, String)>>,
        items: Mutex<HashMap<SecretItemTag, String>>,
        locked: bool,
    }

    impl HostSecrets for MemorySecrets {
        fn load(&self, connection_id: String, kind: SecretKindTag) -> Result<Option<String>, HostSecretError> {
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
            secret: String,
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

        fn load_item(&self, item: SecretItemTag) -> Result<Option<String>, HostSecretError> {
            Ok(self.items.lock().unwrap().get(&item).cloned())
        }

        fn store_item(&self, item: SecretItemTag, secret: String) -> Result<(), HostSecretError> {
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

        assert_eq!(found.found().map(|secret| exposed(&secret)), Some("hunter2".to_owned()));
        assert!(!after_delete.is_stored());
    }

    #[tokio::test]
    async fn an_item_is_kept_apart_from_every_connection() {
        let store = store(MemorySecrets::default());
        let item = SecretItem::AiKey(AiProvider::Anthropic);

        store.store_item(item, &SecretString::from("sk-test")).await.unwrap();
        store.delete_connection(Uuid::new_v4()).await.unwrap();
        let found = store.load_item(item).await.unwrap();

        assert_eq!(found.map(|secret| exposed(&secret)), Some("sk-test".to_owned()));
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
