//! One DuckDB database per file in this process.
//!
//! Every connection to a file comes from one instance: the workspace's
//! pool, each editor tab and each streamed read. A second instance on
//! the same file would keep a catalogue and a write-ahead log of its
//! own, and DuckDB's file lock does not keep two instances of one
//! process apart, so two windows on the file would overwrite each
//! other's changes. A file is known by its device and inode, so a hard
//! link or a second path to it is the same file, and one attached to
//! another open database counts as open. Every connection holds its
//! instance, which closes the file when the last of them is gone,
//! editor sessions included.

use std::collections::HashMap;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, LazyLock, Mutex, PoisonError, Weak};
use std::time::Duration;

use duckdb::{AccessMode, Config, InterruptHandle};
use tablepro_core::{BusyReason, DriverError, FileClaim, FileEndpoint, FileOpenMode, LossPhase};
use tokio_util::sync::CancellationToken;

use crate::create_file::create_or_replace;
use crate::driver::ENGINE;
use crate::errors::{map_error, map_open_error};

/// The files this process has open. An entry whose instance is gone is
/// a database still closing: its drop removes the entry once DuckDB has
/// let the file go.
static OPEN: LazyLock<Mutex<HashMap<FileId, Opened>>> = LazyLock::new(|| Mutex::new(HashMap::new()));

/// A file whatever path names it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct FileId {
    device: u64,
    inode: u64,
}

impl FileId {
    fn of(path: &Path) -> Option<Self> {
        std::fs::metadata(path).ok().map(|metadata| Self {
            device: metadata.dev(),
            inode: metadata.ino(),
        })
    }
}

struct Opened {
    instance: Weak<Instance>,
    read_only: bool,
    /// The instance's root connection, which asks what it has attached
    /// without keeping the instance alive.
    root: Root,
}

type Root = Arc<Mutex<Option<duckdb::Connection>>>;

/// How long an open waits before it looks again at a file still
/// closing.
const CLOSING_POLL: Duration = Duration::from_millis(10);

/// An open database file, shared by every connection to it.
pub(crate) struct Instance {
    /// What new connections are cloned from, since DuckDB connects only
    /// to a database already open. It runs only the catalogue read of
    /// what is attached. Taken at drop, which closes the file.
    root: Root,
    id: FileId,
    path: PathBuf,
    read_only: bool,
    /// The catalogue name DuckDB gave the file, which the catalogue
    /// reads filter on: attached databases are in the same lists.
    catalog: String,
    /// The file and every file a tab attached, kept from SQLite until the
    /// database closes. Dropped after `root`, once DuckDB has let go.
    claims: Mutex<Vec<FileClaim>>,
}

impl std::fmt::Debug for Instance {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Instance")
            .field("path", &self.path)
            .field("read_only", &self.read_only)
            .field("catalog", &self.catalog)
            .finish_non_exhaustive()
    }
}

/// DuckDB checkpoints the file as its last connection closes. An open of
/// the same file waits until that is done, or it would read a file still
/// being written.
impl Drop for Instance {
    fn drop(&mut self) {
        let mut open = OPEN.lock().unwrap_or_else(PoisonError::into_inner);
        drop(self.root.lock().unwrap_or_else(PoisonError::into_inner).take());
        if open
            .get(&self.id)
            .is_some_and(|entry| entry.instance.strong_count() == 0)
        {
            open.remove(&self.id);
        }
    }
}

/// One connection to an instance, with the handle that interrupts the
/// statement it runs. Declared before the instance, so the connection
/// closes first.
pub(crate) struct Link {
    pub(crate) connection: duckdb::Connection,
    stop: StopHandle,
    instance: Arc<Instance>,
}

/// What stops the statement a connection runs. DuckDB clears an
/// interrupt when its next statement starts, so one sent just before a
/// statement begins is lost: a stop keeps sending it for as long as the
/// connection runs work a stop may cut short.
#[derive(Clone)]
pub(crate) struct StopHandle {
    interrupt: Arc<InterruptHandle>,
    stoppable: Arc<AtomicBool>,
}

impl StopHandle {
    pub(crate) fn interrupt(&self) {
        self.interrupt.interrupt();
    }

    pub(crate) fn is_stoppable(&self) -> bool {
        self.stoppable.load(Ordering::SeqCst)
    }

