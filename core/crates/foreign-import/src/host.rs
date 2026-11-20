use std::sync::Arc;

use secrecy::SecretString;

use crate::ForeignApp;

#[derive(Debug, Clone)]
pub enum KeychainRead {
    Found(SecretString),
    NotFound,
    // The user refused a prompt, or the store would not answer: the import stops asking.
    Denied,
}

// The keychain another app saved its passwords in. Only macOS lets one app read another's items,
// and only after the user allows it.
pub trait ForeignKeychain: Send + Sync {
    fn read_password(&self, service: &str, account: Option<&str>) -> KeychainRead;
}

// Windows' data protection API, which seals a blob to the signed-in user: another app's key sealed with it opens only
// for that user on that machine, and only with the entropy it was sealed with, empty for none.
pub trait DataProtection: Send + Sync {
    fn unprotect(&self, blob: &[u8], entropy: &[u8]) -> Option<Vec<u8>>;
}

// Windows' Credential Manager, where any app the user runs reads the user's generic credentials with no prompt.
pub trait ForeignCredentialManager: Send + Sync {
    // The generic credential named `target`, its blob read as UTF-16 text, as Windows writes a password.
    fn read_generic(&self, target: &str) -> KeychainRead;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SecretScope {
    Everywhere,
    // Only the collection the `default` alias names; none when that names no collection the service lists.
    DefaultCollection,
}

// The Secret Service on Linux (GNOME Keyring, KWallet), which files each item in a collection under attributes.
pub trait ForeignSecretService: Send + Sync {
    // The secret of the first item holding every attribute given, an unlocked one before a locked one. A locked item is
    // unlocked first, which may prompt. No service on the session bus reads as `NotFound`.
    fn search(&self, scope: SecretScope, attributes: &[(&str, &str)]) -> KeychainRead;
}

pub trait ForeignHost: Send + Sync {
    // `None` when the platform cannot tell, so an app counts as there when its files are.
    fn installed(&self, _app: ForeignApp) -> Option<bool> {
        None
    }

    fn keychain(&self) -> Option<Arc<dyn ForeignKeychain>> {
        None
    }

    fn data_protection(&self) -> Option<Arc<dyn DataProtection>> {
        None
    }

    fn credential_manager(&self) -> Option<Arc<dyn ForeignCredentialManager>> {
        None
    }

    fn secret_service(&self) -> Option<Arc<dyn ForeignSecretService>> {
        None
    }
}

// No installed-app lookup and no other app's store of any kind.
#[derive(Debug, Clone, Copy, Default)]
pub struct PlainHost;

impl ForeignHost for PlainHost {}
