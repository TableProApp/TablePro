use std::collections::HashMap;
use std::sync::Arc;

use async_trait::async_trait;
use secrecy::{ExposeSecret, SecretString};
use tablepro_core::credentials::{SecretError, SecretItem, SecretItems, SecretKind, SecretLookup, SecretVault};
use tablepro_storage::{SecretItemLabeler, english_item_label};
use tokio::sync::{Mutex, OnceCell};
use uuid::Uuid;

use super::backend::{self, Backend};
use super::keyring_error::{Stage, invalidates_handle, map_error};
use super::secret_attributes;

/// Keyring items for one application id.
///
/// The schema attribute carries that id, so a development build never
/// reads an installed build's secrets even though both talk to the same
/// Secret Service.
pub struct SecretStore {
    schema: String,
    // Held only to read or replace the handle, never across a keyring call.
    handle: Mutex<Handle>,
    item_labeler: SecretItemLabeler,
}

#[derive(Default)]
struct Handle {
    // Opened on first use and dropped after a wire error, so a service restart does not leave every
    // later call failing on a dead socket.
    backend: Option<Arc<Backend>>,
    // Calls that arrive while an open runs share its result, failure included, so a dismissed unlock
    // prompt is not shown again for each of them. The next call after it retries.
    opening: Option<Arc<OnceCell<Opened>>>,
}

type Opened = Result<Arc<Backend>, SecretError>;

impl SecretStore {
    pub fn new(schema: impl Into<String>) -> Self {
        Self {
            schema: schema.into(),
            handle: Mutex::new(Handle::default()),
            item_labeler: english_item_label,
        }
    }

