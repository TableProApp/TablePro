mod query_favorites;

use std::collections::BTreeMap;
use std::io::Cursor;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use plist::{Dictionary, Value};
use secrecy::SecretString;
use tokio_util::sync::CancellationToken;

use crate::app::{AppReader, check_cancel};
use crate::apps::resolve_key_path;
use crate::collect::assemble;
use crate::{
    CollectedImport, ForeignApp, ForeignAppDirs, ForeignColor, ForeignConnection, ForeignConnectionRecord,
    ForeignCredentials, ForeignImportError, ForeignKeychain, ForeignSsh, ForeignSshAuth, ForeignSsl, ForeignSslMode,
    ImportRequest, Inventory, KeychainRead, PasswordOutcome,
};

const DEFAULT_PORT: u16 = 3306;
const SSH_TUNNEL_TYPE: i64 = 2;

pub(crate) struct SequelAce {
    favorites: PathBuf,
    query_favorites: PathBuf,
    keychain: Option<Arc<dyn ForeignKeychain>>,
}

impl SequelAce {
    pub(crate) fn new(
        favorites: PathBuf,
        query_favorites: PathBuf,
        keychain: Option<Arc<dyn ForeignKeychain>>,
    ) -> Self {
        Self {
            favorites,
            query_favorites,
            keychain,
        }
    }

    pub(crate) fn locate(dirs: &ForeignAppDirs, keychain: Option<Arc<dyn ForeignKeychain>>) -> Self {
        let library = ["Library", "Containers", "com.sequel-ace.sequel-ace", "Data", "Library"]
            .iter()
            .fold(dirs.home.clone(), |path, part| path.join(part));
        Self::new(
            library
                .join("Application Support")
                .join("Sequel Ace")
                .join("Data")
                .join("Favorites.plist"),
            // Query favorites live in the app's sandboxed preferences, not beside the connections.
            library.join("Preferences").join("com.sequel-ace.sequel-ace.plist"),
            keychain,
        )
    }
}

impl AppReader for SequelAce {
    fn has_data(&self) -> bool {
        self.favorites.exists()
    }

    fn inventory(&self) -> Inventory {
        let connections = read_dictionary(&self.favorites)
            .as_ref()
            .and_then(favorites_children)
            .map_or(0, |children| count_connections(&children));
        Inventory {
            connections,
            saved_queries: query_favorites::count(&self.query_favorites),
        }
    }

    fn collect(
        &self,
        request: &ImportRequest,
        cancel: &CancellationToken,
    ) -> Result<CollectedImport, ForeignImportError> {
        if !self.favorites.exists() {
            return Err(ForeignImportError::FileNotFound {
                app: ForeignApp::SequelAce,
            });
        }
        let root = read_dictionary(&self.favorites)
            .ok_or_else(|| ForeignImportError::parse("Could not read Favorites.plist"))?;
        let children = favorites_children(&root)
            .ok_or_else(|| ForeignImportError::unsupported("Missing Favorites Root or Children key"))?;

        let mut passwords = match (request.include_passwords, self.keychain.as_deref()) {
            (true, Some(keychain)) => Some(KeychainPasswords {
                keychain,
                stopped: false,
            }),
            _ => None,
        };
        let mut records = Vec::new();
        parse_children(&children, &[], &mut passwords, &mut records, cancel)?;

        let saved_queries = if request.include_saved_queries {
            query_favorites::saved_queries(&self.query_favorites, request.saved_query_byte_limit, cancel)?
        } else {
            Vec::new()
        };

        let outcome = match passwords {
            _ if !request.include_passwords => PasswordOutcome::NotRequested,
            None => PasswordOutcome::LeftInKeychain,
            Some(passwords) if passwords.stopped => PasswordOutcome::Stopped,
            Some(_) => PasswordOutcome::Read,
        };
        assemble(ForeignApp::SequelAce, records, saved_queries, outcome)
    }
}

fn read_dictionary(path: &Path) -> Option<Dictionary> {
    let data = crate::files::read_capped(path).ok()?;
    Value::from_reader(Cursor::new(data)).ok()?.into_dictionary()
}

