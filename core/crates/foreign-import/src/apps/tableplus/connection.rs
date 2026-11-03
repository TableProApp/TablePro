use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::Path;

use plist::{Dictionary, Value};

use super::form_values::{PasswordMode, tls_form};
use crate::apps::resolve_key_path;
use crate::engine::{self, LocalFilePathField};
use crate::{ForeignAppDirs, ForeignColor, ForeignConnection, ForeignSsh, ForeignSshAuth, ForeignSsl};

// The macOS library nests groups three deep; it cuts a deeper path there too.
const MAXIMUM_GROUP_DEPTH: usize = 3;

// The connection files differ by platform: the Windows app writes the macOS keys with its own
// value types, and the Linux app writes JSON under its own names.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Dialect {
    MacOs,
    Windows,
    Linux,
}

// One saved connection with the macOS key names, whatever file it came from.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(super) struct Entry {
    pub id: Option<String>,
    pub name: Option<String>,
    pub driver: Option<String>,
    pub host: Option<String>,
    pub port: Option<i64>,
    pub user: Option<String>,
    pub database_name: Option<String>,
    pub database_path: Option<String>,
    pub group_id: Option<String>,
    pub over_ssh: bool,
    pub ssh_host: Option<String>,
    pub ssh_port: Option<String>,
    pub ssh_user: Option<String>,
    pub use_private_key: bool,
    pub private_key_name: Option<String>,
    // Present when the connection has the `tLSMode` key at all.
    pub tls_mode: Option<i64>,
    pub tls_key_paths: Vec<String>,
    // TLS settings whose meaning is not known, kept only to say they were not read.
    pub tls_unread: bool,
    pub environment: Option<String>,
    pub database_password_mode: Option<i64>,
    pub server_password_mode: Option<i64>,
}

impl Entry {
    pub(super) fn from_plist(entry: &Dictionary) -> Self {
        let text = |key: &str| entry.get(key).and_then(Value::as_string).map(str::to_owned);
        Self {
            id: text("ID"),
            name: text("ConnectionName"),
            driver: text("Driver"),
            host: text("DatabaseHost"),
            port: entry.get("DatabasePort").and_then(port),
            user: text("DatabaseUser"),
            database_name: text("DatabaseName"),
            database_path: text("DatabasePath"),
            group_id: text("GroupID"),
            over_ssh: entry.get("isOverSSH").is_some_and(flag),
            ssh_host: text("ServerAddress"),
            ssh_port: text("ServerPort"),
            ssh_user: text("ServerUser"),
            use_private_key: entry.get("isUsePrivateKey").is_some_and(flag),
            private_key_name: text("ServerPrivateKeyName"),
            tls_mode: entry
                .contains_key("tLSMode")
                .then(|| entry.get("tLSMode").and_then(Value::as_signed_integer).unwrap_or(0)),
            tls_key_paths: entry.get("TlsKeyPaths").map(strings).unwrap_or_default(),
            tls_unread: false,
            environment: text("Enviroment"),
            database_password_mode: entry.get("DatabasePasswordMode").and_then(Value::as_signed_integer),
            server_password_mode: entry.get("ServerPasswordMode").and_then(Value::as_signed_integer),
        }
    }

    pub(super) fn database_password_mode(&self) -> PasswordMode {
        PasswordMode::from_index(self.database_password_mode)
    }

    pub(super) fn server_password_mode(&self) -> PasswordMode {
        PasswordMode::from_index(self.server_password_mode)
    }
}

fn port(value: &Value) -> Option<i64> {
    match value {
        Value::Integer(_) => value.as_signed_integer(),
        Value::String(text) => text.parse().ok(),
        _ => None,
    }
}

// The macOS app saves a Bool; the Windows app saves 0 or 1.
fn flag(value: &Value) -> bool {
    match value {
        Value::Boolean(on) => *on,
        Value::Integer(_) => value.as_signed_integer() == Some(1),
        _ => false,
    }
}

// All or nothing, as a list with one stray value reads as no list.
fn strings(value: &Value) -> Vec<String> {
    value
        .as_array()
        .and_then(|items| {
            items
                .iter()
                .map(|item| item.as_string().map(str::to_owned))
                .collect::<Option<Vec<_>>>()
        })
        .unwrap_or_default()
}

pub(super) struct Group {
    pub name: String,
    pub parent: Option<String>,
}

pub(super) fn groups_from_plist(root: &Value) -> HashMap<String, Group> {
    let Some(items) = root.as_array() else {
        return HashMap::new();
    };
    let Some(dictionaries) = items.iter().map(Value::as_dictionary).collect::<Option<Vec<_>>>() else {
        return HashMap::new();
    };
    let mut groups = HashMap::with_capacity(dictionaries.len());
    for group in dictionaries {
        let text = |key: &str| group.get(key).and_then(Value::as_string).map(str::to_owned);
        if let (Some(id), Some(name)) = (text("ID"), text("Name")) {
            groups.insert(
                id,
                Group {
                    name,
                    parent: text("GroupID"),
                },
            );
        }
    }
    groups
}