    pub fn with_item_labeler(mut self, labeler: SecretItemLabeler) -> Self {
        self.item_labeler = labeler;
        self
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
        self.with_backend(async |backend| {
            backend
                .store(label, &attributes, oo7::Secret::text(token.expose_secret()))
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
        self.with_backend(async |backend| {
            backend
                .store(label, &attributes, oo7::Secret::text(key.expose_secret()))
                .await
        })
        .await
    }

    pub async fn delete_ai_key(&self, provider: &str) -> Result<(), SecretError> {
        let attributes = secret_attributes::for_ai_key(&self.schema, provider);
        self.with_backend(async |backend| backend.delete(&attributes).await)
            .await
    }

    pub async fn load_account_token(&self) -> Result<Option<SecretString>, SecretError> {
        self.load_text(&secret_attributes::for_account_token(&self.schema))
            .await
    }

    // Replaces the item: the server rotates the token on every refresh.
    pub async fn store_account_token(&self, token: &SecretString, label: &str) -> Result<(), SecretError> {
        let attributes = secret_attributes::for_account_token(&self.schema);
        self.with_backend(async |backend| {
            backend
                .store(label, &attributes, oo7::Secret::text(token.expose_secret()))
                .await
        })
        .await
    }

    pub async fn delete_account_token(&self) -> Result<(), SecretError> {
        let attributes = secret_attributes::for_account_token(&self.schema);
        self.with_backend(async |backend| backend.delete(&attributes).await)
            .await
    }

    /// The text of the first item matching `attributes`.
    async fn load_text(&self, attributes: &HashMap<&'static str, String>) -> Result<Option<SecretString>, SecretError> {
        let secret = self
            .with_backend(async |backend| backend.find_secret(attributes).await)
            .await?;
        let Some(secret) = secret else {
            return Ok(None);
        };
        let text = std::str::from_utf8(secret.as_bytes()).map_err(|_| SecretError::InvalidEncoding)?;
        Ok(Some(SecretString::from(text.to_owned())))
    }

    async fn with_backend<T, F>(&self, operation: F) -> Result<T, SecretError>
    where
        F: AsyncFnOnce(&Backend) -> backend::Result<T>,
    {
        let backend = self.backend().await?;
        backend.unlock().await.map_err(|error| map_error(*error, Stage::Use))?;

        match operation(&backend).await {
            Ok(value) => Ok(value),
            Err(error) => {
                if invalidates_handle(&error) {
                    self.forget(&backend).await;
                }
                Err(map_error(*error, Stage::Use))
            }
        }
    }

    async fn backend(&self) -> Result<Arc<Backend>, SecretError> {
        self.backend_from(async {
            Backend::open()
                .await
                .map(Arc::new)
                .map_err(|error| map_error(*error, Stage::Open))
        })
        .await
    }

    async fn backend_from(&self, open: impl Future<Output = Opened>) -> Opened {
        let attempt = {
            let mut handle = self.handle.lock().await;
            if let Some(backend) = &handle.backend {
                return Ok(Arc::clone(backend));
            }
            Arc::clone(handle.opening.get_or_insert_with(Default::default))
        };
        let result = attempt.get_or_init(|| open).await.clone();

        let mut handle = self.handle.lock().await;
        if handle
            .opening
            .as_ref()
            .is_some_and(|current| Arc::ptr_eq(current, &attempt))
        {
            handle.opening = None;
            handle.backend = result.as_ref().ok().cloned();
        }
        result
    }

    // Only the handle that failed, so a call that already reopened keeps its new one.
    async fn forget(&self, failed: &Arc<Backend>) {
        let mut handle = self.handle.lock().await;
        if handle
            .backend
            .as_ref()
            .is_some_and(|current| Arc::ptr_eq(current, failed))
        {
            handle.backend = None;
        }
    }
}

#[async_trait]
impl SecretVault for SecretStore {
    async fn store(&self, id: Uuid, kind: SecretKind, secret: &SecretString, label: &str) -> Result<(), SecretError> {
        let attributes = secret_attributes::for_secret(&self.schema, id, kind);
        // The one copy is the oo7::Secret, which zeroes itself on drop.
        self.with_backend(async |backend| {
            backend
                .store(label, &attributes, oo7::Secret::text(secret.expose_secret()))
                .await
        })
        .await
    }

    async fn load(&self, id: Uuid, kind: SecretKind) -> Result<SecretLookup, SecretError> {
        let attributes = secret_attributes::for_secret(&self.schema, id, kind);
        let secret = self
            .with_backend(async |backend| backend.find_secret(&attributes).await)
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
        self.with_backend(async |backend| backend.relabel(&attributes, label).await)
            .await
    }

    async fn delete_kind(&self, id: Uuid, kind: SecretKind) -> Result<(), SecretError> {
        let attributes = secret_attributes::for_secret(&self.schema, id, kind);
        self.with_backend(async |backend| backend.delete(&attributes).await)
            .await
    }

    async fn delete_connection(&self, id: Uuid) -> Result<(), SecretError> {
        // One call on the connection attributes, so no kind can be left
        // behind if a later delete fails.
        let attributes = secret_attributes::for_connection(&self.schema, id);
        self.with_backend(async |backend| backend.delete(&attributes).await)
            .await
    }
}

#[async_trait]
impl SecretItems for SecretStore {
    async fn load_item(&self, item: SecretItem) -> Result<Option<SecretString>, SecretError> {
        match item {
            SecretItem::McpToken => self.load_mcp_token().await,
            SecretItem::AiKey(provider) => self.load_ai_key(provider.id()).await,
        }
    }

    async fn store_item(&self, item: SecretItem, secret: &SecretString) -> Result<(), SecretError> {
        let label = (self.item_labeler)(item);
        match item {
            SecretItem::McpToken => self.store_mcp_token(secret, &label).await,
            SecretItem::AiKey(provider) => self.store_ai_key(provider.id(), secret, &label).await,
        }
    }

    async fn delete_item(&self, item: SecretItem) -> Result<(), SecretError> {
        match item {
            SecretItem::McpToken => {
                let attributes = secret_attributes::for_mcp_token(&self.schema);
                self.with_backend(async |backend| backend.delete(&attributes).await)
                    .await
            }
            SecretItem::AiKey(provider) => self.delete_ai_key(provider.id()).await,
        }
    }
}

impl std::fmt::Debug for SecretStore {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SecretStore").field("schema", &self.schema).finish()
    }
}

#[cfg(test)]
mod tests {
    use std::path::Path;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::Duration;

