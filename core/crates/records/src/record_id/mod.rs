// 0052: one id form per kind, computed the same way for CloudKit and TablePro Sync.

use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::envelope::SecretKind;
use crate::kind::Kind;

mod key_object;

pub use key_object::{KeyObjectId, KeyPurpose, Recipient, SasStep};

pub const MAX_UTF16_UNITS: usize = 255;
pub const DIGEST_PREFIX: &str = "sha256-";

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum IdError {
    #[error("a record id is 1 to 255 UTF-16 code units without NUL")]
    Syntax,
    #[error("the id is not in the form 0052 gives a {kind} record")]
    Form { kind: Kind },
}

impl IdError {
    pub const fn code(&self) -> &'static str {
        "records.bad_record_id"
    }
}

// 0051, Kinds: valid UTF-8 (a `&str` is), no U+0000, 1 to 255 UTF-16 code units.
pub fn well_formed(id: &str) -> bool {
    let units = id.encode_utf16().count();
    (1..=MAX_UTF16_UNITS).contains(&units) && !id.contains('\0')
}

// A pulled record whose id fails its kind's form stays unapplied and is logged (0052, Every id).
pub fn check(kind: Kind, id: &str) -> Result<(), IdError> {
    if !well_formed(id) {
        return Err(IdError::Syntax);
    }
    let fits = match kind {
        Kind::Connection
        | Kind::Group
        | Kind::Tag
        | Kind::SshProfile
        | Kind::CredentialProfile
        | Kind::SavedQuery
        | Kind::SavedQueryFolder
        | Kind::TableFolder
        | Kind::ConnectionProject => parse_uuid(id).is_some(),
        Kind::HistoryEntry => parse_uuid(id).is_some_and(|uuid| uuid.get_version_num() == 4),
        Kind::FavouriteTable | Kind::FavouriteDatabase | Kind::TableFolderItem => is_digest(id),
        Kind::MacosSettings | Kind::IosSettings | Kind::LinuxSettings | Kind::WindowsSettings => {
            digest_form(id) || crate::settings::registry(kind).is_some_and(|registry| registry.names(id))
        }
        Kind::SecretEnvelope => digest_form(id) || parse_envelope_id(id).is_some(),
        Kind::LibraryConnection | Kind::LibraryFolder | Kind::LibraryQuery => true,
        Kind::KeyAccount
        | Kind::KeyDevice
        | Kind::KeyRecovery
        | Kind::KeyReset
        | Kind::KeyCancel
        | Kind::KeyRequest
        | Kind::KeySas
        | Kind::KeyVersion
        | Kind::KeyWrap
        | Kind::KeyRing
        | Kind::KeyMember => KeyObjectId::parse(kind, id).is_some(),
    };
    if fits { Ok(()) } else { Err(IdError::Form { kind }) }
}

// Upper case, as `uuidString` writes it (0052, Every id).
pub fn uuid_id(id: Uuid) -> String {
    id.hyphenated().to_string().to_uppercase()
}

// Only the upper-case 8-4-4-4-12 form; nothing is case-folded.
pub fn parse_uuid(id: &str) -> Option<Uuid> {
    let canonical = id.len() == 36
        && id.bytes().enumerate().all(|(index, byte)| match index {
            8 | 13 | 18 | 23 => byte == b'-',
            _ => byte.is_ascii_digit() || (b'A'..=b'F').contains(&byte),
        });
    canonical.then(|| Uuid::try_parse(id).ok()).flatten()
}

// A random UUIDv4, the id of a history entry and of anything new a device names (0052).
pub fn new_id() -> String {
    uuid_id(Uuid::new_v4())
}

pub fn sha256_hex(text: &str) -> String {
    hex::encode(Sha256::digest(text.as_bytes()))
}

// `SyncRecordType.recordName(for:)`: past 255 UTF-16 code units with the kind's CloudKit prefix, the id becomes a
// digest of itself. A kind CloudKit does not carry has an empty prefix.
pub fn shortened(kind: Kind, id: String) -> String {
    let prefix = crate::cloudkit::prefix(kind);
    if prefix.encode_utf16().count() + id.encode_utf16().count() <= MAX_UTF16_UNITS {
        return id;
    }
    format!("{DIGEST_PREFIX}{}", sha256_hex(&id))
}

fn digest_form(id: &str) -> bool {
    id.strip_prefix(DIGEST_PREFIX).is_some_and(is_digest)
}

fn is_digest(text: &str) -> bool {
    text.len() == 64
        && text
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

// `IdentityPath.escaped`: `\` as `\\`, then the separator as `\` and the separator.
fn escaped(component: &str) -> String {
    if !component.contains(['|', '\\']) {
        return component.to_owned();
    }
    component.replace('\\', "\\\\").replace('|', "\\|")
}

fn escaped_path(components: &[&str]) -> String {
    components
        .iter()
        .map(|part| escaped(part))
        .collect::<Vec<_>>()
        .join("|")
}

// A favourite table's id, and the legacy alias Macs before 0.77 wrote when a name holds `|` or `\`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FavouriteTableId {
    pub id: String,
    pub alias: Option<String>,
}