// Walks up through each group's own parent, root first.
pub(super) fn group_path(group_id: Option<&str>, groups: &HashMap<String, Group>) -> Vec<String> {
    let mut path = Vec::new();
    let mut seen = HashSet::new();
    let mut next = group_id.filter(|id| !id.is_empty());
    while let Some(id) = next {
        if !seen.insert(id) {
            break;
        }
        let Some(group) = groups.get(id) else {
            break;
        };
        path.push(group.name.clone());
        next = group.parent.as_deref().filter(|parent| !parent.is_empty());
    }
    path.reverse();
    path.truncate(MAXIMUM_GROUP_DEPTH);
    path
}

pub(super) struct Mapping<'a> {
    pub dialect: Dialect,
    pub dirs: &'a ForeignAppDirs,
    pub key_file_exists: fn(&Path) -> bool,
}

impl Mapping<'_> {
    // `None` for an entry with no name, which the app never writes.
    pub(super) fn connection(&self, entry: &Entry) -> Option<ForeignConnection> {
        let name = entry.name.clone()?;
        let driver = self.driver(entry.driver.as_deref().unwrap_or_default());
        let engine = engine_for_driver(driver);
        let file_path_field = engine::local_file_path_field(&engine);
        // The Windows app keeps a file engine's path where the host goes.
        let path_in_host =
            self.dialect == Dialect::Windows && file_path_field.is_some() && entry.database_path.is_none();
        let raw_path = if path_in_host {
            &entry.host
        } else {
            &entry.database_path
        };
        let file_path = file_path_field.and(raw_path.as_deref()).filter(|path| !path.is_empty());

        let host = if path_in_host { None } else { entry.host.clone() };
        let port = match entry.port.and_then(|port| u16::try_from(port).ok()) {
            Some(port) => port,
            None if file_path.is_none() => engine::default_port(&engine),
            None => 0,
        };

        let mut additional_fields = BTreeMap::new();
        let database = match (file_path, file_path_field) {
            (Some(path), Some(LocalFilePathField::Database)) => path.to_owned(),
            (Some(path), Some(LocalFilePathField::AdditionalField(field))) => {
                additional_fields.insert(field.to_owned(), path.to_owned());
                String::new()
            }
            _ => entry.database_name.clone().unwrap_or_default(),
        };
        if engine == "DynamoDB" {
            additional_fields.extend(dynamodb_fields(entry));
        }
        if entry.database_password_mode().prompts_for_password()
            && !engine::hides_built_in_password(&engine, &additional_fields)
        {
            additional_fields.insert("promptForPassword".to_owned(), "true".to_owned());
        }
        if entry.tls_unread {
            additional_fields.insert(crate::TLS_SETTINGS_UNREAD.to_owned(), "true".to_owned());
        }

        Some(ForeignConnection {
            name,
            host: host.unwrap_or_else(|| "localhost".to_owned()),
            port,
            database,
            username: entry.user.clone().unwrap_or_default(),
            ssh: self.ssh(entry),
            ssl: ssl(entry, driver),
            color: entry.environment.as_deref().and_then(environment_color),
            engine,
            additional_fields,
        })
    }

    // The Windows app reads its driver names in any case.
    fn driver<'a>(&self, driver: &'a str) -> &'a str {
        if self.dialect != Dialect::Windows {
            return driver;
        }
        KNOWN_DRIVERS
            .iter()
            .find(|known| known.eq_ignore_ascii_case(driver))
            .copied()
            .unwrap_or(driver)
    }

    fn ssh(&self, entry: &Entry) -> Option<ForeignSsh> {
        if !entry.over_ssh {
            return None;
        }
        let key_path = if entry.use_private_key {
            self.imported_key_path(entry.private_key_name.as_deref().unwrap_or_default())
        } else {
            String::new()
        };
        Some(ForeignSsh {
            host: entry.ssh_host.clone().unwrap_or_default(),
            port: entry
                .ssh_port
                .as_deref()
                .and_then(|port| port.parse::<i64>().ok())
                .and_then(|port| u16::try_from(port).ok()),
            username: entry.ssh_user.clone().unwrap_or_default(),
            auth: if entry.use_private_key {
                ForeignSshAuth::PrivateKey
            } else {
                ForeignSshAuth::Password
            },
            private_key_path: key_path,
            jump_hosts: Vec::new(),
        })
    }

    // A bare name is a key in `~/.ssh`, kept only when it is there: the app's empty picker
    // saves its placeholder text as the name.
    fn imported_key_path(&self, raw: &str) -> String {
        let trimmed = raw.trim_matches(is_inline_space);
        let resolved = resolve_key_path(trimmed);
        if resolved.is_empty() || resolved == trimmed {
            return resolved;
        }
        if (self.key_file_exists)(&self.dirs.expand_home(&resolved)) {
            resolved
        } else {
            String::new()
        }
    }
}

