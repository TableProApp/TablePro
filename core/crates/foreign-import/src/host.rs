use std::sync::Arc;

use secrecy::SecretString;

use crate::ForeignApp;

#[derive(Debug, Clone)]
pub enum KeychainRead {
    Found(SecretString),
    NotFound,
    // The user refused a prompt, or the keychain would not answer: the import stops asking.
    Denied,
}

// The keychain another app saved its passwords in. Only macOS lets one app read another's items,
// and only after the user allows it.
pub trait ForeignKeychain: Send + Sync {
    fn read_password(&self, service: &str, account: Option<&str>) -> KeychainRead;
}

// Windows' data protection API, which seals a blob to the signed-in user: another app's key sealed with it opens only
// for that user on that machine.
pub trait DataProtection: Send + Sync {
    fn unprotect(&self, blob: &[u8]) -> Option<Vec<u8>>;
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
}

// No installed-app lookup, no other app's keychain and no data protection.
#[derive(Debug, Clone, Copy, Default)]
pub struct PlainHost;

impl ForeignHost for PlainHost {}
