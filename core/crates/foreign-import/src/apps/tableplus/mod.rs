mod connection;
mod favorites;
mod form_values;
mod linux;
mod locations;

use std::collections::HashMap;
use std::io::Cursor;
use std::path::Path;
use std::sync::Arc;

use secrecy::SecretString;
use tokio_util::sync::CancellationToken;

use self::connection::{Dialect, Entry, Group, Mapping, group_path, groups_from_plist};
use self::linux::ObjectList;
use self::locations::{ConnectionStore, Layout, StoreFormat};
use crate::app::{AppReader, check_cancel};
use crate::collect::assemble;
use crate::{
    CollectedImport, ForeignApp, ForeignAppDirs, ForeignConnectionRecord, ForeignCredentials, ForeignImportError,
    ForeignKeychain, ImportRequest, Inventory, KeychainRead, PasswordOutcome,
};

const KEYCHAIN_SERVICE: &str = "com.tableplus.TablePlus";

pub(crate) struct TablePlus {
    layout: Layout,
    dirs: ForeignAppDirs,
    keychain: Option<Arc<dyn ForeignKeychain>>,
    key_file_exists: fn(&Path) -> bool,
}

impl TablePlus {
    fn new(
        layout: Layout,
        dirs: ForeignAppDirs,
        keychain: Option<Arc<dyn ForeignKeychain>>,
        key_file_exists: fn(&Path) -> bool,
    ) -> Self {
        Self {
            layout,
            dirs,
            keychain,
            key_file_exists,
        }
    }

    pub(crate) fn locate(dirs: &ForeignAppDirs, keychain: Option<Arc<dyn ForeignKeychain>>) -> Self {
        Self::new(locations::layout(dirs), dirs.clone(), keychain, Path::exists)
    }

    fn present_stores(&self) -> impl Iterator<Item = &ConnectionStore> {
        self.layout
            .stores
            .iter()
            .filter(|store| store.connections_file().exists())
    }

    // Only the macOS app keeps its passwords where another app may ask for them.
    fn readable_keychain(&self, request: &ImportRequest) -> Option<&dyn ForeignKeychain> {
        if !request.include_passwords || self.layout.dialect != Dialect::MacOs {
            return None;
        }
        self.keychain.as_deref()
    }
}

impl AppReader for TablePlus {
    fn has_data(&self) -> bool {
        self.present_stores().next().is_some()
    }

    // Only the entries collect reads, so the count says what an import brings; the macOS app
    // counts every entry, unreadable ones included.
    fn inventory(&self) -> Inventory {
        let mapping = Mapping {
            dialect: self.layout.dialect,
            dirs: &self.dirs,
            key_file_exists: self.key_file_exists,
        };
        Inventory {
            connections: self
                .present_stores()
                .map(|store| {
                    load_entries(store).map_or(0, |entries| {
                        entries
                            .iter()
                            .filter(|entry| mapping.connection(entry).is_some())
                            .count()
                    })
                })
                .sum(),
            saved_queries: favorites::count(&self.layout.favorite_roots),
        }
    }

    fn collect(
        &self,
        request: &ImportRequest,
        cancel: &CancellationToken,
    ) -> Result<CollectedImport, ForeignImportError> {
        let stores: Vec<&ConnectionStore> = self.present_stores().collect();
        if stores.is_empty() {
            return Err(ForeignImportError::FileNotFound {
                app: ForeignApp::TablePlus,
            });
        }
        let keychain = self.readable_keychain(request);
        let mapping = Mapping {
            dialect: self.layout.dialect,
            dirs: &self.dirs,
            key_file_exists: self.key_file_exists,
        };
        let mut stopped = false;
        let mut records = Vec::new();
        for store in stores {
            let entries = load_entries(store)?;
            let groups = load_groups(store);
            for entry in entries {
                check_cancel(cancel)?;
                let Some(settings) = mapping.connection(&entry) else {
                    tracing::warn!("skipping a TablePlus connection that could not be read");
                    continue;
                };
                let credentials = match (keychain, entry.id.as_deref()) {
                    (Some(keychain), Some(id)) if !stopped => read_credentials(keychain, id, &entry, &mut stopped),
                    _ => None,
                };
                records.push(ForeignConnectionRecord {
                    group_path: group_path(entry.group_id.as_deref(), &groups),
                    source_id: entry.id,
                    settings,
                    credentials,
                });
            }
        }

        let saved_queries = if request.include_saved_queries {
            favorites::saved_queries(
                &self.layout.favorite_roots,
                request.saved_query_byte_limit,
                self.layout.reads_keywords,
                cancel,
            )?
        } else {
            Vec::new()
        };

        let passwords = match (request.include_passwords, keychain) {
            (false, _) => PasswordOutcome::NotRequested,
            (true, None) => PasswordOutcome::LeftInKeychain,
            (true, Some(_)) if stopped => PasswordOutcome::Stopped,
            (true, Some(_)) => PasswordOutcome::Read,
        };
        assemble(ForeignApp::TablePlus, records, saved_queries, passwords)
    }
}

