// Saved connections and queries read from other database clients' own files, mapped to TablePro's
// terms, then reviewed against a connection library and added to it.

mod app;
mod apps;
mod collect;
mod dirs;
mod engine;
mod error;
mod files;
mod host;
mod record;
pub mod review;
mod sql_file_tree;

pub use app::{ForeignApp, ForeignImporter, ImportRequest, Inventory, PasswordSource, SavedQuerySupport};
pub use collect::{CollectedConnection, CollectedImport, CollectedSavedQuery, PasswordOutcome};
pub use dirs::{ForeignAppDirs, ForeignPlatform};
pub use error::ForeignImportError;
pub use host::{ForeignHost, ForeignKeychain, KeychainRead, PlainHost};
pub use record::{
    ForeignColor, ForeignConnection, ForeignConnectionRecord, ForeignCredentials, ForeignJumpHost, ForeignSavedQuery,
    ForeignSsh, ForeignSshAuth, ForeignSsl, ForeignSslMode, SavedQueryContent, TLS_SETTINGS_UNREAD,
};