const KNOWN_DRIVERS: &[&str] = &[
    "MicrosoftSQLServer",
    "Mongo",
    "Cockroach",
    "CloudflareD1",
    "LibSQL",
    "ElasticSearch",
    "MySQL",
    "MariaDB",
    "PostgreSQL",
    "Greenplum",
    "Redshift",
    "Vertica",
    "Cassandra",
    "Redis",
    "ClickHouse",
    "Oracle",
];

fn engine_for_driver(driver: &str) -> String {
    match driver {
        "MicrosoftSQLServer" => "SQL Server".to_owned(),
        "Mongo" => "MongoDB".to_owned(),
        "Cockroach" => "CockroachDB".to_owned(),
        "CloudflareD1" => "Cloudflare D1".to_owned(),
        "LibSQL" => "libSQL".to_owned(),
        "ElasticSearch" => "Elasticsearch".to_owned(),
        _ => engine::resolve(driver),
    }
}

fn ssl(entry: &Entry, driver: &str) -> Option<ForeignSsl> {
    let form = tls_form(driver);
    let mode = *form.modes.get(usize::try_from(entry.tls_mode?).ok()?)?;
    let path = |slot: Option<usize>| {
        slot.and_then(|slot| entry.tls_key_paths.get(slot))
            .filter(|path| !path.is_empty())
            .cloned()
    };
    Some(ForeignSsl {
        mode,
        ca_certificate_path: path(form.slots.certificate_authority),
        client_certificate_path: path(form.slots.client_certificate),
        client_key_path: path(form.slots.client_key),
    })
}

// DynamoDB keeps its region in the host field and its access key ID in the user field.
fn dynamodb_fields(entry: &Entry) -> BTreeMap<String, String> {
    let mut fields = BTreeMap::from([("awsAuthMethod".to_owned(), "credentials".to_owned())]);
    let trimmed = |value: &Option<String>| {
        value
            .as_deref()
            .map(str::trim)
            .filter(|text| !text.is_empty())
            .map(str::to_owned)
    };
    if let Some(region) = trimmed(&entry.host) {
        fields.insert("awsRegion".to_owned(), region);
    }
    if let Some(access_key_id) = trimmed(&entry.user) {
        fields.insert("awsAccessKeyId".to_owned(), access_key_id);
    }
    fields
}

fn environment_color(environment: &str) -> Option<ForeignColor> {
    match environment {
        "staging" => Some(ForeignColor::Yellow),
        "production" => Some(ForeignColor::Red),
        "testing" => Some(ForeignColor::Blue),
        "development" => Some(ForeignColor::Green),
        _ => None,
    }
}

