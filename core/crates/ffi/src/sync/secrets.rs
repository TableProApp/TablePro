// The device's secrets as TablePro Sync seals and writes them (core ADR 0044, Secrets; 0056, Envelopes and history):
// each kind the app names through the app, which writes a pulled one as this device's own item, and a connection's
// password, SSH password and key passphrase it does not name through this Core's own secret store.

use std::sync::Arc;

use async_trait::async_trait;
use secrecy::SecretString;
use tablepro_core::credentials::{SecretError, SecretKind as StoredKind, SecretLookup, SecretVault};
use tablepro_records::Kind;
use tablepro_records::envelope::SecretKind;
use tablepro_session::runtime::Tasks;
use tablepro_storage::{ConnectionStore, english_secret_label};
use tablepro_sync::api::AdapterError;
use tablepro_sync::api::secrets::{DeviceSecrets, SecretRef};

use crate::host::HostSecretError;
use crate::library::LibraryWrites;

// The secrets of synced records as TablePro Sync reads and lands them, named as ADR 0056's envelope table names them.
// A pulled secret is kept on this device only, never in iCloud Keychain (ADR 0044, iCloud Keychain), whatever the
// app's own password sync switch says at that moment. Each call may block, so the core makes it on a blocking thread.
#[uniffi::export(callback_interface)]
pub trait HostSyncedSecrets: Send + Sync {
    // The secret kinds of `parent` the app keeps here, as `ssh_password` or `password`; asked once as sync opens. A
    // kind named here goes through these calls, a connection's password, SSH password and key passphrase included;
    // those three go through `HostSecrets` only when the app leaves them out.
    fn kinds(&self, parent: SyncedSecretParentTag) -> Vec<String>;

    fn load(&self, secret: SyncedSecretRef) -> Result<Option<SecretString>, HostSecretError>;

    fn store(&self, secret: SyncedSecretRef, value: SecretString) -> Result<(), HostSecretError>;

    // Deleting a secret that is not there succeeds.
    fn delete(&self, secret: SyncedSecretRef) -> Result<(), HostSecretError>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum SyncedSecretParentTag {
    Connection,
    SshProfile,
    CredentialProfile,
}

// `parent_id` is the record's upper-case UUID text, `kind` the envelope table's name for the secret.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct SyncedSecretRef {
    pub parent: SyncedSecretParentTag,
    pub parent_id: String,
    pub kind: String,
}

const PARENTS: [(Kind, SyncedSecretParentTag); 3] = [
    (Kind::Connection, SyncedSecretParentTag::Connection),
    (Kind::SshProfile, SyncedSecretParentTag::SshProfile),
    (Kind::CredentialProfile, SyncedSecretParentTag::CredentialProfile),
];

fn tag_of(parent: Kind) -> Option<SyncedSecretParentTag> {
    PARENTS.iter().find(|(kind, _)| *kind == parent).map(|(_, tag)| *tag)
}

// The connection secrets this Core's own store keeps.
fn stored_kind(parent: Kind, secret: &SecretKind) -> Option<StoredKind> {
    match (parent, secret) {
        (Kind::Connection, SecretKind::Password) => Some(StoredKind::DatabasePassword),
        (Kind::Connection, SecretKind::SshPassword) => Some(StoredKind::SshPassword),
        (Kind::Connection, SecretKind::SshKeyPassphrase) => Some(StoredKind::SshPassphrase),
        _ => None,
    }
}

const STORE: &str = "secrets";

fn store_error(error: impl std::fmt::Display) -> AdapterError {
    AdapterError::Store {
        store: STORE.to_owned(),
        detail: error.to_string(),
    }
}

fn unkept() -> AdapterError {
    store_error("a secret this device does not keep")
}

fn secret_error(error: &SecretError) -> AdapterError {
    AdapterError::Store {
        store: STORE.to_owned(),
        detail: error.to_string(),
    }
}

// The host's secrets under the engine's trait, with the kinds it said it keeps.
struct HostKept {
    host: Arc<dyn HostSyncedSecrets>,
    kinds: Vec<(Kind, Vec<SecretKind>)>,
}

impl HostKept {
    fn new(host: Arc<dyn HostSyncedSecrets>) -> Self {
        let kinds = PARENTS
            .iter()
            .map(|(parent, tag)| {
                let kinds = host
                    .kinds(*tag)
                    .iter()
                    .filter_map(|name| SecretKind::parse(*parent, name))
                    .collect();
                (*parent, kinds)
            })
            .collect();
        Self { host, kinds }
    }

    fn keeps(&self, parent: Kind, secret: &SecretKind) -> bool {
        self.kinds
            .iter()
            .any(|(kind, kinds)| *kind == parent && kinds.contains(secret))
    }
}