    use secrecy::{ExposeSecret, SecretString};
    use tablepro_core::credentials::{SecretError, SecretKind, SecretLookup, SecretVault};
    use tokio::sync::Notify;
    use uuid::Uuid;

    use super::super::backend::Backend;
    use super::super::secret_attributes;
    use super::SecretStore;

    const SCHEMA: &str = "app.tablepro.TablePro.Test.Password";
    // The length GNOME Keyring's portal hands out.
    const PORTAL_KEY: [u8; 64] = [0x5a; 64];

    // What oo7 0.6's Keyring::new builds inside the sandbox, minus the portal call: the keyring
    // beta.1 and beta.2 saved passwords through.
    async fn oo7_keyring(path: &Path) -> oo7::Keyring {
        let file = oo7::file::UnlockedKeyring::load(path, oo7::Secret::from(PORTAL_KEY.to_vec()))
            .await
            .expect("oo7 opens the file keyring");
        oo7::Keyring::File(Arc::new(tokio::sync::RwLock::new(Some(oo7::file::Keyring::Unlocked(
            file,
        )))))
    }

    async fn file_store(path: &Path) -> SecretStore {
        let backend = Backend::open_file(path, oo7::Secret::blob(PORTAL_KEY))
            .await
            .expect("the store opens the file keyring");
        let store = SecretStore::new(SCHEMA);
        store.handle.lock().await.backend = Some(Arc::new(backend));
        store
    }

    #[tokio::test]
    async fn the_store_reads_what_oo7s_keyring_saved_in_the_sandbox() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let path = dir.path().join("default.keyring");
        let id = Uuid::new_v4();
        let attributes = secret_attributes::for_secret(SCHEMA, id, SecretKind::DatabasePassword);
        oo7_keyring(&path)
            .await
            .create_item("saved by beta.2", &attributes, oo7::Secret::text("s3cret"), true)
            .await
            .expect("oo7 stores the item");

        let store = file_store(&path).await;
        let found = store
            .load(id, SecretKind::DatabasePassword)
            .await
            .expect("the store reads the keyring");

        let SecretLookup::Found(secret) = found else {
            panic!("the store lost the saved password: {found:?}");
        };
        assert_eq!(secret.expose_secret(), "s3cret");
    }

    #[tokio::test]
    async fn oo7s_keyring_reads_what_the_store_saved() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let path = dir.path().join("default.keyring");
        let id = Uuid::new_v4();
        let store = file_store(&path).await;
        store
            .store(id, SecretKind::SshPassword, &SecretString::from("tunnel"), "first")
            .await
            .expect("the store saves the item");
        store
            .relabel(id, SecretKind::SshPassword, "second")
            .await
            .expect("the store relabels the item");

        let keyring = oo7_keyring(&path).await;
        let items = keyring
            .search_items(&secret_attributes::for_secret(SCHEMA, id, SecretKind::SshPassword))
            .await
            .expect("oo7 searches the keyring");