    pub(crate) fn set_stoppable(&self, stoppable: bool) {
        self.stoppable.store(stoppable, Ordering::SeqCst);
    }
}

impl std::fmt::Debug for Link {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Link").finish_non_exhaustive()
    }
}

impl Link {
    fn new(connection: duckdb::Connection, instance: Arc<Instance>) -> Self {
        let stop = StopHandle {
            interrupt: connection.interrupt_handle(),
            stoppable: Arc::new(AtomicBool::new(false)),
        };
        Self {
            connection,
            stop,
            instance,
        }
    }

    pub(crate) fn stop_handle(&self) -> StopHandle {
        self.stop.clone()
    }

    /// Keep stops off the statements that clean up after work: a
    /// rollback must not be interrupted by the stop that caused it.
    pub(crate) fn hold_stops(&self) {
        self.stop.set_stoppable(false);
    }
}

impl Instance {
    /// Open the file the endpoint names, or join the instance this
    /// process already has on it. Blocks: DuckDB reads the file and
    /// replays its log here, and a file still closing is waited for.
    /// `given_up` is the connect's own stop: the blocking open outlives a
    /// caller that went while it waited, and must not then replace the
    /// file.
    pub(crate) fn open(
        endpoint: &FileEndpoint,
        read_only: bool,
        given_up: &CancellationToken,
    ) -> Result<Arc<Self>, DriverError> {
        let path = endpoint.path();
        let _opening = tablepro_core::opening_file_blocking();
        loop {
            // Held through the open, so two windows opening one file at
            // once get one instance.
            let mut open = OPEN.lock().unwrap_or_else(PoisonError::into_inner);
            let known = FileId::of(path)
                .and_then(|id| open.get(&id))
                .map(|entry| entry.instance.strong_count() > 0);
            match (known, endpoint.mode()) {
                (Some(false), _) => {
                    drop(open);
                    std::thread::sleep(CLOSING_POLL);
                    continue;
                }
                // Replacing a file this process has open would pull it
                // out from under the windows using it.
                (Some(true), FileOpenMode::CreateNew) => return Err(DriverError::Busy(BusyReason::FileLocked)),
                (None, FileOpenMode::CreateNew) => {
                    if FileId::of(path).is_some_and(|id| attached(&open, id, None)) {
                        return Err(DriverError::Busy(BusyReason::FileLocked));
                    }
                    if given_up.is_cancelled() {
                        return Err(DriverError::Cancelled);
                    }
                    create_or_replace(path, given_up)?;
                }
                (_, FileOpenMode::OpenExisting) => {}
            }
            let canonical = existing_file(path)?;
            let id = FileId::of(&canonical).ok_or_else(|| DriverError::FileNotFound {
                path: path.to_path_buf(),
            })?;
            if let Some(entry) = open.get(&id) {
                // One instance is opened one way, and a read-only
                // connection cannot be told apart on one opened to write.
                if entry.read_only != read_only {
                    return Err(DriverError::Busy(BusyReason::FileLocked));
                }
                match entry.instance.upgrade() {
                    Some(instance) => return Ok(instance),
                    None => {
                        drop(open);
                        std::thread::sleep(CLOSING_POLL);
                        continue;
                    }
                }
            }
            if attached(&open, id, None) {
                return Err(DriverError::Busy(BusyReason::FileLocked));
            }
            // No DuckDB database here has the file, so a descriptor this
            // process holds on it is SQLite's, whose locks DuckDB would
            // drop by closing the file on finding no database of its own.
            if tablepro_core::held_by_this_process(&canonical) {
                return Err(DriverError::Busy(BusyReason::FileLocked));
            }
            let claim = tablepro_core::claim_file(&canonical, ENGINE)?;
            let root = duckdb::Connection::open_with_flags(&canonical, config(read_only)?)
                .map_err(|error| map_open_error(error, path))?;
            let catalog = root
                .query_row("SELECT current_database()", [], |row| row.get::<_, String>(0))
                .map_err(|error| map_open_error(error, path))?;
            let root: Root = Arc::new(Mutex::new(Some(root)));
            let instance = Arc::new(Self {
                root: root.clone(),
                id,
                path: canonical,
                read_only,
                catalog,
                claims: Mutex::new(claim.into_iter().collect()),
            });
            open.insert(
                id,
                Opened {
                    instance: Arc::downgrade(&instance),
                    read_only,
                    root,
                },
            );
            return Ok(instance);
        }
    }

