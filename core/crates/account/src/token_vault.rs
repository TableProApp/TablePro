use std::sync::Arc;

use async_trait::async_trait;
use secrecy::SecretString;
use tablepro_core::credentials::SecretError;

use crate::account_settings::SignInKey;

// Each app keeps the refresh token in its platform's secret store.
#[async_trait]
pub trait RefreshTokenVault: Send + Sync {
    async fn load_refresh_token(&self) -> Result<Option<SecretString>, SecretError>;

    async fn store_refresh_token(&self, token: &SecretString) -> Result<(), SecretError>;

    async fn delete_refresh_token(&self) -> Result<(), SecretError>;
}

// Where each sign-in keeps its refresh token, so a company server's never lands in tablepro.app's item.
pub trait RefreshTokenVaults: Send + Sync {
    fn vault(&self, sign_in: &SignInKey) -> Arc<dyn RefreshTokenVault>;
}

// One item for every sign-in, for an app that signs in to one server only.
pub struct SingleVault(pub Arc<dyn RefreshTokenVault>);

impl RefreshTokenVaults for SingleVault {
    fn vault(&self, _: &SignInKey) -> Arc<dyn RefreshTokenVault> {
        self.0.clone()
    }
}
