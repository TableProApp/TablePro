use async_trait::async_trait;
use secrecy::zeroize::{Zeroize, Zeroizing};
use secrecy::{ExposeSecret, SecretString};
use tablepro_core::AiProvider;
use tablepro_core::credentials::{SecretError, SecretItem, SecretItems, SecretKind, SecretLookup, SecretVault};
use tablepro_session::runtime::Tasks;
use tablepro_storage::english_item_label;
use uuid::Uuid;
use windows_sys::Win32::Foundation::{ERROR_NOT_FOUND, GetLastError};
use windows_sys::Win32::Security::Credentials::{
    CRED_MAX_CREDENTIAL_BLOB_SIZE, CRED_MAX_STRING_LENGTH, CRED_PERSIST_LOCAL_MACHINE, CRED_TYPE_GENERIC,
    CREDENTIAL_ATTRIBUTEW, CREDENTIALW, CredDeleteW, CredFree, CredReadW, CredWriteW,
};

use crate::credential_parts::{self, Layout, PartStore, Stored};

static STORE: std::sync::Mutex<()> = std::sync::Mutex::new(());

// CredWriteW refuses a larger blob, which an Entra or RDS IAM token passes.
const PART_SIZE: usize = CRED_MAX_CREDENTIAL_BLOB_SIZE as usize;

// One unit short of CRED_MAX_STRING_LENGTH leaves room for the NUL whether or not CredWriteW counts it.
const COMMENT_UNITS: usize = CRED_MAX_STRING_LENGTH as usize - 1;

// An attribute keyword of the form CREDENTIAL_ATTRIBUTEW asks for, <Company>_<Name>.
const LAYOUT_KEYWORD: &str = "TablePro_Parts";

// Generic credentials under one prefix, so Credential Manager lists TablePro's together and a test keeps to its own.
pub(crate) struct CredentialManager {
    prefix: String,
    tasks: Tasks,
}

impl CredentialManager {
    pub(crate) fn new(prefix: impl Into<String>, tasks: Tasks) -> Self {
        Self {
            prefix: prefix.into(),
            tasks,
        }
    }

    fn connection_target(&self, id: Uuid, kind: SecretKind) -> String {
        format!("{}/connection/{id}/{}", self.prefix, kind_name(kind))
    }

    fn item_target(&self, item: SecretItem) -> String {
        format!("{}/{}", self.prefix, item_name(item))
    }

    // One call at a time: concurrent writes from one process lost each other's changes on both CI runners.
    async fn blocking<T, F>(&self, work: F) -> Result<T, SecretError>
    where
        T: Send + 'static,
        F: FnOnce() -> Result<T, SecretError> + Send + 'static,
    {
        let serialized = move || {
            let _held = STORE.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            work()
        };
        match self.tasks.spawn_blocking_task(serialized).await {
            Ok(result) => result,
            Err(failure) => Err(SecretError::Backend {
                detail: failure.to_string(),
                service_message: None,
            }),
        }
    }
}

impl std::fmt::Debug for CredentialManager {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CredentialManager")
            .field("prefix", &self.prefix)
            .finish_non_exhaustive()
    }
}

fn kind_name(kind: SecretKind) -> &'static str {
    match kind {
        SecretKind::DatabasePassword => "database-password",
        SecretKind::SshPassword => "ssh-password",
        SecretKind::SshPassphrase => "ssh-passphrase",
    }
}

fn item_name(item: SecretItem) -> &'static str {
    match item {
        SecretItem::McpToken => "mcp-token",
        SecretItem::AiKey(AiProvider::Anthropic) => "ai-key/anthropic",
        SecretItem::AiKey(AiProvider::OpenAi) => "ai-key/openai",
        SecretItem::AiKey(AiProvider::OpenAiCompatible) => "ai-key/openai-compatible",
    }
}

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(std::iter::once(0)).collect()
}