fn favorites_children(root: &Dictionary) -> Option<Vec<&Dictionary>> {
    let favorites_root = root.get("Favorites Root")?.as_dictionary()?;
    dictionaries(favorites_root.get("Children"))
}

// A list counts only when every item is a dictionary, as Swift's cast to `[[String: Any]]` does.
fn dictionaries(value: Option<&Value>) -> Option<Vec<&Dictionary>> {
    value?.as_array()?.iter().map(Value::as_dictionary).collect()
}

// The rule `parse_children` reads by, so the count says what an import brings. The macOS app
// counts by `host` and a numeric `id` instead, which can disagree with what it reads.
fn count_connections(children: &[&Dictionary]) -> usize {
    children
        .iter()
        .map(|child| match dictionaries(child.get("Children")) {
            Some(children) => count_connections(&children),
            None => 1,
        })
        .sum()
}

fn parse_children(
    children: &[&Dictionary],
    group_path: &[String],
    passwords: &mut Option<KeychainPasswords<'_>>,
    records: &mut Vec<ForeignConnectionRecord>,
    cancel: &CancellationToken,
) -> Result<(), ForeignImportError> {
    for child in children {
        check_cancel(cancel)?;
        if let Some(sub_children) = dictionaries(child.get("Children")) {
            let mut path = group_path.to_vec();
            path.push(text(child, "Name").unwrap_or("Untitled Group").to_owned());
            parse_children(&sub_children, &path, passwords, records, cancel)?;
            continue;
        }
        let credentials = passwords.as_mut().and_then(|passwords| passwords.credentials(child));
        records.push(ForeignConnectionRecord {
            source_id: number_or_text(child.get("id")),
            settings: connection(child),
            group_path: group_path.to_vec(),
            credentials,
        });
    }
    Ok(())
}

fn connection(entry: &Dictionary) -> ForeignConnection {
    let connection_type = integer(entry.get("type")).unwrap_or(0);
    ForeignConnection {
        name: text(entry, "name").unwrap_or("Untitled").to_owned(),
        host: text(entry, "host").unwrap_or("localhost").to_owned(),
        port: port(entry.get("port")).unwrap_or(DEFAULT_PORT),
        database: text(entry, "database").unwrap_or_default().to_owned(),
        username: text(entry, "user").unwrap_or_default().to_owned(),
        engine: "MySQL".to_owned(),
        ssh: ssh(entry, connection_type),
        ssl: ssl(entry),
        color: color(integer(entry.get("colorIndex")).unwrap_or(-1)),
        additional_fields: BTreeMap::new(),
    }
}

fn ssh(entry: &Dictionary, connection_type: i64) -> Option<ForeignSsh> {
    if connection_type != SSH_TUNNEL_TYPE {
        return None;
    }
    let key_enabled = integer(entry.get("sshKeyLocationEnabled")).unwrap_or(0) != 0;
    Some(ForeignSsh {
        host: text(entry, "sshHost").unwrap_or_default().to_owned(),
        port: port(entry.get("sshPort")),
        username: text(entry, "sshUser").unwrap_or_default().to_owned(),
        auth: if key_enabled {
            ForeignSshAuth::PrivateKey
        } else {
            ForeignSshAuth::Password
        },
        private_key_path: if key_enabled {
            resolve_key_path(text(entry, "sshKeyLocation").unwrap_or_default())
        } else {
            String::new()
        },
        jump_hosts: Vec::new(),
    })
}

fn ssl(entry: &Dictionary) -> Option<ForeignSsl> {
    if integer(entry.get("useSSL")).unwrap_or(0) == 0 {
        return None;
    }
    let path = |key: &str| text(entry, key).map(str::to_owned);
    Some(ForeignSsl {
        mode: ForeignSslMode::Required,
        ca_certificate_path: path("sslCACertFileLocation"),
        client_certificate_path: path("sslCertificateFileLocation"),
        client_key_path: path("sslKeyFileLocation"),
    })
}

fn color(index: i64) -> Option<ForeignColor> {
    match index {
        0 => Some(ForeignColor::Red),
        1 => Some(ForeignColor::Orange),
        2 => Some(ForeignColor::Yellow),
        3 => Some(ForeignColor::Green),
        4 => Some(ForeignColor::Blue),
        5 => Some(ForeignColor::Purple),
        6 => Some(ForeignColor::Pink),
        7 => Some(ForeignColor::Gray),
        _ => None,
    }
}

