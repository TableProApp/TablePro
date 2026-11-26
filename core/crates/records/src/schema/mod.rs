use serde_json::Value;

use crate::kind::{Kind, Scope};

mod keys;
pub mod model;
mod personal;
mod readable;
mod sealed;
mod team;

pub use personal::{AI_POLICIES, COLORS, DRIVER_TYPES, EXTERNAL_ACCESS, SAFE_MODE_LEVELS, SSL_MODES, core_driver, wire_type};
pub use readable::readable;
pub use sealed::HISTORY_ENTRY;

// A kind's explicit wire schema (0051, What syncs): every member a record of it may carry, with its JSON type, its
// class (0044, Fields a pull applies only with approval) and whether it is content or placement (0051, Conflict rules).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Schema {
    pub kind: Kind,
    pub fields: &'static [Field],
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Field {
    pub key: &'static str,
    pub ty: Type,
    pub class: Class,
    pub role: Role,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Type {
    Text,
    Integer,
    // Any JSON number, such as a column's width.
    Number,
    Boolean,
    // Whole milliseconds since the Unix epoch, the precision a CloudKit date keeps (0052).
    Millis,
    // Another record's id, in that kind's form (0052, Every id).
    Reference(Kind),
    // Values the apps know; another value is kept as written and read as the loosest.
    Enum(&'static [&'static str]),
    List(&'static Type),
    Object(&'static [Field]),
    // An object keyed by data, which only the team library's bundle format carries.
    Map(&'static Type),
    // A map keyed by data, sent as a list of `{"id", "value"}` entries, so a key that reads as a secret's name, such as
    // a driver's field id or a column's name, is a value and never a member name (0051, What syncs).
    Entries(&'static Type),
    // Canonical base64url without padding (0056, Encoding); `None` when its length varies.
    Bytes(Option<usize>),
    // A settings category's options, which the platform's registry classes one by one.
    Options,
}

// A member with no mark counts as content (0051, Conflict rules).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    // A change revives a record deleted elsewhere.
    Content,
    // Order, parent, group, favourite or folder membership: a change never revives a deleted record.
    Placement,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Class {
    // Applied on pull.
    Inert,
    // A pulled change waits for the person on each device.
    Approval(Approval),
    // Never pushed.
    DeviceOnly,
    // Never applied on pull, so the device never edits it either (0044, startup SQL and tunnel commands in a team).
    Dropped,
    // Each entry takes the class its driver declares for its id (`entry_class`).
    ByEntry,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Approval {
    // Any change waits.
    Always,
    // A change to a later value in this list waits; the list runs strictest first, and a value not in it is loosest.
    Looser(&'static [&'static str]),
    // Turning it on waits.
    WhenOn,
    // A higher number waits.
    WhenHigher,
}

impl Approval {
    pub fn waits(self, held: Option<&Value>, pulled: Option<&Value>) -> bool {
        if held == pulled {
            return false;
        }
        match self {
            Self::Always => true,
            Self::Looser(order) => {
                let rank = |value: Option<&Value>| {
                    value
                        .and_then(Value::as_str)
                        .and_then(|text| order.iter().position(|known| *known == text))
                        .unwrap_or(order.len())
                };
                // A value removed or first set reads against the app's default, which the pull cannot be trusted
                // to know, so only the strictest value goes in unasked.
                match (held, pulled) {
                    (_, None) => true,
                    (None, Some(_)) => rank(pulled) > 0,
                    (Some(_), Some(_)) => rank(pulled) > rank(held),
                }
            }
            Self::WhenOn => pulled.and_then(Value::as_bool) != Some(false),
            Self::WhenHigher => match (held.and_then(Value::as_i64), pulled.and_then(Value::as_i64)) {
                (Some(held), Some(pulled)) => pulled > held,
                _ => true,
            },
        }
    }
}

impl Class {
    pub const fn is_pushed(self) -> bool {
        !matches!(self, Self::DeviceOnly | Self::Dropped)
    }
}

// The class of a driver's field from the trust its driver declares for the id, as the Mac's `ConnectionFieldTrust`
// names them. That trust says what may travel, not what weakens a protection: a driver keeps switches such as TLS
// verification among its settings, so every field that syncs waits for approval. A team drops scripts on pull (0051,
// What syncs).
pub fn entry_class(scope: Scope, trust: Option<&str>) -> Class {
    match trust {
        Some("secret" | "hostInternal") => Class::DeviceOnly,
        Some("ownDevices") if scope == Scope::Team => Class::Dropped,
        _ => Class::Approval(Approval::Always),
    }
}

impl Schema {
    pub fn field(&self, key: &str) -> Option<&'static Field> {
        self.fields.iter().find(|field| field.key == key)
    }

    // A member the schema does not name is content (0051, Conflict rules).
    pub fn role(&self, key: &str) -> Role {
        self.field(key).map_or(Role::Content, |field| field.role)
    }

    // A member the schema does not name waits for approval (0044).
    pub fn class(&self, key: &str) -> Class {
        self.field(key)
            .map_or(Class::Approval(Approval::Always), |field| field.class)
    }
}

pub fn schema(kind: Kind) -> Schema {
    let fields: &'static [Field] = match kind {
        Kind::Connection => personal::CONNECTION,
        Kind::Group => personal::GROUP,
        Kind::Tag => personal::TAG,
        Kind::SshProfile => personal::SSH_PROFILE,
        Kind::CredentialProfile => personal::CREDENTIAL_PROFILE,
        Kind::SavedQuery => personal::SAVED_QUERY,
        Kind::SavedQueryFolder => personal::SAVED_QUERY_FOLDER,
        Kind::FavouriteTable => personal::FAVOURITE_TABLE,
        Kind::FavouriteDatabase => personal::FAVOURITE_DATABASE,
        Kind::TableFolder => personal::TABLE_FOLDER,
        Kind::TableFolderItem => personal::TABLE_FOLDER_ITEM,
        Kind::ConnectionProject => personal::CONNECTION_PROJECT,
        Kind::MacosSettings | Kind::IosSettings | Kind::LinuxSettings | Kind::WindowsSettings => personal::SETTINGS,
        Kind::LibraryConnection => team::LIBRARY_CONNECTION,
        Kind::LibraryFolder => team::LIBRARY_FOLDER,
        Kind::LibraryQuery => team::LIBRARY_QUERY,
        Kind::SecretEnvelope | Kind::HistoryEntry => sealed::SEALED,
        Kind::KeyAccount | Kind::KeyMember => keys::ACCOUNT,
        Kind::KeyDevice => keys::DEVICE,
        Kind::KeyRecovery => keys::RECOVERY,
        Kind::KeyReset => keys::RESET,
        Kind::KeyCancel => keys::CANCEL,
        Kind::KeyRequest => keys::REQUEST,
        Kind::KeySas => keys::SAS,
        Kind::KeyVersion => keys::VERSION,
        Kind::KeyWrap => keys::WRAP,
        Kind::KeyRing => keys::RING,
    };
    Schema { kind, fields }
}

pub const ENTRY: &[Field] = &[
    Field {
        key: "id",
        ty: Type::Text,
        class: Class::Inert,
        role: Role::Content,
    },
    Field {
        key: "value",
        ty: Type::Text,
        class: Class::Inert,
        role: Role::Content,
    },
];

// Every key a schema names at any depth, as a dotted path.
pub fn paths(fields: &'static [Field]) -> Vec<String> {
    let mut found = Vec::new();
    collect(fields, "", &mut found);
    found
}

fn collect(fields: &'static [Field], prefix: &str, found: &mut Vec<String>) {
    for field in fields {
        let path = if prefix.is_empty() {
            field.key.to_owned()
        } else {
            format!("{prefix}.{}", field.key)
        };
        found.push(path.clone());
        if let Some(nested) = nested(&field.ty) {
            collect(nested, &path, found);
        }
    }
}

pub fn nested(ty: &Type) -> Option<&'static [Field]> {
    match ty {
        Type::Object(fields) => Some(fields),
        Type::List(inner) | Type::Map(inner) => nested(inner),
        Type::Entries(_) => Some(ENTRY),
        _ => None,
    }
}

// Whether a value has the JSON shape the type gives it. A known kind's record with a member of the wrong shape is not
// applied, as the Mac's decoder refuses one today.
pub fn conforms(ty: &Type, value: &Value) -> bool {
    match ty {
        Type::Text | Type::Enum(_) | Type::Reference(_) | Type::Bytes(_) => value.is_string(),
        Type::Integer | Type::Millis => value.is_i64() || value.is_u64(),
        Type::Number => value.is_number(),
        Type::Boolean => value.is_boolean(),
        Type::List(inner) => value
            .as_array()
            .is_some_and(|items| items.iter().all(|item| conforms(inner, item))),
        Type::Object(fields) => match value {
            Value::Object(members) => members.iter().all(|(key, member)| {
                fields
                    .iter()
                    .find(|field| field.key == key)
                    .is_none_or(|field| conforms(&field.ty, member))
            }),
            _ => false,
        },
        Type::Map(inner) => match value {
            Value::Object(members) => members.values().all(|member| conforms(inner, member)),
            _ => false,
        },
        Type::Entries(inner) => value.as_array().is_some_and(|items| {
            items.iter().all(|item| {
                item.get("id").is_some_and(Value::is_string)
                    && item.get("value").is_some_and(|value| conforms(inner, value))
            })
        }),
        Type::Options => value.is_object() || value.is_array(),
    }
}

#[cfg(test)]
mod tests;