fn failure(action: &str) -> SecretError {
    // SAFETY: reads the calling thread's last error, which the failed call just set.
    let code = unsafe { GetLastError() };
    SecretError::Backend {
        detail: format!("Credential Manager could not {action} a credential (error {code})"),
        service_message: None,
    }
}

// The blob holds UTF-16, as cmdkey and the Credential Manager control panel write it.
fn decode(blob: &[u8]) -> Result<SecretString, SecretError> {
    if blob.len() % 2 != 0 {
        return Err(SecretError::InvalidEncoding);
    }
    let units: Vec<u16> = blob
        .chunks_exact(2)
        .map(|pair| u16::from_le_bytes([pair[0], pair[1]]))
        .collect();
    let units = Zeroizing::new(units);
    // Sized exactly, so neither a push nor SecretString's shrink to fit leaves a copy in freed memory.
    let mut size = 0;
    for decoded in char::decode_utf16(units.iter().copied()) {
        size += decoded.map_err(|_| SecretError::InvalidEncoding)?.len_utf8();
    }
    let mut text = String::with_capacity(size);
    text.extend(char::decode_utf16(units.iter().copied()).flatten());
    Ok(SecretString::from(text))
}

struct Credentials;

impl PartStore for Credentials {
    type Error = SecretError;

    fn read(&self, target: &str) -> Result<Option<Stored>, SecretError> {
        let name = wide(target);
        let mut found: *mut CREDENTIALW = std::ptr::null_mut();
        // SAFETY: `name` is NUL-terminated and outlives the call; `found` receives a buffer CredFree releases.
        let ok = unsafe { CredReadW(name.as_ptr(), CRED_TYPE_GENERIC, 0, &raw mut found) };
        if ok == 0 {
            // SAFETY: reads the last error CredReadW set.
            if unsafe { GetLastError() } == ERROR_NOT_FOUND {
                return Ok(None);
            }
            return Err(failure("read"));
        }
        let keyword = wide(LAYOUT_KEYWORD);
        // SAFETY: CredReadW succeeded: `found`, its blob and its attributes are live and sized as given until CredFree.
        let stored = unsafe {
            let credential = &*found;
            let size = credential.CredentialBlobSize as usize;
            let blob = if credential.CredentialBlob.is_null() || size == 0 {
                Zeroizing::new(Vec::new())
            } else {
                let blob = std::slice::from_raw_parts_mut(credential.CredentialBlob, size);
                let copied = Zeroizing::new(blob.to_vec());
                // CredFree releases the block as it is, so the decrypted text would stay in freed memory.
                blob.zeroize();
                copied
            };
            let attributes = if credential.Attributes.is_null() {
                &[][..]
            } else {
                std::slice::from_raw_parts(credential.Attributes, credential.AttributeCount as usize)
            };
            let layout = attributes
                .iter()
                .find(|attribute| names(attribute.Keyword, &keyword))
                .filter(|attribute| !attribute.Value.is_null())
                .and_then(|attribute| {
                    Layout::from_bytes(std::slice::from_raw_parts(
                        attribute.Value,
                        attribute.ValueSize as usize,
                    ))
                });
            Stored { blob, layout }
        };
        // SAFETY: `found` came from CredReadW and is freed once.
        unsafe { CredFree(found.cast_const().cast()) };
        Ok(Some(stored))
    }