struct KeychainPasswords<'a> {
    keychain: &'a dyn ForeignKeychain,
    stopped: bool,
}

impl KeychainPasswords<'_> {
    fn credentials(&mut self, entry: &Dictionary) -> Option<ForeignCredentials> {
        if self.stopped {
            return None;
        }
        let name = text(entry, "name").unwrap_or_default();
        let id = number_or_text(entry.get("id")).unwrap_or_else(|| "0".to_owned());
        let user = text(entry, "user").unwrap_or_default();
        let host = text(entry, "host").unwrap_or_default();
        let database = text(entry, "database").unwrap_or_default();

        let password = self.read(
            &format!("Sequel Ace : {name} ({id})"),
            &format!("{user}@{host}/{database}"),
        );
        let ssh_password = if integer(entry.get("type")).unwrap_or(0) == SSH_TUNNEL_TYPE {
            let ssh_user = text(entry, "sshUser").unwrap_or_default();
            let ssh_host = text(entry, "sshHost").unwrap_or_default();
            self.read(
                &format!("Sequel Ace SSHTunnel : {name} ({id})"),
                &format!("{ssh_user}@{ssh_host}"),
            )
        } else {
            None
        };

        if password.is_none() && ssh_password.is_none() {
            return None;
        }
        Some(ForeignCredentials {
            password,
            ssh_password,
            key_passphrase: None,
        })
    }

    fn read(&mut self, service: &str, account: &str) -> Option<SecretString> {
        if self.stopped {
            return None;
        }
        match self.keychain.read_password(service, Some(account)) {
            KeychainRead::Found(password) => Some(password),
            KeychainRead::NotFound => None,
            KeychainRead::Denied => {
                tracing::info!("the keychain refused a Sequel Ace password, so the rest are not read");
                self.stopped = true;
                None
            }
        }
    }
}

fn text<'a>(entry: &'a Dictionary, key: &str) -> Option<&'a str> {
    entry.get(key).and_then(Value::as_string)
}

// What Swift's `as? Int` gives for a property list value: a boolean is 0 or 1, a real only when whole.
fn integer(value: Option<&Value>) -> Option<i64> {
    match value? {
        Value::Integer(number) => number.as_signed(),
        Value::Boolean(flag) => Some(i64::from(*flag)),
        Value::Real(real) => whole(*real),
        _ => None,
    }
}

fn whole(real: f64) -> Option<i64> {
    // 2^63: the first whole value past i64::MAX, and the magnitude of i64::MIN.
    const LIMIT: f64 = 9_223_372_036_854_775_808.0;
    (real.fract() == 0.0 && (-LIMIT..LIMIT).contains(&real)).then_some(real as i64)
}

// A number, else a decimal string. A port past what a port can hold reads as no port.
fn port(value: Option<&Value>) -> Option<u16> {
    let number = integer(value).or_else(|| value?.as_string()?.parse::<i64>().ok())?;
    u16::try_from(number).ok()
}

