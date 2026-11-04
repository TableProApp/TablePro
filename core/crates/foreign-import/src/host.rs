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

pub trait ForeignHost: Send + Sync {
    // `None` when the platform cannot tell, so an app counts as there when its files are.
    fn installed(&self, _app: ForeignApp) -> Option<bool> {
        None
    }

    fn keychain(&self) -> Option<Arc<dyn ForeignKeychain>> {
        None
    }
}

// Linux and Windows: no installed-app lookup and no other app's keychain.
#[derive(Debug, Clone, Copy, Default)]
pub struct PlainHost;

impl ForeignHost for PlainHost {}