pub fn favourite_table(connection: Uuid, database: Option<&str>, schema: Option<&str>, name: &str) -> FavouriteTableId {
    let connection = uuid_id(connection);
    let components = [connection.as_str(), database.unwrap_or(""), schema.unwrap_or(""), name];
    let plain = components.join("|");
    let path = escaped_path(&components);
    if path == plain {
        return FavouriteTableId {
            id: sha256_hex(&path),
            alias: None,
        };
    }
    FavouriteTableId {
        id: sha256_hex(&escaped_path(&["escaped", &path])),
        alias: Some(sha256_hex(&plain)),
    }
}

// No escaping: the UUID has a fixed length and holds no `|`. The environment is left out, so filing a database
// under another one keeps its record.
pub fn favourite_database(connection: Uuid, database: &str) -> String {
    sha256_hex(&format!("{}|{database}", uuid_id(connection)))
}

pub fn table_folder_item(connection: Uuid, database: &str, schema: Option<&str>, name: &str) -> String {
    let connection = uuid_id(connection);
    sha256_hex(&escaped_path(&[&connection, database, schema.unwrap_or(""), name]))
}

pub const COLUMN_LAYOUT_PREFIX: &str = "columnLayout.";
pub const THEME_PREFIX: &str = "theme.";

// `columnLayout.<table key>`, each part percent-encoded as Foundation's `.alphanumerics` encoding does it: every
// UTF-8 byte but an ASCII letter or digit becomes `%` and two upper-case hex digits.
pub fn column_layout_category(connection: Uuid, database: Option<&str>, schema: Option<&str>, table: &str) -> String {
    let parts = [
        percent_encoded(&uuid_id(connection)),
        percent_encoded(database.unwrap_or("")),
        percent_encoded(schema.unwrap_or("")),
        percent_encoded(table),
    ];
    format!("{COLUMN_LAYOUT_PREFIX}{}", parts.join("."))
}

fn percent_encoded(text: &str) -> String {
    let mut encoded = String::with_capacity(text.len());
    for byte in text.bytes() {
        if byte.is_ascii_alphanumeric() {
            encoded.push(char::from(byte));
        } else {
            encoded.push_str(&format!("%{byte:02X}"));
        }
    }
    encoded
}

// The connection a column layout category belongs to. The Mac's parser takes a raw hyphen as well as `%2D`.
pub fn column_layout_connection(category: &str) -> Option<Uuid> {
    let key = category.strip_prefix(COLUMN_LAYOUT_PREFIX)?;
    let parts: Vec<&str> = key.split('.').collect();
    let [connection, _, _, _] = parts.as_slice() else {
        return None;
    };
    if !parts.iter().all(|part| {
        part.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'%' || b == b'-')
    }) {
        return None;
    }
    Uuid::try_parse(&connection.replace("%2D", "-")).ok()
}

// `theme.<theme id>`, the id the theme file declares: 1 to 128 bytes of letters, digits, `.`, `_` and `-`, no `..`.
pub fn theme_category(theme_id: &str) -> Option<String> {
    let valid = !theme_id.is_empty()
        && theme_id.len() <= 128
        && !theme_id.contains("..")
        && theme_id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'));
    valid.then(|| format!("{THEME_PREFIX}{theme_id}"))
}

// 0052, Secret envelopes: the parent's kind, its record id and the secret kind, joined with `/`.
pub fn envelope_id(parent: Kind, parent_id: &str, secret: &SecretKind) -> String {
    format!("{parent}/{parent_id}/{secret}")
}

// The parent's id is what lies between the first and the last `/`, since neither kind holds one.
pub fn parse_envelope_id(id: &str) -> Option<(Kind, &str, SecretKind)> {
    let (parent, rest) = id.split_once('/')?;
    let (parent_id, secret) = rest.rsplit_once('/')?;
    let parent = Kind::parse(parent).ok()??;
    let secret = SecretKind::parse(parent, secret)?;
    check(parent, parent_id).ok()?;
    Some((parent, parent_id, secret))
}

// 0052, Team scope: a new team record takes the stored id of the same kind matching the entity's UUID once both are
// lower-cased, else the UUID in lower case, as `TeamLibraryID.of` gives it.
pub fn library_id<'a>(entity: Uuid, stored: impl IntoIterator<Item = &'a str>) -> String {
    let own = entity.hyphenated().to_string();
    stored
        .into_iter()
        .find(|id| library_ids_match(id, &own))
        .map_or(own, str::to_owned)
}

// `TeamLibraryID.same`: compared lower-cased, an empty reference naming nothing.
pub fn library_ids_match(left: &str, right: &str) -> bool {
    !left.is_empty() && !right.is_empty() && left.to_lowercase() == right.to_lowercase()
}

#[cfg(test)]
mod tests;