// NSNumber's `stringValue`, or the string itself.
fn number_or_text(value: Option<&Value>) -> Option<String> {
    match value? {
        Value::Integer(number) => Some(number.to_string()),
        Value::Boolean(flag) => Some(u8::from(*flag).to_string()),
        Value::Real(real) => Some(whole(*real).map_or_else(|| real.to_string(), |number| number.to_string())),
        Value::String(text) => Some(text.clone()),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dictionary(pairs: &[(&str, Value)]) -> Dictionary {
        pairs
            .iter()
            .map(|(key, value)| ((*key).to_owned(), value.clone()))
            .collect()
    }

    #[test]
    fn numbers_read_as_swift_reads_them_as_int() {
        assert_eq!(integer(Some(&Value::Integer(2.into()))), Some(2));
        assert_eq!(integer(Some(&Value::Boolean(true))), Some(1));
        assert_eq!(integer(Some(&Value::Boolean(false))), Some(0));
        assert_eq!(integer(Some(&Value::Real(3306.0))), Some(3306));
        assert_eq!(integer(Some(&Value::Real(3306.5))), None);
        assert_eq!(integer(Some(&Value::Real(f64::NAN))), None);
        assert_eq!(integer(Some(&Value::Integer(u64::MAX.into()))), None);
        assert_eq!(integer(Some(&Value::String("1".to_owned()))), None);
        assert_eq!(integer(None), None);
    }

    #[test]
    fn an_id_reads_as_nsnumber_string_value_or_as_text() {
        assert_eq!(
            number_or_text(Some(&Value::Integer((-42).into()))).as_deref(),
            Some("-42")
        );
        assert_eq!(
            number_or_text(Some(&Value::Integer(u64::MAX.into()))).as_deref(),
            Some("18446744073709551615")
        );
        assert_eq!(number_or_text(Some(&Value::Boolean(true))).as_deref(), Some("1"));
        assert_eq!(number_or_text(Some(&Value::Real(42.0))).as_deref(), Some("42"));
        assert_eq!(number_or_text(Some(&Value::Real(1.5))).as_deref(), Some("1.5"));
        assert_eq!(
            number_or_text(Some(&Value::String("abc".to_owned()))).as_deref(),
            Some("abc")
        );
        assert_eq!(number_or_text(Some(&Value::Data(vec![1]))), None);
    }

    #[test]
    fn a_port_is_a_number_or_a_decimal_string_that_fits() {
        assert_eq!(port(Some(&Value::Integer(2222.into()))), Some(2222));
        assert_eq!(port(Some(&Value::String("3333".to_owned()))), Some(3333));
        assert_eq!(port(Some(&Value::String(String::new()))), None);
        assert_eq!(port(Some(&Value::String(" 22".to_owned()))), None);
        assert_eq!(port(Some(&Value::Integer(70_000.into()))), None);
        assert_eq!(port(None), None);
    }

    #[test]
    fn a_children_list_with_a_non_dictionary_item_is_not_a_group() {
        let entry = dictionary(&[
            ("name", Value::String("Odd".to_owned())),
            ("Children", Value::Array(vec![Value::String("x".to_owned())])),
        ]);
        assert!(dictionaries(entry.get("Children")).is_none());
        let mut records = Vec::new();
        parse_children(&[&entry], &[], &mut None, &mut records, &CancellationToken::new()).expect("parsed");
        assert_eq!(records.len(), 1);
        assert_eq!(records[0].settings.name, "Odd");
        assert_eq!(count_connections(&[&entry]), 1);
    }

    #[test]
    fn counting_follows_the_same_children_rule_as_reading() {
        let group_with_host = dictionary(&[
            ("host", Value::String("db".to_owned())),
            (
                "Children",
                Value::Array(vec![
                    Value::Dictionary(dictionary(&[("host", Value::String("a".to_owned()))])),
                    Value::Dictionary(dictionary(&[("host", Value::String("b".to_owned()))])),
                ]),
            ),
        ]);
        let bare = dictionary(&[("name", Value::String("Bare".to_owned()))]);
        let numbered = dictionary(&[("id", Value::Integer(7.into()))]);
        let children = [&group_with_host, &bare, &numbered];
        assert_eq!(count_connections(&children), 4);

        let mut records = Vec::new();
        parse_children(&children, &[], &mut None, &mut records, &CancellationToken::new()).expect("parsed");
        let names: Vec<&str> = records.iter().map(|record| record.settings.name.as_str()).collect();
        assert_eq!(names, ["Untitled", "Untitled", "Bare", "Untitled"]);
        assert_eq!(records[0].group_path, ["Untitled Group"]);
        assert_eq!(records[2].settings.host, "localhost");
        assert_eq!(records[3].source_id.as_deref(), Some("7"));
    }

    #[test]
    fn reading_stops_when_cancelled() {
        let entry = dictionary(&[("name", Value::String("A".to_owned()))]);
        let cancel = CancellationToken::new();
        cancel.cancel();
        let outcome = parse_children(&[&entry], &[], &mut None, &mut Vec::new(), &cancel);
        assert!(matches!(outcome, Err(ForeignImportError::Cancelled)));
    }
}
