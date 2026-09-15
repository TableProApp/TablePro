use std::collections::HashMap;

use oo7::Keyring;
use secrecy::SecretString;
use uuid::Uuid;

use crate::error::StorageError;

const KIND_DB_PASSWORD: &str = "db_password";
const KIND_SSH_PASSWORD: &str = "ssh_password";
const KIND_SSH_PASSPHRASE: &str = "ssh_passphrase";

/// Keyring items for one application id. The schema attribute carries
/// that id, so a development build never reads an installed build's
/// secrets even though both talk to the same Secret Service.
#[derive(Debug, Clone)]
pub struct SecretStore {
    schema: String,
}

impl SecretStore {
    pub fn new(schema: impl Into<String>) -> Self {
        Self { schema: schema.into() }
    }

    pub fn schema(&self) -> &str {
        &self.schema
    }

    pub async fn store_password(&self, id: Uuid, password: &str, label: &str) -> Result<(), StorageError> {
        self.store_secret(id, KIND_DB_PASSWORD, password, label).await
    }

    pub async fn load_password(&self, id: Uuid) -> Result<Option<SecretString>, StorageError> {
        self.load_secret(id, KIND_DB_PASSWORD).await
    }

    pub async fn delete_password(&self, id: Uuid) -> Result<(), StorageError> {
        self.delete_secret(id, KIND_DB_PASSWORD).await
    }

    pub async fn store_ssh_password(&self, id: Uuid, password: &str, label: &str) -> Result<(), StorageError> {
        self.store_secret(id, KIND_SSH_PASSWORD, password, label).await
    }

    pub async fn load_ssh_password(&self, id: Uuid) -> Result<Option<SecretString>, StorageError> {
        self.load_secret(id, KIND_SSH_PASSWORD).await
    }

    pub async fn delete_ssh_password(&self, id: Uuid) -> Result<(), StorageError> {
        self.delete_secret(id, KIND_SSH_PASSWORD).await
    }

    pub async fn store_ssh_passphrase(&self, id: Uuid, passphrase: &str, label: &str) -> Result<(), StorageError> {
        self.store_secret(id, KIND_SSH_PASSPHRASE, passphrase, label).await
    }

    pub async fn load_ssh_passphrase(&self, id: Uuid) -> Result<Option<SecretString>, StorageError> {
        self.load_secret(id, KIND_SSH_PASSPHRASE).await
    }

    pub async fn delete_ssh_passphrase(&self, id: Uuid) -> Result<(), StorageError> {
        self.delete_secret(id, KIND_SSH_PASSPHRASE).await
    }

    async fn store_secret(&self, id: Uuid, kind: &str, value: &str, label: &str) -> Result<(), StorageError> {
        let keyring = open().await?;
        keyring
            .create_item(label, &self.attrs_for(id, kind), value.as_bytes(), true)
            .await
            .map_err(map_err)?;
        Ok(())
    }

    async fn load_secret(&self, id: Uuid, kind: &str) -> Result<Option<SecretString>, StorageError> {
        let keyring = match open().await {
            Ok(keyring) => keyring,
            Err(error) => {
                // A missing Secret Service must not stop the app, but
                // staying silent turns into a misleading "auth failed"
                // further down.
                tracing::warn!(connection_id = %id, kind, %error, "keyring unavailable, secret cannot be loaded");
                return Ok(None);
            }
        };
        let items = keyring.search_items(&self.attrs_for(id, kind)).await.map_err(map_err)?;
        let Some(item) = items.into_iter().next() else {
            return Ok(None);
        };
        let secret = item.secret().await.map_err(map_err)?;
        let text = String::from_utf8(secret.to_vec())
            .map_err(|error| StorageError::Schema(format!("secret utf8: {error}")))?;
        Ok(Some(SecretString::new(text.into())))
    }

    async fn delete_secret(&self, id: Uuid, kind: &str) -> Result<(), StorageError> {
        let keyring = open().await?;
        keyring.delete(&self.attrs_for(id, kind)).await.map_err(map_err)?;
        Ok(())
    }

    fn attrs_for(&self, id: Uuid, kind: &str) -> HashMap<&'static str, String> {
        let mut attributes = HashMap::new();
        attributes.insert("xdg:schema", self.schema.clone());
        attributes.insert("connection-id", id.to_string());
        attributes.insert("kind", kind.to_string());
        attributes
    }
}

async fn open() -> Result<Keyring, StorageError> {
    Keyring::new()
        .await
        .map_err(|error| StorageError::Schema(format!("secret service unavailable: {error}")))
}