fn reference(secret: &SecretRef) -> Option<SyncedSecretRef> {
    Some(SyncedSecretRef {
        parent: tag_of(secret.parent)?,
        parent_id: tablepro_records::record_id::uuid_id(secret.parent_id),
        kind: secret.secret.to_string(),
    })
}

pub(crate) struct CoreSecrets {
    vault: Arc<dyn SecretVault>,
    store: ConnectionStore,
    // The lock a library write holds while it saves a record and its secrets, which `hold` takes.
    writes: LibraryWrites,
    host: Option<HostKept>,
    tasks: Tasks,
}

impl CoreSecrets {
    pub(crate) fn new(
        vault: Arc<dyn SecretVault>,
        store: ConnectionStore,
        writes: LibraryWrites,
        host: Option<Arc<dyn HostSyncedSecrets>>,
        tasks: Tasks,
    ) -> Self {
        Self {
            vault,
            store,
            writes,
            host: host.map(HostKept::new),
            tasks,
        }
    }

    // The app's calls for a kind it named.
    fn host_for(&self, secret: &SecretRef) -> Option<(Arc<dyn HostSyncedSecrets>, SyncedSecretRef)> {
        match (&self.host, reference(secret)) {
            (Some(kept), Some(named)) if kept.keeps(secret.parent, &secret.secret) => {
                Some((Arc::clone(&kept.host), named))
            }
            _ => None,
        }
    }

    async fn on_host<T: Send + 'static>(
        &self,
        call: impl FnOnce() -> Result<T, HostSecretError> + Send + 'static,
    ) -> Result<T, AdapterError> {
        self.tasks
            .spawn_blocking_task(call)
            .await
            .map_err(store_error)?
            .map_err(store_error)
    }

    // The label the library gives the same item, so a pulled password reads in the store as one saved here does.
    async fn label(&self, secret: &SecretRef, kind: StoredKind) -> Result<String, AdapterError> {
        let store = self.store.clone();
        let id = secret.parent_id;
        let list = self
            .tasks
            .spawn_blocking_task(move || store.list_blocking())
            .await
            .map_err(store_error)?
            .map_err(store_error)?;
        let target = list
            .connections
            .iter()
            .find(|saved| saved.id == id)
            .map(|saved| saved.secret_target(kind))
            .unwrap_or_default();
        Ok(english_secret_label(kind, &target))
    }
}

#[async_trait]
impl DeviceSecrets for CoreSecrets {
    fn kinds(&self, parent: Kind) -> Vec<SecretKind> {
        let mut kinds: Vec<SecretKind> = self
            .host
            .iter()
            .flat_map(|kept| kept.kinds.iter())
            .filter(|(kind, _)| *kind == parent)
            .flat_map(|(_, kinds)| kinds.iter().cloned())
            .collect();
        if parent == Kind::Connection {
            for secret in [
                SecretKind::Password,
                SecretKind::SshPassword,
                SecretKind::SshKeyPassphrase,
            ] {
                if !kinds.contains(&secret) {
                    kinds.push(secret);
                }
            }
        }
        kinds
    }

    async fn hold(&self) -> Box<dyn Send> {
        Box::new(Arc::clone(&self.writes).lock_owned().await)
    }

    async fn load(&self, secret: &SecretRef) -> Result<Option<SecretString>, AdapterError> {
        if let Some((host, named)) = self.host_for(secret) {
            return self.on_host(move || host.load(named)).await;
        }
        if let Some(kind) = stored_kind(secret.parent, &secret.secret) {
            return match self.vault.load(secret.parent_id, kind).await {
                Ok(SecretLookup::Found(value)) => Ok(Some(value)),
                Ok(SecretLookup::NotStored) => Ok(None),
                Err(error) => Err(secret_error(&error)),
            };
        }
        Err(unkept())
    }

    async fn store(&self, secret: &SecretRef, value: &SecretString) -> Result<(), AdapterError> {
        if let Some((host, named)) = self.host_for(secret) {
            let value = value.clone();
            return self.on_host(move || host.store(named, value)).await;
        }
        if let Some(kind) = stored_kind(secret.parent, &secret.secret) {
            let label = self.label(secret, kind).await?;
            return self
                .vault
                .store(secret.parent_id, kind, value, &label)
                .await
                .map_err(|error| secret_error(&error));
        }
        Err(unkept())
    }

    async fn delete(&self, secret: &SecretRef) -> Result<(), AdapterError> {
        if let Some((host, named)) = self.host_for(secret) {
            return self.on_host(move || host.delete(named)).await;
        }
        if let Some(kind) = stored_kind(secret.parent, &secret.secret) {
            return self
                .vault
                .delete_kind(secret.parent_id, kind)
                .await
                .map_err(|error| secret_error(&error));
        }
        Err(unkept())
    }
}

#[cfg(test)]
#[path = "secrets_tests.rs"]
mod tests;
