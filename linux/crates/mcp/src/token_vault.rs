use async_trait::async_trait;
use secrecy::SecretString;
use tablepro_core::credentials::SecretError;
use tablepro_storage::SecretStore;

use crate::access_token::{AccessToken, TokenError};

const LABEL: &str = "TablePro MCP access token";

#[async_trait]
pub trait TokenVault: Send + Sync {
    async fn load_token(&self) -> Result<Option<SecretString>, SecretError>;

    async fn store_token(&self, token: &SecretString) -> Result<(), SecretError>;
}

#[async_trait]
impl TokenVault for SecretStore {
    async fn load_token(&self) -> Result<Option<SecretString>, SecretError> {
        self.load_mcp_token().await
    }

    async fn store_token(&self, token: &SecretString) -> Result<(), SecretError> {
        self.store_mcp_token(token, LABEL).await
    }
}

#[derive(Debug, thiserror::Error)]
pub enum ObtainError {
    #[error(transparent)]
    Keyring(#[from] SecretError),
    #[error(transparent)]
    Random(#[from] TokenError),
}

/// The token the keyring holds, or a new one stored there first, so a
/// client set up once keeps working across restarts.
pub async fn obtain_token(vault: &dyn TokenVault) -> Result<AccessToken, ObtainError> {
    let stored = match vault.load_token().await {
        Ok(stored) => stored,
        // Not text, so no client can be holding it.
        Err(SecretError::InvalidEncoding) => None,
        Err(error) => return Err(error.into()),
    };
    if let Some(token) = stored.and_then(AccessToken::from_secret) {
        return Ok(token);
    }
    replace_token(vault).await
}

/// A new token, stored before it is used, so a client never holds one
/// the next start would not know.
pub async fn replace_token(vault: &dyn TokenVault) -> Result<AccessToken, ObtainError> {
    let token = AccessToken::generate()?;
    vault.store_token(token.secret()).await?;
    Ok(token)
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use secrecy::ExposeSecret;

    use super::*;

    #[derive(Default)]
    struct Memory(Mutex<Option<String>>);

    #[async_trait]
    impl TokenVault for Memory {
        async fn load_token(&self) -> Result<Option<SecretString>, SecretError> {
            Ok(self.0.lock().unwrap().clone().map(SecretString::from))
        }

        async fn store_token(&self, token: &SecretString) -> Result<(), SecretError> {
            *self.0.lock().unwrap() = Some(token.expose_secret().to_owned());
            Ok(())
        }
    }

    #[tokio::test]
    async fn the_first_token_is_stored_and_read_back_after() {
        let vault = Memory::default();

        let first = obtain_token(&vault).await.expect("a token");
        let again = obtain_token(&vault).await.expect("a token");
        let replaced = replace_token(&vault).await.expect("a token");

        assert_eq!(first.secret().expose_secret(), again.secret().expose_secret());
        assert_ne!(first.secret().expose_secret(), replaced.secret().expose_secret());
        assert_eq!(
            vault.0.lock().unwrap().as_deref(),
            Some(replaced.secret().expose_secret())
        );
    }

    #[tokio::test]
    async fn an_empty_stored_token_is_replaced() {
        let vault = Memory(Mutex::new(Some(String::new())));

        let token = obtain_token(&vault).await.expect("a token");

        assert!(token.secret().expose_secret().starts_with("tp_"));
    }
}