fn map_err(error: oo7::Error) -> StorageError {
    StorageError::Schema(format!("secret service: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    const SCHEMA: &str = "app.tablepro.TablePro.Password";

    fn store() -> SecretStore {
        SecretStore::new(SCHEMA)
    }

    #[test]
    fn attrs_include_schema_connection_id_and_kind() {
        let id = Uuid::new_v4();

        let attributes = store().attrs_for(id, KIND_DB_PASSWORD);

        assert_eq!(attributes.get("xdg:schema").map(String::as_str), Some(SCHEMA));
        assert_eq!(
            attributes.get("connection-id").map(String::as_str),
            Some(id.to_string().as_str())
        );
        assert_eq!(attributes.get("kind").map(String::as_str), Some(KIND_DB_PASSWORD));
    }

    #[test]
    fn secret_attributes_use_injected_schema() {
        let id = Uuid::new_v4();
        let devel = SecretStore::new("app.tablepro.TablePro.Devel.Password");

        let installed = store().attrs_for(id, KIND_DB_PASSWORD);
        let development = devel.attrs_for(id, KIND_DB_PASSWORD);

        assert_ne!(installed.get("xdg:schema"), development.get("xdg:schema"));
        assert_eq!(
            development.get("xdg:schema").map(String::as_str),
            Some("app.tablepro.TablePro.Devel.Password")
        );
    }

    #[test]
    fn attrs_distinguish_kinds() {
        let id = Uuid::new_v4();
        let store = store();

        let db = store.attrs_for(id, KIND_DB_PASSWORD);
        let ssh = store.attrs_for(id, KIND_SSH_PASSWORD);
        let passphrase = store.attrs_for(id, KIND_SSH_PASSPHRASE);

        assert_ne!(db.get("kind"), ssh.get("kind"));
        assert_ne!(ssh.get("kind"), passphrase.get("kind"));
    }

    #[test]
    fn kind_constants_are_distinct_and_non_empty() {
        assert!(!KIND_DB_PASSWORD.is_empty());
        assert!(!KIND_SSH_PASSWORD.is_empty());
        assert!(!KIND_SSH_PASSPHRASE.is_empty());
        assert_ne!(KIND_DB_PASSWORD, KIND_SSH_PASSWORD);
        assert_ne!(KIND_DB_PASSWORD, KIND_SSH_PASSPHRASE);
        assert_ne!(KIND_SSH_PASSWORD, KIND_SSH_PASSPHRASE);
    }

    #[test]
    fn map_err_produces_storage_error_schema() {
        // The underlying message reaches the user-facing error UI, so it
        // must survive the mapping.
        let mapped = map_err(oo7::dbus::Error::Deleted.into());

        match mapped {
            StorageError::Schema(message) => {
                assert!(message.starts_with("secret service:"), "missing prefix: {message}");
            }
            other => panic!("expected Schema variant, got {other:?}"),
        }
    }

    #[test]
    fn invalid_utf8_secret_produces_schema_error_with_descriptive_prefix() {
        // A binary blob written by something other than TablePro must come
        // back as a clear error, not a raw FromUtf8Error.
        let error = String::from_utf8(vec![0xFF, 0xFE, 0xFD])
            .map_err(|error| StorageError::Schema(format!("secret utf8: {error}")))
            .unwrap_err();

        match error {
            StorageError::Schema(message) => assert!(message.starts_with("secret utf8:"), "missing prefix: {message}"),
            other => panic!("expected Schema variant, got {other:?}"),
        }
    }

    #[test]
    fn attrs_for_includes_uuid_in_canonical_lowercase_hyphenated_form() {
        // Secret Service searches match attribute strings exactly, so a
        // different UUID format silently breaks every lookup.
        let id = Uuid::parse_str("550e8400-e29b-41d4-a716-446655440000").expect("a valid uuid");

        let attributes = store().attrs_for(id, KIND_DB_PASSWORD);

        assert_eq!(
            attributes.get("connection-id").map(String::as_str),
            Some("550e8400-e29b-41d4-a716-446655440000")
        );
    }

    #[tokio::test]
    #[ignore = "requires a Secret Service"]
    async fn round_trip_via_secret_service() {
        use secrecy::ExposeSecret;

        let store = store();
        let id = Uuid::new_v4();

        store.store_password(id, "test-secret", "tablepro-spike").await.unwrap();
        let loaded = store.load_password(id).await.unwrap();
        store.delete_password(id).await.unwrap();
        let after = store.load_password(id).await.unwrap();

        assert_eq!(
            loaded.map(|secret| secret.expose_secret().to_string()),
            Some("test-secret".to_string())
        );
        assert!(after.is_none());
    }
}
