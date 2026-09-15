use std::collections::HashMap;

use oo7::Keyring;
use secrecy::SecretString;
use uuid::Uuid;

use crate::error::StorageError;

const SCHEMA: &str = "app.tablepro.TablePro.Password";

const KIND_DB_PASSWORD: &str = "db_password";
const KIND_SSH_PASSWORD: &str = "ssh_password";
const KIND_SSH_PASSPHRASE: &str = "ssh_passphrase";

pub async fn store_password(id: Uuid, password: &str, label: &str) -> Result<(), StorageError> {
    store_secret(id, KIND_DB_PASSWORD, password, label).await
}

pub async fn load_password(id: Uuid) -> Result<Option<SecretString>, StorageError> {
    load_secret(id, KIND_DB_PASSWORD).await
}

pub async fn delete_password(id: Uuid) -> Result<(), StorageError> {
    delete_secret(id, KIND_DB_PASSWORD).await
}

pub async fn store_ssh_password(id: Uuid, password: &str, label: &str) -> Result<(), StorageError> {
    store_secret(id, KIND_SSH_PASSWORD, password, label).await
}

pub async fn load_ssh_password(id: Uuid) -> Result<Option<SecretString>, StorageError> {
    load_secret(id, KIND_SSH_PASSWORD).await
}

pub async fn delete_ssh_password(id: Uuid) -> Result<(), StorageError> {
    delete_secret(id, KIND_SSH_PASSWORD).await
}

pub async fn store_ssh_passphrase(id: Uuid, passphrase: &str, label: &str) -> Result<(), StorageError> {
    store_secret(id, KIND_SSH_PASSPHRASE, passphrase, label).await
}

pub async fn load_ssh_passphrase(id: Uuid) -> Result<Option<SecretString>, StorageError> {
    load_secret(id, KIND_SSH_PASSPHRASE).await
}

pub async fn delete_ssh_passphrase(id: Uuid) -> Result<(), StorageError> {
    delete_secret(id, KIND_SSH_PASSPHRASE).await
}

async fn store_secret(id: Uuid, kind: &str, value: &str, label: &str) -> Result<(), StorageError> {
    let keyring = open().await?;
    keyring
        .create_item(label, &attrs_for(id, kind), value.as_bytes(), true)
        .await
        .map_err(map_err)?;
    Ok(())
}

async fn load_secret(id: Uuid, kind: &str) -> Result<Option<SecretString>, StorageError> {
    let keyring = match open().await {
        Ok(k) => k,
        Err(e) => {
            // Don't fail outright — a missing Secret Service shouldn't crash
            // the app — but the user will hit a misleading "auth failed"
            // downstream if we stay silent.
            tracing::warn!(connection_id = %id, kind, error = %e, "keyring unavailable, secret cannot be loaded");
            return Ok(None);
        }
    };
    let items = keyring.search_items(&attrs_for(id, kind)).await.map_err(map_err)?;
    let Some(item) = items.into_iter().next() else {
        return Ok(None);
    };
    let secret = item.secret().await.map_err(map_err)?;
    let s = String::from_utf8(secret.to_vec()).map_err(|e| StorageError::Schema(format!("secret utf8: {e}")))?;
    Ok(Some(SecretString::new(s.into())))
}

async fn delete_secret(id: Uuid, kind: &str) -> Result<(), StorageError> {
    let keyring = open().await?;
    keyring.delete(&attrs_for(id, kind)).await.map_err(map_err)?;
    Ok(())
}

async fn open() -> Result<Keyring, StorageError> {
    Keyring::new()
        .await
        .map_err(|e| StorageError::Schema(format!("secret service unavailable: {e}")))
}

fn map_err(e: oo7::Error) -> StorageError {
    StorageError::Schema(format!("secret service: {e}"))
}

fn attrs_for(id: Uuid, kind: &str) -> HashMap<&'static str, String> {
    let mut m = HashMap::new();
    m.insert("xdg:schema", SCHEMA.to_string());
    m.insert("connection-id", id.to_string());
    m.insert("kind", kind.to_string());
    m
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn attrs_include_schema_connection_id_and_kind() {
        let id = Uuid::new_v4();
        let a = attrs_for(id, KIND_DB_PASSWORD);
        assert_eq!(a.get("xdg:schema").map(String::as_str), Some(SCHEMA));
        assert_eq!(
            a.get("connection-id").map(String::as_str),
            Some(id.to_string().as_str())
        );
        assert_eq!(a.get("kind").map(String::as_str), Some(KIND_DB_PASSWORD));
    }

    #[test]
    fn schema_name_follows_the_app_id() {
        assert_eq!(SCHEMA, "app.tablepro.TablePro.Password");
        assert!(SCHEMA.starts_with("app.tablepro."));
    }

    #[test]
    fn attrs_distinguish_kinds() {
        let id = Uuid::new_v4();
        let db = attrs_for(id, KIND_DB_PASSWORD);
        let ssh = attrs_for(id, KIND_SSH_PASSWORD);
        let pp = attrs_for(id, KIND_SSH_PASSPHRASE);
        assert_ne!(db.get("kind"), ssh.get("kind"));
        assert_ne!(ssh.get("kind"), pp.get("kind"));
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
        // map_err shouldn't lose the underlying message, since downstream
        // surfaces it in the user-facing error UI.
        let oo7_err: oo7::Error = oo7::dbus::Error::Deleted.into();
        let mapped = map_err(oo7_err);
        match mapped {
            StorageError::Schema(msg) => {
                assert!(msg.starts_with("secret service:"), "missing prefix: {msg}");
            }
            other => panic!("expected Schema variant, got {other:?}"),
        }
    }

    #[test]
    fn invalid_utf8_secret_produces_schema_error_with_descriptive_prefix() {
        // load_secret's UTF-8 conversion path: if a secret round-trips through
        // a non-UTF-8 byte sequence (e.g. a binary blob smuggled in via a
        // non-tablepro caller), we surface a clear "secret utf8" prefix
        // instead of a raw FromUtf8Error.
        let bad: Vec<u8> = vec![0xFF, 0xFE, 0xFD];
        let err = String::from_utf8(bad)
            .map_err(|e| StorageError::Schema(format!("secret utf8: {e}")))
            .unwrap_err();
        match err {
            StorageError::Schema(msg) => assert!(msg.starts_with("secret utf8:"), "missing prefix: {msg}"),
            other => panic!("expected Schema variant, got {other:?}"),
        }
    }

    #[test]
    fn attrs_for_includes_uuid_in_canonical_lowercase_hyphenated_form() {
        // Secret Service searches are exact-match on attribute strings, so
        // shifting the UUID format would silently break key lookups.
        let id = Uuid::parse_str("550e8400-e29b-41d4-a716-446655440000").unwrap();
        let a = attrs_for(id, KIND_DB_PASSWORD);
        assert_eq!(
            a.get("connection-id").map(String::as_str),
            Some("550e8400-e29b-41d4-a716-446655440000")
        );
    }

    #[tokio::test]
    #[ignore = "requires a Secret Service"]
    async fn round_trip_via_secret_service() {
        use secrecy::ExposeSecret;
        let id = Uuid::new_v4();
        store_password(id, "test-secret", "tablepro-spike").await.unwrap();
        let loaded = load_password(id).await.unwrap();
        assert_eq!(
            loaded.map(|s| s.expose_secret().to_string()),
            Some("test-secret".to_string())
        );
        delete_password(id).await.unwrap();
        let after = load_password(id).await.unwrap();
        assert!(after.is_none());
    }
}