        assert_eq!(items.len(), 1);
        let secret = items[0].secret().await.expect("oo7 reads the secret");
        assert_eq!(secret.as_bytes(), b"tunnel");
        assert_eq!(items[0].label().await.expect("oo7 reads the label"), "second");
    }

    #[tokio::test]
    async fn a_connection_deleted_by_the_store_is_gone_for_oo7() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let path = dir.path().join("default.keyring");
        let id = Uuid::new_v4();
        let store = file_store(&path).await;
        for kind in SecretKind::ALL {
            store
                .store(id, kind, &SecretString::from("x"), "label")
                .await
                .expect("the store saves the item");
        }

        store
            .delete_connection(id)
            .await
            .expect("the store deletes the connection");

        let items = oo7_keyring(&path)
            .await
            .search_items(&secret_attributes::for_connection(SCHEMA, id))
            .await
            .expect("oo7 searches the keyring");
        assert!(items.is_empty(), "{} items survived the delete", items.len());
    }

    #[tokio::test]
    async fn another_portal_key_does_not_open_the_keyring() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let path = dir.path().join("default.keyring");
        file_store(&path)
            .await
            .store(
                Uuid::new_v4(),
                SecretKind::DatabasePassword,
                &SecretString::from("x"),
                "l",
            )
            .await
            .expect("the store saves the item");

        let opened = Backend::open_file(&path, oo7::Secret::blob([0x11; 64])).await;

        assert!(opened.is_err(), "a keyring opened with the wrong key");
    }

    #[tokio::test]
    async fn a_relabel_waits_for_a_write_in_progress() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let id = Uuid::new_v4();
        let store = file_store(&dir.path().join("default.keyring")).await;
        store
            .store(id, SecretKind::DatabasePassword, &SecretString::from("old"), "first")
            .await
            .expect("the store saves the item");
        let backend = store.handle.lock().await.backend.clone().expect("an open keyring");
        let Backend::File { writes, .. } = &*backend else {
            panic!("expected the file keyring");
        };

        let writing = writes.lock().await;
        let relabel = tokio::time::timeout(
            Duration::from_millis(100),
            store.relabel(id, SecretKind::DatabasePassword, "second"),
        )
        .await;
        drop(writing);

        assert!(relabel.is_err(), "a relabel ran while another write held the keyring");
    }

    #[tokio::test]
    async fn a_relabel_beside_a_store_keeps_the_new_password() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let id = Uuid::new_v4();
        let store = file_store(&dir.path().join("default.keyring")).await;
        store
            .store(id, SecretKind::DatabasePassword, &SecretString::from("old"), "first")
            .await
            .expect("the store saves the item");

        let new = SecretString::from("new");
        let (relabelled, stored) = tokio::join!(
            store.relabel(id, SecretKind::DatabasePassword, "second"),
            store.store(id, SecretKind::DatabasePassword, &new, "first"),
        );
        relabelled.expect("the relabel");
        stored.expect("the store");

        let found = store
            .load(id, SecretKind::DatabasePassword)
            .await
            .expect("the store reads the keyring");
        let SecretLookup::Found(secret) = found else {
            panic!("the password was lost: {found:?}");
        };
        assert_eq!(secret.expose_secret(), "new");
    }

    #[tokio::test]
    async fn callers_waiting_on_an_open_share_its_failure_and_a_later_call_retries() {
        let store = SecretStore::new(SCHEMA);
        let opens = AtomicUsize::new(0);
        let answered = Notify::new();
        let refused_open = || async {
            opens.fetch_add(1, Ordering::SeqCst);
            answered.notified().await;
            Err(SecretError::Locked)
        };

        let (first, second, third, ()) = tokio::join!(
            store.backend_from(refused_open()),
            store.backend_from(refused_open()),
            store.backend_from(refused_open()),
            async {
                tokio::task::yield_now().await;
                answered.notify_one();
            },
        );

        assert_eq!(
            opens.load(Ordering::SeqCst),
            1,
            "each waiting call opened its own prompt"
        );
        for result in [first, second, third] {
            assert!(matches!(result, Err(SecretError::Locked)), "{:?}", result.err());
        }
        answered.notify_one();
        let retried = store.backend_from(refused_open()).await;
        assert!(matches!(retried, Err(SecretError::Locked)), "{:?}", retried.err());
        assert_eq!(opens.load(Ordering::SeqCst), 2);
    }

    #[tokio::test]
    async fn a_call_after_a_cancelled_open_opens_again() {
        let store = SecretStore::new(SCHEMA);

        let cancelled =
            tokio::time::timeout(Duration::from_millis(50), store.backend_from(std::future::pending())).await;
        let retried = tokio::time::timeout(
            Duration::from_secs(5),
            store.backend_from(async { Err(SecretError::UnlockDismissed) }),
        )
        .await
        .expect("a cancelled open must not block the next one");

        assert!(cancelled.is_err());
        assert!(
            matches!(retried, Err(SecretError::UnlockDismissed)),
            "{:?}",
            retried.err()
        );
    }
}