fn load_entries(store: &ConnectionStore) -> Result<Vec<Entry>, ForeignImportError> {
    let path = store.connections_file();
    let data = crate::files::read_capped(&path).map_err(|source| ForeignImportError::Unreadable { path, source })?;
    match store.format {
        StoreFormat::Plist => {
            let root = plist::Value::from_reader(Cursor::new(data)).ok();
            let dictionaries = root
                .as_ref()
                .and_then(plist::Value::as_array)
                .and_then(|items| {
                    items
                        .iter()
                        .map(plist::Value::as_dictionary)
                        .collect::<Option<Vec<_>>>()
                })
                .ok_or_else(|| {
                    ForeignImportError::unsupported("Expected array of dictionaries in Connections.plist")
                })?;
            Ok(dictionaries.into_iter().map(Entry::from_plist).collect())
        }
        StoreFormat::Json => {
            let list = ObjectList::parse(&data)
                .filter(ObjectList::all_objects)
                .ok_or_else(|| ForeignImportError::unsupported("Expected a list of objects in connections.json"))?;
            Ok(list.objects.iter().map(linux::entry).collect())
        }
    }
}

fn load_groups(store: &ConnectionStore) -> HashMap<String, Group> {
    let Ok(data) = crate::files::read_capped(store.groups_file()) else {
        return HashMap::new();
    };
    match store.format {
        StoreFormat::Plist => plist::Value::from_reader(Cursor::new(data))
            .map(|root| groups_from_plist(&root))
            .unwrap_or_default(),
        StoreFormat::Json => ObjectList::parse(&data)
            .map(|list| linux::groups(&list))
            .unwrap_or_default(),
    }
}

// A refused prompt stops every read after it, this connection's included.
fn read_credentials(
    keychain: &dyn ForeignKeychain,
    id: &str,
    entry: &Entry,
    stopped: &mut bool,
) -> Option<ForeignCredentials> {
    let mut read = |suffix: &str| -> Option<SecretString> {
        if *stopped {
            return None;
        }
        match keychain.read_password(KEYCHAIN_SERVICE, Some(&format!("{id}_{suffix}"))) {
            KeychainRead::Found(secret) => Some(secret),
            KeychainRead::NotFound => None,
            KeychainRead::Denied => {
                *stopped = true;
                None
            }
        }
    };
    let password = if entry.database_password_mode().stores_password_in_keychain() {
        read("database")
    } else {
        None
    };
    let ssh_password = if entry.server_password_mode().stores_password_in_keychain() {
        read("server")
    } else {
        None
    };
    let key_passphrase = read("server_key");
    ForeignCredentials {
        password,
        ssh_password,
        key_passphrase,
    }
    .non_empty()
}

#[cfg(test)]
mod tests {
    use std::fs;

    use std::sync::Mutex;

    use super::*;
    use crate::{ForeignPlatform, SavedQueryContent};

    struct Keychain {
        calls: Mutex<Vec<String>>,
        deny: bool,
    }

    impl ForeignKeychain for Keychain {
        fn read_password(&self, _service: &str, account: Option<&str>) -> KeychainRead {
            if let Ok(mut calls) = self.calls.lock() {
                calls.push(account.unwrap_or_default().to_owned());
            }
            if self.deny {
                KeychainRead::Denied
            } else {
                KeychainRead::Found(SecretString::from("s3cret"))
            }
        }
    }