// Spaces and tabs, not line breaks.
fn is_inline_space(character: char) -> bool {
    character == '\t'
        || (character.is_whitespace()
            && !matches!(
                character,
                '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}'
            ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{ForeignPlatform, ForeignSslMode};

    fn groups(items: &[(&str, &str, Option<&str>)]) -> HashMap<String, Group> {
        items
            .iter()
            .map(|(id, name, parent)| {
                (
                    (*id).to_owned(),
                    Group {
                        name: (*name).to_owned(),
                        parent: parent.map(str::to_owned),
                    },
                )
            })
            .collect()
    }

    fn mapping(dirs: &ForeignAppDirs, dialect: Dialect, key_file_exists: fn(&Path) -> bool) -> Mapping<'_> {
        Mapping {
            dialect,
            dirs,
            key_file_exists,
        }
    }

    fn named(name: &str) -> Entry {
        Entry {
            name: Some(name.to_owned()),
            ..Entry::default()
        }
    }

    #[test]
    fn a_group_path_walks_parents_root_first_and_stops_at_a_cycle_or_three_levels() {
        let map = groups(&[
            ("a", "Servers", None),
            ("b", "EU", Some("a")),
            ("c", "Prod", Some("b")),
            ("d", "Deep", Some("c")),
            ("x", "Loop X", Some("y")),
            ("y", "Loop Y", Some("x")),
            ("orphan", "Orphan", Some("gone")),
        ]);
        assert_eq!(group_path(Some("b"), &map), ["Servers", "EU"]);
        assert_eq!(group_path(Some("d"), &map), ["Servers", "EU", "Prod"]);
        assert_eq!(group_path(Some("x"), &map), ["Loop Y", "Loop X"]);
        assert_eq!(group_path(Some("orphan"), &map), ["Orphan"]);
        assert!(group_path(Some("missing"), &map).is_empty());
        assert!(group_path(Some(""), &map).is_empty());
        assert!(group_path(None, &map).is_empty());
    }

    #[test]
    fn groups_read_as_none_when_one_item_is_not_a_dictionary() {
        let mut group = Dictionary::new();
        group.insert("ID".to_owned(), Value::String("g".to_owned()));
        group.insert("Name".to_owned(), Value::String("Prod".to_owned()));
        let good = Value::Array(vec![Value::Dictionary(group.clone())]);
        let mixed = Value::Array(vec![Value::Dictionary(group), Value::String("stray".to_owned())]);
        assert_eq!(groups_from_plist(&good).len(), 1);
        assert!(groups_from_plist(&mixed).is_empty());
    }

    #[test]
    fn flags_and_ports_accept_the_types_each_app_writes() {
        assert!(flag(&Value::Boolean(true)));
        assert!(flag(&Value::Integer(1_i64.into())));
        assert!(!flag(&Value::Integer(2_i64.into())));
        assert!(!flag(&Value::String("true".to_owned())));
        assert_eq!(port(&Value::Integer(5433_i64.into())), Some(5433));
        assert_eq!(port(&Value::String("5433".to_owned())), Some(5433));
        assert_eq!(port(&Value::String(" 5433".to_owned())), None);
        assert_eq!(port(&Value::String(String::new())), None);
        let mixed = Value::Array(vec![Value::String("a".to_owned()), Value::Integer(1_i64.into())]);
        assert!(strings(&mixed).is_empty());
    }

    #[test]
    fn a_bare_key_name_is_checked_in_the_ssh_folder_and_an_explicit_path_is_kept() {
        let dirs = ForeignAppDirs::conventional(ForeignPlatform::MacOs, Path::new("/Users/test"));
        let present = mapping(&dirs, Dialect::MacOs, |path| {
            path == Path::new("/Users/test/.ssh/id_rsa")
        });
        assert_eq!(present.imported_key_path(" id_rsa\t"), "~/.ssh/id_rsa");
        assert_eq!(present.imported_key_path("id_other"), "");
        assert_eq!(present.imported_key_path("/keys/id"), "/keys/id");
        assert_eq!(present.imported_key_path("~/keys/id"), "~/keys/id");
        assert_eq!(present.imported_key_path("C:\\keys\\id"), "C:\\keys\\id");
        assert_eq!(present.imported_key_path("  "), "");
    }

    #[test]
    fn a_windows_file_engine_reads_its_path_from_the_host_and_its_driver_in_any_case() {
        let dirs = ForeignAppDirs::conventional(ForeignPlatform::Windows, Path::new("C:/Users/test"));
        let windows = mapping(&dirs, Dialect::Windows, |_| false);
        let sqlite = Entry {
            driver: Some("sqlite".to_owned()),
            host: Some("C:\\data\\app.db".to_owned()),
            ..named("Local")
        };
        let connection = windows.connection(&sqlite).expect("a connection");
        assert_eq!(connection.engine, "SQLite");
        assert_eq!(connection.database, "C:\\data\\app.db");
        assert_eq!(connection.host, "localhost");
        assert_eq!(connection.port, 0);

        let postgres = Entry {
            driver: Some("postgresql".to_owned()),
            tls_mode: Some(4),
            ..named("Server")
        };
        let connection = windows.connection(&postgres).expect("a connection");
        assert_eq!(connection.engine, "PostgreSQL");
        assert_eq!(connection.ssl.map(|ssl| ssl.mode), Some(ForeignSslMode::VerifyCa));

        let macos = mapping(&dirs, Dialect::MacOs, |_| false);
        let connection = macos.connection(&sqlite).expect("a connection");
        assert_eq!(connection.database, "");
        assert_eq!(connection.host, "C:\\data\\app.db");
    }

    #[test]
    fn a_port_past_the_range_falls_back_to_the_engines_default() {
        let dirs = ForeignAppDirs::conventional(ForeignPlatform::MacOs, Path::new("/Users/test"));
        let entry = Entry {
            driver: Some("MySQL".to_owned()),
            port: Some(70_000),
            ..named("Wide")
        };
        let connection = mapping(&dirs, Dialect::MacOs, |_| false)
            .connection(&entry)
            .expect("a connection");
        assert_eq!(connection.port, 3306);
        assert!(
            mapping(&dirs, Dialect::MacOs, |_| false)
                .connection(&Entry::default())
                .is_none()
        );
    }
}
