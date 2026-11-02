use async_trait::async_trait;
use secrecy::SecretString;
use uuid::Uuid;

use super::{SecretError, SecretKind, SecretLookup};

/// Where connection secrets live.
///
/// A trait so the app can be tested without a Secret Service, and so the
/// backend can change without touching the call sites.
#[async_trait]
pub trait SecretVault: Send + Sync {
    async fn store(&self, id: Uuid, kind: SecretKind, secret: &SecretString, label: &str) -> Result<(), SecretError>;

    async fn load(&self, id: Uuid, kind: SecretKind) -> Result<SecretLookup, SecretError>;

    /// Change the label without touching the secret, for when a
    /// connection is renamed or its host changes.
    async fn relabel(&self, id: Uuid, kind: SecretKind, label: &str) -> Result<(), SecretError>;

    async fn delete_kind(&self, id: Uuid, kind: SecretKind) -> Result<(), SecretError>;

    /// Remove every secret of a connection in one call, so a delete
    /// cannot leave one kind orphaned in the keyring.
    async fn delete_connection(&self, id: Uuid) -> Result<(), SecretError>;
}
