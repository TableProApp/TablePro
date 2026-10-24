use async_trait::async_trait;
use secrecy::SecretString;
use tablepro_core::credentials::SecretError;
use tablepro_storage::SecretStore;

use tablepro_core::AiProvider;

/// Where the providers' API keys are kept: the Secret Service, as
/// connection passwords are.
#[async_trait]
pub trait ApiKeyVault: Send + Sync {
    async fn load_key(&self, provider: AiProvider) -> Result<Option<SecretString>, SecretError>;

    async fn store_key(&self, provider: AiProvider, key: &SecretString) -> Result<(), SecretError>;

    async fn delete_key(&self, provider: AiProvider) -> Result<(), SecretError>;
}

#[async_trait]
impl ApiKeyVault for SecretStore {
    async fn load_key(&self, provider: AiProvider) -> Result<Option<SecretString>, SecretError> {
        self.load_ai_key(provider.id()).await
    }

    async fn store_key(&self, provider: AiProvider, key: &SecretString) -> Result<(), SecretError> {
        self.store_ai_key(provider.id(), key, &label(provider)).await
    }

    async fn delete_key(&self, provider: AiProvider) -> Result<(), SecretError> {
        self.delete_ai_key(provider.id()).await
    }
}

/// What Seahorse shows for the item, so the user can tell what it is
/// without TablePro open.
fn label(provider: AiProvider) -> String {
    let name = match provider {
        AiProvider::Anthropic => "Anthropic",
        AiProvider::OpenAi => "OpenAI",
        AiProvider::OpenAiCompatible => "an OpenAI-compatible server",
    };
    format!("TablePro API key for {name}")
}