    /// A new connection to the database, as DuckDB documents for using
    /// one database from several places.
    pub(crate) fn link(self: &Arc<Self>) -> Result<Link, DriverError> {
        let root = self.root.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(root) = root.as_ref() else {
            return Err(DriverError::ConnectionLost {
                during: LossPhase::Idle,
            });
        };
        let connection = root.try_clone().map_err(map_error)?;
        Ok(Link::new(connection, self.clone()))
    }

    /// A connection for the app's own reads and saves. `SET
    /// default_collation` in an editor tab reaches every connection to
    /// the database, and `=` on a key would then find `'ABC'` and `'abc'`
    /// alike, which DuckDB keeps as two rows: these compare byte for byte
    /// whatever the tabs set.
    pub(crate) fn workspace_link(self: &Arc<Self>) -> Result<Link, DriverError> {
        let link = self.link()?;
        link.connection
            .execute_batch("SET SESSION default_collation = ''")
            .map_err(map_error)?;
        Ok(link)
    }

    pub(crate) fn catalog(&self) -> &str {
        &self.catalog
    }
}

/// The files a database has open, its own and the ones attached to it,
/// under the paths DuckDB lists them by.
fn database_paths(entry: &Opened) -> Vec<String> {
    let root = entry.root.lock().unwrap_or_else(PoisonError::into_inner);
    let Some(root) = root.as_ref() else {
        return Vec::new();
    };
    let paths = root
        .prepare("SELECT path FROM duckdb_databases() WHERE path IS NOT NULL")
        .and_then(|mut statement| {
            statement
                .query_map([], |row| row.get::<_, String>(0))
                .and_then(|rows| rows.collect::<Result<Vec<_>, _>>())
        });
    paths.unwrap_or_else(|error| {
        tracing::warn!(%error, "could not read the databases an open file has attached");
        Vec::new()
    })
}

/// Whether an open database other than `except` has the file attached,
/// which DuckDB lists with its own file.
fn attached(open: &HashMap<FileId, Opened>, id: FileId, except: Option<FileId>) -> bool {
    open.iter().filter(|(key, _)| Some(**key) != except).any(|(_, entry)| {
        database_paths(entry)
            .iter()
            .any(|path| FileId::of(Path::new(path)) == Some(id))
    })
}

/// Run `attach`, an ATTACH on `link` that may open any of `targets`,
/// unless a database in this process has one of them open, as its own
/// file or attached to it: DuckDB would make a second database on it,
/// which writes past the first. DuckDB finds a file the link's own
/// database has open by the path it lists it under, so `ATTACH IF NOT
/// EXISTS` of that path again does nothing, while another name for the
/// file, a hard link among them, would open it twice. The registry is
/// held across the check and the attach, so no window opens the file,
/// and no tab attaches it, in between.
pub(crate) fn attach_unless_open<T>(
    link: &Link,
    targets: &[PathBuf],
    attach: impl FnOnce() -> Result<T, DriverError>,
) -> Result<T, DriverError> {
    let _opening = tablepro_core::opening_file_blocking();
    let open = OPEN.lock().unwrap_or_else(PoisonError::into_inner);
    let own = link.instance.id;
    let own_paths = open.get(&own).map(database_paths).unwrap_or_default();
    let in_use = targets.iter().any(|target| {
        let Some(id) = FileId::of(target) else {
            return false;
        };
        let mut held_here = own_paths
            .iter()
            .filter(|path| FileId::of(Path::new(path)) == Some(id))
            .peekable();
        if held_here.peek().is_some() {
            let spelled = target.to_string_lossy();
            return !held_here.any(|path| *path == spelled);
        }
        // A file no DuckDB database has that this process holds is
        // SQLite's.
        open.contains_key(&id) || attached(&open, id, Some(own)) || tablepro_core::held_by_this_process(target)
    });
    if in_use {
        return Err(DriverError::Busy(BusyReason::FileLocked));
    }
    // A FIFO would hold the ATTACH, and every open in the process behind
    // it, until something wrote to it.
    if let Some(target) = targets
        .iter()
        .find(|target| std::fs::metadata(target).is_ok_and(|metadata| !metadata.is_file()))
    {
        return Err(DriverError::NotADatabase { path: target.clone() });
    }
    let result = attach()?;
    // `ATTACH IF NOT EXISTS` under an alias already taken opens nothing,
    // so only a file the database now lists is claimed.
    let listed: Vec<FileId> = open
        .get(&own)
        .map(database_paths)
        .unwrap_or_default()
        .iter()
        .filter_map(|path| FileId::of(Path::new(path)))
        .collect();
    let mut claims = Vec::with_capacity(targets.len());
    for target in targets {
        if FileId::of(target).is_some_and(|id| listed.contains(&id)) {
            claims.extend(tablepro_core::claim_file(target, ENGINE)?);
        }
    }
    link.instance
        .claims
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .extend(claims);
    drop(open);
    Ok(result)
}

