use async_trait::async_trait;
use secrecy::SecretString;
use tablepro_core::AiProvider;
use tablepro_core::credentials::{SecretError, SecretItem, SecretItems};

/// Where the providers' API keys are kept: the platform's keyring, as
/// connection passwords are.
#[async_trait]
pub trait ApiKeyVault: Send + Sync {
    async fn load_key(&self, provider: AiProvider) -> Result<Option<SecretString>, SecretError>;

    async fn store_key(&self, provider: AiProvider, key: &SecretString) -> Result<(), SecretError>;

    async fn delete_key(&self, provider: AiProvider) -> Result<(), SecretError>;
}

#[async_trait]
impl<T: SecretItems + ?Sized> ApiKeyVault for T {
    async fn load_key(&self, provider: AiProvider) -> Result<Option<SecretString>, SecretError> {
        self.load_item(SecretItem::AiKey(provider)).await
    }

    async fn store_key(&self, provider: AiProvider, key: &SecretString) -> Result<(), SecretError> {
        self.store_item(SecretItem::AiKey(provider), key).await
    }

    async fn delete_key(&self, provider: AiProvider) -> Result<(), SecretError> {
        self.delete_item(SecretItem::AiKey(provider)).await
    }
}
