use async_trait::async_trait;
use secrecy::SecretString;

use super::{SecretError, SecretItem};

/// Where each platform keeps the secrets that belong to no connection.
/// The store names each item for its keyring, so a caller passes only
/// what the item is.
#[async_trait]
pub trait SecretItems: Send + Sync {
    async fn load_item(&self, item: SecretItem) -> Result<Option<SecretString>, SecretError>;

    /// Replaces the item's secret, if it had one.
    async fn store_item(&self, item: SecretItem, secret: &SecretString) -> Result<(), SecretError>;

    async fn delete_item(&self, item: SecretItem) -> Result<(), SecretError>;
}
