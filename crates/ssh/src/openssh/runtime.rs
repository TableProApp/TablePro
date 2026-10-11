use std::ffi::OsString;
use std::fs::{DirBuilder, File, Metadata, OpenOptions};
use std::io;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use uuid::Uuid;

use super::OpenSshError;
use super::error::unsafe_dir;

pub(crate) const LOCK_FILE: &str = "lock";

#[derive(Debug)]
pub struct OpenSshRuntime {
    root: PathBuf,
    instance_dir: PathBuf,
    instance_id: String,
    owner_uid: u32,
    _lock: File,
}

impl OpenSshRuntime {
    pub fn default_base() -> Result<PathBuf, OpenSshError> {
        resolve_base(std::env::var_os("XDG_RUNTIME_DIR"), &std::env::temp_dir())
    }

    pub fn acquire(base: &Path) -> Result<Arc<OpenSshRuntime>, OpenSshError> {
        let root = base.join("ssh");
        let root_metadata = private_dir(&root)?;
        let (instance_id, instance_dir) = create_unique_dir(&root, 8)?;
        let instance_metadata =
            std::fs::symlink_metadata(&instance_dir).map_err(|error| unsafe_dir(&instance_dir, error))?;
        if instance_metadata.uid() != root_metadata.uid() {
            if let Err(error) = std::fs::remove_dir(&instance_dir) {
                tracing::debug!(%error, "could not remove a foreign ssh instance directory");
            }
            return Err(unsafe_dir(&root, "the directory belongs to another user"));
        }
        let lock_path = instance_dir.join(LOCK_FILE);
        let lock = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&lock_path)
            .map_err(|error| unsafe_dir(&lock_path, error))?;
        lock.try_lock().map_err(|error| unsafe_dir(&lock_path, error))?;
        Ok(Arc::new(Self {
            root,
            instance_dir,
            instance_id,
            owner_uid: instance_metadata.uid(),
            _lock: lock,
        }))
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn instance_dir(&self) -> &Path {
        &self.instance_dir
    }

    pub fn instance_id(&self) -> &str {
        &self.instance_id
    }

    pub(crate) fn owner_uid(&self) -> u32 {
        self.owner_uid
    }

    pub(crate) fn create_master_dir(&self) -> Result<PathBuf, OpenSshError> {
        create_unique_dir(&self.instance_dir, 4).map(|(_, dir)| dir)
    }
}

fn resolve_base(xdg_runtime_dir: Option<OsString>, temp_dir: &Path) -> Result<PathBuf, OpenSshError> {
    let base = match xdg_runtime_dir.map(PathBuf::from) {
        Some(dir) if dir.is_absolute() && dir.is_dir() => dir.join("tablepro"),
        _ => temp_dir.join(format!("tablepro-{}", current_uid(temp_dir)?)),
    };
    private_dir(&base)?;
    Ok(base)
}

fn current_uid(temp_dir: &Path) -> Result<u32, OpenSshError> {
    std::fs::metadata("/proc/self")
        .map(|metadata| metadata.uid())
        .map_err(|error| unsafe_dir(temp_dir, error))
}

fn private_dir(path: &Path) -> Result<Metadata, OpenSshError> {
    match DirBuilder::new().mode(0o700).create(path) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(unsafe_dir(path, error)),
    }
    let metadata = std::fs::symlink_metadata(path).map_err(|error| unsafe_dir(path, error))?;
    if !metadata.is_dir() {
        return Err(unsafe_dir(path, "the path is not a directory"));
    }
    if metadata.mode() & 0o077 != 0 {
        return Err(unsafe_dir(
            path,
            format!("the directory mode is {:o}, expected 700", metadata.mode() & 0o777),
        ));
    }
    Ok(metadata)
}

fn create_unique_dir(parent: &Path, id_bytes: usize) -> Result<(String, PathBuf), OpenSshError> {
    loop {
        let id: String = Uuid::new_v4()
            .into_bytes()
            .iter()
            .take(id_bytes)
            .map(|byte| format!("{byte:02x}"))
            .collect();
        let dir = parent.join(&id);
        match DirBuilder::new().mode(0o700).create(&dir) {
            Ok(()) => return Ok((id, dir)),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(unsafe_dir(&dir, error)),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::fs::TryLockError;
    use std::os::unix::fs::PermissionsExt;

    use super::*;

    fn mode(path: &Path) -> u32 {
        std::fs::metadata(path).unwrap().permissions().mode() & 0o777
    }

    #[test]
    fn acquire_creates_private_directories_and_holds_the_instance_lock() {
        let temp = tempfile::tempdir().unwrap();
        let runtime = OpenSshRuntime::acquire(temp.path()).unwrap();

        assert_eq!(runtime.root(), temp.path().join("ssh"));
        assert_eq!(mode(runtime.root()), 0o700);
        assert_eq!(mode(runtime.instance_dir()), 0o700);
        assert_eq!(runtime.instance_id().len(), 16);
        let lock_path = runtime.instance_dir().join(LOCK_FILE);
        assert_eq!(mode(&lock_path), 0o600);
        let other = File::open(&lock_path).unwrap();
        assert!(matches!(other.try_lock(), Err(TryLockError::WouldBlock)));

        let master = runtime.create_master_dir().unwrap();
        assert_eq!(master.parent(), Some(runtime.instance_dir()));
        assert_eq!(mode(&master), 0o700);
        assert_eq!(runtime.owner_uid(), std::fs::metadata(&master).unwrap().uid());
    }

    #[test]
    fn a_second_acquire_gets_a_distinct_instance() {
        let temp = tempfile::tempdir().unwrap();
        let first = OpenSshRuntime::acquire(temp.path()).unwrap();
        let second = OpenSshRuntime::acquire(temp.path()).unwrap();
        assert_ne!(first.instance_dir(), second.instance_dir());
    }

    #[test]
    fn a_group_writable_root_is_unsafe() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("ssh");
        std::fs::create_dir(&root).unwrap();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o770)).unwrap();
        assert!(matches!(
            OpenSshRuntime::acquire(temp.path()),
            Err(OpenSshError::RuntimeDirUnsafe { .. })
        ));
    }

    #[test]
    fn a_symlinked_root_is_unsafe() {
        let temp = tempfile::tempdir().unwrap();
        let elsewhere = temp.path().join("elsewhere");
        std::fs::create_dir(&elsewhere).unwrap();
        std::os::unix::fs::symlink(&elsewhere, temp.path().join("ssh")).unwrap();
        assert!(matches!(
            OpenSshRuntime::acquire(temp.path()),
            Err(OpenSshError::RuntimeDirUnsafe { .. })
        ));
    }

    #[test]
    fn the_base_lives_under_the_runtime_dir_when_it_is_set() {
        let runtime = tempfile::tempdir().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let base = resolve_base(Some(runtime.path().into()), temp.path()).unwrap();
        assert_eq!(base, runtime.path().join("tablepro"));
        assert_eq!(mode(&base), 0o700);
    }

    #[test]
    fn the_base_falls_back_to_a_private_temp_dir() {
        let temp = tempfile::tempdir().unwrap();
        for unusable in [
            None,
            Some(OsString::from("relative/run")),
            Some(OsString::from("/nonexistent/run")),
        ] {
            let base = resolve_base(unusable, temp.path()).unwrap();
            assert_eq!(base.parent(), Some(temp.path()));
            assert!(base.file_name().unwrap().to_string_lossy().starts_with("tablepro-"));
            assert_eq!(mode(&base), 0o700);
        }
    }
}
