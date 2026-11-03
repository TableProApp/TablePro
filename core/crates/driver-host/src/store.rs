// Installed drivers in the app's data folder: `<dir>/<install id>/<library>` per install and `installed.json`
// naming the current one of each driver. Every load opens the file, checks its checksum against the index and
// its signature, and only then maps it. A library that loaded is never unloaded, so a replaced or removed one
// stays until the app quits and its folder goes at the next start.

use std::collections::HashMap;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tablepro_driver_abi::proto::{self, Request, request, response};

use crate::error::PluginError;
use crate::handle::DriverHandle;
use crate::library::{DriverIdentity, DriverLibrary};
use crate::registry::{HostTarget, RegistryEntry};
use crate::trust::{Purpose, Trust, open_for_load};

pub const INDEX_FILE: &str = "installed.json";
// Held across every read-modify-write of the folder, so two app processes never interleave theirs.
const LOCK_FILE: &str = ".lock";
const DESCRIBE_TIMEOUT: Duration = Duration::from_secs(10);
const SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(5);

pub fn library_file_name() -> String {
    format!(
        "{}tablepro-driver{}",
        std::env::consts::DLL_PREFIX,
        std::env::consts::DLL_SUFFIX
    )
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Expected {
    pub id: String,
    pub version: String,
    pub sha256: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InstalledDriver {
    pub id: String,
    pub display_name: String,
    pub version: String,
    pub path: PathBuf,
    pub state: DriverState,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DriverState {
    Loaded { abi_major: u16, abi_minor: u16 },
    Failed(PluginError),
}

pub struct LoadedDriver {
    pub identity: DriverIdentity,
    pub description: proto::Description,
    pub handle: Arc<DriverHandle>,
    path: PathBuf,
    sha256: String,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct Index {
    drivers: Vec<IndexEntry>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct IndexEntry {
    id: String,
    display_name: String,
    version: String,
    folder: String,
    sha256: String,
}

#[derive(Default)]
struct State {
    attempted: HashMap<String, IndexEntry>,
    loaded: HashMap<String, LoadedDriver>,
    failed: HashMap<String, PluginError>,
    swept: bool,
}

pub struct DriverStore {
    dir: PathBuf,
    trust: Arc<dyn Trust>,
    state: Mutex<State>,
}

impl DriverStore {
    // Every method blocks on file work, signature checks and the driver's own start, so it runs on a thread
    // that may block.
    pub fn new(dir: PathBuf, trust: Arc<dyn Trust>) -> Self {
        Self {
            dir,
            trust,
            state: Mutex::new(State::default()),
        }
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    // Loads every installed driver not tried yet, in the order they were installed.
    pub fn installed(&self) -> Result<Vec<InstalledDriver>, PluginError> {
        let mut state = self.lock();
        let _folder = self.lock_folder()?;
        let index = self.read_index()?;
        self.reconcile(&mut state, &index);
        self.sweep(&mut state, &index);
        let mut drivers = Vec::with_capacity(index.drivers.len());
        for entry in &index.drivers {
            if !state.attempted.contains_key(&entry.id) {
                state.attempted.insert(entry.id.clone(), entry.clone());
                let path = self.dir.join(&entry.folder).join(library_file_name());
                let expected = Expected {
                    id: entry.id.clone(),
                    version: entry.version.clone(),
                    sha256: entry.sha256.clone(),
                };
                match self.admit(&path, Some(&expected), Purpose::Load) {
                    Ok(loaded) => {
                        state.loaded.insert(entry.id.clone(), loaded);
                    }
                    Err(error) => {
                        tracing::warn!(id = %entry.id, %error, "an installed driver did not load");
                        state.failed.insert(entry.id.clone(), error);
                    }
                }
            }
            drivers.push(self.describe_entry(&state, entry));
        }
        Ok(drivers)
    }

    pub fn install_file(&self, source: &Path, expected: Option<&Expected>) -> Result<InstalledDriver, PluginError> {
        let mut state = self.lock();
        let _folder = self.lock_folder()?;
        let mut index = self.read_index()?;
        self.sweep(&mut state, &index);
        let folder = uuid::Uuid::new_v4().simple().to_string();
        let directory = self.dir.join(&folder);
        let path = directory.join(library_file_name());
        let copied = std::fs::create_dir_all(&directory).and_then(|()| std::fs::copy(source, &path));
        if let Err(error) = copied {
            let _ = std::fs::remove_dir_all(&directory);
            return Err(PluginError::io(&format!("could not copy {}", source.display()), &error));
        }
        let loaded = match self.admit(&path, expected, Purpose::Install) {
            Ok(loaded) => loaded,
            Err(error) => {
                let _ = std::fs::remove_dir_all(&directory);
                return Err(error);
            }
        };
        let id = loaded.identity.id.clone();
        let entry = IndexEntry {
            id: id.clone(),
            display_name: loaded.description.display_name.clone(),
            version: loaded.identity.version.clone(),
            folder,
            sha256: loaded.sha256.clone(),
        };
        let replaced: Vec<IndexEntry> = index.drivers.extract_if(.., |old| old.id == id).collect();
        index.drivers.push(entry.clone());
        if let Err(error) = self.write_index(&index) {
            shut_down_later(loaded.handle);
            let _ = std::fs::remove_dir_all(&directory);
            return Err(error);
        }
        if let Some(old) = state.loaded.insert(id.clone(), loaded) {
            shut_down_later(old.handle);
        }
        state.failed.remove(&id);
        state.attempted.insert(id, entry.clone());
        for old in replaced {
            // A library still mapped cannot be deleted on Windows; the next start's sweep takes it.
            let _ = std::fs::remove_dir_all(self.dir.join(old.folder));
        }
        Ok(self.describe_entry(&state, &entry))
    }

    // `downloaded` is the release's file, fetched by the app from the release's URL.
    pub fn install_release(&self, entry: &RegistryEntry, downloaded: &Path) -> Result<InstalledDriver, PluginError> {
        let release = entry
            .release_for(HostTarget::current())
            .ok_or_else(|| PluginError::NoRelease { id: entry.id.clone() })?;
        let expected = Expected {
            id: entry.id.clone(),
            version: release.version.clone(),
            sha256: release.sha256.clone(),
        };
        self.install_file(downloaded, Some(&expected))
    }

    pub fn remove(&self, id: &str) -> Result<(), PluginError> {
        let mut state = self.lock();
        let _folder = self.lock_folder()?;
        let mut index = self.read_index()?;
        let removed: Vec<IndexEntry> = index.drivers.extract_if(.., |entry| entry.id == id).collect();
        if removed.is_empty() {
            return Err(PluginError::NotInstalled { id: id.to_owned() });
        }
        self.write_index(&index)?;
        if let Some(loaded) = state.loaded.remove(id) {
            loaded.handle.shutdown(SHUTDOWN_TIMEOUT);
        }
        state.failed.remove(id);
        state.attempted.remove(id);
        for entry in removed {
            let _ = std::fs::remove_dir_all(self.dir.join(entry.folder));
        }
        Ok(())
    }

    pub fn handle(&self, id: &str) -> Option<Arc<DriverHandle>> {
        self.lock().loaded.get(id).map(|loaded| Arc::clone(&loaded.handle))
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    // Released when the file closes, a crashed process's included.
    fn lock_folder(&self) -> Result<File, PluginError> {
        let path = self.dir.join(LOCK_FILE);
        let failed = |error: std::io::Error| PluginError::io(&format!("could not lock {}", path.display()), &error);
        std::fs::create_dir_all(&self.dir).map_err(failed)?;
        let file = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(&path)
            .map_err(failed)?;
        file.lock().map_err(failed)?;
        Ok(file)
    }

    fn admit(&self, path: &Path, expected: Option<&Expected>, purpose: Purpose) -> Result<LoadedDriver, PluginError> {
        // Held until the library is mapped, so the file checked is the file loaded.
        let file = open_for_load(path)?;
        let sha256 = sha256_of(&file, path)?;
        if let Some(expected) = expected
            && !expected.sha256.eq_ignore_ascii_case(&sha256)
        {
            return Err(PluginError::ChecksumMismatch {
                expected: expected.sha256.clone(),
                found: sha256,
            });
        }
        self.trust.verify(&file, path, purpose)?;
        // The trust policy vouched for this file, which remains held through mapping.
        let library = unsafe { DriverLibrary::load(path) }?;
        let identity = library.identity().clone();
        if let Some(expected) = expected
            && (expected.id != identity.id || expected.version != identity.version)
        {
            return Err(PluginError::WrongDriver {
                expected: expected.id.clone(),
                expected_version: expected.version.clone(),
                found: identity.id,
                found_version: identity.version,
            });
        }
        let handle = Arc::new(library.open()?);
        drop(file);
        let description = match describe(&handle, &identity.id) {
            Ok(description) if description.id == identity.id => description,
            Ok(description) => {
                shut_down_later(handle);
                return Err(PluginError::NotADriver {
                    path: path.display().to_string(),
                    detail: format!(
                        "its descriptor names {} and it describes itself as {}",
                        identity.id, description.id
                    ),
                });
            }
            Err(error) => {
                shut_down_later(handle);
                return Err(error);
            }
        };
        Ok(LoadedDriver {
            identity,
            description,
            handle,
            path: path.to_owned(),
            sha256,
        })
    }

    fn reconcile(&self, state: &mut State, index: &Index) {
        // Another process can replace or remove an installation while this process keeps its old handle.
        let stale: Vec<String> = state
            .attempted
            .extract_if(|_, attempted| !index.drivers.contains(attempted))
            .map(|(id, _)| id)
            .collect();
        for id in stale {
            if let Some(loaded) = state.loaded.remove(&id) {
                shut_down_later(loaded.handle);
            }
            state.failed.remove(&id);
        }
    }

    fn describe_entry(&self, state: &State, entry: &IndexEntry) -> InstalledDriver {
        let path = self.dir.join(&entry.folder).join(library_file_name());
        let driver_state = match (state.loaded.get(&entry.id), state.failed.get(&entry.id)) {
            (Some(loaded), _) => DriverState::Loaded {
                abi_major: loaded.identity.abi_major,
                abi_minor: loaded.handle.negotiated_minor(),
            },
            (None, Some(error)) => DriverState::Failed(error.clone()),
            (None, None) => DriverState::Failed(PluginError::NotInstalled { id: entry.id.clone() }),
        };
        InstalledDriver {
            id: entry.id.clone(),
            display_name: entry.display_name.clone(),
            version: entry.version.clone(),
            path: state.loaded.get(&entry.id).map_or(path, |loaded| loaded.path.clone()),
            state: driver_state,
        }
    }

    fn read_index(&self) -> Result<Index, PluginError> {
        let path = self.dir.join(INDEX_FILE);
        match std::fs::read(&path) {
            Ok(bytes) => {
                let mut index: Index = serde_json::from_slice(&bytes).map_err(|error| PluginError::Io {
                    detail: format!("{} is not readable: {error}", path.display()),
                })?;
                // A folder is always one this store named; anything else could point outside it.
                index.drivers.retain(|entry| {
                    let named = is_install_folder(&entry.folder);
                    if !named {
                        tracing::warn!(id = %entry.id, folder = %entry.folder, "an index entry names a foreign folder");
                    }
                    named
                });
                Ok(index)
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Index::default()),
            Err(error) => Err(PluginError::io(&format!("could not read {}", path.display()), &error)),
        }
    }

    fn write_index(&self, index: &Index) -> Result<(), PluginError> {
        let path = self.dir.join(INDEX_FILE);
        let staged = self
            .dir
            .join(format!("{INDEX_FILE}.{}.tmp", uuid::Uuid::new_v4().simple()));
        let text = serde_json::to_vec_pretty(index).map_err(|error| PluginError::Io {
            detail: error.to_string(),
        })?;
        // On disk before the rename, so a power loss leaves the old index or the new one, never half of one.
        let written = File::create(&staged)
            .and_then(|mut file| file.write_all(&text).and_then(|()| file.sync_all()))
            .and_then(|()| std::fs::rename(&staged, &path));
        if written.is_err() {
            let _ = std::fs::remove_file(&staged);
        }
        written.map_err(|error| PluginError::io(&format!("could not write {}", path.display()), &error))
    }

    // Once a process: the folders of removed and replaced drivers, which a running app may still have mapped.
    fn sweep(&self, state: &mut State, index: &Index) {
        if state.swept {
            return;
        }
        state.swept = true;
        let Ok(entries) = std::fs::read_dir(&self.dir) else {
            return;
        };
        for entry in entries.flatten() {
            let name = entry.file_name();
            let Some(name) = name.to_str() else {
                continue;
            };
            let listed = index.drivers.iter().any(|driver| driver.folder == name);
            let is_dir = entry.file_type().is_ok_and(|kind| kind.is_dir());
            if is_dir && is_install_folder(name) && !listed {
                let _ = std::fs::remove_dir_all(entry.path());
            } else if !is_dir && name.starts_with(INDEX_FILE) && name.ends_with(".tmp") {
                let _ = std::fs::remove_file(entry.path());
            }
        }
    }
}

fn is_install_folder(name: &str) -> bool {
    name.len() == 32 && name.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn describe(handle: &DriverHandle, id: &str) -> Result<proto::Description, PluginError> {
    let request = Request::of(request::Kind::Describe(proto::Describe {}));
    let reply = handle
        .call_blocking(&request, DESCRIBE_TIMEOUT)
        .map_err(|status| PluginError::OpenFailed {
            id: id.to_owned(),
            detail: format!("Describe was refused with status {status}"),
        })?
        .into_result()?;
    match reply.response.kind {
        Some(response::Kind::Description(description)) => Ok(description),
        _ => Err(PluginError::OpenFailed {
            id: id.to_owned(),
            detail: "Describe was answered with no description".to_owned(),
        }),
    }
}

fn shut_down_later(handle: Arc<DriverHandle>) {
    let _ = std::thread::Builder::new()
        .name("tablepro-driver-shutdown".to_owned())
        .spawn(move || handle.shutdown(SHUTDOWN_TIMEOUT));
}

// Reads from the start and leaves the file at its start, for WinVerifyTrust reading the same handle next.
fn sha256_of(mut file: &File, path: &Path) -> Result<String, PluginError> {
    let rewind = |mut file: &File| {
        file.seek(SeekFrom::Start(0))
            .map_err(|error| PluginError::io(&format!("could not read {}", path.display()), &error))
    };
    rewind(file)?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 1 << 16];
    loop {
        let read = file
            .read(&mut buffer)
            .map_err(|error| PluginError::io(&format!("could not read {}", path.display()), &error))?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    rewind(file)?;
    Ok(hasher.finalize().iter().map(|byte| format!("{byte:02x}")).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Refuse;

    // This policy never permits native code to load.
    unsafe impl Trust for Refuse {
        fn verify(&self, _file: &File, path: &Path, _purpose: Purpose) -> Result<(), PluginError> {
            Err(PluginError::Unsigned {
                path: path.display().to_string(),
            })
        }
    }

    #[test]
    fn an_empty_folder_has_no_drivers() {
        let folder = tempfile::tempdir().unwrap();
        let store = DriverStore::new(folder.path().join("drivers"), Arc::new(Refuse));

        assert!(store.installed().unwrap().is_empty());
    }

    #[test]
    fn a_refused_file_leaves_nothing_behind() {
        let folder = tempfile::tempdir().unwrap();
        let source = folder.path().join("driver.bin");
        std::fs::write(&source, b"not signed").unwrap();
        let store = DriverStore::new(folder.path().join("drivers"), Arc::new(Refuse));

        let error = store.install_file(&source, None).unwrap_err();

        assert_eq!(error.code(), "plugin.unsigned");
        let left: Vec<_> = std::fs::read_dir(store.dir())
            .unwrap()
            .flatten()
            .map(|entry| entry.file_name())
            .collect();
        assert_eq!(left, [LOCK_FILE]);
        assert!(store.installed().unwrap().is_empty());
    }

    #[test]
    fn a_checksum_the_catalog_does_not_list_is_refused_before_the_signature() {
        let folder = tempfile::tempdir().unwrap();
        let source = folder.path().join("driver.bin");
        std::fs::write(&source, b"bytes").unwrap();
        let store = DriverStore::new(folder.path().join("drivers"), Arc::new(Refuse));
        let expected = Expected {
            id: "sqlite".to_owned(),
            version: "0.1.0".to_owned(),
            sha256: "00".repeat(32),
        };

        let error = store.install_file(&source, Some(&expected)).unwrap_err();

        assert_eq!(error.code(), "plugin.checksum_mismatch");
    }

    #[test]
    fn removing_a_driver_that_is_not_installed_says_so() {
        let folder = tempfile::tempdir().unwrap();
        let store = DriverStore::new(folder.path().to_owned(), Arc::new(Refuse));

        assert_eq!(store.remove("sqlite").unwrap_err().code(), "plugin.not_installed");
    }

    #[test]
    fn an_index_entry_cannot_name_a_folder_outside_the_store() {
        let folder = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        std::fs::write(
            folder.path().join(INDEX_FILE),
            format!(
                r#"{{"drivers": [{{"id": "x", "displayName": "X", "version": "1", "folder": "{}", "sha256": "00"}}]}}"#,
                outside.path().display().to_string().replace('\\', "/")
            ),
        )
        .unwrap();
        let store = DriverStore::new(folder.path().to_owned(), Arc::new(Refuse));

        assert!(store.installed().unwrap().is_empty());
        assert!(store.remove("x").is_err());
        assert!(outside.path().exists());
    }

    #[test]
    fn a_folder_no_index_entry_names_is_swept() {
        let folder = tempfile::tempdir().unwrap();
        let stale = folder.path().join("0123456789abcdef0123456789abcdef");
        std::fs::create_dir_all(&stale).unwrap();
        std::fs::write(stale.join(library_file_name()), b"old").unwrap();
        let store = DriverStore::new(folder.path().to_owned(), Arc::new(Refuse));

        store.installed().unwrap();

        assert!(!stale.exists());
    }
}