    fn write_connections(folder: &Path, names: &[&str]) {
        let entries = names
            .iter()
            .map(|name| {
                let mut entry = plist::Dictionary::new();
                entry.insert("ConnectionName".to_owned(), plist::Value::String((*name).to_owned()));
                entry.insert("ID".to_owned(), plist::Value::String(format!("id-{name}")));
                plist::Value::Dictionary(entry)
            })
            .collect();
        fs::create_dir_all(folder).expect("a folder");
        plist::Value::Array(entries)
            .to_file_binary(folder.join("Connections.plist"))
            .expect("a plist");
    }

    fn reader(home: &Path, dialect: Dialect, keychain: Arc<Keychain>) -> TablePlus {
        let platform = match dialect {
            Dialect::MacOs => ForeignPlatform::MacOs,
            Dialect::Windows => ForeignPlatform::Windows,
            Dialect::Linux => ForeignPlatform::Linux,
        };
        let layout = Layout {
            dialect,
            stores: vec![ConnectionStore {
                folder: home.join("Data"),
                format: StoreFormat::Plist,
            }],
            favorite_roots: favorites::roots(home.join("Data/Favorite"), Vec::new()),
            reads_keywords: true,
        };
        TablePlus::new(
            layout,
            ForeignAppDirs::conventional(platform, home),
            Some(keychain),
            |_| false,
        )
    }

    fn request(include_passwords: bool) -> ImportRequest {
        ImportRequest {
            include_passwords,
            include_saved_queries: true,
            saved_query_byte_limit: 1_000,
        }
    }

    #[test]
    fn a_denied_prompt_stops_every_later_read() {
        let home = tempfile::tempdir().expect("a temp dir");
        write_connections(&home.path().join("Data"), &["A", "B"]);
        let keychain = Arc::new(Keychain {
            calls: Mutex::new(Vec::new()),
            deny: true,
        });
        let collected = reader(home.path(), Dialect::MacOs, Arc::clone(&keychain))
            .collect(&request(true), &CancellationToken::new())
            .expect("an import");
        assert_eq!(collected.passwords, PasswordOutcome::Stopped);
        assert_eq!(*keychain.calls.lock().expect("calls"), ["id-A_database"]);
        assert!(
            collected
                .connections
                .iter()
                .all(|connection| connection.credentials.is_none())
        );
    }

    #[test]
    fn a_keychain_given_on_another_platform_is_never_asked() {
        let home = tempfile::tempdir().expect("a temp dir");
        write_connections(&home.path().join("Data"), &["A"]);
        let keychain = Arc::new(Keychain {
            calls: Mutex::new(Vec::new()),
            deny: false,
        });
        let collected = reader(home.path(), Dialect::Windows, Arc::clone(&keychain))
            .collect(&request(true), &CancellationToken::new())
            .expect("an import");
        assert_eq!(collected.passwords, PasswordOutcome::LeftInKeychain);
        assert!(keychain.calls.lock().expect("calls").is_empty());
    }

    #[test]
    fn a_cancelled_import_stops_with_an_error() {
        let home = tempfile::tempdir().expect("a temp dir");
        write_connections(&home.path().join("Data"), &["A"]);
        fs::create_dir_all(home.path().join("Data/Favorite")).expect("a folder");
        fs::write(home.path().join("Data/Favorite/q.sql"), "SELECT 1").expect("a file");
        let keychain = Arc::new(Keychain {
            calls: Mutex::new(Vec::new()),
            deny: false,
        });
        let tableplus = reader(home.path(), Dialect::MacOs, keychain);
        let cancel = CancellationToken::new();
        cancel.cancel();
        assert!(matches!(
            tableplus.collect(&request(false), &cancel),
            Err(ForeignImportError::Cancelled)
        ));
        let collected = tableplus
            .collect(&request(false), &CancellationToken::new())
            .expect("an import");
        assert_eq!(
            collected.saved_queries[0].content,
            SavedQueryContent::Text("SELECT 1".to_owned())
        );
    }
}
