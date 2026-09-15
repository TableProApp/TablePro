use std::collections::HashMap;
use std::sync::Mutex;

use async_trait::async_trait;
use secrecy::{ExposeSecret, SecretString};
use tablepro_core::credentials::{SecretError, SecretKind, SecretLookup, SecretVault};
use uuid::Uuid;

/// An in-memory vault for tests. It can be told to fail a given kind, so
/// the save flow's failure paths are exercised without a keyring.
#[derive(Default)]
pub struct FakeSecretVault {
    state: Mutex<State>,
}

#[derive(Default)]
struct State {
    secrets: HashMap<(Uuid, SecretKind), StoredSecret>,
    fail_store: HashMap<SecretKind, SecretError>,
    fail_delete_connection: Option<SecretError>,
    calls: Vec<Call>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct StoredSecret {
    secret: String,
    label: String,
}

/// What the vault was asked to do, in order, so a test can assert the
/// secrets were written before the list.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Call {
    Store(Uuid, SecretKind),
    Load(Uuid, SecretKind),
    Relabel(Uuid, SecretKind),
    DeleteKind(Uuid, SecretKind),
    DeleteConnection(Uuid),
}

impl FakeSecretVault {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn fail_store(&self, kind: SecretKind, error: SecretError) {
        self.lock().fail_store.insert(kind, error);
    }

    pub fn fail_delete_connection(&self, error: SecretError) {
        self.lock().fail_delete_connection = Some(error);
    }

    pub fn calls(&self) -> Vec<Call> {
        self.lock().calls.clone()
    }

    pub fn stored_label(&self, id: Uuid, kind: SecretKind) -> Option<String> {
        self.lock().secrets.get(&(id, kind)).map(|stored| stored.label.clone())
    }

    pub fn stored_secret(&self, id: Uuid, kind: SecretKind) -> Option<String> {
        self.lock().secrets.get(&(id, kind)).map(|stored| stored.secret.clone())
    }

    pub fn is_empty(&self) -> bool {
        self.lock().secrets.is_empty()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

#[async_trait]
impl SecretVault for FakeSecretVault {
    async fn store(&self, id: Uuid, kind: SecretKind, secret: &SecretString, label: &str) -> Result<(), SecretError> {
        let mut state = self.lock();
        state.calls.push(Call::Store(id, kind));
        if let Some(error) = state.fail_store.get(&kind) {
            return Err(error.clone());
        }
        state.secrets.insert(
            (id, kind),
            StoredSecret {
                secret: secret.expose_secret().to_owned(),
                label: label.to_owned(),
            },
        );
        Ok(())
    }

    async fn load(&self, id: Uuid, kind: SecretKind) -> Result<SecretLookup, SecretError> {
        let mut state = self.lock();
        state.calls.push(Call::Load(id, kind));
        Ok(match state.secrets.get(&(id, kind)) {
            Some(stored) => SecretLookup::Found(SecretString::from(stored.secret.clone())),
            None => SecretLookup::NotStored,
        })
    }

    async fn relabel(&self, id: Uuid, kind: SecretKind, label: &str) -> Result<(), SecretError> {
        let mut state = self.lock();
        state.calls.push(Call::Relabel(id, kind));
        if let Some(stored) = state.secrets.get_mut(&(id, kind)) {
            stored.label = label.to_owned();
        }
        Ok(())
    }

    async fn delete_kind(&self, id: Uuid, kind: SecretKind) -> Result<(), SecretError> {
        let mut state = self.lock();
        state.calls.push(Call::DeleteKind(id, kind));
        state.secrets.remove(&(id, kind));
        Ok(())
    }

    async fn delete_connection(&self, id: Uuid) -> Result<(), SecretError> {
        let mut state = self.lock();
        state.calls.push(Call::DeleteConnection(id));
        if let Some(error) = state.fail_delete_connection.clone() {
            return Err(error);
        }
        state.secrets.retain(|(stored_id, _), _| *stored_id != id);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn store_then_load_round_trips_and_records_calls() {
        let vault = FakeSecretVault::new();
        let id = Uuid::new_v4();

        vault
            .store(id, SecretKind::DatabasePassword, &SecretString::from("s3cret"), "label")
            .await
            .expect("store");
        let found = vault.load(id, SecretKind::DatabasePassword).await.expect("load");

        assert!(found.is_stored());
        assert_eq!(
            vault.stored_label(id, SecretKind::DatabasePassword).as_deref(),
            Some("label")
        );
        assert_eq!(
            vault.calls(),
            vec![
                Call::Store(id, SecretKind::DatabasePassword),
                Call::Load(id, SecretKind::DatabasePassword)
            ]
        );
    }

    #[tokio::test]
    async fn delete_connection_removes_every_kind() {
        let vault = FakeSecretVault::new();
        let id = Uuid::new_v4();
        for kind in SecretKind::ALL {
            vault
                .store(id, kind, &SecretString::from("x"), "label")
                .await
                .expect("store");
        }

        vault.delete_connection(id).await.expect("delete");

        assert!(vault.is_empty());
    }

    #[tokio::test]
    async fn a_configured_failure_is_returned() {
        let vault = FakeSecretVault::new();
        vault.fail_store(SecretKind::SshPassphrase, SecretError::Locked);

        let refused = vault
            .store(Uuid::new_v4(), SecretKind::SshPassphrase, &SecretString::from("x"), "l")
            .await;

        assert_eq!(refused, Err(SecretError::Locked));
    }
}