/// DuckDB 1.x's default. DuckDB 2.0 writes files 1.x cannot open, and
/// this keeps every file a connection creates or attaches readable there.
const STORAGE_VERSION: &str = "v0.10.2";

/// Every connection opens the same way. Extensions are never fetched:
/// a query that needs one DuckDB does not link in fails instead of
/// downloading it, as the app makes no requests of its own.
pub(crate) fn config(read_only: bool) -> Result<Config, DriverError> {
    let mode = match read_only {
        true => AccessMode::ReadOnly,
        false => AccessMode::ReadWrite,
    };
    Config::default()
        .access_mode(mode)
        .and_then(|config| config.with("storage_compatibility_version", STORAGE_VERSION))
        .and_then(|config| config.with("autoinstall_known_extensions", "false"))
        .and_then(|config| config.with("autoload_known_extensions", "false"))
        .map_err(map_error)
}

/// DuckDB creates a file it is asked to open and cannot find, so a moved
/// database would come back as a new empty one. Only a file that is
/// there is opened.
/// A directory, a FIFO or a device is no database, and opening a FIFO
/// would wait for a writer that never comes.
fn existing_file(path: &Path) -> Result<PathBuf, DriverError> {
    let canonical = std::fs::canonicalize(path).map_err(|error| file_error(error.kind(), path))?;
    match std::fs::metadata(&canonical) {
        Ok(metadata) if !metadata.is_file() => Err(DriverError::NotADatabase {
            path: path.to_path_buf(),
        }),
        Ok(_) => Ok(canonical),
        Err(error) => Err(file_error(error.kind(), path)),
    }
}

