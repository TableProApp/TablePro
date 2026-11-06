use async_trait::async_trait;
use secrecy::SecretString;
use tablepro_core::credentials::SecretError;

// Each app keeps the refresh token in its platform's secret store.
#[async_trait]
pub trait RefreshTokenVault: Send + Sync {
    async fn load_refresh_token(&self) -> Result<Option<SecretString>, SecretError>;

    async fn store_refresh_token(&self, token: &SecretString) -> Result<(), SecretError>;

    async fn delete_refresh_token(&self) -> Result<(), SecretError>;
}
