use std::collections::BTreeMap;

use secrecy::SecretString;

// Set in `additional_fields` when the app saved TLS settings the importer cannot read, so the review
// says so and leaves the connection unchecked instead of importing it with TLS off.
pub const TLS_SETTINGS_UNREAD: &str = "tlsSettingsUnread";

// Set in `additional_fields` when the app's own SSL setting reads off but it or its driver encrypts
// anyway, so the review says where the imported TLS came from.
pub const TLS_FROM_DRIVER_DEFAULT: &str = "tlsFromDriverDefault";

// The fields follow the macOS app's exported connection, so every platform maps the same record.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ForeignConnection {
    pub name: String,
    pub host: String,
    pub port: u16,
    pub database: String,
    pub username: String,
    // TablePro's engine name (`MySQL`, `SQL Server`), or the other app's word when TablePro has none.
    pub engine: String,
    pub ssh: Option<ForeignSsh>,
    pub ssl: Option<ForeignSsl>,
    pub color: Option<ForeignColor>,
    // Keyed as the macOS app keys them, such as `promptForPassword` or `awsRegion`.
    pub additional_fields: BTreeMap<String, String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ForeignSsh {
    pub host: String,
    pub port: Option<u16>,
    pub username: String,
    pub auth: ForeignSshAuth,
    // As the app wrote it: absolute, `~/`-relative, or empty.
    pub private_key_path: String,
    pub jump_hosts: Vec<ForeignJumpHost>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ForeignJumpHost {
    pub host: String,
    pub port: Option<u16>,
    pub username: String,
    pub auth: ForeignSshAuth,
    pub private_key_path: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ForeignSshAuth {
    Password,
    PrivateKey,
    Agent,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ForeignSsl {
    pub mode: ForeignSslMode,
    pub ca_certificate_path: Option<String>,
    pub client_certificate_path: Option<String>,
    pub client_key_path: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ForeignSslMode {
    Disabled,
    Preferred,
    Required,
    VerifyCa,
    VerifyIdentity,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ForeignColor {
    Red,
    Orange,
    Yellow,
    Green,
    Blue,
    Purple,
    Pink,
    Gray,
}

#[derive(Debug, Clone, Default)]
pub struct ForeignCredentials {
    pub password: Option<SecretString>,
    pub ssh_password: Option<SecretString>,
    pub key_passphrase: Option<SecretString>,
}

impl ForeignCredentials {
    pub fn is_empty(&self) -> bool {
        self.password.is_none() && self.ssh_password.is_none() && self.key_passphrase.is_none()
    }

    pub fn non_empty(self) -> Option<Self> {
        if self.is_empty() { None } else { Some(self) }
    }
}

#[derive(Debug, Clone)]
pub struct ForeignConnectionRecord {
    // The other app's id for the connection, which its saved queries name.
    pub source_id: Option<String>,
    pub settings: ForeignConnection,
    pub group_path: Vec<String>,
    pub credentials: Option<ForeignCredentials>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SavedQueryContent {
    Text(String),
    Oversized { byte_count: u64 },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ForeignSavedQuery {
    pub name: String,
    pub content: SavedQueryContent,
    pub keyword: Option<String>,
    pub folder_path: Vec<String>,
    pub source_connection_id: Option<String>,
    // Named by the other app, such as `console_3`, so the review leaves it unchecked.
    pub is_auto_named: bool,
}