pub(crate) fn file_error(kind: std::io::ErrorKind, path: &Path) -> DriverError {
    let path = path.to_path_buf();
    match kind {
        std::io::ErrorKind::NotFound => DriverError::FileNotFound { path },
        std::io::ErrorKind::IsADirectory | std::io::ErrorKind::NotADirectory => DriverError::NotADatabase { path },
        std::io::ErrorKind::PermissionDenied => DriverError::FileAccessDenied { path },
        kind => DriverError::FileIo { path, kind },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn created(directory: &Path, name: &str) -> FileEndpoint {
        FileEndpoint::create_new(directory.join(name)).unwrap()
    }

    #[test]
    fn a_missing_file_is_not_created() {
        let directory = tempfile::tempdir().unwrap();
        let missing = directory.path().join("moved.duckdb");

        for read_only in [false, true] {
            let opened = Instance::open(
                &FileEndpoint::open_existing(missing.clone()).unwrap(),
                read_only,
                &CancellationToken::new(),
            );

            assert_eq!(opened.unwrap_err(), DriverError::FileNotFound { path: missing.clone() });
            assert!(!missing.exists(), "opening created the file with read_only={read_only}");
        }
    }

    #[test]
    fn one_file_has_one_instance_in_the_process() {
        let directory = tempfile::tempdir().unwrap();
        let first = Instance::open(
            &created(directory.path(), "one.duckdb"),
            false,
            &CancellationToken::new(),
        )
        .unwrap();
        let again = FileEndpoint::open_existing(directory.path().join("one.duckdb")).unwrap();

        let second = Instance::open(&again, false, &CancellationToken::new()).unwrap();

        assert!(Arc::ptr_eq(&first, &second));
        assert_eq!(
            Instance::open(&again, true, &CancellationToken::new()).unwrap_err(),
            DriverError::Busy(BusyReason::FileLocked),
            "a read-only window joined a writable instance"
        );
    }

    /// A window that closes while a tab still runs on the file leaves
    /// the file to that tab, and a window opening it again joins it.
    #[test]
    fn a_connection_keeps_its_instance_open() {
        let directory = tempfile::tempdir().unwrap();
        let first = Instance::open(
            &created(directory.path(), "kept.duckdb"),
            false,
            &CancellationToken::new(),
        )
        .unwrap();
        let link = first.link().unwrap();
        let weak = Arc::downgrade(&first);
        drop(first);

        let again = Instance::open(
            &FileEndpoint::open_existing(directory.path().join("kept.duckdb")).unwrap(),
            false,
            &CancellationToken::new(),
        )
        .unwrap();

        assert!(weak.upgrade().is_some_and(|kept| Arc::ptr_eq(&kept, &again)));
        drop((link, again));
        assert!(weak.upgrade().is_none());
        assert!(
            Instance::open(
                &created(directory.path(), "kept.duckdb"),
                false,
                &CancellationToken::new()
            )
            .is_ok(),
            "the file was still held once every connection was gone"
        );
    }

    /// A connect given up while its open waited does not go on to
    /// replace the file.
    #[test]
    fn a_given_up_create_leaves_the_file_alone() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("kept.duckdb");
        std::fs::write(&path, b"what the user had").unwrap();
        let given_up = CancellationToken::new();
        given_up.cancel();

        let opened = Instance::open(&FileEndpoint::create_new(path.clone()).unwrap(), false, &given_up);

        assert_eq!(opened.unwrap_err(), DriverError::Cancelled);
        assert_eq!(std::fs::read(&path).unwrap(), b"what the user had");
    }

    /// SQLite holding the file in this process would lose its locks when
    /// DuckDB closed the file again.
    #[test]
    fn a_file_another_engine_holds_is_not_opened() {
        let directory = tempfile::tempdir().unwrap();
        let endpoint = created(directory.path(), "held.duckdb");
        drop(Instance::open(&endpoint, false, &CancellationToken::new()).unwrap());
        let reopen = FileEndpoint::open_existing(directory.path().join("held.duckdb")).unwrap();
        let held = std::fs::File::open(directory.path().join("held.duckdb")).unwrap();

        let opened = Instance::open(&reopen, false, &CancellationToken::new());

        assert_eq!(opened.unwrap_err(), DriverError::Busy(BusyReason::FileLocked));
        drop(held);
        let instance = Instance::open(&reopen, false, &CancellationToken::new()).unwrap();
        assert!(tablepro_core::claimed_by_another(&instance.path, "sqlite"));
    }

    #[test]
    fn a_file_is_not_replaced_while_this_process_has_it_open() {
        let directory = tempfile::tempdir().unwrap();
        let endpoint = created(directory.path(), "busy.duckdb");
        let _open = Instance::open(&endpoint, false, &CancellationToken::new()).unwrap();

        assert_eq!(
            Instance::open(&endpoint, false, &CancellationToken::new()).unwrap_err(),
            DriverError::Busy(BusyReason::FileLocked)
        );
    }

    #[test]
    fn the_catalogue_is_named_after_the_file() {
        let directory = tempfile::tempdir().unwrap();

        let instance = Instance::open(
            &created(directory.path(), "sales.duckdb"),
            false,
            &CancellationToken::new(),
        )
        .unwrap();

        assert_eq!(instance.catalog(), "sales");
        assert!(!instance.read_only);
    }

    /// Opening a FIFO would wait for a writer, with every other open in
    /// the process waiting behind it.
    #[test]
    fn a_fifo_is_no_database() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("pipe.duckdb");
        assert!(
            std::process::Command::new("mkfifo")
                .arg(&path)
                .status()
                .unwrap()
                .success()
        );

        let opened = Instance::open(
            &FileEndpoint::open_existing(path.clone()).unwrap(),
            true,
            &CancellationToken::new(),
        );

        assert_eq!(opened.unwrap_err(), DriverError::NotADatabase { path });
    }

    #[test]
    fn a_file_that_is_not_a_database_is_named_as_such() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("notes.duckdb");
        std::fs::write(&path, b"plain text, longer than any header DuckDB reads first").unwrap();

        let opened = Instance::open(
            &FileEndpoint::open_existing(path.clone()).unwrap(),
            true,
            &CancellationToken::new(),
        );

        assert_eq!(opened.unwrap_err(), DriverError::NotADatabase { path });
    }
}
