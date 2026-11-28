use async_trait::async_trait;
use secrecy::SecretString;
use tablepro_records::Kind;
use tablepro_records::envelope::SecretKind;
use uuid::Uuid;

use super::error::AdapterError;

// A secret of a synced record, named as 0056's envelope table names it.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct SecretRef {
    pub parent: Kind,
    pub parent_id: Uuid,
    pub secret: SecretKind,
}

// The device's own store of the secrets its personal records name (0044, Secrets): the Keychain, Credential Manager or
// the Secret Service, as the app keeps them. `secret_envelope` goes up and comes down through it.
#[async_trait]
pub trait DeviceSecrets: Send + Sync {
    // The kinds of `parent` this device keeps. An envelope of any other kind is held for a device that keeps it, never
    // deleted from here.
    fn kinds(&self, parent: Kind) -> Vec<SecretKind>;

    // Holds off the app's own writes of records and their secrets until the guard drops, so a record read under it is
    // still the one a secret is read for or written to (0056, At use). The calls below take no hold of their own.
    async fn hold(&self) -> Box<dyn Send>;

    async fn load(&self, secret: &SecretRef) -> Result<Option<SecretString>, AdapterError>;

    // A pulled secret, which stays on this device: iCloud Keychain never carries it beside its envelope (0044,
    // iCloud Keychain).
    async fn store(&self, secret: &SecretRef, value: &SecretString) -> Result<(), AdapterError>;

    async fn delete(&self, secret: &SecretRef) -> Result<(), AdapterError>;
}
