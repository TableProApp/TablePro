mod audit_journal;
mod connection_bundle;
mod connection_bundle_crypto;
mod connection_color;
mod connection_organization;
mod connection_url;
mod connections;
mod error;
mod favorites;
mod file_access;
mod paths;
pub mod query_history;
mod secrets;

pub use audit_journal::{AuditJournal, AuditJournalRecovery, LegacyJournalRotation, sample_event};
pub use connection_bundle::{
    BUNDLE_EXCLUDED_FIELDS, BUNDLE_FORMAT, BUNDLE_INCLUDED_FIELDS, BUNDLE_VERSION, BundleBody, BundleConnection,
    BundleError, BundleExport, BundleOrganization, BundleSecrets, BundleSshSecret, BundleSshSecretKind,
    EncryptedBundle, ImportDisposition, ImportItem, ImportPlan, MAX_BUNDLE_BYTES, MAX_BUNDLE_CONNECTIONS,
    MAX_SSH_HOPS as BUNDLE_MAX_SSH_HOPS, ParsedBundle, bundle_organization, collect_bundle_secrets, export_encrypted,
    export_plaintext, forget_imported_bundle_secrets, forget_imported_secrets, parse_bundle, plan_import,
    store_bundle_secrets,
};
pub use connection_color::{
    CONNECTION_COLORS, CONNECTION_STRIP_CLASSES, connection_color, connection_color_css_class, connection_strip_class,
};
pub use connection_organization::{
    ConnectionOrganization, ConnectionOrganizationIndex, MAX_LABEL_LEN, MAX_ORGANIZED_CONNECTIONS,
    MAX_TAGS_PER_CONNECTION, arrange_connections, connection_matches_filter, load_organization, save_organization,
};
pub use connection_url::{ParsedConnectionUrl, parse_connection_url};
pub use connections::{
    SavedConnection, SavedSshAuth, SavedSshConfig, SshClient, apply_import, delete_connection, duplicate_connection,
    load_connections, restore_connection, save_connections, touch_last_opened,
};
pub use error::{KeyringFailure, StorageError};
pub use favorites::{
    SavedQuery, delete_favorite, load_favorites, matches_filter, rank_favorites, save_favorite, touch_favorite,
};
pub use paths::{config_path, data_path, secret_schema, storage_dir_name};
pub use secrets::{
    SshHopSecretKind, delete_mcp_token, delete_password, delete_ssh_hop_passphrase, delete_ssh_hop_password,
    delete_ssh_passphrase, delete_ssh_password, load_mcp_token, load_password, load_ssh_hop_passphrase,
    load_ssh_hop_password, load_ssh_passphrase, load_ssh_password, store_mcp_token, store_password,
    store_ssh_hop_passphrase, store_ssh_hop_password, store_ssh_passphrase, store_ssh_password,
};