    fn write(&self, target: &str, blob: &[u8], label: &str, layout: Option<Layout>) -> Result<(), SecretError> {
        let name = wide(target);
        let mut comment = wide(credential_parts::fitted(label, COMMENT_UNITS));
        let mut user = wide("TablePro");
        let size = u32::try_from(blob.len()).map_err(|_| SecretError::Backend {
            detail: "a part of the secret is too long for Credential Manager".to_owned(),
            service_message: None,
        })?;
        // SAFETY: every field of CREDENTIALW is a number or a pointer, for which zero is valid.
        let mut credential: CREDENTIALW = unsafe { std::mem::zeroed() };
        credential.Type = CRED_TYPE_GENERIC;
        credential.TargetName = name.as_ptr().cast_mut();
        credential.Comment = comment.as_mut_ptr();
        credential.CredentialBlobSize = size;
        // CredWriteW reads the blob and never writes through the pointer.
        credential.CredentialBlob = if blob.is_empty() {
            std::ptr::null_mut()
        } else {
            blob.as_ptr().cast_mut()
        };
        credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
        credential.UserName = user.as_mut_ptr();
        let mut keyword = wide(LAYOUT_KEYWORD);
        let mut value = layout.map(Layout::to_bytes);
        let mut attribute = CREDENTIAL_ATTRIBUTEW::default();
        if let Some(value) = value.as_mut() {
            attribute.Keyword = keyword.as_mut_ptr();
            attribute.ValueSize = Layout::SIZE as u32;
            attribute.Value = value.as_mut_ptr();
            credential.AttributeCount = 1;
            credential.Attributes = &raw mut attribute;
        }
        // SAFETY: every pointer in `credential` points into a buffer that outlives the call.
        let ok = unsafe { CredWriteW(&raw const credential, 0) };
        if ok == 0 {
            return Err(failure("write"));
        }
        Ok(())
    }

    fn delete(&self, target: &str) -> Result<bool, SecretError> {
        let name = wide(target);
        // SAFETY: `name` is NUL-terminated and outlives the call.
        if unsafe { CredDeleteW(name.as_ptr(), CRED_TYPE_GENERIC, 0) } != 0 {
            return Ok(true);
        }
        // SAFETY: reads the last error CredDeleteW set.
        if unsafe { GetLastError() } == ERROR_NOT_FOUND {
            return Ok(false);
        }
        Err(failure("delete"))
    }
}

// The keyword is NUL-terminated, and a shorter one differs at its NUL before anything past it is read.
unsafe fn names(keyword: *const u16, expected: &[u16]) -> bool {
    if keyword.is_null() {
        return false;
    }
    for (index, unit) in expected.iter().enumerate() {
        // SAFETY: every unit before `index` matched one of `expected`'s, none of which is the NUL before its last.
        if unsafe { *keyword.add(index) } != *unit {
            return false;
        }
    }
    true
}

fn read(target: &str) -> Result<Option<SecretString>, SecretError> {
    match credential_parts::read_secret(&Credentials, target)? {
        Some(blob) => decode(&blob).map(Some),
        None => Ok(None),
    }
}

fn write(target: &str, secret: &str, label: &str) -> Result<(), SecretError> {
    // Sized up front: a collect that grew would leave parts of the secret in the buffers it gave up.
    let mut blob: Zeroizing<Vec<u8>> = Zeroizing::new(Vec::with_capacity(secret.encode_utf16().count() * 2));
    blob.extend(secret.encode_utf16().flat_map(u16::to_le_bytes));
    credential_parts::write_secret(&Credentials, target, &blob, label, PART_SIZE)
}

fn delete(target: &str) -> Result<(), SecretError> {
    credential_parts::delete_secret(&Credentials, target)
}

#[async_trait]
impl SecretVault for CredentialManager {
    async fn store(&self, id: Uuid, kind: SecretKind, secret: &SecretString, label: &str) -> Result<(), SecretError> {
        let target = self.connection_target(id, kind);
        let (secret, label) = (secret.clone(), label.to_owned());
        self.blocking(move || write(&target, secret.expose_secret(), &label))
            .await
    }

    async fn load(&self, id: Uuid, kind: SecretKind) -> Result<SecretLookup, SecretError> {
        let target = self.connection_target(id, kind);
        let found = self.blocking(move || read(&target)).await?;
        Ok(found.map_or(SecretLookup::NotStored, SecretLookup::Found))
    }

    async fn relabel(&self, id: Uuid, kind: SecretKind, label: &str) -> Result<(), SecretError> {
        let target = self.connection_target(id, kind);
        let label = label.to_owned();
        self.blocking(move || match read(&target)? {
            Some(secret) => write(&target, secret.expose_secret(), &label),
            None => Ok(()),
        })
        .await
    }

