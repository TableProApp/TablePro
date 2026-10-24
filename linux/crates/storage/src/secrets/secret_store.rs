use std::collections::HashMap;

use async_trait::async_trait;
use oo7::Keyring;
use secrecy::{ExposeSecret, SecretString};
use tablepro_core::credentials::{SecretError, SecretKind, SecretLookup, SecretVault};
use tokio::sync::Mutex;
use uuid::Uuid;

use super::keyring_error::{Stage, invalidates_handle, map_error};
use super::secret_attributes;

/// Keyring items for one application id.
///
/// The schema attribute carries that id, so a development build never
/// reads an installed build's secrets even though both talk to the same
/// Secret Service.
pub struct SecretStore {
    schema: String,
    /// Opened on first use and dropped after a wire error, so a service
    /// restart does not leave every later call failing on a dead socket.
    keyring: Mutex<Option<Keyring>>,
}

impl SecretStore {
    pub fn new(schema: impl Into<String>) -> Self {
        Self {
            schema: schema.into(),
            keyring: Mutex::new(None),
        }
    }

    pub fn schema(&self) -> &str {
        &self.schema
    }

    /// The token MCP clients present, or `None` before one was made.
    pub async fn load_mcp_token(&self) -> Result<Option<SecretString>, SecretError> {
        self.load_text(&secret_attributes::for_mcp_token(&self.schema)).await
    }

    /// Store `token` in place of the one before it.
    pub async fn store_mcp_token(&self, token: &SecretString, label: &str) -> Result<(), SecretError> {
        let attributes = secret_attributes::for_mcp_token(&self.schema);
        self.with_keyring(async |keyring| {
            keyring
                .create_item(label, &attributes, oo7::Secret::text(token.expose_secret()), true)
                .await
        })
        .await
    }

    /// The API key kept for an AI provider, or `None` before one was
    /// added. `provider` is the provider's stored id.
    pub async fn load_ai_key(&self, provider: &str) -> Result<Option<SecretString>, SecretError> {
        self.load_text(&secret_attributes::for_ai_key(&self.schema, provider))
            .await
    }

    /// Store `key` in place of the provider's key before it.
    pub async fn store_ai_key(&self, provider: &str, key: &SecretString, label: &str) -> Result<(), SecretError> {
        let attributes = secret_attributes::for_ai_key(&self.schema, provider);
        self.with_keyring(async |keyring| {
            keyring
                .create_item(label, &attributes, oo7::Secret::text(key.expose_secret()), true)
                .await
        })
        .await
    }

    pub async fn delete_ai_key(&self, provider: &str) -> Result<(), SecretError> {
        let attributes = secret_attributes::for_ai_key(&self.schema, provider);
        self.with_keyring(async |keyring| keyring.delete(&attributes).await)
            .await
    }

    /// The text of the first item matching `attributes`.
    async fn load_text(&self, attributes: &HashMap<&'static str, String>) -> Result<Option<SecretString>, SecretError> {
        let secret = self
            .with_keyring(async |keyring| {
                let items = keyring.search_items(attributes).await?;
                let Some(item) = items.into_iter().next() else {
                    return Ok(None);
                };
                if item.is_locked().await? {
                    item.unlock().await?;
                }
                item.secret().await.map(Some)
            })
            .await?;
        let Some(secret) = secret else {
            return Ok(None);
        };
        let text = std::str::from_utf8(secret.as_bytes()).map_err(|_| SecretError::InvalidEncoding)?;
        Ok(Some(SecretString::from(text.to_owned())))
    }

    /// Run one operation against an unlocked keyring, reopening the
    /// handle if a previous call broke it.
    async fn with_keyring<T, F>(&self, operation: F) -> Result<T, SecretError>
    where
        F: AsyncFnOnce(&Keyring) -> Result<T, oo7::Error>,
    {
        let mut guard = self.keyring.lock().await;
        let keyring = match guard.as_ref() {
            Some(keyring) => keyring,
            None => guard.insert(Keyring::new().await.map_err(|error| map_error(error, Stage::Open))?),
        };

        // Unlocking before the read is what turns a silent empty result
        // into a prompt the user can answer.
        if keyring
            .is_locked()
            .await
            .map_err(|error| map_error(error, Stage::Use))?
        {
            keyring.unlock().await.map_err(|error| map_error(error, Stage::Use))?;
        }

        match operation(keyring).await {
            Ok(value) => Ok(value),
            Err(error) => {
                if invalidates_handle(&error) {
                    *guard = None;
                }
                Err(map_error(error, Stage::Use))
            }
        }
    }
}

#[async_trait]
impl SecretVault for SecretStore {
    async fn store(&self, id: Uuid, kind: SecretKind, secret: &SecretString, label: &str) -> Result<(), SecretError> {
        let attributes = secret_attributes::for_secret(&self.schema, id, kind);
        // The one copy is the oo7::Secret, which zeroes itself on drop.
        self.with_keyring(async |keyring| {
            keyring
                .create_item(label, &attributes, oo7::Secret::text(secret.expose_secret()), true)
                .await
        })
        .await
    }

    async fn load(&self, id: Uuid, kind: SecretKind) -> Result<SecretLookup, SecretError> {
        let attributes = secret_attributes::for_secret(&self.schema, id, kind);
        let secret = self
            .with_keyring(async |keyring| {
                let items = keyring.search_items(&attributes).await?;
                let Some(item) = items.into_iter().next() else {
                    return Ok(None);
                };
                // An item can be locked even when the collection is not.
                if item.is_locked().await? {
                    item.unlock().await?;
                }
                item.secret().await.map(Some)
            })
            .await?;

        let Some(secret) = secret else {
            return Ok(SecretLookup::NotStored);
        };
        // oo7::Secret zeroes itself on drop, and the one copy taken out
        // moves straight into a SecretString, which zeroes it too.
        let text = std::str::from_utf8(secret.as_bytes()).map_err(|_| SecretError::InvalidEncoding)?;
        Ok(SecretLookup::Found(SecretString::from(text.to_owned())))
    }

    async fn relabel(&self, id: Uuid, kind: SecretKind, label: &str) -> Result<(), SecretError> {
        let attributes = secret_attributes::for_secret(&self.schema, id, kind);
        self.with_keyring(async |keyring| {
            for item in keyring.search_items(&attributes).await? {
                item.set_label(label).await?;
            }
            Ok(())
        })
        .await
    }

    async fn delete_kind(&self, id: Uuid, kind: SecretKind) -> Result<(), SecretError> {
        let attributes = secret_attributes::for_secret(&self.schema, id, kind);
        self.with_keyring(async |keyring| keyring.delete(&attributes).await)
            .await
    }

    async fn delete_connection(&self, id: Uuid) -> Result<(), SecretError> {
        // One call on the connection attributes, so no kind can be left
        // behind if a later delete fails.
        let attributes = secret_attributes::for_connection(&self.schema, id);
        self.with_keyring(async |keyring| keyring.delete(&attributes).await)
            .await
    }
}

impl std::fmt::Debug for SecretStore {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SecretStore").field("schema", &self.schema).finish()
    }
}