    async fn delete_kind(&self, id: Uuid, kind: SecretKind) -> Result<(), SecretError> {
        let target = self.connection_target(id, kind);
        self.blocking(move || delete(&target)).await
    }

    async fn delete_connection(&self, id: Uuid) -> Result<(), SecretError> {
        let targets: Vec<String> = SecretKind::ALL
            .iter()
            .map(|kind| self.connection_target(id, *kind))
            .collect();
        self.blocking(move || targets.iter().try_for_each(|target| delete(target)))
            .await
    }
}

#[async_trait]
impl SecretItems for CredentialManager {
    async fn load_item(&self, item: SecretItem) -> Result<Option<SecretString>, SecretError> {
        let target = self.item_target(item);
        self.blocking(move || read(&target)).await
    }

    async fn store_item(&self, item: SecretItem, secret: &SecretString) -> Result<(), SecretError> {
        let target = self.item_target(item);
        let secret = secret.clone();
        let label = english_item_label(item);
        self.blocking(move || write(&target, secret.expose_secret(), &label))
            .await
    }

    async fn delete_item(&self, item: SecretItem) -> Result<(), SecretError> {
        let target = self.item_target(item);
        self.blocking(move || delete(&target)).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runtime;

    fn manager() -> CredentialManager {
        CredentialManager::new(format!("TableProTest-{}", Uuid::new_v4()), runtime::tasks().unwrap())
    }

    #[tokio::test]
    async fn a_password_is_kept_in_credential_manager_and_read_back() {
        let manager = manager();
        let id = Uuid::new_v4();

        manager
            .store(
                id,
                SecretKind::DatabasePassword,
                &SecretString::from("p\u{e4}ss \u{1f511}"),
                "label",
            )
            .await
            .unwrap();
        let found = manager.load(id, SecretKind::DatabasePassword).await.unwrap();
        manager.delete_connection(id).await.unwrap();
        let gone = manager.load(id, SecretKind::DatabasePassword).await.unwrap();

        assert_eq!(
            found.found().map(|secret| secret.expose_secret().to_owned()),
            Some("p\u{e4}ss \u{1f511}".to_owned())
        );
        assert!(!gone.is_stored());
    }

    #[tokio::test]
    async fn an_empty_password_is_stored_as_one() {
        let manager = manager();
        let id = Uuid::new_v4();

        manager
            .store(id, SecretKind::DatabasePassword, &SecretString::from(""), "label")
            .await
            .unwrap();
        let found = manager.load(id, SecretKind::DatabasePassword).await.unwrap();
        manager.delete_connection(id).await.unwrap();

        assert_eq!(
            found.found().map(|secret| secret.expose_secret().to_owned()),
            Some(String::new())
        );
    }

    #[tokio::test]
    async fn a_token_longer_than_one_credential_holds_is_kept_whole_under_a_long_label() {
        let manager = manager();
        let id = Uuid::new_v4();
        // The key's two UTF-16 units straddle the first credential's last byte.
        let token = format!("{}\u{1f511}{}", "a".repeat(PART_SIZE / 2 - 1), "b".repeat(2000));
        let label = "l".repeat(1000);

        manager
            .store(
                id,
                SecretKind::DatabasePassword,
                &SecretString::from(token.clone()),
                &label,
            )
            .await
            .unwrap();
        let found = manager.load(id, SecretKind::DatabasePassword).await.unwrap();
        manager
            .store(id, SecretKind::DatabasePassword, &SecretString::from("short"), &label)
            .await
            .unwrap();
        let shortened = manager.load(id, SecretKind::DatabasePassword).await.unwrap();
        let continued = Credentials
            .read(&format!(
                "{}/1",
                manager.connection_target(id, SecretKind::DatabasePassword)
            ))
            .unwrap();
        manager.delete_connection(id).await.unwrap();

        assert_eq!(
            found.found().map(|secret| secret.expose_secret().to_owned()),
            Some(token)
        );
        assert_eq!(
            shortened.found().map(|secret| secret.expose_secret().to_owned()),
            Some("short".to_owned())
        );
        assert!(continued.is_none());
    }

    #[tokio::test]
    async fn a_secret_that_fills_a_credential_exactly_reads_back() {
        let manager = manager();
        let id = Uuid::new_v4();
        let secret = "x".repeat(PART_SIZE);

        manager
            .store(
                id,
                SecretKind::SshPassphrase,
                &SecretString::from(secret.clone()),
                "label",
            )
            .await
            .unwrap();
        let found = manager.load(id, SecretKind::SshPassphrase).await.unwrap();
        manager.delete_connection(id).await.unwrap();
        let gone = manager.load(id, SecretKind::SshPassphrase).await.unwrap();

        assert_eq!(
            found.found().map(|secret| secret.expose_secret().to_owned()),
            Some(secret)
        );
        assert!(!gone.is_stored());
    }

    #[tokio::test]
    async fn relabelling_keeps_the_secret_and_a_missing_one_stays_missing() {
        let manager = manager();
        let id = Uuid::new_v4();

        manager
            .store(id, SecretKind::SshPassword, &SecretString::from("hunter2"), "old")
            .await
            .unwrap();
        manager.relabel(id, SecretKind::SshPassword, "new").await.unwrap();
        manager.relabel(id, SecretKind::SshPassphrase, "new").await.unwrap();
        let kept = manager.load(id, SecretKind::SshPassword).await.unwrap();
        let missing = manager.load(id, SecretKind::SshPassphrase).await.unwrap();
        manager.delete_connection(id).await.unwrap();

        assert_eq!(
            kept.found().map(|secret| secret.expose_secret().to_owned()),
            Some("hunter2".to_owned())
        );
        assert!(!missing.is_stored());
    }

    #[tokio::test]
    async fn a_deleted_item_is_gone() {
        let manager = manager();
        let item = SecretItem::McpToken;

        manager.store_item(item, &SecretString::from("token")).await.unwrap();
        manager.delete_item(item).await.unwrap();

        assert!(manager.load_item(item).await.unwrap().is_none());
    }

    #[tokio::test]
    async fn an_item_is_kept_apart_from_the_connections() {
        let manager = manager();
        let item = SecretItem::AiKey(AiProvider::OpenAi);

        manager.store_item(item, &SecretString::from("sk-test")).await.unwrap();
        manager.delete_connection(Uuid::new_v4()).await.unwrap();
        let found = manager.load_item(item).await.unwrap();
        manager.delete_item(item).await.unwrap();
        let gone = manager.load_item(item).await.unwrap();

        assert_eq!(
            found.map(|secret| secret.expose_secret().to_owned()),
            Some("sk-test".to_owned())
        );
        assert!(gone.is_none());
    }

    #[tokio::test]
    async fn writes_from_many_tasks_at_once_all_hold() {
        let managers: Vec<CredentialManager> = (0..16).map(|_| manager()).collect();
        let id = Uuid::new_v4();

        let found = futures::future::join_all(managers.iter().enumerate().map(|(index, manager)| async move {
            let secret = format!("secret {index}");
            manager
                .store(
                    id,
                    SecretKind::DatabasePassword,
                    &SecretString::from(secret.clone()),
                    "label",
                )
                .await
                .unwrap();
            let read = manager.load(id, SecretKind::DatabasePassword).await.unwrap();
            manager.delete_connection(id).await.unwrap();
            let gone = manager.load(id, SecretKind::DatabasePassword).await.unwrap();
            (
                read.found().map(|read| read.expose_secret() == secret),
                gone.is_stored(),
            )
        }))
        .await;

        assert!(
            found.iter().all(|(read, gone)| *read == Some(true) && !gone),
            "{found:?}"
        );
    }
}
